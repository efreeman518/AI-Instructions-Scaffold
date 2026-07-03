# Entity Template

> **When to read:** Phase 5a, when generating a new entity class with private setters, factory `Create()`, and rule-based validation.
> **Skip if:** Entity already exists; modifying existing behavior only; non-entity domain work (value objects, domain services).

| | |
|---|---|
| **File** | `Domain.Model/Entities/{Entity}.cs` |
| **Depends on** | [domain-specification-schema.md](../ai/domain-specification-schema.md), [resource-implementation-schema.md](../ai/resource-implementation-schema.md) |
| **Referenced by** | [data-mapping-template](data-mapping-template.md), [ef-configuration-template](ef-configuration-template.md) |

## File: Domain/Shared/Ids/DomainIds.cs

> **Centralized ID types - one file per bounded context, never scattered into individual entity files.**
> Define all domain ID structs here. `TenantId` is typically defined in a shared package; add it here only for apps that own their own tenant concept.

```csharp
using EF.Domain.Contracts;

namespace Domain.Shared.Ids;

public readonly record struct {Entity}Id(Guid Value) : IDomainId<{Entity}Id>
{
    public static {Entity}Id From(Guid value) => new(value);
    public static implicit operator Guid({Entity}Id id) => id.Value;
    public override string ToString() => Value.ToString();
}

// Repeat pattern for each entity ID in the bounded context:
// public readonly record struct {OtherEntity}Id(Guid Value) : IDomainId<{OtherEntity}Id> { ... }
```

> `TenantId` follows the same pattern and is typically shared across the solution (defined once in a shared project or package).

---

## File: Domain/Model/Entities/{Entity}.cs

> **EntityBase properties (inherited, do NOT redefine):**
> - `{Entity}Id Id { get; init; }` - typed domain ID, client-generated via `Guid.CreateVersion7()` (set by the app, not the store; EF `ValueGeneratedNever()`), init-only
> - `byte[]? RowVersion { get; set; }` - nullable, configured via `.IsRowVersion()` in EF config
>
> `EntityBase<TId>` is the generic base where `TId : IDomainId<TId>`. The typed `Id` property replaces the raw `Guid Id`.
>
> **Do NOT inherit `AuditableBase<T>`** unless audit fields must live on the entity itself. The default pattern uses `AuditInterceptor` on the `DbContext` to manage audit metadata externally.

