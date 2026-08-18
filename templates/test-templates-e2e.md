# Test Templates - E2E Workflow (Phase 5b, tests-after)

| | |
|---|---|
| **Generates** | `tests/Test.Support/Hosting/DockerRuntimePreflight.cs` (shared with other container tiers), `tests/Test.E2E/SqlApiFactory.cs`, `tests/Test.E2E/{Entity}WorkflowTests.cs` |
| **Requires** | [test-templates-endpoint](test-templates-endpoint.md) (for the shared `WebApplicationFactoryBase`), real SQL via Testcontainers |
| **Phase** | Generated in Phase 4 (factory shell) and filled in during Phase 5b once services + endpoints are green |
| **Protocol** | Tests-after. Unit + Endpoint tests in `Test.Endpoints` already pin per-endpoint behavior; E2E validates multi-endpoint **workflows** against real SQL - paging plans, FK constraints, projection translation, owned-type round-trip, and child-aggregate lifecycles. |

## Why E2E exists separately

| Tier | Backing store | What only this tier catches |
|---|---|---|
| `Test.Endpoints` (InMemory) | EF InMemory provider | Per-endpoint contract: status code, response shape, validation. **Misses:** projection plans, shadow properties, FK constraints, owned-type column flattening, raw SQL paging behavior. |
| `Test.E2E` (Testcontainers SQL) | Real SQL Server | Multi-endpoint workflows (create -> search -> update -> delete), paginated search across distinct pages, projection round-trip, child-aggregate FK behavior. |
| `Test.Aspire` (mesh) | Full distributed app | Cross-process: API -> Service Bus -> Function -> projection store -> audit row. See [test-templates-aspire.md](test-templates-aspire.md). |
| `Test.Integration` (component) | One real store | One class vs one Testcontainer: repo vs SQL, audit repo vs Azurite, projection vs SQL. See [test-templates-integration.md](test-templates-integration.md). |

Rule of thumb: if the workflow spans **two or more endpoints** and the assertion depends on **real EF translation** (paging, projection, owned types, FK behavior), it belongs in `Test.E2E`. Single-endpoint contract checks belong in `Test.Endpoints`.

---

## SqlApiFactory

### File: `tests/Test.E2E/SqlApiFactory.cs`

```csharp
using Microsoft.EntityFrameworkCore;
using {Project}.Infrastructure.Data;
using Test.Support;
using Test.Support.Hosting;
using Testcontainers.MsSql;

namespace Test.E2E;

/// <summary>
/// Real-SQL-Server WebApplicationFactory backed by Testcontainers.
/// Exercises the full stack: HTTP -> Endpoint -> Service -> EF -> SQL.
///
/// Used for multi-endpoint workflow E2E tests where contract-only endpoint coverage
/// (Test.Endpoints' in-memory factory) is insufficient - e.g., tests that span
/// create -> search -> update -> delete and need real SQL behavior (concurrency, projection plans,
/// FK constraints).
/// </summary>
public sealed class SqlApiFactory : WebApplicationFactoryBase<Program, {App}DbContextTrxn, {App}DbContextQuery>
{
    private static MsSqlContainer _container = null!;
    private static string _connectionString = null!;
    private static bool _started;

    /// <summary>Startup failure captured by <see cref="StartContainerAsync"/>; null when the container started cleanly.</summary>
    public static Exception? StartupError { get; private set; }
    public static string? DockerUnavailableReason { get; private set; }

    public static async Task StartContainerAsync(CancellationToken cancellationToken)
    {
        if (_started || DockerUnavailableReason is not null || StartupError is not null) return;

        DockerUnavailableReason = await DockerRuntimePreflight.GetUnavailableReasonAsync(
            TimeSpan.FromSeconds(10),
            cancellationToken);
        if (DockerUnavailableReason is not null) return;

        try
        {
            _container = new MsSqlBuilder("mcr.microsoft.com/mssql/server:2025-latest").Build();
            await _container.StartAsync();
            _connectionString = _container.GetConnectionString();
            _started = true;
        }
        catch (Exception ex)
        {
            StartupError = ex;
        }
    }

    public static async Task StopContainerAsync()
    {
        if (!_started) return;
        await _container.DisposeAsync();
        _started = false;
    }

    protected override DbContextOptions BuildTrxnOptions() =>
        new DbContextOptionsBuilder<{App}DbContextTrxn>()
            .UseSqlServer(_connectionString, sql => sql.UseCompatibilityLevel(170))
            .Options;

    protected override DbContextOptions BuildQueryOptions() =>
        new DbContextOptionsBuilder<{App}DbContextQuery>()
            .UseSqlServer(_connectionString, sql => sql.UseCompatibilityLevel(170))
            .Options;
}
```

