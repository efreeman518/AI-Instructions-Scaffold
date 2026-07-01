# Test Templates - Aspire / Mesh (Phase 5b, on-demand)

| | |
|---|---|
| **Generates** | `Test/Test.Aspire/AspireTestHost.cs`, `Test/Test.Aspire/AspireMeshLifecycle.cs`, `Test/Test.Aspire/AssemblyInfo.cs`, `Test/Test.Aspire/ApiAuditPipelineTests.cs`, `Test/Test.Aspire/FunctionAuditPipelineTests.cs` (when a Functions host is enabled), Blazor-mesh smoke (when `includeBlazorUI`), `Test/Test.Aspire/Test.Aspire.csproj` |
| **Requires** | an Aspire AppHost project, [test-templates-integration.md](test-templates-integration.md) (the component tier this splits from), `Aspire.Hosting.Testing`, `EF.IntegrationTesting` (Aspire + Environment helpers) |
| **Phase** | Host + lifecycle shells in Phase 4; mesh tests filled in Phase 5b (and Phase 5c for opt-in hosts: Functions, Blazor, Service Bus) |
| **Protocol** | Tests-after - the mesh tier verifies the production AppHost graph end-to-end once the component and endpoint tiers pin behavior. |
| **Component tier** | One-class-vs-one-store tests (repository, audit repository, projection) live in the separate `Test.Integration` project on standalone Testcontainers - see [test-templates-integration.md](test-templates-integration.md). |

## Why this tier exists

`Test.Aspire` is the **mesh** tier - it boots the **production AppHost graph in-process** (API, Functions, SQL, Service Bus emulator, Azure Table Storage) via `DistributedApplicationTestingBuilder` and drives it over **HTTP**. It is the only tier that exercises the full service mesh: `HTTP -> API -> Service Bus -> Function -> projection -> audit row`. Use it for:

- API request -> audit middleware -> Azurite, with polling read-back.
- Functions host request -> audit middleware -> Azurite (longest cold-start; opt-in on `func.exe`).
- Service Bus emulator -> Function trigger -> projection store handoff.
- Blazor-mesh smoke (Gateway routing + Refit + tenant header) when `includeBlazorUI: true`.

> **Why a separate project from `Test.Integration`.** The mesh graph costs ~60-90 s on warm Docker (minutes cold). Keeping mesh tests in their own assembly means the fast component tier never pays that boot, and the graph boots **once per run**, only when a mesh test actually executes. A test belongs here when it needs `CreateHttpClient(...)`, multiple Aspire resources, `WaitForResourceHealthyAsync`, or `DistributedApplicationTestingBuilder`. If it instantiates one class against one store, it belongs in `Test.Integration`.

## Lazy startup + lifecycle

`AspireTestHost` is **lazy**: it exposes a static `EnsureStartedAsync(TestContext)` guarded by a `SemaphoreSlim`, called from each mesh test class's `[ClassInitialize]`. There is no eager `[AssemblyInitialize]` start - the graph boots on the first mesh class to run. Teardown is owned by `AspireMeshLifecycle.[AssemblyCleanup]`, which stops/disposes the graph exactly once regardless of which class warmed it up. All mesh tests are `[DoNotParallelize]`.

> **Naming:** `AspireTestHost` (not `DatabaseFixture`). The fixture owns the full distributed application - DB + Functions + Table Storage + lifecycle - and the name reflects that. It can stay `internal` (consumed only within `Test.Aspire`).

---

## AspireTestHost

### File: `Test/Test.Aspire/AspireTestHost.cs`

