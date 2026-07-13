# API Host Wiring Patterns

Cross-project wiring for API host startup, request context, and conditional auth. Load before Phase 5b (App Core + Runtime) when API host orchestration or runtime/edge wiring is in scope.

For base types used here, see [../support/ef-packages-reference.md](../support/ef-packages-reference.md).

---

## API Startup Sequence

**Source:** `Host/{App}.Api/Program.cs`

The startup follows a strict order: early logger, service registration chain, build, pipeline, startup tasks, run. The entire body is wrapped in try/catch/finally using a `StaticLogging` logger created before the host exists.

```csharp
var builder = WebApplication.CreateBuilder(args);
var config = builder.Configuration;
var services = builder.Services;
var appName = config.GetValue<string>("AppName") ?? "{App}.Api";
var env = config.GetValue<string>("ASPNETCORE_ENVIRONMENT")
    ?? config.GetValue<string>("DOTNET_ENVIRONMENT") ?? "Undefined";

ILogger<Program> startupLogger = CreateStartupLogger();
startupLogger.LogInformation("{AppName} {Environment} - Startup.", appName, env);

try
{
    // 1. Service defaults (OpenTelemetry, health, resilience)
    builder.AddServiceDefaults();

    // 2. Registration chain -- order matters for dependency resolution
    services
        .RegisterInfrastructureServices(config)  // config, caching, DB, request context, startup tasks
        .RegisterDomainServices(config)          // domain-specific registrations
        .RegisterApplicationServices(config)     // message handlers, app services
        .RegisterBackgroundServices(config)      // channel background queue
        .AddApiServices(config, startupLogger); // auth, routing, health checks, rate limiting

    // 3. Build + pipeline
    var app = builder.Build().ConfigurePipeline();

    // 4. Startup tasks (cache warmup, dev seeding - never schema migrations)
    await app.RunStartupTasks();

    // 5. Switch to runtime logger
    StaticLogging.SetStaticLoggerFactory(app.Services.GetRequiredService<ILoggerFactory>());

    await app.RunAsync();
}
catch (Exception ex)
{
    startupLogger.LogCritical(ex, "{AppName} {Environment} - Host terminated unexpectedly.", appName, env);
}
finally
{
    startupLogger.LogInformation("{AppName} {Environment} - Ending application.", appName, env);
}

// Required for WebApplicationFactory in integration tests
public partial class Program { }
```

**Early logger factory** -- created before the host so startup failures are visible:

```csharp
ILogger<Program> CreateStartupLogger()
{
    StaticLogging.CreateStaticLoggerFactory(logBuilder =>
    {
        logBuilder.SetMinimumLevel(LogLevel.Information);
        logBuilder.AddConsole();
    });
    return StaticLogging.CreateLogger<Program>();
}
```

**Middleware pipeline order** (`Host/{App}.Api/WebApplicationBuilderExtensions.cs`):

```csharp
public static WebApplication ConfigurePipeline(this WebApplication app)
{
    // 1. Security headers (CSP, X-Frame, etc.)
    app.UseMiddleware<SecurityHeadersMiddleware>();

    // 2. Correlation tracking
    app.UseMiddleware<CorrelationIdMiddleware>();

    // 3. Catch unhandled exceptions (before routing)
    app.UseExceptionHandler();

    // 4. Rate limiting
    app.UseRateLimiter();

    // 5. CORS
    app.UseCors("UiCors");

    // 6. Authenticate
    app.UseAuthentication();

    // 7. Authorize
    app.UseAuthorization();

    // OpenAPI + Scalar (feature-gated)
    if (app.Configuration.GetValue<bool>("OpenApiSettings:Enable", true))
    {
        app.MapOpenApi();
        app.MapScalarApiReference(options =>
        {
            options.WithTitle("{App} API");
            options.WithTheme(ScalarTheme.Moon);
        });
    }

    // Scaffold ServiceDefaults maps /healthz and /readyz here.
    app.MapDefaultEndpoints();

    // Map backward-compatible aliases once; do not combine with the stock Aspire /health + /alive body.
    app.MapHealthChecks("/health", new() { Predicate = r => r.Tags.Contains("ready") }).AllowAnonymous();
    app.MapHealthChecks("/alive", new() { Predicate = r => r.Tags.Contains("live") }).AllowAnonymous();

    // API endpoint groups
    SetupApiEndpoints(app);

    return app;
}
```

**Why:** Security and correlation must envelope every response, exception handling must wrap downstream failures, CORS must answer preflight before authentication, and authentication must establish the principal before authorization. Therefore preserve this middleware order.

---

## Gateway Claim Relay Trust Boundary

