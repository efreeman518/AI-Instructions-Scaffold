# Service Template

> **When to read:** Phase 5b, when generating an application service for an entity - orchestrating repositories, mapping DTOs, returning `Result<T>` / `Result<DefaultResponse>`.
> **Skip if:** Pure projection (no orchestration); query-only with no domain rules; service already exists.

| | |
|---|---|
| **File** | `Application.Services/{Entity}Service.cs` |
| **Depends on** | [repository-template](repository-template.md), [data-mapping-template](data-mapping-template.md), [structure-validator-template](structure-validator-template.md) |
| **Referenced by** | [endpoint-template](endpoint-template.md), [bootstrapper.md](../skills/bootstrapper.md) |

> **Multi-tenant toggle:** Lines marked `// [MULTI-TENANT]` apply only when the domain specification enables multi-tenancy. DTOs retain `TenantId` for response/round-trip compatibility, but write services overwrite it from `IRequestContext` before validation/mapping; clients never select tenant ownership. For single-tenant scaffolds, omit `ITenantBoundaryValidator` injection, tenant stamping, boundary checks, tenant filter enforcement, and `TenantInfoDto` in `DefaultResponse`. TaskFlow demonstrates multi-tenant patterns.

## File: Application/Services/{Entity}Service.cs

```csharp
namespace Application.Services;

internal class {Entity}Service(
    ILogger<{Entity}Service> logger,
    IRequestContext<string, Guid?> requestContext,
    I{Entity}RepositoryTrxn repoTrxn,
    I{Entity}RepositoryQuery repoQuery,
    IInternalMessageBus messageBus,
    IEntityCacheProvider cache,
    IFusionCacheProvider fusionCacheProvider,
    ITenantBoundaryValidator tenantBoundaryValidator) : I{Entity}Service  // [MULTI-TENANT] omit ITenantBoundaryValidator for single-tenant
{
    private readonly IFusionCache _cache = fusionCacheProvider.GetCache(AppConstants.DEFAULT_CACHE);

    private Guid? RequestTenantId => requestContext.TenantId;                           // [MULTI-TENANT]
    private IReadOnlyCollection<string> RequestRoles => requestContext.Roles;            // [MULTI-TENANT]
    private bool IsGlobalAdmin => RequestRoles.Contains(AppConstants.ROLE_GLOBAL_ADMIN); // [MULTI-TENANT]

    #region Helpers

    private static DefaultResponse<{Entity}Dto> BuildResponse({Entity}Dto dto) =>
        new() { Item = dto, TenantInfo = null };  // [MULTI-TENANT] include TenantInfo when available

    #endregion

    // ===== Search =====
    public async Task<PagedResponse<{Entity}Dto>> SearchAsync(
        SearchRequest<{Entity}SearchFilter> request, CancellationToken ct = default)
    {
        // [MULTI-TENANT] enforce tenant filter for non-admin requests
        if (!IsGlobalAdmin)
        {
            request.Filter ??= new();
            if (request.Filter.TenantId is Guid supplied && supplied != RequestTenantId)
            {
                logger.LogTenantFilterManipulation("{Entity}Search", RequestTenantId, supplied);
            }
            request.Filter.TenantId = RequestTenantId;
        }
        return await repoQuery.Search{Entity}Async(request, ct);
    }

    // ===== Get =====
    public async Task<Result<DefaultResponse<{Entity}Dto>>> GetAsync(Guid id, CancellationToken ct = default)
    {
        var entity = await repoTrxn.Get{Entity}Async(id, true, ct);
        if (entity == null) return Result<DefaultResponse<{Entity}Dto>>.None();

        // [MULTI-TENANT]
        var boundary = tenantBoundaryValidator.EnsureTenantBoundary(
            logger, RequestTenantId, RequestRoles, entity.TenantId,
            "{Entity}:Get", nameof({Entity}), entity.Id);
        if (boundary.IsFailure) return Result<DefaultResponse<{Entity}Dto>>.Failure(boundary.ErrorMessage!);

        return Result<DefaultResponse<{Entity}Dto>>.Success(BuildResponse(entity.ToDto()));
    }

    // ===== Create =====
    public async Task<Result<DefaultResponse<{Entity}Dto>>> CreateAsync(
        DefaultRequest<{Entity}Dto> request, CancellationToken ct = default)
    {
        var dto = request.Item;

        // [MULTI-TENANT] Overwrite untrusted payload tenant before validation/mapping.
        // Guid.Empty deliberately fails when trusted tenant context is missing; never fall back to dto.TenantId.
        var authoritativeTenantId = RequestTenantId ?? Guid.Empty;
        dto.TenantId = authoritativeTenantId;

        // [IDENTITY] Stamp owner/created-by from request context when the entity has one - UI-driven
        // creates arrive with an empty owner and would otherwise violate the user FK. The audit id is a
        // real seeded user GUID in dev (ScaffoldAuthHandler -> DevSeedIds.UserId). See
        // ../patterns/api-host-wiring.md section Dev-Mode Write Identity. Omit for ownerless entities.
        // dto.OwnerId = ParseAuditId(requestContext.AuditId); // overwrite untrusted payload

        // Structure validation (delegates to StructureValidators for common checks)
        var validation = {Entity}StructureValidator.ValidateCreate(dto);
        if (validation.IsFailure) return Result<DefaultResponse<{Entity}Dto>>.Failure(validation.Errors);

        // [MULTI-TENANT] Tenant boundary
        var boundary = tenantBoundaryValidator.EnsureTenantBoundary(
            logger, RequestTenantId, RequestRoles, authoritativeTenantId,
            "{Entity}:Create", nameof({Entity}));
        if (boundary.IsFailure) return Result<DefaultResponse<{Entity}Dto>>.Failure(boundary.ErrorMessage!);

        // Create domain entity via factory + UpdateFromDto for children
        var entityResult = dto.ToEntity(authoritativeTenantId)
            .Bind(e => repoTrxn.UpdateFromDto(e, dto));
        if (entityResult.IsFailure)
            return Result<DefaultResponse<{Entity}Dto>>.Failure(entityResult.ErrorMessage);

        var entity = entityResult.Value!;
        repoTrxn.Create(ref entity);

        try
        {
            await repoTrxn.SaveChangesAsync(OptimisticConcurrencyWinner.ClientWins, ct);
        }
        catch (Exception ex)
        {
            return Result<DefaultResponse<{Entity}Dto>>.Failure(ex.GetBaseException().Message);
        }

        await _cache.SetAsync($"{Entity}:{entity.Id}", entity.ToDto(), token: ct);

        // Publish integration event (fire-and-forget - entity is already saved)
        try
        {
            await messageBus.PublishAsync(
                new {Entity}CreatedEvent(entity.Id, entity.TenantId),
                requestContext.CorrelationId, ct);
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Failed to publish {Entity}CreatedEvent for {Id}; entity was saved successfully", entity.Id);
        }

        return Result<DefaultResponse<{Entity}Dto>>.Success(BuildResponse(entity.ToDto()));
    }

    // ===== Update =====
    public async Task<Result<DefaultResponse<{Entity}Dto>>> UpdateAsync(
        DefaultRequest<{Entity}Dto> request, CancellationToken ct = default)
    {
        var dto = request.Item;

        // [MULTI-TENANT] Overwrite untrusted payload tenant before validation/mapping.
        var authoritativeTenantId = RequestTenantId ?? Guid.Empty;
        dto.TenantId = authoritativeTenantId;

        // Structure validation
        var validation = {Entity}StructureValidator.ValidateUpdate(dto);
        if (validation.IsFailure) return Result<DefaultResponse<{Entity}Dto>>.Failure(validation.Errors);

        // Fetch existing
        var entity = await repoTrxn.Get{Entity}Async(dto.Id!.Value, true, ct);
        if (entity == null)
            return Result<DefaultResponse<{Entity}Dto>>.Failure($"{ErrorConstants.ERROR_ITEM_NOTFOUND}: {dto.Id}");

        // [MULTI-TENANT] Tenant boundary
        var boundary = tenantBoundaryValidator.EnsureTenantBoundary(
            logger, RequestTenantId, RequestRoles, entity.TenantId,
            "{Entity}:Update", nameof({Entity}), entity.Id);
        if (boundary.IsFailure) return Result<DefaultResponse<{Entity}Dto>>.Failure(boundary.ErrorMessage!);

        // [MULTI-TENANT] Prevent tenant change
        var tenantChange = tenantBoundaryValidator.PreventTenantChange(
            logger, entity.TenantId, authoritativeTenantId, nameof({Entity}), entity.Id);
        if (tenantChange.IsFailure) return Result<DefaultResponse<{Entity}Dto>>.Failure(tenantChange.ErrorMessage!);

        // Update domain entity via UpdateFromDto (handles children).
        // RelationshipAndEntity: aggregate-edit pages send the full desired child
        // list, so items missing from the DTO must be hard-deleted. Default `None`
        // silently drops client-side removals. If this service is used only by
        // non-aggregate callers that never remove children, drop the 3rd arg.
        var updateResult = repoTrxn.UpdateFromDto(entity, dto, RelatedDeleteBehavior.RelationshipAndEntity);
        if (updateResult.IsFailure)
            return Result<DefaultResponse<{Entity}Dto>>.Failure(updateResult.ErrorMessage);

        try
        {
            await repoTrxn.SaveChangesAsync(OptimisticConcurrencyWinner.ClientWins, ct);
        }
        catch (Exception ex)
        {
            return Result<DefaultResponse<{Entity}Dto>>.Failure(ex.GetBaseException().Message);
        }

        await _cache.SetAsync($"{Entity}:{entity.Id}", entity.ToDto(), token: ct);

        return Result<DefaultResponse<{Entity}Dto>>.Success(BuildResponse(entity.ToDto()));
    }

    // ===== Delete (idempotent - return success if not found) =====
    public async Task<Result> DeleteAsync(Guid id, CancellationToken ct = default)
    {
        var entity = await repoTrxn.Get{Entity}Async(id, false, ct);
        if (entity == null) return Result.Success();  // idempotent

        // [MULTI-TENANT]
        var boundary = tenantBoundaryValidator.EnsureTenantBoundary(
            logger, RequestTenantId, RequestRoles, entity.TenantId,
            "{Entity}:Delete", nameof({Entity}), entity.Id);
        if (boundary.IsFailure) return Result.Failure(boundary.ErrorMessage!);

        repoTrxn.Delete(entity);

        try
        {
            await repoTrxn.SaveChangesAsync(OptimisticConcurrencyWinner.ClientWins, ct);
        }
        catch (Exception ex)
        {
            return Result.Failure(ex.GetBaseException().Message);
        }

        await _cache.RemoveAsync($"{Entity}:{entity.Id}", token: ct);

        return Result.Success();
    }

    // ===== Lookup (autocomplete / dropdowns) =====
    public async Task<StaticList<StaticItem<Guid, Guid?>>> LookupAsync(
        Guid? tenantId, string? search, CancellationToken ct = default)
    {
        // [MULTI-TENANT] Use request-context tenant if not global admin
        if (!IsGlobalAdmin) tenantId = RequestTenantId;
        return await repoQuery.Lookup{Entity}Async(tenantId, search, ct);
    }
}
```

