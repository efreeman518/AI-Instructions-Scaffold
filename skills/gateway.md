# Gateway (YARP)

## Purpose

Gateway is a YARP reverse proxy in front of API/backends. It handles user-facing auth, CORS, downstream token relay, and trusted forwarding of original user claims.

## Non-Negotiables

1. Keep proxy routes/clusters in configuration and load through YARP.
2. Relay service-to-service bearer token per cluster via `TokenService`.
3. Treat `X-Orig-Request` as a gateway-owned header: strip any inbound value, regenerate it from the authenticated user principal, and let the API consume it only after validating the gateway service identity.
4. Keep pipeline order deterministic (security -> routing/auth -> endpoints -> proxy).
5. Normalize path prefixes consistently between UI, gateway transforms, and backend routes.
6. Normalize trusted forwarded scheme/host before OIDC or YARP so redirects use the public origin.

Reference patterns: [../patterns/api-host-wiring.md](../patterns/api-host-wiring.md) (Gateway Claim Relay).

---

## Project Shape

```
Host/{Gateway}.Gateway/
|-- Program.cs
|-- RegisterServices.cs
|-- WebApplicationBuilderExtensions.cs
|-- TokenService.cs
|-- Auth/
|-- HealthChecks/
|-- StartupTasks/
|-- appsettings.json
`-- Dockerfile
```

---

## YARP Configuration

```json
{
  "ReverseProxy": {
    "Routes": {
      "api-route": {
        "ClusterId": "api-cluster",
        "AuthorizationPolicy": "Default",
        "Match": { "Path": "/api/{**catch-all}" },
        "Transforms": [{ "PathRemovePrefix": "/api" }]
      }
    },
    "Clusters": {
      "api-cluster": {
        "Destinations": {
          "api": { "Address": "https://localhost:7065" }
        }
      }
    }
  }
}
```

With Aspire, destination resolution can be service-discovery driven.

---

## Service Registration Pattern

```csharp
using Azure.Core;
using Azure.Identity;

private static void AddReverseProxy(IServiceCollection services, IConfiguration config)
{
    // Register TokenCredential - DefaultAzureCredential handles local dev + managed identity in production
    services.AddSingleton<TokenCredential>(_ => new DefaultAzureCredential());
    services.AddSingleton<TokenService>();

    services.AddReverseProxy()
        .LoadFromConfig(config.GetSection("ReverseProxy"))
        .AddTransforms(ConfigureProxyTransforms);
}
```

> **Package:** Add `Azure.Identity` to the Gateway project. Version managed via `Directory.Packages.props`.

> **Service discovery:** For Aspire-hosted scenarios, use service-discovery URI syntax (`https+http://{app}-api`) in `appsettings.json` cluster destinations. If explicit resolver registration is needed, add the `Microsoft.Extensions.ServiceDiscovery.Yarp` package and call `AddServiceDiscoveryDestinationResolver()`.


Transform pattern:

```csharp
private static void ConfigureProxyTransforms(TransformBuilderContext context)
{
    context.AddRequestTransform(async ctx =>
    {
        const string originalUserHeader = "X-Orig-Request";

        // Never forward a caller-supplied claims envelope. This transform runs only after
        // gateway user authentication and rebuilds the header from HttpContext.User.
        ctx.ProxyRequest.Headers.Remove(originalUserHeader);
        AddOriginalUserClaimsHeader(ctx);

        var token = await tokenService.GetAccessTokenAsync(clusterId);
        ctx.ProxyRequest.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
    });
}
```

### Forwarded Claims Trust Boundary

**Why:** Any client can forge an ordinary request header. Therefore `X-Orig-Request` carries context only; this exact boundary establishes trust:

1. Every claim-relaying proxy route requires an authenticated-user authorization policy. Pipeline order alone does not reject anonymous callers.
2. Gateway removes any inbound `X-Orig-Request` and regenerates one envelope only from the authenticated `HttpContext.User`.
3. Gateway replaces the user token with its downstream service token.
4. API bearer authentication validates issuer and audience, then an allowlisted gateway application identity (`azp` for v2 tokens, `appid` for v1) before any forwarded-claims transformer parses the envelope.
5. Non-gateway service identities and direct-user-token paths ignore the header. `IRequestContext` reads only the resulting authenticated principal, never the raw envelope.

Required verification:

- `AnonymousClaimRelayRoute_IsRejectedBeforeProxy`: an anonymous caller never reaches the transform.
- `ForgedInboundEnvelope_IsOverwritten`: a caller-supplied envelope sent through Gateway cannot supply roles or tenant.
- `ForgedDirectEnvelope_WithoutTrustedGateway_IsIgnored`: a direct API call with no allowlisted gateway service identity returns 401/403 or leaves the principal unchanged.
- `TrustedGatewayEnvelope_AddsExpectedClaims`: a valid gateway service token plus gateway-generated envelope produces only the expected user, role, and tenant claims.
- `RepeatedTransformation_DoesNotDuplicateForwardedClaims`: repeated authentication transformation adds no duplicate identity or claim.

Keep API-side wiring concise and point it back here; see [api-host-wiring.md](../patterns/api-host-wiring.md#gateway-claim-relay-trust-boundary).

---

## TokenService Contract

`TokenService` acquires and caches client-credential tokens per cluster with an expiry buffer. Injects `TokenCredential` (not `IConfiguration` or MSAL directly).

```csharp
using Azure.Core;
using System.Collections.Concurrent;

public class TokenService(TokenCredential credential, IConfiguration config)
{
    private readonly ConcurrentDictionary<string, (string Token, DateTimeOffset Expiry)> _cache = new();

    public async Task<string> GetAccessTokenAsync(string clusterId, CancellationToken ct = default)
    {
        if (_cache.TryGetValue(clusterId, out var cached) && cached.Expiry > DateTimeOffset.UtcNow.AddMinutes(5))
            return cached.Token;

        var scope = config[$"ReverseProxy:Clusters:{clusterId}:TokenScope"]
            ?? throw new InvalidOperationException($"TokenScope not configured for cluster '{clusterId}'");

        var tokenResult = await credential.GetTokenAsync(new TokenRequestContext([scope]), ct);
        _cache[clusterId] = (tokenResult.Token, tokenResult.ExpiresOn);
        return tokenResult.Token;
    }
}
```

### Token Configuration

Each cluster declares its token scope in `appsettings.json`:

```json
{
  "ReverseProxy": {
    "Clusters": {
      "api-cluster": {
        "TokenScope": "api://your-api-client-id/.default",
        "Destinations": {
          "api": { "Address": "https://localhost:7065" }
        }
      }
    }
  }
}
```

> **Why `TokenCredential`?** Abstracts the credential source - `DefaultAzureCredential` auto-chains Azure CLI (local dev), managed identity (deployed), environment variables (CI). No MSAL configuration code needed.

---

## Authentication Model

Typical split:

- Gateway authenticates user token (for example Entra External/B2C).
- Gateway acquires service token for downstream API.
- Gateway strips caller-supplied forwarded-claims headers and regenerates the payload from the authenticated user.
- API authenticates and allowlists the gateway service identity before accepting the forwarded user claims payload.

```csharp
private static void AddAuthentication(IServiceCollection services, IConfiguration config)
{
    services.AddAuthentication(options =>
    {
        options.DefaultScheme = JwtBearerDefaults.AuthenticationScheme;
    })
    .AddMicrosoftIdentityWebApi(config.GetSection("Gateway_EntraExt"));

    services.AddSingleton<IAuthorizationHandler, TenantMatchHandler>();
    services.AddTransient<IClaimsTransformation, GatewayClaimsTransformer>();
}
```

---

## Pipeline Order

```csharp
public static WebApplication ConfigurePipeline(this WebApplication app)
{
    ConfigureSecurity(app);
    ConfigureCors(app);
    ConfigureMiddleware(app);   // routing, limiter, auth
    ConfigureEndpoints(app);    // health/liveness
    ConfigureReverseProxy(app);
    return app;
}
```

**Why:** Proxy execution must follow authentication so transforms serialize a verified user principal, not attacker-supplied headers or an anonymous identity. Therefore claim-relaying routes require authorization and map only after authentication/authorization middleware.

---

## Multi-Hop Forwarded Headers and Path-Base Hosting

A chain such as edge proxy -> YARP Gateway -> app has two separate trust boundaries. Each process must adopt the public request values from its immediate trusted upstream before redirects, authentication, link generation, or proxying.

1. The edge proxy removes caller-supplied forwarding headers and writes the canonical `X-Forwarded-For`, `X-Forwarded-Proto`, and `X-Forwarded-Host` values.
2. Gateway runs `UseForwardedHeaders()` before HTTPS redirection, authentication/OIDC, routing, and YARP. This changes `Request.Scheme` and `Request.Host` to the public values before YARP's default X-Forwarded transform re-stamps the downstream request.
3. The downstream app also runs `UseForwardedHeaders()` before HTTPS redirection, static files, authentication/OIDC, routing, and endpoints, with `XForwardedProto` and `XForwardedHost` enabled.

The blanket `ASPNETCORE_FORWARDEDHEADERS_ENABLED=true` switch is not the complete chain pattern: it has a one-hop default and does not enable `X-Forwarded-Host`. Configure the middleware explicitly:

```csharp
builder.Services.Configure<ForwardedHeadersOptions>(options =>
{
    options.ForwardedHeaders = ForwardedHeaders.XForwardedFor
        | ForwardedHeaders.XForwardedProto
        | ForwardedHeaders.XForwardedHost;

    // Preferred: trust the immediate proxy IP/network and keep a finite hop limit.
    options.ForwardLimit = 1;
    options.KnownProxies.Add(IPAddress.Parse(configuration["ReverseProxy:TrustedProxyIp"]!));
});
```

Prefer explicit `KnownProxies`/`KnownIPNetworks` and a finite `ForwardLimit`. Container networks with dynamic proxy addresses may instead use `ForwardLimit = null` plus cleared `KnownIPNetworks`/`KnownProxies` only when network policy makes the app port unreachable except through the controlled Gateway. Clearing trust lists on a publicly reachable port lets clients forge scheme and host.

For an externally prefixed app such as `/admin`, preserve that prefix to the downstream host and call `UsePathBase` (for example, `UsePathBase("/admin")`) before static files, routing, auth, and endpoints. Derive the served HTML `<base href>` from the effective `Request.PathBase` and include the same prefix in redirect/logout URIs. If YARP strips the external prefix, `UsePathBase` cannot rediscover it; either preserve the prefix or set `Request.PathBase` from controlled deployment configuration. ASP.NET Core forwarded-header middleware does not infer it from `X-Forwarded-Prefix`.

Deployment proof uses the public URL: an unauthenticated challenge redirects to public `https://<host>/<path-base>/...`, and prefixed UI root, framework, content, API, and OIDC callback paths return the expected status. Internal `http://container:port` must not appear in a redirect.

---

## Path Prefix Normalization Rule

The `PathRemovePrefix` transform removes a prefix **before forwarding to the backend**. Only use it when the backend routes do NOT include that prefix.

| Backend routes registered at | Gateway route match | Correct transform |
|---|---|---|
| `/v1/tasks`, `/v1/categories` | `/api/{**catch-all}` | `PathRemovePrefix: "/api"` |
| `/api/tasks`, `/api/categories` | `/api/{**catch-all}` | *(no transform - keep the prefix)* |

**Wrong (causes 404):** stripping `/api` when the downstream routes already include it:
```
client: /api/categories  -> gateway strips /api -> backend: /categories  -> 404
```

**Correct:** omit the transform when backend and gateway share the same prefix:
```json
"Routes": {
  "api-route": {
    "ClusterId": "api-cluster",
    "AuthorizationPolicy": "Default",
    "Match": { "Path": "/api/{**catch-all}" }
  }
}
```

Pick one convention per project and apply it everywhere. Never use dual-prefix probing logic.

---

## Health and Startup Tasks

- Add aggregated downstream health checks.
- Add startup warmup tasks for token acquisition/dependency checks before live traffic.

---

## Verification

- [ ] YARP routes/clusters load from config
- [ ] transform removes caller-supplied `X-Orig-Request`, then adds a gateway-generated envelope + downstream bearer token
- [ ] API validates an allowlisted gateway `azp`/`appid` before parsing forwarded claims
- [ ] forged-header cases in Forwarded Claims Trust Boundary pass
- [ ] `TokenService` caches cluster tokens with expiry buffer
- [ ] gateway auth section matches intended identity provider config
- [ ] pipeline order is security -> middleware -> endpoints -> reverse proxy
- [ ] forwarded proto and host are applied before OIDC and YARP; downstream app trusts only its controlled proxy chain
- [ ] CORS origins match UI local/deployed origins
- [ ] path-prefix convention is documented and consistent across UI/gateway/API
- [ ] path-prefixed UI derives `<base href>` and redirect URIs from the effective `PathBase`
- [ ] health checks and startup warmup are registered
- [ ] cross-check with [aspire.md](aspire.md) and [iac.md](iac.md)