### Static container lifecycle

- `StartContainerAsync` is idempotent and **static** so multiple test classes can share the container without reference counting.
- `_started` flag prevents redundant starts when the runner instantiates the factory more than once.
- Pin the image tag (`mcr.microsoft.com/mssql/server:2025-latest`) - a `latest` rolling pull breaks CI on image rev.
- Container lifecycle is owned by the **test class**, not the factory instance - see `[ClassInitialize]` below.

---

## File: `tests/Test.E2E/{Entity}WorkflowTests.cs`

```csharp
using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;
using EF.Common.Contracts;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using {Project}.Application.Models;
using {Project}.Domain.Shared.Enums;

namespace Test.E2E;

/// <summary>
/// Multi-endpoint workflow tests over the full HTTP->Endpoint->Service->EF->SQL stack: {Entity}
/// CRUD round-trips, server-side paged search across distinct pages, and child-aggregate
/// ({ChildEntity}) lifecycles.
/// SQL tier (WebApplicationFactory + Testcontainers SQL via SqlApiFactory): real SQL is required
/// for paging plans, FK constraints applied by EF migrations, and projection behavior - InMemory
/// (Test.Endpoints tier) would silently mask these. The Aspire tier is unnecessary because only
/// one backing service (SQL) participates.
/// </summary>
[TestClass]
[TestCategory("E2E")]
public class {Entity}WorkflowTests
{
    private static SqlApiFactory _factory = null!;
    private static readonly JsonSerializerOptions _json = new()
    {
        PropertyNameCaseInsensitive = true,
        Converters = { new JsonStringEnumConverter() }
    };

    [ClassInitialize]
    public static async Task ClassInit(TestContext _)
    {
        await SqlApiFactory.StartContainerAsync(_.CancellationToken);
        if (SqlApiFactory.DockerUnavailableReason is not null || SqlApiFactory.StartupError is not null)
            return;

        _factory = new SqlApiFactory();

        // Apply EF migrations against the real SQL container
        using var scope = _factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<{App}DbContextTrxn>();
        await db.Database.MigrateAsync();
    }

    /// <summary>Classifies Docker unavailability separately from a SQL startup failure.</summary>
    [TestInitialize]
    public void TestSetup()
    {
        if (SqlApiFactory.DockerUnavailableReason is not null)
        {
            Assert.Inconclusive(SqlApiFactory.DockerUnavailableReason);
            return;
        }

        if (SqlApiFactory.StartupError is not null)
            Assert.Fail($"SQL container startup failed after Docker preflight succeeded:{Environment.NewLine}{SqlApiFactory.StartupError}");
    }

    [ClassCleanup]
    public static async Task ClassCleanup()
    {
        _factory?.Dispose();
        await SqlApiFactory.StopContainerAsync();
    }

    private HttpClient CreateClient() => _factory.CreateClient();

    // -- Full CRUD round-trip ----------------------------------

    [TestMethod]
    public async Task {Entity}_FullCrudCycle_AgainstRealSql()
    {
        using var client = CreateClient();

        // CREATE
        var dto = new {Entity}Dto { Name = "E2E {Entity}", /* ... */ };
        var createResp = await client.PostAsJsonAsync("/api/{entities}",
            new DefaultRequest<{Entity}Dto> { Item = dto });
        Assert.AreEqual(HttpStatusCode.Created, createResp.StatusCode,
            $"Create failed: {await createResp.Content.ReadAsStringAsync()}");
        var created = (await createResp.Content.ReadFromJsonAsync<DefaultResponse<{Entity}Dto>>(_json))!.Item;
        Assert.IsNotNull(created);
        var id = created.Id!.Value;

        // READ
        var getResp = await client.GetAsync($"/api/{entities}/{id}");
        Assert.AreEqual(HttpStatusCode.OK, getResp.StatusCode);
        var fetched = (await getResp.Content.ReadFromJsonAsync<DefaultResponse<{Entity}Dto>>(_json))!.Item;
        Assert.AreEqual("E2E {Entity}", fetched!.Name);

        // UPDATE
        var updateDto = new {Entity}Dto { Id = id, Name = "E2E {Entity} Updated", /* ... */ };
        var putResp = await client.PutAsJsonAsync($"/api/{entities}/{id}",
            new DefaultRequest<{Entity}Dto> { Item = updateDto });
        Assert.AreEqual(HttpStatusCode.OK, putResp.StatusCode,
            $"Update failed: {await putResp.Content.ReadAsStringAsync()}");

        // DELETE
        var delResp = await client.DeleteAsync($"/api/{entities}/{id}");
        Assert.AreEqual(HttpStatusCode.NoContent, delResp.StatusCode);

        // VERIFY DELETED
        var verifyResp = await client.GetAsync($"/api/{entities}/{id}");
        Assert.AreEqual(HttpStatusCode.NotFound, verifyResp.StatusCode);
    }

    // -- Search round-trip -------------------------------------

    [TestMethod]
    public async Task {Entity}_Search_ReturnsResults_AgainstRealSql()
    {
        using var client = CreateClient();

        var marker = $"Searchable E2E {Guid.NewGuid():N}";
        await client.PostAsJsonAsync("/api/{entities}",
            new DefaultRequest<{Entity}Dto> { Item = new {Entity}Dto { Name = $"{marker} Item" } });

        var searchReq = new SearchRequest<{Entity}SearchFilter>
        {
            PageIndex = 1,
            PageSize = 50,
            Filter = new {Entity}SearchFilter { SearchTerm = marker }
        };
        var searchResp = await client.PostAsJsonAsync("/api/{entities}/search", searchReq);
        Assert.AreEqual(HttpStatusCode.OK, searchResp.StatusCode);

        using var document = await JsonDocument.ParseAsync(await searchResp.Content.ReadAsStreamAsync());
        var root = document.RootElement;
        var total = root.GetProperty("total").GetInt32();
        Assert.IsGreaterThanOrEqualTo(total, 1, $"Expected at least 1 result, got {total}");
    }

    // -- Distinct-page pagination (critical: catches PageIndex 0/1 off-by-one bugs) --

    [TestMethod]
    public async Task {Entity}_Search_PaginatesDistinctPages_AgainstRealSql()
    {
        using var client = CreateClient();

        var marker = $"Paged Search E2E {Guid.NewGuid():N}";
        foreach (var suffix in new[] { "01", "02" })
        {
            var dto = new {Entity}Dto { Name = $"{marker} {suffix}" };
            var resp = await client.PostAsJsonAsync("/api/{entities}",
                new DefaultRequest<{Entity}Dto> { Item = dto });
            Assert.AreEqual(HttpStatusCode.Created, resp.StatusCode,
                $"Seed create failed: {await resp.Content.ReadAsStringAsync()}");
        }

        async Task<(int Total, List<string> Names)> SearchPageAsync(int pageIndex)
        {
            var request = new SearchRequest<{Entity}SearchFilter>
            {
                PageIndex = pageIndex,
                PageSize = 1,
                Filter = new {Entity}SearchFilter { SearchTerm = marker }
            };
            var response = await client.PostAsJsonAsync("/api/{entities}/search", request);
            Assert.AreEqual(HttpStatusCode.OK, response.StatusCode);

            using var document = await JsonDocument.ParseAsync(await response.Content.ReadAsStreamAsync());
            var root = document.RootElement;
            var total = root.GetProperty("total").GetInt32();
            var names = root.GetProperty("data")
                .EnumerateArray()
                .Select(item => item.GetProperty("name").GetString())
                .Where(n => !string.IsNullOrWhiteSpace(n))
                .Cast<string>()
                .ToList();
            return (total, names);
        }

        var firstPage = await SearchPageAsync(1);
        var secondPage = await SearchPageAsync(2);

        Assert.AreEqual(2, firstPage.Total);
        Assert.AreEqual(2, secondPage.Total);
        Assert.HasCount(1, firstPage.Names);
        Assert.HasCount(1, secondPage.Names);
        CollectionAssert.AreEquivalent(
            new[] { $"{marker} 01", $"{marker} 02" },
            new[] { firstPage.Names[0], secondPage.Names[0] });
    }

    // -- Child aggregate lifecycle (generate only when entity has children) ----------

    [TestMethod]
    public async Task {ChildEntity}_CrudCycle_AgainstRealSql()
    {
        using var client = CreateClient();

        // Create parent
        var parentResp = await client.PostAsJsonAsync("/api/{entities}",
            new DefaultRequest<{Entity}Dto> { Item = new {Entity}Dto { Name = "Parent for {ChildEntity}" } });
        var parentId = (await parentResp.Content.ReadFromJsonAsync<DefaultResponse<{Entity}Dto>>(_json))!.Item!.Id!.Value;

        // Create child
        var childDto = new {ChildEntity}Dto { /* ... */ {Entity}Id = parentId };
        var createResp = await client.PostAsJsonAsync("/api/{child-entities}",
            new DefaultRequest<{ChildEntity}Dto> { Item = childDto });
        Assert.AreEqual(HttpStatusCode.Created, createResp.StatusCode);
        var created = (await createResp.Content.ReadFromJsonAsync<DefaultResponse<{ChildEntity}Dto>>(_json))!.Item;

        // Delete child
        var delResp = await client.DeleteAsync($"/api/{child-entities}/{created!.Id}");
        Assert.AreEqual(HttpStatusCode.NoContent, delResp.StatusCode);
    }
}
```

