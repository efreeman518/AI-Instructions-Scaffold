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

### Data Migrations

Migration files should contain schema changes only. Use one-time background jobs for non-trivial backfill and use `migrationBuilder.Sql()` only for simple, safe updates.

### Applying Migrations at Startup

For development/local environments, apply pending EF migrations automatically during host startup. Guard with a connection string check so the host doesn't crash when DB is unavailable:

```csharp
var connStr = builder.Configuration.GetConnectionString("{Project}DbContextTrxn");
if (!string.IsNullOrEmpty(connStr))
{
    using var scope = app.Services.CreateScope();
    var factory = scope.ServiceProvider.GetRequiredService<IDbContextFactory<{Project}DbContextTrxn>>();
    await using var db = await factory.CreateDbContextAsync();
    await db.Database.MigrateAsync();
}
```

Alternatively, use the `IStartupTask` pattern from [bootstrapper.md](../skills/bootstrapper.md).

> **Production:** Prefer idempotent migration scripts or CI pipeline-applied migrations over runtime `MigrateAsync`.

### Third-Party Operational Store Schemas

Libraries like TickerQ, Hangfire, or Quartz may use their own EF DbContext for operational tables but do not ship bundled EF migrations. In this case:

1. `MigrateAsync()` is a no-op (no migrations to apply).
2. `EnsureCreatedAsync()` is a no-op when the database already exists from another context's migrations.
3. Use `GenerateCreateScript()` + batch execution with existence check:

```csharp
var conn = db.Database.GetDbConnection();
await conn.OpenAsync();
await using var cmd = conn.CreateCommand();
cmd.CommandText = "SELECT CASE WHEN EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = '{schema}' AND TABLE_NAME = '{PrimaryTable}') THEN 1 ELSE 0 END";
var result = await cmd.ExecuteScalarAsync();
await conn.CloseAsync();

if (result is not (int)1)
{
    var script = db.Database.GenerateCreateScript();
    var batches = Regex.Split(script, @"^\s*GO\s*$", RegexOptions.Multiline | RegexOptions.IgnoreCase)
        .Where(b => !string.IsNullOrWhiteSpace(b));
    foreach (var batch in batches)
    {
        await db.Database.ExecuteSqlRawAsync(batch);
    }
}
```

Key points:
- **Always check existence first** - running CREATE statements against existing tables produces `fail:` log spam on every restart with persistent volumes.
- `ExecuteSqlRawAsync` cannot handle `GO` batch separators - split first.
- Swallowing all exceptions in a catch-all hides real failures; prefer the existence check pattern.

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
