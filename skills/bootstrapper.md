# Bootstrapper

> **When to read:** Phase 5b/5c, when wiring shared DI for domain/application/infrastructure services that multiple hosts (API, Function App, Scheduler, integration tests) consume.
> **Skip if:** Single-host scaffold where registration lives directly in the host; pure domain or pure data-access work that does not touch DI.

## Overview

The **Bootstrapper project** is the centralized DI registration hub. It wires up all non-host-specific services (domain, application, infrastructure) so they can be shared across multiple deployable hosts - API, Function App, Scheduler, and integration tests - without duplicating registration code.

## Project Structure

> Reference patterns: [../patterns/api-host-wiring.md](../patterns/api-host-wiring.md) (API Startup), [../patterns/data-layer-wiring.md](../patterns/data-layer-wiring.md) (DB Wiring).
> Base types (`IStartupTask`, `RunStartupTasks()`): [../support/ef-packages-reference.md](../support/ef-packages-reference.md).
> `StaticLogging`: from `EF.Common` package (used in Program.cs for early logger).

```
Host/{Host}.Bootstrapper/
|-- RegisterServices.cs                       # Partial class - public orchestration methods
|-- Registration/
|   |-- RegisterServices.Application.cs        # App services, message handlers
|   |-- RegisterServices.Caching.cs            # FusionCache + Redis backplane
|   |-- RegisterServices.Database.cs           # DbContext pooling, repositories
|   |-- RegisterServices.Infrastructure.cs     # Blob storage, service bus, health checks
|   `-- RegisterServices.RequestContext.cs     # Scoped IRequestContext factory
|-- IStartupTask.cs                           # Startup task interface
|-- IHostExtensions.cs                        # Host extension for running startup tasks
`-- StartupTasks/
    `-- WarmupDependencies.cs
```

## Registration Pattern

`RegisterServices.cs` is a **partial static class** with extension methods on `IServiceCollection`, organized by layer. Private helper methods live in partial files under `Registration/`:

> See [../patterns/data-layer-wiring.md](../patterns/data-layer-wiring.md) for full registration pattern.

```csharp
// Compact pattern - see reference app (TaskFlow) for full implementation
public static partial class RegisterServices
{
    public static IServiceCollection RegisterDomainServices(this IServiceCollection services, IConfiguration config)
    {
        // Domain services (if any)
        return services;
    }

    public static IServiceCollection RegisterApplicationServices(this IServiceCollection services, IConfiguration config)
    {
        AddMessageHandlers(services);
        AddApplicationServices(services, config);
        return services;
    }

    public static IServiceCollection RegisterInfrastructureServices(this IServiceCollection services, IConfiguration config)
    {
        services.AddSingleton(TimeProvider.System);
        AddRequestContextServices(services);
        AddCachingServices(services, config);
        AddDatabaseServices(services, config);  // Pooled factories + scoped wrappers
        AddAzureClientServices(services, config);
        AddStartupTasks(services);
        return services;
    }

    public static IServiceCollection RegisterBackgroundServices(this IServiceCollection services, IConfiguration config)
    {
        // Host-specific listeners / cron services go here.
        // The shared channel queue + internal message bus live in AddSupportServices().
        return services;
    }
}
```

### Support Services (Background Task Queue + Internal Message Bus)

`AuditInterceptor` from the EF packages depends on `IInternalMessageBus`, which in turn depends on `IBackgroundTaskQueue`. These must be registered early, before database services:

```csharp
private static IServiceCollection AddSupportServices(this IServiceCollection services)
{
    services.AddChannelBackgroundTaskQueueWithShutdownHandling();
    services.AddSingleton<IInternalMessageBus, InternalMessageBus>();
    return services;
}
```

Call `AddSupportServices()` as the **first** registration in the main chain (before `AddDatabaseServices`). Without it, any host that registers `AuditInterceptor` will fail at startup with a DI resolution error.

`InternalMessageBus` does **not** execute handlers inline. It enqueues work onto `IBackgroundTaskQueue`, which is drained by the channel hosted service. If you skip `AddChannelBackgroundTaskQueueWithShutdownHandling()`, audited saves can succeed while message-handler side effects never execute.

Required usings:
```csharp
using EF.BackgroundServices;
using EF.BackgroundServices.InternalMessageBus;
using EF.BackgroundServices.Work;
```

> **Note:** `AddBackgroundTaskQueue()` and `AddChannelBackgroundTaskQueue()` register different concrete types. If `AuditInterceptor` expects `ChannelBackgroundTaskQueue`, use `AddChannelBackgroundTaskQueueWithShutdownHandling()` - it registers both the queue and the hosted service that drains it on shutdown.
```

## Conditional (Per-Host) Dependency Pattern

Not every host wires every infrastructure client. The Functions host commonly omits `CosmosClient`, the Scheduler omits Service Bus senders, and Lite-mode API skips Redis. Any **shared** registration that depends on a client only some hosts have **must be opt-in**, not part of `RegisterInfrastructureServices` / `RegisterApplicationServices`.

