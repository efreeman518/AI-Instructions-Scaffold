# Test Templates - Integration / Component (Phase 5a/5b, on-demand)

| | |
|---|---|
| **Generates** | `Test/Test.Integration/Infrastructure/SqlContainerFixture.cs`, `Test/Test.Integration/Infrastructure/AzuriteContainerFixture.cs` (+ `RedisContainerFixture.cs` when the app uses Redis), `Test/Test.Integration/Infrastructure/IntegrationTestSetup.cs`, `Test/Test.Integration/{Entity}RepositoryIntegrationTests.cs`, `Test/Test.Integration/AuditLogRepositoryAzuriteTests.cs`, `Test/Test.Integration/DomainEventPipelineTests.cs` |
| **Requires** | [repository-template](repository-template.md), [updater-template](updater-template.md), `EF.IntegrationTesting` (Testcontainers fixtures), Testcontainers packages for each store the app uses |
| **Phase** | Fixtures generated in Phase 4 (component shells); tests filled in during Phase 5a (`*RepositoryIntegrationTests`) and Phase 5b (`AuditLogRepositoryAzuriteTests`, `DomainEventPipelineTests`) |
| **Protocol** | Tests-after for this tier - TDD lives in `Test.Unit` and `Test.Endpoints`. Integration verifies wiring against real infrastructure (SQL/Azurite/Redis), so write the tests once the unit + endpoint tests pin behavior. |
| **Mesh tier** | The full-AppHost-graph mesh tests (`AspireTestHost`, API/Function audit pipelines, Blazor-mesh smoke) live in a **separate `Test.Aspire` project** - see [test-templates-aspire.md](test-templates-aspire.md). |

## Why this tier exists

`Test.Endpoints` runs against in-memory EF, which silently masks tenant query filters, owned-type flattening, paging plans, raw SQL projections, M:N bridge tables, polymorphic indexes, and audit interceptor wiring. `Test.E2E` runs the full HTTP path but only against a single SQL container.

`Test.Integration` is the **component** tier - it exercises **one class against one real store** (a repository vs SQL, the audit repository vs Azurite Table Storage, the projection service vs SQL) by instantiating the class under test directly against a **standalone Testcontainer**. No HTTP, no Aspire graph. Use it for:

- EF migration apply against real SQL Server (catches FK ordering / shadow-property / schema drift bugs).
- Tenant query filters, M:N junction navigation (`.ThenInclude`), polymorphic-index existence checks.
- `AuditLogRepository.AppendAsync -> Azurite` round-trip (partition/row-key shape, metadata round-trip).
- Domain-event projection (`SQL -> projection service -> view document`) with an in-memory view store.

> **Component vs mesh.** A test belongs here when it instantiates one class against one store. It belongs in [test-templates-aspire.md](test-templates-aspire.md) (the `Test.Aspire` project) when it needs the production AppHost graph over HTTP - `CreateHttpClient(...)`, multiple Aspire resources, `WaitForResourceHealthyAsync`, `DistributedApplicationTestingBuilder`. The split keeps the fast component tier off the ~60-90 s Aspire boot. `Test.Integration` must **not** reference `AppHost` or `Aspire.Hosting.Testing`.

## Fixture model

Each store the app uses gets a **standalone Testcontainer fixture** under `Test/Test.Integration/Infrastructure/`. A single `IntegrationTestSetup` starts the needed fixtures in parallel from `[AssemblyInitialize]` and disposes them in `[AssemblyCleanup]`. Each fixture **captures its `StartupError` rather than throwing**, and each test marks itself `Inconclusive` when its store failed to start (assembly-init safety - a container failure must not flip the whole assembly red). Generate only the fixtures the app needs (SQL always; Azurite when audit/table storage is in scope; Redis when a distributed cache is in scope).

> **Naming:** name each fixture for the store it owns (`SqlContainerFixture`, `AzuriteContainerFixture`, `RedisContainerFixture`). They are standalone - they do **not** wrap or depend on the Aspire host.

---

### File: `Test/Test.Integration/Infrastructure/SqlContainerFixture.cs`

