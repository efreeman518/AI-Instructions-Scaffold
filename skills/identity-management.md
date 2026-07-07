# Identity Management

Use this skill when domain inputs enable `authProvider` and the solution needs authentication or identity-backed user management. **This skill is applied in the integration phase (Phase 5e)** - earlier phases use auth stubs so the project compiles and runs without identity configuration.

Reference patterns: [../patterns/api-host-wiring.md](../patterns/api-host-wiring.md) (Conditional Auth Configuration).

## Scaffold Mode vs Live Provider

**The default scaffold state is `AuthMode: Scaffold`.** Generated apps must run locally without any live identity provider (Entra ID, Entra External ID) configured. Real provider setup is supplemental deployment hardening, not a scaffold requirement.

- Phase 5e authentication finalization is complete when the app boots end-to-end with the scaffold principal and endpoint tests pass.
- Live Entra setup is a `deployment-only` dependency: log it in `HANDOFF.md` and continue.
- The config key (`AuthMode` or equivalent) must be present in `appsettings.Development.json` with value `Scaffold` by default.
- Production/staging environments override `AuthMode` to the live provider name; the application code path is identical - only the token source changes.

## Identity Provider Scenarios

Prompt the user at the start of this phase to select the appropriate scenario:

| Scenario | Provider(s) | Typical use |
|---|---|---|
| Enterprise / internal users | Microsoft Entra ID | Internal apps, admin portals, SSO, conditional access, group-based roles |
| External / consumer users | Microsoft Entra External ID, Google, Facebook, Apple, OAuth2/OIDC | Customer-facing apps, self-service portals |
| Hybrid | Entra ID + Entra External ID / social providers | Public UI for external users + enterprise back-office for internal users |

## Pre-Auth Stub Pattern (Phases 5a-5d)

Until this phase is reached, authentication must be **stubbed** so the project compiles and runs:

```csharp
// File: Host/{Host}.Api/Auth/AuthStub.cs
// TODO: [CONFIGURE] Authentication - replace this stub with real identity provider configuration (see skills/identity-management.md)

public static class AuthStub
{
    public static IServiceCollection AddAuthStub(this IServiceCollection services)
    {
        // No-op auth - all endpoints accessible without authentication
        // Remove this stub and wire real auth in Phase 5e
        return services;
    }
}
```

- Register `builder.Services.AddAuthStub()` in the host's `Program.cs`
- Do **not** add `[Authorize]` attributes or `RequireAuthorization()` until real auth is wired
- All endpoints should work without authentication during development

## Config-Driven Auth Toggle (Phase 5e)

Replace the pre-auth stub with a config-driven toggle that defaults to scaffold mode:

```json
// appsettings.Development.json
{
  "AuthMode": "Scaffold"
}
```

```csharp
// File: Host/{Host}.Api/Auth/AuthConfiguration.cs
public static class AuthConfiguration
{
    public static IServiceCollection AddAuth(this IServiceCollection services, IConfiguration config)
    {
        var mode = config["AuthMode"] ?? "Scaffold";

        if (mode.Equals("Scaffold", StringComparison.OrdinalIgnoreCase))
        {
            // Scaffold principal: all requests succeed with a predictable test identity
            services.AddAuthentication("Scaffold")
                .AddScheme<AuthenticationSchemeOptions, ScaffoldAuthHandler>("Scaffold", _ => { });
            return services;
        }

        // Production path - wire real JWT validation
        var section = config.GetSection($"{mode}Auth");
        services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
            .AddJwtBearer(options =>
            {
                options.Authority = section["Authority"];
                options.Audience = section["ClientId"];
            });
        return services;
    }
}
```

