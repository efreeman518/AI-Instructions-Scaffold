# Data Mapping Template (DTOs + Mappers)

| | |
|---|---|
| **Files** | `Application.Models/{Entity}/{Entity}Dto.cs`, `{Entity}SearchFilter.cs`, `{ChildEntity}Dto.cs`, `Application.Mappers/{Entity}Mapper.cs`, `Application.Mappers/{ChildEntity}Mapper.cs` |
| **Depends on** | [entity-template](entity-template.md) |
| **Referenced by** | [service-template](service-template.md), [endpoint-template](endpoint-template.md), [repository-template](repository-template.md) |

## DTOs

### File: Application/Models/{Entity}/{Entity}Dto.cs

```csharp
using EF.Domain.Contracts;

namespace Application.Models.{Entity};

public record {Entity}Dto : EntityBaseDto, ITenantEntityDto
{
    [Required]
    public Guid TenantId { get; set; }

    [Required]
    public string Name { get; set; } = null!;

    public {Entity}Flags Flags { get; set; } = {Entity}Flags.None;

    // Child collections
    public List<{ChildEntity}Dto> {ChildEntity}s { get; set; } = [];

    // Navigation (read-only, populated by mapper)
    public {Parent}Dto? Parent { get; set; }
}
```

### File: Application/Models/{Entity}/{ChildEntity}Dto.cs

```csharp
using EF.Domain.Contracts;

namespace Application.Models.{Entity};

public record {ChildEntity}Dto : EntityBaseDto
{
    public Guid? {Entity}Id { get; set; }
    // ... properties
}
```

### File: Application/Models/{Entity}/{Entity}SearchFilter.cs

```csharp
namespace Application.Models.{Entity};

public record {Entity}SearchFilter : DefaultSearchFilter
{
    public string? Name { get; set; }
    public {Entity}Flags? Flags { get; set; }
}
```

### Base DTO Types (from Application.Models/Shared/)

```csharp
// DefaultSearchFilter - base for all search filters (Application.Models/)
public record DefaultSearchFilter
{
    public string? SearchTerm { get; set; }
    public Guid? TenantId { get; set; }
}

public abstract record EntityBaseDto : IEntityBaseDto
{
    public Guid? Id { get; set; }
}

public interface IEntityBaseDto
{
    Guid? Id { get; set; }
}

public interface ITenantEntityDto
{
    Guid TenantId { get; set; }
}
```

### DTO Rules

- DTOs are `record` types (value equality, `with` expressions)
- DTOs live in `Application.Models/{Entity}/` -- separate project from contracts
- `Id` is `Guid?` -- null on Create, required on Update (inherited from `EntityBaseDto`)
- `TenantId` is `Guid` (non-nullable) -- always required
- Search filters are `record` types inheriting `DefaultSearchFilter` (provides `SearchTerm` and `TenantId`). Add only entity-specific filter properties.
- Audit fields (CreatedDate, etc.) may be included as read-only properties on response DTOs via `IEntityBaseDto` -- the `AuditInterceptor` on the DbContext manages write-side audit data
- Child collections default to empty list -- never null
- Use `{Entity}Flags` (flags enum) instead of a separate Status enum

## Mappers

### File: Application/Mappers/{Entity}Mapper.cs

```csharp
using System.Linq.Expressions;
using EF.Common;
using EF.Domain.Contracts;  // DomainResult<T> lives here, NOT in EF.Domain

namespace Application.Mappers;

public static class {Entity}Mapper
{
    // ===== Canonical full shape (EF-safe projection + compiled ToDto) =====
    // Use this shape for detail/get queries and in-memory mapping. Keep child DTOs inline:
    // EF cannot translate child .ToDto() method calls inside expressions.
    public static readonly Expression<Func<{Entity}, {Entity}Dto>> Projection =
        entity => new {Entity}Dto
        {
            Id = entity.Id,
            TenantId = entity.TenantId,
            Name = entity.Name,
            Flags = entity.Flags,
            {ChildEntity}s = entity.{ChildEntity}s.Select(c => new {ChildEntity}Dto
            {
                Id = c.Id,
                {Entity}Id = c.{Entity}Id,
                // ... child properties mapped directly
            }).ToList(),
            Parent = entity.Parent != null
                ? new {Parent}Dto
                {
                    Id = entity.Parent.Id,
                    // ... parent properties mapped directly
                }
                : null
        };

    private static readonly Func<{Entity}, {Entity}Dto> Compiled = Projection.Compile();

    public static {Entity}Dto ToDto(this {Entity} entity) => Compiled(entity);

    // ===== DTO -> Entity (factory, returns DomainResult) =====
    public static DomainResult<{Entity}> ToEntity(this {Entity}Dto dto, Guid tenantId)
    {
        return {Entity}.Create(tenantId, dto.Name);
    }

    // ===== Query-shape-only projectors (Expression<Func<T, TDto>>) =====

    // Optional lean projection for lists/grids when search results intentionally differ
    // from the canonical full shape. If search uses the full DTO shape, use Projection.
    public static readonly Expression<Func<{Entity}, {Entity}Dto>> ProjectorSearch =
        entity => new {Entity}Dto
        {
            Id = entity.Id,
            TenantId = entity.TenantId,
            Name = entity.Name,
            Flags = entity.Flags
            // No child collections for search results
        };

    // Lookup projection for dropdowns/autocompletes
    public static readonly Expression<Func<{Entity}, StaticItem<Guid, Guid?>>> ProjectorStaticItems =
        entity => new StaticItem<Guid, Guid?>(entity.Id, entity.Name, null);
}
```

