# Test Templates - Endpoint (Phase 5b)

| | |
|---|---|
| **Generates** | `tests/Test.Endpoints/Endpoints/{Entity}EndpointsTests.cs` |
| **Requires** | [endpoint-template](endpoint-template.md), CustomApiFactory from Phase 4, DTOs from Phase 4 |
| **Phase** | 5b (App Core TDD) |
| **Protocol** | Write these tests BEFORE implementing endpoints. See [../ai/tdd-protocol.md](../ai/tdd-protocol.md). |

## BDD Naming Convention

All test methods use `Given_When_Then`:
```csharp
[TestMethod]
public async Task Given_ValidPayload_When_PostEntity_Then_Returns201() { }
```

---

## Shared JSON Options (Required)

Every `ReadFromJsonAsync<T>` / `PostAsJsonAsync<T>` call must pass `JsonTestOptions.Default` from `Test.Support`. Without it, responses carrying string enums (`"status": "InProgress"`) fail to deserialize against the default `JsonSerializerOptions` and tests pass-then-fail based on whether the API host happened to emit a numeric or named enum. The shared options align the test deserializer with the host's `ConfigureHttpJsonOptions` (see [../skills/api.md](../skills/api.md) section JSON Contract Across Hosts and Tests).

```csharp
// Required at the top of every endpoint test file
using static {Project}.Test.Support.JsonTestOptions;

var dto = await response.Content.ReadFromJsonAsync<DefaultResponse<{Entity}Dto>>(Default);
await client.PostAsJsonAsync("/api/{entities}", request, Default);
```

If the test base evolves to wrap `HttpClient` in an extension method (e.g. `client.GetJsonAsync<T>("/api/...")`), the extension must close over `JsonTestOptions.Default` internally so no individual test forgets the converter set.

---

## Shared WebApplicationFactoryBase (in Test.Support)

The plumbing for swapping the production DbContext + interceptors + pooled factories with a test-mode store ships in the `EF.IntegrationTesting` package as `EF.IntegrationTesting.AspNetCore.EfWebApplicationFactoryBase<TProgram, TTrxnContext, TQueryContext>`. `Test.Support` carries only a thin app adapter, `WebApplicationFactoryBase<TProgram, TTrxnContext, TQueryContext>`, and both `Test.Endpoints` (in-memory) and `Test.E2E` (Testcontainers SQL) derive specializations that only declare which options to use.

> **Phase 4 generates this file.** The adapter is part of the contract-scaffolding output (see [../ai/contract-scaffolding.md](../ai/contract-scaffolding.md), `### 4. Test Infrastructure`) so the solution builds and both `Test.Endpoints` and `Test.E2E` compile before Phase 5 begins. The package base's descriptor removal no-ops when a descriptor is absent - at Phase 4 the host registers no DbContext yet; the swap takes effect in 5b.

`tests/Test.Support/WebApplicationFactoryBase.cs`:

```csharp
using EF.Data;
using EF.IntegrationTesting.AspNetCore;
using Microsoft.AspNetCore.Hosting;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace Test.Support;

/// <summary>
/// App-specific adapter over the reusable EF.IntegrationTesting WebApplicationFactory base.
/// Keeps test factories stable while the shared EF host-replacement plumbing lives in the package.
/// </summary>
public abstract class WebApplicationFactoryBase<TProgram, TTrxnContext, TQueryContext>
    : EfWebApplicationFactoryBase<TProgram, TTrxnContext, TQueryContext>
    where TProgram : class
    where TTrxnContext : DbContextBase<string, Guid?>
    where TQueryContext : DbContextBase<string, Guid?>
{
    protected override string? StartupTaskServiceTypeFullName => "{App}.Bootstrapper.IStartupTask";

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        base.ConfigureWebHost(builder);
        builder.ConfigureLogging(logging =>
        {
            logging.ClearProviders();
            logging.AddConsole();
        });
    }
}
```

