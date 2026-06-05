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
    /// <summary>Per-call deadline applied via <c>.WaitAsync(DefaultTimeout, ct)</c>. Sized for slow CI cold-starts.</summary>
    internal static readonly TimeSpan DefaultTimeout = TimeSpan.FromMinutes(5);

    /// <summary>Cleanup deadline. StopAsync should return promptly; the bound prevents a stuck shutdown.</summary>
    private static readonly TimeSpan CleanupTimeout = TimeSpan.FromMinutes(1);

    /// <summary>Guards the lazy single-start so concurrent <c>[ClassInitialize]</c> calls boot the graph once.</summary>
    private static readonly SemaphoreSlim Gate = new(1, 1);

    private static EnvironmentVariableScope? _environment;
    internal static string ConnectionString = null!;

    /// <summary>Shared Aspire app started once for all mesh tests.</summary>
    internal static DistributedApplication? AspireApp { get; private set; }

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

        var appHostProgramType = Type.GetType("Program, AppHost", throwOnError: true)!;

        var builder = await DistributedApplicationTestingBuilder.CreateAsync(
            appHostProgramType,
            args: [],
            configureBuilder: (appOptions, hostSettings) =>
            {
                appOptions.DisableDashboard = true; // explicit > implicit default
                appOptions.EnableResourceLogging = true;

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
3. **Scope env vars** - `{APP}_ASPIRE_TESTING`, `{APP}_INCLUDE_FUNCTIONS` via `EnvironmentVariableScope` (restored on dispose).
4. **Per-call `.WaitAsync(DefaultTimeout, ct)`** on every async Aspire call. Not a single umbrella CTS.
5. **`WaitForResourceHealthyAsync(name, ct)` before talking to a resource.** Running != ready.
6. **`[AssemblyCleanup]` lives in `AspireMeshLifecycle`** - bound `StopAsync` with `.WaitAsync(CleanupTimeout)` and catch `TimeoutException` so a stuck teardown does not hang CI.

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
/// </summary>
[TestClass]
[TestCategory("Integration")]
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
    <ProjectReference Include="..\..\Host\Aspire\AppHost\AppHost.csproj" />
  </ItemGroup>
</Project>
```

---

## Verification

- [ ] `Test.Aspire` references `AppHost` and `Aspire.Hosting.Testing`; it is registered in the solution.
- [ ] `AspireTestHost` is lazy (`EnsureStartedAsync` + `SemaphoreSlim`); no eager `[AssemblyInitialize]` start.
- [ ] `AspireMeshLifecycle.[AssemblyCleanup]` stops/disposes the graph once; bounded by `CleanupTimeout`.
- [ ] Every mesh test class calls `AspireTestHost.EnsureStartedAsync` from `[ClassInitialize]` and is `[DoNotParallelize]`.
- [ ] Every async Aspire call has its own `.WaitAsync(DefaultTimeout, ct)`; tests gate on `WaitForResourceHealthyAsync`.
- [ ] `Parameters:*` passed via `configureBuilder.hostSettings.Configuration`; env vars scoped + restored.
- [ ] Multi-resource pipeline tests assert against the **downstream persistent effect** (audit row, projection document), not the bus/queue.
- [ ] Running `Test.Aspire` boots the graph **once**; running `Test.Integration` boots **no** graph.

---

**TaskFlow proof (local):**
- `../AI-Instructions-ReferenceApp/src/Test/Test.Aspire/AspireTestHost.cs`
- `../AI-Instructions-ReferenceApp/src/Test/Test.Aspire/AspireMeshLifecycle.cs`
- `../AI-Instructions-ReferenceApp/src/Test/Test.Aspire/ApiAuditPipelineTests.cs`
- `../AI-Instructions-ReferenceApp/src/Test/Test.Aspire/FunctionAuditPipelineTests.cs`

**TaskFlow proof (remote fallback):**
<https://github.com/efreeman518/AI-Instructions-ReferenceApp/tree/main/src/Test/Test.Aspire>