```csharp
using EF.IntegrationTesting.Testcontainers;
using Microsoft.EntityFrameworkCore;
using {Project}.Infrastructure.Data;

namespace Test.Integration.Infrastructure;

/// <summary>
/// Standalone SQL Server Testcontainer for the component tier. Wraps the shared EF.IntegrationTesting
/// <c>MsSqlContainerFixture</c> so SQL-only repository/migration/projection tests run against a real
/// database without booting the Aspire AppHost graph. Started once by <see cref="IntegrationTestSetup"/>;
/// <see cref="StartupError"/> is captured (not thrown) so a container failure marks only the dependent
/// tests Inconclusive instead of aborting the whole assembly.
/// </summary>
internal static class SqlContainerFixture
{
    private static readonly MsSqlContainerFixture Sql = new();

    /// <summary>Startup failure captured by <see cref="StartAsync"/>; null when the container started cleanly.</summary>
    internal static Exception? StartupError { get; private set; }

    /// <summary>Connection string for the running SQL container. Only valid once startup succeeded.</summary>
    internal static string ConnectionString => Sql.ConnectionString;

    /// <summary>Starts the SQL container, capturing any failure for the Inconclusive-on-failure pattern.</summary>
    internal static async Task StartAsync()
    {
        try { await Sql.StartAsync(); }
        catch (Exception ex) { StartupError = ex; }
    }

    /// <summary>Disposes the SQL container.</summary>
    internal static async Task StopAsync() => await Sql.DisposeAsync();

    /// <summary>Builds a trxn context against the standalone SQL container.</summary>
    internal static {App}DbContextTrxn CreateTrxnContext(string? connString = null) =>
        new(BuildSqlServerOptions<{App}DbContextTrxn>(connString ?? Sql.ConnectionString)) { AuditId = "integration-test" };

    /// <summary>Builds a query context against the standalone SQL container.</summary>
    internal static {App}DbContextQuery CreateQueryContext(string? connString = null) =>
        new(BuildSqlServerOptions<{App}DbContextQuery>(connString ?? Sql.ConnectionString)) { AuditId = "integration-test" };

    private static DbContextOptions<TContext> BuildSqlServerOptions<TContext>(string connectionString)
        where TContext : DbContext =>
        new DbContextOptionsBuilder<TContext>()
            .UseSqlServer(connectionString, sql =>
            {
                sql.UseLatestCompatibilityLevel();
                sql.EnableRetryOnFailure();
            })
            .Options;
}
```

> **`AuditId` bypass:** `DbContextBase<string, Guid?>` declares `required string AuditId`. When constructing contexts outside DI, set it directly via object-initializer syntax - the design-time factory uses the same pattern. (Apps whose context takes an `IRequestContext` instead build it with an admin context here; TaskFlow uses the `AuditId` string.)

---

### File: `Test/Test.Integration/Infrastructure/AzuriteContainerFixture.cs`

Generate when the app persists to Azure Table/Blob/Queue storage (audit log, attachments).

```csharp
using Testcontainers.Azurite;

namespace Test.Integration.Infrastructure;

/// <summary>
/// Standalone Azurite Testcontainer for the component tier. Provides a real Table Storage endpoint for
/// the audit-repository test without booting the Aspire AppHost graph. Started once by
/// <see cref="IntegrationTestSetup"/>; <see cref="StartupError"/> is captured (not thrown).
/// </summary>
internal static class AzuriteContainerFixture
{
    // Pin the image explicitly - the parameterless AzuriteBuilder() ctor is obsolete in Testcontainers.Azurite 4.x.
    private static readonly AzuriteContainer Azurite =
        new AzuriteBuilder("mcr.microsoft.com/azure-storage/azurite:3.33.0").Build();

    /// <summary>Startup failure captured by <see cref="StartAsync"/>; null when the container started cleanly.</summary>
    internal static Exception? StartupError { get; private set; }

    /// <summary>Azurite connection string (blob/queue/table). Only valid once startup succeeded.</summary>
    internal static string ConnectionString => Azurite.GetConnectionString();

    /// <summary>Starts the Azurite container, capturing any failure for the Inconclusive-on-failure pattern.</summary>
    internal static async Task StartAsync()
    {
        try { await Azurite.StartAsync(); }
        catch (Exception ex) { StartupError = ex; }
    }

    /// <summary>Disposes the Azurite container.</summary>
    internal static async Task StopAsync() => await Azurite.DisposeAsync();
}
```

> **Redis:** when the app uses a distributed cache, generate a parallel `RedisContainerFixture` wrapping `Testcontainers.Redis` (`new RedisBuilder("redis:7").Build()`, `GetConnectionString()`) with the same `StartupError` shape, and start it in `IntegrationTestSetup` alongside the others.