```csharp
// File: Host/{Host}.Api/Auth/ScaffoldAuthHandler.cs
// TODO: [CONFIGURE] Remove or gate this handler when deploying with a real identity provider
public class ScaffoldAuthHandler : AuthenticationHandler<AuthenticationSchemeOptions>
{
    protected override Task<AuthenticateResult> HandleAuthenticateAsync()
    {
        var claims = new[]
        {
            // Audit id: RequestContext reads oid > NameIdentifier > sub. Use the FIXED seeded dev-user
            // GUID (SeedConstants.DevUserId) so a stamped owner FK resolves - never a random/string id.
            new Claim(ClaimTypes.NameIdentifier, SeedConstants.DevUserId.ToString()),
            new Claim(ClaimTypes.Name, "Scaffold Principal"),
            // Roles MUST use ClaimTypes.Role - RequestContext reads c.Type == ClaimTypes.Role. A bare
            // "roles" string leaves RequestRoles empty and the global-admin bypass never fires.
            new Claim(ClaimTypes.Role, AppConstants.ROLE_GLOBAL_ADMIN),
            // Tenant MUST use the "userTenantId" claim RequestContext reads; the seeded dev tenant GUID
            // (SeedConstants.DevTenantId, same as {App}:DefaultTenantId). Omit it and tenant is null.
            new Claim("userTenantId", SeedConstants.DevTenantId.ToString()),
        };
        var identity = new ClaimsIdentity(claims, "Scaffold");
        var ticket = new AuthenticationTicket(new ClaimsPrincipal(identity), "Scaffold");
        return Task.FromResult(AuthenticateResult.Success(ticket));
    }
}
```

### Claim-type contract (non-negotiable)

The handler and the `RequestContext` reader must use the SAME claim types, or the dev principal is
silently broken end to end - see [../patterns/api-host-wiring.md](../patterns/api-host-wiring.md) -> Request Context Resolution. They must agree on:

| Concern | Handler emits | RequestContext reads |
|---|---|---|
| Audit id (owner) | `ClaimTypes.NameIdentifier` = seeded dev-user GUID | `oid` > `NameIdentifier` > `sub` |
| Roles | `ClaimTypes.Role` | `c.Type == ClaimTypes.Role` |
| Tenant | `userTenantId` = seeded dev tenant GUID | `c.Type == "userTenantId"` |

A mismatch (e.g. `new Claim("roles", ...)`) yields empty roles -> global-admin tenant-bypass never
fires; a missing `userTenantId` yields a null tenant -> every list silently returns zero rows.

## Dev-Mode Auth Patterns

### UI: Custom Auth Provider (dev) to MSAL (production)

Scaffold with `.AddCustom()` in `App.xaml.host.cs` - no external identity provider required:

```csharp
.UseAuthentication(auth => auth
    .AddCustom(custom => custom
        .Login(async (sp, dispatcher, credentials, ct) =>
        {
            credentials["AccessToken"] = "dev-token";
            return true;
        }), name: "CustomAuth"))
```

Upgrade to production: replace `.AddCustom(...)` with `.AddMsal()`, change csproj `<UnoFeatures>` from `AuthenticationCustom` to `AuthenticationMsal`, and populate `EntraExternal` config with real tenant values. `AuthTokenHandler` reads from `ITokenCache` and works identically with either provider.

### Gateway: Config-Driven Auth Toggle

Gateway's `AddAuthentication` checks for a config section (e.g., `TaskFlowGateway_EntraID`). If the section is **absent or empty**, auth is registered as a no-op passthrough. When real values are provided, JWT Bearer validation activates:

```csharp
public static void AddAuthentication(this IServiceCollection services, IConfiguration config)
{
    var entraSection = config.GetSection("TaskFlowGateway_EntraID");
    if (!entraSection.Exists())
    {
        // Dev mode: register empty auth so middleware doesn't reject requests
        services.AddAuthentication().AddJwtBearer();
        return;
    }
    // Production: wire real JWT validation
    services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
        .AddJwtBearer(options => { /* bind from config */ });
}
```

Config shape when enabled:

```json
{
  "TaskFlowGateway_EntraID": {
    "Instance": "https://YOUR-TENANT.ciamlogin.com/",
    "TenantId": "YOUR-TENANT-ID",
    "ClientId": "YOUR-CLIENT-ID",
    "Audience": "api://YOUR-CLIENT-ID"
  }
}
```

