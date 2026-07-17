# Test Templates - Integration / Component (Phase 5a/5b, on-demand)

| | |
|---|---|
| **Generates** | `tests/Test.Support/Hosting/DockerRuntimePreflight.cs` (shared with Aspire-backed tiers when present), `tests/Test.Integration/Infrastructure/SqlContainerFixture.cs`, `tests/Test.Integration/Infrastructure/AzuriteContainerFixture.cs` (+ `RedisContainerFixture.cs` when the app uses Redis), `tests/Test.Integration/Infrastructure/IntegrationTestSetup.cs`, `tests/Test.Integration/{Entity}RepositoryIntegrationTests.cs`, `tests/Test.Integration/AuditLogRepositoryAzuriteTests.cs`, `tests/Test.Integration/DomainEventPipelineTests.cs` |
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

Each store the app uses gets a **standalone Testcontainer fixture** under `tests/Test.Integration/Infrastructure/`. A single `IntegrationTestSetup` runs the shared bounded Docker preflight, starts the needed fixtures in parallel from `[AssemblyInitialize]`, and disposes them in `[AssemblyCleanup]`. Each fixture captures its `StartupError` rather than throwing so discovery continues, but each dependent test then fails with the full exception. Only the preflight-confirmed unavailable runtime is `Inconclusive`. Generate only the fixtures the app needs (SQL always; Azurite when audit/table storage is in scope; Redis when a distributed cache is in scope).

> **Naming:** name each fixture for the store it owns (`SqlContainerFixture`, `AzuriteContainerFixture`, `RedisContainerFixture`). They are standalone - they do **not** wrap or depend on the Aspire host.

> **Cleanup is owned by `DisposeAsync` + the Testcontainers reaper - never hand-sweep Docker.** Each fixture's `StopAsync` -> `DisposeAsync` removes its own container deterministically. As a backstop, Testcontainers' Resource Reaper (Ryuk) stamps every container it starts with a per-run `org.testcontainers.session-id` label and removes only those when the test process exits - so a crashed run still cleans up by **exact session ownership**. Do **not** add `docker rm`/`docker container prune` sweeps to fixtures or test code: a sweep by image name or generic label would also delete other projects', other sessions', and intentional persistent containers. The reaper already owns this correctly.

---

### File: `tests/Test.Integration/Infrastructure/SqlContainerFixture.cs`

```csharp
using EF.IntegrationTesting.Testcontainers;
using Microsoft.EntityFrameworkCore;
using {Project}.Infrastructure.Data;

namespace Test.Integration.Infrastructure;

/// <summary>
/// Standalone SQL Server Testcontainer for the component tier. Wraps the shared EF.IntegrationTesting
/// <c>MsSqlContainerFixture</c> so SQL-only repository/migration/projection tests run against a real
/// database without booting the Aspire AppHost graph. Started once by <see cref="IntegrationTestSetup"/>;
/// <see cref="StartupError"/> is captured so dependent tests fail with its diagnostics without aborting
/// assembly discovery.
/// </summary>
internal static class SqlContainerFixture
{
    private static readonly MsSqlContainerFixture Sql = new();

    /// <summary>Startup failure captured by <see cref="StartAsync"/>; null when the container started cleanly.</summary>
    internal static Exception? StartupError { get; private set; }

    /// <summary>Connection string for the running SQL container. Only valid once startup succeeded.</summary>
    internal static string ConnectionString => Sql.ConnectionString;

    /// <summary>Starts the SQL container, capturing any post-preflight failure for dependent tests.</summary>
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

### File: `tests/Test.Integration/Infrastructure/AzuriteContainerFixture.cs`

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
    // Pass the image explicitly (the parameterless AzuriteBuilder() ctor is [Obsolete]); pin the tag
    // to latest like every other emulator - see aspire.md section Emulator Image Pinning.
    private static readonly AzuriteContainer Azurite =
        new AzuriteBuilder("mcr.microsoft.com/azure-storage/azurite:latest").Build();

    /// <summary>Startup failure captured by <see cref="StartAsync"/>; null when the container started cleanly.</summary>
    internal static Exception? StartupError { get; private set; }

    /// <summary>Azurite connection string (blob/queue/table). Only valid once startup succeeded.</summary>
    internal static string ConnectionString => Azurite.GetConnectionString();

    /// <summary>Starts the Azurite container, capturing any post-preflight failure for dependent tests.</summary>
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

### File: `tests/Test.Integration/Infrastructure/IntegrationTestSetup.cs`

```csharp
namespace Test.Integration.Infrastructure;

