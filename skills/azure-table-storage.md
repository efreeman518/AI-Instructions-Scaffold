# Azure Table Storage (EF.Table)

> **Shared shape** (settings class, repository wrapper, DI registration, Aspire integration, local inspection tools) lives in [azure-data-storage.md](azure-data-storage.md). This file covers Table-specific guidance only.

### Purpose

Use Table Storage for low-cost, high-volume key-value access where queries are primarily `PartitionKey + RowKey` driven.

### Non-Negotiables

1. Entities must implement `Azure.Data.Tables.ITableEntity`.
2. `PartitionKey` design follows dominant query shape.
3. `RowKey` is unique within partition and supports required ordering.
4. Access data through repository abstractions (`ITableRepository` wrappers).
5. Use named `TableServiceClient` registration via `IAzureClientFactory`.
6. For timeline/audit streams, define retention, archival, and replay expectations explicitly.

### Entity Pattern

```csharp
public class {Entity}TableEntity : Azure.Data.Tables.ITableEntity
{
    public string PartitionKey { get; set; } = null!;
    public string RowKey { get; set; } = null!;
    public DateTimeOffset? Timestamp { get; set; }
    public ETag ETag { get; set; }

    public string Name { get; set; } = null!;
    public string Status { get; set; } = "Active";
    public DateTime CreatedUtc { get; set; } = DateTime.UtcNow;
}
```

### Key Strategy Guidance

| Strategy | PartitionKey | RowKey | Typical Use |
|---|---|---|---|
| Tenant + Id | `TenantId` | `EntityId` | tenant-scoped lookups |
| Type + inverse time | `"AuditLog"` | `{InverseTicks}_{Guid}` | recent-first event streams |
| Category + key | `Category` | `ItemKey` | lookup/config tables |
| Composite | `{TenantId}:{Year}` | `{EntityId}` | tenant + time partitioning |

Use inverse ticks for newest-first ordering:

```csharp
var rowKey = $"{DateTime.MaxValue.Ticks - DateTime.UtcNow.Ticks:D19}_{Guid.NewGuid()}";
```

### Repository Contract

`ITableRepository` supports:

- point operations (`GetItemAsync`, `CreateItemAsync`, `UpsertItemAsync`, `UpdateItemAsync`, `DeleteItemAsync`),
- pagination (`QueryPageAsync` with LINQ/OData filters),
- streaming (`GetStream<T>()`),
- table lifecycle (`GetOrCreateTableAsync`, `DeleteTableAsync`).

### Project Repository Wrapper

```csharp
public interface I{Project}TableRepository : ITableRepository { }

public class {Project}TableRepository : TableRepositoryBase, I{Project}TableRepository
{
    public {Project}TableRepository(
        ILogger<{Project}TableRepository> logger,
        IOptions<{Project}TableRepositorySettings> settings,
        IAzureClientFactory<TableServiceClient> clientFactory)
        : base(logger, settings, clientFactory) { }
}

public class {Project}TableRepositorySettings : TableRepositorySettingsBase { }
```

`TableRepositorySettingsBase` requires `TableServiceClientName`.

`TableUpdateMode` usage:

- `Merge` for partial updates,
- `Replace` for full entity overwrite.

### Configuration

`appsettings.json`

```json
{
  "ConnectionStrings": {
    "TableStorage1": ""
  },
  "{Project}TableRepositorySettings": {
    "TableServiceClientName": "{Project}TableClient"
  }
}
```

`appsettings.Development.json`

```json
{
  "ConnectionStrings": {
    "TableStorage1": "UseDevelopmentStorage=true"
  }
}
```

### DI Registration

```csharp
private static void AddTableStorageServices(IServiceCollection services, IConfiguration config)
{
    services.AddAzureClients(builder =>
    {
        builder.AddTableServiceClient(config.GetConnectionString("TableStorage1")!)
            .WithName("{Project}TableClient");
    });

    services.Configure<{Project}TableRepositorySettings>(
        config.GetSection("{Project}TableRepositorySettings"));

    services.AddScoped<I{Project}TableRepository, {Project}TableRepository>();
}
```

### Usage Patterns

- **Audit/event log:** append records with inverse-tick `RowKey`.
- **Lookup/config store:** `PartitionKey=category`, `RowKey=setting-key`.
- **Large scans:** prefer continuation-token pagination or streaming APIs.

If table entities participate in mixed-store workflows, include reconciliation checks against the authoritative source.

Avoid relationship-heavy data models; denormalize where necessary.

## Verification

- [ ] Entity implements `ITableEntity` (`PartitionKey`, `RowKey`, `Timestamp`, `ETag`)
- [ ] `PartitionKey` and `RowKey` match access/query patterns
- [ ] Repository derives from `TableRepositoryBase`
- [ ] Settings derive from `TableRepositorySettingsBase`
- [ ] Named `TableServiceClient` registration is present
- [ ] Local dev uses `UseDevelopmentStorage=true` (Azurite)
- [ ] Pagination/streaming path is used for non-trivial scans
- [ ] Resource naming matches Aspire/IaC storage configuration
