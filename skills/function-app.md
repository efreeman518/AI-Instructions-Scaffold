# Azure Functions (Isolated Worker)

Reference patterns: [../patterns/expected-output-index.md](../patterns/expected-output-index.md).

## Prerequisites

- [solution-structure.md](solution-structure.md)
- [bootstrapper.md](bootstrapper.md)
- [aspire.md](aspire.md)

## Purpose

Use an isolated-worker Function App for trigger-driven workloads that should run outside API request pipelines. Reuse shared domain/application/infrastructure registrations through Bootstrapper.

## Non-Negotiables

1. Use isolated worker model (`FunctionsApplication.CreateBuilder`) only.
2. Reuse Bootstrapper registration chain; avoid duplicating DI setup.
3. Keep runtime startup keys in `local.settings.json`; use `appsettings.json` for app-level options.
4. Use configuration-bound trigger expressions (`%SettingName%`) for non-hardcoded bindings.
5. Keep function endpoints secure (`AuthorizationLevel.Function` for business handlers; `Anonymous` for health only).

---

## Profile Strategy

Set `functionProfile` in [resource-implementation-schema.md](../ai/resource-implementation-schema.md):

- `starter`: host + HTTP + Timer first.
- `full`: add Blob/StorageQueue/ServiceBus/EventGrid after dependencies are ready.

Prefer `starter` when local infra (Azurite, Service Bus, Event Grid route) is not ready.

---

## Minimal Project Shape

```
src/Host/{App}.Functions/
|-- Program.cs
|-- {App}.FunctionApp.csproj
|-- Settings.cs
|-- appsettings.json
|-- host.json
|-- local.settings.json
|-- FunctionHttpTrigger.cs
|-- FunctionTimerTrigger.cs
|-- Infrastructure/
|   |-- GlobalExceptionHandler.cs
|   `-- GlobalLogger.cs
`-- Model/
```

Trigger files stay flat at the project root and use `Function{TriggerType}` naming.

---

## Host Boot Sequence (Required)

```csharp
var builder = FunctionsApplication.CreateBuilder(args);

builder.Configuration.AddJsonFile("appsettings.json", optional: true);
builder.ConfigureFunctionsWebApplication();

builder.AddServiceDefaults(); // shared telemetry/health/resilience seam - see Telemetry below

builder.Services
    .RegisterDomainServices(config)
    .RegisterInfrastructureServices(config)
    .RegisterApplicationServices(config)
    .RegisterBackgroundServices(config);

builder.UseMiddleware<GlobalExceptionHandler>();
builder.UseMiddleware<GlobalLogger>();

var app = builder.Build();
app.AutoRegisterMessageHandlers();
await app.RunAsync();
```

Key constraints:

- `appsettings.json` is loaded explicitly for app options.
- runtime binding values come from `local.settings.json`/environment.
- If the host uses `AuditInterceptor` or in-process message handlers, Functions still needs the shared background queue + internal bus wiring from the Bootstrapper.
- startup should surface failures through structured logging.

---

## Per-Invocation Request Context (Multi-Tenant Functions)

When the Functions host writes domain rows via the same `*Service.CreateAsync` / `UpdateAsync` paths the API uses, every service call resolves the **scoped** `IRequestContext<...>` to stamp `TenantId` and audit fields. The API path populates that context from JWT claims or the dev tenant header; the Functions worker has no `HttpContext`, so a naive scaffold falls back to a **singleton admin context with `TenantId = Guid.Empty`**, and every webhook-ingested row persists under the wrong tenant. The bug is invisible at the row level - SQL is happy - and only surfaces when a tenant-scoped query returns zero hits.

**Rule:** Functions triggers that ingest tenant-scoped data must build a **per-invocation** `IRequestContext` from the trigger envelope (header, queue message property, blob metadata, Event Grid extended properties) and register it for the duration of the invocation. Do not ship a singleton admin context as a "temporary" placeholder - it ends up persisting wrong-tenant rows in production.