**Symptom of getting this wrong:** `UseDefaultServiceProvider(opt => opt.ValidateOnBuild = true)` throws at host startup with `"Unable to resolve service for type 'Microsoft.Azure.Cosmos.CosmosClient' while attempting to activate '{App}.Infrastructure.Cosmos.ActivityFeedRepository'."` - a host that never reads activity feed still fails to start because the registration is unconditional.

### Rule

Any service whose implementation depends on `CosmosClient`, `ServiceBusClient`, `IConnectionMultiplexer` (Redis), `BlobServiceClient`, or `TableServiceClient` is registered through a **feature-scoped extension** named `Register{Feature}Services(this IServiceCollection services, IConfiguration config)`. The extension is called **only by hosts that also wire the underlying Azure client** (`AddAzureCosmosClient`, `AddAzureServiceBusClient`, etc.).

```csharp
// Bootstrapper/Registration/RegisterServices.ActivityFeed.cs
public static partial class RegisterServices
{
    public static IServiceCollection RegisterActivityFeedServices(
        this IServiceCollection services, IConfiguration config)
    {
        services.AddScoped<IActivityFeedRepository, ActivityFeedRepository>();
        services.AddScoped<IActivityFeedService, ActivityFeedService>();
        return services;
    }
}
```

```csharp
// Host/{App}.Api/Program.cs - opts in only when Cosmos is wired
builder.AddAzureCosmosClient("ActivityFeedCosmos"); // Aspire-injected
builder.Services
    .RegisterInfrastructureServices(config)
    .RegisterApplicationServices(config)
    .RegisterActivityFeedServices(config);          // <- per-host opt-in

// Host/{App}.Functions/Program.cs - does NOT call RegisterActivityFeedServices
// because it has no AddAzureCosmosClient and no consumer of the feed.
```

**Do not** rely on `TryAdd*` or runtime null-checks inside `RegisterInfrastructureServices` to "auto-detect" whether the client is present. `ValidateOnBuild` runs before any first request, sees the unsatisfied `CosmosClient` dependency, and fails - comments like `// registered when a CosmosClient is in the container` are not enforcement.

**Naming convention:** one feature -> one `RegisterServices.{Feature}.cs` partial -> one `Register{Feature}Services` extension. Apply to: Cosmos-backed features (activity feeds, audit ingest), Service Bus publishers/processors, Redis-only services (distributed locks, backplane caches), Event Hub producers/processors, and AI Search/Foundry clients.

Record per-host opt-ins in `HANDOFF.md` under a `featureOptIns:` block so the next session knows which hosts call which extensions without re-reading every `Program.cs`.

### `IOptions<T>` Settings Types Must Be Instantiable

Any class bound via `IOptions<T>` / `Configure<T>` must be **concrete and parameterless-constructible**. `OptionsFactory<T>.Create` calls `Activator.CreateInstance<T>()` before the configure delegate runs, so an `abstract` settings base (even one with no abstract members) crashes the first consumer with `MissingMethodException: Cannot dynamically create an instance of type '...SettingsBase'`. Either drop `abstract` from the base or make the consumer generic in `TSettings`; do not bind via `IOptions<AbstractBase>`.

### Symmetric `Configure<T>` Across Hosts

Every host that registers a service-bus sender / processor / blob writer must **also** call the matching `services.Configure<{SettingsType}>(...)` with the entity path / container name. Skipping the configure block lets the host start green, then crashes on first publish with `"ServiceBusSenderSettingsBase.EntityPath is not configured"` (or equivalent) at the first send / first message processed.

Treat it as a paired registration:

```csharp
// Symmetric in both API and Functions hosts:
services.AddSingleton<IWebhookIngestSender, WebhookIngestSender>();
services.Configure<ServiceBusSenderSettingsBase>(opts =>
{
    opts.EntityPath = "webhook-ingest";
    opts.ServiceBusClientName = "servicebus";
});
```

The Phase 5c gate (`function-app`, `background-services`, `messaging`) must verify that any host registering an `ISender` / `IProcessor` also configures its settings - a green build does not catch this.

## Startup Task Pattern

> See [../patterns/data-layer-wiring.md](../patterns/data-layer-wiring.md).

### Interface

```csharp
public interface IStartupTask
{
    Task ExecuteAsync(CancellationToken cancellationToken = default);
}
```

### Host Extension

```csharp
public static void AutoRegisterMessageHandlers(this IHost host)
{
    var msgBus = host.Services.GetRequiredService<IInternalMessageBus>();
    msgBus.AutoRegisterHandlers(host.Services, typeof(SomeMessageHandler).Assembly);
}

public static async Task RunStartupTasks(this IHost host)
{
    host.AutoRegisterMessageHandlers();
    using var scope = host.Services.CreateScope();
    foreach (var task in scope.ServiceProvider.GetServices<IStartupTask>())
        await task.ExecuteAsync();
}
```

`[ScopedMessageHandler]` marks the handler for scoped resolution during dispatch. It does **not** add the handler to DI. Register each `IMessageHandler<T>` implementation explicitly in `RegisterApplicationServices()`.

### Example Startup Tasks

