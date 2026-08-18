# API

> **When to read:** Phase 5b, when building ASP.NET Core Minimal API endpoint groups, `ProblemDetails` exception handling, or the API host's middleware pipeline.
> **Skip if:** No API host in scope (e.g., scheduler-only or function-app-only scaffold); UI work; gateway-only work (see `gateway.md`).

## Generated Endpoint Shape

Use [endpoint-template.md](../templates/endpoint-template.md) as the canonical service-style endpoint implementation. It owns generated CRUD/search routes, handler signatures, `Result.Match()` response mapping, OpenAPI metadata, and pipeline registration examples. This skill owns the surrounding API host, policy, binding-hazard, versioning, and service/CQRS route-switch rules.

## Overview

Use ASP.NET Core Minimal APIs with endpoint classes (no controllers), `ProblemDetails`, and deterministic middleware ordering.

Reference patterns: [../patterns/api-host-wiring.md](../patterns/api-host-wiring.md) (API Startup Sequence, Middleware Pipeline).

## Required Layout

```
Host/{Host}.Api/
|-- Program.cs
|-- RegisterApiServices.cs
|-- WebApplicationBuilderExtensions.cs
|-- Endpoints/{Entity}Endpoints.cs
|-- Auth/
|-- HealthChecks/
|-- Middleware/
`-- Properties/
    `-- launchSettings.json   # REQUIRED - sets ASPNETCORE_ENVIRONMENT=Development
```

`launchSettings.json` must exist so that running under Aspire (or `dotnet run`) sets the correct environment. Without it, `IsDevelopment()` returns false, Scalar is skipped, and the API port is not surfaced in the Aspire dashboard.

Minimal `Properties/launchSettings.json`:

```json
{
  "profiles": {
    "http": {
      "commandName": "Project",
      "dotnetRunMessages": true,
      "launchBrowser": false,
      "applicationUrl": "http://localhost:5100",
      "environmentVariables": { "ASPNETCORE_ENVIRONMENT": "Development" }
    },
    "https": {
      "commandName": "Project",
      "dotnetRunMessages": true,
      "launchBrowser": false,
      "applicationUrl": "https://localhost:7100;http://localhost:5100",
      "environmentVariables": { "ASPNETCORE_ENVIRONMENT": "Development" }
    }
  }
}
```

## Startup Pattern

In `Program.cs`, keep this order: service defaults/config -> bootstrapper + API registration -> build -> pipeline -> startup tasks -> run.

```csharp
var builder = WebApplication.CreateBuilder(args);

// JSON contract: the API host's serializer shape MUST match the Refit client
// and the endpoint-test deserializer. The Blazor / Uno Refit clients use
// JsonStringEnumConverter (see ui-blazor.md). Without the matching converter
// here, the host returns numeric enums and rejects string-enum bodies with
// "JsonException: The JSON value could not be converted to <Enum>", surfacing
// as a 400 on every list/filter/search request that carries an enum.
builder.Services.ConfigureHttpJsonOptions(options =>
{
    options.SerializerOptions.Converters.Add(
        new System.Text.Json.Serialization.JsonStringEnumConverter());
    options.SerializerOptions.PropertyNameCaseInsensitive = true;
    options.SerializerOptions.DefaultIgnoreCondition =
        System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull;
});

builder.AddServiceDefaults();
services
    .RegisterInfrastructureServices(config)
    .RegisterDomainServices(config)
    .RegisterApplicationServices(config)
    .RegisterBackgroundServices(config)
    .AddApiServices(config, startupLogger);

var app = builder.Build().ConfigurePipeline();
await app.RunStartupTasks();
await app.RunAsync();
```

### JSON Contract Across Hosts and Tests

**Rule:** The JSON serializer shape is a contract between three places - keep all three aligned:

1. **API host** - `ConfigureHttpJsonOptions(...)` (above) governs request **and** response serialization.
2. **Refit client** (Blazor / Uno) - `SystemTextJsonContentSerializer(jsonOptions)` in [`ui-blazor.md`](ui-blazor.md) (`Program.cs`) and the analogous Uno wire-up.
3. **Endpoint tests** - every `ReadFromJsonAsync<T>` / `PostAsJsonAsync<T>` call must use a shared `JsonSerializerOptions` instance with the same converters.

