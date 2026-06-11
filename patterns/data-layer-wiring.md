# Data Layer Wiring Patterns

Cross-project wiring for database context setup, startup tasks, migrations, and seed data. Load before Phase 5a (Foundation) and Phase 5b (App Core).

For base types used here (`DbContextBase`, `DbContextScopedFactory`, `AuditInterceptor`, `IStartupTask`), see [../support/ef-packages-reference.md](../support/ef-packages-reference.md).

---

## Database Context Pooling & Scoped Wrappers

**Source:** `{App}.Bootstrapper/Registration/RegisterServices.Database.cs`

Dual-context registration: pooled factories for Trxn and Query contexts, `DbContextScopedFactory` wrappers for scoped resolution, audit interceptor on Trxn only, `ConnectionNoLockInterceptor` on both, Azure vs local SQL detection, `ReadOnly` intent injection for Query.

Set all SQL Server and Azure SQL EF registrations to compatibility level 170. This is SQL Server 2025 compatibility and enables native JSON type support, vector data types, and related indexing features.

### DbSet Declarations

Declare all DbSets in the **abstract base context**, not in the concrete Trxn/Query contexts. Use auto-property syntax with `null!` initializer:

```csharp
public abstract class {App}DbContextBase(DbContextOptions options)
    : DbContextBase<string, Guid?>(options)
{
    public DbSet<{Entity}> {Entity}s { get; set; } = null!;
    public DbSet<{ChildEntity}> {ChildEntity}s { get; set; } = null!;
    // ... all entity DbSets here
}
```

> **Do NOT** use the expression-body `=> Set<T>()` pattern - it creates a new `DbSet` instance on every access and defeats EF's internal caching.

### Registration

```csharp
private static void AddDatabaseServices(IServiceCollection services, IConfiguration config)
{
    // Repository registrations. Under repositoryContractStyle: hybrid/generic-only, register the
    // open-generic pair ONCE (serves every generic-coverable entity via the closed-over-context
    // subclasses) and add bespoke repos only where read/write logic earns a per-aggregate contract.
    services.AddScoped(typeof(IRepositoryTrxn<>), typeof({App}RepositoryTrxn<>));
    services.AddScoped(typeof(IRepositoryQuery<>), typeof({App}RepositoryQuery<>));
    services.AddScoped<I{Entity}RepositoryQuery, {Entity}RepositoryQuery>();   // bespoke only
    services.AddScoped<I{Root}RepositoryTrxn, {Root}RepositoryTrxn>();         // ALWAYS for aggregate roots with owned children (GR-15), even under generic-only
    // (repositoryContractStyle: per-entity - omit the open generics and register a pair per entity.)

    // Interceptors
    services.AddTransient<AuditInterceptor<string, Guid?>>();
    services.AddTransient<ConnectionNoLockInterceptor>();

    ConfigureDatabaseContexts(services, config);
}
```

**Dual pooled context wiring:**

```csharp
private static void ConfigureSqlDatabase(IServiceCollection services,
    string dbConnectionStringTrxn, string dbConnectionStringQuery)
{
    // -- TRXN context: audit interceptor + exception processor
    services.AddPooledDbContextFactory<{App}DbContextTrxn>((sp, options) =>
    {
        ConfigureTrxnDbContext(options, dbConnectionStringTrxn);
        var auditInterceptor = sp.GetRequiredService<AuditInterceptor<string, Guid?>>();
        options.UseExceptionProcessor().AddInterceptors(auditInterceptor);
    });
    services.AddScoped<DbContextScopedFactory<{App}DbContextTrxn, string, Guid?>>();
    services.AddScoped(sp => sp.GetRequiredService<DbContextScopedFactory<{App}DbContextTrxn, string, Guid?>>()
        .CreateDbContext());

    // -- QUERY context: no audit interceptor, no-tracking, ReadOnly intent
    services.AddPooledDbContextFactory<{App}DbContextQuery>((sp, options) =>
    {
        ConfigureQueryDbContext(options, dbConnectionStringQuery);
        options.UseExceptionProcessor();
    });
    services.AddScoped<DbContextScopedFactory<{App}DbContextQuery, string, Guid?>>();
    services.AddScoped(sp => sp.GetRequiredService<DbContextScopedFactory<{App}DbContextQuery, string, Guid?>>()
        .CreateDbContext());
}
```

**Azure vs local detection + ReadOnly intent for Query:**