Startup tasks cover runtime warm-up concerns only: cache preload, dependency warmup, local-dev seeding (see [../patterns/data-layer-wiring.md](../patterns/data-layer-wiring.md) section Startup Tasks). Schema migrations are never a startup task - they run in the dedicated `{App}.DatabaseMigrator` host (see [../support/data-persistence-advanced.md](../support/data-persistence-advanced.md) section Migration Ownership: Dedicated Migrator Host).

```csharp
// Warm critical downstream dependencies before accepting traffic
public class WarmupDependencies(IFusionCacheProvider cache, ILogger<WarmupDependencies> logger) : IStartupTask
{
    public async Task ExecuteAsync(CancellationToken ct = default)
    {
        logger.LogInformation("Startup warmup start");
        // Preload hot cache entries, prime connection pools
        await Task.CompletedTask;
        logger.LogInformation("Startup warmup finish");
    }
}
```

## Usage in Host Projects

> See [../patterns/api-host-wiring.md](../patterns/api-host-wiring.md) (API Startup Sequence).

### API Program.cs

```csharp
var builder = WebApplication.CreateBuilder(args);
var config = builder.Configuration;

builder.Services
    .RegisterInfrastructureServices(config)
    .RegisterDomainServices(config)
    .RegisterApplicationServices(config)
    .RegisterBackgroundServices(config)
    .AddApiServices(config, startupLogger);  // API-specific

var app = builder.Build().ConfigurePipeline();
await app.RunStartupTasks();
await app.RunAsync();
```

### Function App Program.cs

```csharp
builder.Services
    .RegisterInfrastructureServices(builder.Configuration)
    .RegisterDomainServices(builder.Configuration)
    .RegisterApplicationServices(builder.Configuration)
    .RegisterBackgroundServices(builder.Configuration);
    // No RegisterApiServices - functions don't need endpoints/auth pipeline

var app = builder.Build();
app.AutoRegisterMessageHandlers();
await app.RunAsync();
```

## Key Principles

1. **One Bootstrapper project** - All non-host-specific DI goes here
2. **Host projects only add host-specific concerns** - API adds endpoints/auth, Functions add triggers, etc.
3. **Extension method chaining** - Each `Register*()` returns `IServiceCollection` for fluent chaining
4. **Private helper methods** - Keep the public surface clean; group related registrations
5. **Configuration-driven** - Settings classes loaded from `IConfiguration` sections; bootstrapper reads config, never owns per-host defaults
6. **Startup tasks run after Build()** - Before `RunAsync()`, caches warmed, dev seed applied - never schema migrations (migrator host owns those)
7. **Every host must supply its config** - Any key read inside `RegisterInfrastructureServices` (or any shared registration method) must exist in the `appsettings*.json` of every host that calls it: API, Scheduler, and Functions all need the same config keys
8. **Build after DI changes** - Small registration changes (factory lambdas, new `using` imports, constructor signature changes) can break compile. Run a focused host build immediately after any registration edit to catch failures early

---

## Verification

After generating the Bootstrapper, confirm:

- [ ] Single `RegisterServices.cs` (partial class) with public `RegisterInfrastructureServices`, `RegisterDomainServices`, `RegisterApplicationServices`, and `RegisterBackgroundServices` extension methods
- [ ] Private helper methods split into `Registration/RegisterServices.*.cs` partial files
- [ ] DbContexts registered via pooled factory with scoped wrappers
- [ ] All `I{Entity}RepositoryTrxn` and `I{Entity}RepositoryQuery` interfaces registered
- [ ] All `I{Entity}Service` implementations registered
- [ ] All `IMessageHandler<T>` implementations are registered in DI (typically scoped)
- [ ] `AutoRegisterMessageHandlers()` called after `Build()` to bind handler assemblies into `IInternalMessageBus`
- [ ] FusionCache registered with Redis backplane (if caching is enabled)
- [ ] Startup tasks registered as `IStartupTask` (cache warmup, dev seeding - never schema migrations)
- [ ] No host-specific concerns (no endpoints, no triggers, no YARP) - those belong in the host project
- [ ] Cross-references: Every service/repository in [solution-structure.md](solution-structure.md) reference map is registered here

---

**TaskFlow proof (local):** `../AI-Instructions-ReferenceApp/src/Host/TaskFlow.Bootstrapper/RegisterServices.cs` + `../AI-Instructions-ReferenceApp/src/Host/TaskFlow.Bootstrapper/Registration/RegisterServices.*.cs` (Application, Infrastructure, Database, Caching, RequestContext partials)
**TaskFlow proof (remote fallback):** <https://github.com/efreeman518/AI-Instructions-ReferenceApp/tree/main/src/Host/TaskFlow.Bootstrapper>

## Application Style Registration

Resolve application style from `<APP>_APPLICATION_STYLE`, then `Application:Style`, defaulting to `Service`. Register shared application services once. In CQRS or switch mode, add command/query handlers with `AddDecoratedRequestHandler<TRequest,TResponse,THandler>()`; endpoint registration chooses the service or CQRS endpoint set. Keep service registrations when other hosts or AI tools still consume `I{Entity}Service`.