If any of the three drifts, requests fail with `JsonException` on the host (string enum rejected as 400) or tests fail to deserialize valid responses (default `ReadFromJsonAsync` decodes numeric enums but not string enums).

The endpoint test base must publish the shared options:

```csharp
// tests/Test.Support/JsonTestOptions.cs
public static class JsonTestOptions
{
    public static readonly JsonSerializerOptions Default = new()
    {
        PropertyNameCaseInsensitive = true,
        Converters = { new JsonStringEnumConverter() },
    };
}
```

Endpoint tests then always pass it explicitly:

```csharp
var created = await response.Content.ReadFromJsonAsync<DefaultResponse<TaskItemDto>>(JsonTestOptions.Default);
await client.PostAsJsonAsync("/api/task-items", new DefaultRequest<TaskItemDto> { Item = dto }, JsonTestOptions.Default);
```

Centralize on `JsonTestOptions.Default`; do **not** construct ad-hoc `JsonSerializerOptions` per test - drift between tests masks contract regressions.

### Standalone CORS (Without Aspire)

When the API runs without Aspire orchestration (e.g. `dotnet run --launch-profile https` directly), the browser WASM client cannot reach it without an explicit CORS policy. Add this before authentication middleware:

```csharp
const string UiPolicy = "UiCors";
builder.Services.AddCors(options =>
    options.AddPolicy(UiPolicy, policy =>
        policy.WithOrigins("https://localhost:{uiPort}", "http://localhost:{uiPort}")
              .AllowAnyHeader()
              .AllowAnyMethod()));

// In pipeline, before UseAuthentication:
app.UseCors(UiPolicy);
```

Note: Aspire-hosted deployments typically handle CORS through the gateway - only add direct API CORS for standalone dev scenarios.

## Service Registration

`RegisterApiServices.cs` owns API-only concerns (public method: `AddApiServices`):

- Entra auth + authorization policies (admin role, user role)
- `DefaultExceptionHandler` + `ProblemDetails`
- OpenAPI/Scalar (feature-flagged via `OpenApiSettings:Enable`)
- Rate limiting
- `IClaimsTransformation` for Gateway-forwarded claims

## Pipeline + Versioned Groups

Use an explicit route-versioning boundary. Public business/domain API contracts should normally live under a versioned group such as `/api/v1/*`. Operational, host-management, health, gateway, and package-owned admin surfaces should stay unversioned unless they are part of the public client contract. Examples: `/health/*`, `/alive`, `/healthz`, `/api/flowengine/*`, gateway root/proxy health, and Azure Functions host health (`/api/health` with the Functions default prefix).

Endpoint classes should map relative routes only; the host decides whether the containing group is versioned.

Keep API version metadata in one host-owned type so routing, API versioning, OpenAPI, Scalar, tests, and clients do not drift:

```csharp
internal static class ApiContract
{
    public const string Title = "{App} API";
    public const string Description = "Multi-tenant {App} API";
    public const string ApiExplorerGroupNameFormat = "'v'VVV";
    public const string VersionedRoutePrefix = "/api/v{apiVersion:apiVersion}";

    public static readonly ApiDocument V1 = new(new ApiVersion(1, 0), "v1");
    public static readonly IReadOnlyList<ApiDocument> SupportedDocuments = [V1];

    public static ApiVersion DefaultVersion => V1.Version;
    public static string DefaultGroupName => V1.GroupName;
}

internal sealed record ApiDocument(ApiVersion Version, string GroupName)
{
    public string DisplayName => GroupName;
}
```

`WebApplicationBuilderExtensions.cs` must preserve middleware order:
SecurityHeaders -> CorrelationId -> ExceptionHandler -> RateLimiter -> CORS -> Authentication -> Authorization.

Map versioned groups and apply policy at the group level (adjust route pattern to project needs - tenant-scoped, versioned, or simple `/api/` prefix):

