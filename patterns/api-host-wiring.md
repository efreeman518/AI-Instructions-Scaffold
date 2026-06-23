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

    // 4. Startup tasks (migrations, seeding, etc.)
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

    // Default Aspire endpoints
    app.MapDefaultEndpoints();

    // Health + liveness
    app.MapHealthChecks("/health");
    app.MapGet("/alive", () => Results.Ok("Alive"));

    // API endpoint groups
    SetupApiEndpoints(app);

    return app;
}
```

---

## Request Context Resolution

**Source:** `Host/{App}.Bootstrapper/Registration/RegisterServices.RequestContext.cs`

Scoped `IRequestContext<string, Guid?>` factory: correlation ID from `X-Correlation-ID` header, claim precedence (`oid` > `NameIdentifier` > `sub`), tenant from `userTenantId` claim, role extraction, background service fallback.

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

### Dev-Mode Tenant Fallback (Auth Off)

When the scaffold ships with auth off (`Auth:Enabled: false` or no `Auth` section), `userTenantId` claims are absent and the tenant resolves to `null`. The EF tenant query filter then matches nothing and the entire UI looks silently empty (zero rows on every list). Two acceptable mitigations - pick **one** and record it in `HANDOFF.md`:

1. **Single-tenant scaffold** (preferred when only one tenant exists in dev): drop `ITenantEntity<TenantId>` from the entity, remove the tenant query filter, and skip this section.
2. **Dev tenant header**: keep multi-tenancy on, register a `DevRequestContextMiddleware` that reads a tenant id from a project-scoped header (e.g., `X-{App}-Tenant`) **only when** `app.Environment.IsDevelopment()` and `Auth:Enabled` is false. The matching Blazor `TenantHeaderHandler` lives in [../skills/ui-blazor.md](../skills/ui-blazor.md) -> *Dev Tenant Header*.

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
same treatment: UI-driven create DTOs arrive with an empty owner/created-by and (often) an empty
`TenantId`, because the browser has no identity to populate them. If nothing stamps them server-side,
every UI-driven create violates the user/tenant FK.

Stamp owner and tenant from `IRequestContext` on the create path when the inbound DTO leaves them empty.
The application service is the natural seam - it already stamps tenant in its `CreateAsync` (see
[../templates/service-template.md](../templates/service-template.md)):

```csharp
// Application service CreateAsync, before the factory call:
dto.TenantId = RequestTenantId ?? dto.TenantId;       // already present
dto.OwnerId  = dto.OwnerId == Guid.Empty || dto.OwnerId is null
    ? ParseAuditId(requestContext.AuditId)            // dev: SeedConstants.DevUserId via ScaffoldAuthHandler
    : dto.OwnerId;
```

For the owner FK to resolve, the audit id must be a real, seeded user GUID - hence the
`ScaffoldAuthHandler` emits the fixed `SeedConstants.DevUserId` and the dev seeder inserts that user (see
[../support/data-persistence-advanced.md](../support/data-persistence-advanced.md) section Startup Seeding). The
client never sends tenant/owner; the server owns them in every mode. Production resolves both from
claims; dev resolves them from the scaffold principal + seeded user.

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

The auth configuration implements no-op path when config section is missing; full JwtBearer + MicrosoftIdentityWebApi + fallback policy when present.
