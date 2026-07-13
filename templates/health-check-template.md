# Health Check Template

**Generates:** `SqlHealthCheck.cs`, `RedisHealthCheck.cs` (and per-dependency checks as needed)
**Requires:** [../skills/observability.md](../skills/observability.md)

## Health Check Implementation

```csharp
public class SqlHealthCheck(IDbContextFactory<{App}DbContextTrxn> factory) : IHealthCheck
{
    public async Task<HealthCheckResult> CheckHealthAsync(
        HealthCheckContext context, CancellationToken ct = default)
    {
        try
        {
            using var db = await factory.CreateDbContextAsync(ct);
            await db.Database.CanConnectAsync(ct);
            return HealthCheckResult.Healthy();
        }
        catch (Exception ex)
        {
            return HealthCheckResult.Unhealthy("SQL connection failed", ex);
        }
    }
}
```

## Registration

```csharp
// In RegisterApiServices or Bootstrapper
services.AddHealthChecks()
    .AddCheck<SqlHealthCheck>("sql", tags: ["ready"])
    .AddCheck<RedisHealthCheck>("redis", tags: ["ready"]);
```

## Endpoint Mapping

```csharp
app.MapHealthChecks("/healthz", new() { Predicate = r => r.Tags.Contains("live") }).AllowAnonymous(); // liveness
app.MapHealthChecks("/readyz", new() { Predicate = r => r.Tags.Contains("ready") }).AllowAnonymous(); // readiness
```

## Rules

- One `IHealthCheck` class per external dependency.
- Tag dependency checks with `"ready"`; ServiceDefaults owns the `"self"` check tagged `"live"`.
- `/healthz` runs only `"live"` checks. `/readyz` runs only `"ready"` checks.
- Do not duplicate ServiceDefaults self-liveness - add domain-specific readiness only.
- **Why:** dependency failure must stop new traffic through readiness without making the orchestrator restart a healthy process through liveness.
- Verify a failed dependency makes `/readyz` unhealthy while `/healthz` remains healthy.