```csharp
// Simple pattern for unversioned/internal routes when a versioned public contract is not needed.
app.MapGroup("/api/categories")
    .WithTags("Categories")
    .RequireAuthorization()
    .MapCategoryEndpoints(problemDetailsIncludeStackTrace);

// Versioned public contract pattern.
var apiVersionSetBuilder = app.NewApiVersionSet()
    .ReportApiVersions()
foreach (var document in ApiContract.SupportedDocuments)
    apiVersionSetBuilder.HasApiVersion(document.Version);

var apiVersionSet = apiVersionSetBuilder.Build();

var api = app.MapGroup(ApiContract.VersionedRoutePrefix)
    .WithApiVersionSet(apiVersionSet)
    .MapToApiVersion(ApiContract.DefaultVersion)
    .RequireAuthorization("TenantMatch");

api.MapGroup("/categories")
    .MapCategoryEndpoints(problemDetailsIncludeStackTrace);
```

## Endpoint Contract

Each entity exposes one static mapper: `Map{Entity}Endpoints(this IEndpointRouteBuilder group, ...)`.
The canonical mapper, route set, metadata, and handler implementation live in [endpoint-template.md](../templates/endpoint-template.md).

Required endpoint rules:

1. Static class + static handlers.
2. Use `TypedResults` for success responses.
3. **Use `Result.Match()` - never `IsSuccess`/`else` guards.** Every handler must branch through `Result.Match<IResult>()`. Three branches for `Result<T>` (success, errors, none); two branches for non-generic `Result` (success, errors). The `none` branch is the only correct way to produce a `404` - omitting it silently returns `200 OK` for not-found cases.
   ```csharp
   // Typed result (3 branches)
   return result.Match<IResult>(
       value  => TypedResults.Ok(new DefaultResponse<T>(value)),
       errors => TypedResults.Problem(ProblemDetailsHelper.BuildProblemDetailsResponseMultiple(
                     errors: errors, statusCodeOverride: StatusCodes.Status400BadRequest,
                     traceId: httpContext.TraceIdentifier, includeStackTrace: _problemDetailsIncludeStackTrace)),
       ()     => TypedResults.NotFound());

   // Non-generic Result (2 branches - fire-and-forget commands)
   return result.Match<IResult>(
       ()     => TypedResults.Ok(),
       errors => TypedResults.Problem(ProblemDetailsHelper.BuildProblemDetailsResponseMultiple(
                     errors: errors, statusCodeOverride: StatusCodes.Status400BadRequest,
                     traceId: httpContext.TraceIdentifier, includeStackTrace: _problemDetailsIncludeStackTrace)));
   ```
4. **Handler signature:** `HttpContext httpContext` must be the first parameter on every handler (needed for `traceId` in `ProblemDetailsHelper`). `CancellationToken` is the last parameter. **Every service-typed parameter MUST carry an explicit `[FromServices]` attribute.** This is non-negotiable.
   ```csharp
   private static async Task<IResult> GetById(
       HttpContext httpContext,
       [FromServices] IMyService service, Guid id, CancellationToken ct)
   ```

   **Why this is non-negotiable.** Without `[FromServices]`, minimal-API parameter binding falls back to `IServiceProviderIsService.IsService(type)` at *route discovery time* (before any request fires). If the type is registered -> parameter is bound from DI; if **not** registered -> parameter is inferred as `[FromBody]` and the host throws `System.InvalidOperationException: Body was inferred but the method does not allow inferred body parameters` at `app.MapGroup(...)`. The failure takes down **every** endpoint, not just the unregistered one.

   This is especially fragile when a feature is gated per host (Cosmos-only services, Service Bus senders - see [bootstrapper.md](bootstrapper.md) section Conditional (Per-Host) Dependency Pattern). The endpoint still references the service interface; the host that opted out of registering it then refuses to start with a misleading body-inference error.

   **No exceptions:** add `[FromServices]` on the service parameter even for trivially-registered types. Treat any handler missing `[FromServices]` on a service parameter as a Phase 5b regression and fix it before the gate.