---

## E2E test coverage matrix

| Scenario | Generate when |
|---|---|
| `{PrimaryWorkflow}_EndToEnd_AgainstRealSql` | **Always - at least one.** The app's primary domain journey: the multi-step business workflow that strings several endpoints together (create parent -> add children/state transitions -> the action the app exists to perform -> verify outcome), not isolated CRUD. This is the one test that proves the app actually does its job. See section Primary domain-journey E2E. |
| `{Entity}_FullCrudCycle_AgainstRealSql` | Every entity exposed via API endpoints. |
| `{Entity}_Search_ReturnsResults_AgainstRealSql` | Every entity with a search endpoint. |
| `{Entity}_Search_PaginatesDistinctPages_AgainstRealSql` | Every search endpoint - the cheapest catch for `PageIndex` off-by-one bugs and projection drift across pages. |
| `{ChildEntity}_CrudCycle_AgainstRealSql` | Entity has child collections exposed via dedicated endpoints. |
| `{Entity}_ConcurrentUpdates_OptimisticConcurrencyEnforced` | High-contention domains (inventory, reservations, balances). Optional. |

---

## Primary domain-journey E2E

Rich CRUD/health smoke proves the plumbing; it does not prove the app does its job. Generate at least
one journey test that walks the primary business workflow end to end through the real API/gateway against
real SQL - the path a real user takes from nothing to the outcome the app exists to produce.

