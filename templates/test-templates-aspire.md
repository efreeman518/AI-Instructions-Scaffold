# Test Templates - Aspire / Mesh (Phase 5b, on-demand)

| | |
|---|---|
| **Generates** | `tests/Test.Support/Hosting/DockerRuntimePreflight.cs`, `tests/Test.Support/Aspire/AspireTestHostContext.cs`, `tests/Test.Aspire/AspireTestHost.cs`, `tests/Test.Aspire/AspireMeshLifecycle.cs`, `tests/Test.Aspire/AssemblyInfo.cs`, `tests/Test.Aspire/ApiAuditPipelineTests.cs`, `tests/Test.Aspire/FunctionAuditPipelineTests.cs` (when a Functions host is enabled), Blazor-mesh smoke (when `includeBlazorUI`), `tests/Test.Aspire/Test.Aspire.csproj` |
| **Requires** | an Aspire AppHost project, [test-templates-integration.md](test-templates-integration.md) (the component tier this splits from), `Aspire.Hosting.Testing` on `Test.Support` plus Aspire-backed consumers, `EF.IntegrationTesting` (Aspire + Environment helpers) |
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

## One AppHost Graph Per Mesh Run

Canonical rule: [../skills/testing.md](../skills/testing.md#heavy-aspire-mesh-graph-rule) (**Heavy Aspire Mesh Graph Rule**). In short: one assembly-scoped `AspireTestHost` graph per mesh run; prove opt-in branches with a cheap topology guard, never a second `DistributedApplicationTestingBuilder` in a test class, and push live-provider behavior to a lighter lane.

## Lazy startup + lifecycle

`AspireTestHost` is **lazy**: it exposes a static `EnsureStartedAsync(TestContext)` guarded by a `SemaphoreSlim`, called from each mesh test class's `[ClassInitialize]`. There is no eager `[AssemblyInitialize]` start - the graph boots on the first mesh class to run. Teardown is owned by `AspireMeshLifecycle.[AssemblyCleanup]`, which stops/disposes the graph exactly once regardless of which class warmed it up. All mesh tests are `[DoNotParallelize]`.

> **Naming:** `AspireTestHost` (not `DatabaseFixture`). The fixture owns the full distributed application - DB + Functions + Table Storage + lifecycle - and the name reflects that. It can stay `internal` (consumed only within `Test.Aspire`).

## Shared Aspire test-host context

Generate one `DockerRuntimePreflight` under `tests/Test.Support/Hosting` and one `AspireTestHostContext` under `tests/Test.Support/Aspire`; mesh, admin/browser, and WasmUI fixtures consume the context instead of copying lifecycle code. Component Testcontainers fixtures may call the same generic Docker preflight without taking an AppHost dependency. Neither helper depends on MSTest. For required mesh infrastructure, thin adapters alone translate an explicit opt-out or the preflight's Docker-unavailable result to `Assert.Inconclusive`. Optional Azure `LiveAI` performs provider eligibility before calling the shared host, as specified below.

Required public surface:

```csharp
public sealed class AspireTestHostContext
{
    public AspireTestHostContext(TimeSpan startupBudget, string resourceLoggingEnvironmentVariable, TimeSpan? cleanupBudget = null);
    public bool ResourceLoggingEnabled { get; }
    public TimeSpan RemainingStartupBudget { get; }
    public Task<string?> GetDockerUnavailableReasonAsync(CancellationToken ct);
    public Task<T> RunStartupStepAsync<T>(string step, Func<CancellationToken, Task<T>> operation, CancellationToken ct);
    public Task RunStartupStepAsync(string step, Func<CancellationToken, Task> operation, CancellationToken ct);
    public void Attach(DistributedApplication app);
    public Task WaitForResourceHealthyAsync(string resourceName, CancellationToken ct);
    public Task DumpResourceDiagnosticsAsync(string resourceName, CancellationToken ct);
    public Task StopAndDisposeAsync(CancellationToken ct);
}
```

Implementation rules:

1. Start a monotonic clock in the constructor. `RunStartupStepAsync` passes a linked token and the **remaining** budget; it never grants a fresh timeout. Relabel cancellation/timeout as global-deadline expiry only when the context's own deadline fired; preserve a shorter step's original timeout and diagnostics.
2. `GetDockerUnavailableReasonAsync` spends the remaining deadline through `DockerRuntimePreflight.GetUnavailableReasonAsync`. That helper runs `docker info` with a short cap, starts `ReadToEndAsync()` for both stdout and stderr before awaiting exit, and kills the process tree on timeout. It returns a precise reason only for a missing/unreachable Docker-compatible runtime.
3. `Attach` records the built `DistributedApplication`. Named waits call `ResourceNotifications.WaitForResourceHealthyAsync` through `RunStartupStepAsync`.
4. Every wait/startup failure prints state, health, exit code, start timestamp, and stop timestamp before rethrowing. Resource logs are additive and opt-in via `{APP}_ASPIRE_RESOURCE_LOGGING=true`; state diagnostics are always on.
5. Cleanup has one separate bounded wall-clock budget across both `StopAsync` and `DisposeAsync`. Restore fixture-owned environment in a caller `finally` even when cleanup fails.
6. Reference proof: `scaffold-proof/tests/Test.Support/Aspire/AspireTestHostContext.cs`. Copy behavior, not TaskFlow names.

---

## AspireTestHost

### File: `tests/Test.Aspire/AspireTestHost.cs`

```csharp
using Aspire.Hosting;
using Aspire.Hosting.Testing;
using AppHost;
using EF.IntegrationTesting.Aspire;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Test.Support.Aspire;
using EnvironmentVariableScope = EF.IntegrationTesting.Environment.EnvironmentVariableScope;
using FunctionsCoreToolsDiscovery = EF.IntegrationTesting.Environment.FunctionsCoreToolsDiscovery;

namespace Test.Aspire;

/// <summary>
/// Lazy assembly-scoped fixture that starts the full Aspire AppHost graph (API, Functions, SQL, Table
/// Storage) the first time a mesh test class calls <see cref="EnsureStartedAsync"/> from
/// <c>[ClassInitialize]</c>. Mesh tier (Aspire.Hosting.Testing) - the only tier that exercises the full
/// service mesh, which no lighter tier reproduces. Teardown runs once via
/// <c>AspireMeshLifecycle.[AssemblyCleanup]</c>. AspireTestHostContext owns the cumulative startup
/// deadline, named waits, diagnostics, and bounded cleanup.
/// </summary>
internal static class AspireTestHost
{
    /// <summary>
    /// Internal diagnostic switch (NOT a test-selection opt-in). Resource logging is off by default to keep
    /// TRX output readable; set <c>{APP}_ASPIRE_RESOURCE_LOGGING=true</c> only while diagnosing a startup or
    /// routing failure. Document it under troubleshooting, never in the normal test opt-in surface.
    /// </summary>
    internal const string ResourceLoggingEnvironmentVariable = "{APP}_ASPIRE_RESOURCE_LOGGING";

    /// <summary>Guards the lazy single-start so concurrent <c>[ClassInitialize]</c> calls boot the graph once.</summary>
    private static readonly SemaphoreSlim Gate = new(1, 1);

    private static EnvironmentVariableScope? _environment;
    private static AspireTestHostContext? _hostContext;
    internal static string ConnectionString = null!;
    internal static TimeSpan DefaultTimeout => _hostContext?.RemainingStartupBudget
        ?? AspireTestHostContext.ReadPositiveSeconds("{APP}_ASPIRE_STARTUP_TIMEOUT_SECONDS", 900);

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

        if (string.Equals(Environment.GetEnvironmentVariable("{APP}_RUN_ASPIRE_TESTS"), "false", StringComparison.OrdinalIgnoreCase))
        {
            Assert.Inconclusive("{APP}_RUN_ASPIRE_TESTS=false - Aspire mesh tier opted out.");
            return;
        }

        await Gate.WaitAsync(context.CancellationToken);
        try
        {
            if (AspireApp is not null)
                return;

            _hostContext = new AspireTestHostContext(
                AspireTestHostContext.ReadPositiveSeconds("{APP}_ASPIRE_STARTUP_TIMEOUT_SECONDS", 900),
                ResourceLoggingEnvironmentVariable);
            var dockerUnavailable = await _hostContext.GetDockerUnavailableReasonAsync(context.CancellationToken);
            if (dockerUnavailable is not null)
            {
                _hostContext = null;
                Assert.Inconclusive(dockerUnavailable);
                return;
            }

            try
            {
                await StartAsync(context.CancellationToken);
            }
            catch
            {
                foreach (var resource in new[] { "{app}db", "{app}migrator", "{app}api", "{app}gateway" })
                    await _hostContext.DumpResourceDiagnosticsAsync(resource, CancellationToken.None);

                try { await StopAsync(CancellationToken.None); }
                catch (Exception cleanupException) { Console.Error.WriteLine($"Cleanup also failed: {cleanupException.Message}"); }
                throw;
            }
        }
        finally
        {
            Gate.Release();
        }
    }

    private static async Task StartAsync(CancellationToken ct)
    {
        var hostContext = _hostContext ?? throw new InvalidOperationException("Aspire host context is not initialized.");
        // AppHost.cs reads these via Environment.GetEnvironmentVariable, so they must be process env vars.
        _environment = new EnvironmentVariableScope()
            .Set("{APP}_ASPIRE_TESTING", "true");

        if (!IsExplicitlyDisabled("{APP}_RUN_FUNCTIONS_TESTS") && EnsureFuncToolAvailable())
            _environment.Set("{APP}_INCLUDE_FUNCTIONS", "true");

        ResourceLoggingEnabled = hostContext.ResourceLoggingEnabled;

        var appHostProgramType = Type.GetType("Program, AppHost", throwOnError: true)!;

        var builder = await hostContext.RunStartupStepAsync(
            "create Aspire mesh test host",
            token => DistributedApplicationTestingBuilder.CreateAsync(
                appHostProgramType,
                args: [],
                configureBuilder: (appOptions, hostSettings) =>
                {
                    appOptions.DisableDashboard = true;
                    appOptions.EnableResourceLogging = ResourceLoggingEnabled;
                    hostSettings.Configuration ??= new();
                    hostSettings.Configuration["Parameters:sql-password"] = LocalSqlSettings.SharedSaPassword;
                },
                cancellationToken: token),
            ct);

        builder.Services.AddLogging(logging =>
        {
            logging.SetMinimumLevel(LogLevel.Information);
            logging.AddFilter("Microsoft.AspNetCore", LogLevel.Warning);
            logging.AddFilter("Aspire.", LogLevel.Warning);
        });

        AspireApp = await hostContext.RunStartupStepAsync("build Aspire mesh test host", token => builder.BuildAsync(token), ct);
        hostContext.Attach(AspireApp);
        await hostContext.RunStartupStepAsync("start Aspire mesh test host", token => AspireApp.StartAsync(token), ct);

        await hostContext.WaitForResourceHealthyAsync("{app}db", ct);

        ConnectionString = await hostContext.RunStartupStepAsync(
            "resolve {app}db connection string",
            token => AspireApp.GetRequiredConnectionStringAsync("{app}db", hostContext.RemainingStartupBudget, token),
            ct);
    }

    /// <summary>Stops and disposes the graph (if started) and restores env vars. Invoked once by AspireMeshLifecycle.</summary>
    internal static async Task StopAsync(CancellationToken ct)
    {
        var hostContext = _hostContext;
        try
        {
            if (hostContext is not null)
                await hostContext.StopAndDisposeAsync(ct);
        }
        finally
        {
            AspireApp = null;
            _hostContext = null;
            _environment?.Dispose();
            _environment = null;
        }
    }

    /// <summary>Waits for a named Aspire resource within the one cumulative startup deadline.</summary>
    internal static Task WaitForResourceHealthyAsync(string resourceName, CancellationToken cancellationToken = default)
    {
        var hostContext = _hostContext ?? throw new InvalidOperationException("Aspire host context is not initialized.");
        return hostContext.WaitForResourceHealthyAsync(resourceName, cancellationToken);
    }

    /// <summary>Checks if Azure Functions Core Tools (func.exe) is available on PATH.</summary>
    internal static bool EnsureFuncToolAvailable() => FunctionsCoreToolsDiscovery.EnsureFuncToolAvailable();

    /// <summary>True only when the named env var is a case-insensitive "true". Used for diagnostic overrides.</summary>
    private static bool IsEnabled(string variableName) =>
        string.Equals(Environment.GetEnvironmentVariable(variableName), "true", StringComparison.OrdinalIgnoreCase);

    private static bool IsExplicitlyDisabled(string variableName)
    {
        var value = Environment.GetEnvironmentVariable(variableName);
        return string.Equals(value, "false", StringComparison.OrdinalIgnoreCase)
            || string.Equals(value, "0", StringComparison.OrdinalIgnoreCase)
            || string.Equals(value, "no", StringComparison.OrdinalIgnoreCase);
    }
}
```

### File: `tests/Test.Aspire/AspireMeshLifecycle.cs`

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

### File: `tests/Test.Aspire/AssemblyInfo.cs`

```csharp
[assembly: DoNotParallelize]
```

### Aspire fixture non-negotiables

1. **One shared app per assembly, lazily started** - boot in `EnsureStartedAsync` (guarded by a `SemaphoreSlim`), called from each mesh class's `[ClassInitialize]`. Never per test method. No eager `[AssemblyInitialize]` start.
2. **`Parameters:*` via `configureBuilder.hostSettings.Configuration`** - not env-var mutation.
3. **Scope env vars** - `{APP}_ASPIRE_TESTING`, `{APP}_INCLUDE_FUNCTIONS` via `EnvironmentVariableScope` (restored on dispose). Do not add an explicitly opted-out Functions/UI resource to the test graph. These choices are read at graph construction and baked into the one shared graph, so they cannot be re-flipped per test. A test that needs a different provider/config builds its own isolated graph (see [ai-integration.md](../skills/ai-integration.md) section Deciding the Live Lane Without Probing the CLI).
4. **One shared `AspireTestHostContext` startup deadline** across Docker preflight, create, build, start, named health waits, endpoint/connection resolution, and any browser launch. Per-step caps may be shorter but never reset the deadline.
5. **`WaitForResourceHealthyAsync(name, ct)` before talking to a resource.** Running != ready.
6. **`[AssemblyCleanup]` lives in `AspireMeshLifecycle`** - call `AspireTestHostContext.StopAndDisposeAsync`; one cleanup deadline covers both stop and dispose, and environment restoration stays in `finally`.
7. **Distinct `Aspire` category** - tag every mesh test `[TestCategory("Aspire")]`, never `Integration`. The component tier owns `Integration`; sharing the category would boot the whole graph on a `--filter TestCategory=Integration` run, defeating the split.
8. **Configurable global startup budget** - `{APP}_ASPIRE_STARTUP_TIMEOUT_SECONDS` defaults to 900 s and is read once when the context starts. Do not re-read it per step.
9. **Default-on, narrow inconclusive boundary for required mesh infrastructure** - honour `{APP}_RUN_ASPIRE_TESTS=false` and failed Docker preflight with precise `Assert.Inconclusive` messages. Docker success means AppHost/container/create/build/start/readiness failures are red after state diagnostics. Fast CI lanes set the explicit opt-out when they intentionally exclude the tier. Optional Azure `LiveAI` uses the pre-host eligibility exception owned by [../skills/ai-integration.md](../skills/ai-integration.md).
10. **Test containers are ephemeral; the SDK owns teardown.** The AppHost gates `ContainerLifetime.Persistent` + `WithDataVolume` on `!IsAspireTesting()` (see [../skills/aspire.md](../skills/aspire.md), Rules), so the graph this fixture boots uses **ephemeral** containers. `AspireApp.StopAsync()`/`DisposeAsync()` in `AspireTestHost.StopAsync` removes **exactly** the containers this run started. **Never** add a `docker rm` sweep filtered by image, name prefix, or the generic `com.microsoft.dotnet.aspire.container.name` label - that deletes other projects' and sessions' containers, including intentional persistent stacks. The mesh tier needs no Docker cleanup beyond `DisposeAsync`.

When Functions is in the graph, its project must override the Functions SDK's relative `RunWorkingDirectory` with an absolute path per [../skills/function-app.md](../skills/function-app.md) section Make the local Functions run directory absolute. Do not call `WithWorkingDirectory(...)` on `AzureFunctionsProjectResource`; that extension only supports executable resources. A Running resource whose proxy returns 500 because Core Tools never bound its port is a host startup failure, not an inconclusive prerequisite gap.

### State diagnostics on by default; resource logs optional

State comes from notifications on every failure; raw logs remain an additive diagnostic override.

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

The shared context calls both from startup and named-wait failure paths before rethrowing. `ResourceLoggerService` lives in `Aspire.Hosting.ApplicationModel`.

### Cleanup: ephemeral-by-default, per-run label only as a fallback

The default needs no Docker commands at all - ephemeral test containers are torn down by `DisposeAsync` (non-negotiable 10). Only if a project **must** keep persistent lifetime under test (rare - e.g. a slow Cosmos preview emulator it reuses across runs) do you add explicit cleanup, and it must be scoped to this run's exact ownership, never a generic sweep:

1. Generate one run id in the test host.
2. Pass it to the AppHost through `hostSettings.Configuration` (the same channel as `Parameters:sql-password` in `StartAsync`), e.g. `hostSettings.Configuration["Parameters:test-run-id"] = runId;`.
3. In the AppHost, under `IsAspireTesting()`, stamp each test-owned container: `c.WithContainerRuntimeArgs("--label", $"{app}.aspire.test-run-id={runId}")`.
4. In `AspireMeshLifecycle.[AssemblyCleanup]`, **after** `StopAsync`/`DisposeAsync`, remove only the matching run: `docker ps -aq --filter "label={app}.aspire.test-run-id=<runId>"` -> `docker rm -f`.

Do **not** sweep old stopped containers unless the developer explicitly asks for machine-level Docker cleanup. Removing by exact run id leaves other projects, prior sessions, and intentional persistent containers untouched.

### Required-mesh opt-out + Docker preflight

The required mesh tier is default-on so Test Explorer discovers it. Only explicit opt-out and a failed Docker-compatible runtime preflight are inconclusive for required mesh infrastructure. Put translation in the thin MSTest adapter; `AspireTestHostContext` returns the Docker reason and never depends on MSTest:

```csharp
[ClassInitialize]
public static async Task ClassInit(TestContext context)
{
    if (string.Equals(Environment.GetEnvironmentVariable("{APP}_RUN_ASPIRE_TESTS"), "false", StringComparison.OrdinalIgnoreCase))
    {
        Assert.Inconclusive("{APP}_RUN_ASPIRE_TESTS=false - mesh tier opted out.");
        return;
    }

    await AspireTestHost.EnsureStartedAsync(context);
}
```

`AspireTestHost.EnsureStartedAsync` performs the shared Docker preflight and marks it inconclusive when unavailable. It never catches AppHost startup/readiness failures as availability; those dump diagnostics and propagate red.

### Optional Azure LiveAI eligibility before host creation

When AI is generated, the Azure `LiveAI` class must check provider eligibility before it can call `AspireTestHost.EnsureStartedAsync`. `{APP}_RUN_AZURE_FOUNDRY_TESTS=false` is a fast opt-out, not a required flag when Azure configuration is absent.

```csharp
[ClassInitialize]
public static async Task ClassInit(TestContext context)
{
    if (string.Equals(
        Environment.GetEnvironmentVariable("{APP}_RUN_AZURE_FOUNDRY_TESTS"),
        "false",
        StringComparison.OrdinalIgnoreCase))
    {
        Assert.Inconclusive("{APP}_RUN_AZURE_FOUNDRY_TESTS=false - Azure live AI opted out.");
        return;
    }

    var unavailable = AzureFoundryTestEligibility.GetUnavailableReason();
    if (unavailable is not null)
    {
        Assert.Inconclusive(unavailable);
        return;
    }

    await AspireTestHost.EnsureStartedAsync(context);
}
```

Generate `AzureFoundryTestEligibility` as a thin, process-only preflight. It loads the same environment/user-secret inputs the AppHost consumes and calls the same pure Azure-selection predicate. If selection is currently inline in AppHost `Program.cs`, extract one pure predicate and reuse it; do not duplicate a second heuristic in tests. The preflight must not create `DistributedApplicationTestingBuilder`, call `EnsureStartedAsync`, query `/api/v1/ai/status`, authenticate, or call a model. Missing selection inputs return a precise unavailable reason. Once eligible, startup/authentication/provider/status/routing/HTTP/JSON/schema/contract failures stay red. Full classification: [../skills/ai-integration.md](../skills/ai-integration.md) section Optional Live-Provider Classification.

---

## API Audit Pipeline Test

End-to-end: `POST /api/{entities}` -> API request handling -> audit middleware -> Azurite Table Storage, with polling read-back. Two Aspire resources participate (`{app}api`, `TableStorage1`); both must be Healthy.

### File: `tests/Test.Aspire/ApiAuditPipelineTests.cs`

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
///   dotnet test tests/Test.Aspire/Test.Aspire.csproj --filter TestCategory=Aspire -m:1
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
    [Timeout(1_200_000, CooperativeCancellation = true)]
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

Aspire's emulators (Service Bus, Azurite) are best-effort under `DistributedApplicationTestingBuilder`. Asserting "audit row exists in Azurite for this request" exercises the same path production runs through, and it survives the small lag between HTTP 201 and the background `AuditHandler` flushing. **Assert against the persistent downstream effect (the audit row, the projection document), not against the bus/queue.** If that effect is outside the selected test scope, do not generate the test; an enabled mesh test must not hide the missing dependency with `[Ignore]`.

---

## Other mesh tests (generate when the host is enabled)

- **`FunctionAuditPipelineTests`** (`includeFunctions`): same shape against the `{app}functions` resource. An explicit `{APP}_RUN_FUNCTIONS_TESTS=false` opts out before graph construction. Otherwise `AspireTestHost.EnsureFuncToolAvailable()` must fail red with the install step when `func` is absent. Functions has the longest cold-start; its coarse MSTest `[Timeout]` must exceed the configurable global startup budget plus assertion time (for a 900 s startup default, use at least 1200 s).
- **Blazor-mesh smoke** (`includeBlazorUI`): `tests/Test.Aspire/BlazorMeshSmokeTests`. Opt the Blazor resource into the graph via `{APP}_INCLUDE_BLAZOR=true` and hit one page that round-trips through the API (Gateway routing + Refit + tenant header). Calls `AspireTestHost.EnsureStartedAsync` from `[ClassInitialize]`.
- **Service Bus -> Function -> projection**: assert on the projection store's downstream document, never the topic/queue.

---

## Project file

### File: `tests/Test.Aspire/Test.Aspire.csproj`

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
    <ProjectReference Include="..\..\src\Host\{Host}.Api\{Host}.Api.csproj" />
    <ProjectReference Include="..\..\src\Application\{Project}.Application.Models\{Project}.Application.Models.csproj" />
    <ProjectReference Include="..\..\src\Infrastructure\{Project}.Infrastructure.Storage\{Project}.Infrastructure.Storage.csproj" />
    <ProjectReference Include="..\..\src\Host\Aspire\AppHost\AppHost.csproj" AdditionalProperties="SkipUnoWasmBuild=true" />
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
- [ ] Mesh and Playwright/WasmUI adapters use one shared `AspireTestHostContext`; no fixture duplicates Docker probing, deadlines, state dumps, or cleanup.
- [ ] One startup context begins before Docker/test-owned restore and bounds create, build, start, named waits, endpoint resolution, warm-up, and browser launch by remaining time.
- [ ] `Parameters:*` passed via `configureBuilder.hostSettings.Configuration`; env vars scoped + restored.
- [ ] Multi-resource pipeline tests assert against the **downstream persistent effect** (audit row, projection document), not the bus/queue.
- [ ] Every mesh test carries `[TestCategory("Aspire")]` (not `Integration`); `--filter TestCategory=Integration` boots **no** graph.
- [ ] `{APP}_ASPIRE_STARTUP_TIMEOUT_SECONDS` is read once as a global budget (default 900 s); subordinate per-step caps cannot extend it.
- [ ] Required mesh infrastructure is inconclusive only for `{APP}_RUN_ASPIRE_TESTS=false` or failed Docker preflight; AppHost/container/start/readiness failures dump diagnostics and fail.
- [ ] Azure `LiveAI` checks the app's shared provider-selection predicate before `AspireTestHost.EnsureStartedAsync`; missing optional Azure configuration is inconclusive without booting the graph, while eligible-provider failures stay red per `skills/ai-integration.md`.
- [ ] Docker preflight begins concurrent stdout/stderr drains before waiting for `docker info` and kills the process tree on timeout.
- [ ] Failure output includes resource state, health, exit code, and start/stop timestamps by default; resource logs are optional.
- [ ] Cleanup uses one bounded deadline across stop and dispose; fixture-owned environment is restored in `finally`.
- [ ] Test-booted containers are **ephemeral** (AppHost gates persistent lifetime + data volume on `!IsAspireTesting()`); cleanup is `DisposeAsync` only - no `docker rm` sweep by image, name prefix, or the generic `com.microsoft.dotnet.aspire.container.name` label.
- [ ] Running `Test.Aspire` boots the graph **once**; running `Test.Integration` boots **no** graph.
- [ ] `EnableResourceLogging` defaults to **false**; the `{APP}_ASPIRE_RESOURCE_LOGGING=true` override re-enables it. Failure diagnostics read `ResourceNotifications` state; `DumpResourceLogsAsync` resolves `ResourceLoggerService` with `GetService` and no-ops (never throws) when logging is off.

---

**TaskFlow proof (local):**
- `../scaffold-proof/tests/Test.Aspire/AspireTestHost.cs`
- `../scaffold-proof/tests/Test.Aspire/AspireMeshLifecycle.cs`
- `../scaffold-proof/tests/Test.Aspire/ApiAuditPipelineTests.cs`
- `../scaffold-proof/tests/Test.Aspire/FunctionAuditPipelineTests.cs`

**TaskFlow proof (remote fallback):**
<https://github.com/efreeman518/scaffold-proof/tree/main/tests/Test.Aspire>