5. Return `ProblemDetails` for errors (no raw strings). Always use `ProblemDetailsHelper.BuildProblemDetailsResponseMultiple` (or the singular variant for single-error cases) - never `TypedResults.BadRequest(string)`.
6. Validate route/body ID consistency on update.
7. Add OpenAPI metadata (`Produces*`, summary/tags).
8. Use POST for complex search filters.
9. Ensure `global using EF.AspNetCore;` is present in `GlobalUsings.cs` for `ProblemDetailsHelper` to resolve.

## Service/CQRS Route Switch

When `applicationStyle: switch`, generate both endpoint sets:

- `Endpoints/{Entity}Endpoints.cs` injects `I{Entity}Service`.
- `Endpoints/Cqrs/{Entity}CqrsEndpoints.cs` injects the specific `IRequestHandler<TRequest,TResponse>`.
- CQRS request types are imported from `Application.Cqrs/Features/{Entity}` namespaces.
- `Application.Contracts/ApplicationStyle.cs` owns `ApplicationStyleResolver` with config key `Application:Style`, env var `<APP>_APPLICATION_STYLE`, default `Service`, and allowed values `Service` / `Cqrs`.

At route mapping time, resolve `ApplicationStyle` once and map exactly one CRUD endpoint set - `Map{Entity}CqrsEndpoints` or `Map{Entity}Endpoints`. Switch route-mapping code shape: [../templates/cqrs-endpoint-template.md](../templates/cqrs-endpoint-template.md).

Keep route templates and response shapes identical between service and CQRS endpoint sets. Shared read-only view endpoints with no CQRS alternate, such as activity feed or audit search, may remain mapped once outside the switch.

## Custom Action Endpoints

The six-route CRUD shape above is the default. When `.scaffold/domain-specification.yaml` declares a `customActions` entry on an entity (e.g. `Reschedule`, `Approve`, `Cancel`), or when a non-CRUD operation legitimately spans multiple entities (cross-entity aggregation, bulk import, workflow trigger), surface it as an additional route on the same entity's endpoint group rather than inventing a parallel controller.

**Route convention.** Stateful actions on a single aggregate go under the entity route as `POST /{entities}/{id:guid}/{action-name}` (kebab-case action segment). Cross-entity queries that don't bind to a single id go under `POST /{entities}/search/{aggregate-name}` so search-style POST semantics carry through.

```csharp
// Inside Map{Entity}Endpoints - co-locate custom actions with CRUD routes
group.MapPost("/{id:guid}/reschedule", Reschedule)
    .Produces<DefaultResponse<{Entity}Dto>>(StatusCodes.Status200OK)
    .ProducesValidationProblem()
    .ProducesProblem(StatusCodes.Status404NotFound)
    .WithSummary("Reschedule a {Entity} to a new due date");
```

**Request / response.** Each custom action gets its own DTO in `Application.Models`:

- Request: `{ActionName}Request` containing exactly the parameters declared on the `customActions` entry (e.g. `RescheduleRequest { DateTimeOffset NewDueDate }`). Wrap in `DefaultRequest<T>` only when the action mutates and returns the full entity.
- Response: same `Result<T>` -> `Result.Match()` -> `TypedResults` + `ProblemDetails` flow as CRUD; do not invent action-specific error envelopes.

**Service contract.** Add a method to `I{Entity}Service` named after the action (`Task<Result<{Entity}Dto>> RescheduleAsync(Guid id, RescheduleRequest req, CancellationToken ct)`). The service orchestrates: load aggregate -> invoke domain method -> persist -> emit `afterAction({ActionName})` event per the existing event model in `domain-specification-schema.md`.

**Domain method.** The action lives on the entity itself as a `DomainResult` method (e.g. `public DomainResult Reschedule(DateTimeOffset newDueDate)`), keeping invariants and state transitions inside the aggregate. The service does not contain the rule logic - only the orchestration around it.

**Cross-entity queries.** When the operation reads across multiple entities and does not naturally belong to one of them (e.g. `POST /reports/search/sla-breaches` aggregating SLA, Order, and Customer), put it in a dedicated `{Domain}QueryEndpoints.cs` mapper. Apply the same Result-mapping rules; do not bypass `ProblemDetails` for these.