API may consume `X-Orig-Request` only after bearer authentication validates issuer, audience, and an allowlisted gateway application identity (`azp`/`appid`). A forwarded-claims transformer may then add context to the authenticated principal; `IRequestContext` reads that principal, never the raw header. Direct-user-token and other service-token paths ignore the envelope. The canonical trust boundary and forged-header cases live in [gateway.md](../skills/gateway.md#forwarded-claims-trust-boundary).

When claim relay is used, bind `ForwardedClaims:TrustedGatewayClientIds` from validated configuration and fail startup when the allowlist is empty. Register the transformer only for that path. `IClaimsTransformation` runs during authentication, before authorization; the transformer itself must enforce the caller check before reading the header. It may run more than once, so forwarded-context application must be idempotent: clone one identity and add each allowlisted claim only when the same type/value is absent.

```csharp
private bool IsTrustedGatewayCaller(ClaimsPrincipal principal)
{
    if (principal.Identity?.IsAuthenticated != true) return false;

    var callerAppId = principal.FindFirst("azp")?.Value
        ?? principal.FindFirst("appid")?.Value; // v1 fallback only when azp is absent

    return callerAppId is not null
        && trustedGatewayClientIds.Contains(callerAppId, StringComparer.OrdinalIgnoreCase);
}

public Task<ClaimsPrincipal> TransformAsync(ClaimsPrincipal principal)
{
    if (!IsTrustedGatewayCaller(principal)) return Task.FromResult(principal);
    var request = httpContextAccessor.HttpContext?.Request;
    if (request is null || !request.Headers.TryGetValue("X-Orig-Request", out var envelope))
        return Task.FromResult(principal);
    if (envelope.Count != 1) return Task.FromResult(principal);

    // Parse validated gateway context, clone one identity, and add missing allowlisted type/value pairs only.
    // Never copy arbitrary claim names. AddForwardedContextAsync must be idempotent.
    return AddForwardedContextAsync(principal, envelope);
}
```

---

## Request Context Resolution

**Source:** `Host/{App}.Bootstrapper/Registration/RegisterServices.RequestContext.cs`

Scoped `IRequestContext<string, Guid?>` factory: correlation ID from `X-Correlation-ID` header, claim precedence (`oid` > `NameIdentifier` > `sub`), tenant from the authenticated principal's `userTenantId` claim, role extraction, background service fallback.

```csharp
private static void AddRequestContextServices(IServiceCollection services)
{
    services.AddScoped<IRequestContext<string, Guid?>>(provider =>
    {
        var httpContext = provider.GetService<IHttpContextAccessor>()?.HttpContext;

        // Correlation ID: prefer header, fallback to new GUID
        var correlationId = Guid.NewGuid().ToString();
        if (httpContext != null)
        {
            var headers = httpContext.Request?.Headers;
            if (headers != null && headers.TryGetValue("X-Correlation-ID", out var headerValues))
            {
                var headerValue = headerValues.FirstOrDefault();
                if (!string.IsNullOrWhiteSpace(headerValue))
                    correlationId = headerValue;
            }
        }

        // Background service fallback -- no HttpContext available
        if (httpContext == null)
        {
            return new RequestContext<string, Guid?>(
                correlationId, $"BackgroundService-{correlationId}", null, []);
        }

        // Claim precedence for audit identity
        var user = httpContext.User;
        var auditId = user.Claims.FirstOrDefault(c => c.Type == "oid")?.Value
            ?? user.Claims.FirstOrDefault(c => c.Type == ClaimTypes.NameIdentifier)?.Value
            ?? user.Claims.FirstOrDefault(c => c.Type == "sub")?.Value
            ?? "NoAuditClaim";

        // Tenant from custom claim
        var tenantIdClaim = user.Claims.FirstOrDefault(c => c.Type == "userTenantId")?.Value;
        var tenantId = Guid.TryParse(tenantIdClaim, out var tenantGuid)
            ? tenantGuid : (Guid?)null;

        // Roles
        var rolesList = user.Claims
            .Where(c => c.Type == ClaimTypes.Role)
            .Select(c => c.Value).ToList();

        return new RequestContext<string, Guid?>(correlationId, auditId, tenantId, rolesList);
    });
}
```

> **Claim source must match these reads.** When the scaffold runs with auth on via `ScaffoldAuthHandler`,
> that handler must emit roles as `ClaimTypes.Role`, tenant as a `userTenantId` claim, and the seeded
> dev-user GUID as `NameIdentifier` - see
> [../skills/identity-management.md](../skills/identity-management.md) section Claim-type contract. The
> reads above are the other half of that contract; a mismatch silently empties roles and tenant.
> When claims originate at Gateway, a forwarded-claims transformer may add them only after validating the
> allowlisted gateway service identity in [gateway.md](../skills/gateway.md#forwarded-claims-trust-boundary). The request-context factory reads the resulting
> principal; it never parses `X-Orig-Request` itself.

### Dev-Mode Tenant Fallback (Auth Off)

When the scaffold ships with auth off (`Auth:Enabled: false` or no `Auth` section), `userTenantId` claims are absent and the tenant resolves to `null`. The EF tenant query filter then matches nothing and the entire UI looks silently empty (zero rows on every list). Two acceptable mitigations - pick **one** and record it in `HANDOFF.md`:

1. **Single-tenant scaffold** (preferred when only one tenant exists in dev): drop `ITenantEntity<TenantId>` from the entity, remove the tenant query filter, and skip this section.
2. **Dev tenant header**: keep multi-tenancy on, register a `DevRequestContextMiddleware` that reads a tenant id from a project-scoped header (e.g., `X-{App}-Tenant`) **only when** `app.Environment.IsDevelopment()` and `Auth:Enabled` is false. This is an explicit local-only exception to the authenticated-claim boundary and must never activate in staging/production. The matching Blazor `TenantHeaderHandler` lives in [../skills/ui-blazor.md](../skills/ui-blazor.md) -> *Dev Tenant Header*.

Wire the middleware before `UseAuthentication`:

```csharp
// Host/{App}.Api/Middleware/DevRequestContextMiddleware.cs
public sealed class DevRequestContextMiddleware(RequestDelegate next)
{
    public async Task InvokeAsync(HttpContext ctx, IConfiguration config)
    {
        if (!ctx.Request.Headers.TryGetValue($"X-{{App}}-Tenant", out var raw))
        {
            var fallback = config["{App}:DefaultTenantId"];
            if (!string.IsNullOrWhiteSpace(fallback)) raw = fallback;
        }
        if (Guid.TryParse(raw, out var tenantId))
        {
            ctx.Items["DevTenantId"] = tenantId;
        }
        await next(ctx);
    }
}
```

Inside the `IRequestContext` factory, prefer `httpContext.Items["DevTenantId"]` when the `userTenantId` claim is absent. Production paths still rely on claims - the dev branch is a `IsDevelopment()` short-circuit.

**Symptom:** if a Blazor or external client lands at the API without either a tenant claim or the dev header, every list endpoint returns an empty payload and no error. Log the resolved tenant id at `Information` once per request during dev so the empty-payload case is observable.

### Dev-Mode Write Identity (owner/tenant stamping)

The tenant fallback above fixes the **read** path (query-filter tenant). The **write** path needs the
same treatment: DTOs retain `TenantId` for response and round-trip compatibility, but the browser does
not own that value. UI-driven creates may also carry a forged owner/created-by. If the server does not
stamp both from trusted context, writes can violate user/tenant FKs or accept forged ownership.

Stamp tenant from `IRequestContext` unconditionally before validation/mapping; never fall back to the
caller-supplied DTO value. For server-owned creator/owner fields, overwrite from the audit identity even
when the payload is non-empty. The application service is
the natural seam - it already stamps tenant in its `CreateAsync` (see
[../templates/service-template.md](../templates/service-template.md)):

```csharp
// Application service CreateAsync, before the factory call:
var authoritativeTenantId = RequestTenantId ?? Guid.Empty;
dto.TenantId = authoritativeTenantId;                 // overwrite untrusted payload
dto.OwnerId = ParseAuditId(requestContext.AuditId);   // overwrite untrusted payload
```

`Guid.Empty` deliberately fails structure validation when no request tenant exists. Do not recover with
`dto.TenantId`; that would let a caller establish its own tenant boundary.

For the owner FK to resolve, the audit id must be a real, seeded user GUID - hence the
`ScaffoldAuthHandler` emits the fixed `SeedConstants.DevUserId` and the dev seeder inserts that user (see
[../support/data-persistence-advanced.md](../support/data-persistence-advanced.md) section Startup Seeding). The
client may round-trip tenant/owner fields for contract compatibility, but the server owns them in every
mode. Production resolves both from claims; dev resolves them from the scaffold principal + seeded user.
If users may assign work to someone else, model a separate `AssigneeId` and authorize that operation;
do not overload server-owned creator/owner identity.

---

## Conditional Auth Configuration

**Source:** `Host/{App}.Api/Auth/AuthConfiguration.cs` + `Auth/AuthorizationPolicies.cs`

Auth is delegated to separate files under `Auth/`. In `RegisterApiServices.cs`:

```csharp
private static void AddAuthentication(IServiceCollection services, IConfiguration config, ILogger logger)
{
    services.Add{App}Auth(config);  // delegates to Auth/AuthConfiguration.cs
}

private static void AddAuthorization(IServiceCollection services)
{
    services.Add{App}Authorization();  // delegates to Auth/AuthorizationPolicies.cs
}
```

The auth configuration implements no-op path when config section is missing; full JwtBearer + MicrosoftIdentityWebApi + fallback policy when present. The scaffold-vs-live `AuthMode` toggle and `ScaffoldAuthHandler` are owned by [../skills/identity-management.md](../skills/identity-management.md) (Phase 5e).
