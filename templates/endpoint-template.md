# Endpoint Template

> **When to read:** Phase 5b, when generating the Minimal API endpoint group for an entity - CRUD + search routes mapped through the entity's service.
> **Skip if:** No API host in scope; entity is internal-only (no public surface); endpoint group already exists.

| | |
|---|---|
| **File** | `Host/{Host}.Api/Endpoints/{Entity}Endpoints.cs` |
| **Depends on** | [service-template](service-template.md), [data-mapping-template](data-mapping-template.md) |
| **Referenced by** | [api.md](../skills/api.md), [test-templates-endpoint.md](test-templates-endpoint.md), [test-templates.md](test-templates.md) |

## File: Host/{Host}.Api/Endpoints/{Entity}Endpoints.cs

Endpoint templates map relative routes only. The API host owns the outer route group and versioning decision, for example `/api/v1/{entity}` for public domain endpoints. Do not bake `/api`, `/v1`, tenant segments, gateway prefixes, health routes, or admin routes into entity endpoint classes.

> **Aggregate-internal children get no standalone write endpoint (GR-15).** This template's `Create` / `Update` / `Delete` routes apply to **aggregate roots** only. If the entity is an internal child of a root (a 1:N owned entity or M:N junction - e.g. a comment or checklist item on a task), do **not** generate a `{Child}Endpoints` write surface. Instead expose the child writes as **nested sub-resource routes on the root's** endpoint class, calling the root's domain methods through a loaded aggregate:
>
> ```csharp
> // In {Root}Endpoints - children are mutated only through the root (GR-15):
> group.MapPost("/{id:guid}/{children}", Add{Child});                       // -> root.Add{Child}(...)
> group.MapPut("/{id:guid}/{children}/{childId:guid}", Update{Child});       // -> child.Update(...)
> group.MapDelete("/{id:guid}/{children}/{childId:guid}", Remove{Child});    // -> root.Remove{Child}(...)
> group.MapPost("/{id:guid}/tags/{tagId:guid}", AssociateTag);              // -> root.AssociateTag(tagId)  (M:N)
> group.MapDelete("/{id:guid}/tags/{tagId:guid}", RemoveTag);               // -> root.RemoveTag(tagId)
> ```
>
> Each nested handler loads the root via its transactional repository, calls the matching `Add*`/`Update`/`Remove*` method, and saves the aggregate in one transaction (return `Success(Item=null)` for a missing root so the shared 2-arg `Match` maps to 404). A child read endpoint (`GetById`/`Search`) is still allowed because reads may cross aggregate boundaries. See [../skills/domain-model.md](../skills/domain-model.md) section Aggregate Roots vs Internal Children.

```csharp
using Microsoft.AspNetCore.Mvc;

namespace {Host}.Api.Endpoints;

public static class {Entity}Endpoints
{
    private static bool _problemDetailsIncludeStackTrace;

    public static IEndpointRouteBuilder Map{Entity}Endpoints(this IEndpointRouteBuilder group, bool problemDetailsIncludeStackTrace)
    {
        _problemDetailsIncludeStackTrace = problemDetailsIncludeStackTrace;

        group.MapPost("/search", Search)
            .Produces<PagedResponse<{Entity}Dto>>(StatusCodes.Status200OK)
            .WithSummary("Search {Entities} with paging, filters, and sorts");

        group.MapGet("/lookup", Lookup)
            .Produces<StaticList<StaticItem<Guid, Guid?>>>(StatusCodes.Status200OK)
            .WithSummary("Lookup list for autocomplete");

        group.MapGet("/{id:guid}", GetById)
            .Produces<DefaultResponse<{Entity}Dto>>(StatusCodes.Status200OK)
            .ProducesProblem(StatusCodes.Status404NotFound)
            .WithSummary("Get a single {Entity}");

        group.MapPost("/", Create)
            .Produces<DefaultResponse<{Entity}Dto>>(StatusCodes.Status201Created)
            .ProducesValidationProblem()
            .WithSummary("Create a new {Entity}");

        group.MapPut("/{id:guid}", Update)
            .Produces<DefaultResponse<{Entity}Dto>>()
            .ProducesValidationProblem()
            .ProducesProblem(StatusCodes.Status404NotFound)
            .WithSummary("Update an existing {Entity}");

        group.MapDelete("/{id:guid}", Delete)
            .Produces(StatusCodes.Status204NoContent)
            .ProducesValidationProblem()
            .WithSummary("Delete a {Entity}");

        return group;
    }

    private static async Task<IResult> Search(
        [FromServices] I{Entity}Service service,
        [FromBody] SearchRequest<{Entity}SearchFilter> request,
        CancellationToken ct)
    {
        var items = await service.SearchAsync(request, ct);
        return TypedResults.Ok(items);
    }

    private static async Task<IResult> Lookup(
        [FromServices] I{Entity}Service service,
        [FromQuery] Guid? tenantId,
        [FromQuery] string? search,
        CancellationToken ct)
    {
        var items = await service.LookupAsync(tenantId, search, ct);
        return TypedResults.Ok(items);
    }

    private static async Task<IResult> GetById(
        [FromServices] I{Entity}Service service, Guid id,
        CancellationToken ct)
    {
        var result = await service.GetAsync(id, ct);
        return result.Match<IResult>(
            response => TypedResults.Ok(response),
            errors => TypedResults.Problem(ProblemDetailsHelper.BuildProblemDetailsResponseMultiple(
                errors: errors, statusCodeOverride: StatusCodes.Status400BadRequest)),
            () => TypedResults.NotFound(id));
    }

    private static async Task<IResult> Create(
        HttpContext httpContext,
        [FromServices] I{Entity}Service service,
        [FromBody] DefaultRequest<{Entity}Dto> request,
        CancellationToken ct)
    {
        var result = await service.CreateAsync(request, ct);
        return result.Match<IResult>(
            response => TypedResults.Created(httpContext.Request.Path, response),
            errors => TypedResults.Problem(ProblemDetailsHelper.BuildProblemDetailsResponseMultiple(
                errors: errors, traceId: httpContext.TraceIdentifier,
                includeStackTrace: _problemDetailsIncludeStackTrace)));
    }

    private static async Task<IResult> Update(
        HttpContext httpContext,
        [FromServices] I{Entity}Service service,
        Guid id,
        [FromBody] DefaultRequest<{Entity}Dto> request,
        CancellationToken ct)
    {
        if (request.Item.Id != null && request.Item.Id != id)
            return TypedResults.Problem(ProblemDetailsHelper.BuildProblemDetailsResponse(
                statusCodeOverride: StatusCodes.Status400BadRequest,
                message: ErrorConstants.ERROR_URL_BODY_ID_MISMATCH));

        var result = await service.UpdateAsync(request, ct);
        return result.Match(
            response => response.Item is null ? Results.NotFound(id) : TypedResults.Ok(response),
            errors => TypedResults.Problem(ProblemDetailsHelper.BuildProblemDetailsResponseMultiple(
                errors: errors, traceId: httpContext.TraceIdentifier,
                includeStackTrace: _problemDetailsIncludeStackTrace)));
    }

    private static async Task<IResult> Delete(
        HttpContext httpContext,
        [FromServices] I{Entity}Service service, Guid id,
        CancellationToken ct)
    {
        var result = await service.DeleteAsync(id, ct);
        return result.Match<IResult>(
            () => TypedResults.NoContent(),
            errors => TypedResults.Problem(ProblemDetailsHelper.BuildProblemDetailsResponseMultiple(
                errors: errors, traceId: httpContext.TraceIdentifier,
                includeStackTrace: _problemDetailsIncludeStackTrace)));
    }
}
```