```csharp
using Aspire.Hosting;
using Aspire.Hosting.Testing;
using AppHost;
using EF.IntegrationTesting.Aspire;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using EnvironmentVariableScope = EF.IntegrationTesting.Environment.EnvironmentVariableScope;
using FunctionsCoreToolsDiscovery = EF.IntegrationTesting.Environment.FunctionsCoreToolsDiscovery;

namespace Test.Aspire;

/// <summary>
/// Lazy assembly-scoped fixture that starts the full Aspire AppHost graph (API, Functions, SQL, Table
/// Storage) the first time a mesh test class calls <see cref="EnsureStartedAsync"/> from
/// <c>[ClassInitialize]</c>. Mesh tier (Aspire.Hosting.Testing) - the only tier that exercises the full
/// service mesh, which no lighter tier reproduces. Teardown runs once via
/// <c>AspireMeshLifecycle.[AssemblyCleanup]</c>. Per-call <c>.WaitAsync(DefaultTimeout, ct)</c> bounds
/// every async Aspire step; <c>WaitForResourceHealthyAsync</c> avoids races where containers report
/// Running before they accept connections.
/// </summary>
internal static class AspireTestHost
{
    /// <summary>
    /// Per-call deadline applied via <c>.WaitAsync(DefaultTimeout, ct)</c>. Sized for slow cold-starts -
    /// SQL + storage containers on a cold Docker (first image pull, post-prune) can exceed 5 min.
    /// Override with the {APP}_ASPIRE_STARTUP_TIMEOUT_SECONDS env var; defaults to 600 s.
    /// </summary>
    internal static readonly TimeSpan DefaultTimeout = TimeSpan.FromSeconds(
        int.TryParse(Environment.GetEnvironmentVariable("{APP}_ASPIRE_STARTUP_TIMEOUT_SECONDS"), out var s) && s > 0
            ? s
            : 600);

    /// <summary>Cleanup deadline. StopAsync should return promptly; the bound prevents a stuck shutdown.</summary>
    private static readonly TimeSpan CleanupTimeout = TimeSpan.FromMinutes(1);

    /// <summary>
    /// Internal diagnostic switch (NOT a test-selection opt-in). Resource logging is off by default to keep
    /// TRX output readable; set <c>{APP}_ASPIRE_RESOURCE_LOGGING=true</c> only while diagnosing a startup or
    /// routing failure. Document it under troubleshooting, never in the normal test opt-in surface.
    /// </summary>
    internal const string ResourceLoggingEnvironmentVariable = "{APP}_ASPIRE_RESOURCE_LOGGING";

    /// <summary>Guards the lazy single-start so concurrent <c>[ClassInitialize]</c> calls boot the graph once.</summary>
    private static readonly SemaphoreSlim Gate = new(1, 1);

    private static EnvironmentVariableScope? _environment;
    internal static string ConnectionString = null!;

    /// <summary>Shared Aspire app started once for all mesh tests.</summary>
    internal static DistributedApplication? AspireApp { get; private set; }

    /// <summary>True when the resource-logging diagnostic override was set for this run. Default false.</summary>
    internal static bool ResourceLoggingEnabled { get; private set; }

    /// <summary>
    /// Starts the Aspire graph on first call and returns immediately afterwards. Mesh test classes call this
    /// from <c>[ClassInitialize]</c> so the ~60-90 s boot is paid only when a mesh test runs.
    /// </summary>
    internal static async Task EnsureStartedAsync(TestContext context)
    {
        if (AspireApp is not null)
            return;

        await Gate.WaitAsync(context.CancellationToken);
        try
        {
            if (AspireApp is not null)
                return;
            await StartAsync(context.CancellationToken);
        }
        finally
        {
            Gate.Release();
        }
    }

    private static async Task StartAsync(CancellationToken ct)
    {
        // AppHost.cs reads these via Environment.GetEnvironmentVariable, so they must be process env vars.
        _environment = new EnvironmentVariableScope()
            .Set("{APP}_ASPIRE_TESTING", "true");

        if (EnsureFuncToolAvailable())
            _environment.Set("{APP}_INCLUDE_FUNCTIONS", "true");

        ResourceLoggingEnabled = IsEnabled(ResourceLoggingEnvironmentVariable);

        var appHostProgramType = Type.GetType("Program, AppHost", throwOnError: true)!;

        var builder = await DistributedApplicationTestingBuilder.CreateAsync(
            appHostProgramType,
            args: [],
            configureBuilder: (appOptions, hostSettings) =>
            {
                appOptions.DisableDashboard = true; // explicit > implicit default
                // Quiet by default - resource logs flood the TRX and make failures unreadable. The
                // diagnostic override re-enables them; state comes from ResourceNotifications, not logs.
                appOptions.EnableResourceLogging = ResourceLoggingEnabled;

                // Pass parameters through IConfiguration, NOT env-var mutation, so test isolation stays clean.
                hostSettings.Configuration ??= new();
                hostSettings.Configuration["Parameters:sql-password"] = LocalSqlSettings.SharedSaPassword;
            },
            cancellationToken: ct).WaitAsync(DefaultTimeout, ct);

        builder.Services.AddLogging(logging =>
        {
            logging.SetMinimumLevel(LogLevel.Information);
            logging.AddFilter("Microsoft.AspNetCore", LogLevel.Warning);
            logging.AddFilter("Aspire.", LogLevel.Warning);
        });

        AspireApp = await builder.BuildAsync(ct).WaitAsync(DefaultTimeout, ct);
        await AspireApp.StartAsync(ct).WaitAsync(DefaultTimeout, ct);

        // Container reaching Running != SQL accepting connections - wait for the health check.
        await AspireApp.WaitForResourceHealthyAsync("{app}db", DefaultTimeout, ct);

        ConnectionString = await AspireApp.GetRequiredConnectionStringAsync("{app}db", DefaultTimeout, ct);
    }

    /// <summary>Stops and disposes the graph (if started) and restores env vars. Invoked once by AspireMeshLifecycle.</summary>
    internal static async Task StopAsync(CancellationToken ct)
    {
        if (AspireApp is not null)
        {
            try
            {
                await AspireApp.StopAsync(ct).WaitAsync(CleanupTimeout);
            }
            catch (TimeoutException)
            {
                // Bounded shutdown - DisposeAsync below still cleans up underlying processes/containers.
            }

            await AspireApp.DisposeAsync();
            AspireApp = null;
        }

        _environment?.Dispose();
        _environment = null;
    }

    /// <summary>Waits for a named Aspire resource to reach Healthy, bounded by DefaultTimeout. Call before talking to it.</summary>
    internal static Task WaitForResourceHealthyAsync(string resourceName, CancellationToken cancellationToken = default)
    {
        if (AspireApp is null)
            throw new InvalidOperationException("AspireApp is not initialized.");

        return AspireApp.WaitForResourceHealthyAsync(resourceName, DefaultTimeout, cancellationToken);
    }

    /// <summary>Checks if Azure Functions Core Tools (func.exe) is available on PATH.</summary>
    internal static bool EnsureFuncToolAvailable() => FunctionsCoreToolsDiscovery.EnsureFuncToolAvailable();

    /// <summary>True only when the named env var is a case-insensitive "true". Used for diagnostic overrides.</summary>
    private static bool IsEnabled(string variableName) =>
        string.Equals(Environment.GetEnvironmentVariable(variableName), "true", StringComparison.OrdinalIgnoreCase);
}
```