## File: Application/Contracts/Services/I{Entity}Service.cs

```csharp
namespace Application.Contracts.Services;

public interface I{Entity}Service
{
    Task<PagedResponse<{Entity}Dto>> SearchAsync(SearchRequest<{Entity}SearchFilter> request, CancellationToken ct = default);
    Task<Result<DefaultResponse<{Entity}Dto>>> GetAsync(Guid id, CancellationToken ct = default);
    Task<Result<DefaultResponse<{Entity}Dto>>> CreateAsync(DefaultRequest<{Entity}Dto> request, CancellationToken ct = default);
    Task<Result<DefaultResponse<{Entity}Dto>>> UpdateAsync(DefaultRequest<{Entity}Dto> request, CancellationToken ct = default);
    Task<Result> DeleteAsync(Guid id, CancellationToken ct = default);
    Task<StaticList<StaticItem<Guid, Guid?>>> LookupAsync(Guid? tenantId, string? search, CancellationToken ct = default);
}
```

## Common Mistakes (Verified via Test Failures)

1. **Delete no-op** - Forgetting `repoTrxn.Delete(entity)` before `SaveChangesAsync`. The entity is loaded but never marked for deletion. Save commits nothing.
2. **CreateAsync incomplete** - `Entity.Create()` only accepts factory constructor args. Additional DTO properties (e.g., `EstimatedHours`, `ActualHours`, `Description`) must be applied via `entity.Update(...)` after creation. If omitted, domain validation that depends on those fields won't trigger.
3. **Wrong SaveChangesAsync** - `DbContextBase.SaveChangesAsync(CancellationToken)` throws `NotImplementedException` by design. Must use `SaveChangesAsync(OptimisticConcurrencyWinner.ClientWins, ct)`.
4. **Post-mapping search results** - When the query repo uses `QueryPageProjectionAsync` and returns `PagedResponse<{Entity}Dto>`, the service MUST direct-return: `return await repoQuery.Search{Entity}Async(request, ct);`. Do NOT re-wrap into a new `PagedResponse` or call `.ToDto()` - the projection already happened at the SQL level.
5. **Missing UpdateFromDto mock in tests** - `CreateAsync` uses `.Bind(e => repoTrxn.UpdateFromDto(e, dto))` and `UpdateAsync` calls `repoTrxn.UpdateFromDto(entity, dto, RelatedDeleteBehavior.RelationshipAndEntity)`. If tests don't mock `UpdateFromDto`, they get `NullReferenceException`. Always mock with `It.IsAny<RelatedDeleteBehavior>()` so both call shapes match: `_repoTrxnMock.Setup(r => r.UpdateFromDto(It.IsAny<{Entity}>(), It.IsAny<{Entity}Dto>(), It.IsAny<RelatedDeleteBehavior>())).Returns((Entity e, EntityDto _, RelatedDeleteBehavior _) => DomainResult<{Entity}>.Success(e));`
6. **[Multi-tenant] Missing authoritative TenantId stamp** - Immediately after `var dto = request.Item;`, compute `var authoritativeTenantId = RequestTenantId ?? Guid.Empty`, overwrite `dto.TenantId`, then validate/map with `authoritativeTenantId`. Never use `RequestTenantId ?? dto.TenantId`; that lets a forged payload establish ownership when trusted context is absent.
7. **Update not-found returns Failure** - Use `Result<DefaultResponse<{Entity}Dto>>.Failure($"{ErrorConstants.ERROR_ITEM_NOTFOUND}: {dto.Id}")`, not `Success` with `Item = null`.
8. **Inline entity name strings** - Always use `nameof({Entity})` in boundary-validator calls and error messages, not hardcoded strings.
9. **Missing BuildResponse** - All success paths should use the private static `BuildResponse` helper, not inline `new() { Item = ... }`.
10. **[Multi-tenant] Missing PreventTenantChange in Update** - After boundary check, before domain update, compare the existing entity tenant with the stamped authoritative tenant as a defense-in-depth invariant.
11. **Invented repository members (GR-14)** - Call only members that exist on the injected contract. Read the interface (or the first green service/handler in the codebase) before writing call sites. `IRepositoryQuery<TEntity, TId>` exposes `GetAsync(id)` / `ListAsync(predicate)`; paged search lives on the bespoke `I{Entity}RepositoryQuery.Search{Entity}Async`. There is no `QueryPageAsync` on the consumer-facing contracts - `QueryPageAsync` / `QueryPageProjectionAsync` are protected `RepositoryBase` helpers, callable only inside repository implementations.

## Policy Notes

- Monetary and time-boundary sensitive logic should be delegated to dedicated policy services (for example money calculation, entitlement resolution, and period boundary policy) rather than hard-coded inside endpoint handlers.

---

**TaskFlow proof (local):** `../scaffold-proof/src/Application/TaskFlow.Application.Services/TaskItemService.cs` + companion `Rules/TaskItemStructureValidator.cs` (multi-tenant variant) and `Rules/ServiceErrorMessages.cs`
**TaskFlow proof (remote fallback):** <https://github.com/efreeman518/scaffold-proof/blob/main/src/Application/TaskFlow.Application.Services/TaskItemService.cs>
