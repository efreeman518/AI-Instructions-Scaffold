# Multi-Tenant Architecture

Reference patterns: [../patterns/api-host-wiring.md](../patterns/api-host-wiring.md) (Request Context Resolution), [../patterns/data-layer-wiring.md](../patterns/data-layer-wiring.md) (Multi-tenant Query Filter).

> **Applicability:** This skill applies only when the domain specification enables multi-tenancy. The TaskFlow reference app demonstrates full multi-tenant patterns. For single-tenant scaffolds, skip this entire file - omit `ITenantEntity<TenantId>`, `ITenantBoundaryValidator`, tenant query filters, tenant stamping, and tenant-scoped search enforcement. The service template marks optional sections with `// [MULTI-TENANT]`.

## Purpose

Enforce tenant isolation through data, service, and request-context layers with explicit global-admin escape paths only where intended.

## Enforcement Layers

1. EF query filters on tenant-scoped entities.
2. Service-layer tenant boundary validation.
3. Scoped `IRequestContext` built from authenticated claims (or the explicit local/background fallback paths in [api-host-wiring.md](../patterns/api-host-wiring.md)).

## Non-Negotiables

1. Tenant-scoped entities implement `ITenantEntity<TenantId>`.
2. DbContext applies tenant query filters automatically for tenant entities.
3. Services validate tenant boundary before returning/modifying entity data.
4. Create/update flows derive tenant from request context, not client payload.
5. Global-admin bypass is explicit and auditable.
6. DTOs retain `TenantId` for response/round-trip compatibility, but clients never own write-side tenant selection.

---

## Tenant Entity Contract

```csharp
public interface ITenantEntity<TTenantId>
{
    TTenantId TenantId { get; }
}

public class TodoItem : EntityBase<TodoItemId>, ITenantEntity<TenantId>
{
    public TenantId TenantId { get; init; }
}
```

`TenantId` is a typed value struct (`TenantId : IDomainId<TenantId>`) and is immutable after creation. **Why:** Tenant identity is an ownership boundary, not editable business data; reassignment would turn an update into a cross-tenant move that bypasses query-filter and audit assumptions. Therefore ordinary updates cannot change it.

---

## Automatic Query Filters

```csharp
private void ConfigureTenantQueryFilters(ModelBuilder modelBuilder)
{
    var tenantEntityClrTypes = modelBuilder.Model.GetEntityTypes()
        .Where(et => typeof(ITenantEntity<TenantId>).IsAssignableFrom(et.ClrType))
        .Select(et => et.ClrType);

    foreach (var clrType in tenantEntityClrTypes)
    {
        var filter = BuildTenantFilter(clrType);
        modelBuilder.Entity(clrType).HasQueryFilter(filter);
    }
}
```

Use `IgnoreQueryFilters()` only for explicitly authorized cross-tenant paths (for example, global admin tooling).

**Hand-written tenant filters** (when `BuildTenantFilter` does not fit - e.g. entities implement `ITenantEntity<Guid>` while the context is `DbContextBase<string, Guid?>`): use lifted nullable equality - `e => TenantId == null || e.TenantId == TenantId`. Never `e => !TenantId.HasValue || e.TenantId == TenantId!.Value` - EF parameterizes the captured `TenantId.Value` eagerly regardless of the `||` short-circuit and throws `InvalidOperationException: Nullable object must have a value` at query time when the context tenant is null.

## Tenant Input Models

The scaffold baseline is **server-authoritative with a DTO-carried field**:

- Keep `TenantId` on shared DTOs so read responses, mappers, validators, service/CQRS styles, and existing clients retain one compatible contract.
- Treat the inbound value as untrusted on create/update. Immediately compute `var authoritativeTenantId = RequestTenantId ?? Guid.Empty`, assign it to `dto.TenantId`, then validate and map with `authoritativeTenantId`.
- Never use `RequestTenantId ?? dto.TenantId`. Missing trusted tenant context must fail validation/authorization; a caller-provided value cannot establish ownership.
- Keep `ITenantBoundaryValidator` for loaded-entity access, explicit admin paths, and defense-in-depth reassignment checks.

**Why:** Stamping before validation and mapping makes every downstream check use the same server-owned tenant; validating first either rejects normal empty DTOs or evaluates an attacker-controlled value. Therefore every write path overwrites the DTO first.

Generic service/CQRS create and update paths are tenant-local even for global admins. A cross-tenant admin mutation is a separate, explicitly authorized path: call `EnsureGlobalAdmin`, load the target outside normal query filters, then stamp an update DTO from the loaded entity tenant. A cross-tenant create derives its target from a separately authorized admin contract, never the shared DTO field. Do not route either case through the ordinary request-context stamp.

---

## Request Context Contract

```csharp
public interface IRequestContext<TAuditId, TTenantId>
{
    string CorrelationId { get; }
    TAuditId AuditId { get; }
    TTenantId TenantId { get; }
    IReadOnlyCollection<string> Roles { get; }
}
```