```csharp
using Domain.Shared;
using Domain.Shared.Constants;
using Domain.Shared.Ids;
using EF.Domain;
using EF.Domain.Contracts;

namespace Domain.Model;

public class {Entity} : EntityBase<{Entity}Id>, ITenantEntity<TenantId>  // [MULTI-TENANT] omit ITenantEntity<TenantId> for single-tenant
{
    // ===== Factory Create - the ONLY way to create an instance =====
    public static DomainResult<{Entity}> Create(Guid tenantId, string name, /* additional params */)
    {
        var entity = new {Entity}(TenantId.From(tenantId), name);  // wrap raw Guid on intake
        return entity.Valid().Map(_ => entity);
    }

    // ===== Private constructor - enforces factory usage =====
    private {Entity}(TenantId tenantId, string name)
    {
        TenantId = tenantId;
        Name = name;
    }

    // ===== EF Core parameterless constructor =====
    private {Entity}() { }

    // ===== Properties - private setters enforce immutability outside domain methods =====
    public TenantId TenantId { get; init; }  // init for tenant (set once)
    public string Name { get; private set; } = null!;
    public {ValueObject}? {ValueObjectProperty} { get; private set; } // [VALUE-OBJECT] optional owned value object from domain spec
    public {Entity}Flags Flags { get; private set; } = {Entity}Flags.None;

    // ===== Navigation Properties - ICollection<T>, never List<T> =====
    public ICollection<{ChildEntity}> {ChildEntity}s { get; private set; } = [];

    // ===== Update - returns DomainResult for validation =====
    public DomainResult<{Entity}> Update(string? name = null, {Entity}Flags? flags = null)
    {
        if (name is not null) Name = name;
        if (flags.HasValue) Flags = flags.Value;
        return Valid().Map(_ => this);
    }

    // ===== Child Collection Management =====
    public DomainResult<{ChildEntity}> Add{ChildEntity}({ChildEntity} child)
    {
        var existing = {ChildEntity}s.FirstOrDefault(c => c.Id == child.Id);
        if (existing != null) return DomainResult<{ChildEntity}>.Success(existing);  // Idempotent

        {ChildEntity}s.Add(child);
        return DomainResult<{ChildEntity}>.Success(child);
    }

    public DomainResult Remove{ChildEntity}({ChildEntity} child)
    {
        {ChildEntity}s.Remove(child);
        return DomainResult.Success();  // Desired-state: always succeeds
    }

    public DomainResult Remove{ChildEntity}(Guid id)
    {
        var child = {ChildEntity}s.FirstOrDefault(c => c.Id.Value == id);  // unwrap for Guid comparison
        if (child != null) {ChildEntity}s.Remove(child);
        return DomainResult.Success();  // Desired-state: always succeeds
    }

    // ===== Validation - called by Create() and Update() =====
    private DomainResult<{Entity}> Valid()
    {
        var errors = new List<DomainError>();

        if (TenantId.Value == Guid.Empty) errors.Add(DomainError.Create("Tenant ID cannot be empty.")); // [MULTI-TENANT]
        if (string.IsNullOrWhiteSpace(Name)) errors.Add(DomainError.Create("Name is required."));
        if (Name?.Length < DomainConstants.RULE_DEFAULT_NAME_LENGTH_MIN)
            errors.Add(DomainError.Create($"Name must be at least {DomainConstants.RULE_DEFAULT_NAME_LENGTH_MIN} characters."));
        if (Name?.Length > DomainConstants.RULE_DEFAULT_NAME_LENGTH_MAX)
            errors.Add(DomainError.Create($"Name cannot exceed {DomainConstants.RULE_DEFAULT_NAME_LENGTH_MAX} characters."));

        return errors.Count > 0
            ? DomainResult<{Entity}>.Failure(errors)
            : DomainResult<{Entity}>.Success(this);
    }
}
```

## File: Domain/Model/ValueObjects/{ValueObject}.cs

Generate value objects only when `.scaffold/domain-specification.yaml` declares `valueObjects`. Keep them immutable, domain-side, and free of EF/DTO concerns. Use factories returning `DomainResult<T>` for validation instead of throwing expected domain failures.

```csharp
using EF.Domain.Contracts;

namespace Domain.Model.ValueObjects;

public sealed record {ValueObject}
{
    public string Value { get; }

    private {ValueObject}(string value)
    {
        Value = value;
    }

    public static DomainResult<{ValueObject}> Create(string value)
    {
        if (string.IsNullOrWhiteSpace(value))
            return DomainResult<{ValueObject}>.Failure("{ValueObject} is required.");

        return DomainResult<{ValueObject}>.Success(new {ValueObject}(value.Trim()));
    }

    public override string ToString() => Value;
}
```

### Composing a value object into the entity factory

VO `Create()` short-circuits on the first error (single-error `DomainResult<T>`). The entity **aggregates** across VOs and primitives so the caller sees every field error in one pass. Use two VO construction paths:

- **Validating intake** (`Create` / `Update`): build the VO via `{ValueObject}.Create(raw)` and fold its errors into the same `List<DomainError>` as the primitive checks; materialize the VO property only when the aggregate passes. Do this inside `Valid()` (which runs on both create and update) so both paths aggregate identically - keep the raw input as a backing field the constructor captures.
- **Non-validating materialization** (EF rehydration + internal reconstruction): add a `{ValueObject}.From(raw)` that skips validation and trusts stored data. EF and post-materialization code use `From`, never `Create`.

