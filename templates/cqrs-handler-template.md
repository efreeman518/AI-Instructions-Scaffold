# CQRS Handler Template

Use when `.scaffold/resource-implementation.yaml` sets `applicationStyle: cqrs` or `switch`.

Place request records, handlers, validators, and feature registration in `Application.Cqrs/Features/{Entity}/`. Keep shared CQRS helpers in `Application.Cqrs/Features/Shared/`. The root `Registration/CqrsHandlerRegistrationCatalog.cs` aggregates the per-feature registration fragments.

Default scaffold and TaskFlow reference app: keep DTOs in `Application.Models` and static mappers in `Application.Mappers` so service and CQRS styles share one HTTP contract. Full CQRS vertical slice: move feature-specific models, mappers, projections, and adapters into `Application.Cqrs/Features/{Entity}` when they are not shared with service endpoints.

```csharp
namespace {Project}.Application.Cqrs.Features.{EntityPlural};

public sealed record Create{Entity}Command(DefaultRequest<{Entity}Dto> Request)
    : ICommand<Result<DefaultResponse<{Entity}Dto>>>;

internal sealed class Create{Entity}Handler(
    ILogger<Create{Entity}Handler> logger,
    IRequestContext<string, Guid?> requestContext,
    I{Entity}RepositoryTrxn repoTrxn,
    ITenantBoundaryValidator tenantBoundaryValidator)
    : IRequestHandler<Create{Entity}Command, Result<DefaultResponse<{Entity}Dto>>>
{
    public async Task<Result<DefaultResponse<{Entity}Dto>>> HandleAsync(
        Create{Entity}Command command,
        CancellationToken ct = default)
    {
        var dto = command.Request.Item;
        dto.TenantId = requestContext.TenantId ?? Guid.Empty;

        var validation = {Entity}StructureValidator.ValidateCreate(dto);
        if (validation.IsFailure) return Result<DefaultResponse<{Entity}Dto>>.Failure(validation.Errors);

        var boundary = tenantBoundaryValidator.EnsureTenantBoundary(
            logger, requestContext.TenantId, requestContext.Roles, dto.TenantId,
            "{Entity}:Create", nameof({Entity}));
        if (boundary.IsFailure) return Result<DefaultResponse<{Entity}Dto>>.Failure(boundary.ErrorMessage!);

        var entityResult = dto.ToEntity(dto.TenantId);
        if (entityResult.IsFailure) return Result<DefaultResponse<{Entity}Dto>>.Failure(entityResult.ErrorMessage!);

        var entity = entityResult.Value!;
        repoTrxn.Create(ref entity);

        var save = await CqrsHandlerSupport.TrySaveAsync(repoTrxn, logger, "Error creating {Entity}", ct);
        if (save.IsFailure) return Result<DefaultResponse<{Entity}Dto>>.Failure(save.ErrorMessage!);

        return HandlerHelpers.Success(entity.ToDto());
    }
}
```

Rules:

- **Derive repository call sites from the actual contract (GR-14).** Before writing handler bodies, read the repository interface the handler injects (vendored source under `src/Packages/<Prefix>.Data.Contracts`, or [repository-template.md](repository-template.md) section Generic Repository Pair) or the first green handler in the codebase, and call only members that exist there. `IRepositoryQuery<T>` exposes `GetAsync(id)` and `ListAsync(predicate)` - there is no `QueryPageAsync` on it. Paged search goes through the bespoke `I{Entity}RepositoryQuery.Search{Entity}sAsync` (which uses the protected `RepositoryBase.QueryPageProjectionAsync` internally). Do not invent method names from conventions; a plausible name that compiles nowhere costs a fix in every generated handler.
- Avoid central request dispatchers, request buses, and generic `Send()` entrypoints.
- Reason: keep route -> request -> handler flow explicit and registered once.
- One command/query maps to one handler registration.
- Handler injects only repositories and collaborators it uses.
- Reuse existing repository contracts; do not create CQRS-specific repositories unless the domain needs a genuinely different abstraction.
- Keep DTOs in `Application.Models` and mappers in `Application.Mappers` for the default scaffold and TaskFlow reference app. For a CQRS-only or stricter vertical-slice implementation, move feature-specific models, mappers, projections, or adapters into the feature folder when the CQRS contract intentionally differs.
- Use `CqrsHandlerSupport` only for small ceremony: save error handling, search cancellation, best-effort publish, and validation-result mapping. Do not hide create/update/delete flow behind generic base handlers.

Per-feature registration fragment:

```csharp
namespace {Project}.Application.Cqrs.Features.{EntityPlural};

internal static class {Entity}CqrsRegistrations
{
    public static IReadOnlyList<CqrsHandlerRegistration> Registrations { get; } =
    [
        new(typeof(Create{Entity}Command), typeof(Result<DefaultResponse<{Entity}Dto>>), typeof(Create{Entity}Handler)),
    ];
}
```

Root catalog aggregates feature fragments:

```csharp
public static class CqrsHandlerRegistrationCatalog
{
    public static IReadOnlyList<CqrsHandlerRegistration> Registrations { get; } =
    [
        ..{Entity}CqrsRegistrations.Registrations,
    ];
}
```