```csharp
public class WebhookProcessorFunction(
    IServiceScopeFactory scopeFactory,
    ILogger<WebhookProcessorFunction> logger)
{
    [Function(nameof(WebhookProcessorFunction))]
    public async Task Run(
        [ServiceBusTrigger("webhook-ingest", Connection = "servicebus")]
            ServiceBusReceivedMessage message,
        CancellationToken ct)
    {
        var tenantId = ResolveTenantId(message); // from envelope/property
        var correlationId = message.CorrelationId ?? Guid.NewGuid().ToString();

        await using var scope = scopeFactory.CreateAsyncScope();
        var ctxAccessor = scope.ServiceProvider.GetRequiredService<IRequestContextAccessor>();
        ctxAccessor.Current = new RequestContext<string, Guid?>(
            correlationId, auditId: "webhook-ingest", tenantId: tenantId, roles: []);

        var service = scope.ServiceProvider.GetRequiredService<I{Entity}Service>();
        await service.CreateAsync(ParseDto(message), ct);
    }
}
```

`IRequestContextAccessor` is a scoped wrapper around an `AsyncLocal`/scoped field that `RegisterServices.RequestContext.cs` already creates the API factory against - reuse the same accessor, just write into it from the trigger instead of an HTTP middleware. The Bootstrapper registration becomes:

```csharp
// Already-scoped factory in RegisterServices.RequestContext.cs
services.AddScoped<IRequestContext<string, Guid?>>(sp =>
    sp.GetRequiredService<IRequestContextAccessor>().Current
    ?? throw new InvalidOperationException("No request context set for this scope."));
```

A **singleton admin** `IRequestContext` is acceptable only for triggers that legitimately span tenants (cross-tenant reporting jobs, system maintenance timers). Document that decision per-trigger; do not let it leak into webhook ingestion.

---

## Trigger Pattern

Use primary-constructor DI + explicit function attributes:

```csharp
public class FunctionTimerTrigger(ILogger<FunctionTimerTrigger> logger)
{
    [Function(nameof(FunctionTimerTrigger))]
    [ExponentialBackoffRetry(5, "00:00:05", "00:05:00")]
    public Task Run([TimerTrigger("%TimerCron%")] TimerInfo timer, CancellationToken ct)
    {
        logger.LogInformation("Timer fired at {UtcNow}", DateTime.UtcNow);
        return Task.CompletedTask;
    }
}
```

### Callback/Webhook Security (HTTP triggers)

For provider callbacks, require all of:

- signature verification before processing
- replay window/timestamp validation
- dedup check before side effects
- auditable rejection path for invalid requests

### Trigger Matrix

| Trigger | Binding Pattern | Notes |
|---|---|---|
| HTTP | `[HttpTrigger(AuthorizationLevel.Function, ...)]` | Business endpoints |
| Timer | `[TimerTrigger("%TimerCron%") ]` | add retry policy |
| Blob | `[BlobTrigger("%BlobContainer%/{file}")]` | storage connection required |
| Storage Queue | `[QueueTrigger("%QueueName%") ]` | poison handling required |
| Service Bus Queue/Topic | `[ServiceBusTrigger(...)]` | dead-letter strategy required |
| Event Grid | `[EventGridTrigger]` | infra route/subscription required |
| Health | HTTP + `AuthorizationLevel.Anonymous` | health only |

---

## Configuration Contract

### `local.settings.json` (runtime)

Must include:

- `FUNCTIONS_WORKER_RUNTIME: dotnet-isolated`
- `AzureWebJobsStorage`
- binding keys (`TimerCron`, `BlobContainer`, queue/topic names)
- connection strings/setting names referenced by triggers

### `appsettings.json` (app options)

Use for host-specific options and injected settings objects (`IOptions<T>`).

### `host.json`

Use for logging, sampling, extension/runtime behavior.

---

## Dependencies

Core packages:

- `Microsoft.Azure.Functions.Worker`
- `Microsoft.Azure.Functions.Worker.Sdk`
- extensions needed by enabled triggers (`Http`, `Timer`, `Storage`, `ServiceBus`, `EventGrid`)

Project file requirements:

- `<AzureFunctionsVersion>v4</AzureFunctionsVersion>`
- `<OutputType>Exe</OutputType>`
- reference to Bootstrapper project

---

## Container Port on ACA (Isolated Worker)

