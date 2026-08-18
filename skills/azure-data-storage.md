# Azure Data Storage (Blob, Table, Cosmos DB)

Base types for each store come from dedicated `EF.*` packages - see [package-dependencies.md](package-dependencies.md) and the [EF.Packages repo](https://github.com/efreeman518/EF.Packages) for full API details.

## Prerequisites

- [package-dependencies.md](package-dependencies.md)
- [solution-structure.md](solution-structure.md)
- [bootstrapper.md](bootstrapper.md)
- [configuration-secrets.md](configuration-secrets.md)

## Overview

| Storage type | Best use | Partition strategy | Aspire resource |
|---|---|---|---|
| Blob Storage | Unstructured payloads (documents, media, exports, backups) | Container + blob path hierarchy | `AddAzureStorage().AddBlobs()` |
| Table Storage | Low-cost, high-volume key-value access; `PartitionKey + RowKey` driven queries | `PartitionKey` aligned to dominant query shape; `RowKey` unique within partition | `AddAzureStorage().AddTables()` |
| Cosmos DB | Document-first aggregates (nested JSON, high-throughput partitioned access, global distribution) | Dominant read/query path (e.g., `TenantId`) | `AddAzureCosmosDB()` |

### Local Inspection Tools

- **Azurite (Blob/Queue/Table):** Microsoft Azure Storage Explorer (desktop) is the supported first-party tool. Keep Aspire host ports on the defaults `10000`/`10001`/`10002` so Storage Explorer auto-detects the emulator. Browser-based storage explorers are third-party - use only with explicit approval.
- **Cosmos DB preview emulator:** Use the built-in Data Explorer (`WithDataExplorer(1234)`) for local inspection. When `http://localhost:1234` spins forever, inspect the Cosmos resource health first - the explorer is served from the emulator itself.

See [aspire.md](aspire.md) -> *Local Explorer Tooling* for the canonical port matrix, the `isTesting` gate, and the Cosmos preview emulator persistence exception.

Quick positioning against SQL:

- **SQL:** relational joins + transactions + FK relationships + migrations.
- **Cosmos DB:** schema-less documents + partition-aware access + single-document atomic writes. Tenant filtering is explicit (no EF global query filter).
- **Table Storage:** partitioned key-value entities, lowest-cost transaction model.

---

## Common Patterns

All three stores follow the same structural conventions.

### Settings Class

Each store has a project-specific settings POCO that inherits the package base:

```csharp
public class {Project}{Store}RepositorySettings : {Store}RepositorySettingsBase { }
```

| Store | Base class | Key setting |
|---|---|---|
| Blob | `BlobRepositorySettingsBase` | `BlobServiceClientName` |
| Table | `TableRepositorySettingsBase` | `TableServiceClientName` |
| Cosmos DB | `CosmosDbRepositorySettingsBase` | `CosmosDbId` |

### Repository Wrapper

Each store exposes a project-specific interface + implementation deriving from the package base:

```csharp
public interface I{Project}{Store}Repository : I{Store}Repository { }

public class {Project}{Store}Repository : {Store}RepositoryBase, I{Project}{Store}Repository
{
    public {Project}{Store}Repository(
        ILogger<{Project}{Store}Repository> logger,
        IOptions<{Project}{Store}RepositorySettings> settings,
        ...)                           // Blob/Table: + IAzureClientFactory<*ServiceClient>
        : base(logger, settings, ...) { }
}
```

### DI Registration (Bootstrapper)

Registration follows the same three-step pattern in each `Add{Store}Services` method:

1. Register a **named service client** via `AddAzureClients`.
2. **Bind settings** from configuration.
3. Register the **scoped repository**.

```csharp
private static void Add{Store}Services(IServiceCollection services, IConfiguration config)
{
    services.AddAzureClients(builder =>
    {
        builder.Add{Store}ServiceClient(config.GetConnectionString("{ConnectionName}")!)
            .WithName("{Project}{Store}Client");
    });

    services.Configure<{Project}{Store}RepositorySettings>(
        config.GetSection("{Project}{Store}RepositorySettings"));

    services.AddScoped<I{Project}{Store}Repository, {Project}{Store}Repository>();
}
```

### Aspire Integration

Blob and Table share an `AzureStorage` resource with emulator support. Cosmos DB uses its own resource.

> **Dependency alignment:** Resolve the latest stable `Microsoft.Extensions.Azure` when using `IAzureClientFactory<T>` alongside `EF.Host`. Keep the concrete version in `Directory.Packages.props`; restore and build must reject an incompatible transitive family.

> **Cosmos DB dependency:** When adding Cosmos, resolve the latest stable compatible `Newtonsoft.Json` explicitly in `Directory.Packages.props`; do not preserve an older transitive version from copied guidance.

```csharp
// Blob + Table (shared Azure Storage resource)
var storage = builder.AddAzureStorage("AzureStorage").RunAsEmulator();
var blobs  = storage.AddBlobs("BlobStorage1");
var tables = storage.AddTables("TableStorage1");

// Cosmos DB
var cosmos = builder.AddAzureCosmosDB("CosmosDb1").RunAsEmulator();

builder.AddProject<Projects.{Project}_Api>("{project}-api")
    .WithReference(blobs)
    .WithReference(tables)
    .WithReference(cosmos);
```

## Store-Specific Guidance

Load only the file(s) for the store(s) this scaffold uses - each builds on the common shape above:

- [azure-blob-storage.md](azure-blob-storage.md) - Blob: large/binary content, SAS, streaming upload/download.
- [azure-table-storage.md](azure-table-storage.md) - Table: partition/row key design, cheap key-value lookups.
- [azure-cosmos.md](azure-cosmos.md) - Cosmos DB: document aggregates, partition strategy, read-model projections.