**What the package base does** (`EfWebApplicationFactoryBase`, namespace `EF.IntegrationTesting.AspNetCore`): removes the production EF registrations for both contexts (pooled contexts and pool/lease plumbing, `DbContextOptions<T>`, `IDbContextFactory<T>` + `DbContextScopedFactory`, the audit and SQL-only interceptors), re-registers test-mode `IDbContextFactory<T>` + scoped contexts built from the options the derived factory supplies, creates contexts via reflection (bypasses `required` audit/tenant member enforcement - no CS9035), and suppresses app startup tasks named by `StartupTaskServiceTypeFullName`. Descriptor removal no-ops when a registration is absent, so the adapter is safe in a Phase 4 contract scaffold where the host registers no DbContext yet.

**Critical details:**

1. **Typed options per context.** Use `new DbContextOptionsBuilder<{App}DbContextTrxn>().UseInMemoryDatabase(name).Options` - do NOT use generic `DbContextOptions` when multiple contexts exist. `DbContextBase` constructors take `DbContextOptions` (non-generic base), but EF validates the generic type at runtime.
2. Derived factories provide only the test-mode store (override the abstract `BuildTrxnOptions()` / `BuildQueryOptions()`); `ConfigureTestConfiguration(IConfigurationBuilder)` is the hook for app-specific test configuration.
3. Do not hand-roll descriptor-removal or reflection-creation plumbing in the app - it ships in `EF.IntegrationTesting` (see [../support/ef-packages-reference.md](../support/ef-packages-reference.md) section Testing).

## SqlAggregateSeeder (in Test.Support)

**Conditional - generate on first need, not by default.** When the API can create every row a test acts
on (dev-seam auth supplies user/tenant), seed through the API - that is the reference pattern, and this
file is not generated. Builders (`tests/Test.Support/Builders/{Entity}Builder.cs`) construct **domain objects
in memory**; they do not persist a valid FK chain. When tests need prerequisite rows the API never
creates (a real user in a real tenant owning the aggregate), do not duplicate that insert inline - it
drifts per-test and reintroduces the user/tenant FK bugs the dev seam fixes. Provide this one shared
seeder in `Test.Support` that persists the full FK chain in dependency order through the live DbContext.

`tests/Test.Support/SqlAggregateSeeder.cs`:

```csharp
namespace Test.Support;

/// <summary>
/// Persists a valid FK chain (tenant -> user -> aggregate -> children) against a real store via the
/// transactional DbContext, so workflow/E2E tests start from a row the API will accept. Builders
/// construct the domain objects; this seeder owns insert order and FK wiring. Idempotent per id.
/// </summary>
public sealed class SqlAggregateSeeder(IDbContextFactory<{App}DbContextTrxn> factory)
{
    public async Task<SeededContext> SeedAsync(CancellationToken ct = default)
    {
        await using var db = await factory.CreateDbContextAsync(ct);

        // 1. Tenant first (and the user, when the app models users as an entity with an owner FK) -
        //    use the same fixed ids the dev principal/claims use so seeded rows, ScaffoldAuthHandler
        //    claims, and stamped owners all line up. Drop the user step for audit-id-string owners.
        if (!await db.Set<Tenant>().AnyAsync(t => t.Id == SeedConstants.DevTenantId, ct))
            db.Add(Tenant.Create("Test Tenant", SeedConstants.DevTenantId));
        if (!await db.Set<User>().AnyAsync(u => u.Id == SeedConstants.DevUserId, ct))
            db.Add(User.Create(SeedConstants.DevUserId, "Test Principal", SeedConstants.DevTenantId));

        // 2. Aggregate + children via the builder, owned by the seeded user/tenant.
        var parent = new {Entity}Builder()
            .WithTenant(SeedConstants.DevTenantId)
            .WithOwner(SeedConstants.DevUserId)
            .WithChild(/* ... */)
            .Build();
        db.Add(parent);

        await db.SaveChangesAsync(ct);
        return new SeededContext(SeedConstants.DevTenantId, SeedConstants.DevUserId, parent.Id);
    }
}

public sealed record SeededContext(Guid TenantId, Guid UserId, Guid AggregateId);
```

Use it from `[ClassInitialize]`/`[TestInitialize]` in `Test.E2E` and `Test.Integration` after migrations
are applied, instead of inline seeding. The primary domain-journey E2E
([test-templates-e2e.md](test-templates-e2e.md) section Primary domain-journey E2E) and the multi-resource
integration tier ([test-templates-integration.md](test-templates-integration.md)) both consume it.

## Test.Endpoints derived factory (in-memory)

`tests/Test.Endpoints/CustomApiFactory.cs`:

