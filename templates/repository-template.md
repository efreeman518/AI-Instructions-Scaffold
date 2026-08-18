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
///   TTenantId = Guid? (matches ITenantEntity<TenantId> - nullable for non-tenant scenarios)
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

        var searchText = string.IsNullOrWhiteSpace(search) ? null : search.Trim();

        if (tenantId.HasValue && searchText is not null)
        {
            var typedTenantId = TenantId.From(tenantId.Value);
            filter = e => e.TenantId == typedTenantId && e.Name.Contains(searchText);
        }
        else if (tenantId.HasValue)
        {
            var typedTenantId = TenantId.From(tenantId.Value);
            filter = e => e.TenantId == typedTenantId;
        }
        else if (searchText is not null)
        {
            filter = e => e.Name.Contains(searchText);
        }

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

        var requireTenantId = filter.TenantId.HasValue;
        var tenantId = requireTenantId ? TenantId.From(filter.TenantId.GetValueOrDefault()) : default;
        var hasName = !string.IsNullOrWhiteSpace(filter.Name);
        var name = hasName ? filter.Name.Trim() : string.Empty;
        var hasFlags = filter.Flags.HasValue;
        var flags = filter.Flags.GetValueOrDefault();

        return e =>
            (!requireTenantId || e.TenantId == tenantId) &&
            (!hasName || e.Name.Contains(name)) &&
            (!hasFlags || e.Flags.HasFlag(flags));
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
                "name" => q => q.OrderByDescending(e => e.Name).ThenBy(e => e.Id),
                _ => q => q.OrderByDescending(e => e.Name).ThenBy(e => e.Id)
            };
        }

        return sort?.PropertyName.ToLowerInvariant() switch
        {
            "name" => q => q.OrderBy(e => e.Name).ThenBy(e => e.Id),
            _ => q => q.OrderBy(e => e.Name).ThenBy(e => e.Id)  // Stable default sort
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
>
> **Never for an aggregate root with owned children (GR-15).** A root that owns child collections
> ALWAYS keeps a bespoke `{Root}RepositoryTrxn` + `I{Root}RepositoryTrxn` + `{Root}Updater`, even under
> `generic-only` - regardless of query complexity. `Get{Root}Async(includeChildren)` + `UpdateFromDto`
> graph sync can only live on a bespoke Trxn repo, and `I{Root}RepositoryTrxn` is the only
> Infrastructure-free way to expose include-load + graph-sync to handlers (the application/CQRS layer
> may not reference Infrastructure). Dropping it pushes child writes into the application layer - the
> anemic-aggregate anti-pattern. Generic-only applies to leaf/CRUD/log/join entities only.

`IRepositoryBase` already exposes generic-method CRUD/query (`Create<T>(ref T)`, `Delete<T>(T)`,
`GetEntityAsync<T>(...)`, `QueryPageProjectionAsync<T,TProject>(...)`, `SaveChangesAsync(...)`), so the
generic contracts add only entity-typed convenience. They belong in `<packagePrefix>.Data.Contracts` /
`<packagePrefix>.Data` (canonical `EF.*` shown):

```csharp
// EF.Data.Contracts - open-generic contracts (typed ID overloads)
public interface IRepositoryTrxn<TEntity, TId> : IRepositoryBase
    where TEntity : EntityBase<TId>
    where TId : struct, IDomainId<TId>
{
    Task<TEntity?> GetAsync(TId id, CancellationToken ct = default);                 // tracked
}
public interface IRepositoryQuery<TEntity, TId> : IRepositoryBase
    where TEntity : EntityBase<TId>
    where TId : struct, IDomainId<TId>
{
    Task<TEntity?> GetAsync(TId id, CancellationToken ct = default);                 // no-tracking
    Task<IReadOnlyList<TEntity>> ListAsync(Expression<Func<TEntity, bool>> predicate, CancellationToken ct = default);
}

// EF.Data - generic impls over RepositoryBase (audit id = string, tenant id = Guid?)
public class RepositoryTrxn<TEntity, TId, TDbContext>(TDbContext db)
    : RepositoryBase<TDbContext, string, Guid?>(db), IRepositoryTrxn<TEntity, TId>
    where TEntity : EntityBase<TId>
    where TId : struct, IDomainId<TId>
    where TDbContext : DbContextBase<string, Guid?>
{
    public async Task<TEntity?> GetAsync(TId id, CancellationToken ct = default)
        => await GetEntityAsync<TEntity>(true, filter: e => e.Id == id, cancellationToken: ct)
            .ConfigureAwait(ConfigureAwaitOptions.None);
}
public class RepositoryQuery<TEntity, TId, TDbContext>(TDbContext db)
    : RepositoryBase<TDbContext, string, Guid?>(db), IRepositoryQuery<TEntity, TId>
    where TEntity : EntityBase<TId>
    where TId : struct, IDomainId<TId>
    where TDbContext : DbContextBase<string, Guid?>
{
    public async Task<TEntity?> GetAsync(TId id, CancellationToken ct = default)
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

`RepositoryBase` needs the concrete `TDbContext`, so the generic impls carry entity, ID, and context
type parameters and cannot be registered as a two-arg open generic directly. Generate a two-arg
subclass per app that closes over each context, then register the open generic against it - once, serving every
generic-coverable entity:

```csharp
// Infrastructure.Repositories/{App}GenericRepositories.cs
public sealed class {App}RepositoryTrxn<TEntity, TId>({App}DbContextTrxn db)
    : RepositoryTrxn<TEntity, TId, {App}DbContextTrxn>(db)
    where TEntity : EntityBase<TId>
    where TId : struct, IDomainId<TId> { }

public sealed class {App}RepositoryQuery<TEntity, TId>({App}DbContextQuery db)
    : RepositoryQuery<TEntity, TId, {App}DbContextQuery>(db)
    where TEntity : EntityBase<TId>
    where TId : struct, IDomainId<TId> { }

// Bootstrapper/RegisterServices.Database.cs
services.AddScoped(typeof(IRepositoryTrxn<,>), typeof({App}RepositoryTrxn<,>));
services.AddScoped(typeof(IRepositoryQuery<,>), typeof({App}RepositoryQuery<,>));
```

Consumers (services, CQRS handlers) inject `IRepositoryTrxn<{Entity}, {Entity}Id>` / `IRepositoryQuery<{Entity}, {Entity}Id>`
and call `GetAsync({Entity}Id.From(rawGuid))`, `ListAsync(predicate)`, `Create(ref e)`, `Delete(e)`, `SaveChangesAsync(...)`.

### Split aggregate: bespoke read extends the generic pair

When an aggregate's write side is pure CRUD but its read side needs paged `Search`, fold the write
side into the generic pair and write a slim bespoke query repo that **extends** the generic so
get/list stay inherited (recommended shape for new code):

```csharp
public interface I{Entity}RepositoryQuery : IRepositoryQuery<{Entity}, {Entity}Id>
{
    Task<PagedResponse<{Entity}Dto>> Search{Entity}sAsync(SearchRequest<{Entity}SearchFilter> request, CancellationToken ct = default);
}
public class {Entity}RepositoryQuery({App}DbContextQuery db)
    : RepositoryQuery<{Entity}, {Entity}Id, {App}DbContextQuery>(db), I{Entity}RepositoryQuery   // inherits GetAsync/ListAsync
{ /* Search{Entity}sAsync via QueryPageProjectionAsync */ }

services.AddScoped<I{Entity}RepositoryQuery, {Entity}RepositoryQuery>();             // alongside the open-generic pair
```

**Reference-app proof:** `TaskItemTag` (pure join) resolves the generic pair on both sides with no
per-entity class; `Tag` / `Comment` / `ChecklistItem` fold their pure-CRUD write side into the generic
pair (bespoke Trxn interfaces deleted) and keep a bespoke `Search`-bearing query repo. See
`../scaffold-proof/src/Infrastructure/TaskFlow.Infrastructure.Repositories/TaskFlowGenericRepositories.cs`
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

> **Call it with named arguments - always.** `QueryPageProjectionAsync` takes several same-typed value arguments in the order `readNoLock, pageSize, pageIndex, ..., includeTotal`. A **positional** call compiles fine but is a silent footgun with two failure modes that no in-memory or mocked-repo test can catch: (1) swapping `pageSize`/`pageIndex` returns a near-empty page for a normal `PageIndex=1, PageSize=20` request; (2) passing `includeTotal:false` returns `Total = -1`. Both translate to real SQL that behaves correctly against the fake providers used in fast tests, so only a real-SQL search test (see below) surfaces them. Always pass `readNoLock:`, `pageSize:`, `pageIndex:`, `includeTotal:` by name, as the pattern above does.

> **PageIndex pitfall:** `ComposeIQueryable` in EF.Data expects **1-based** `pageIndex` (it does `pageIndex - 1` internally). `SearchRequest<T>.PageIndex` defaults to `0`. Without `Math.Max(1, request.PageIndex)`, a default request produces a negative SQL `OFFSET`, crashing with `SqlException: The offset specified in a OFFSET clause may not be negative`.

> **Prove it with a real-SQL search test.** Because both the argument-swap and `includeTotal` regressions are invisible to fake providers, every searchable aggregate needs a `Test.Integration` search test against a SQL Testcontainer that asserts the returned page **and** `Total`. This is required at `balanced` and above - it is the specific failure that test exists to catch.

### Paged queries require a deterministic total order

Every order passed to `QueryPageProjectionAsync`, `Skip`, or `Take` must end in a unique tie-breaker. A business column such as `Name`, `Title`, `CreatedAt`, or `Status` is not unique and cannot define stable page boundaries alone. Append `ThenBy(e => e.Id)` (or another immutable unique key) after the requested business sort, including every default and descending branch. The business sort controls presentation; the tie-breaker exists only for deterministic membership. Do not turn this into a universal newest-first or UUID-version policy.

Real-SQL coverage must create more than one page of rows with the same business sort value, read all pages, and assert exact IDs: no duplicate, no omission, stable repeat result, and correct `Total`. In smoke/UI tests, locate the created row by its returned ID or an exact normalized cell value. Substring matches can select another user's row once shared data grows.

## Critical: Value-Converted Predicate Boundary

EF Core cannot translate member access on a value-converted property. This compiles and passes model validation, then fails at runtime against a real relational provider:

```csharp
// FAIL WRONG - member access on converted columns cannot translate to SQL
filter = e => e.TenantId.Value == request.Filter.TenantId!.Value;
filter = u => u.Email.Value.Contains(term);
```

Build typed IDs and value objects from raw filter input before the expression, then compare the whole property:

```csharp
// OK CORRECT - converter handles the typed property comparison
if (filter.TenantId.HasValue)
{
    var tenantId = TenantId.From(filter.TenantId.Value);
    queryFilter = e => e.TenantId == tenantId;
}

if (!string.IsNullOrWhiteSpace(filter.Email))
{
    var email = Email.From(filter.Email);
    queryFilter = u => u.Email == email;
}
```

Applies to `QueryPageProjectionAsync`, `ListAsync`, `Where`, `Any`, `First`, `Single`, `QuerySpec`, search handlers, and message handlers. The `.Value` unwrap idiom is correct only in domain code or post-materialization LINQ-to-objects, for example `entity.Children.First(c => c.Id.Value == id)` or `list.Select(e => e.Id.Value)`.

Prefer typed-to-typed comparison (`e.TenantId == tenantId`) over implicit `Guid` comparison. Value objects with no LIKE-able backing, such as `Email` or `Locale`, are exact matches. Keep `Contains` / `StartsWith` / `LIKE` for plain string columns such as `Name`, `Title`, or `DisplayName`.

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

- **Repositories inherit `RepositoryBase<TContext, TAuditId, TTenantId>`** - provides `GetEntityAsync`, `Create(ref)`, `UpdateFull(ref)`, `Delete(entity)`, `DeleteAsync(predicate)`, `SaveChangesAsync(OptimisticConcurrencyWinner, CancellationToken)`, `QueryPageProjectionAsync`, `QueryPageAsync`. These are **protected helpers for repository implementations only** - none of them appear on `IRepositoryQuery<TEntity, TId>` / `IRepositoryTrxn<TEntity, TId>`, so services and handlers can never call them; consumers get `GetAsync` / `ListAsync` plus the bespoke `Search{Entity}sAsync` methods (GR-14)
- **`DB` property** - `RepositoryBase` exposes `protected TDbContext DB => dbContext;` for calling extension methods (e.g. Updater) on the context
- **Generic args:** `TAuditId = string` (matches `IRequestContext.AuditId`), `TTenantId = Guid?` (matches `ITenantEntity<TenantId>` - nullable for non-tenant scenarios)
- **`QueryPageProjectionAsync` signature:** `(Expression<Func<T, TProject>> projector, bool readNoLock, int? pageSize, int? pageIndex, Expression<Func<T, bool>>? filter, Func<IQueryable<T>, IOrderedQueryable<T>>? orderBy, bool includeTotal, SplitQueryThresholdOptions?, CancellationToken, params includes[])` - call with **named arguments** (adjacent same-typed `pageSize`/`pageIndex` swap silently; see the "Call it with named arguments" note above)
- **`SearchRequest<TFilter>`** is a record: `PageSize` (int), `PageIndex` (int), `Sorts` (IEnumerable\<Sort\>?), `Filter` (TFilter?). Does **not** have `Page`, `PageNumber`, `SortBy`, or `SortDirection`
- **Trxn repository**: Uses `{Project}DbContextTrxn` (tracking, audit interceptor, read-write)
- **Query repository**: Uses `{Project}DbContextQuery` (NoTracking, read-only replica)
- **UpdateFromDto** delegates to `DB.UpdateFromDto(entity, dto, relatedDeleteBehavior)` - a DbContext extension method (see updater-template.md)
- Projectors (`{Entity}Mapper.Projection` by default, `{Entity}Mapper.ProjectorSearch` for intentional lean grid shapes) used in query repo for efficient SQL translation
- No `SaveChangesAsync` override on query repo - read-only by design
- Entity-specific repositories for bespoke read/write logic; the open-generic `IRepositoryTrxn<TEntity, TId>` / `IRepositoryQuery<TEntity, TId>` pair (see [Generic Repository Pair](#generic-repository-pair-repositorycontractstyle-hybrid--generic-only)) covers simple CRUD / join / append-only entities under `repositoryContractStyle: hybrid`/`generic-only`. **Aggregate roots that own child collections ALWAYS get a bespoke `{Root}RepositoryTrxn` + `{Root}Updater` regardless of query complexity or contract style (GR-15)** - the include-load + `UpdateFromDto` graph sync cannot live on the generic pair, and the application/CQRS layer can only reach it through `I{Root}RepositoryTrxn`
- Use `ConfigureAwait(ConfigureAwaitOptions.None)` in repository methods (library code)

---

**TaskFlow proof (local):** `../scaffold-proof/src/Infrastructure/TaskFlow.Infrastructure.Repositories/TaskItemRepositoryTrxn.cs` + `TaskItemRepositoryQuery.cs`
**TaskFlow proof (remote fallback):** <https://github.com/efreeman518/scaffold-proof/blob/main/src/Infrastructure/TaskFlow.Infrastructure.Repositories/TaskItemRepositoryTrxn.cs>
