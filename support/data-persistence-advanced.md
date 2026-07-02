# Data Persistence - Advanced

Load this file only when the current task needs design-time factory setup, migration strategy, JSON column troubleshooting, startup seeding, or zero-downtime schema change guidance.

Core read/write repository and EF configuration guidance stays in [../skills/data-persistence.md](../skills/data-persistence.md).

---

## Design-Time Factory

Use `IDesignTimeDbContextFactory<T>` for CLI migrations. Two factories - one per context - each sets `AuditId` and `TenantId` for the `DbContextBase` tenant filter and audit infrastructure.

```csharp
[ExcludeFromCodeCoverage]
public class DesignTimeDbContextFactoryTrxn : IDesignTimeDbContextFactory<{Project}DbContextTrxn>
{
    public {Project}DbContextTrxn CreateDbContext(string[] args)
    {
        var connectionString = Environment.GetEnvironmentVariable("EFCORETOOLSDB")
            ?? throw new InvalidOperationException("Set EFCORETOOLSDB env var");

        var optionsBuilder = new DbContextOptionsBuilder<{Project}DbContextTrxn>();
        optionsBuilder.UseSqlServer(connectionString, sql => sql.UseCompatibilityLevel(170));

        var context = new {Project}DbContextTrxn(optionsBuilder.Options);
        context.AuditId = "design-time";
        context.TenantId = Guid.Empty;
        return context;
    }
}

[ExcludeFromCodeCoverage]
public class DesignTimeDbContextFactoryQuery : IDesignTimeDbContextFactory<{Project}DbContextQuery>
{
    public {Project}DbContextQuery CreateDbContext(string[] args)
    {
        var connectionString = Environment.GetEnvironmentVariable("EFCORETOOLSDB")
            ?? throw new InvalidOperationException("Set EFCORETOOLSDB env var");

        var optionsBuilder = new DbContextOptionsBuilder<{Project}DbContextQuery>();
        optionsBuilder.UseSqlServer(connectionString, sql => sql.UseCompatibilityLevel(170));

        var context = new {Project}DbContextQuery(optionsBuilder.Options);
        context.AuditId = "design-time";
        context.TenantId = Guid.Empty;
        return context;
    }
}
```

> **Why two factories?** EF CLI uses `IDesignTimeDbContextFactory<T>` - each context type needs its own factory. Both must set `AuditId`/`TenantId` because `DbContextBase` uses these for tenant query filters and audit interceptor.
> **Why `[ExcludeFromCodeCoverage]`?** Design-time factories are only invoked by EF CLI tooling, never in production code paths.

---

## JSON Columns (`ToJson()`) Troubleshooting

`ToJson()` with owned types is the preferred pattern for structured data stored as JSON in SQL Server. EF Core may still fail to generate migrations for complex graphs with nested collections or dictionaries.

Fallback: use a serializer-backed value conversion to `nvarchar(max)` with a custom `ValueComparer`.

```csharp
builder.Property(e => e.ComplexData)
    .HasConversion(
        v => JsonSerializer.Serialize(v, (JsonSerializerOptions?)null),
        v => JsonSerializer.Deserialize<ComplexType>(v, (JsonSerializerOptions?)null)!)
    .HasColumnType("nvarchar(max)")
    .Metadata.SetValueComparer(
        new ValueComparer<ComplexType>(
            (a, b) => JsonSerializer.Serialize(a, (JsonSerializerOptions?)null) == JsonSerializer.Serialize(b, (JsonSerializerOptions?)null),
            v => JsonSerializer.Serialize(v, (JsonSerializerOptions?)null).GetHashCode(),
            v => JsonSerializer.Deserialize<ComplexType>(JsonSerializer.Serialize(v, (JsonSerializerOptions?)null), (JsonSerializerOptions?)null)!));
```

If you use this fallback, record it in `HANDOFF.md` and repo docs. Do not hand-edit migration files to work around `ToJson()` failures.

---

## Migrations

### EF CLI Prerequisites

Before running any migration command, ensure `dotnet ef` is available. Prefer repo-local tooling for reproducibility; an existing user-global install is acceptable.