---

### File: `Test/Test.Integration/Infrastructure/IntegrationTestSetup.cs`

```csharp
namespace Test.Integration.Infrastructure;

/// <summary>
/// Assembly-scoped lifecycle for the component tier. Starts the standalone store Testcontainers in
/// parallel via <c>[AssemblyInitialize]</c> and disposes them via <c>[AssemblyCleanup]</c>. Each fixture
/// captures its own <c>StartupError</c> (assembly-init safety) so a container failure marks only the
/// dependent tests Inconclusive instead of aborting the whole assembly. Component tier only - no Aspire
/// graph, no <c>AppHost</c> reference.
/// </summary>
[TestClass]
public class IntegrationTestSetup
{
    [AssemblyInitialize]
    public static async Task AssemblyInit(TestContext _) =>
        await Task.WhenAll(
            SqlContainerFixture.StartAsync(),
            AzuriteContainerFixture.StartAsync());

    [AssemblyCleanup]
    public static async Task AssemblyCleanup(TestContext _) =>
        await Task.WhenAll(
            SqlContainerFixture.StopAsync(),
            AzuriteContainerFixture.StopAsync());
}
```

> Only one `[AssemblyInitialize]`/`[AssemblyCleanup]` per assembly. Add each generated store fixture's `StartAsync`/`StopAsync` to the `Task.WhenAll` calls.

---

## Repository Integration Tests

Cover **migration apply** + **CRUD against real SQL** + **child includes** + **M:N junction navigation** + **tenant query filter** + **polymorphic indexes** when applicable. Build contexts via `SqlContainerFixture` and gate on `StartupError` in `[TestInitialize]`.

### File: `Test/Test.Integration/{Entity}RepositoryIntegrationTests.cs`

