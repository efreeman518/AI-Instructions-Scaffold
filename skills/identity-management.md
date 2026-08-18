# Identity Management

Use this skill when domain inputs enable `authProvider` and the solution needs authentication or identity-backed user management. **This skill is applied in the integration phase (Phase 5e)** - earlier phases use auth stubs so the project compiles and runs without identity configuration.

Reference patterns: [../patterns/api-host-wiring.md](../patterns/api-host-wiring.md) (Conditional Auth Configuration).

## Scaffold Mode vs Live Provider

**The default scaffold state is `AuthMode: Scaffold`.** Generated apps must run locally without any live identity provider (Entra ID, Entra External ID) configured. Real provider setup is supplemental deployment hardening, not a scaffold requirement.

- Phase 5e authentication finalization is complete when the app boots end-to-end with the scaffold principal and endpoint tests pass.
- Live Entra setup is a `deployment-only` dependency: log it in `HANDOFF.md` and continue.
- The config key (`AuthMode` or equivalent) must be present in `appsettings.Development.json` with value `Scaffold` by default.
- Production/staging environments override `AuthMode` to the live provider name. That mode must control registration, mapped routes, and visible client sign-in choices together.

## Identity Provider Scenarios

Prompt the user at the start of this phase to select the appropriate scenario:

| Scenario | Provider(s) | Typical use |
|---|---|---|
| Enterprise / internal users | Microsoft Entra ID | Internal apps, admin portals, SSO, conditional access, group-based roles |
| External / consumer users | Microsoft Entra External ID, Google, Facebook, Apple, OAuth2/OIDC | Customer-facing apps, self-service portals |
| Hybrid | Entra ID + Entra External ID / social providers | Public UI for external users + enterprise back-office for internal users |

### Admin Portal / Entra External ID Deployment Runbook

Apply this runbook when a deployed admin portal or other interactive client signs users in through an Entra External ID (CIAM) tenant. Scaffold completion may defer it, but production deployment may not.

1. Create a separate interactive-client app registration when the admin portal has different redirect URIs, roles, or operators from the public client. Record its client ID in deployment configuration, not source placeholders.
2. Register the exact public HTTPS redirect and post-logout URIs, including any path base and callback path. Do not register an internal container host or HTTP URI as the production callback.
3. Define the required app roles, make user/group assignment required when appropriate, create the enterprise application/service principal, and assign the admin user or group.
4. Request the OIDC `openid` and `profile` delegated permissions used by the client. CIAM commonly disables user consent, so grant tenant admin consent before testing the user flow.
5. Use `https://<tenant-subdomain>.ciamlogin.com/` as the interactive CIAM instance/authority. Do not substitute `login.microsoftonline.com` for an External ID user flow.
6. Create a local CIAM user for portal acceptance and assign its app role. Guest or personal Microsoft account administrators may administer the tenant but generally cannot sign in through CIAM local-user flows.
7. If automation creates the service principal and operators need it to appear under the portal's default Enterprise Applications filter, add the `WindowsAzureActiveDirectoryIntegratedApp` tag.
8. From the deployed public URL, complete one real interactive sign-in and verify the expected role claim and authorized admin page. A client-credentials token or scaffold auth test is not equivalent evidence.

### Live browser OIDC contract

Apply these rules only when a browser head enables a live provider. They do not make live identity a scaffold-completion prerequisite.

- Use authorization code with PKCE and the exact registered public HTTPS callback, including path base and callback path.
- Keep authority and issuer validation strict. The configured authority host, tenant identifier, and discovery issuer must agree; do not disable issuer validation to hide a friendly-host/GUID-host mismatch.
- Constrain outbound token attachment to exact allowed origins and path boundaries. Normalize the configured base with a trailing slash before prefix comparison so `https://api.example/a` cannot authorize `https://api.example/attacker`.
- Request scopes for the resource being called. Do not call Graph or OIDC userinfo with an access token issued for the application's API audience. If the provider library would call userinfo with that token, set `LoadProfile=false` and use validated ID-token claims or acquire the correct resource token separately.
- Attach diagnostics to the logger factory the OIDC provider instance actually uses. Configuring an unrelated application logger does not expose protocol diagnostics when the provider still owns a null logger factory.
- Require non-empty state, exact callback origin, exact callback path, and per-attempt correlation before completing the flow. Popup pre-opening and window-handle rules are canonical in [ui-uno-mvux.md](ui-uno-mvux.md) section Browser-WASM MSAL Custom Web UI.

Deterministic tests cover PKCE parameters, callback equality, issuer/authority mismatch, endpoint boundary/trailing slash, token audience, missing/mismatched state, wrong origin/path, popup sequencing, and logger wiring. One real interactive sign-in per enabled deployed UI head remains the release gate because headless automation may not reproduce browser popup policy.

### Mutable authorization and external identity side effects

When roles, tenant membership, institution membership, or resource scope can change in application data, resolve effective access server-side from that data on each authorization boundary. Token/cookie claims and client routing are UI hints, not continuing authorization after membership changes. Enforce resource access in the API/application layer even when the UI hides the route.

- Validate request bodies at the endpoint trust boundary, including empty minimal-API bodies, before application services run.
- Cache expected 401/403 no-access results only where the product intends that behavior. Never permanently cache a faulted access-context task or transient provider/database failure.
- External identity mutations use an explicit local/external operation order, report partial failure, return stable user-safe errors, and emit sanitized structured server logs with correlation IDs. Do not return raw Graph/provider messages, identifiers, tenant configuration, or credentials to clients.
- General smoke tests do not create users, assign roles, or mutate optional external identity providers. Put those actions in an explicit provider-specific acceptance lane with owned cleanup.

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

### Three-Leg Auth-Mode Contract