### File: `Test/Test.Aspire/AspireMeshLifecycle.cs`

```csharp
namespace Test.Aspire;

/// <summary>
/// Assembly lifecycle for the mesh tier. The graph is started lazily by
/// <c>AspireTestHost.EnsureStartedAsync</c> from each mesh test class's <c>[ClassInitialize]</c>, so the
/// <c>[AssemblyInitialize]</c> here is intentionally a no-op. <c>[AssemblyCleanup]</c> stops and disposes
/// the graph exactly once, regardless of which mesh class warmed it up.
/// </summary>
[TestClass]
public class AspireMeshLifecycle
{
    [AssemblyInitialize]
    public static void AssemblyInit(TestContext _) { }

    [AssemblyCleanup]
    public static Task AssemblyCleanup(TestContext context) => AspireTestHost.StopAsync(context.CancellationToken);
}
```

### File: `Test/Test.Aspire/AssemblyInfo.cs`

```csharp
[assembly: DoNotParallelize]
```

### Aspire fixture non-negotiables

1. **One shared app per assembly, lazily started** - boot in `EnsureStartedAsync` (guarded by a `SemaphoreSlim`), called from each mesh class's `[ClassInitialize]`. Never per test method. No eager `[AssemblyInitialize]` start.
2. **`Parameters:*` via `configureBuilder.hostSettings.Configuration`** - not env-var mutation.
3. **Scope env vars** - `{APP}_ASPIRE_TESTING`, `{APP}_INCLUDE_FUNCTIONS` via `EnvironmentVariableScope` (restored on dispose). These are read at graph-construction time and baked into the graph once it starts, so the one shared lazily-started graph cannot re-flip them per test. A test that needs a different provider/config (e.g. proving local fallback) builds its own isolated graph (see [ai-integration.md](../skills/ai-integration.md) section Deciding the Live Lane Without Probing the CLI) - it does not mutate the shared graph's env after start.
4. **Per-call `.WaitAsync(DefaultTimeout, ct)`** on every async Aspire call. Not a single umbrella CTS.
5. **`WaitForResourceHealthyAsync(name, ct)` before talking to a resource.** Running != ready.
6. **`[AssemblyCleanup]` lives in `AspireMeshLifecycle`** - bound `StopAsync` with `.WaitAsync(CleanupTimeout)` and catch `TimeoutException` so a stuck teardown does not hang CI.
7. **Distinct `Aspire` category** - tag every mesh test `[TestCategory("Aspire")]`, never `Integration`. The component tier owns `Integration`; sharing the category would boot the whole graph on a `--filter TestCategory=Integration` run, defeating the split.
8. **Configurable startup timeout** - `DefaultTimeout` reads `{APP}_ASPIRE_STARTUP_TIMEOUT_SECONDS` (default 600 s) so cold containers (first image pull, post-prune) do not time out at a hardcoded 5 min.
9. **Default-on, false-only opt-out** - the mesh tier is discoverable and runs by default so Test Explorer surfaces it. Honour `{APP}_RUN_ASPIRE_TESTS=false` and a missing-Docker/AppHost preflight by marking dependent tests `Assert.Inconclusive` with a precise message - never red. Fast CI lanes set the opt-out; they do not rely on an enable flag.
10. **Test containers are ephemeral; the SDK owns teardown.** The AppHost gates `ContainerLifetime.Persistent` + `WithDataVolume` on `!IsAspireTesting()` (see [../skills/aspire.md](../skills/aspire.md), Rules), so the graph this fixture boots uses **ephemeral** containers. `AspireApp.StopAsync()`/`DisposeAsync()` in `AspireTestHost.StopAsync` removes **exactly** the containers this run started. **Never** add a `docker rm` sweep filtered by image, name prefix, or the generic `com.microsoft.dotnet.aspire.container.name` label - that deletes other projects' and sessions' containers, including intentional persistent stacks. The mesh tier needs no Docker cleanup beyond `DisposeAsync`.