```csharp
using EF.Data.Contracts;
using Microsoft.EntityFrameworkCore;
using {Project}.Domain.Model;
using {Project}.Infrastructure.Data;
using Test.Integration.Infrastructure;
using Test.Support;
using Test.Support.Builders;

namespace Test.Integration;

/// <summary>
/// Validates EF migrations apply cleanly against real SQL Server and that core repository operations
/// (CRUD, includes, many-to-many bridges, the tenant query filter, polymorphic-attachment indexing where
/// applicable) work against the migrated schema.
/// Component tier: instantiates contexts directly against a standalone SQL Testcontainer via
/// <c>SqlContainerFixture</c> (started by <c>IntegrationTestSetup</c>) - no Aspire graph, no HTTP.
/// </summary>
[TestClass]
[TestCategory("Integration")]
public class {Entity}RepositoryIntegrationTests
{
    private static readonly Guid TenantA = TestConstants.TenantId;
    private static readonly Guid TenantB = Guid.Parse("00000000-0000-0000-0000-000000000099");

    /// <summary>Marks the test Inconclusive when the SQL container failed to start (assembly-init safety).</summary>
    [TestInitialize]
    public void TestSetup()
    {
        if (SqlContainerFixture.StartupError != null)
            Assert.Inconclusive($"SQL container startup failed: {SqlContainerFixture.StartupError.Message}");
    }

    [TestMethod]
    [Timeout(120000)]
    public async Task Migrations_ApplyCleanly_ToSqlContainer()
    {
        await using var db = SqlContainerFixture.CreateTrxnContext();
        await db.Database.MigrateAsync();

        Assert.IsTrue(await db.Database.CanConnectAsync());

        var conn = db.Database.GetDbConnection();
        await conn.OpenAsync();
        await using var cmd = conn.CreateCommand();
        cmd.CommandText = "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = '{app}'";
        var tableCount = (int)(await cmd.ExecuteScalarAsync())!;
        Assert.IsGreaterThanOrEqualTo(tableCount, {ExpectedTableCount},
            $"Expected >= {ExpectedTableCount} tables in {app} schema, found {tableCount}");
    }

    [TestMethod]
    [Timeout(120000)]
    public async Task {Entity}_CrudOperations_WorkAgainstRealSql()
    {
        await using var db = SqlContainerFixture.CreateTrxnContext();
        await db.Database.MigrateAsync();

        // Create
        var entity = new {Entity}Builder().WithName("Integration {Entity}").Build();
        db.{Entities}.Add(entity);
        await db.SaveChangesAsync(OptimisticConcurrencyWinner.ClientWins);
        var id = entity.Id;
        Assert.AreNotEqual(Guid.Empty, id);

        // Read
        var fetched = await db.{Entities}.FindAsync(id);
        Assert.IsNotNull(fetched);
        Assert.AreEqual("Integration {Entity}", fetched.Name);

        // Update via domain method
        fetched.Update(name: "Updated {Entity}");
        await db.SaveChangesAsync(OptimisticConcurrencyWinner.ClientWins);
        var updated = await db.{Entities}.FindAsync(id);
        Assert.AreEqual("Updated {Entity}", updated!.Name);

        // Delete
        db.{Entities}.Remove(updated);
        await db.SaveChangesAsync(OptimisticConcurrencyWinner.ClientWins);
        var deleted = await db.{Entities}.FindAsync(id);
        Assert.IsNull(deleted);
    }

    [TestMethod]
    [Timeout(120000)]
    public async Task {Entity}_WithChildren_PersistsCorrectly()
    {
        await using var db = SqlContainerFixture.CreateTrxnContext();
        await db.Database.MigrateAsync();

        var entity = new {Entity}Builder().WithName("Parent {Entity}").Build();
        db.{Entities}.Add(entity);
        await db.SaveChangesAsync(OptimisticConcurrencyWinner.ClientWins);

        var childResult = {ChildEntity}.Create(TenantA, entity.Id, "Child body");
        db.{ChildEntities}.Add(childResult.Value!);
        await db.SaveChangesAsync(OptimisticConcurrencyWinner.ClientWins);

        var loaded = await db.{Entities}
            .Include(e => e.{ChildEntities})
            .FirstOrDefaultAsync(e => e.Id == entity.Id);

        Assert.IsNotNull(loaded);
        Assert.HasCount(1, loaded.{ChildEntities});
    }

    [TestMethod]
    [Timeout(120000)]
    public async Task {Entity}Tag_ManyToMany_WorksCorrectly()
    {
        // Only generate when entity participates in an M:N relationship via a junction entity.
        await using var db = SqlContainerFixture.CreateTrxnContext();
        await db.Database.MigrateAsync();

        var entity = new {Entity}Builder().WithName("Tagged").Build();
        db.{Entities}.Add(entity);
        var tag = new TagBuilder().WithName("M2MTag").Build();
        db.Tags.Add(tag);
        await db.SaveChangesAsync(OptimisticConcurrencyWinner.ClientWins);

        var bridge = {Entity}Tag.Create(TenantA, entity.Id, tag.Id);
        db.{Entity}Tags.Add(bridge.Value!);
        await db.SaveChangesAsync(OptimisticConcurrencyWinner.ClientWins);

        var loaded = await db.{Entities}
            .Include(e => e.{Entity}Tags).ThenInclude(et => et.Tag)
            .FirstOrDefaultAsync(e => e.Id == entity.Id);

        Assert.IsNotNull(loaded);
        Assert.HasCount(1, loaded.{Entity}Tags);
        Assert.AreEqual("M2MTag", loaded.{Entity}Tags.First().Tag!.Name);
    }

    [TestMethod]
    [Timeout(120000)]
    public async Task TenantQueryFilter_RestrictsResults_WhenTenantIdSet()
    {
        // Only generate when enableMultiTenant is true.
        await using var db = SqlContainerFixture.CreateTrxnContext();
        await db.Database.MigrateAsync();

        var entityA = new {Entity}Builder().WithTenantId(TenantA).WithName("Tenant A").Build();
        var entityB = new {Entity}Builder().WithTenantId(TenantB).WithName("Tenant B").Build();
        db.{Entities}.Add(entityA);
        db.{Entities}.Add(entityB);
        await db.SaveChangesAsync(OptimisticConcurrencyWinner.ClientWins);

        // IgnoreQueryFilters returns all rows; the active filter must restrict the count.
        var allViaEf = await db.{Entities}.IgnoreQueryFilters()
            .Where(e => e.Name.StartsWith("Tenant"))
            .ToListAsync();
        Assert.IsGreaterThanOrEqualTo(allViaEf.Count, 2);

        var filteredCount = await db.{Entities}
            .Where(e => e.Name.StartsWith("Tenant"))
            .CountAsync();

        Assert.IsGreaterThanOrEqualTo(allViaEf.Count, filteredCount,
            "Query filter should restrict results");
    }
}
```

