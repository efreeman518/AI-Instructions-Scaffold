# Repository Template

> **When to read:** Phase 5a, when generating the Trxn (mutations) + Query (reads) repository pair for an EF-backed entity, plus their interfaces.
> **Skip if:** Entity has no mutations (read-only projection); persistence is non-EF (Cosmos/Table/Blob - use `azure-data-storage.md`); repository pair already exists.
>
> **Read [Generic Repository Pair](#generic-repository-pair-repositorycontractstyle-hybrid--generic-only) FIRST.** Under `repositoryContractStyle: hybrid`/`generic-only` (the default is `hybrid`), CRUD-only / append-only / join entities use the shared open-generic pair and get **no** per-entity repository - the bespoke per-entity classes below are only for entities with real read/write logic (multi-include loads, `UpdateFromDto` child sync, paged `Search`, polymorphic/hierarchy/multi-key queries).

| | |
|---|---|
| **File** | `Infrastructure.Repositories/{Entity}RepositoryTrxn.cs`, `{Entity}RepositoryQuery.cs` |
| **Depends on** | [entity-template](entity-template.md), [ef-configuration-template](ef-configuration-template.md) |
| **Referenced by** | [service-template](service-template.md), [bootstrapper.md](../skills/bootstrapper.md) |

## File: Infrastructure/Repositories/{Entity}RepositoryTrxn.cs

```csharp
using System.Linq.Expressions;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Query;
using EF.Data;
using EF.Data.Contracts;
using EF.Domain;
using EF.Domain.Contracts;
using Infrastructure.Repositories.Updaters;

namespace Infrastructure.Repositories;

/// <summary>
/// RepositoryBase generic args: <TDbContext, TAuditId, TTenantId>
///   TAuditId = string (matches IRequestContext.AuditId type)
///   TTenantId = Guid? (matches ITenantEntity<Guid> - nullable for non-tenant scenarios)
/// </summary>
public class {Entity}RepositoryTrxn({Project}DbContextTrxn dbContext)
    : RepositoryBase<{Project}DbContextTrxn, string, Guid?>(dbContext), I{Entity}RepositoryTrxn
{
    // ===== Get with includes (entity-specific) =====
    public async Task<{Entity}?> Get{Entity}Async(Guid id, bool includeChildren = false, CancellationToken ct = default)
    {
        var includes = new List<Expression<Func<IQueryable<{Entity}>, IIncludableQueryable<{Entity}, object?>>>>();

        if (includeChildren)
        {
            includes.Add(q => q.Include(e => e.{ChildEntity}s));
        }

        return await GetEntityAsync(
            true,
            filter: e => e.Id == id,
            splitQueryThresholdOptions: SplitQueryThresholdOptions.Default,
            includes: [.. includes],
            cancellationToken: ct
        ).ConfigureAwait(ConfigureAwaitOptions.None);
    }

    // ===== UpdateFromDto - delegates to DbContext extension method =====
    public DomainResult<{Entity}> UpdateFromDto({Entity} entity, {Entity}Dto dto,
        RelatedDeleteBehavior relatedDeleteBehavior = RelatedDeleteBehavior.None)
    {
        return DB.UpdateFromDto(entity, dto, relatedDeleteBehavior);
    }
}
```

## File: Infrastructure/Repositories/{Entity}RepositoryQuery.cs

```csharp
using System.Linq.Expressions;
using EF.Data;
using EF.Common;

namespace Infrastructure.Repositories;

public class {Entity}RepositoryQuery({Project}DbContextQuery dbContext)
    : RepositoryBase<{Project}DbContextQuery, string, Guid?>(dbContext), I{Entity}RepositoryQuery
{
    // ===== Search with paging (uses inherited QueryPageProjectionAsync) =====
    public async Task<PagedResponse<{Entity}Dto>> Search{Entity}Async(
        SearchRequest<{Entity}SearchFilter> request, CancellationToken ct = default)
    {
        return await QueryPageProjectionAsync<{Entity}, {Entity}Dto>(
            {Entity}Mapper.Projection, // Use ProjectorSearch only for an intentional lean grid shape.
            readNoLock: true,
            pageSize: request.PageSize,
            pageIndex: Math.Max(1, request.PageIndex),
            filter: BuildFilter(request.Filter),
            orderBy: BuildOrderBy(request.Sorts),
            includeTotal: true,
            splitQueryThresholdOptions: SplitQueryThresholdOptions.Default,
            cancellationToken: ct).ConfigureAwait(ConfigureAwaitOptions.None);
    }

    // ===== Lookup (autocomplete) =====
    public async Task<StaticList<StaticItem<Guid, Guid?>>> Lookup{Entity}Async(
        Guid? tenantId, string? search, CancellationToken ct = default)
    {
        Expression<Func<{Entity}, bool>>? filter = null;

        if (tenantId.HasValue && !string.IsNullOrWhiteSpace(search))
            filter = e => e.TenantId == tenantId && e.Name.Contains(search);
        else if (tenantId.HasValue)
            filter = e => e.TenantId == tenantId;
        else if (!string.IsNullOrWhiteSpace(search))
            filter = e => e.Name.Contains(search);

        var result = await QueryPageProjectionAsync(
            {Entity}Mapper.ProjectorStaticItems,
            readNoLock: false,
            pageSize: 50,
            pageIndex: 1,
            filter: filter,
            orderBy: q => q.OrderBy(e => e.Name),
            includeTotal: false,
            splitQueryThresholdOptions: null,
            cancellationToken: ct).ConfigureAwait(ConfigureAwaitOptions.None);

        return new StaticList<StaticItem<Guid, Guid?>> { Items = result.Data };
    }

    // ===== Filter Builder =====
    private static Expression<Func<{Entity}, bool>>? BuildFilter({Entity}SearchFilter? filter)
    {
        if (filter == null) return null;

        return e =>
            (!filter.TenantId.HasValue || e.TenantId == filter.TenantId) &&
            (string.IsNullOrWhiteSpace(filter.Name) || e.Name.Contains(filter.Name)) &&
            (!filter.Flags.HasValue || e.Flags.HasFlag(filter.Flags.Value));
    }

    // ===== Order Builder =====
    private static Func<IQueryable<{Entity}>, IOrderedQueryable<{Entity}>> BuildOrderBy(
        IEnumerable<Sort>? sorts)
    {
        var sort = sorts?.FirstOrDefault();
        if (sort?.SortOrder == SortOrder.Descending)
        {
            return sort.PropertyName.ToLowerInvariant() switch
            {
                "name" => q => q.OrderByDescending(e => e.Name),
                _ => q => q.OrderByDescending(e => e.Name)
            };
        }

        return sort?.PropertyName.ToLowerInvariant() switch
        {
            "name" => q => q.OrderBy(e => e.Name),
            _ => q => q.OrderBy(e => e.Name)  // Default sort
        };
    }
}
```

## File: Application/Contracts/Repositories/I{Entity}RepositoryTrxn.cs

```csharp
using EF.Data;
using EF.Domain.Contracts;

namespace Application.Contracts.Repositories;

public interface I{Entity}RepositoryTrxn : IRepositoryBase
{
    Task<{Entity}?> Get{Entity}Async(Guid id, bool includeChildren = false, CancellationToken ct = default);
    DomainResult<{Entity}> UpdateFromDto({Entity} entity, {Entity}Dto dto,
        RelatedDeleteBehavior relatedDeleteBehavior = RelatedDeleteBehavior.None);

    // Inherited from RepositoryBase:
    // Task<T?> GetEntityAsync<T>(...)
    // void Create<T>(ref T entity)
    // void UpdateFull<T>(ref T entity)
    // Task DeleteAsync<T>(CancellationToken ct, params object[] keyValues)
    // void Delete<T>(T entity)
    // Task<int> SaveChangesAsync(OptimisticConcurrencyWinner winner, CancellationToken ct)
}
```

## File: Application/Contracts/Repositories/I{Entity}RepositoryQuery.cs

```csharp
using EF.Common;

namespace Application.Contracts.Repositories;

public interface I{Entity}RepositoryQuery
{
    Task<PagedResponse<{Entity}Dto>> Search{Entity}Async(SearchRequest<{Entity}SearchFilter> request, CancellationToken ct = default);
    Task<StaticList<StaticItem<Guid, Guid?>>> Lookup{Entity}Async(Guid? tenantId, string? search, CancellationToken ct = default);
}
```

## Generic Repository Pair (`repositoryContractStyle: hybrid` / `generic-only`)

> **When to use:** an entity with **no bespoke read/write logic** - join entities, append-only logs,
> simple CRUD. Resolve the shared generic pair instead of generating the per-entity classes above.

`IRepositoryBase` already exposes generic-method CRUD/query (`Create<T>(ref T)`, `Delete<T>(T)`,
`GetEntityAsync<T>(...)`, `QueryPageProjectionAsync<T,TProject>(...)`, `SaveChangesAsync(...)`), so the
generic contracts add only entity-typed convenience. They belong in `<packagePrefix>.Data.Contracts` /
`<packagePrefix>.Data` (canonical `EF.*` shown):

```csharp
// EF.Data.Contracts - open-generic contracts
public interface IRepositoryTrxn<TEntity> : IRepositoryBase where TEntity : class
{
    Task<TEntity?> GetAsync(Guid id, CancellationToken ct = default);                // tracked
}
public interface IRepositoryQuery<TEntity> : IRepositoryBase where TEntity : class
{
    Task<TEntity?> GetAsync(Guid id, CancellationToken ct = default);                // no-tracking
    Task<IReadOnlyList<TEntity>> ListAsync(Expression<Func<TEntity, bool>> predicate, CancellationToken ct = default);
}

// EF.Data - generic impls over RepositoryBase (audit id = string, tenant id = Guid?)
public class RepositoryTrxn<TEntity, TDbContext>(TDbContext db)
    : RepositoryBase<TDbContext, string, Guid?>(db), IRepositoryTrxn<TEntity>
    where TEntity : EntityBase where TDbContext : DbContextBase<string, Guid?>
{
    public async Task<TEntity?> GetAsync(Guid id, CancellationToken ct = default)
        => await GetEntityAsync<TEntity>(true, filter: e => e.Id == id, cancellationToken: ct)
            .ConfigureAwait(ConfigureAwaitOptions.None);
}
public class RepositoryQuery<TEntity, TDbContext>(TDbContext db)
    : RepositoryBase<TDbContext, string, Guid?>(db), IRepositoryQuery<TEntity>
    where TEntity : EntityBase where TDbContext : DbContextBase<string, Guid?>
{
    public async Task<TEntity?> GetAsync(Guid id, CancellationToken ct = default)
        => await GetEntityAsync<TEntity>(false, filter: e => e.Id == id, cancellationToken: ct)
            .ConfigureAwait(ConfigureAwaitOptions.None);
    public async Task<IReadOnlyList<TEntity>> ListAsync(Expression<Func<TEntity, bool>> predicate, CancellationToken ct = default)
        => await DB.Set<TEntity>().AsNoTracking().Where(predicate).ToListAsync(ct)
            .ConfigureAwait(ConfigureAwaitOptions.None);
}
```

> **Delivery:** these ship in the `<packagePrefix>.Data` / `<packagePrefix>.Data.Contracts` packages
> (canonical example: EF.Data / EF.Data.Contracts) - see
> [../support/ef-packages-reference.md](../support/ef-packages-reference.md). When
> `packageStrategy: local`/`hybrid`, they are part of the generated `<packagePrefix>.Data` /
> `<packagePrefix>.Data.Contracts` projects.

### Open-generic DI registration (closed-over-context subclass)

`RepositoryBase` needs the concrete `TDbContext`, so the generic impls carry two type parameters and
cannot be registered as a one-arg open generic directly. Generate a one-arg subclass per app that
closes over each context, then register the open generic against it - once, serving every
generic-coverable entity:

```csharp
// Infrastructure.Repositories/{App}GenericRepositories.cs
public sealed class {App}RepositoryTrxn<TEntity>({App}DbContextTrxn db)
    : RepositoryTrxn<TEntity, {App}DbContextTrxn>(db) where TEntity : EntityBase { }
public sealed class {App}RepositoryQuery<TEntity>({App}DbContextQuery db)
    : RepositoryQuery<TEntity, {App}DbContextQuery>(db) where TEntity : EntityBase { }

// Bootstrapper/RegisterServices.Database.cs
services.AddScoped(typeof(IRepositoryTrxn<>), typeof({App}RepositoryTrxn<>));
services.AddScoped(typeof(IRepositoryQuery<>), typeof({App}RepositoryQuery<>));
```

Consumers (services, CQRS handlers) inject `IRepositoryTrxn<{Entity}>` / `IRepositoryQuery<{Entity}>`
and call `GetAsync(id)`, `ListAsync(predicate)`, `Create(ref e)`, `Delete(e)`, `SaveChangesAsync(...)`.

### Split aggregate: bespoke read extends the generic pair

When an aggregate's write side is pure CRUD but its read side needs paged `Search`, fold the write
side into the generic pair and write a slim bespoke query repo that **extends** the generic so
get/list stay inherited (recommended shape for new code):

```csharp
public interface I{Entity}RepositoryQuery : IRepositoryQuery<{Entity}>
{
    Task<PagedResponse<{Entity}Dto>> Search{Entity}sAsync(SearchRequest<{Entity}SearchFilter> request, CancellationToken ct = default);
}
public class {Entity}RepositoryQuery({App}DbContextQuery db)
    : RepositoryQuery<{Entity}, {App}DbContextQuery>(db), I{Entity}RepositoryQuery   // inherits GetAsync/ListAsync
{ /* Search{Entity}sAsync via QueryPageProjectionAsync */ }

services.AddScoped<I{Entity}RepositoryQuery, {Entity}RepositoryQuery>();             // alongside the open-generic pair
```

**Reference-app proof:** `TaskItemTag` (pure join) resolves the generic pair on both sides with no
per-entity class; `Tag` / `Comment` / `ChecklistItem` fold their pure-CRUD write side into the generic
pair (bespoke Trxn interfaces deleted) and keep a bespoke `Search`-bearing query repo. See
`../AI-Instructions-ReferenceApp/src/Infrastructure/TaskFlow.Infrastructure.Repositories/TaskFlowGenericRepositories.cs`
(closed-over-context subclasses; the generic impls they extend come from the EF.Data package).

## Critical: Query Repos MUST Use QueryPageProjectionAsync

**Anti-pattern (manual paging):**
```csharp
// FAIL WRONG - materializes full entities, no projection, manual paging
var query = DB.Categories.AsNoTracking().AsQueryable();
if (filter.Name != null) query = query.Where(...);
var total = await query.CountAsync(ct);
var data = await query.OrderBy(...).Skip(...).Take(...).ToListAsync(ct);
return new PagedResponse<Category> { Data = data, ... };
```

**Correct pattern (base class projection):**
```csharp
// OK CORRECT - SQL-level projection, base class handles paging/count
return await QueryPageProjectionAsync<Category, CategoryDto>(
    CategoryMapper.Projection,
    readNoLock: true,
    pageSize: request.PageSize,
    pageIndex: Math.Max(1, request.PageIndex),
    filter: BuildFilter(request.Filter),
    orderBy: BuildOrderBy(request.Sorts),
    includeTotal: true,
    splitQueryThresholdOptions: SplitQueryThresholdOptions.Default,
    cancellationToken: ct).ConfigureAwait(ConfigureAwaitOptions.None);
```

Every query repo search method must follow this pattern. Use `{Entity}Mapper.Projection` when the search result matches the canonical full DTO shape. Use `{Entity}Mapper.ProjectorSearch` only when the entity has a deliberately lean list/grid shape. The service layer then direct-returns the result without post-mapping.

> **PageIndex pitfall:** `ComposeIQueryable` in EF.Data expects **1-based** `pageIndex` (it does `pageIndex - 1` internally). `SearchRequest<T>.PageIndex` defaults to `0`. Without `Math.Max(1, request.PageIndex)`, a default request produces a negative SQL `OFFSET`, crashing with `SqlException: The offset specified in a OFFSET clause may not be negative`.

## Critical: Delete Pattern (MUST call `Delete(entity)`)

The `Delete` method is inherited from `RepositoryBase`. It marks the entity for deletion in the change tracker. **You MUST call it before `SaveChangesAsync`** - simply loading an entity and saving will NOT delete it.

```csharp
// In service layer (not repository):
var entity = await repoTrxn.Get{Entity}Async(id, false, ct);
if (entity == null) return Result.Success(); // idempotent - not-found returns success
repoTrxn.Delete(entity);                     // marks for deletion
await repoTrxn.SaveChangesAsync(OptimisticConcurrencyWinner.ClientWins, ct);
return Result.Success();
```

> **BUG PATTERN:** Omitting `repoTrxn.Delete(entity)` causes delete operations to silently no-op. This was found and fixed during reference app (TaskFlow) TestContainer testing.

## Critical: SaveChangesAsync - NEVER Use 1-Param Overload

`DbContextBase.SaveChangesAsync(CancellationToken)` **ALWAYS throws `NotImplementedException`** by design. Always use the 2-param overload:

```csharp
// OK CORRECT - always use this
await repoTrxn.SaveChangesAsync(OptimisticConcurrencyWinner.ClientWins, ct);

// FAIL WRONG - throws NotImplementedException at runtime
await repoTrxn.SaveChangesAsync(ct);
```

The 2-param overload retries on `DbUpdateConcurrencyException` using the specified winner strategy.

## Notes

- **Repositories inherit `RepositoryBase<TContext, TAuditId, TTenantId>`** - provides `GetEntityAsync`, `Create(ref)`, `UpdateFull(ref)`, `Delete(entity)`, `DeleteAsync(predicate)`, `SaveChangesAsync(OptimisticConcurrencyWinner, CancellationToken)`, `QueryPageProjectionAsync`, `QueryPageAsync`. These are **protected helpers for repository implementations only** - none of them appear on `IRepositoryQuery<T>` / `IRepositoryTrxn<T>`, so services and handlers can never call them; consumers get `GetAsync` / `ListAsync` plus the bespoke `Search{Entity}sAsync` methods (GR-14)
- **`DB` property** - `RepositoryBase` exposes `protected TDbContext DB => dbContext;` for calling extension methods (e.g. Updater) on the context
- **Generic args:** `TAuditId = string` (matches `IRequestContext.AuditId`), `TTenantId = Guid?` (matches `ITenantEntity<Guid>` - nullable for non-tenant scenarios)
- **`QueryPageProjectionAsync` signature:** `(Expression<Func<T, TProject>> projector, bool readNoLock, int? pageSize, int? pageIndex, Expression<Func<T, bool>>? filter, Func<IQueryable<T>, IOrderedQueryable<T>>? orderBy, bool includeTotal, SplitQueryThresholdOptions?, CancellationToken, params includes[])`
- **`SearchRequest<TFilter>`** is a record: `PageSize` (int), `PageIndex` (int), `Sorts` (IEnumerable\<Sort\>?), `Filter` (TFilter?). Does **not** have `Page`, `PageNumber`, `SortBy`, or `SortDirection`
- **Trxn repository**: Uses `{Project}DbContextTrxn` (tracking, audit interceptor, read-write)
- **Query repository**: Uses `{Project}DbContextQuery` (NoTracking, read-only replica)
- **UpdateFromDto** delegates to `DB.UpdateFromDto(entity, dto, relatedDeleteBehavior)` - a DbContext extension method (see updater-template.md)
- Projectors (`{Entity}Mapper.Projection` by default, `{Entity}Mapper.ProjectorSearch` for intentional lean grid shapes) used in query repo for efficient SQL translation
- No `SaveChangesAsync` override on query repo - read-only by design
- Entity-specific repositories only for bespoke read/write logic; the open-generic `IRepositoryTrxn<T>`/`IRepositoryQuery<T>` pair (see [Generic Repository Pair](#generic-repository-pair-repositorycontractstyle-hybrid--generic-only)) covers simple CRUD / join / append-only entities under `repositoryContractStyle: hybrid`/`generic-only`
- Use `ConfigureAwait(ConfigureAwaitOptions.None)` in repository methods (library code)

---

**TaskFlow proof (local):** `../AI-Instructions-ReferenceApp/src/Infrastructure/TaskFlow.Infrastructure.Repositories/TaskItemRepositoryTrxn.cs` + `TaskItemRepositoryQuery.cs`
**TaskFlow proof (remote fallback):** <https://github.com/efreeman518/AI-Instructions-ReferenceApp/blob/main/src/Infrastructure/TaskFlow.Infrastructure.Repositories/TaskItemRepositoryTrxn.cs>
