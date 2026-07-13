# Observability

## Purpose

Structured logging, distributed tracing, custom metrics, and health checks for all hosts. Complements [aspire.md](aspire.md) (which wires OpenTelemetry/ServiceDefaults) - this skill covers application-level conventions.

Not a monitoring dashboard skill - dashboard/alerting configuration is Azure-side (App Insights, Grafana, Azure Monitor). The telemetry **export** to Azure Monitor is wired in ServiceDefaults (gated on `APPLICATIONINSIGHTS_CONNECTION_STRING`) - only the dashboards/alerts on top of it are Azure-side. Any exporter, resource, or instrumented meter this skill or a tech-design Observability section names must have a real call-site or be tagged `not wired`; the discipline gate and `ConfigureOpenTelemetry` body are owned by [../patterns/infrastructure-wiring.md](../patterns/infrastructure-wiring.md) section Telemetry Export.

---

## Structured Logging Conventions

### Log Levels

| Level | Use For | Example |
|---|---|---|
| `Debug` | EF queries, cache internals, detailed diagnostics | `"Executing query for {Entity} with filter {Filter}"` |
| `Information` | Request/response lifecycle, business events | `"Created {Entity} {EntityId} for tenant {TenantId}"` |
| `Warning` | Retries, degraded paths, fallback behavior | `"Cache miss for {Entity}:{EntityId}, falling back to database"` |
| `Error` | Unhandled + caught-and-handled failures | `"Failed to save {Entity} {EntityId}: {ErrorMessage}"` |
| `Critical` | Startup failures, data corruption, unrecoverable state | `"Required schema missing - run the database migrator; application cannot start"` |

### Template Format

Always use structured placeholders - **never** string interpolation:

```csharp
// CORRECT
logger.LogInformation("Created {Entity} {EntityId} for tenant {TenantId}",
    nameof(TodoItem), entity.Id, entity.TenantId);

// WRONG - loses structured properties
logger.LogInformation($"Created TodoItem {entity.Id} for tenant {entity.TenantId}");
```

### Sensitive Data

> **CRITICAL:** Never log PII/PHI (names, emails, SSNs, health data). Reference `dataClassification` from [resource-implementation-schema.md](../ai/resource-implementation-schema.md) compliance metadata to identify sensitive fields. Log entity IDs and tenant IDs only.

### Logger Injection

Inject `ILogger<T>` per class - not `ILoggerFactory`:

```csharp
internal class TodoItemService(ILogger<TodoItemService> logger, ...) : ITodoItemService
```

---

## Correlation & Distributed Tracing

### Aspire Automatic Wiring

ServiceDefaults calls `ConfigureOpenTelemetry()` which wires `Activity.Current` automatically for HTTP and EF spans. No manual setup needed for standard request flows.

### Cross-Service Correlation

Middleware pattern for `X-Correlation-Id` header propagation:

```csharp
public class CorrelationIdMiddleware(RequestDelegate next)
{
    public async Task InvokeAsync(HttpContext context)
    {
        var correlationId = context.Request.Headers["X-Correlation-Id"].FirstOrDefault()
            ?? Activity.Current?.Id
            ?? Guid.NewGuid().ToString();

        context.Response.Headers["X-Correlation-Id"] = correlationId;
        using (logger.BeginScope(new Dictionary<string, object> { ["CorrelationId"] = correlationId }))
        {
            await next(context);
        }
    }
}
```

### Background Services

Create explicit `Activity` spans for job execution:

```csharp
using var activity = ActivitySource.StartActivity("ProcessDueReminders");
activity?.SetTag("job.name", "ProcessDueReminders");
activity?.SetTag("tenant.id", tenantId.ToString());
```

### Gateway -> API

YARP preserves correlation headers by default. Forward: `X-Correlation-Id`, `traceparent`, `tracestate`. No additional config needed unless custom headers are required.

---

## Custom Metrics

Use `System.Diagnostics.Metrics` (not legacy `EventCounters`):

### Meter Naming

`{Project}.{Layer}` - e.g., `TaskFlow.Api`, `TaskFlow.Domain`.

### Registration in Bootstrapper

```csharp
// In RegisterInfrastructureServices or a dedicated RegisterObservability method
services.AddSingleton(new Meter("{Project}.Api"));
services.AddSingleton(new Meter("{Project}.Domain"));
```

### Counter & Histogram Examples

```csharp
private static readonly Meter s_meter = new("{Project}.Api");
private static readonly Counter<long> s_entityCreated = s_meter.CreateCounter<long>("entity.created");
private static readonly Counter<long> s_cacheHit = s_meter.CreateCounter<long>("cache.hit");
private static readonly Counter<long> s_cacheMiss = s_meter.CreateCounter<long>("cache.miss");
private static readonly Histogram<double> s_requestDuration = s_meter.CreateHistogram<double>("request.duration", "ms");

// Usage
s_entityCreated.Add(1, new KeyValuePair<string, object?>("entity", nameof(TodoItem)));
s_cacheHit.Add(1, new KeyValuePair<string, object?>("key", cacheKey));
```

---

## Health Checks

**Required:** SQL connectivity (all hosts), Redis connectivity (if caching enabled).
**Optional:** Downstream API (Gateway -> API), Blob storage, Service Bus, Cosmos DB.

Implementation: Use `IHealthCheck` per dependency. Register with `services.AddHealthChecks().AddCheck<T>(name, tags: ["ready"])`. Map `/healthz` to `"live"` checks only and `/readyz` to `"ready"` checks. See [health-check-template.md](../templates/health-check-template.md) for the implementation pattern.

Aspire wiring: ServiceDefaults calls `AddDefaultHealthChecks()` to register the `"self"` liveness check. Add domain-specific readiness checks in host registration. Dependency outages make readiness fail without triggering liveness restart loops.

---

## Verification Checklist

- [ ] All log statements use structured placeholders, never string interpolation
- [ ] No PII/PHI in log output - entity IDs and tenant IDs only
- [ ] `ILogger<T>` injected per class (not `ILoggerFactory`)
- [ ] Correlation ID middleware registered in API pipeline
- [ ] Background jobs create explicit `Activity` spans
- [ ] Custom metrics use `System.Diagnostics.Metrics` with `{Project}.{Layer}` naming
- [ ] Health checks registered for SQL and Redis (if enabled)
- [ ] `/healthz` (liveness) and `/readyz` (readiness) endpoints mapped
- [ ] Dependency failure makes `/readyz` unhealthy while `/healthz` stays healthy
- [ ] ServiceDefaults OpenTelemetry wiring not duplicated
