# Test Templates - Endpoint (Phase 5b)

| | |
|---|---|
| **Generates** | `Test/Test.Endpoints/Endpoints/{Entity}EndpointsTests.cs` |
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

The plumbing for swapping the production DbContext + interceptors + pooled factories with a test-mode store is identical between `Test.Endpoints` (in-memory) and `Test.E2E` (Testcontainers SQL). It lives once in `Test.Support` as `WebApplicationFactoryBase<TProgram, TTrxnContext, TQueryContext>`. Both projects derive thin specializations that only declare which options to use.

> **Phase 4 generates this file.** The shared base is part of the contract-scaffolding output (see [../ai/contract-scaffolding.md](../ai/contract-scaffolding.md), `### 4. Test Infrastructure`) so the solution builds and both `Test.Endpoints` and `Test.E2E` compile before Phase 5 begins. The shape below is the canonical reference.

`Test/Test.Support/WebApplicationFactoryBase.cs`:

```csharp
using EF.Data;
using EF.Data.Interceptors;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Hosting;

namespace Test.Support;

/// <summary>
/// Shared base for WebApplicationFactory-based test factories.
///
/// Subclasses override BuildTrxnOptions and BuildQueryOptions to choose the test database
/// (in-memory for endpoint contract tests, Testcontainers SQL for E2E workflow tests).
///
/// Removes the standard pooled-DbContext + interceptor + scoped-factory plumbing that the
/// production host registers, then re-registers test-mode contexts using TestDbContextFactory.
///
/// Constrained to DbContextBase&lt;string, Guid?&gt; - the EF.Packages canonical audit/tenant
/// shape. Apps that deviate from these types must override ConfigureWebHost directly rather
/// than using this base.
/// </summary>
public abstract class WebApplicationFactoryBase<TProgram, TTrxnContext, TQueryContext> : WebApplicationFactory<TProgram>
    where TProgram : class
    where TTrxnContext : DbContextBase<string, Guid?>
    where TQueryContext : DbContextBase<string, Guid?>
{
    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.UseEnvironment("Development");
        builder.ConfigureServices(services =>
        {
            services.RemoveAll<IHostedService>();
            RemoveStandardEfInfrastructure(services);
            RemoveAppSpecificServices(services);

            var trxnOptions = BuildTrxnOptions();
            var queryOptions = BuildQueryOptions();
            services.AddScoped(_ => WebApplicationFactoryHelpers.CreateContext<TTrxnContext>(trxnOptions));
            services.AddScoped(_ => WebApplicationFactoryHelpers.CreateContext<TQueryContext>(queryOptions));
            services.AddSingleton<IDbContextFactory<TTrxnContext>>(new TestDbContextFactory<TTrxnContext>(trxnOptions));
            services.AddSingleton<IDbContextFactory<TQueryContext>>(new TestDbContextFactory<TQueryContext>(queryOptions));
        });
    }

    protected abstract DbContextOptions BuildTrxnOptions();
    protected abstract DbContextOptions BuildQueryOptions();
    protected virtual void RemoveAppSpecificServices(IServiceCollection services) { }

    private static void RemoveStandardEfInfrastructure(IServiceCollection services)
    {
        services.RemoveAll<AuditInterceptor<string, Guid?>>();
        services.RemoveAll<ConnectionNoLockInterceptor>();

        WebApplicationFactoryHelpers.RemoveDescriptorsByServiceType(services, typeof(TTrxnContext));
        WebApplicationFactoryHelpers.RemoveDescriptorsByServiceType(services, typeof(TQueryContext));
        WebApplicationFactoryHelpers.RemoveDescriptorsByServiceType(services, typeof(DbContextOptions<TTrxnContext>));
        WebApplicationFactoryHelpers.RemoveDescriptorsByServiceType(services, typeof(DbContextOptions<TQueryContext>));
        WebApplicationFactoryHelpers.RemoveDescriptorsByServiceType(services, typeof(DbContextOptions));
        WebApplicationFactoryHelpers.RemoveDescriptorsByServiceType(services, typeof(IDbContextFactory<TTrxnContext>));
        WebApplicationFactoryHelpers.RemoveDescriptorsByServiceType(services, typeof(IDbContextFactory<TQueryContext>));
        WebApplicationFactoryHelpers.RemoveDescriptorsByServiceType(services, typeof(DbContextScopedFactory<TTrxnContext, string, Guid?>));
        WebApplicationFactoryHelpers.RemoveDescriptorsByServiceType(services, typeof(DbContextScopedFactory<TQueryContext, string, Guid?>));
        WebApplicationFactoryHelpers.RemoveDescriptorsByImplPartialName(services, "DbContextPool");
    }
}

public sealed class TestDbContextFactory<TContext>(DbContextOptions options) : IDbContextFactory<TContext>
    where TContext : DbContext
{
    public TContext CreateDbContext() => WebApplicationFactoryHelpers.CreateContext<TContext>(options);
}

public static class WebApplicationFactoryHelpers
{
    public static TContext CreateContext<TContext>(DbContextOptions options) where TContext : DbContext
    {
        var genericOptionsType = typeof(DbContextOptions<>).MakeGenericType(typeof(TContext));
        var ctor = typeof(TContext).GetConstructor([genericOptionsType])
                ?? typeof(TContext).GetConstructor([typeof(DbContextOptions)]);
        return (TContext)ctor!.Invoke([options]);
    }

    public static void RemoveDescriptorsByServiceType(IServiceCollection services, Type serviceType)
    {
        foreach (var d in services.Where(d => d.ServiceType == serviceType).ToList())
            services.Remove(d);
    }

    public static void RemoveDescriptorsByImplPartialName(IServiceCollection services, string partialName)
    {
        foreach (var d in services.Where(d =>
            d.ImplementationType?.FullName?.Contains(partialName) == true
            || d.ServiceType.FullName?.Contains(partialName) == true).ToList())
            services.Remove(d);
    }
}
```