### Resource logging off by default

State comes from notifications; raw logs only via the diagnostic override.

Aspire resource logging floods the TRX and makes a real failure impossible to find. Keep it **off by default** and read resource *state* from `ResourceNotifications`, which is always available regardless of the logging switch. Surface the raw logs only through the internal diagnostic override.

- **`DumpResourceState`** uses `AspireApp.ResourceNotifications.TryGetCurrentState(name, out var e)` and prints `State`, `HealthStatus`, `ExitCode`, and start/stop timestamps. This is the primary failure diagnostic - it works with logging off.
- **`DumpResourceLogsAsync`** must be **guarded**: resolve `ResourceLoggerService` via `AspireApp.Services.GetService<ResourceLoggerService>()` (note `GetService`, not `GetRequiredService`). When it is `null` (logging disabled), print a one-line hint naming the override var and return - never throw. Wrap the `GetAllAsync` enumeration in a `try/catch (InvalidOperationException)` so missing/closed log streams degrade to a message, not a test failure.

```csharp
private static void DumpResourceState(string resourceName)
{
    if (AspireApp is null) return;
    if (!AspireApp.ResourceNotifications.TryGetCurrentState(resourceName, out var resourceEvent))
    {
        Console.WriteLine($"{resourceName} state: not found");
        return;
    }
    var s = resourceEvent.Snapshot;
    Console.WriteLine($"{resourceName} state: {s.State}; health: {s.HealthStatus}; exit: {s.ExitCode}; started: {s.StartTimeStamp:O}; stopped: {s.StopTimeStamp:O}");
}

private static async Task DumpResourceLogsAsync(string resourceName, CancellationToken ct)
{
    if (AspireApp is null) return;

    var logs = AspireApp.Services.GetService<ResourceLoggerService>();
    if (logs is null)
    {
        // Logging disabled (the default) - state already came from DumpResourceState above.
        Console.WriteLine($"{resourceName}: resource logging disabled; set {ResourceLoggingEnvironmentVariable}=true to capture Aspire resource logs.");
        return;
    }

    try
    {
        await foreach (var batch in logs.GetAllAsync(resourceName).WithCancellation(ct))
            foreach (var line in batch)
                Console.WriteLine($"{resourceName}: {line}");
    }
    catch (InvalidOperationException ex)
    {
        Console.WriteLine($"{resourceName}: resource logs unavailable: {ex.Message}");
    }
}
```