### Repository test coverage matrix

| Scenario | Generate when |
|---|---|
| `Migrations_ApplyCleanly_ToSqlContainer` | Always - once per schema, not per entity. |
| `{Entity}_CrudOperations_WorkAgainstRealSql` | Every entity with mutations. |
| `{Entity}_WithChildren_PersistsCorrectly` | Entity has owned/dependent child collections (1:N). |
| `{Entity}Tag_ManyToMany_WorksCorrectly` | Entity participates in M:N via a junction. |
| `TenantQueryFilter_RestrictsResults_WhenTenantIdSet` | `enableMultiTenant: true`. |
| `Polymorphic_Index_Exists` | Entity uses a polymorphic ownership pattern (e.g., `Attachment.OwnerType` + `OwnerId`). |

---

## Audit Repository (Azurite) Test

Validates `AuditLogRepository.AppendAsync` against real Azurite Table Storage (partition key, row key shape, round-trip metadata). Component tier - it exercises only Azurite via `AzuriteContainerFixture`, no API and no Function.

### File: `Test/Test.Integration/AuditLogRepositoryAzuriteTests.cs`

```csharp
using Azure.Data.Tables;
using EF.Common.Contracts;
using Microsoft.Extensions.Azure;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;
using {Project}.Infrastructure.Storage;
using Test.Integration.Infrastructure;

namespace Test.Integration;

/// <summary>
/// Validates AuditLogRepository.AppendAsync against real Azurite Table Storage: partition key,
/// row key shape (..._{Id:N}), and round-trip of audit metadata.
/// Component tier: exercises only Azurite via a standalone <c>AzuriteContainerFixture</c> (started by
/// <c>IntegrationTestSetup</c>) - no API, no Function, no Aspire graph.
/// </summary>
[TestClass]
[TestCategory("Integration")]
[DoNotParallelize]
public class AuditLogRepositoryAzuriteTests
{
    /// <summary>Marks the test Inconclusive when the Azurite container failed to start (assembly-init safety).</summary>
    [TestInitialize]
    public void TestSetup()
    {
        if (AzuriteContainerFixture.StartupError != null)
            Assert.Inconclusive($"Azurite container startup failed: {AzuriteContainerFixture.StartupError.Message}");
    }

    [TestMethod]
    [Timeout(300000)]
    public async Task Given_AuditEntry_When_AppendAsyncToAzurite_Then_TableEntityPersistedWithExpectedKeys()
    {
        var ct = CancellationToken.None;

        var connectionString = AzuriteContainerFixture.ConnectionString;
        Assert.IsFalse(string.IsNullOrWhiteSpace(connectionString));

        var tableName = $"audit{Guid.NewGuid():N}"[..31];
        var tableServiceClient = new TableServiceClient(connectionString);
        var repository = new AuditLogRepository(
            new TestTableServiceClientFactory(tableServiceClient),
            Options.Create(new AuditLogStorageSettings
            {
                TableName = tableName,
                NullTenantPartitionKey = "_system"
            }),
            NullLogger<AuditLogRepository>.Instance);

        var tenantId = Guid.NewGuid();
        var entry = new AuditEntry<string, Guid>
        {
            Id = Guid.NewGuid(),
            AuditId = "integration-user",
            TenantId = tenantId,
            EntityType = "{Entity}",
            EntityKey = Guid.NewGuid().ToString(),
            Status = AuditStatus.Success,
            Action = "Create",
            Metadata = "{\"source\":\"azurite-test\"}"
        };

        try
        {
            await repository.AppendAsync(entry, ct);

            var tableClient = tableServiceClient.GetTableClient(tableName);
            var persisted = await ReadSingleEntityAsync(tableClient, tenantId.ToString());

            Assert.IsNotNull(persisted);
            Assert.AreEqual(tenantId.ToString(), persisted.PartitionKey);
            Assert.IsTrue(persisted.RowKey.EndsWith($"_{entry.Id:N}", StringComparison.Ordinal));
            Assert.AreEqual(entry.AuditId, persisted.AuditId);
            Assert.AreEqual(entry.Action, persisted.Action);
            Assert.AreEqual(entry.Status.ToString(), persisted.Status);
        }
        finally
        {
            await tableServiceClient.DeleteTableAsync(tableName);
        }
    }

    private static async Task<AuditLogTableEntity> ReadSingleEntityAsync(
        TableClient tableClient, string partitionKey)
    {
        await foreach (var entity in tableClient.QueryAsync<AuditLogTableEntity>(
            e => e.PartitionKey == partitionKey))
        {
            return entity;
        }
        Assert.Fail("Expected an audit entity to be written to Azurite.");
        throw new InvalidOperationException("Unreachable");
    }

    private sealed class TestTableServiceClientFactory(TableServiceClient client)
        : IAzureClientFactory<TableServiceClient>
    {
        public TableServiceClient CreateClient(string name) => client;
    }
}
```

