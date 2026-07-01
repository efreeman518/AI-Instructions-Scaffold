# Caching

Reference patterns: [../patterns/infrastructure-wiring.md](../patterns/infrastructure-wiring.md) (Multi-Cache Configuration).

## Purpose

Use FusionCache as the application cache abstraction, with Redis as distributed layer and backplane for cross-instance invalidation.

FusionCache is referenced directly from the application layer (services/handlers inject `IFusionCache` / `IFusionCacheProvider`) and is **not** wrapped in an Infrastructure project, because `IFusionCache` is already the app-level abstraction you would otherwise author. This is the deliberate direct-reference exception to the usual contract-in-Application / implementation-in-Infrastructure split - see the Wrap vs. Direct Reference rule in [solution-structure.md](solution-structure.md#wrap-vs-direct-reference).

## Architecture

```
Application -> FusionCache (L1 memory) -> Redis (L2 distributed)
                         \-> Redis backplane (invalidation sync)
```

For local Redis inspection under Aspire, use the **Aspire-managed RedisInsight browser UI** (`WithRedisInsight`) over the Windows desktop app - it ships with the resource and avoids manual config. See [aspire.md](aspire.md) -> *Local Explorer Tooling* for the canonical pinned-port pattern and `isTesting` gate.

## Non-Negotiables

1. Use `IFusionCacheProvider` (named caches), not a single global cache instance.
2. Configure cache instances from settings (`CacheSettings[]`).
3. Use cache-aside for reads and explicit invalidation on writes.
4. Keep fail-safe enabled for resilience under transient dependency failures.
5. Align Redis connection names with Aspire/bootstrapper config.

---

## Configuration

```json
{
  "CacheSettings": [
    {
      "Name": "Default",
      "DurationMinutes": 30,
      "DistributedCacheDurationMinutes": 60,
      "FailSafeMaxDurationMinutes": 120,
      "FailSafeThrottleDurationSeconds": 1,
      "RedisConnectionStringName": "Redis1",
      "BackplaneChannelName": "cache-sync"
    }
  ]
}
```

`StaticData`-style long-lived caches can be added as separate named instances.

---

## Registration Pattern (Bootstrapper)

**Source:** `Host/{App}.Bootstrapper/Registration/RegisterServices.Caching.cs`. Bind `CacheSettings[]` from config and register each as a named FusionCache. Every entry-option value comes from `CacheSettings` (see model below) - do not hard-code durations/timeouts. When no `CacheSettings` are configured, register one default cache so `IFusionCacheProvider.GetCache(DEFAULT_CACHE)` always resolves. Wire the Redis L2 + backplane only when that cache sets `RedisConnectionStringName`.

```csharp
private static void AddCachingServices(IServiceCollection services, IConfiguration config)
{
    List<CacheSettings> cacheSettings = [];
    config.GetSection("CacheSettings").Bind(cacheSettings);

    if (cacheSettings.Count == 0)
        cacheSettings.Add(new CacheSettings { Name = AppConstants.DEFAULT_CACHE });

    foreach (var settings in cacheSettings)
    {
        var fcBuilder = services.AddFusionCache(settings.Name)
            .WithSystemTextJsonSerializer(new JsonSerializerOptions
            {
                ReferenceHandler = ReferenceHandler.Preserve
            })
            .WithCacheKeyPrefix($"{settings.Name}:")
            .WithDefaultEntryOptions(new FusionCacheEntryOptions
            {
                Duration = TimeSpan.FromMinutes(settings.DurationMinutes),
                DistributedCacheDuration = TimeSpan.FromMinutes(settings.DistributedCacheDurationMinutes),
                IsFailSafeEnabled = true,
                FailSafeMaxDuration = TimeSpan.FromMinutes(settings.FailSafeMaxDurationMinutes),
                FailSafeThrottleDuration = TimeSpan.FromSeconds(settings.FailSafeThrottleDurationSeconds),
                JitterMaxDuration = TimeSpan.FromSeconds(settings.JitterMaxDurationSeconds),
                FactorySoftTimeout = TimeSpan.FromSeconds(settings.FactorySoftTimeoutSeconds),
                FactoryHardTimeout = TimeSpan.FromSeconds(settings.FactoryHardTimeoutSeconds),
                EagerRefreshThreshold = settings.EagerRefreshThreshold
            });

        var redisConnStr = !string.IsNullOrEmpty(settings.RedisConnectionStringName)
            ? config.GetConnectionString(settings.RedisConnectionStringName)
            : null;

        if (!string.IsNullOrEmpty(redisConnStr))
        {
            fcBuilder
                .WithDistributedCache(new RedisCache(new RedisCacheOptions { Configuration = redisConnStr }))
                .WithBackplane(new RedisBackplane(new RedisBackplaneOptions { Configuration = redisConnStr }));
        }
    }
}
```

---

## Tag-Based Invalidation

Tags are a positional parameter on `GetOrSetAsync` / `SetAsync`, not an option property. Invalidate by tag with `RemoveByTagAsync`.

```csharp
// Setting tags when caching
await _cache.SetAsync($"todoitem:{id}", dto, options: null, tags: ["todoitems"], token: ct);

// Invalidating by tag
await _cache.RemoveByTagAsync("todoitems", null, ct);
```

---

## Usage Patterns

### Named cache resolution

```csharp
private readonly IFusionCache _cache = fusionCacheProvider.GetCache(AppConstants.DEFAULT_CACHE);
```

### Cache-aside read

```csharp
public Task<TodoItemDto?> GetCachedAsync(Guid id, CancellationToken ct)
{
    return _cache.GetOrSetAsync(
        $"todoitem:{id}",
        async (ctx, token) => (await repoQuery.GetTodoItemAsync(id, token))?.ToDto(),
        cancellationToken: ct);
}
```

### Invalidate / cache-on-write

```csharp
await _cache.RemoveAsync($"todoitem:{id}", token: ct);
await _cache.SetAsync($"todoitem:{entity.Id}", entity.ToDto(), token: ct);
```

---

## Cache Key Rules

- item keys: `{entity}:{id}`
- list/query keys: `{entity}:list:{filterHash}`
- tenant-aware keys should include tenant scope where applicable

Keep key format deterministic and versionable.

---

## CacheSettings Model

```csharp
public class CacheSettings
{
    public string Name { get; set; } = "Default";
    public int DurationMinutes { get; set; } = 30;
    public int DistributedCacheDurationMinutes { get; set; } = 60;
    public int FailSafeMaxDurationMinutes { get; set; } = 120;
    public int FailSafeThrottleDurationSeconds { get; set; } = 1;
    public int JitterMaxDurationSeconds { get; set; } = 10;
    public int FactorySoftTimeoutSeconds { get; set; } = 1;
    public int FactoryHardTimeoutSeconds { get; set; } = 30;
    public float EagerRefreshThreshold { get; set; } = 0.9f;
    public string? RedisConnectionStringName { get; set; }
    public string? BackplaneChannelName { get; set; }
}
```

**Extending cache behavior:** add fields to `CacheSettings` and update all host `appsettings*.json` in the same change. Do not add a new separate settings class - the list-based pattern already supports per-named-cache tuning.

---

## Testing Guidance

Mock `IFusionCacheProvider` and `IFusionCache` in test base; verify:

- cache hits return expected value,
- misses call underlying repository once,
- write operations invalidate/update keys.

---

## Verification

- [ ] FusionCache registered with named instances
- [ ] Redis L2 + backplane configured where distributed caching is enabled
- [ ] key patterns are deterministic and tenant-safe
- [ ] reads use `GetOrSetAsync` cache-aside pattern
- [ ] writes invalidate or update relevant keys
- [ ] `IFusionCacheProvider` is used for named cache resolution
- [ ] Aspire Redis resource name aligns with connection string naming
- [ ] tests mock cache provider and validate behavior