**Azure Functions dotnet-isolated containers listen on port 80, not 8080.** The isolated base image (`mcr.microsoft.com/azure-functions/dotnet-isolated:...`) sets no `ASPNETCORE_URLS`, unlike the ASP.NET hosts here which set `ASPNETCORE_URLS=http://+:8080`. Any `--target-port`/ingress for the Functions app on Container Apps must use **80**. Confirm at first deploy. If the Functions app needs ingress, expose it explicitly in the AppHost publish-mode branch; by default leave it internal (no `.WithExternalHttpEndpoints()`) - see [aspire.md](aspire.md) -> *Ingress Rules*.

---

## Aspire Integration

Register Functions as its own project/resource in AppHost and add only required dependencies (`.WithReference(...)`) for enabled triggers and shared infrastructure.

### AzureWebJobsStorage Under Aspire

The Functions runtime uses `AzureWebJobsStorage` internally for blob trigger leases, timer checkpoints, and internal locking. When Aspire manages Azurite, it runs on **dynamic ports** - the hardcoded `UseDevelopmentStorage=true` in `local.settings.json` (which resolves to `127.0.0.1:10000`) will not work.

Fix both problems in AppHost:

```csharp
var storage = builder.AddAzureStorage("AzureStorage").RunAsEmulator();
var blobs = storage.AddBlobs("BlobStorage1");

builder.AddProject<Projects.{Host}_Functions>("{host}functions")
    .WithReference(blobs)
    .WithReference(serviceBus)
    .WithEnvironment("AzureWebJobsSecretStorageType", "Files")
    .WithEnvironment(ctx =>
    {
        ctx.EnvironmentVariables["AzureWebJobsStorage"] = storage.Resource;
    })
    .WaitFor(storage)
    .WaitFor(sql);
```