## Custom Action Routes (Optional)

Include only when `.scaffold/domain-specification.yaml` declares a `customActions` entry on `{Entity}` (e.g. `Reschedule`, `Approve`, `Cancel`). Map the action route inside the same `Map{Entity}Endpoints` extension so each entity's surface stays co-located. See [../skills/api.md](../skills/api.md) section Custom Action Endpoints for routing conventions and the request/response contract.

```csharp
// Inside Map{Entity}Endpoints - add alongside the CRUD routes above:
group.MapPost("/{id:guid}/{action-name}", {ActionName})
    .Produces<DefaultResponse<{Entity}Dto>>(StatusCodes.Status200OK)
    .ProducesValidationProblem()
    .ProducesProblem(StatusCodes.Status404NotFound)
    .WithSummary("{ActionName} a {Entity}");

private static async Task<IResult> {ActionName}(
    HttpContext httpContext,
    [FromServices] I{Entity}Service service,
    Guid id,
    [FromBody] {ActionName}Request request,
    CancellationToken ct)
{
    var result = await service.{ActionName}Async(id, request, ct);
    return result.Match<IResult>(
        response => TypedResults.Ok(response),
        errors => TypedResults.Problem(ProblemDetailsHelper.BuildProblemDetailsResponseMultiple(
            errors: errors, traceId: httpContext.TraceIdentifier,
            includeStackTrace: _problemDetailsIncludeStackTrace)),
        () => TypedResults.NotFound(id));
}
```

The handler shape mirrors `GetById` / `Update` deliberately - same `Result.Match()` three-branch mapping, same `ProblemDetails` builder, same `CancellationToken` placement. The service method invokes the entity's domain method (e.g. `entity.{ActionName}(...)`) and emits `afterAction({ActionName})` per the event model.

## Registration in Pipeline

In `WebApplicationBuilderExtensions.cs`, add to `SetupApiEndpoints`:

```csharp
// Simple pattern (default)
app.MapGroup("/api/{entities}")
    .WithTags("{Entities}")
    .RequireAuthorization()
    .Map{Entity}Endpoints(problemDetailsIncludeStackTrace);

// Versioned + tenant-scoped pattern (when needed)
app.MapGroup("v{apiVersion:apiVersion}/tenant/{tenantId}/{entity}")
    .WithApiVersionSet(apiVersionSet)
    .RequireAuthorization("TenantMatch")
    .Map{Entity}Endpoints(problemDetailsIncludeStackTrace);
```

For kebab-case route segments, use `{entity-route}` in route definitions.

---

**TaskFlow proof (local):** `../AI-Instructions-ReferenceApp/src/Host/TaskFlow.Api/Endpoints/TaskItemEndpoints.cs`
**TaskFlow proof (remote fallback):** <https://github.com/efreeman518/AI-Instructions-ReferenceApp/blob/main/src/Host/TaskFlow.Api/Endpoints/TaskItemEndpoints.cs>

## CQRS Endpoint Variant

When `applicationStyle` is `cqrs` or `switch`, keep route and DTO contracts aligned with the service endpoint, but inject `IRequestHandler<TRequest,TResponse>` for the specific command/query. Do not inject `I{Entity}Service` from CQRS endpoints and do not add a central dispatch step; this keeps route -> request -> handler flow visible at the endpoint.