```powershell
dotnet ef --version
dotnet new tool-manifest
dotnet tool install dotnet-ef
```

The startup project must reference `Microsoft.EntityFrameworkCore.Design`.

If `nuget.config` uses `<packageSourceMapping>`, add an explicit entry for `dotnet-ef` under `nuget.org`.

### Migration Naming

Format: `YYYYMMDD_Description`.

```text
20260301_InitialCreate
20260305_AddCategoryColorHex
20260310_AddTodoItemPriority
```

Never rename a migration after it has been shared with any environment or teammate.

### Canonical Commands

```powershell
$env:EFCORETOOLSDB = "Server=..."

dotnet ef migrations add {MigrationName} `
  --project src/Infrastructure/{Project}.Infrastructure.Data `
  --startup-project src/Host/{Host}.Api `
  --context {App}DbContextTrxn

dotnet ef database update `
  --project src/Infrastructure/{Project}.Infrastructure.Data `
  --startup-project src/Host/{Host}.Api `
  --context {App}DbContextTrxn

dotnet ef migrations script --idempotent `
  --project src/Infrastructure/{Project}.Infrastructure.Data `
  --startup-project src/Host/{Host}.Api `
  --context {App}DbContextTrxn `
  -o migrations.sql
```

### Mapping-Foundation Neutrality Gate

After any refactor to typed-ID or value-object mapping, verify that the runtime model is schema-neutral before adding or regenerating migrations:

```powershell
dotnet ef migrations has-pending-model-changes `
  --project src/Infrastructure/{Project}.Infrastructure.Data `
  --startup-project src/Host/{Host}.Api `
  --context {App}DbContextTrxn
```

Use the same `--project` / `--startup-project` rooting that real migrations use. If the Data project itself carries the design-time factory and `Microsoft.EntityFrameworkCore.Design`, you may run with the Data project as startup instead. The result must be `No changes`. If EF reports pending model changes, reconcile the moved facet (max length, nullability, default value, column type, FK shape) in configuration. Do not blind-regenerate a migration for a mapping-foundation refactor.

### Data Migrations

Migration files should contain schema changes only. Use one-time background jobs for non-trivial backfill and use `migrationBuilder.Sql()` only for simple, safe updates.

### Migration Ownership: Dedicated Migrator Host

**Canonical owner for migration execution.** Exactly one process owns schema: `src/Host/{App}.DatabaseMigrator`, a console host in the solution (plus a Dockerfile when the app deploys containers). Runtime hosts (API, Scheduler, Functions, workers, Gateway) never call `Database.MigrateAsync`, create schemas, or patch tables at startup. Scaled-out instances race DDL, runtime identities would need broad permissions, and startup failure modes become uncontrollable.

Runner primitives ship in EF.Data (`EF.Data.Migrations` namespace): `AddDatabaseMigrationRunner()`, `AddEfCoreMigrationTarget<TContext>(logicalName, order)`, `DatabaseMigrationRunner.RunAsync()`. Each target resolves `IDbContextFactory<TContext>` - register target contexts with `AddDbContextFactory` (the `Add{App}MigrationDbContexts` helper's job), never plain `AddDbContext`.

Sub-phase split: Phase 5a creates the initial migration files (the schema artifact); the migrator host project and the AppHost `WaitForCompletion` wiring are generated in 5b with the rest of runtime orchestration.

```csharp
var builder = Host.CreateApplicationBuilder(args);
builder.AddServiceDefaults();
builder.Services
    .AddDatabaseMigrationRunner()
    .Add{App}MigrationDbContexts(builder.Configuration)  // migrator-local context factories
    // Deterministic order: app schema first, then FlowEngine, then Scheduler/TickerQ.
    .AddEfCoreMigrationTarget<{App}DbContextTrxn>("{App}DbContextTrxn", 10)
    .AddEfCoreMigrationTarget<{App}FlowEngineDbContext>("{App}FlowEngineDbContext", 20)
    .AddEfCoreMigrationTarget<{App}TickerQDbContext>("{App}TickerQDbContext", 30);