```csharp
public sealed class CustomApiFactory : WebApplicationFactoryBase<Program, {App}DbContextTrxn, {App}DbContextQuery>
{
    private readonly string _dbName = $"TestDb_{Guid.NewGuid()}";

    protected override DbContextOptions BuildTrxnOptions() =>
        new DbContextOptionsBuilder<{App}DbContextTrxn>().UseInMemoryDatabase(_dbName).Options;

    protected override DbContextOptions BuildQueryOptions() =>
        new DbContextOptionsBuilder<{App}DbContextQuery>().UseInMemoryDatabase(_dbName).Options;
}
```

That's the entire file. The pooled-context swap, interceptor removal, factory plumbing, and reflection-based context creation are inherited.

## Test.E2E derived factory (Testcontainers SQL)

`tests/Test.E2E/SqlApiFactory.cs` is identical except the options use `UseSqlServer(connectionString, sql => sql.UseCompatibilityLevel(170))` and the class manages a static Testcontainers SQL lifecycle (`StartContainerAsync` / `StopContainerAsync`). Full template: [test-templates-e2e.md](test-templates-e2e.md) section SqlApiFactory.

## Multi-resource Integration tier

When a test needs the **full distributed app over HTTP** (the API + audit pipeline across resources, Service Bus -> Function handoffs), do not extend `WebApplicationFactoryBase` - use the lazy `AspireTestHost` mesh fixture in `Test.Aspire` from [test-templates-aspire.md](test-templates-aspire.md). For **one class vs one real store** (repository vs SQL, audit repo vs Azurite), use the standalone Testcontainers fixtures in `Test.Integration` from [test-templates-integration.md](test-templates-integration.md). The WAF base is for HTTP-in-API-out testing.

---

## Endpoint Tests

### File: `tests/Test.Endpoints/Endpoints/{Entity}EndpointsTests.cs`