using Test.Support.Hosting;

/// <summary>
/// Assembly-scoped lifecycle for the component tier. Starts the standalone store Testcontainers in
/// parallel via <c>[AssemblyInitialize]</c> and disposes them via <c>[AssemblyCleanup]</c>. A bounded Docker
/// preflight is the only inconclusive path; captured container startup failures remain red. Component tier
/// only - no Aspire graph or AppHost reference.
/// </summary>
[TestClass]
public class IntegrationTestSetup
{
    internal static string? DockerUnavailableReason { get; private set; }

    [AssemblyInitialize]
    public static async Task AssemblyInit(TestContext context)
    {
        DockerUnavailableReason = await DockerRuntimePreflight.GetUnavailableReasonAsync(
            TimeSpan.FromSeconds(10),
            context.CancellationToken);
        if (DockerUnavailableReason is not null)
            return;

        await Task.WhenAll(
            SqlContainerFixture.StartAsync(),
            AzuriteContainerFixture.StartAsync());
    }

    [AssemblyCleanup]
    public static async Task AssemblyCleanup(TestContext _)
    {
        if (DockerUnavailableReason is null)
            await Task.WhenAll(SqlContainerFixture.StopAsync(), AzuriteContainerFixture.StopAsync());
    }

    internal static bool IsUnavailable(Exception? startupError) =>
        DockerUnavailableReason is not null || startupError is not null;