### File: Application/Mappers/{ChildEntity}Mapper.cs

```csharp
using System.Linq.Expressions;

namespace Application.Mappers;

public static class {ChildEntity}Mapper
{
    public static readonly Expression<Func<{ChildEntity}, {ChildEntity}Dto>> Projection =
        entity => new {ChildEntity}Dto
        {
            Id = entity.Id,
            // ... properties
        };

    private static readonly Func<{ChildEntity}, {ChildEntity}Dto> Compiled = Projection.Compile();

    public static {ChildEntity}Dto ToDto(this {ChildEntity} entity) => Compiled(entity);
}
```

### Mapper Rules

- Mappers are **static classes** in `Application.Mappers/` -- separate project, no DI, no state
- **`Projection`** -- Canonical full DTO shape. EF uses it with `.Select(Projection)`; `ToDto()` reuses its compiled delegate for in-memory mapping.
- **`ToDto()`** -- Extension method on entity. Route through cached `Projection.Compile()` delegate, not a second hand-written mapping.
- **`ToEntity()`** -- Extension method on DTO. Returns `DomainResult<T>` (delegates to domain factory).
- **Query-shape projectors** -- `ProjectorSearch` and `ProjectorStaticItems` are only for shapes with no `ToDto()` twin. Keep them EF-safe.
- **Multiple projectors per entity** -- `Projection` is the canonical full shape. Add `ProjectorSearch` only when list/grid rows intentionally omit fields or children. Keep `ProjectorStaticItems` for lookup DTOs.
- **No mapper registration** -- Static classes, no DI needed.
- **No audit fields** -- Audit data (CreatedDate, CreatedBy, etc.) is managed by the `AuditInterceptor`, not mapped on DTOs

### Compile-Projection Caveats

- Use the compile-projection pattern only for DTO shapes that have both an EF call site and an in-memory call site. Query-only shapes (`ProjectorSearch`, `ProjectorStaticItems`) do not need compiled delegates.
- `Projection` must stay EF-translatable and also evaluate correctly in memory. Use property access, explicit null checks (`entity.X != null ? entity.X.Y : null`), and inline `.Select(...).ToList()` for child collections.
- Do not call mapper methods, `ToString(format)`, C#-only helpers, or complex ternaries inside `Projection`.
- Owned-type flattening must satisfy both constraints. Example: `TaskItem.DateRange -> StartDate / DueDate` and `TaskItem.RecurrencePattern -> RecurrenceInterval / RecurrenceFrequency / RecurrenceEndDate` should use direct property access plus null checks.
- A projection can translate in EF but still throw in memory if a navigation or owned value is unset on a hydrated entity. Mapper parity tests must exercise these paths.

## Child Collection Mapping

> **Aggregate-root DTOs MUST carry their owned child collections, and the root `Projection`/`ToDto` MUST project them (non-negotiable).** The `{Root}Updater.UpdateFromDto` graph sync diffs `dto.{ChildEntity}s` against the loaded aggregate; if the root DTO omits the child collection or `ToDto` does not populate it, the updater has nothing to diff and child writes silently no-op. A flat parent DTO is the most common cause of "child saves are lost." Generation rule: for every `one-to-many`/`one-to-one`/`many-to-many` child in the domain spec, the root DTO declares `List<{ChildEntity}Dto>? {ChildEntity}s` and the root `Projection` includes the inline `.Select(...).ToList()` for it.
>
> **Null vs present contract** (mirrors the null-coalesce note in [updater-template.md](updater-template.md)): a **null** child collection on the incoming DTO means "don't touch these children"; a **present** collection (including empty) means "this is the desired full set" - items missing from it are removed when the caller passes `RelatedDeleteBehavior.RelationshipAndEntity`. Response DTOs always populate the collection (empty, never null) so clients can round-trip an edit.

Child collections follow a consistent pattern across both DTOs and Mappers:

### DTO Side
- Parent DTO declares `List<{ChildEntity}Dto> {ChildEntity}s { get; set; } = [];` -- always initialized, never null
- Child DTO inherits from `EntityBaseDto` and includes a nullable foreign key: `Guid? {Entity}Id`
- Child DTO lives in the same namespace as the parent: `Application.Models.{Entity}/`

### Mapper Side
- **`Projection`** maps children inline with DTO constructors; EF cannot translate child `.ToDto()` calls inside expressions.
- **`ToDto()`** routes through the cached compiled `Projection` delegate.
- **`ToEntity()`** only creates the parent via the domain factory -- child collections are handled separately by `repoTrxn.UpdateFromDto()` in the service layer
- **`ProjectorSearch`** omits child collections for performance only when list/grid results intentionally use a lean shape
- **`Projection`** includes child collections with inline projection (no method calls -- must remain EF-safe):
  ```csharp
  {ChildEntity}s = entity.{ChildEntity}s.Select(c => new {ChildEntity}Dto
  {
      Id = c.Id,
      // ... child properties mapped directly
  }).ToList()
  ```

### Service Layer Integration
- On **Create**: `dto.ToEntity(tenantId)` builds the parent, then `repoTrxn.UpdateFromDto(entity, dto)` syncs child collections
- On **Update**: The existing entity is fetched with includes, then `repoTrxn.UpdateFromDto(entity, dto)` diffs and syncs children (adds new, updates existing, removes missing)
- The repository's `UpdateFromDto` handles the EF change-tracking for child add/update/remove -- mappers do not manage this