```csharp
private static void ConfigureSqlOptions(DbContextOptionsBuilder options, string connectionString)
{
    if (connectionString.Contains("database.windows.net"))
    {
        options.UseAzureSql(connectionString, sqlOptions =>
        {
            sqlOptions.UseCompatibilityLevel(170);
            sqlOptions.EnableRetryOnFailure(maxRetryCount: 5,
                maxRetryDelay: TimeSpan.FromSeconds(30), errorNumbersToAdd: null);
        });
    }
    else
    {
        options.UseSqlServer(connectionString, sqlOptions =>
        {
            sqlOptions.UseCompatibilityLevel(170);
            sqlOptions.EnableRetryOnFailure(maxRetryCount: 5,
                maxRetryDelay: TimeSpan.FromSeconds(30), errorNumbersToAdd: null);
        });
    }
}

private static void ConfigureQueryDbContext(DbContextOptionsBuilder options, string connectionString)
{
    var readOnlyConnectionString = connectionString.Contains("ApplicationIntent=")
        ? connectionString
        : connectionString + ";ApplicationIntent=ReadOnly";
    options.UseQueryTrackingBehavior(QueryTrackingBehavior.NoTracking);
    ConfigureSqlOptions(options, readOnlyConnectionString);
}
```

---

## DbContext OnModelCreating Order

**Source:** `Infrastructure.Data/{App}DbContextBase.cs`

The base context inherits from `DbContextBase<string, Guid?>` (from EF.Data). `OnModelCreating` must follow this exact call order:

```csharp
public abstract class {App}DbContextBase(DbContextOptions options)
    : DbContextBase<string, Guid?>(options)
{
    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        base.OnModelCreating(modelBuilder);                                      // 1. Base class config

        modelBuilder.HasDefaultSchema("{schemaName}");                           // 2. Default schema

        modelBuilder.ApplyConfigurationsFromAssembly(                            // 3. All IEntityTypeConfiguration<T>
            typeof({App}DbContextBase).Assembly);

        ConfigureDefaultDataTypes(modelBuilder);                                 // 4. Global type defaults
        SetTableNames(modelBuilder);                                             // 5. Table naming convention
        ConfigureTenantQueryFilters(modelBuilder);                               // 6. Tenant filters
    }
```

**Dynamic tenant query filter** -- applied to every entity implementing `ITenantEntity<Guid>`:

```csharp
    private void ConfigureTenantQueryFilters(ModelBuilder modelBuilder)
    {
        var tenantEntityClrTypes = modelBuilder.Model.GetEntityTypes()
            .Where(entityType => typeof(ITenantEntity<Guid>).IsAssignableFrom(entityType.ClrType))
            .Select(entityType => entityType.ClrType);

        foreach (var clrType in tenantEntityClrTypes)
        {
            var filter = BuildTenantFilter(clrType);   // from DbContextBase -- uses IRequestContext.TenantId
            modelBuilder.Entity(clrType).HasQueryFilter(filter);
        }
    }
```

**Global decimal and datetime2 defaults:**

```csharp
    private static void ConfigureDefaultDataTypes(ModelBuilder modelBuilder)
    {
        foreach (var entityType in modelBuilder.Model.GetEntityTypes())
        {
            foreach (var property in entityType.GetProperties())
            {
                // All decimals -> decimal(10,4) unless explicitly overridden
                if (property.ClrType == typeof(decimal) || property.ClrType == typeof(decimal?))
                {
                    if (property.GetPrecision() is null)
                        property.SetPrecision(10);
                    if (property.GetScale() is null)
                        property.SetScale(4);
                }

                // All DateTime -> datetime2
                if (property.ClrType == typeof(DateTime) || property.ClrType == typeof(DateTime?))
                {
                    property.SetColumnType("datetime2");
                }
            }
        }
    }
```

**Singular table names (class name = table name, skip owned types):**

```csharp
    private static void SetTableNames(ModelBuilder modelBuilder)
    {
        foreach (var entityType in modelBuilder.Model.GetEntityTypes())
        {
            if (entityType.IsOwned()) continue;     // owned types share parent table
            entityType.SetTableName(entityType.ClrType.Name);  // singular, matches class name
        }
    }
```

---

## Startup Tasks

`IStartupTask` (from EF.Common.Contracts) is the interface for tasks that run after `builder.Build()` but before the host accepts requests. `app.RunStartupTasks()` (from EF.Host) resolves and executes all registered implementations in order.

### Registration