Shape (one class, sequential steps, real SQL):

```csharp
[TestMethod]
public async Task {PrimaryWorkflow}_EndToEnd_AgainstRealSql()
{
    var client = SqlApiFactory.CreateClient();

    // 1. Create the parent aggregate via the same endpoint the UI calls.
    var parent = await CreateAsync(client, NewParentDto());
    // 2. Drive the business steps that make this app what it is (children, state transitions, the action).
    await AddChildAsync(client, parent.Id, NewChildDto());
    await TransitionAsync(client, parent.Id, "{NextState}");
    // 3. Assert the OUTCOME, not just 200s - the projected/derived state the workflow is supposed to yield.
    var result = await GetAsync(client, parent.Id);
    Assert.AreEqual("{ExpectedOutcome}", result.Status);
}
```

Rules:
- Drive **writes through the API/gateway**, not the browser - see [ui-blazor-forms.md](../skills/ui-blazor-forms.md) and the *Prefer the API/gateway path for write assertions* note below.
- If the workflow invokes an AI agent, run it deterministically via the scripted-agent switch so the journey is offline and repeatable - see [ai-integration.md](../skills/ai-integration.md) section Deterministic agents for tests.
- Seed through the API when it can create the rows the test acts on (reference pattern). When it cannot (user/tenant FK chain), use the shared `SqlAggregateSeeder` ([test-templates-endpoint.md](test-templates-endpoint.md) section SqlAggregateSeeder) - never inline per-test inserts.

