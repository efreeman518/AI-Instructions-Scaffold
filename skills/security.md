# Security

## Purpose

Hardening checklist for API, Gateway, and optional hosts. Complements [identity-management.md](identity-management.md) (which handles authn); this covers authz patterns, transport security, and input safety.

---

## Rate Limiting

Use ASP.NET `RateLimiterMiddleware` for request throttling.

### Patterns

```csharp
// In RegisterApiServices.cs
services.AddRateLimiter(options =>
{
    // Fixed window per-tenant
    options.AddPolicy("PerTenant", context =>
        RateLimitPartition.GetFixedWindowLimiter(
            context.User?.FindFirst("tenant_id")?.Value ?? "anonymous",
            _ => new FixedWindowRateLimiterOptions
            {
                PermitLimit = 100,
                Window = TimeSpan.FromMinutes(1)
            }));

    // Sliding window per-endpoint
    options.AddPolicy("PerEndpoint", context =>
        RateLimitPartition.GetSlidingWindowLimiter(
            context.Request.Path.Value ?? "/",
            _ => new SlidingWindowRateLimiterOptions
            {
                PermitLimit = 30,
                Window = TimeSpan.FromSeconds(30),
                SegmentsPerWindow = 3
            }));

    options.RejectionStatusCode = StatusCodes.Status429TooManyRequests;
});
```

### Pipeline Registration

```csharp
app.UseRateLimiter();  // After UseRouting, before UseAuthorization
```

### Testing

> **CRITICAL:** Disable rate limiter in `CustomApiFactory` for integration tests to avoid flaky 429 responses:
> ```csharp
> services.Configure<RateLimiterOptions>(o => o.GlobalLimiter = PartitionedRateLimiter.CreateChained<HttpContext>());
> ```

---

## Input Validation & Sanitization

### DTO Structure Validation

Use [structure-validator-template](../templates/structure-validator-template.md) for DTO shape validation before domain operations. Validates required fields, string lengths, enum ranges.

### String Safety

- Store canonical validated text. Prefer framework text bindings that encode for their sink; when raw output is unavoidable, use the encoder for that specific HTML, attribute, URL, or JavaScript context. **Why:** Storage-time HTML encoding causes double encoding and does not protect other output contexts. Therefore the actual sink owns encoding.
- Enforce `MaxLength` at both DTO (StructureValidator) and EF (`HasMaxLength()`) levels - defense in depth.
- Reject null bytes and control characters in text inputs.

---

## Security Headers

Add middleware to set security headers on all responses:

```csharp
public class SecurityHeadersMiddleware(RequestDelegate next)
{
    public async Task InvokeAsync(HttpContext context)
    {
        context.Response.Headers["X-Content-Type-Options"] = "nosniff";
        context.Response.Headers["X-Frame-Options"] = "DENY";
        context.Response.Headers["Referrer-Policy"] = "strict-origin-when-cross-origin";

        // HSTS - set via config toggle, not in middleware (UseHsts in pipeline)
        // Content-Security-Policy - set in Gateway for UI responses only

        await next(context);
    }
}
```

Register early in pipeline - before routing.

For UI hosts (Gateway serving Uno WASM), add `Content-Security-Policy` with appropriate directives. Use config-driven toggle to adjust between dev/prod.

---

## CORS Policy

CORS configuration belongs in the **Gateway only**. API behind gateway should reject direct browser requests.

### Configuration Pattern

```json
// appsettings.json
{
  "CorsSettings": {
    "AllowedOrigins": ["https://localhost:5001", "https://myapp.azurewebsites.net"],
    "AllowCredentials": true
  }
}
```

```csharp
// Gateway RegisterServices
services.AddCors(options =>
{
    options.AddDefaultPolicy(policy =>
    {
        var origins = config.GetSection("CorsSettings:AllowedOrigins").Get<string[]>() ?? [];
        policy.WithOrigins(origins)
              .AllowAnyMethod()
              .AllowAnyHeader()
              .AllowCredentials();
    });
});
```

---

## Data Protection

ASP.NET Core Data Protection handles encryption of cookies, anti-forgery tokens, and other sensitive payloads. In multi-instance deployments, keys must be shared and persisted externally. **Why:** Without one persisted key ring, another replica or a restarted host cannot decrypt existing payloads, causing intermittent authentication failures and mass session invalidation. Therefore every replica uses the same durable key ring and application name.

### Registration (Program.cs)