Call both from a test's failure path before rethrowing (`DumpResourceState(name); await DumpResourceLogsAsync(name, ct); throw;`). `ResourceLoggerService` lives in `Aspire.Hosting.ApplicationModel`.

### Cleanup: ephemeral-by-default, per-run label only as a fallback

The default needs no Docker commands at all - ephemeral test containers are torn down by `DisposeAsync` (non-negotiable 10). Only if a project **must** keep persistent lifetime under test (rare - e.g. a slow Cosmos preview emulator it reuses across runs) do you add explicit cleanup, and it must be scoped to this run's exact ownership, never a generic sweep:

1. Generate one run id in the test host.
2. Pass it to the AppHost through `hostSettings.Configuration` (the same channel as `Parameters:sql-password` in `StartAsync`), e.g. `hostSettings.Configuration["Parameters:test-run-id"] = runId;`.
3. In the AppHost, under `IsAspireTesting()`, stamp each test-owned container: `c.WithContainerRuntimeArgs("--label", $"{app}.aspire.test-run-id={runId}")`.
4. In `AspireMeshLifecycle.[AssemblyCleanup]`, **after** `StopAsync`/`DisposeAsync`, remove only the matching run: `docker ps -aq --filter "label={app}.aspire.test-run-id=<runId>"` -> `docker rm -f`.

Do **not** sweep old stopped containers unless the developer explicitly asks for machine-level Docker cleanup. Removing by exact run id leaves other projects, prior sessions, and intentional persistent containers untouched.

### Opt-out + preflight (default-on, Inconclusive on missing prereqs)

The mesh tier is default-on so Test Explorer discovers it. It must degrade to `Inconclusive` - never red - when the opt-out is set or Docker/AppHost is unavailable. Put the decision in one helper and call it from each mesh class's `[ClassInitialize]` before `EnsureStartedAsync`:

```csharp
internal static class MeshPreflight
{
    /// <summary>Returns a reason to skip (Inconclusive), or null when the mesh tier should run.</summary>
    public static string? SkipReason()
    {
        if (string.Equals(Environment.GetEnvironmentVariable("{APP}_RUN_ASPIRE_TESTS"), "false",
                StringComparison.OrdinalIgnoreCase))
            return "{APP}_RUN_ASPIRE_TESTS=false - mesh tier opted out.";

        if (!DockerAvailable())
            return "Docker Desktop is not running. Start Docker, then run " +
                   "eng/test/start-local-test-stack.ps1, or set {APP}_RUN_ASPIRE_TESTS=false to skip.";

        return null;
    }

    private static bool DockerAvailable()
    {
        try
        {
            using var p = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(
                "docker", "info") { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false });
            p!.WaitForExit(5000);
            return p.HasExited && p.ExitCode == 0;
        }
        catch { return false; }
    }
}

// In each mesh test class:
[ClassInitialize]
public static async Task ClassInit(TestContext context)
{
    var skip = MeshPreflight.SkipReason();
    if (skip is not null) { Assert.Inconclusive(skip); return; }
    await AspireTestHost.EnsureStartedAsync(context);
}
```

`Assert.Inconclusive` in `[ClassInitialize]` marks the class's tests inconclusive without failing the run. The message is precise and actionable - no vague "skipped".