---

## Critical patterns

### Apply migrations once per class init
Migrations are applied in `[ClassInitialize]` against the live container. If the test class uses `SqlApiFactory` without applying migrations, the InMemory-style behavior won't surface and the FK / projection drift the tier is meant to catch goes uncaught.

### JSON serializer must accept named enums
The API host emits string enums via `ConfigureHttpJsonOptions`. Without `JsonStringEnumConverter`, the deserializer throws on `"status": "InProgress"`. Either share `JsonTestOptions.Default` from `Test.Support` (preferred - see [test-templates-endpoint.md](test-templates-endpoint.md) section Shared JSON Options) or instantiate a local `_json` field as shown above.

### `DefaultRequest<T>` / `DefaultResponse<T>` wrappers
Every endpoint contract uses `DefaultRequest<T>` for body and `DefaultResponse<T>` for response. Tests must follow the same shape - `new DefaultRequest<{Entity}Dto> { Item = dto }` on POST/PUT, `ReadFromJsonAsync<DefaultResponse<{Entity}Dto>>` on GET/POST/PUT. Direct DTO POSTs will fail validation.

### Missing Docker degrades to Inconclusive; container startup stays red
`StartContainerAsync` runs the shared bounded `DockerRuntimePreflight` before creating the SQL container. `[ClassInitialize]` returns early when preflight or startup failed so discovery continues. Every test's `[TestInitialize]` marks only `DockerUnavailableReason` inconclusive; a captured `StartupError` after successful preflight fails with the full exception. This matches `Test.Integration` and Aspire-backed tiers without turning an image, port, configuration, or health failure into an environment skip.

### Static container ownership
The container is started and disposed via the **first and last** test class. With multiple workflow test classes, both call `SqlApiFactory.StartContainerAsync()`; the second call is a cheap idempotent return because `_started` is set. This is intentional - DO NOT add reference counting or "is anyone still using it" logic; the static `_started` flag is sufficient.

### Prefer the API/gateway path for write assertions
Assert writes by calling the API/gateway directly (the `SqlApiFactory` client), not by driving the
Blazor UI. A browser-driven write adds two failure modes unrelated to the behavior under test: a MudBlazor
dialog + Refit `AddStandardResilienceHandler` can return 400 before the request leaves the client (the
same payload sent direct-to-gateway succeeds), and `@bind-Value` commits on blur so a programmatic fill
can submit stale/empty values (see [troubleshooting.md](../support/troubleshooting.md) and
[ui-blazor-forms.md](../skills/ui-blazor-forms.md)). Reserve browser-driven steps for render and
interaction checks; prove create/update/delete through the API.

---

## Verification

- [ ] `Test.E2E` references `Microsoft.AspNetCore.Mvc.Testing` + `Testcontainers.MsSql`.
- [ ] `SqlApiFactory` derives from `WebApplicationFactoryBase<Program, {App}DbContextTrxn, {App}DbContextQuery>` - does **not** reimplement the swap-out logic.
- [ ] `SqlApiFactory.StartContainerAsync` is idempotent, runs bounded Docker preflight once, and captures post-preflight `StartupError` without aborting discovery.
- [ ] Every workflow class marks only `DockerUnavailableReason` inconclusive and fails a captured `StartupError` with the full exception.
- [ ] Every workflow class applies migrations in `[ClassInitialize]` (skipped via early return when preflight or startup failed).
- [ ] Every test in `Test.E2E` carries `[TestCategory("E2E")]`.
- [ ] JSON deserialization uses a configured `JsonSerializerOptions` (named-enum tolerant + case-insensitive).
- [ ] Distinct-page pagination test exists for every searchable entity.
- [ ] Class-level `<summary>` declares the SQL tier and why a lighter / heavier tier is wrong for this scope.
- [ ] No `Test.E2E` test asserts on seeded counts that depend on shared state - each test seeds its own marker.

---

**TaskFlow proof (local):**
- `../scaffold-proof/tests/Test.E2E/SqlApiFactory.cs`
- `../scaffold-proof/tests/Test.E2E/TaskItemCrudE2ETests.cs`

**TaskFlow proof (remote fallback):**
<https://github.com/efreeman518/scaffold-proof/tree/main/tests/Test.E2E>