**Why a base class:** the production host registers `AddPooledDbContextFactory` + `DbContextScopedFactory` + `AuditInterceptor` (per [data-layer-wiring.md](../patterns/data-layer-wiring.md)). Both Test.Endpoints and Test.E2E need to remove **all** of the following before re-registering test contexts:

| Registration to Remove | Why |
|---|---|
| `AuditInterceptor<string, Guid?>` | Depends on `IInternalMessageBus` (EF.BackgroundServices), not registered in test host |
| `ConnectionNoLockInterceptor` | SQL-only interceptor, incompatible with InMemory provider |
| `IDbContextPool<T>` (internal) | Pooled factory creates singleton pools that conflict with scoped test options |
| `DbContextScopedFactory<T, string, Guid?>` | Wraps `IDbContextFactory<T>` - must be removed and re-registered |
| `IDbContextFactory<T>` | Original pooled factory - must be replaced with `TestDbContextFactory<T>` |
| `DbContextOptions<T>` + `DbContextOptions` | Pool-registered options conflict with new test options |

The base does this once. Derived classes provide only the test-mode store.

**Critical details preserved by the base:**
1. **Typed options per context.** Use `new DbContextOptionsBuilder<{App}DbContextTrxn>().UseInMemoryDatabase(name).Options` - do NOT use generic `DbContextOptions` when multiple contexts exist. `DbContextBase` constructors take `DbContextOptions` (non-generic base), but EF validates the generic type at runtime.
2. **Required member bypass.** `DbContextBase<TAuditIdType, TTenantIdType>` declares `required` members (e.g., `AuditId`). The base's `WebApplicationFactoryHelpers.CreateContext<T>` uses `ConstructorInfo.Invoke()` via reflection to bypass compile-time `required` enforcement when creating contexts from a test factory.
3. **Re-provided `IDbContextFactory<T>`.** `DbContextScopedFactory` resolves `IDbContextFactory<T>` - the base registers `TestDbContextFactory<T>` that creates contexts via reflection.

## Test.Endpoints derived factory (in-memory)

`Test/Test.Endpoints/CustomApiFactory.cs`:

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

`Test/Test.E2E/SqlApiFactory.cs` is identical except the options use `UseSqlServer(connectionString, sql => sql.UseCompatibilityLevel(170))` and the class manages a static Testcontainers SQL lifecycle (`StartContainerAsync` / `StopContainerAsync`). Full template: [test-templates-e2e.md](test-templates-e2e.md) section SqlApiFactory.

## Multi-resource Integration tier

When a test needs the **full distributed app over HTTP** (the API + audit pipeline across resources, Service Bus -> Function handoffs), do not extend `WebApplicationFactoryBase` - use the lazy `AspireTestHost` mesh fixture in `Test.Aspire` from [test-templates-aspire.md](test-templates-aspire.md). For **one class vs one real store** (repository vs SQL, audit repo vs Azurite), use the standalone Testcontainers fixtures in `Test.Integration` from [test-templates-integration.md](test-templates-integration.md). The WAF base is for HTTP-in-API-out testing.

---

## Endpoint Tests

### File: `Test/Test.Endpoints/Endpoints/{Entity}EndpointsTests.cs`

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

### File: `Test/Test.Endpoints/appsettings-test.json`

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