---

## API Audit Pipeline Test

End-to-end: `POST /api/{entities}` -> API request handling -> audit middleware -> Azurite Table Storage, with polling read-back. Two Aspire resources participate (`{app}api`, `TableStorage1`); both must be Healthy.

### File: `Test/Test.Aspire/ApiAuditPipelineTests.cs`

```csharp
using System.Net;
using System.Net.Http.Json;
using Aspire.Hosting.Testing;
using Azure;
using Azure.Data.Tables;
using EF.Common.Contracts;
using {Project}.Application.Models;
using {Project}.Infrastructure.Storage;

namespace Test.Aspire;

/// <summary>
/// End-to-end audit pipeline test for the API: POST /api/{entities} -> API request handling -> audit
/// middleware -> Azurite Table Storage row, with a polling read-back. Mesh tier (Aspire.Hosting.Testing) -
/// two Aspire resources participate ({app}api for the request, TableStorage1 for verification), both must
/// be Healthy. The polling helper tolerates eventual consistency between request completion and table
/// visibility.
/// Manual run (Docker Desktop must be running; start the local stack first - see
/// eng/test/start-local-test-stack.ps1):
///   dotnet test src/Test/Test.Aspire/Test.Aspire.csproj --filter TestCategory=Aspire
/// Set {APP}_RUN_ASPIRE_TESTS=false to skip the mesh tier (e.g. in fast CI lanes).
/// </summary>
[TestClass]
[TestCategory("Aspire")]
[DoNotParallelize]
public class ApiAuditPipelineTests
{
    private static readonly Guid ScaffoldTenantId = Guid.Parse("00000000-0000-0000-0000-000000000001");

    /// <summary>Boots the Aspire graph lazily on first mesh-test class to run; teardown is owned by <c>AspireMeshLifecycle</c>.</summary>
    [ClassInitialize]
    public static Task ClassInit(TestContext context) => AspireTestHost.EnsureStartedAsync(context);

    [TestMethod]
    [Timeout(300000)]
    public async Task Given_Api{Entity}Create_When_RequestHandled_Then_AuditEntryPersistedToTableStorage()
    {
        var ct = CancellationToken.None;
        await AspireTestHost.WaitForResourceHealthyAsync("{app}api", ct);
        await AspireTestHost.WaitForResourceHealthyAsync("TableStorage1", ct);

        using var client = AspireTestHost.AspireApp!.CreateHttpClient("{app}api", "http");
        client.Timeout = TimeSpan.FromMinutes(10);
        var auditWindowStartUtc = DateTimeOffset.UtcNow;

        var request = new DefaultRequest<{Entity}Dto>
        {
            Item = new {Entity}Dto { Name = $"Api Audit {Guid.NewGuid():N}", /* ... */ }
        };

        using var response = await PostCreateWithRetryAsync(client, request, ct);
        Assert.AreEqual(HttpStatusCode.Created, response.StatusCode);

        var connectionString = await AspireTestHost.AspireApp!.GetRequiredConnectionStringAsync(
            "TableStorage1", AspireTestHost.DefaultTimeout, ct);
        var tableClient = new TableServiceClient(connectionString).GetTableClient("{app}audit");
        var auditEntity = await WaitForAuditEntityAsync(
            tableClient, ScaffoldTenantId.ToString(), "{Entity}", "Added", auditWindowStartUtc, ct);

        Assert.IsNotNull(auditEntity);
        Assert.AreEqual(ScaffoldTenantId.ToString(), auditEntity.PartitionKey);
        Assert.AreEqual("{Entity}", auditEntity.EntityType);
        Assert.AreEqual("Added", auditEntity.Action);
        Assert.AreEqual(AuditStatus.Success.ToString(), auditEntity.Status);
        Assert.IsTrue(auditEntity.RecordedUtc >= auditWindowStartUtc);
    }

    private static async Task<HttpResponseMessage> PostCreateWithRetryAsync(
        HttpClient client, object request, CancellationToken ct)
    {
        // Poll until 201 or a 45 s deadline. The API may not serve requests in the first second after Running.
        var deadline = DateTimeOffset.UtcNow.AddSeconds(45);
        HttpStatusCode? lastStatusCode = null;
        string? lastBody = null;

        while (DateTimeOffset.UtcNow < deadline)
        {
            try
            {
                var response = await client.PostAsJsonAsync("/api/{entities}", request, ct);
                if (response.StatusCode == HttpStatusCode.Created) return response;
                lastStatusCode = response.StatusCode;
                lastBody = await response.Content.ReadAsStringAsync(ct);
                response.Dispose();
            }
            catch (HttpRequestException) { }
            await Task.Delay(TimeSpan.FromSeconds(1), ct);
        }

        Assert.Fail($"Create API did not return 201. Last status: {lastStatusCode}; body: {lastBody}");
        throw new InvalidOperationException("Unreachable");
    }

    private static async Task<AuditLogTableEntity> WaitForAuditEntityAsync(
        TableClient tableClient, string partitionKey, string expectedEntityType,
        string expectedAction, DateTimeOffset windowStartUtc, CancellationToken ct)
    {
        // Poll the table for a matching row inside the audit window. Tolerates the gap between 201 and flush.
        var deadline = DateTimeOffset.UtcNow.AddSeconds(45);
        while (DateTimeOffset.UtcNow < deadline)
        {
            try
            {
                await foreach (var entity in tableClient.QueryAsync<AuditLogTableEntity>(
                    e => e.PartitionKey == partitionKey, cancellationToken: ct))
                {
                    if (entity.RecordedUtc >= windowStartUtc
                        && entity.EntityType == expectedEntityType
                        && entity.Action == expectedAction
                        && entity.Status == AuditStatus.Success.ToString())
                    {
                        return entity;
                    }
                }
            }
            catch (RequestFailedException ex) when (ex.Status == 404) { /* table not yet created */ }
            await Task.Delay(TimeSpan.FromSeconds(1), ct);
        }
        Assert.Fail($"Expected audit entity not found for partition '{partitionKey}'.");
        throw new InvalidOperationException("Unreachable");
    }
}
```