using var host = builder.Build();
using var scope = host.Services.CreateScope();
await scope.ServiceProvider.GetRequiredService<DatabaseMigrationRunner>().RunAsync();
```

Rules:

- **Fail fast.** Each target logs its database + context before migrating. An unhandled failure terminates the process with nonzero exit; later targets do not run. No catch-and-ignore, no retry loops around migration ownership.
- **Migrator-only timeouts.** Long SQL command timeouts belong only in the migrator's DbContext registrations. Do not copy migration timeout defaults into API, Scheduler, Functions, or any request-path registration.
- **Schema + history isolation.** Each context keeps its own schema and migrations history table (`sql.MigrationsHistoryTable(name, schema)`), even when local Aspire maps every logical connection to one physical database. Design-time factories must match the runner configuration exactly: schema, history table, migrations assembly, provider, SQL compatibility level. Add or update the design-time factory whenever a migration target is added.
- **Stable logical connection names.** One name per logical store: `{App}DbContextTrxn`, `{App}DbContextQuery`, `{App}FlowEngineDbContext`, `{ThirdPartyStore}DbContext`. Development config may point them all at one local database; Azure splits physical databases later through configuration only, never runtime code. Hosts fail fast when a required connection string is missing; do not infer one logical store from another (the only deliberate fallback lives in migrator-only registration).
- **Data movement is a deployment unit.** Pre/post-schema steps (C# steps needing EF services, or SQL steps for staging, backfill, compatibility copies, cleanup) run inside the migrator as ordered work, never hidden in runtime hosted services. Data that must survive between steps lives in durable staging tables in the migration schema, dropped when the migration completes - do not rely on temp tables surviving across connections.

Orchestration:

- **Local Aspire:** AppHost adds the migrator project against the same local SQL resource; every runtime host declares `.WaitForCompletion(migrator)`. One SQL resource, one physical database, multiple schemas + logical connection names - do not require multiple local SQL containers because production may split databases later.
- **Azure:** deploy infrastructure -> run the migrator once (Container Apps Job: manual trigger, parallelism `1`, replica completion count `1`, retry limit `0` unless the migration is provably restart-safe, timeout sized for data movement; the pipeline polls the job execution to terminal status) -> deploy or start runtime apps. Deployment workflow gates every runtime deploy job on migration success. Non-container hosting follows the same order: single migrator run before runtime rollout. See [cicd.md](../skills/cicd.md) section Production DB Migration (Migrator Job).
- **Identity split.** The migrator identity gets schema DDL + migration-history permissions. Runtime identities get least-privilege DML and no DDL. Entra-auth SQL connection strings do not create contained database users or grants - infra either wires SQL data-plane identities explicitly or carries a clear comment that SQL identities are not wired.

Tests (proportional to blast radius): unit tests for target ordering and fail-fast (later targets skipped after a failure); SQL integration tests applying all targets to a fresh database and running the migrator twice for idempotency; third-party schema validation failing when the schema is missing; an Aspire topology test proving runtime hosts wait on migrator completion. SQL-container tests report `Assert.Inconclusive(...)` when the container cannot start - never silently pass. Integration/E2E fixtures prepare the database explicitly (direct `MigrateAsync` in test setup) before booting runtime hosts.

**TaskFlow proof:** `src/Host/TaskFlow.DatabaseMigrator/Program.cs` (ordered targets, migrator-only timeouts, per-target history tables), `src/Host/Aspire/AppHost/AppHost.cs` (`WaitForCompletion`), `infra/modules/container-app-job.bicep` + `.github/workflows/deploy.yml` (one-shot job gating runtime rollout), `src/Test/Test.Unit/Infrastructure/DatabaseMigrationRunnerTests.cs`.

### Third-Party Operational Store Schemas

Libraries like TickerQ, Hangfire, or Quartz persist operational tables through their own EF model but do not ship bundled migrations. Give each an app-owned migration context; never let runtime startup auto-create or patch third-party schema, and keep any library `AutoCreateSchema`/deployment-script feature off in production.

Shape (TickerQ example):

- `{App}TickerQDbContext` - app-owned context exposing the library's model, with a dedicated schema (`Scheduler`) and history table (`Scheduler.__EFMigrationsHistory_TickerQ`).
- Generated migrations live under a separate folder (`Migrations/TickerQ`) with an explicit migrations assembly, so third-party operational schema never mixes with app domain migrations.
- Registered as an ordered target in the migrator host (see <Migration Ownership: Dedicated Migrator Host>); the design-time factory matches the target configuration.
- The scheduler host validates required tables exist at startup and fails fast when missing - it does not create them. The scheduler uses its own logical operational-store connection string; app domain connection strings stay reserved for domain work.
- Prefer an explicit app-owned context name over a library-provided context name - upstream design-time context discovery is unreliable in fresh projects. Prove `dotnet ef migrations add` plus a real SQL apply before treating the integration as done.

**TaskFlow proof:** `src/Infrastructure/TaskFlow.Infrastructure.Data/TaskFlowTickerQDbContext.cs`, `TaskFlowTickerQSchemaValidator.cs`, `Migrations/TickerQ/`, scheduler validation in `src/Host/TaskFlow.Scheduler/RegisterSchedulerServices.cs`.

### Zero-Downtime Schema Changes

Use expand/contract:

1. Expand: add nullable/defaulted shape, deploy code that writes both old and new.
2. Backfill: migrate existing data.
3. Contract: remove old shape in a later deployment.

Never combine expand and contract in one deployment.

### Rollback Strategy

Development:

```powershell
dotnet ef database update {PreviousMigrationName} `
  --context {App}DbContextTrxn
```