> The **API/Function audit pipeline** (request -> middleware -> Table Storage over HTTP) is a mesh test - it lives in `Test.Aspire`. See [test-templates-aspire.md](test-templates-aspire.md).

---

## Domain Event Projection Pipeline

### File: `Test/Test.Integration/DomainEventPipelineTests.cs`

```csharp
using System.Text.Json;
using EF.Data.Contracts;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Logging.Abstractions;
using {Project}.Application.Contracts.Repositories;
using {Project}.Application.Contracts.Storage;
using {Project}.Application.Services;
using {Project}.Domain.Model;
using {Project}.Infrastructure.Data;
using {Project}.Infrastructure.Repositories;
using Test.Integration.Infrastructure;

namespace Test.Integration;

/// <summary>
/// Validates the domain-event projection pipeline: an entity persisted to SQL is read by the projection
/// service through the query-side repositories and emitted as a view document with correct counts.
/// Component tier: only SQL is exercised (the Service Bus -> Function -> projection hop is covered by the
/// mesh tier in <c>Test.Aspire</c>); contexts are built against a standalone SQL Testcontainer via
/// <c>SqlContainerFixture</c> (started by <c>IntegrationTestSetup</c>) - no Aspire graph. The view store is
/// in-memory - real Cosmos behavior is out of scope.
/// </summary>
[TestClass]
public class DomainEventPipelineTests
{
    private static readonly Guid TenantId = Guid.Parse("11111111-1111-1111-1111-111111111111");

    [ClassInitialize]
    public static async Task ClassInit(TestContext _)
    {
        if (SqlContainerFixture.StartupError != null)
            return; // tests mark themselves Inconclusive in TestSetup
        await using var db = SqlContainerFixture.CreateTrxnContext();
        await db.Database.MigrateAsync();
    }

    /// <summary>Marks the test Inconclusive when the SQL container failed to start (assembly-init safety).</summary>
    [TestInitialize]
    public void TestSetup()
    {
        if (SqlContainerFixture.StartupError != null)
            Assert.Inconclusive($"SQL container startup failed: {SqlContainerFixture.StartupError.Message}");
    }

    [TestMethod]
    [TestCategory("Integration")]
    [Timeout(120000)]
    public async Task Given_{Entity}Created_When_ProjectionRuns_Then_{Entity}ViewProduced()
    {
        var connStr = SqlContainerFixture.ConnectionString;
        await using var ctx = SqlContainerFixture.CreateTrxnContext(connStr);

        var entityResult = {Entity}.Create(TenantId, "Integration Test {Entity}");
        Assert.IsTrue(entityResult.IsSuccess);
        var entity = entityResult.Value!;
        ctx.{Entities}.Add(entity);
        await ctx.SaveChangesAsync(OptimisticConcurrencyWinner.ClientWins);

        await using var queryCtx = SqlContainerFixture.CreateQueryContext(connStr);
        var viewRepo = new InMemory{Entity}ViewRepository();
        var projectionService = new {Entity}ViewProjectionService(
            new {Entity}RepositoryQuery(queryCtx),
            viewRepo,
            NullLogger<{Entity}ViewProjectionService>.Instance);

        await projectionService.Project{Entity}Async(entity.Id);

        var view = await viewRepo.GetAsync(entity.Id.ToString(), TenantId.ToString());
        Assert.IsNotNull(view, "View should be created by projection");
        Assert.AreEqual("Integration Test {Entity}", view.Name);
    }
}

/// <summary>In-memory implementation of I{Entity}ViewRepository for integration testing
/// without a Cosmos emulator.</summary>
internal class InMemory{Entity}ViewRepository : I{Entity}ViewRepository
{
    private readonly Dictionary<string, {Entity}ViewDto> _store = new();

    public Task UpsertAsync({Entity}ViewDto view, CancellationToken ct = default)
    {
        _store[$"{view.TenantId}:{view.Id}"] = view;
        return Task.CompletedTask;
    }

    public Task<{Entity}ViewDto?> GetAsync(string id, string tenantId, CancellationToken ct = default)
    {
        _store.TryGetValue($"{tenantId}:{id}", out var result);
        return Task.FromResult(result);
    }
}
```

