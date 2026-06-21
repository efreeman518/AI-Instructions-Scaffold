# Infrastructure Wiring Patterns

Cross-project wiring for caching and Aspire orchestration. Load in Phase 5b when runtime services are enabled. Reload in Phase 5c only when an enabled optional host needs shared infrastructure wiring.

For base types used here, see [../support/ef-packages-reference.md](../support/ef-packages-reference.md).

---

## Multi-Cache Configuration

**Source:** `Host/{App}.Bootstrapper/Registration/RegisterServices.Caching.cs`

FusionCache config loop: bind `CacheSettings[]` from configuration, register each as a named FusionCache with exact entry option defaults (fail-safe, jitter, eager refresh threshold), conditional Redis backplane per cache instance.

```csharp
private static void AddCachingServices(IServiceCollection services, IConfiguration config)
{
    List<CacheSettings> cacheSettings = [];
    config.GetSection("CacheSettings").Bind(cacheSettings);
    foreach (var cacheSettingsInstance in cacheSettings)
    {
        ConfigureFusionCacheInstance(services, config, cacheSettingsInstance);
    }
}

private static void ConfigureFusionCacheInstance(IServiceCollection services,
    IConfiguration config, CacheSettings cacheSettingsInstance)
{
    var jsonOptions = new JsonSerializerOptions
    {
        ReferenceHandler = ReferenceHandler.Preserve,
    };

    var fcBuilder = services.AddFusionCache(cacheSettingsInstance.Name)
        .WithSystemTextJsonSerializer(jsonOptions)
        .WithCacheKeyPrefix($"{cacheSettingsInstance.Name}:")
        .WithDefaultEntryOptions(new FusionCacheEntryOptions()
        {
            Duration = TimeSpan.FromMinutes(cacheSettingsInstance.DurationMinutes),
            DistributedCacheDuration = TimeSpan.FromMinutes(
                cacheSettingsInstance.DistributedCacheDurationMinutes),
            IsFailSafeEnabled = true,
            FailSafeMaxDuration = TimeSpan.FromMinutes(
                cacheSettingsInstance.FailSafeMaxDurationMinutes),
            FailSafeThrottleDuration = TimeSpan.FromSeconds(
                cacheSettingsInstance.FailSafeThrottleDurationMinutes),
            JitterMaxDuration = TimeSpan.FromSeconds(10),
            FactorySoftTimeout = TimeSpan.FromSeconds(1),
            FactoryHardTimeout = TimeSpan.FromSeconds(30),
            EagerRefreshThreshold = 0.9f
        });

    ConfigureFusionCacheRedis(fcBuilder, config, cacheSettingsInstance);
}
```

**Conditional Redis backplane** -- only wired when `RedisConnectionStringName` is set in that cache's config:

```csharp
private static void ConfigureFusionCacheRedis(IFusionCacheBuilder fcBuilder,
    IConfiguration config, CacheSettings cacheSettingsInstance)
{
    if (!string.IsNullOrEmpty(cacheSettingsInstance.RedisConnectionStringName))
    {
        var redisConnectionString = config.GetConnectionString(
            cacheSettingsInstance.RedisConnectionStringName);
        fcBuilder
            .WithDistributedCache(new RedisCache(new RedisCacheOptions()
            {
                Configuration = redisConnectionString
            }))
            .WithBackplane(new RedisBackplane(new RedisBackplaneOptions
            {
                Configuration = redisConnectionString
            }));
    }
}
```

---

## ServiceDefaults Configuration

**Source:** `Host/Aspire/ServiceDefaults/Extensions.cs`

Every host project calls `builder.AddServiceDefaults(config, appName)` as the first registration step. This extension lives in the shared ServiceDefaults project and wires OpenTelemetry, health checks, service discovery, and HTTP resilience defaults.

```csharp
public static IHostApplicationBuilder AddServiceDefaults(
    this IHostApplicationBuilder builder,
    IConfiguration config,
    string appName)
{
    builder.ConfigureOpenTelemetry();
    builder.AddDefaultHealthChecks();
    builder.Services.AddServiceDiscovery();
    builder.Services.ConfigureHttpClientDefaults(http =>
    {
        http.AddStandardResilienceHandler();
        http.AddServiceDiscovery();
    });
    return builder;
}
```

**Rules:**
- Call once per host, before any other service registration.
- Do not duplicate OpenTelemetry or health check setup in individual hosts - ServiceDefaults owns it.
- Add domain-specific readiness checks (SQL, Redis) in host registration, not in ServiceDefaults.

---

## Aspire Resource Wiring

**Source:** `Host/Aspire/AppHost/AppHost.cs`

SQL with password parameter + data volume, Redis with data volume, per-service endpoints/references/WaitFor, Gateway wired to API only, Scheduler pinned to 1 replica.

