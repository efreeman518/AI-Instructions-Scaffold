# appsettings.json Reference Template

| | |
|---|---|
| **Files** | `appsettings.json` per host (API, Gateway, Scheduler, Functions) |
| **Depends on** | [configuration-secrets.md](../skills/configuration-secrets.md) |
| **Referenced by** | [api.md](../skills/api.md), [gateway.md](../skills/gateway.md), [bootstrapper.md](../skills/bootstrapper.md) |

## API appsettings.json

This is a complete reference of all configuration sections used across the solution. Customize values per project.

```json
{
  "AppName": "{Host}.Api",

  "ConnectionStrings": {
    "{Project}DbContextTrxn": "Server=localhost,1433;Database={Project}Db;Integrated Security=True;TrustServerCertificate=True",
    "{Project}DbContextQuery": "Server=localhost,1433;Database={Project}Db;Integrated Security=True;TrustServerCertificate=True;ApplicationIntent=ReadOnly",
    "Redis1": "localhost:6379"
  },

  "CacheSettings": [
    {
      "Name": "Default",
      "DurationMinutes": 30,
      "DistributedCacheDurationMinutes": 60,
      "FailSafeMaxDurationMinutes": 120,
      "FailSafeThrottleDurationSeconds": 60,
      "RedisConnectionStringName": "Redis1",
      "BackplaneChannelName": "cache-sync"
    },
    {
      "Name": "StaticData",
      "DurationMinutes": 1440,
      "DistributedCacheDurationMinutes": 2880,
      "FailSafeMaxDurationMinutes": 4320,
      "FailSafeThrottleDurationSeconds": 300,
      "RedisConnectionStringName": "Redis1",
      "BackplaneChannelName": "cache-sync-static"
    }
  ],

  "AzureAd": {
    "Instance": "https://login.microsoftonline.com/",
    "TenantId": "{entra-tenant-id}",
    "ClientId": "{api-client-id}",
    "Audience": "api://{api-client-id}"
  },

  "OpenApiSettings": {
    "Enable": true
  },

  "EnforceHttpsRedirection": false,

  "Logging": {
    "LogLevel": {
      "Default": "Information",
      "Microsoft.AspNetCore": "Warning",
      "Microsoft.EntityFrameworkCore.Database.Command": "Warning"
    }
  },

  "AllowedHosts": "*"
}
```

## Gateway appsettings.json

```json
{
  "AppName": "{Gateway}.Gateway",

  "Gateway_EntraExt": {
    "Instance": "https://{tenant-name}.ciamlogin.com/",
    "TenantId": "{entra-external-tenant-id}",
    "ClientId": "{gateway-client-id}",
    "Audience": "{gateway-client-id}"
  },

  "ServiceAuth": {
    "api-cluster": {
      "TenantId": "{entra-tenant-id}",
      "ClientId": "{gateway-service-client-id}",
      "ClientSecret": "{gateway-service-client-secret}",
      "Scope": "api://{api-client-id}/.default"
    }
  },

  "ReverseProxy": {
    "Routes": {
      "api-route": {
        "ClusterId": "api-cluster",
        "Match": {
          "Path": "api/{**catch-all}"
        },
        "Transforms": [
          { "PathRemovePrefix": "/api" }
        ]
      }
    },
    "Clusters": {
      "api-cluster": {
        "Destinations": {
          "api": {
            "Address": "https://localhost:7065"
          }
        }
      }
    }
  },

"CorsSettings": {
"AllowedOrigins": ["https://localhost:44318", "http://localhost:5173"]
},

"AiServices": {
"UseSearch": false,
"UseAgents": false,
"UseVectorSearch": false,
"DisableFoundryLocal": false,
"RequireFoundryLocal": false,
"LocalModel": "qwen2.5-0.5b",
"LocalWebUrl": "http://127.0.0.1:52415",
"DevStubContent": false,
"FoundryEndpoint": "",
"AgentModelDeployment": "",
"EmbeddingModelDeployment": "",
"SearchEndpoint": "",
"SearchIndexName": "",
"FoundryResourceName": "",
"FoundryResourceGroup": "",
"FoundryProjectEndpoint": "",
"FoundryAgentName": ""
},

"Logging": {
"LogLevel": {
      "Default": "Information",
      "Microsoft.AspNetCore": "Warning",
      "Yarp": "Information"
    }
  }
}
```

## appsettings.Development.json (API)

```json
{
  "ConnectionStrings": {
    "{Project}DbContextTrxn": "Server=localhost,1433;Database={Project}Db;Integrated Security=True;TrustServerCertificate=True",
    "{Project}DbContextQuery": "Server=localhost,1433;Database={Project}Db;Integrated Security=True;TrustServerCertificate=True"
  },
  "OpenApiSettings": {
    "Enable": true
  },
  "Logging": {
    "LogLevel": {
      "Default": "Debug",
      "Microsoft.EntityFrameworkCore.Database.Command": "Information"
    }
  }
}
```

## Notes

- Connection string names must match what the Bootstrapper expects: `{Project}DbContextTrxn` and `{Project}DbContextQuery`
- With Aspire, connection strings are **injected automatically** via `.WithReference(projectDb, connectionName: ...)` - no manual config needed in development
- Redis connection string name (`Redis1`) must match the `RedisConnectionStringName` in `CacheSettings`
- `CacheSettings` is an array - each entry creates a named FusionCache instance
- `FailSafeThrottleDurationSeconds` - note the unit is **seconds** (passed to `TimeSpan.FromSeconds()`)
- `ServiceAuth` section in Gateway maps cluster IDs to OAuth2 client credential configs
- `AiServices:RequireFoundryLocal` stays false in normal appsettings; set true only in `Test.FoundryLocal`
- For production/Azure: use Key Vault references or App Configuration for secrets