## Projects

- External user administration: `src/Infrastructure/{Project}.Infrastructure.EntraExt`
- Enterprise Graph access: `src/Infrastructure/{Project}.Infrastructure.Graph`

---

## Auth Configuration

### Entra External ID (gateway)

```csharp
builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddJwtBearer(options =>
    {
        options.Authority = $"https://{tenantName}.ciamlogin.com/{tenantId}/v2.0";
        options.Audience = configuration["AzureAd:ClientId"];
        options.TokenValidationParameters = new TokenValidationParameters
        {
            ValidateIssuer = true,
            ValidIssuer = $"https://{tenantName}.ciamlogin.com/{tenantId}/v2.0",
            ValidateAudience = true,
            ValidateLifetime = true
        };
    });
```

### Entra ID (enterprise)

```csharp
builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddJwtBearer(options =>
    {
        options.Authority = $"https://login.microsoftonline.com/{tenantId}/v2.0";
        options.Audience = configuration["AzureAd:ClientId"];
        options.TokenValidationParameters = new TokenValidationParameters
        {
            ValidateIssuer = true,
            ValidIssuer = $"https://login.microsoftonline.com/{tenantId}/v2.0",
            ValidateAudience = true,
            ValidateLifetime = true,
            RoleClaimType = "roles"
        };
    });
```

---

## Service Contracts

### External user admin

```csharp
public interface IEntraExtService
{
    Task<Result<string>> CreateUserAsync(string email, string displayName, CancellationToken ct = default);
    Task<Result> InviteUserAsync(string email, string redirectUrl, CancellationToken ct = default);
    Task<Result> AssignAppRoleAsync(string userId, string appRoleId, CancellationToken ct = default);
    Task<Result> RemoveAppRoleAsync(string userId, string appRoleId, CancellationToken ct = default);
    Task<Result<ExternalUserInfo>> GetUserAsync(string userId, CancellationToken ct = default);
    Task<Result> DisableUserAsync(string userId, CancellationToken ct = default);
}
```

### Enterprise Graph access

```csharp
public interface IGraphService
{
    Task<Result<EnterpriseUserInfo>> GetUserAsync(string userId, CancellationToken ct = default);
    Task<Result<IReadOnlyList<EnterpriseUserInfo>>> SearchUsersAsync(string query, CancellationToken ct = default);
    Task<Result<IReadOnlyList<string>>> GetUserGroupsAsync(string userId, CancellationToken ct = default);
    Task<Result<byte[]>> GetUserPhotoAsync(string userId, CancellationToken ct = default);
}
```

Implementation rule: return `Result`/`Result<T>` from all Graph operations; do not leak exceptions.

---

## Graph Client + DI

Use conditional registration - if the config section is absent, register a no-op stub so the app boots without Entra credentials:

```csharp
services.Configure<EntraExtServiceSettings>(configuration.GetSection("EntraExt"));

var entraSection = configuration.GetSection("EntraExt");
if (entraSection.Exists() && !string.IsNullOrWhiteSpace(entraSection["ClientId"]))
{
    var entra = entraSection.Get<EntraExtServiceSettings>()!;
    var entraCredential = new ClientSecretCredential(entra.TenantId, entra.ClientId, entra.ClientSecret);
    services.AddSingleton(new GraphServiceClient(entraCredential));
    services.AddScoped<IEntraExtService, EntraExtService>();
}
else
{
    // TODO: [CONFIGURE] Entra External ID - populate EntraExt config section for live user management
    services.AddScoped<IEntraExtService, NoOpEntraExtService>();
}

services.Configure<GraphServiceSettings>(configuration.GetSection("Graph"));

var graphSection = configuration.GetSection("Graph");
if (graphSection.Exists() && !string.IsNullOrWhiteSpace(graphSection["ClientId"]))
{
    var graph = graphSection.Get<GraphServiceSettings>()!;
    var graphCredential = new ClientSecretCredential(graph.TenantId, graph.ClientId, graph.ClientSecret);
    services.AddSingleton(new GraphServiceClient(graphCredential));
    services.AddScoped<IGraphService, GraphService>();
}
else
{
    // TODO: [CONFIGURE] Microsoft Graph - populate Graph config section for live enterprise identity
    services.AddScoped<IGraphService, NoOpGraphService>();
}
```