    internal static void AssertAvailable(string resourceName, Exception? startupError)
    {
        if (DockerUnavailableReason is not null)
        {
            Assert.Inconclusive(DockerUnavailableReason);
            return;
        }

        if (startupError is not null)
            Assert.Fail($"{resourceName} container startup failed after Docker preflight succeeded:{Environment.NewLine}{startupError}");
    }
}
```

> Only one `[AssemblyInitialize]`/`[AssemblyCleanup]` per assembly. Add each generated store fixture's `StartAsync`/`StopAsync` to the `Task.WhenAll` calls.

---

## Repository Integration Tests

Cover **migration apply** + **CRUD against real SQL** + **child includes** + **updater navigation-add round-trip** (for entities with an `{Entity}Updater`) + **M:N junction navigation** + **tenant query filter** + **polymorphic indexes** when applicable + **paged search projection per searchable aggregate**. Build contexts via `SqlContainerFixture` and gate on `StartupError` in `[TestInitialize]`.

> **Paged search projection is required at `balanced`+ for every searchable aggregate.** Call the repo's search method (which wraps `QueryPageProjectionAsync`) for a normal `PageIndex=1, PageSize=n` request and assert **both** the returned page contents **and** `Total`. This is the only tier that catches a positional `QueryPageProjectionAsync` call - a swapped `pageSize`/`pageIndex` (near-empty page) or `includeTotal:false` (`Total = -1`) - because fake providers used in fast tiers translate the same wrong call into correct-looking results. See the "Call it with named arguments" note in [repository-template.md](repository-template.md).

> **Typed ID - assertion pitfall:** Entity `Id` is now `{Entity}Id` (a typed value struct), not `Guid`. A direct equality comparison between a `Guid` and a typed ID will not compile or silently fail. Always unwrap `.Value` when comparing a typed ID against a raw `Guid`:
> ```csharp
> // WRONG - type mismatch, will not compile
> Assert.AreEqual(categoryId, result.CategoryId);
>
> // RIGHT - unwrap the typed ID
> Assert.AreEqual(categoryId, result.CategoryId.Value);
> Assert.AreEqual(categoryId, result.CategoryId?.Value);  // nullable form
> Assert.AreNotEqual(Guid.Empty, entity.Id.Value);
> ```
>
> **Generic repo construction:** When constructing the generic repository pair directly in tests (for CRUD-only/join entities), include the typed ID parameter:
> ```csharp
> // OLD - will not compile with typed ID constraints
> var repo = new {App}RepositoryTrxn<Tag>(db);
>
> // NEW
> var repo = new {App}RepositoryTrxn<Tag, TagId>(db);
> ```
> Bespoke repos (`{Entity}RepositoryTrxn`) are constructed without type parameters - they do not change.

> **Seeding a full FK chain:** repository tests below seed a bare parent in their own unit of work
> (fine for repo-level assertions). When a test needs the **owner/tenant chain** (a row owned by a real
> user in a real tenant - e.g. anything exercising the write-identity path), use the shared
> `SqlAggregateSeeder` from `Test.Support` ([test-templates-endpoint.md](test-templates-endpoint.md)
> section SqlAggregateSeeder - conditional, generate on first need) rather than re-inlining
> tenant+user inserts per test.

### File: `tests/Test.Integration/{Entity}RepositoryIntegrationTests.cs`

```csharp
using EF.Data.Contracts;
using Microsoft.EntityFrameworkCore;
using {Project}.Application.Models;        // {Entity}Dto / {ChildEntity}Dto for the updater round-trip test
using {Project}.Domain.Model;
using {Project}.Infrastructure.Data;
using {Project}.Infrastructure.Repositories;  // {Entity}RepositoryTrxn for the updater round-trip test
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

    // Async test class -> declare the instance TestContext and flow TestContext.CancellationToken into
    // every cancellable async call (including helpers). See ../skills/testing.md Cancellation-Token discipline.
    public TestContext TestContext { get; set; } = null!;

    /// <summary>Classifies Docker unavailability separately from a SQL startup failure.</summary>
    [TestInitialize]
    public void TestSetup()
    {
        IntegrationTestSetup.AssertAvailable("SQL", SqlContainerFixture.StartupError);
    }

    [TestMethod]
    [Timeout(120000)]
    public async Task Migrations_ApplyCleanlyTwice_WithHistoryInOwnedSchema()
    {
        var ct = TestContext.CancellationToken;
        await using (var firstRun = SqlContainerFixture.CreateTrxnContext())
        {
            await firstRun.Database.MigrateAsync(ct);
        }

        // Fresh context catches unqualified history-table lookup and accidental InitialCreate replay.
        await using var db = SqlContainerFixture.CreateTrxnContext();
        await db.Database.MigrateAsync(ct);

        Assert.IsTrue(await db.Database.CanConnectAsync(ct));

        var conn = db.Database.GetDbConnection();
        await conn.OpenAsync(ct);
        await using var cmd = conn.CreateCommand();
        cmd.CommandText = "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = '{app}'";
        var tableCount = (int)(await cmd.ExecuteScalarAsync(ct))!;
        Assert.IsGreaterThanOrEqualTo(tableCount, {ExpectedTableCount},
            $"Expected >= {ExpectedTableCount} tables in {app} schema, found {tableCount}");

        cmd.CommandText = "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = '{app}' AND TABLE_NAME = '__EFMigrationsHistory'";
        var historyTableCount = (int)(await cmd.ExecuteScalarAsync(ct))!;
        Assert.AreEqual(1, historyTableCount, "Migration history table must be pinned to the owned schema");
    }

    [TestMethod]
    [Timeout(120000)]
    public async Task {Entity}_CrudOperations_WorkAgainstRealSql()
    {
        var ct = TestContext.CancellationToken;
        await using var db = SqlContainerFixture.CreateTrxnContext();
        await db.Database.MigrateAsync(ct);

        // Create
        var entity = new {Entity}Builder().WithName("Integration {Entity}").Build();
        db.{Entities}.Add(entity);
        await db.SaveChangesAsync(OptimisticConcurrencyWinner.ClientWins, cancellationToken: ct);
        var id = entity.Id;
        Assert.AreNotEqual(Guid.Empty, id.Value);  // unwrap typed ID for Guid comparison

        // Read - FindAsync takes the key array-wrapped, THEN the token (the named-arg form is a compile break).
        var fetched = await db.{Entities}.FindAsync([id], ct);
        Assert.IsNotNull(fetched);
        Assert.AreEqual("Integration {Entity}", fetched.Name);

        // Update via domain method
        fetched.Update(name: "Updated {Entity}");
        await db.SaveChangesAsync(OptimisticConcurrencyWinner.ClientWins, cancellationToken: ct);
        var updated = await db.{Entities}.FindAsync([id], ct);
        Assert.AreEqual("Updated {Entity}", updated!.Name);

        // Delete
        db.{Entities}.Remove(updated);
        await db.SaveChangesAsync(OptimisticConcurrencyWinner.ClientWins, cancellationToken: ct);
        var deleted = await db.{Entities}.FindAsync([id], ct);
        Assert.IsNull(deleted);
    }

    // The remaining methods in this class follow the same discipline: `var ct = TestContext.CancellationToken;`
    // then flow `ct` into every MigrateAsync / SaveChangesAsync / FindAsync / EF async call and any private helper.

    [TestMethod]
    [Timeout(120000)]
    public async Task {Entity}_WithChildren_PersistsCorrectly()
    {
        await using var db = SqlContainerFixture.CreateTrxnContext();
        await db.Database.MigrateAsync();

        var entity = new {Entity}Builder().WithName("Parent {Entity}").Build();
        db.{Entities}.Add(entity);
        await db.SaveChangesAsync(OptimisticConcurrencyWinner.ClientWins);

        var childResult = {ChildEntity}.Create(TenantA, entity.Id.Value, "Child body");  // unwrap typed IDs for cross-boundary factory
        db.{ChildEntities}.Add(childResult.Value!);
        await db.SaveChangesAsync(OptimisticConcurrencyWinner.ClientWins);

        var loaded = await db.{Entities}
            .Include(e => e.{ChildEntities})
            .FirstOrDefaultAsync(e => e.Id == entity.Id);

        Assert.IsNotNull(loaded);
        Assert.HasCount(1, loaded.{ChildEntities});
    }

    /// <summary>
    /// Regression guard for the <c>ValueGeneratedNever</c> key baseline (GR-16). Drives a real
    /// <c>repo.UpdateFromDto(reloadedParent, dto)</c> round-trip that adds a NEW child to an
    /// already-persisted, freshly-loaded (tracked) parent - the exact aggregate-edit path the API uses,
    /// and the ONLY path that exercises EF's add-vs-update state inference for navigation-added children.
    /// The <c>{Entity}_WithChildren_PersistsCorrectly</c> test above seeds children via
    /// <c>db.{ChildEntities}.Add(...)</c>, which inserts them directly and bypasses this inference -
    /// it cannot catch a missing/regressed baseline. Here the insert succeeds only because
    /// <c>EntityBase.Id</c> is <c>ValueGeneratedNever</c> (EntityBaseConfiguration): EF treats the
    /// client-set Guid v7 key as application-assigned and infers the navigation-add as Added. Drop that
    /// baseline (or add a child whose config skips <c>base.Configure</c>) and the save throws
    /// <c>DbUpdateConcurrencyException</c> (UPDATE against a non-existent row).
    /// </summary>
    [TestMethod]
    [Timeout(120000)]
    public async Task {Entity}_UpdateFromDto_AddsChildToReloadedParent_AgainstRealSql()
    {
        {Entity}Id parentId;  // typed ID - not Guid

        // Seed a bare parent in its own unit of work.
        await using (var seed = SqlContainerFixture.CreateTrxnContext())
        {
            await seed.Database.MigrateAsync();
            var seeded = new {Entity}Builder().WithName("Updater Parent").Build();
            seed.{Entities}.Add(seeded);
            await seed.SaveChangesAsync(OptimisticConcurrencyWinner.ClientWins);
            parentId = seeded.Id;
        }

        // Reload the persisted parent (tracked, children included) in a fresh context - the handler/service path.
        await using var db = SqlContainerFixture.CreateTrxnContext();
        var loaded = await db.{Entities}
            .Include(e => e.{ChildEntities})
            .FirstAsync(e => e.Id == parentId);

        // Desired-state DTO carries a NEW child (no Id -> create path). The DTO collection property
        // mirrors the entity navigation; fill the child's required fields for your domain.
        // DTOs still carry Guid - unwrap typed ID with .Value when populating DTO fields.
        var dto = new {Entity}Dto
        {
            Id = parentId.Value,
            Name = "Updater Parent",
            {ChildEntities} = [new {ChildEntity}Dto { /* required fields */ {Entity}Id = parentId.Value }]
        };

        var repo = new {Entity}RepositoryTrxn(db);
        var sync = repo.UpdateFromDto(loaded, dto, RelatedDeleteBehavior.RelationshipAndEntity);
        Assert.IsTrue(sync.IsSuccess, $"UpdateFromDto failed: {sync.ErrorMessage}");

        // Inserts the navigation-added child. Throws here if the ValueGeneratedNever baseline is missing.
        await db.SaveChangesAsync(OptimisticConcurrencyWinner.ClientWins);

        // Confirm the child persisted via a clean reload.
        await using var verify = SqlContainerFixture.CreateTrxnContext();
        var reloaded = await verify.{Entities}
            .Include(e => e.{ChildEntities})
            .FirstAsync(e => e.Id == parentId);
        Assert.HasCount(1, reloaded.{ChildEntities});
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

        var bridge = {Entity}Tag.Create(TenantA, entity.Id.Value, tag.Id.Value);  // unwrap typed IDs for cross-boundary factory
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
| `{Entity}_WithChildren_PersistsCorrectly` | Entity has owned/dependent child collections (1:N). Persistence + includes only - seeds children via `db.{ChildEntities}.Add(...)`, so it does NOT exercise the updater/navigation-add path (see next row). |
| `{Entity}_UpdateFromDto_AddsChildToReloadedParent_AgainstRealSql` | Entity has owned/dependent child collections (1:N) **and** an `{Entity}Updater`. Required regression guard for the `ValueGeneratedNever` key baseline (GR-16) - the only test that adds a NEW child through `repo.UpdateFromDto` against real SQL. A green `WithChildren_PersistsCorrectly` does not substitute for it. |
| `{Entity}Tag_ManyToMany_WorksCorrectly` | Entity participates in M:N via a junction. |
| `TenantQueryFilter_RestrictsResults_WhenTenantIdSet` | `enableMultiTenant: true`. |
| `Polymorphic_Index_Exists` | Entity uses a polymorphic ownership pattern (e.g., `Attachment.OwnerType` + `OwnerId`). |

---

## Audit Repository (Azurite) Test

Validates `AuditLogRepository.AppendAsync` against real Azurite Table Storage (partition key, row key shape, round-trip metadata). Component tier - it exercises only Azurite via `AzuriteContainerFixture`, no API and no Function.

### File: `tests/Test.Integration/AuditLogRepositoryAzuriteTests.cs`

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
    public TestContext TestContext { get; set; } = null!;

    /// <summary>Classifies Docker unavailability as Inconclusive and post-preflight startup failure as red.</summary>
    [TestInitialize]
    public void TestSetup()
    {
        IntegrationTestSetup.AssertAvailable("Azurite", AzuriteContainerFixture.StartupError);
    }

    [TestMethod]
    [Timeout(300000)]
    public async Task Given_AuditEntry_When_AppendAsyncToAzurite_Then_TableEntityPersistedWithExpectedKeys()
    {
        var ct = TestContext.CancellationToken;  // flow the test token, not CancellationToken.None

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

### File: `tests/Test.Integration/DomainEventPipelineTests.cs`

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

    // Instance TestContext (per-test cancellation) is separate from the static ClassInitialize parameter
    // below - both coexist. See ../skills/testing.md Cancellation-Token discipline.
    public TestContext TestContext { get; set; } = null!;

    [ClassInitialize]
    public static async Task ClassInit(TestContext context)
    {
        if (IntegrationTestSetup.IsUnavailable(SqlContainerFixture.StartupError))
            return;
        await using var db = SqlContainerFixture.CreateTrxnContext();
        await db.Database.MigrateAsync(context.CancellationToken);
    }

    /// <summary>Classifies Docker unavailability separately from a SQL startup failure.</summary>
    [TestInitialize]
    public void TestSetup()
    {
        IntegrationTestSetup.AssertAvailable("SQL", SqlContainerFixture.StartupError);
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

### File: `tests/Test.Integration/Test.Integration.csproj`

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
    <ProjectReference Include="..\..\src\Application\{Project}.Application.Contracts\{Project}.Application.Contracts.csproj" />
    <ProjectReference Include="..\..\src\Application\{Project}.Application.Services\{Project}.Application.Services.csproj" />
    <ProjectReference Include="..\..\src\Infrastructure\{Project}.Infrastructure.Data\{Project}.Infrastructure.Data.csproj" />
    <ProjectReference Include="..\..\src\Infrastructure\{Project}.Infrastructure.Repositories\{Project}.Infrastructure.Repositories.csproj" />
    <ProjectReference Include="..\..\src\Infrastructure\{Project}.Infrastructure.Storage\{Project}.Infrastructure.Storage.csproj" />
  </ItemGroup>
</Project>
```

> **No `AppHost` / `Aspire.Hosting.Testing` reference.** Those belong only to `Test.Aspire`. Add `Testcontainers.Redis` when a `RedisContainerFixture` is generated.

---

## Verification

- [ ] `Test.Integration` references **no** `AppHost` and **no** `Aspire.Hosting.Testing` - component tier only.
- [ ] One standalone fixture per store under `Infrastructure/`; each captures `StartupError` instead of aborting discovery.
- [ ] One `IntegrationTestSetup` owns bounded Docker preflight plus the sole `[AssemblyInitialize]`/`[AssemblyCleanup]`, then starts fixtures in parallel only after preflight succeeds.
- [ ] Every test marks failed Docker preflight `Inconclusive`; a captured store startup failure after successful preflight fails with the full exception.
- [ ] Component tests instantiate the class under test directly against a fixture connection string - no `CreateHttpClient`, no `WaitForResourceHealthyAsync`, no `DistributedApplicationTestingBuilder`.
- [ ] `Migrations_ApplyCleanly_ToSqlContainer` exists exactly once per assembly (not per entity).
- [ ] Tenant query filter test exists when `enableMultiTenant: true`; M:N test exists when entity uses a junction.
- [ ] Every test class has a class-level `<summary>` declaring tier (component) + store.
- [ ] Running `Test.Integration` boots **no** Aspire graph (no `DistributedApplicationTestingBuilder` log lines).
- [ ] No fixture or test performs a manual `docker rm`/`docker container prune` sweep; per-run cleanup is left to each fixture's `DisposeAsync` plus the Testcontainers reaper (`org.testcontainers.session-id`).

---

**TaskFlow proof (local):**
- `../AI-Instructions-ReferenceApp/tests/Test.Integration/Infrastructure/SqlContainerFixture.cs`
- `../AI-Instructions-ReferenceApp/tests/Test.Integration/Infrastructure/AzuriteContainerFixture.cs`
- `../AI-Instructions-ReferenceApp/tests/Test.Integration/Infrastructure/IntegrationTestSetup.cs`
- `../AI-Instructions-ReferenceApp/tests/Test.Integration/MigrationAndRepositoryTests.cs`
- `../AI-Instructions-ReferenceApp/tests/Test.Integration/AuditLogRepositoryAzuriteTests.cs`
- `../AI-Instructions-ReferenceApp/tests/Test.Integration/DomainEventPipelineTests.cs`

**TaskFlow proof (remote fallback):**
<https://github.com/efreeman518/AI-Instructions-ReferenceApp/tree/main/tests/Test.Integration>