**What stays out.** Do not add custom action routes purely to expose internal admin operations - those belong in a separate admin-scoped endpoint group with its own auth policy. Do not route domain events through HTTP; events are an internal contract surfaced via `IIntegrationEventPublisher`, not an API resource.

## Error Handling Strategy

Two complementary layers - **Result pattern for expected outcomes, `DefaultExceptionHandler` for unexpected exceptions**:

1. **Result flow (primary path):** Services return `Result<T>` / `DomainResult<T>`. Endpoints use `Result.Match()` to map success/failure/not-found to `TypedResults` + `ProblemDetails`. No exceptions thrown for validation, business rules, or not-found cases. DomainResult mechanics (factory results, Bind/Map chaining, error surface): [domain-model.md](domain-model.md) section DomainResult Pattern.
2. **`DefaultExceptionHandler` (safety net):** A global `IExceptionHandler` registered via `AddExceptionHandler<DefaultExceptionHandler>()`. Catches only truly unexpected exceptions (null refs, timeouts, infra failures) and maps them to `ProblemDetails` with appropriate HTTP status codes. This is a last-resort handler, not a control-flow mechanism. See [exception-handler-template](../templates/exception-handler-template.md) for implementation.

Reference: See [exception-handler-template](../templates/exception-handler-template.md) for the implementation pattern. Outbound HTTP resilience defaults (retry, circuit breaker, timeout): [resilience.md](resilience.md).

### Error Pipeline Overview

```
[Domain]   DomainResult<T>.Success / .Failure     - business validation, rules, state transitions
               down
[Service]  Result<T>.Success / .Failure / .None    - orchestration, tenant boundary, structure validation
               down
[Endpoint] result.Match(ok -> TypedResults, errors -> ProblemDetails, notFound -> NotFound)
               down
[Global]   DefaultExceptionHandler (IExceptionHandler)  - unexpected exceptions only -> ProblemDetails
```

### Error Type Mapping

| Source | Error | HTTP Status |
|---|---|---|
| Domain | `DomainError.Validation` | 400 Bad Request |
| Domain | `DomainError.NotFound` | 404 Not Found |
| Domain | `DomainError.Conflict` | 409 Conflict |
| Domain | `DomainError.Unauthorized` | 403 Forbidden |
| Service | `Result.Failure` (generic) | 422 Unprocessable Entity |
| Service | `Result.None` | 404 Not Found |
| Service | `StructureValidator` failure | 400 Bad Request |
| Global | `DbUpdateConcurrencyException` | 409 Conflict |
| Global | `UnauthorizedAccessException` | 403 Forbidden |
| Global | `OperationCanceledException` | 499 Client Closed (non-standard; log only - response may not be written) |
| Global | Unhandled exception | 500 Internal Server Error |

### Anti-Patterns

- **Throwing exceptions for business logic** - Use `DomainResult.Failure()` / `Result.Failure()` instead.
- **Swallowing errors silently** - Every failure must propagate through the Result chain or be logged explicitly.
- **Returning raw error strings** - Always wrap in `ProblemDetails` at the API boundary.
- **Catching generic `Exception` in services** - Let `DefaultExceptionHandler` handle the rest.
- **Exposing stack traces in production** - Only include outside production.
- **Relying on `DefaultExceptionHandler` to silence `OperationCanceledException`** - The VS debugger breaks at the throw site (inside EF Core) before the handler runs. Catch `OperationCanceledException` in the service method and return an empty/default result:
  ```csharp
  catch (OperationCanceledException)
  {
      logger.LogDebug("Search cancelled by client.");
      return new PagedResponse<TDto>();
  }
  ```
- **Non-nullable `[FromBody]` on search endpoints** - An empty body (e.g. sent on rapid navigation or client cancellation) causes `BadHttpRequestException` before the service is reached. Make the parameter nullable and null-coalesce at the call site:
  ```csharp
  app.MapPost("/search", async ([FromBody] SearchRequest<TFilter>? request, ...) => {
      request ??= new SearchRequest<TFilter>();
      ...
  });
  ```