Registration pattern:

- HTTP path: resolve correlation id, audit id, tenant claim, and roles.
- background path: create fallback context with no tenant and synthetic audit id.

---

## Tenant Boundary Validator

Keep centralized service-level checks in `Application.Services/Rules/`.

Core responsibilities:

1. allow global-admin bypass (`AppConstants.ROLE_GLOBAL_ADMIN`),
2. fail when caller has no roles (missing authentication context),
3. fail when non-admin attempts to access a global (null-tenant) entity,
4. fail on tenant mismatch,
5. prevent tenant reassignment after entity creation.

Implementation pattern - `TenantBoundaryValidator` is a thin `internal sealed class` that delegates all logic to static `ValidationHelper`:

```csharp
internal sealed class TenantBoundaryValidator : ITenantBoundaryValidator
{
    public Result EnsureTenantBoundary(ILogger logger, Guid? requestTenantId,
        IReadOnlyCollection<string> roles, Guid? entityTenantId,
        string operation, string entityName, Guid? entityId = null)
        => ValidationHelper.EnsureTenantBoundary(logger, requestTenantId, roles,
            entityTenantId, operation, entityName, entityId);

    public Result EnsureGlobalAdmin(IReadOnlyCollection<string> callerRoles, string operation)
        => ValidationHelper.EnsureGlobalAdmin(callerRoles, operation);

    public Result PreventTenantChange(ILogger logger, Guid? currentTenantId, Guid? newTenantId,
        string entityName, Guid entityId)
        => ValidationHelper.PreventTenantChange(logger, currentTenantId, newTenantId, entityName, entityId);
}
```

Supporting files in `Application.Services/Rules/`:

- **`ValidationHelper`** - static class with the actual boundary logic; uses `[LoggerMessage]` extensions for structured logging.
- **`TenantBoundaryLoggingExtensions`** - `[LoggerMessage]` source-generated extensions (`LogValidationFailure`, `LogTenantFilterManipulation`, `LogTenantChangeAttempt`).
- **`TenantRules`** - simple static rule methods (e.g., `PreventTenantChange` without logging for domain-level use).

---

## Service Usage Rules

For entity reads/writes:

1. load entity (or query projection),
2. enforce `EnsureTenantBoundary(...)`,
3. continue only on success.

For searches:

- non-admin requests must force filter tenant to request context tenant,
- log tenant filter manipulation when client supplies a different tenant ID via `LogTenantFilterManipulation`,
- never trust client-supplied tenant filter as-is.

For updates:

- stamp the request-context tenant before validation,
- after loading and boundary-checking the entity, call `PreventTenantChange(...)` against the stamped value as a defense-in-depth invariant,
- never restore or fall back to the original payload tenant,
- keep generic updates tenant-local; use the explicit admin path above for authorized cross-tenant mutation.

---

## API and Route Considerations

- Tenant-scoped APIs may include `tenantId` in route, but the route value does not establish ownership.
- Apply route-tenant vs claim-tenant policy (`TenantMatch`) at gateway/API boundary.
- Keep cross-tenant endpoints clearly separated and admin-guarded; role membership alone never turns the generic write endpoint into a cross-tenant mutation path.

---

## Data-Access Performance Rule

Use composite tenant access index on hot entities:

```csharp
builder.HasIndex(e => new { e.TenantId, e.Id })
       .HasDatabaseName("CIX_{Entity}_TenantId_Id")
       .IsUnique()
       .IsClustered();
```

---

## Testing Expectations

Minimum test matrix:

1. same-tenant access succeeds,
2. cross-tenant access is rejected,
3. global-admin cross-tenant access succeeds only on explicitly allowed paths (read-only by default),
4. forged create/update DTO `TenantId` is overwritten by request-context tenant before validation/mapping,
5. missing request-context tenant fails even when the DTO supplies a non-empty tenant,
6. tenant-change attempts fail.

---

## Verification

- [ ] tenant entities implement `ITenantEntity<TenantId>`
- [ ] DbContext applies tenant query filters for tenant entities
- [ ] request context resolves tenant/roles from claims (with background fallback)
- [ ] `TenantBoundaryValidator` is used in service operations
- [ ] DTO retains `TenantId`, but create/update flows overwrite it from request context before validation/mapping
- [ ] no write path uses `RequestTenantId ?? dto.TenantId` or otherwise falls back to payload tenant
- [ ] global-admin bypass is explicit and limited
- [ ] generic create/update paths remain tenant-local; any cross-tenant admin mutation has a separate authorization contract
- [ ] tests cover same-tenant, cross-tenant, admin-bypass, forged-payload, and missing-context scenarios
- [ ] cross-check with [application-layer.md](application-layer.md) and [domain-model.md](domain-model.md)
