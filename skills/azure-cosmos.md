# Azure Cosmos DB (EF.Cosmos)

> **Shared shape** (settings class, repository wrapper, DI registration, Aspire integration, local inspection tools) lives in [azure-data-storage.md](azure-data-storage.md). This file covers Cosmos DB-specific guidance only.

### Purpose

Use Cosmos DB for document-first aggregates (nested JSON, high-throughput partitioned access, globally distributed reads/writes). Keep relational workflows in SQL/EF Core when data requires joins, foreign keys, and cross-aggregate transaction boundaries.

### Non-Negotiables

1. Every Cosmos entity inherits `CosmosDbEntity` and overrides `PartitionKey`.
2. Partition key is chosen from dominant query patterns (not convenience).
3. Data access goes through `ICosmosDbRepository` abstraction.
4. DI wiring is centralized in Bootstrapper.
5. No EF entity configuration classes and no migrations for Cosmos entities.
6. For high-ingest entities, define throughput profile, TTL/retention, and replay window before implementation.

### Canonical Entity Pattern

```csharp
namespace {Project}.Domain.Model;

public class TodoItemDocument : CosmosDbEntity
{
    public override string PartitionKey => TenantId.ToString();

    public Guid TenantId { get; private set; }
    public string Title { get; private set; } = null!;
    public Schedule Schedule { get; private set; } = new();
    public List<ChecklistItem> ChecklistItems { get; private set; } = [];
    public Dictionary<string, string> Metadata { get; private set; } = [];

    public static DomainResult<TodoItemDocument> Create(Guid tenantId, string title)
    {
        if (string.IsNullOrWhiteSpace(title))
            return DomainResult<TodoItemDocument>.Failure("Title is required.");

        return DomainResult<TodoItemDocument>.Success(new TodoItemDocument
        {
            TenantId = tenantId,
            Title = title
        });
    }
}

public class Schedule
{
    public DateTimeOffset? StartDate { get; set; }
    public DateTimeOffset? DueDate { get; set; }
}

public class ChecklistItem
{
    public string Description { get; set; } = null!;
    public bool IsComplete { get; set; }
    public int SortOrder { get; set; }
}
```

### Embedded Model Guidance

- Use nested objects/arrays when children are always loaded and saved with the parent.
- Use dictionary metadata for sparse/variable attributes.
- If child records need independent querying/lifecycle, model them as separate documents or move to SQL.

### Partition Key Guidance

- Tenant-based (`TenantId.ToString()`) for tenant-scoped access.
- Category/group keys for high-volume grouped queries.
- Composite keys (`$"{TenantId}:{Region}"`) only when both dimensions are common filters.
- Avoid random keys that force cross-partition queries for normal reads.

### Operational Controls

- Throughput: document expected RU profile (`standard|high|burst`) and autoscale strategy.
- Lifecycle: define TTL/retention/archival expectations per container or entity family.
- Replay: define backfill/replay window and consistency expectations for out-of-order events.

### Repository Contract

```csharp
public interface ICosmosDbRepository
{
    Task<T> SaveItemAsync<T>(T item) where T : CosmosDbEntity;
    Task<T?> GetItemAsync<T>(string id, string partitionKey) where T : CosmosDbEntity;
    Task DeleteItemAsync<T>(string id, string partitionKey);
    Task DeleteItemAsync<T>(T item) where T : CosmosDbEntity;

    Task<(List<TProject>, int, string?)> QueryPageProjectionAsync<TSource, TProject>(
        string? continuationToken = null,
        int pageSize = 10,
        Expression<Func<TProject, bool>>? filter = null,
        List<Sort>? sorts = null,
        bool includeTotal = false,
        int maxConcurrency = -1,
        CancellationToken cancellationToken = default);

    Task<(List<TProject>, int, string?)> QueryPageProjectionAsync<TSource, TProject>(
        string? continuationToken = null,
        int pageSize = 10,
        string? sql = null,
        string? sqlCount = null,
        Dictionary<string, object>? parameters = null,
        int maxConcurrency = -1,
        CancellationToken cancellationToken = default);

    Task<Container> GetOrAddContainerAsync(string containerId, string? partitionKeyPath = null);
    Task<HttpStatusCode?> DeleteContainerAsync(string containerId, CancellationToken cancellationToken = default);
    Task<HttpStatusCode> SetOrCreateDatabaseAsync(string dbId, int? throughput = null, CancellationToken cancellationToken = default);
    Task<HttpStatusCode> DeleteDatabaseAsync(string? dbId = null, CancellationToken cancellationToken = default);
}
```

