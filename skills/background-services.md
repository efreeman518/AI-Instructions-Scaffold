# Background Services (TickerQ Scheduler)

## Prerequisites

- [solution-structure.md](solution-structure.md)
- [bootstrapper.md](bootstrapper.md)
- [aspire.md](aspire.md)
- [data-persistence.md](data-persistence.md)
- TickerQ docs & source: [https://github.com/Arcenox-co/TickerQ](https://github.com/Arcenox-co/TickerQ)

## Purpose

Use `{Host}.Scheduler` for cron/time-based orchestration with persisted scheduling state via TickerQ. Keep in-process queue consumers and listeners in `{Host}.BackgroundServices`.

## Non-Negotiables

1. Scheduler is a separate host project from API.
2. Job methods are thin `[TickerFunction]` adapters; business logic lives in handlers.
3. Deploy one scheduler replica unless Redis coordination is enabled. **Why:** Without distributed coordination, replicas can independently dispatch the same due schedule, duplicating side effects and racing persisted state. Therefore one replica is the safe baseline.
4. TickerQ persistence uses the app-owned `{App}TickerQDbContext` with the `[Scheduler]` schema and its own migration history table (`Scheduler.__EFMigrationsHistory_TickerQ`).
5. TickerQ schema is applied by the `{App}.DatabaseMigrator` host; scheduler startup validates the schema exists and fails fast - it never creates or patches it (see [../support/data-persistence-advanced.md](../support/data-persistence-advanced.md) section Third-Party Operational Store Schemas).

---

## Scheduler vs BackgroundServices

- `{Host}.Scheduler`: persisted cron/time scheduling, dashboard, orchestration.
- `{Host}.BackgroundServices`: channel consumers, long-running listeners, queue pumps.
- Use both when needed, but keep their responsibilities and deployment independent.

---

## Channel-Based Background Task Queue

Use `EF.BackgroundServices` for fire-and-forget background work within the API host. The package provides a `Channel<T>`-backed producer/consumer queue.

### Registration (Bootstrapper)

```csharp
private static IServiceCollection AddSupportServices(this IServiceCollection services)
{
    services.AddChannelBackgroundTaskQueueWithShutdownHandling();
    services.AddSingleton<IInternalMessageBus, InternalMessageBus>();
    return services;
}
```

`AddChannelBackgroundTaskQueueWithShutdownHandling()` registers `IBackgroundTaskQueue` (singleton) + `ChannelBackgroundTaskQueue` hosted service. The "WithShutdownHandling" variant drains the queue on host shutdown.

### Usage (in services/endpoints)

```csharp
public class SomeService(IBackgroundTaskQueue taskQueue)
{
    public void EnqueueWork(Guid itemId)
    {
        taskQueue.QueueBackgroundWorkItem(async ct =>
        {
            // Fire-and-forget work - runs outside request scope
            // Create a new DI scope if you need scoped services
        });
    }
}
```

### Rules

- Use for work that doesn't need persistence or retry - audit logging, cache invalidation, notifications.
- For work that needs persistence, retry, or scheduling, use TickerQ instead.
- The queue is in-memory - items are lost if the host crashes before processing.
- Always create a new DI scope inside the work item if you need scoped services (DbContext, etc.). **Why:** Queued work can outlive the enqueueing request scope; capturing it can access disposed services or reuse one DbContext unit of work across items. Therefore resolve scoped dependencies inside each work item.

## Minimal Scheduler Structure

```
Host/{Host}.Scheduler/
|-- Program.cs
|-- RegisterSchedulerServices.cs
|-- Abstractions/IScheduledJobHandler.cs
|-- Jobs/BaseTickerQJob.cs
|-- Jobs/{Feature}Jobs.cs
|-- Handlers/{JobName}Handler.cs
|-- Infrastructure/{App}SchedulerExceptionHandler.cs
|-- Infrastructure/SchedulerHealthCheck.cs
`-- appsettings*.json
```

Reference patterns: [../patterns/infrastructure-wiring.md](../patterns/infrastructure-wiring.md) (Aspire Resource Wiring).

---

## Registration Sequence (Required)

The startup flow must remain in this order:

1. Add service defaults.
2. Register bootstrapper infra/app services.
3. Register scheduler-specific services.
4. Configure TickerQ.
5. Build app.
6. Validate the TickerQ operational store (validate-only; the migrator applied the schema).
7. Enable `UseTickerQ()` middleware.
8. Map health/endpoints and run.

```csharp
builder.AddServiceDefaults(config, appName);
services
    .RegisterInfrastructureServices(config)
    .RegisterApplicationServices(config)
    .RegisterSchedulerServices(config);

builder.AddTickerQConfig();

var app = builder.Build();
await app.ValidateTickerQDatabase();
app.UseTickerQ();
app.MapDefaultEndpoints();
await app.RunAsync();
```

---

## Job/Handler Split (Required)

```csharp
public class ReminderJobs(...) : BaseTickerQJob(...)
{
    [TickerFunction("ProcessDueReminders", "10 */5 * * * *", TickerTaskPriority.High)]
    public async Task ProcessDueRemindersAsync(TickerFunctionContext context, CancellationToken ct)
    {
        await ExecuteJobAsync<ProcessDueRemindersHandler>("ProcessDueReminders", context, ct);
    }
}
```

- Job methods only map trigger -> handler.
- Handler implements domain/application logic and remains testable.
- `BaseTickerQJob` manages scope creation, telemetry, and exception wiring.

---

## TickerQ Configuration Contract

`RegisterSchedulerServices` and `AddTickerQConfig` must cover:

- Scoped handlers and job adapters.
- Scheduler settings (`MaxConcurrency`, time zone, poll interval).
- EF Core persistence via `UseTickerQDbContext<{App}TickerQDbContext>(...)` with the `[Scheduler]` schema; SQL options set the migrations assembly + history table to match the migrator target.
- Optional dashboard (secure credentials only).
- Optional Redis coordination for multi-node deployments.

If workflows are time-policy sensitive (billing windows, scheduled publish, SLA windows), bind a shared time-boundary policy and avoid hard-coded timezone math inside handlers.

Key settings:

| Section | Keys |
|---|---|
| `ConnectionStrings` | `{Project}DbContextTrxn`, `TickerQDbContext` |
| `Scheduling` | `UsePersistence`, `EnableDashboard`, `EnableRedis`, `PollIntervalSeconds` |
| `Scheduling:Dashboard` | `Username`, `Password` |

## Database Setup

- `TickerQDbContext` keeps its own logical connection name; it may point at the app database (local) or a dedicated DB (Azure) - configuration only, never runtime code.
- TickerQ tables remain isolated by the `[Scheduler]` schema with their own migration history table.
- Schema is applied by the `{App}.DatabaseMigrator` host via the app-owned `{App}TickerQDbContext` migration target; migrations live under `Migrations/TickerQ` with an explicit migrations assembly. Scheduler startup validates the schema and fails fast when missing (`ValidateTickerQDatabase`); library auto-create and deployment-script generation stay off. Canonical rules: [../support/data-persistence-advanced.md](../support/data-persistence-advanced.md) section Third-Party Operational Store Schemas.

---

## Runtime Scheduling APIs

- One-off jobs: use `ITimeTickerManager<T>.EnqueueAsync("JobName", scheduledTime, payload)`.
- Cron job seeding: use `ICronTickerManager.AddAsync(new CronTickerEntity { Function = "JobName", Expression = "* * * * * *", ... })`.
  `ICronTickerManager` is NOT generic. Property names on `CronTickerEntity` are `Function` (not `FunctionName`) and `Expression` (not `CronExpression`).
- In-memory mode (no `TickerQ.EntityFrameworkCore` configured) does NOT register `ICronTickerManager` - wrap cron seeding in a try-catch on `InvalidOperationException` so the host starts cleanly during development.

TickerQ cron format is six fields: seconds, minutes, hours, day-of-month, month, day-of-week.

For ingestion/event-time workflows, define and apply allowed-lateness/watermark behavior before triggering reconciliation jobs.

---

## Deployment Rules

- Default deployment is single scheduler replica.
- Multi-node scheduler is allowed only with Redis coordination package/config.
- Keep scheduler as its own resource in Aspire/AppHost.
- If dashboard is enabled, secure credentials through environment variables or Key Vault.

### Worker SDK choice drives ACA ingress

A "worker" scaffolded as `Microsoft.NET.Sdk.Web` (uses `WebApplication`, maps `/health` + `/`) DOES serve HTTP, so on Container Apps it gets **internal** ingress (not "no ingress"). That is fine - health probes pass. Do not try to disable its ingress. Only a plain `Microsoft.NET.Sdk.Worker` generic-host project (no `WebApplication`, no mapped endpoints) gets **no ingress**. Pick the SDK to match the intent: use `Sdk.Worker` for pure background processing with no HTTP surface; use `Sdk.Web` when you want the host to expose health endpoints (and accept internal ingress).

---

## Lite Mode

In `lite` mode keep only:

- Program + registration + one job + one handler.
- Persistence and core scheduling settings.

Skip by default:

- Dashboard
- Custom telemetry classes
- Custom exception handler
- Expanded one-off/cron examples

---

## Verification

- [ ] Scheduler project builds cleanly
- [ ] `dotnet run --project src/Host/{Host}.Scheduler` starts successfully
- [ ] At least one `[TickerFunction]` is registered
- [ ] Jobs delegate through `ExecuteJobAsync<THandler>()`
- [ ] `{App}TickerQDbContext` is resolved; startup validation confirms the `[Scheduler]` schema exists (migrator ran)
- [ ] Aspire config uses `WithReplicas(1)` unless Redis coordination is enabled
- [ ] If dashboard enabled, credentials are not default/plain test values
- [ ] If `{Host}.BackgroundServices` exists, it remains a separate project

See [placeholder-tokens.md](../ai/placeholder-tokens.md) for token definitions.
