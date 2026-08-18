# Configuration & Secrets Management

> **When to read:** Phase 5c, when defining the appsettings hierarchy, wiring User Secrets locally, configuring Key Vault with managed identity, or shaping environment-specific config layering.
> **Skip if:** No secrets in scope; appsettings already match the canonical pattern; pure domain or pure API endpoint work.

## Overview

Configuration flows through a strict hierarchy. Secrets are never committed - use User Secrets locally and Key Vault with managed identity in Azure.

See appsettings-template for config file patterns.

Base types (`IKeyVaultManager`, `IKeyVaultCryptoUtility`) come from the `EF.KeyVault` package - see [package-dependencies.md](package-dependencies.md) and the [EF.Packages repo](https://github.com/efreeman518/EF.Packages) for full API details.

---

## Config vs Code

**Must be in config (never hardcoded):**
- CORS allowed origins
- Rate limit thresholds
- DB retry/timeout settings
- Cosmos database and container names
- Gateway/external service base URLs
- Cache duration and tuning values

**May stay in code when not environment-sensitive:**
- OpenAPI title and description
- Enum-based business constants that never differ across deployments

**Required settings must fail fast.** When a setting is required for correct runtime behavior, throw on startup rather than silently falling back:

```csharp
var origins = config.GetSection("Cors:AllowedOrigins").Get<string[]>();
if (origins is null || origins.Length == 0)
    throw new InvalidOperationException("Cors:AllowedOrigins is required but missing from configuration.");
```

Apply this pattern to: CORS origins, gateway base URLs, Entra auth keys (`Instance`, `TenantId`, `ClientId`), and any external dependency URL.

---

### Prerequisites

- [solution-structure.md](solution-structure.md)
- [aspire.md](aspire.md)
- [iac.md](iac.md)
- [package-dependencies.md](package-dependencies.md)
- [identity-management.md](identity-management.md)
- [bootstrapper.md](bootstrapper.md)

### Configuration Hierarchy

**Local:**
1. `appsettings.json`
2. `appsettings.Development.json`
3. User Secrets
4. Environment variables
5. Aspire `WithReference()` injection (highest)

**Azure:**
1. `appsettings.json` / `appsettings.Production.json`
2. Azure App Configuration
3. Azure Key Vault
4. Container Apps env vars/secrets (highest)

---

## Local Configuration

### Base appsettings

```json
{
  "AppName": "{Project}Api",
  "ConnectionStrings": {
    "{Project}DbContextTrxn": "",
    "{Project}DbContextQuery": "",
    "Redis1": ""
  },
  "FeatureFlags": {
    "EnableNotifications": false
  }
}
```

### Development overrides

```json
{
  "ConnectionStrings": {
    "{Project}DbContextTrxn": "Server=localhost;Database={Project}Db;Trusted_Connection=true;TrustServerCertificate=true",
    "{Project}DbContextQuery": "Server=localhost;Database={Project}Db;Trusted_Connection=true;TrustServerCertificate=true"
  }
}
```

### Aspire override

```csharp
api.WithReference(projectDb, connectionName: "{Project}DbContextTrxn")
   .WithReference(projectDb, connectionName: "{Project}DbContextQuery")
   .WithReference(redis, connectionName: "Redis1");
```

### Options & Feature Flags

```json
{
  "FeatureFlags": {
    "EnableNotifications": true,
    "EnableScheduler": true
  }
}
```

```csharp
public class NotificationOptions
{
    public const string SectionName = "Notifications";
    public bool EnableEmail { get; set; }
    public bool EnableSms { get; set; }
    public string SendGridApiKey { get; set; } = string.Empty;
}

services.Configure<NotificationOptions>(config.GetSection(NotificationOptions.SectionName));
```

### PostConfigure

Use `PostConfigure<T>()` when settings need environment-specific overrides after initial binding - for example, swapping webhook URLs in development:

```csharp
services.PostConfigure<WebhookSettings>(options =>
{
    if (builder.Environment.IsDevelopment())
        options.CallbackUrl = config["DevTunnel:BaseUrl"] + "/api/webhook";
});
```

### Local Stub Pattern (Required)

Register stubs when credentials are missing so the app builds/runs without external secrets.

```csharp
if (builder.Environment.IsDevelopment())
{
    builder.Services.AddAuthentication("DevBypass")
        .AddScheme<AuthenticationSchemeOptions, DevBypassAuthHandler>("DevBypass", null);
}

if (string.IsNullOrEmpty(config["Stripe:ApiKey"]))
    services.AddSingleton<IStripeService, StubStripeService>();
else
    services.AddScoped<IStripeService, StripeService>();
```

---

## User Secrets

```powershell
dotnet user-secrets init --project src/Host/{Host}.Api
dotnet user-secrets set "ServiceAuth:api-cluster:ClientSecret" "your-client-secret" --project src/Host/{Host}.Api
dotnet user-secrets set "ConnectionStrings:Redis1" "localhost:6379" --project src/Host/{Host}.Api
```

---

## Shared Azure Credential (Program.cs)

Create a single `DefaultAzureCredential` instance in `Program.cs` and reuse it for all Azure services (App Configuration, Data Protection, Key Vault config provider). This avoids redundant token cache instances.

```csharp
var credential = CreateAzureCredential(config);

static DefaultAzureCredential CreateAzureCredential(IConfiguration config)
{
    var options = new DefaultAzureCredentialOptions();
    var managedIdentityClientId = config.GetValue<string?>("ManagedIdentityClientId", null);
    if (managedIdentityClientId is not null)
        options.ManagedIdentityClientId = managedIdentityClientId;
    var sharedTokenCacheTenantId = config.GetValue<string?>("SharedTokenCacheTenantId", null);
    if (sharedTokenCacheTenantId is not null)
        options.SharedTokenCacheTenantId = sharedTokenCacheTenantId;
    return new DefaultAzureCredential(options);
}
```

- `ManagedIdentityClientId`: set for user-assigned managed identity in Azure.
- `SharedTokenCacheTenantId`: set for local dev when the default tenant doesn't match.
- Omit both in simple Aspire dev - `DefaultAzureCredential` chains through developer credentials automatically.

---

## Azure App Configuration

```csharp
builder.Configuration.AddAzureAppConfiguration(options =>
{
    options.Connect(new Uri(config["AzureAppConfigEndpoint"]), credential)
        .Select(KeyFilter.Any, LabelFilter.Null)
        .Select(KeyFilter.Any, builder.Environment.EnvironmentName)
        .ConfigureKeyVault(kv => kv.SetCredential(credential))
        .ConfigureRefresh(refresh =>
        {
            refresh.Register("Sentinel", refreshAll: true)
                   .SetRefreshInterval(TimeSpan.FromMinutes(5));
        });
});
```

---

## Azure Key Vault

Use Key Vault for:

1. Startup configuration secrets
2. Runtime secret/key/certificate operations
3. Cryptographic operations where private keys remain in Key Vault

### Non-Negotiables

1. Use managed identity/`DefaultAzureCredential` in hosted environments.
2. Keep Key Vault access behind project-specific abstractions.
3. Never log secret values or return them in raw API payloads.
4. Use RBAC least-privilege roles for secrets/keys/certs.
5. Keep soft delete and purge protection enabled.

### Key Vault Configuration Provider (Direct Load)

```csharp
builder.Configuration.AddAzureKeyVault(
    new Uri($"https://{vaultName}.vault.azure.net/"),
    credential);
```

### Key Vault appsettings

`appsettings.json`

```json
{
  "KeyVault": {
    "VaultUri": ""
  },
  "{Project}KeyVaultManagerSettings": {
    "KeyVaultClientName": "{Project}KVClient"
  }
}
```

`appsettings.Development.json`

```json
{
  "KeyVault": {
    "VaultUri": "https://{project}-kv-dev.vault.azure.net/"
  }
}
```

### Core Manager Contract

`IKeyVaultManager` is the runtime abstraction for secret/key/certificate lifecycle actions.

```csharp
public interface IKeyVaultManager
{
    Task<string?> GetSecretAsync(string name, string? version = null, CancellationToken cancellationToken = default);
    Task<string?> SaveSecretAsync(string name, string? value = null, CancellationToken cancellationToken = default);
    Task<DeletedSecret> StartDeleteSecretAsync(string name, CancellationToken cancellationToken = default);

    Task<JsonWebKey?> GetKeyAsync(string name, string? version = null, CancellationToken cancellationToken = default);
    Task<JsonWebKey?> CreateKeyAsync(string name, KeyType keyType, CreateKeyOptions? options = null, CancellationToken cancellationToken = default);
    Task<KeyRotationPolicy> UpdateKeyRotationPolicyAsync(string name, KeyRotationPolicy policy, CancellationToken cancellationToken = default);
    Task<JsonWebKey?> RotateKeyAsync(string name, CancellationToken cancellationToken = default);
    Task<JsonWebKey?> DeleteKeyAsync(string name, CancellationToken cancellationToken = default);

    Task<byte[]?> GetCertAsync(string certificateName, CancellationToken cancellationToken = default);
    Task<byte[]?> ImportCertAsync(ImportCertificateOptions importCertificateOptions, CancellationToken cancellationToken = default);
}
```

### Project Wrapper Pattern

```csharp
public interface I{Project}KeyVaultManager : IKeyVaultManager { }

public class {Project}KeyVaultManager : KeyVaultManagerBase, I{Project}KeyVaultManager
{
    public {Project}KeyVaultManager(
        ILogger<{Project}KeyVaultManager> logger,
        IOptions<{Project}KeyVaultManagerSettings> settings,
        IAzureClientFactory<SecretClient> secretClientFactory,
        IAzureClientFactory<KeyClient> keyClientFactory,
        IAzureClientFactory<CertificateClient> certClientFactory)
        : base(logger, settings, secretClientFactory, keyClientFactory, certClientFactory) { }
}

public class {Project}KeyVaultManagerSettings : KeyVaultManagerSettingsBase { }
```

`KeyVaultManagerSettingsBase` requires `KeyVaultClientName`.

### Crypto Utility Contract

```csharp
public interface IKeyVaultCryptoUtility
{
    Task<byte[]> EncryptAsync(string plaintext);
    Task<string> DecryptAsync(byte[] ciphertext);
}
```

Use `CryptographyClient` (typically RSA-OAEP). This keeps private key operations in Key Vault.

### DI Registration (Bootstrapper)

```csharp
private static void AddKeyVaultServices(IServiceCollection services, IConfiguration config)
{
    var vaultUri = new Uri(config["KeyVault:VaultUri"]!);

    services.AddAzureClients(builder =>
    {
        builder.AddSecretClient(vaultUri).WithName("{Project}KVClient");
        builder.AddKeyClient(vaultUri).WithName("{Project}KVClient");
        builder.AddCertificateClient(vaultUri).WithName("{Project}KVClient");
        builder.UseCredential(new DefaultAzureCredential());
    });

    services.Configure<{Project}KeyVaultManagerSettings>(
        config.GetSection("{Project}KeyVaultManagerSettings"));

    services.AddScoped<I{Project}KeyVaultManager, {Project}KeyVaultManager>();
}
```

Crypto utility registration pattern:

```csharp
services.AddSingleton(sp =>
{
    var keyClient = new KeyClient(new Uri(config["KeyVault:VaultUri"]!), new DefaultAzureCredential());
    return keyClient.GetCryptographyClient(config["KeyVault:EncryptionKeyName"]!);
});
services.AddScoped<IKeyVaultCryptoUtility, KeyVaultCryptoUtility>();
```

### Usage Patterns

- **Startup configuration secrets:** Key Vault configuration provider.
- **Runtime secret management:** `I{Project}KeyVaultManager`.
- **Field-level encryption:** `IKeyVaultCryptoUtility`.
- **Key lifecycle:** create + policy + rotate through manager abstraction.
- **Certificates:** retrieve/import via manager abstraction.

Cache hot secrets appropriately; avoid per-request Key Vault round-trips unless required.

### Security Rules

1. `DefaultAzureCredential` + managed identity for production.
2. Minimal RBAC scope:
   - Secrets User/Officer only when needed,
   - Crypto User only for crypto operations,
   - Certificates User only for cert retrieval.
3. Keep diagnostic logs metadata-only (operation names, key names, status).
4. Isolate dev/prod vault URIs by environment.

---

## Container Apps Configuration

```bicep
env: [
  { name: 'ConnectionStrings__{Project}DbContextTrxn', secretRef: 'sql-trxn-connstr' }
  { name: 'ConnectionStrings__Redis1', secretRef: 'redis-connstr' }
  { name: 'AzureAppConfigEndpoint', value: appConfig.outputs.endpoint }
]
```

`__` maps to `:` in .NET config keys.

---

## Rules

1. Never commit secrets.
2. Prefer managed identity over secrets.
3. Keep config keys consistent across API/Gateway/Scheduler/Functions/UI.
4. Use `Sentinel` + labels for App Configuration refresh strategy.
5. In lite mode, keep to `appsettings` + User Secrets and add App Config/Key Vault later.
6. Map compliance metadata from `.scaffold/resource-implementation.yaml` to configuration controls (classification labels, retention switches, audit flags).

---

## Verification

- [ ] No real secrets in committed appsettings files
- [ ] Aspire connection names match appsettings keys
- [ ] User Secrets initialized for host projects
- [ ] App Config label selection matches environment
- [ ] Key Vault resolves via managed identity
- [ ] `ASPNETCORE_ENVIRONMENT` is correctly set per target
- [ ] Project manager derives from `KeyVaultManagerBase`
- [ ] Settings derive from `KeyVaultManagerSettingsBase`
- [ ] Named `SecretClient`/`KeyClient`/`CertificateClient` are registered
- [ ] Authentication uses `DefaultAzureCredential`
- [ ] Vault URI and client name come from configuration
- [ ] Crypto utility is bound to a specific key
- [ ] Secrets are not logged or exposed in API output
- [ ] Cross-check with [identity-management.md](identity-management.md), [iac.md](iac.md)

---

**TaskFlow proof (local):** `../scaffold-proof/src/Host/TaskFlow.Api/appsettings.json` + `appsettings.Development.json` for the layered hierarchy; gateway/scheduler/functions hosts at `../scaffold-proof/src/Host/TaskFlow.Gateway/appsettings.json`, `TaskFlow.Scheduler/appsettings.json`, `TaskFlow.Functions/appsettings.json`
**TaskFlow proof (remote fallback):** <https://github.com/efreeman518/scaffold-proof/blob/main/src/Host/TaskFlow.Api/appsettings.json>