### Project Repository Wrapper

```csharp
namespace {Project}.Infrastructure.Repositories;

public interface I{Project}CosmosDbRepository : ICosmosDbRepository { }

public class {Project}CosmosDbRepository : CosmosDbRepositoryBase, I{Project}CosmosDbRepository
{
    public {Project}CosmosDbRepository(
        ILogger<{Project}CosmosDbRepository> logger,
        IOptions<{Project}CosmosDbRepositorySettings> settings)
        : base(logger, settings)
    {
    }
}

public class {Project}CosmosDbRepositorySettings : CosmosDbRepositorySettingsBase { }
```

### Configuration

`appsettings.json`

```json
{
  "ConnectionStrings": {
    "CosmosDb1": ""
  },
  "{Project}CosmosDbRepositorySettings": {
    "CosmosDbId": "{project}-db"
  }
}
```

`appsettings.Development.json`

```json
{
  "ConnectionStrings": {
    "CosmosDb1": "AccountEndpoint=https://localhost:8081/;AccountKey=<emulator-key>"
  }
}
```

For deployed environments, prefer managed identity / Key Vault.

### DI Registration

```csharp
private static void AddCosmosDbServices(IServiceCollection services, IConfiguration config)
{
    services.AddAzureClients(builder =>
    {
        builder.AddCosmosServiceClient(config.GetConnectionString("CosmosDb1")!)
            .WithName("{Project}CosmosClient");
    });

    services.Configure<{Project}CosmosDbRepositorySettings>(options =>
    {
        config.GetSection("{Project}CosmosDbRepositorySettings").Bind(options);
    });

    services.AddScoped<I{Project}CosmosDbRepository, {Project}CosmosDbRepository>();
}
```

Direct `CosmosClient` injection in settings is acceptable when `IAzureClientFactory` is not used.

### Service Usage Pattern

```csharp
public class TodoItemService(I{Project}CosmosDbRepository cosmosRepo, IRequestContext<string, Guid?> requestContext)
{
    public async Task<Result<TodoItemDocument>> GetAsync(Guid id, CancellationToken ct = default)
    {
        var tenantPk = requestContext.TenantId!.Value.ToString();
        var item = await cosmosRepo.GetItemAsync<TodoItemDocument>(id.ToString(), tenantPk);
        return item is null ? Result<TodoItemDocument>.None() : Result<TodoItemDocument>.Success(item);
    }
}
```

### Querying

- LINQ: `QueryPageProjectionAsync<TSource, TProject>(filter, sorts, includeTotal: true)` for type-safe pagination.
- SQL: overload with `sql`, `sqlCount`, and parameters for advanced queries.
- Large scans: use streaming APIs where available to avoid loading full datasets.

## Verification

- [ ] Entity inherits `CosmosDbEntity` and overrides `PartitionKey`
- [ ] Partition key aligns with dominant read/query path
- [ ] Repository derives from `CosmosDbRepositoryBase` and exposes `I{Project}CosmosDbRepository`
- [ ] Settings derive from `CosmosDbRepositorySettingsBase` and include `CosmosDbId`
- [ ] Bootstrapper registers Cosmos client + repository
- [ ] Service calls pass both `id` and `partitionKey`
- [ ] No EF migrations/config classes for Cosmos entities
- [ ] Cross-reference alignment with [domain-model.md](domain-model.md) and [application-layer.md](application-layer.md)
