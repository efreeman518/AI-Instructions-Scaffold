# FlowEngine Trigger Templates

Generated when `includeFlowEngine: true`. Pick one or more triggers based on `.scaffold/resource-implementation.yaml` flags. See [../skills/flowengine.md](../skills/flowengine.md) for the surrounding FE setup.

## App-Level Facade - `IWorkflowTrigger`

`IFlowEngine` is the engine's full API (start, signal, resume, terminate). Wrap it in a thin app-level facade so trigger sites stay testable and small. Service Bus, inline, and scheduler adapters may launch the same workflow; keeping business logic in workflow nodes gives every source one versioned, tested behavior. Generate this in `{Project}.Application.Services`.

```csharp
namespace {Project}.Application.Services;

public interface IWorkflowTrigger
{
    Task<Guid> StartAsync(string workflowId, object input, CancellationToken ct = default);
}

public sealed class WorkflowTrigger(IFlowEngine engine) : IWorkflowTrigger
{
    public async Task<Guid> StartAsync(string workflowId, object input, CancellationToken ct = default)
    {
        var instance = await engine.StartAsync(workflowId, input, ct);
        return instance.InstanceId;
    }
}
```

Register in the bootstrapper:

```csharp
services.AddScoped<IWorkflowTrigger, WorkflowTrigger>();
```

---

## Trigger 1 - Service Bus Subscriber (`includeFunctionApp: true`)

Use when an out-of-process integration event should start a workflow. Lives in `{Project}.Functions`.

```csharp
namespace {Project}.Functions;

public sealed class StartWorkflowOnTaskCreated(
    IWorkflowTrigger workflows,
    ILogger<StartWorkflowOnTaskCreated> log)
{
    [Function(nameof(StartWorkflowOnTaskCreated))]
    public async Task Run(
        [ServiceBusTrigger("%TaskFlow:TaskCreatedTopic%", "%TaskFlow:Subscription%",
            Connection = "ServiceBus")]
        TaskCreatedIntegrationEvent evt,
        FunctionContext ctx)
    {
        var ct = ctx.CancellationToken;
        var input = new
        {
            evt.TenantId,
            evt.TaskItemId,
            evt.CreatedUtc
        };

        var instanceId = await workflows.StartAsync(
            workflowId: "approval-loop",
            input: input,
            ct: ct);

        log.LogInformation(
            "Started workflow {WorkflowId} instance {InstanceId} for task {TaskId}",
            "approval-loop", instanceId, evt.TaskItemId);
    }
}
```

Notes:
- The function project must already have `IWorkflowTrigger` registered (see [../skills/function-app.md](../skills/function-app.md) for the function host's DI bootstrapping).
- Use the **typed integration event**, not the in-process `IMessage` model. In-process messages are not delivered through Service Bus and will not arrive at the function.

---

## Trigger 2 - Inline (in-process command)

Use when an API endpoint or service should kick off a workflow synchronously as part of its own work. No new infrastructure.

```csharp
public sealed class TaskItemService(
    IRepository<TaskItem> repo,
    IWorkflowTrigger workflows) : ITaskItemService
{
    public async Task<DomainResult<TaskItem>> ApproveAsync(Guid id, CancellationToken ct)
    {
        var item = await repo.GetByIdAsync(id, ct);
        if (item is null) return DomainResult.NotFound<TaskItem>(id);

        item.MarkApproved();
        await repo.SaveAsync(item, ct);

        // Fire-and-track: the workflow id and the entity id are bound for later correlation.
        await workflows.StartAsync(
            workflowId: "notify-on-completion",
            input: new { item.Id, item.TenantId },
            ct: ct);

        return DomainResult.Success(item);
    }
}
```

Use this when:
- The trigger is an in-process command.
- You want the call site to fail loudly if FE is unavailable (vs. swallowing in a queue).

Avoid this when:
- The workflow may take many seconds and you want to return to the caller immediately. Prefer Trigger 1 (out-of-process) for that.

---

## Trigger 3 - TickerQ Recurring Job (`includeScheduler: true`)

Use when a workflow runs on a cron. Lives in `{Project}.Scheduler`.

```csharp
namespace {Project}.Scheduler.Jobs;

public sealed class NightlyReconciliationJob(IWorkflowTrigger workflows)
{
    [TickerFunction(functionName: nameof(NightlyReconciliationJob), cronExpression: "0 2 * * *")]
    public async Task Run(TickerFunctionContext ctx, CancellationToken ct)
    {
        await workflows.StartAsync(
            workflowId: "nightly-reconciliation",
            input: new { RunDate = DateOnly.FromDateTime(DateTime.UtcNow) },
            ct: ct);
    }
}
```

Notes:
- Cron uses TickerQ's standard 5-field expression (UTC).
- One scheduler replica unless TickerQ Redis coordination is enabled - see [../skills/background-services.md](../skills/background-services.md).
- Do **not** put the workflow's business logic in the job. The job is a thin trigger; the work belongs in the workflow's nodes.

---

## Selecting a Trigger

| Source of trigger | Template |
|---|---|
| Out-of-process integration event (Service Bus topic/queue) | Trigger 1 (Functions subscriber) |
| In-process API/service call | Trigger 2 (inline) |
| Cron / time-based | Trigger 3 (TickerQ job) |
| Multiple sources | Generate each independently; all funnel through `IWorkflowTrigger`. |

Record which triggers are enabled per workflow in `.scaffold/DESIGN-DECISIONS.md`.