Key points:
- **`AzureWebJobsSecretStorageType=Files`** - Prevents the runtime from trying to use Azurite for secret storage (which Aspire doesn't inject automatically).
- **`AzureWebJobsStorage = storage.Resource`** - Injects the Aspire-managed Azurite connection string with correct dynamic ports.
- **`.WaitFor(storage)`** - Ensures Azurite is accepting connections before Functions starts. Without this, blob/timer triggers fail with "connection refused" after 6 retries and the host shuts down.

> `local.settings.json` can keep `UseDevelopmentStorage=true` for standalone `func host start` outside Aspire. Aspire environment variables override it at runtime.

If the Functions host also consumes shared `BlobStorage1`, `TableStorage1`, or `ServiceBus1` clients through the Bootstrapper, make those registrations prefer env/AppHost-injected values over `local.settings.json` fallbacks. Otherwise the host can still connect to stale `UseDevelopmentStorage=true` / empty local settings even when Aspire injected the correct dynamic-port connection strings.

### Make the local Functions run directory absolute

`Microsoft.Azure.Functions.Worker.Sdk` 2.0.x computes `RunWorkingDirectory=$(OutDir)`, a relative path such as `bin\Debug\netX.0`. Aspire may launch `dotnet run --project <absolute-path>` from another directory. Core Tools then fails before binding HTTP with `An error occurred trying to start process 'cmd' ... The directory name is invalid`, while the Aspire proxy only returns 500.

Override the SDK-computed property after `_FunctionsComputeRunArguments` in the Functions project. Do not call Aspire's `WithWorkingDirectory(...)`; `AzureFunctionsProjectResource` is not an `ExecutableResource` and does not support that extension.

```xml
<Target Name="UseAbsoluteFunctionsRunWorkingDirectory"
        AfterTargets="_FunctionsComputeRunArguments">
  <PropertyGroup>
    <RunWorkingDirectory>$([System.IO.Path]::GetFullPath('$(MSBuildProjectDirectory)/$(OutDir)'))</RunWorkingDirectory>
  </PropertyGroup>
</Target>
```

Keep the ordinary AppHost registration:

```csharp
builder.AddAzureFunctionsProject<Projects.{Project}_Functions>("{project}-functions")
    .WithHostStorage(storage);
```

Keep the Functions mesh test red when this launch fails. Only an explicit `{APP}_RUN_FUNCTIONS_TESTS=false` opt-out may mark it inconclusive.

### Always-Aspire by design (no isolation gate)

The API host gates real Azure client registration on connection-string presence so a `WebApplicationFactory` isolation tier can run without Aspire (see [aspire.md](aspire.md) "Detecting Aspire at Runtime - Presence, Not Environment"). The Functions host does **not** do this - it registers its Aspire client integrations unconditionally (`AddSqlServerDbContext`, `AddAzureBlobServiceClient`, `AddAzureServiceBusClient`). This is intentional: there is no in-process WAF-style isolation tier for a Functions worker, so the Aspire-mesh tier - which always supplies connection strings - is the only path that exercises it. Keep these registrations unconditional. If a future Functions host ever needs an isolation tier, reuse the same connection-string presence gate the API uses, never an environment-name check.

---

## Telemetry (Aspire + Functions hazard)

The Functions worker participates in the **shared** telemetry pipeline through `AddServiceDefaults()` (the Azure Monitor OpenTelemetry distro, gated on `APPLICATIONINSIGHTS_CONNECTION_STRING` - owned by [../patterns/infrastructure-wiring.md](../patterns/infrastructure-wiring.md) section Telemetry Export). Two isolated-worker-specific hazards must be respected, or the app breaks at startup or double-reports:

- **No direct App Insights integration in the worker.** Do NOT add `Microsoft.Azure.Functions.Worker.ApplicationInsights` / call `ConfigureFunctionsApplicationInsights()`. Combined with an Aspire orchestration and the Azure Monitor distro it errors on startup. Rely only on the shared exporter in ServiceDefaults.
- **Suppress ASP.NET Core instrumentation in the worker.** The Functions host process already emits request telemetry per invocation. The Azure Monitor distro's `AddAspNetCoreInstrumentation()` would report the same request a second time with the same `OperationId` (duplicate requests). `ConfigureOpenTelemetry` gates ASP.NET Core metric/trace instrumentation off when `{APP}_SUPPRESS_ASPNETCORE_INSTRUMENTATION=true`; the Functions host is the one host that sets it. **Set the flag in both places** so local (Aspire) and cloud (Container Apps) behave identically:
  - AppHost: `.WithEnvironment("{APP}_SUPPRESS_ASPNETCORE_INSTRUMENTATION", "true")` on the Functions resource.
  - `infra/modules/functions.bicep`: the same env var `= 'true'` on the Functions app.

A naive "add App Insights to Functions" instruction breaks the app - this is the correct approach.

---

## Local Development

1. Install Functions Core Tools.
2. Start required local dependencies:
   - Azurite for Blob/Queue triggers.
   - tunneling (`ngrok`/dev tunnel) for Event Grid callback testing.
3. Populate `local.settings.json` (or user secrets/environment values).
4. Run with `func host start --verbose`.

---

## Lite Mode

For `scaffoldMode: lite`:

- generate host + one HTTP trigger only,
- keep config minimal,
- skip advanced trigger wiring until needed.

---

## Rules

1. Isolated worker only; no in-process model.
2. Shared DI comes from Bootstrapper; function-specific additions are appended after.
3. Keep trigger classes flat and consistently named.
4. Prefer `nameof(ClassName)` in `[Function(...)]`.
5. Bind settings via `%SettingName%` expressions.
6. Apply retries for timer/message triggers.
7. Do not expose business handlers as `Anonymous`.
8. If trigger dependencies are not ready, disable registration cleanly rather than shipping broken bindings.
9. Token placeholders remain defined by [placeholder-tokens.md](../ai/placeholder-tokens.md).
10. For event-driven ingestion, align ordering/lateness behavior with `ingestionSemantics` from resource mapping.

---

## Verification

- [ ] project uses `v4` isolated worker (`OutputType=Exe`)
- [ ] Program boot sequence includes Bootstrapper registrations
- [ ] runtime settings include `FUNCTIONS_WORKER_RUNTIME=dotnet-isolated`
- [ ] trigger bindings resolve from configuration settings
- [ ] HTTP auth levels are correct (health-only anonymous)
- [ ] required trigger dependencies are available for enabled triggers
- [ ] AppHost wiring includes Function App references per [aspire.md](aspire.md)