Every auth mode gate has three legs. A mode implementation is incomplete unless all three move together:

1. **DI registration:** register only the authentication handlers, token services, and local-session services used by the selected mode.
2. **Endpoint mapping:** map provider-specific anonymous endpoints only in their owning mode. Conventional local-session routes such as `/auth/login`, `/auth/register`, and `/auth/refresh` exist in `Scaffold`/`Local`; they are not mapped under `Entra`.
3. **Client affordances:** the client reads the runtime mode before rendering sign-in and exposes only compatible actions. Do not show a development email form under `Entra`, or an Entra button when that client build has no live provider configured.

The auth-owning host always exposes anonymous `GET /auth/mode`. Return only a validated public value such as `{ "mode": "Scaffold" }`, `{ "mode": "Local" }`, or `{ "mode": "Entra" }`; do not return tenant IDs, client IDs, authorities, or secrets. Reject unknown configured modes at startup. Clients may use this signal for presentation, but the backend authorization gate remains the security boundary.

Representative mapping shape:

```csharp
app.MapGet("/auth/mode", () => TypedResults.Ok(new { mode = authMode.ToString() }))
    .AllowAnonymous();

if (authMode is AuthMode.Scaffold or AuthMode.Local)
    app.MapLocalSessionEndpoints();
```

Add a mode-matrix test for every supported value. Assert the selected handler resolves, `GET /auth/mode` stays anonymous, local-session routes exist only in local modes, and the client presentation model selects the matching sign-in surface.

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

        if (mode.Equals("Local", StringComparison.OrdinalIgnoreCase))
            return services.AddLocalSessionAuthentication(config);

        if (!mode.Equals("Entra", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException($"Unsupported AuthMode '{mode}'");

        // Selected live mode fails fast when required configuration is missing.
        var section = config.GetRequiredSection("AzureAd");
        _ = section["TenantId"]
            ?? throw new InvalidOperationException("AzureAd:TenantId is required");
        _ = section["ClientId"]
            ?? throw new InvalidOperationException("AzureAd:ClientId is required");
        services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
            .AddMicrosoftIdentityWebApi(section);
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

With Microsoft.Identity.Web's inbound claim mapping active, `oid` arrives renamed to
`http://schemas.microsoft.com/identity/claims/objectidentifier` - a chain that checks short `oid`
then falls to a non-Guid `sub` misses it and silently collapses **every** authenticated user to the
fallback/audit-empty identity. The `oid` step must check both the short name and the objectidentifier
URI (or the handler disables mapping). Only an authenticated post-deploy smoke catches this class.

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

Gateway selects auth from `AuthMode`, not from accidental config-section presence. `Scaffold` and `Local` register their owned development/session schemes. `Entra` requires a complete Entra section and fails startup when it is missing; it must never fall back to anonymous passthrough.

```csharp
public static void AddAuthentication(this IServiceCollection services, IConfiguration config)
{
    var mode = config["AuthMode"] ?? "Scaffold";
    if (mode.Equals("Scaffold", StringComparison.OrdinalIgnoreCase))
    {
        services.AddScaffoldAuthentication();
        return;
    }
    if (mode.Equals("Local", StringComparison.OrdinalIgnoreCase))
    {
        services.AddLocalSessionAuthentication(config);
        return;
    }
    if (!mode.Equals("Entra", StringComparison.OrdinalIgnoreCase))
        throw new InvalidOperationException($"Unsupported AuthMode '{mode}'");

    var entraSection = config.GetRequiredSection("Gateway_EntraExt");
    services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
        .AddMicrosoftIdentityWebApi(entraSection);
}
```

Config shape when enabled:

```json
{
  "Gateway_EntraExt": {
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
7. Optional Entra/Graph admin integrations use a no-op stub when their capability is not selected. A selected `AuthMode: Entra` with missing auth configuration is a startup error, never a no-op fallback.
8. Internal execution routes must use service-scoped policies, not admin role policies. See the Internal vs Admin Routes section.
9. Mutable application membership is the server-side authorization source of truth; client claims and route visibility never replace API authorization.

## Verification

- [ ] App boots and all endpoints are reachable with `AuthMode: Scaffold` and no live identity provider
- [ ] Config-driven auth toggle present in `appsettings.Development.json` (`AuthMode: Scaffold`)
- [ ] `ScaffoldAuthHandler` (or equivalent) registered only when `AuthMode` is `Scaffold`
- [ ] Auth mode controls all three legs: DI registration, endpoint mapping, and client affordances
- [ ] Anonymous `GET /auth/mode` returns only a validated public mode in every supported mode
- [ ] `/auth/login`, `/auth/register`, and `/auth/refresh` are not mapped under `AuthMode: Entra`
- [ ] Mode-matrix endpoint and presentation tests prove route presence/absence and the matching sign-in UI
- [ ] Optional Entra/Graph admin DI is conditional; selected `AuthMode: Entra` fails startup on missing auth config
- [ ] `Infrastructure.EntraExt` and/or `Infrastructure.Graph` builds cleanly when config is populated
- [ ] `Microsoft.Graph` and `Azure.Identity` are in `Directory.Packages.props`
- [ ] Settings POCOs match configuration sections
- [ ] No hardcoded secrets
- [ ] Internal execution routes use service-scoped authorization policies, not admin role policies
- [ ] Live Entra setup logged in `HANDOFF.md` as a deployment-only dependency if not yet performed
- [ ] Deployed interactive clients follow the Admin Portal / Entra External ID Deployment Runbook when applicable
- [ ] Live browser heads pass deterministic PKCE, callback, issuer, endpoint-boundary, state/origin/path, popup-sequencing, token-audience, and provider-logger tests
- [ ] External identity failures expose stable user-safe errors and sanitized correlated logs; general smoke does not mutate optional providers