Skip this template when the project does not have a projection service / read-model store. Generate only when `.scaffold/resource-implementation.yaml` declares a projection/read-model boundary.

---

## Project file

### File: `Test/Test.Integration/Test.Integration.csproj`

```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <IsTestProject>true</IsTestProject>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="MSTest" />
    <PackageReference Include="Microsoft.EntityFrameworkCore.SqlServer" />
    <PackageReference Include="Testcontainers.MsSql" />
    <PackageReference Include="Testcontainers.Azurite" />
    <PackageReference Include="Azure.Data.Tables" />
    <PackageReference Include="EF.IntegrationTesting" />
  </ItemGroup>
  <ItemGroup>
    <Using Include="Microsoft.VisualStudio.TestTools.UnitTesting" />
  </ItemGroup>
  <ItemGroup>
    <ProjectReference Include="..\Test.Support\Test.Support.csproj" />
    <ProjectReference Include="..\..\Application\{Project}.Application.Contracts\{Project}.Application.Contracts.csproj" />
    <ProjectReference Include="..\..\Application\{Project}.Application.Services\{Project}.Application.Services.csproj" />
    <ProjectReference Include="..\..\Infrastructure\{Project}.Infrastructure.Data\{Project}.Infrastructure.Data.csproj" />
    <ProjectReference Include="..\..\Infrastructure\{Project}.Infrastructure.Repositories\{Project}.Infrastructure.Repositories.csproj" />
    <ProjectReference Include="..\..\Infrastructure\{Project}.Infrastructure.Storage\{Project}.Infrastructure.Storage.csproj" />
  </ItemGroup>
</Project>
```

> **No `AppHost` / `Aspire.Hosting.Testing` reference.** Those belong only to `Test.Aspire`. Add `Testcontainers.Redis` when a `RedisContainerFixture` is generated.

---

## Verification

- [ ] `Test.Integration` references **no** `AppHost` and **no** `Aspire.Hosting.Testing` - component tier only.
- [ ] One standalone fixture per store under `Infrastructure/`; each captures `StartupError` instead of throwing.
- [ ] One `IntegrationTestSetup` owns the sole `[AssemblyInitialize]`/`[AssemblyCleanup]` and starts the fixtures in parallel.
- [ ] Every test guards on its store's `StartupError` in `[TestInitialize]` (or `[ClassInitialize]`) and marks itself `Inconclusive` on failure.
- [ ] Component tests instantiate the class under test directly against a fixture connection string - no `CreateHttpClient`, no `WaitForResourceHealthyAsync`, no `DistributedApplicationTestingBuilder`.
- [ ] `Migrations_ApplyCleanly_ToSqlContainer` exists exactly once per assembly (not per entity).
- [ ] Tenant query filter test exists when `enableMultiTenant: true`; M:N test exists when entity uses a junction.
- [ ] Every test class has a class-level `<summary>` declaring tier (component) + store.
- [ ] Running `Test.Integration` boots **no** Aspire graph (no `DistributedApplicationTestingBuilder` log lines).

---

**TaskFlow proof (local):**
- `../AI-Instructions-ReferenceApp/src/Test/Test.Integration/Infrastructure/SqlContainerFixture.cs`
- `../AI-Instructions-ReferenceApp/src/Test/Test.Integration/Infrastructure/AzuriteContainerFixture.cs`
- `../AI-Instructions-ReferenceApp/src/Test/Test.Integration/Infrastructure/IntegrationTestSetup.cs`
- `../AI-Instructions-ReferenceApp/src/Test/Test.Integration/MigrationAndRepositoryTests.cs`
- `../AI-Instructions-ReferenceApp/src/Test/Test.Integration/AuditLogRepositoryAzuriteTests.cs`
- `../AI-Instructions-ReferenceApp/src/Test/Test.Integration/DomainEventPipelineTests.cs`

**TaskFlow proof (remote fallback):**
<https://github.com/efreeman518/AI-Instructions-ReferenceApp/tree/main/src/Test/Test.Integration>
