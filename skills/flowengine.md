# FlowEngine (EF.FlowEngine)

Durable, JSON-defined workflow orchestration. Load when `includeFlowEngine: true` in `.scaffold/resource-implementation.yaml`.

## Prerequisites

- [solution-structure.md](solution-structure.md)
- [bootstrapper.md](bootstrapper.md)
- [data-persistence.md](data-persistence.md)
- [aspire.md](aspire.md)
- [../support/ef-packages-reference.md](../support/ef-packages-reference.md) section Workflow Engine and section FlowEngine Data-Layout Variants

Package version: track `EF.FlowEngine` latest stable. The surface assumed below: interface-composition DbContext, `WorkflowDefinitionJsonOptions.Default`, `AddWorkflowJsonSeeding`, `AddAzureOpenAIAgentClient` factory overload.

## Non-Negotiables

1. FlowEngine is a **separate DbContext** from the app's primary `{Project}DbContextTrxn`. Do not subclass `DbContextBase<TUser,TKey>` - use interface composition.
2. Default data layout is **Variant A** (same database, separate schema). This is the only layout that preserves FE's atomic outbox guarantee. Choosing `separate-db` degrades `message`/`integration`/`agent` delivery to best-effort - flag in `HANDOFF.md` and wire FE message nodes to the app's existing at-least-once publisher.
3. Workflow JSON files are **content-copied** by the API csproj and seeded by `AddWorkflowJsonSeeding()`. The test project must include a file-presence guard.
4. FE migrations live in their own history table (do not share `__EFMigrationsHistory` with the app DbContext) and are applied by a dedicated startup task.
5. Admin endpoints are mapped with an **explicit prefix** - `MapFlowEngineAdmin(prefix: "/api/flowengine")`. The default-prefix drift documented upstream is worked around by always passing it.

---

## Solution Layout

```
src/
  Infrastructure/
    {Project}.Data/
      {Project}DbContextTrxn.cs          # primary app context - inherits DbContextBase<string, Guid?>
      {Project}FlowEngineDbContext.cs    # FE context - interface composition (this file)
      ConfigureFlowEngineSqlOptions.cs   # FE-specific sqlServerOptionsAction
    {Project}.Bootstrapper/
      RegisterServices.FlowEngine.cs     # partial: AddFlowEngine fluent chain
  Host/
    {Project}.Api/
      Workflows/                         # workflow JSON files, copied to output
        approval-loop.json
        notify-on-completion.json
test/
  Test.Integration.{Project}.FlowEngine/ # workflow-tier guard tests (see flowengine-test-template.md)
```

---

## DbContext (interface composition)

`{Project}DbContextTrxn` already inherits `DbContextBase<string, Guid?>` for the audit interceptor. A single DbContext **cannot** inherit both that base and FE's `FlowEngineOutboxDbContext` / `FlowEngineCircuitBreakerDbContext`. Use a fresh DbContext that declares all three FE roles via interfaces.

```csharp
using EF.FlowEngine.Persistence;
using Microsoft.EntityFrameworkCore;

namespace {Project}.Data;

// Separate FE DbContext, NOT a subclass of {Project}DbContextBase.
// Declares all three FE roles via interface composition.
public sealed class {Project}FlowEngineDbContext(DbContextOptions<{Project}FlowEngineDbContext> options)
    : DbContext(options),
      IFlowEngineStateDbContext,
      IFlowEngineOutboxDbContext,
      IFlowEngineCircuitBreakerDbContext
{
    public const string SchemaName = "flowengine";
    public const string MigrationsHistoryTable = "__EFMigrationsHistory_FlowEngine";

    public DbSet<WorkflowInstance> WorkflowInstances => Set<WorkflowInstance>();
    public DbSet<OutboxEntry> OutboxEntries => Set<OutboxEntry>();
    public DbSet<CircuitBreakerState> CircuitBreakerStates => Set<CircuitBreakerState>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.HasDefaultSchema(SchemaName);
        modelBuilder.ApplyFlowEngineStateConfiguration();
        modelBuilder.ApplyFlowEngineOutboxConfiguration();
        modelBuilder.ApplyFlowEngineCircuitBreakerConfiguration();
    }
}
```

Migration-history isolation in the SQL options:

```csharp
public static class FlowEngineSqlOptions
{
    public static void Configure(SqlServerDbContextOptionsBuilder b)
    {
        b.UseCompatibilityLevel(170);
        b.MigrationsAssembly(typeof({Project}FlowEngineDbContext).Assembly.FullName);
        b.MigrationsHistoryTable(
            {Project}FlowEngineDbContext.MigrationsHistoryTable,
            {Project}FlowEngineDbContext.SchemaName);
    }
}
```

---

## Registration (Bootstrapper partial)

```csharp
// RegisterServices.FlowEngine.cs
public static partial class RegisterServices
{
    public static IServiceCollection AddFlowEngine(this IServiceCollection services, IConfiguration cfg)
    {
        var connectionString = cfg.GetConnectionString("Default")
            ?? throw new InvalidOperationException("Connection string 'Default' is required for FlowEngine.");

        services.AddDbContext<{Project}FlowEngineDbContext>(opts =>
            opts.UseSqlServer(connectionString, FlowEngineSqlOptions.Configure));

        services
            .AddFlowEngineCore()
            .AddFlowEngineStateStore<{Project}FlowEngineDbContext>()
            .AddFlowEngineOutbox<{Project}FlowEngineDbContext>()
            .AddFlowEngineCircuitBreaker<{Project}FlowEngineDbContext>()
            .AddSqlWorkflowRegistry<{Project}FlowEngineDbContext>()
            .AddSqlDistributedLockProvider(connectionString)
            .AddSqlHumanTaskStore<{Project}FlowEngineDbContext>()
            .AddHttpClient()
            .AddSqlQueryClient()
            .AddServiceBusMessageClient(cfg.GetSection("ServiceBus"))
            .AddAzureOpenAIAgentClient(
                sp => sp.GetRequiredService<AzureOpenAIClient>(),
                deploymentName: cfg["AzureOpenAI:DeploymentName"]!,
                modelName: cfg["AzureOpenAI:ModelName"]!);

        services.AddWorkflowJsonSeeding(opts =>
        {
            opts.WorkflowDirectory = "Workflows";
            opts.SearchPattern = "*.json";
        });

        return services;
    }
}
```