Production:

- Use idempotent forward-only scripts.
- Prefer blue-green deployment.
- Never delete a migration applied to any shared environment.

### Multi-Store Consistency

For SQL + Cosmos/Table hybrids:

1. EF migrations apply to SQL only.
2. Document stores evolve through code and defaults.
3. Deploy tolerant code before the SQL migration.

---

## Startup Seeding / Reference Data

Use the `IStartupTask` pattern for idempotent seed data after `app.Build()` and before `app.RunAsync()`.

```csharp
public class SeedReferenceDataTask : IStartupTask
{
    private readonly IDbContextFactory<{App}DbContextTrxn> _factory;

    public SeedReferenceDataTask(IDbContextFactory<{App}DbContextTrxn> factory)
        => _factory = factory;

    public async Task ExecuteAsync(CancellationToken ct)
    {
        await using var db = await _factory.CreateDbContextAsync(ct);

        var existing = (await db.Set<{Entity}>()
            .Where(e => e.IsSystem)
            .Select(e => e.Id)
            .ToListAsync(ct)).ToHashSet();

        var seeds = {Entity}Seeds.All
            .Where(s => !existing.Contains(s.Id));

        foreach (var seed in seeds)
        {
            db.Set<{Entity}>().Add(seed);
        }

        await db.SaveChangesAsync(true, ct);
    }
}
```

Seeding rules:

- Seed deterministically with fixed GUIDs.
- Check existence before insert.
- Mark seeded rows with `IsSystem = true`.
- Register startup tasks in dependency order.
- Seed a well-known dev user and dev tenant with fixed compile-time GUID constants on the existing
  `SeedConstants` holder (`SeedConstants.DevUserId`, `SeedConstants.DevTenantId`). The dev write-identity
  seam stamps `SeedConstants.DevUserId` as the owner and `ScaffoldAuthHandler` emits both as claims, so
  UI-driven creates resolve the user/tenant FK with no runtime lookup. Never seed the dev principal with a random Guid -
  a random id forces a lookup and breaks the stamped FK. See
  [../patterns/api-host-wiring.md](../patterns/api-host-wiring.md) section Dev-Mode Write Identity and
  [../skills/identity-management.md](../skills/identity-management.md) section Claim-type contract.

---

## Load This File When

- You are running `dotnet ef` commands.
- You need design-time factory guidance.
- A JSON-column mapping fails during migration generation.
- You are planning expand/contract schema changes.
- You need startup seeding patterns.