## OpenAPI / Scalar Configuration

Gate OpenAPI and Scalar behind `OpenApiSettings:Enable` in appsettings:

```csharp
if (config.GetValue<bool>("OpenApiSettings:Enable"))
{
    foreach (var document in ApiContract.SupportedDocuments)
    {
        services.AddOpenApi(document.GroupName, options =>
        {
            options.ShouldInclude = apiDescription =>
                string.Equals(apiDescription.GroupName, document.GroupName, StringComparison.OrdinalIgnoreCase);

            options.AddDocumentTransformer((openApiDocument, context, ct) =>
            {
                openApiDocument.Info = new()
                {
                    Title = ApiContract.Title,
                    Version = document.DisplayName,
                    Description = ApiContract.Description
                };
                return Task.CompletedTask;
            });
        });
    }
}
```

In `ConfigurePipeline()`:

```csharp
if (app.Configuration.GetValue<bool>("OpenApiSettings:Enable"))
{
    app.MapOpenApi();           // serves /openapi/{documentName}.json
    app.MapScalarApiReference(options =>
    {
        options.WithTitle(ApiContract.Title);
        options.WithTheme(ScalarTheme.Moon);
    });
}
```

Each supported API version gets its own JSON document, for example `/openapi/v1.json` and `/openapi/v2.json`. The `ShouldInclude` filter keeps v1-only, v2-only, and shared endpoints in the correct document according to their API Explorer group.

Endpoint OpenAPI metadata - add to every endpoint:

```csharp
group.MapGet("/{id:guid}", GetById)
    .WithName("Get{Entity}ById")
    .WithSummary("Get a single {Entity} by ID")
    .WithTags("{Entity}")
    .Produces<{Entity}Dto>(200)
    .ProducesProblem(404)
    .ProducesProblem(401);
```

- Enable XML comments in the `.csproj`: `<GenerateDocumentationFile>true</GenerateDocumentationFile>`.
- Add `/// <summary>` to handler methods for auto-generated descriptions.
- Never expose OpenAPI/Scalar in production unless explicitly required.

---

## Verification

- [ ] `Properties/launchSettings.json` exists with `ASPNETCORE_ENVIRONMENT=Development` in every profile
- [ ] `Program.cs` wires bootstrapper + API services before `Build()`
- [ ] Endpoints are static classes under `Endpoints/` with `Map{Entity}Endpoints(...)`
- [ ] Route groups apply `.RequireAuthorization(...)` at the correct scope
- [ ] All handlers have `HttpContext httpContext` as first parameter and `CancellationToken` as last
- [ ] Every handler uses `Result.Match<IResult>()` - no `IsSuccess`/`else` guards anywhere
- [ ] Typed `Result<T>` handlers have all three branches (success, errors, none); non-generic `Result` handlers have two (success, errors)
- [ ] `global using EF.AspNetCore;` present in `GlobalUsings.cs`
- [ ] Validation and business errors return `ProblemDetails`/`ValidationProblem`
- [ ] Swagger/Scalar is gated by `OpenApiSettings:Enable`
- [ ] `/healthz` and `/alive` run only `live` checks; `/readyz` and `/health` run only `ready` checks
- [ ] Entra auth uses `AddMicrosoftIdentityWebApi` (service-to-service)
- [ ] `X-Orig-Request` is parsed only after the caller token matches the allowlisted gateway identity; see [gateway.md](gateway.md#forwarded-claims-trust-boundary)
- [ ] Cross-check with [endpoint-template.md](../templates/endpoint-template.md) and [application-layer.md](application-layer.md)

---

**TaskFlow proof (local):** `../scaffold-proof/src/Host/TaskFlow.Api/RegisterApiServices.cs` + `../scaffold-proof/src/Host/TaskFlow.Api/Endpoints/TaskItemEndpoints.cs`
**TaskFlow proof (remote fallback):** <https://github.com/efreeman518/scaffold-proof/blob/main/src/Host/TaskFlow.Api/Endpoints/TaskItemEndpoints.cs>