```csharp
static void ConfigureDataProtection(
    IServiceCollection services,
    IConfiguration config,
    IHostEnvironment environment)
{
    var credential = CreateAzureCredential(config);
    var dataProtection = services.AddDataProtection()
        .SetApplicationName($"{App}:{environment.EnvironmentName}");
    var keysFileUrl = config.GetValue<string?>("DataProtectionKeysFileUrl", null);
    var encryptionKeyUrl = config.GetValue<string?>("DataProtectionEncryptionKeyUrl", null);
    var hasKeysFile = !string.IsNullOrWhiteSpace(keysFileUrl);
    var hasEncryptionKey = !string.IsNullOrWhiteSpace(encryptionKeyUrl);

    if (hasKeysFile != hasEncryptionKey)
        throw new InvalidOperationException("Configure both Data Protection key URLs or neither.");

    if (!hasKeysFile)
    {
        if (!environment.IsDevelopment() && !environment.IsEnvironment("Testing"))
            throw new InvalidOperationException("Both Data Protection key URLs are required outside Development and Testing.");
        return;
    }

    dataProtection
        .PersistKeysToAzureBlobStorage(new Uri(keysFileUrl!), credential)
        .ProtectKeysWithAzureKeyVault(new Uri(encryptionKeyUrl!), credential);
}

ConfigureDataProtection(builder.Services, builder.Configuration, builder.Environment);
```

### Config

```json
{
  "DataProtectionKeysFileUrl": "https://{storage}.blob.core.windows.net/dataprotection/keys.xml",
  "DataProtectionEncryptionKeyUrl": "https://{vault}.vault.azure.net/keys/{keyname}"
}
```

### Packages

`Azure.Extensions.AspNetCore.DataProtection.Blobs` + `Azure.Extensions.AspNetCore.DataProtection.Keys`.

### Rules

- Omit both config keys in development and isolated test hosts - Data Protection uses its local default key storage while retaining the application discriminator.
- Use managed identity (`DefaultAzureCredential`) for both Blob and Key Vault access.
- Use the same `SetApplicationName` value for every replica of one app; use a different value for unrelated apps sharing the key store.
- The Blob container and Key Vault key must exist before first deployment.
- Key Vault key should have a rotation policy configured.

---

## Dependency Scanning

### CI Pipeline

Add `dotnet nuget audit` to CI builds:

```yaml
- script: dotnet restore --locked-mode
- script: dotnet nuget audit --level moderate --output json
```

### GitHub Dependabot

```yaml
# .github/dependabot.yml
version: 2
updates:
  - package-ecosystem: "nuget"
    directory: "/"
    schedule:
      interval: "weekly"
    open-pull-requests-limit: 10
```

### NuGet Vulnerability Alerts

Enable in `Directory.Build.props` or `.csproj`:
```xml
<PropertyGroup>
  <NuGetAudit>true</NuGetAudit>
  <NuGetAuditLevel>moderate</NuGetAuditLevel>
</PropertyGroup>
```

---

## Secret Rotation

Secrets must be stored in Azure Key Vault (see [configuration-secrets.md](configuration-secrets.md)).

### Rotation Workflow

1. **Create new version** - add new secret version in Key Vault
2. **Update config** - deploy app with config pointing to latest version (Key Vault references auto-resolve latest)
3. **Verify** - confirm app functions with new secret
4. **Remove old version** - disable/remove previous version after grace period

### Configuration Validation

> **CRITICAL:** Use `ValidateOnStart()` for options that bind to secrets - fail fast if secrets are missing or expired rather than failing on first request:
> ```csharp
> services.AddOptions<DatabaseSettings>()
>     .BindConfiguration("DatabaseSettings")
>     .ValidateDataAnnotations()
>     .ValidateOnStart();
> ```

---

## Verification Checklist

- [ ] Rate limiting registered with per-tenant and/or per-endpoint policies
- [ ] Rate limiter disabled in `CustomApiFactory` for tests
- [ ] `StructureValidator` enforces `MaxLength` matching EF configuration
- [ ] User content stays canonical in storage and is context-encoded at the rendering boundary
- [ ] Security headers middleware added (X-Content-Type-Options, X-Frame-Options)
- [ ] CORS configured in Gateway only - API rejects direct browser requests
- [ ] `dotnet nuget audit` included in CI pipeline
- [ ] Dependabot configured for NuGet ecosystem
- [ ] Data Protection configured with Azure Blob key storage and Key Vault key encryption
- [ ] Secrets stored in Key Vault with rotation workflow documented
- [ ] `ValidateOnStart()` used for critical configuration sections