### Why downstream-effect polling matters

Aspire's emulators (Service Bus, Azurite) are best-effort under `DistributedApplicationTestingBuilder`. Asserting "audit row exists in Azurite for this request" exercises the same path production runs through, and it survives the small lag between HTTP 201 and the background `AuditHandler` flushing. **Assert against the persistent downstream effect (the audit row, the projection document), not against the bus/queue.** When the downstream effect is genuinely unavailable in this test scope, `[Ignore]` with a reason rather than asserting against the bus and accepting flakes.

---

## Other mesh tests (generate when the host is enabled)

- **`FunctionAuditPipelineTests`** (`includeFunctions`): same shape against the `{app}functions` resource; gate on `AspireTestHost.EnsureFuncToolAvailable()` and `Assert.Inconclusive` when `func.exe` is absent. Functions has the longest cold-start - keep the 300 s `[Timeout]`.
- **Blazor-mesh smoke** (`includeBlazorUI`): `Test.Aspire/BlazorMeshSmokeTests`. Opt the Blazor resource into the graph via `{APP}_INCLUDE_BLAZOR=true` and hit one page that round-trips through the API (Gateway routing + Refit + tenant header). Calls `AspireTestHost.EnsureStartedAsync` from `[ClassInitialize]`.
- **Service Bus -> Function -> projection**: assert on the projection store's downstream document, never the topic/queue.

---

## Project file

### File: `Test/Test.Aspire/Test.Aspire.csproj`

```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <IsTestProject>true</IsTestProject>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="MSTest" />
    <PackageReference Include="Aspire.Hosting.Testing" />
    <PackageReference Include="Aspire.Hosting.Azure.Storage" />
    <PackageReference Include="Azure.Data.Tables" />
    <PackageReference Include="EF.IntegrationTesting" />
  </ItemGroup>
  <ItemGroup>
    <Using Include="Microsoft.VisualStudio.TestTools.UnitTesting" />
  </ItemGroup>
  <ItemGroup>
    <ProjectReference Include="..\Test.Support\Test.Support.csproj" />
    <ProjectReference Include="..\..\Host\{Host}.Api\{Host}.Api.csproj" />
    <ProjectReference Include="..\..\Application\{Project}.Application.Models\{Project}.Application.Models.csproj" />
    <ProjectReference Include="..\..\Infrastructure\{Project}.Infrastructure.Storage\{Project}.Infrastructure.Storage.csproj" />
    <ProjectReference Include="..\..\Host\Aspire\AppHost\AppHost.csproj" AdditionalProperties="SkipUnoWasmBuild=true" />
  </ItemGroup>
</Project>
```