No-op stubs return `Result.Failure("Not configured")` or empty collections and log a warning; never-throw rule and safe-default table: [../templates/no-op-stub-template.md](../templates/no-op-stub-template.md).

NuGet:

```xml
<PackageReference Include="Microsoft.Graph" />
<PackageReference Include="Azure.Identity" />
```

---

## Internal vs Admin Routes

**Do not model internal execution routes as admin routes.** Mixing them overloads admin authorization and misrepresents runtime execution paths.

| Route category | Who calls it | Auth model |
|---|---|---|
| Admin routes | Human operators via portal/management UI | User roles (`Admin`, `Operator`) from Entra |
| Internal execution routes | Services calling other services (e.g., scheduler -> domain service, AI agent -> API) | Service identity, managed identity, or internal audience claim |

Rules:
- Internal routes (e.g., cosmic-service call-backs, scheduler triggers, agent tool invocations) must declare a **service-scoped policy** (`InternalExecution`, `ServiceToService`) - not reuse `Admin` or `Operator` roles.
- In scaffold mode, internal policies resolve like admin policies (scaffold principal carries all roles).
- When live auth is wired, internal policies validate a dedicated scope claim (e.g., `scp: internal-execute`) or a managed identity client ID, not a human role claim.
- Never apply `[Authorize(Roles = "Admin")]` to an endpoint that is expected to be called by another service without a human initiating it.

---

## Configuration

```json
{
  "EntraExt": {
    "TenantId": "{{from-keyvault}}",
    "TenantDomain": "contoso.onmicrosoft.com",
    "ClientId": "{{from-keyvault}}",
    "ClientSecret": "{{from-keyvault}}",
    "ServicePrincipalId": "{{from-keyvault}}"
  },
  "Graph": {
    "TenantId": "{{from-keyvault}}",
    "ClientId": "{{from-keyvault}}",
    "ClientSecret": "{{from-keyvault}}"
  }
}
```

Rule: secrets come from Key Vault/User Secrets only.

---

## Rules

1. Identity infrastructure projects stay infrastructure-only (no Domain/Application references).
2. Gateway handles token validation; Graph services handle admin/user management operations.
3. Register identity services as `Scoped`.
4. Use `Microsoft.Graph` v5+ with `GraphServiceClient`.
5. In lite mode, skip identity infrastructure and use a local/mock request context.
6. For regulated/sensitive classifications, enforce least-privilege roles and trace access decisions with auditable correlation IDs.
7. Entra/Graph DI registration must be conditional on config presence. Missing config -> no-op stub, not a startup exception.
8. Internal execution routes must use service-scoped policies, not admin role policies. See the Internal vs Admin Routes section.

## Verification

- [ ] App boots and all endpoints are reachable with `AuthMode: Scaffold` and no live identity provider
- [ ] Config-driven auth toggle present in `appsettings.Development.json` (`AuthMode: Scaffold`)
- [ ] `ScaffoldAuthHandler` (or equivalent) registered only when `AuthMode` is `Scaffold`
- [ ] Entra/Graph DI registration is conditional - absent config -> no-op stub registered, no startup exception
- [ ] `Infrastructure.EntraExt` and/or `Infrastructure.Graph` builds cleanly when config is populated
- [ ] `Microsoft.Graph` and `Azure.Identity` are in `Directory.Packages.props`
- [ ] Settings POCOs match configuration sections
- [ ] No hardcoded secrets
- [ ] Internal execution routes use service-scoped authorization policies, not admin role policies
- [ ] Live Entra setup logged in `HANDOFF.md` as a deployment-only dependency if not yet performed