```csharp
[TestClass]
public class {Entity}EndpointsTests : EndpointTestBase
{
    [TestCategory("Endpoint")]
    [TestMethod]
    public async Task Given_ValidPayload_When_PostEntity_Then_Returns201()
    {
        // Arrange
        using var client = await GetHttpClient();
        var tenantId = Guid.NewGuid();
        var createDto = new DefaultRequest<{Entity}Dto>
        {
            Item = new {Entity}Dto { Name = "NewEntity", TenantId = tenantId }
        };

        // Act
        var response = await client.PostAsJsonAsync($"v1/tenant/{tenantId}/{entities}", createDto);

        // Assert
        Assert.AreEqual(HttpStatusCode.Created, response.StatusCode);
        var created = await response.Content.ReadFromJsonAsync<DefaultResponse<{Entity}Dto>>();
        Assert.IsNotNull(created?.Item);
        Assert.AreEqual("NewEntity", created.Item.Name);
    }

    [TestCategory("Endpoint")]
    [TestMethod]
    public async Task Given_NonExistentId_When_GetEntity_Then_Returns404()
    {
        // Arrange
        using var client = await GetHttpClient();
        var tenantId = Guid.NewGuid();
        var nonExistentId = Guid.NewGuid();

        // Act
        var response = await client.GetAsync($"v1/tenant/{tenantId}/{entities}/{nonExistentId}");

        // Assert
        Assert.AreEqual(HttpStatusCode.NotFound, response.StatusCode);
        var problemDetails = await response.Content.ReadFromJsonAsync<ProblemDetails>();
        Assert.IsNotNull(problemDetails);
        Assert.AreEqual(404, problemDetails.Status);
    }

    [TestCategory("Endpoint")]
    [TestMethod]
    public async Task Given_ExistingEntities_When_SearchWithFilter_Then_ReturnsFilteredPage()
    {
        // Arrange
        using var client = await GetHttpClient();
        var tenantId = Guid.NewGuid();

        // Seed
        var create1 = new DefaultRequest<{Entity}Dto>
        {
            Item = new {Entity}Dto { Name = "SearchTarget", TenantId = tenantId }
        };
        var create2 = new DefaultRequest<{Entity}Dto>
        {
            Item = new {Entity}Dto { Name = "OtherItem", TenantId = tenantId }
        };
        await client.PostAsJsonAsync($"v1/tenant/{tenantId}/{entities}", create1);
        await client.PostAsJsonAsync($"v1/tenant/{tenantId}/{entities}", create2);

        // Act
        var searchRequest = new SearchRequest<{Entity}SearchFilter>
        {
            PageIndex = 1,
            PageSize = 10,
            Filter = new {Entity}SearchFilter { SearchTerm = "SearchTarget" }
        };
        var response = await client.PostAsJsonAsync(
            $"v1/tenant/{tenantId}/{entities}/search", searchRequest);

        // Assert
        Assert.AreEqual(HttpStatusCode.OK, response.StatusCode);
        var page = await response.Content.ReadFromJsonAsync<PagedResponse<{Entity}Dto>>();
        Assert.IsNotNull(page);
        Assert.AreEqual(1, page.Total);
        Assert.AreEqual("SearchTarget", page.Data.First().Name);
    }

    [TestCategory("Endpoint")]
    [TestMethod]
    public async Task Given_FullCrudCycle_When_AllOperationsExecuted_Then_AllSucceed()
    {
        // Arrange
        using var client = await GetHttpClient();
        var tenantId = Guid.NewGuid();

        // Create
        var createDto = new DefaultRequest<{Entity}Dto>
        {
            Item = new {Entity}Dto { Name = "CrudTest", TenantId = tenantId }
        };
        var createResponse = await client.PostAsJsonAsync($"v1/tenant/{tenantId}/{entities}", createDto);
        Assert.AreEqual(HttpStatusCode.Created, createResponse.StatusCode);
        var created = await createResponse.Content.ReadFromJsonAsync<DefaultResponse<{Entity}Dto>>();
        var entityId = created!.Item!.Id;

        // Read
        var getResponse = await client.GetAsync($"v1/tenant/{tenantId}/{entities}/{entityId}");
        Assert.AreEqual(HttpStatusCode.OK, getResponse.StatusCode);

        // Update
        var updateDto = new DefaultRequest<{Entity}Dto>
        {
            Item = new {Entity}Dto { Id = entityId, Name = "Updated", TenantId = tenantId }
        };
        var updateResponse = await client.PutAsJsonAsync($"v1/tenant/{tenantId}/{entities}/{entityId}", updateDto);
        Assert.AreEqual(HttpStatusCode.OK, updateResponse.StatusCode);

        // Delete
        var deleteResponse = await client.DeleteAsync($"v1/tenant/{tenantId}/{entities}/{entityId}");
        Assert.AreEqual(HttpStatusCode.OK, deleteResponse.StatusCode);

        // Verify deleted
        var verifyResponse = await client.GetAsync($"v1/tenant/{tenantId}/{entities}/{entityId}");
        Assert.AreEqual(HttpStatusCode.NotFound, verifyResponse.StatusCode);
    }

    [TestCategory("Endpoint")]
    [TestMethod]
    public async Task Given_EmptyDatabase_When_SearchExecuted_Then_ReturnsEmptyPage()
    {
        // Arrange
        using var client = await GetHttpClient();
        var tenantId = Guid.NewGuid();
        var searchRequest = new SearchRequest<{Entity}SearchFilter>
        {
            PageIndex = 1,
            PageSize = 10,
            Filter = new {Entity}SearchFilter()
        };

        // Act
        var response = await client.PostAsJsonAsync($"v1/tenant/{tenantId}/{entities}/search", searchRequest);

        // Assert
        Assert.AreEqual(HttpStatusCode.OK, response.StatusCode);
        var page = await response.Content.ReadFromJsonAsync<PagedResponse<{Entity}Dto>>();
        Assert.IsNotNull(page);
    }
}
```

---

## Test Configuration

### File: `tests/Test.Endpoints/appsettings-test.json`

```json
{
  "TestSettings": {
    "DBSource": "UseInMemoryDatabase",
    "DBName": "Test.Endpoints.TestDB"
  }
}
```

---

## Contention/Concurrency Scenario (Optional)

For high-contention domains (inventory, reservations, financial flows), add:

```csharp
[TestCategory("Endpoint")]
[TestMethod]
public async Task Given_ConcurrentUpdates_When_Executed_Then_OptimisticConcurrencyEnforced()
{
    // Run parallel operations against the same entity
    // Assert: no duplicate side effects, concurrency behavior enforced
}
```