> **`SkipUnoWasmBuild=true` on the AppHost reference.** When the AppHost registers a Uno WASM wrapper host (`{Project}.Uno.WasmHost`), referencing AppHost transitively drags in the Uno WASM build - minutes of `wasm-tools` work that a mesh test never needs. Pass `AdditionalProperties="SkipUnoWasmBuild=true"` on **every** test project that references AppHost (`Test.Aspire`, the C# `Test.PlaywrightUI` host) so they compile fast without forcing the browser-asset build. Omit it only when the scaffold has no Uno UI. The full-solution build still produces the WASM assets - this flag scopes out the cost for AppHost-referencing *test* projects, not the solution.

---

## Verification

- [ ] `Test.Aspire` references `AppHost` and `Aspire.Hosting.Testing`; it is registered in the solution.
- [ ] `AspireTestHost` is lazy (`EnsureStartedAsync` + `SemaphoreSlim`); no eager `[AssemblyInitialize]` start.
- [ ] `AspireMeshLifecycle.[AssemblyCleanup]` stops/disposes the graph once; bounded by `CleanupTimeout`.
- [ ] Every mesh test class calls `AspireTestHost.EnsureStartedAsync` from `[ClassInitialize]` and is `[DoNotParallelize]`.
- [ ] Every async Aspire call has its own `.WaitAsync(DefaultTimeout, ct)`; tests gate on `WaitForResourceHealthyAsync`.
- [ ] `Parameters:*` passed via `configureBuilder.hostSettings.Configuration`; env vars scoped + restored.
- [ ] Multi-resource pipeline tests assert against the **downstream persistent effect** (audit row, projection document), not the bus/queue.
- [ ] Every mesh test carries `[TestCategory("Aspire")]` (not `Integration`); `--filter TestCategory=Integration` boots **no** graph.
- [ ] `DefaultTimeout` reads `{APP}_ASPIRE_STARTUP_TIMEOUT_SECONDS` (default 600 s).
- [ ] Mesh classes preflight via `MeshPreflight.SkipReason()` -> `Assert.Inconclusive` on `{APP}_RUN_ASPIRE_TESTS=false` or missing Docker (never red).
- [ ] Test-booted containers are **ephemeral** (AppHost gates persistent lifetime + data volume on `!IsAspireTesting()`); cleanup is `DisposeAsync` only - no `docker rm` sweep by image, name prefix, or the generic `com.microsoft.dotnet.aspire.container.name` label.
- [ ] Running `Test.Aspire` boots the graph **once**; running `Test.Integration` boots **no** graph.
- [ ] `EnableResourceLogging` defaults to **false**; the `{APP}_ASPIRE_RESOURCE_LOGGING=true` override re-enables it. Failure diagnostics read `ResourceNotifications` state; `DumpResourceLogsAsync` resolves `ResourceLoggerService` with `GetService` and no-ops (never throws) when logging is off.

---

**TaskFlow proof (local):**
- `../AI-Instructions-ReferenceApp/src/Test/Test.Aspire/AspireTestHost.cs`
- `../AI-Instructions-ReferenceApp/src/Test/Test.Aspire/AspireMeshLifecycle.cs`
- `../AI-Instructions-ReferenceApp/src/Test/Test.Aspire/ApiAuditPipelineTests.cs`
- `../AI-Instructions-ReferenceApp/src/Test/Test.Aspire/FunctionAuditPipelineTests.cs`

**TaskFlow proof (remote fallback):**
<https://github.com/efreeman518/AI-Instructions-ReferenceApp/tree/main/src/Test/Test.Aspire>