```csharp
// VO: validating Create for intake, non-validating From for EF/materialization
public static {ValueObject} From(string value) => new(value); // stored data assumed valid

// Entity Valid() folds the VO's DomainResult into the aggregate (no short-circuit)
private DomainResult<{Entity}> Valid()
{
    var errors = new List<DomainError>();
    if (string.IsNullOrWhiteSpace(Name)) errors.Add(DomainError.Create("Name is required."));

    var {vo} = {ValueObject}.Create({voRaw});   // {voRaw}: raw input captured at construction
    if ({vo}.IsFailure) errors.AddRange({vo}.Errors);
    else {ValueObjectProperty} = {vo}.Value;    // materialize only on success

    return errors.Count > 0
        ? DomainResult<{Entity}>.Failure(errors)
        : DomainResult<{Entity}>.Success(this);
}
```

> **Child factory calls (cross-boundary):** When calling a child entity's factory that still accepts raw `Guid`, unwrap the typed ID:
> ```csharp
> {ChildEntity}.Create(TenantId.Value, Id.Value, body);
> ```
> These `.Value` unwraps are domain/post-materialization code. Do not copy this pattern into EF-translated predicates (`Where`, `Any`, `ListAsync`, search `QuerySpec`). In database predicates, build the typed ID outside the expression and compare the whole property, for example `e.TenantId == tenantId`.
> **Optional DomainGuard:** `DomainGuard.NotEmpty(tenantId, nameof(tenantId))` can replace the manual empty-check in `Valid()` for brevity.

## Critical domain-method rules

### `Update()` MUST re-validate (non-negotiable)

Every `Update()` ends with `Valid().Map(_ => this)` - it returns `DomainResult<T>`, never a bare `this`. Mutating fields and returning the entity without re-running `Valid()` lets an update persist invalid state (negative counters, blank required fields) that the factory would have rejected. If a generated `Update()` does not call `Valid()`, it is wrong.

```csharp
// WRONG - skips validation, can persist invalid state
public {Entity} Update(string? name = null) { if (name is not null) Name = name; return this; }

// RIGHT - re-validates, returns DomainResult
public DomainResult<{Entity}> Update(string? name = null)
{
    if (name is not null) Name = name;
    return Valid().Map(_ => this);
}
```

### Lifecycle status is a guarded `Transition`, never a settable `Update` field

When the domain spec declares a `stateMachine` for an entity, the status is **not** a parameter on `Update()`. Expose a dedicated `Transition(target)` that enforces allowed moves and keeps dependent fields aligned (e.g. a completion timestamp). A free-form `Update(status, ...)` lets callers jump to any state and bypass the lifecycle. Use an explicit transition matrix; for compound/guarded transitions, back it with a `{Entity}StatusTransitionRule` (see [domain-rules-template.md](domain-rules-template.md)).

```csharp
public DomainResult<{Entity}> Transition({Entity}Status target)
{
    if (!IsValidTransition(Status, target))
        return DomainResult<{Entity}>.Failure($"Cannot transition from {Status} to {target}.");
    Status = target;
    if (target == {Entity}Status.Completed) CompletedDate = DateTimeOffset.UtcNow;
    return DomainResult<{Entity}>.Success(this);
}

private static bool IsValidTransition({Entity}Status current, {Entity}Status target) =>
    (current, target) switch { /* explicit allowed pairs */ _ => false };
```

Reference: `TaskItem.TransitionStatus` + `IsValidTransition` in the reference app. (Use a non-flags `enum` status for a state machine; `{Entity}Flags` is for independently combinable booleans, not a lifecycle.)

### `DomainError.Create` argument order (GR-14)

`DomainError.Create` takes the **human message FIRST**. `EF.Domain.Contracts` exposes `DomainError.Create(string error)` (no code key) and `DomainError.Create(string error, string code)` (message, then code key). Verify the overload set against the package (GR-14) rather than inferring it. The common, silent bug is emitting the two-arg form with the arguments reversed:

```csharp
// WRONG - code key surfaces as the user-facing message
DomainError.Create("TenantId.Required", "Tenant ID is required.")

// RIGHT - message first
DomainError.Create("Tenant ID is required.", "TenantId.Required")
// or, when no machine code key is needed:
DomainError.Create("Tenant ID is required.")
```

## File: Domain/Shared/{Entity}Flags.cs

```csharp
namespace Domain.Shared;

[Flags]
public enum {Entity}Flags
{
    None = 0,
    IsInactive = 1 << 0,
    IsArchived = 1 << 1,
    IsSuspended = 1 << 2,
    // Add domain-specific flags
}
```

## Polymorphic Join Entity Warning

> **CRITICAL:** When an entity participates as a polymorphic owner (e.g., both `TaskItem` and `Comment` can own `Attachment`), do NOT add `ICollection<PolymorphicChild>` navigation properties to the parent entities. EF auto-generates a real FK constraint from each navigation, creating multiple conflicting FKs on the shared `OwnerId` column. Instead, query polymorphic children explicitly via `OwnerType` + `OwnerId`.

## Polymorphic Ordered Block Note (Optional)

For playlist-driven content entities, model ordered blocks with:

- explicit `Position`
- block discriminator/type
- payload invariants enforced in `Valid()`/domain rules (for example text block requires text, image block requires image URL)

When the child collection property name differs from `{ChildEntity}s`, use the explicit `{Children}` token from [placeholder-tokens.md](../ai/placeholder-tokens.md).

## File: Domain/Model/Entities/{Parent}{Related}.cs (Join Entity)

Default many-to-many join entity pattern - inherits `EntityBase<{Parent}{Related}Id>` with FK on both sides. Only use a pure composite-key join (no `EntityBase`) when confident the join will remain a pure association.

```csharp
using Domain.Shared.Ids;
using EF.Domain;

namespace Domain.Model;

public class {Parent}{Related} : EntityBase<{Parent}{Related}Id>
{
    public static DomainResult<{Parent}{Related}> Create(Guid tenantId, Guid parentId, Guid relatedId)
    {
        var entity = new {Parent}{Related}(TenantId.From(tenantId), {Parent}Id.From(parentId), {Related}Id.From(relatedId));
        return DomainResult<{Parent}{Related}>.Success(entity);
    }

    private {Parent}{Related}(TenantId tenantId, {Parent}Id parentId, {Related}Id relatedId)
    {
        TenantId = tenantId;
        {Parent}Id = parentId;
        {Related}Id = relatedId;
    }

    private {Parent}{Related}() { }

    public TenantId TenantId { get; init; }
    public {Parent}Id {Parent}Id { get; init; }
    public {Related}Id {Related}Id { get; init; }

    public {Parent} {Parent} { get; private set; } = null!;
    public {Related} {Related} { get; private set; } = null!;

    // Add properties as needed (e.g., AssignedDate, SortOrder, CreatedBy)
}
```

**EF Configuration:**
```csharp
// Unique constraint on FK pair (PK is Id from EntityBase)
builder.HasIndex(e => new { e.{Parent}Id, e.{Related}Id }).IsUnique();

builder.HasOne(e => e.{Parent})
    .WithMany(e => e.{Parent}{Related}s)
    .HasForeignKey(e => e.{Parent}Id)
    .OnDelete(DeleteBehavior.Cascade);

builder.HasOne(e => e.{Related})
    .WithMany()
    .HasForeignKey(e => e.{Related}Id)
    .OnDelete(DeleteBehavior.Restrict);
```

---

**TaskFlow proof (local):** `../AI-Instructions-ReferenceApp/src/Domain/TaskFlow.Domain.Model/TaskItem/TaskItem.cs` (full entity with factory + rules), and the `Category/`, `Tag/`, `Comment/`, `ChecklistItem/` sibling folders for relationship variants
**TaskFlow proof (remote fallback):** <https://github.com/efreeman518/AI-Instructions-ReferenceApp/blob/main/src/Domain/TaskFlow.Domain.Model/TaskItem/TaskItem.cs>