Call from `RegisterServices.AddInfrastructure` (or the matching aggregate) inside the existing bootstrapper.

## Migration target

The FE context is an ordered target in the dedicated migrator host - no runtime host migrates it (see [../support/data-persistence-advanced.md](../support/data-persistence-advanced.md) section Migration Ownership: Dedicated Migrator Host):

```csharp
// {Project}.DatabaseMigrator - app schema first, FlowEngine second
.AddEfCoreMigrationTarget<{Project}FlowEngineDbContext>("{Project}FlowEngineDbContext", 20)
```

The migrator's FE context registration applies `FlowEngineSqlOptions.Configure` (history table + schema + migrations assembly, above) so the `flowengine` schema keeps its own history table; the FE design-time factory uses the same configuration. `{Project}FlowEngineDbContext` keeps its own logical connection name even when local Aspire points it at the app database. Runtime hosts assume the schema exists; `AddWorkflowJsonSeeding` seeds workflow definitions only, never schema.

## Workflow JSON content copy

In the API csproj:

```xml
<ItemGroup>
  <Content Include="Workflows\*.json">
    <CopyToOutputDirectory>PreserveNewest</CopyToOutputDirectory>
  </Content>
</ItemGroup>
```

The file-presence guard test ([../templates/flowengine-test-template.md](../templates/flowengine-test-template.md)) protects against silent regression if this glob breaks.

## Admin API mapping

In `WebApplicationBuilderExtensions` (or wherever `MapXxx` calls live):

```csharp
app.MapFlowEngineAdmin(prefix: "/api/flowengine");
```

Always pass the prefix explicitly. The default-prefix value is unstable across FE releases; the explicit string is the contract.

## Trigger model

FlowEngine workflows must be invoked by something. The three canonical patterns live in [../templates/flowengine-trigger-template.md](../templates/flowengine-trigger-template.md):

- **Service Bus subscriber in `{Project}.Functions`** - when `includeFunctionApp: true` and an integration event should start a workflow.
- **Inline call from a service** - when the trigger is an in-process command (e.g., from an API endpoint).
- **TickerQ recurring job in `{Project}.Scheduler`** - when `includeScheduler: true` and the workflow runs on a cron.

`IWorkflowTrigger` is **not** an FE-shipped interface; it is an app-level facade over `IFlowEngine` used to keep the trigger sites thin. Generate it in `{Project}.Application.Services`.

---

## Phase Routing

| Phase | What FlowEngine adds |
|---|---|
| **2** | `includeFlowEngine: true`, `flowEngineDbStrategy: same-db-separate-schema` (Variant A default). When choosing `separate-db`, record the outbox trade-off in `.scaffold/DESIGN-DECISIONS.md`. |
| **3** | Add FE NuGet packages to the package matrix; verify feed access (`EF.FlowEngine`, `EF.FlowEngine.StateStore.Sql`, `EF.FlowEngine.Locks.Sql`, `EF.FlowEngine.WorkflowRegistry.Sql`, `EF.FlowEngine.HumanTaskStore.Sql`, `EF.FlowEngine.Outbox.Sql`, `EF.FlowEngine.CircuitBreaker.Sql`, `EF.FlowEngine.Clients.Http`, `EF.FlowEngine.Clients.Sql`, `EF.FlowEngine.Clients.ServiceBus` if Service Bus enabled, `EF.FlowEngine.Clients.OpenAI` if AI in scope, `EF.FlowEngine.AdminApi`, `EF.FlowEngine.Testing`). |
| **5a** | Generate `{Project}FlowEngineDbContext`, `FlowEngineSqlOptions`, and the FE migration. Do **not** add FE tables to the app's `OnModelCreating`. |
| **5b** | Generate `RegisterServices.FlowEngine.cs` partial, register the FE context as a migrator target in `{Project}.DatabaseMigrator`, and add the `MapFlowEngineAdmin` call in the API host. Place a single placeholder workflow JSON in `Workflows/` and emit the seeding hosted service. |
| **5c** | Emit the chosen trigger template(s) when `includeFunctionApp` or `includeScheduler` is enabled. |
| **5d** | Generate `Test.Integration.{Project}.FlowEngine` with the four-validity-tier guards (deserialize, validate, registry round-trip, builder, file-presence). |
| **5e** | When AI in scope, FE `agent` nodes use `AddAzureOpenAIAgentClient` factory overload - wire `AzureOpenAIClient` from the app's existing AI bootstrap. |

## Anti-patterns

- Subclassing the FE outbox/circuit-breaker abstract bases. Use interface composition instead.
- Adding FE `DbSet`s to the app's primary DbContext. Use a separate FE context.
- Sharing `__EFMigrationsHistory`. Use the dedicated history table constant on the FE context.
- Omitting the workflow-JSON file-presence test. The failure mode is "instance start returns workflow not found at runtime" - silent until exercised.
- Calling `MapFlowEngineAdmin()` without a prefix. Always pass `/api/flowengine` explicitly.
- Wiring FE `message` nodes when `flowEngineDbStrategy: separate-db` without an at-least-once relay. Atomic outbox is gone in Variant B/C.