```csharp
var builder = DistributedApplication.CreateBuilder(args);

// -- Shared infrastructure
var sqlPassword = builder.AddParameter("sql-password", secret: true);
var sql = builder.AddSqlServer("sql", sqlPassword)
    .WithImageTag("2025-latest")
    .WithDataVolume("{app}-sql-data")
    .AddDatabase("{App}Db");

var redis = builder.AddRedis("redis")
    .WithDataVolume("{app}-redis-data");

// -- API: references both SQL + Redis
var {app}Api = builder.AddProject<Projects.{App}_Api>("{app}api")
    .WithReference(sql)
    .WithReference(redis)
    .WithHttpEndpoint(port: 5065, name: "http-api")
    .WithHttpsEndpoint(port: 7065, name: "https-api")
    .WaitFor(sql)
    .WaitFor(redis);

// -- Scheduler: same infra refs, single replica
var {app}Scheduler = builder.AddProject<Projects.{App}_Scheduler>("{app}scheduler")
    .WithReference(sql)
    .WithReference(redis)
    .WithHttpEndpoint(port: 5100, name: "http-scheduler")
    .WithHttpsEndpoint(port: 7100, name: "https-scheduler")
    .WithReplicas(1)
    .WaitFor(sql)
    .WaitFor(redis);

// -- Gateway (YARP): references API only, not infra directly
var {app}Gateway = builder.AddProject<Projects.{App}_Gateway>("{app}gateway")
    .WithReference({app}Api)
    .WithHttpEndpoint(port: 5028, name: "http-gateway")
    .WithHttpsEndpoint(port: 7028, name: "https-gateway")
    .WaitFor({app}Api);

// -- Function App: SQL only
var functionApp = builder.AddProject<Projects.FunctionApp>("functionapp")
    .WaitFor(sql);

builder.Build().Run();
```

### Azure AI Foundry (when `includeAiServices: true`)

Wire the model with `Aspire.Hosting.Foundry` so it provisions Azure on publish. The deployment resource name is the connection name consumers bind to. This snippet covers the default **inference** surface; for the **existing-account** and **project + server-hosted agent** surfaces see [../skills/ai-integration.md](../skills/ai-integration.md) -> *Foundry Projects and Server-Hosted Agents*.

> **Local path note (canonical owner: [../skills/ai-integration.md](../skills/ai-integration.md), "SDK-direct API-host bootstrap").** `RunAsFoundryLocal()` is broken against GA Foundry Local (dotnet/aspire#12750), so the snippet below omits it: the local path wires **no** `chat` resource (no `ConnectionStrings:chat`) and forwards **no** opt-in var - the API host attempts `Microsoft.AI.Foundry.Local` by default when Azure is absent, falling back to no-op. The full diagnosis, availability-driven bootstrap, `AiServices:DisableFoundryLocal` opt-out, future-restored `RunAsFoundryLocal()` branch, and migration checklist live there - do not restate them here. The Azure provision/existing path is unaffected.

```csharp
IResourceBuilder<FoundryDeploymentResource>? chat = null;
var azureConfigured = builder.ExecutionContext.IsPublishMode
    || !string.IsNullOrWhiteSpace(builder.Configuration["AiServices:FoundryEndpoint"])
    || Environment.GetEnvironmentVariable("MYAPP_USE_AZURE_FOUNDRY") == "true";

if (azureConfigured)
{
    // Azure path stays on Aspire: provisions (or connects to) a Foundry account + "chat" deployment.
    chat = builder.AddFoundry("foundry").AddDeployment("chat", FoundryModel.OpenAI.Gpt4oMini);
}

// Azure: wire the deployment (injects ConnectionStrings:chat + CHAT_* env).
// Local: nothing to wire and no opt-in var - the API host attempts Microsoft.AI.Foundry.Local
// on its own when Azure is absent (that bootstrap + the AiServices:DisableFoundryLocal opt-out +
// future RunAsFoundryLocal() branch + migration are owned by ../skills/ai-integration.md).
// A TESTING AppHost forces no-op so the RID-free mesh never starts a model:
//   {app}Api = {app}Api.WithEnvironment("AiServices__DisableFoundryLocal", "true");
if (chat is not null)
    {app}Api = {app}Api.WithReference(chat);
```

To consume an **existing** Foundry account instead of provisioning a new one (the `chat` deployment must already exist), replace the `azureConfigured` branch with `RunAsExisting`:

```csharp
var name = builder.AddParameter("foundry-name");
var rg = builder.AddParameter("foundry-rg");
chat = builder.AddFoundry("foundry").RunAsExisting(name, rg)
    .AddDeployment("chat", FoundryModel.OpenAI.Gpt4oMini);
```

**Registration boundary:** the Azure model client is registered at the **host** (`IHostApplicationBuilder.AddAzureChatCompletionsClient("chat").AddChatClient()` from `Aspire.Azure.AI.Inference`), NOT in the `IServiceCollection` AI-registration extension; the connection name must equal the deployment resource name. The `IServiceCollection` extension gates live agents on `IChatClient` presence and registers a no-op when none was wired. The local workaround instead registers `IChatClient` via the SDK-direct bootstrap. See [../skills/ai-integration.md](../skills/ai-integration.md).
```