```csharp
public static partial class RegisterServices
{
    private static void AddStartupTasks(IServiceCollection services)
    {
        services.AddTransient<IStartupTask, ApplyEFMigrationsStartup>();
        services.AddTransient<IStartupTask, WarmupDependencies>();
        services.AddTransient<IStartupTask, LoadCacheStartup>();
    }
}
```

### Example: Cache Warming

```csharp
public class LoadCacheStartup(
    IConfiguration config,
    ILogger<LoadCacheStartup> logger,
    IFusionCacheProvider cache,
    IRepositoryQuery<{Entity}> repoQuery) : IStartupTask
{
    public async Task ExecuteAsync(CancellationToken cancellationToken = default)
    {
        logger.LogInformation("Startup LoadCache Start");
        // Use FusionCache to preload hot data from repoQuery
        await Task.CompletedTask;
        logger.LogInformation("Startup LoadCache Finish");
    }
}
```

### Example: Seed Data (Local Development)

```csharp
public class SeedDataTask(
    IDbContextFactory<{App}DbContextTrxn> factory,
    IHostEnvironment env,
    ILogger<SeedDataTask> logger) : IStartupTask
{
    public async Task ExecuteAsync(CancellationToken ct = default)
    {
        if (!env.IsDevelopment()) return;

        using var db = await factory.CreateDbContextAsync(ct);
        if (await db.Set<{Entity}>().AnyAsync(ct)) return; // already seeded

        db.Add({Entity}.Create("Sample {Entity}", SeedConstants.DevTenantId));
        await db.SaveChangesAsync(ct);
        logger.LogInformation("Seed data applied for local development.");
    }
}
```

**Rules:**
- Guard with `AnyAsync` - idempotent, safe on repeat runs.
- Gate dev-only tasks with `IHostEnvironment.IsDevelopment()`.
- Use deterministic IDs for dev tenant (`SeedConstants.DevTenantId`) so tests can reference them.

---

## Scaffold Migration Strategy

> **Greenfield only (GR-13):** This remove/recreate strategy applies to a fresh `/scaffold` build. `/scaffold-adopt` and `/vertical-slice` run against an established app and MUST preserve existing migration history - add an additive migration (`dotnet ef migrations add <Change>`) instead of removing. Do not run `migrations remove --force` in those flows.

During a greenfield scaffold, the database schema is evolving rapidly. Use a single clean `InitialCreate` migration - do not accumulate incremental migrations.

**Rule (greenfield):** Before creating a migration, remove any existing migrations first:

```powershell
# Remove all existing migrations
dotnet ef migrations remove --force `
  --project src/Infrastructure/{Project}.Infrastructure.Data `
  --startup-project src/Host/{Host}.Api

# Create a fresh baseline
dotnet ef migrations add InitialCreate `
  --project src/Infrastructure/{Project}.Infrastructure.Data `
  --startup-project src/Host/{Host}.Api `
  --context {App}DbContextTrxn
```

> **`--startup-project` must reference `Microsoft.EntityFrameworkCore.Design`.** The commands above point `--startup-project` at the API host - that only works if the API references the Design package. If the scaffold keeps the Design reference and a `DesignTimeDbContextFactory` in the **Data project only** (the common case here), use the Data project as **both** `--project` and `--startup-project`:
>
> ```powershell
> dotnet ef migrations add InitialCreate `
>   --project src/Infrastructure/{Project}.Infrastructure.Data `
>   --startup-project src/Infrastructure/{Project}.Infrastructure.Data `
>   --context {App}DbContextTrxn
> ```
>
> Pointing `--startup-project` at a host that does not reference Design fails with "doesn't reference Microsoft.EntityFrameworkCore.Design". Pick one rooting consistently across `add`, `remove`, and the production bundle.

**When to run:**
- After Phase 5a (all entities + DbContext configured)
- After any entity/relationship change during scaffolding
- Before Phase 5e tests that need a database

**Post-scaffold:** Once the baseline is established and the project is in production, switch to incremental migrations with descriptive names.

### Production migration bundle

Production schema is **not** applied on startup - the startup migration task is gated `IsDevelopment()` and is a no-op in ACA (Production). Apply production schema with an EF migration bundle run from CI, before the image swap. The bundle uses the same `--project`/`--startup-project` rooting as above (Data project when only Data references Design), bundles the **write** context only when Trxn/Query share a schema, and applies with Entra auth. Full step (firewall handling, Entra connection string, dual-context note) lives in [../skills/cicd.md](../skills/cicd.md) -> *Production DB Migration (EF Bundle)*.
