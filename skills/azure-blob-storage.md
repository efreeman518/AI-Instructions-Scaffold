# Azure Blob Storage (EF.Blob)

> **Shared shape** (settings class, repository wrapper, DI registration, Aspire integration, local inspection tools) lives in [azure-data-storage.md](azure-data-storage.md). This file covers Blob-specific guidance only.

### Purpose

Use Blob Storage for unstructured payloads (documents, media, exports, backups). Keep relational/queryable data in SQL/Cosmos/Table as appropriate.

### Non-Negotiables

1. Access blobs through `IBlobRepository` abstraction.
2. Register storage with named `BlobServiceClient` via `IAzureClientFactory`.
3. Use scoped SAS permissions and short expiry windows.
4. Keep container access private unless explicitly required.
5. Dispose downloaded streams correctly.

### Repository Contract

```csharp
public interface IBlobRepository
{
    Task CreateContainerAsync(ContainerInfo containerInfo, CancellationToken cancellationToken = default);
    Task DeleteContainerAsync(ContainerInfo containerInfo, CancellationToken cancellationToken = default);

    Task<(IReadOnlyList<BlobItem>, string?)> QueryPageBlobsAsync(
        ContainerInfo containerInfo,
        string? continuationToken = null,
        BlobTraits blobTraits = BlobTraits.None,
        BlobStates blobStates = BlobStates.None,
        string? prefix = null,
        CancellationToken cancellationToken = default);

    Task<IAsyncEnumerable<BlobItem>> GetStreamBlobList(
        ContainerInfo containerInfo,
        BlobTraits blobTraits = BlobTraits.None,
        BlobStates blobStates = BlobStates.None,
        string? prefix = null,
        CancellationToken cancellationToken = default);

    Task<Uri?> GenerateBlobSasUriAsync(
        ContainerInfo containerInfo,
        string blobName,
        BlobSasPermissions permissions,
        DateTimeOffset expiresOn,
        SasIPRange? ipRange = null,
        CancellationToken cancellationToken = default);

    Task UploadBlobStreamAsync(
        ContainerInfo containerInfo,
        string blobName,
        Stream stream,
        string? contentType = null,
        bool encrypt = false,
        IDictionary<string, string>? metadata = null,
        CancellationToken cancellationToken = default);

    Task UploadBlobStreamAsync(
        Uri sasUri,
        Stream stream,
        string? contentType = null,
        bool encrypt = false,
        IDictionary<string, string>? metadata = null,
        CancellationToken cancellationToken = default);

    Task<Stream> StartDownloadBlobStreamAsync(
        ContainerInfo containerInfo,
        string blobName,
        bool decrypt = false,
        CancellationToken cancellationToken = default);

    Task<Stream> StartDownloadBlobStreamAsync(
        Uri sasUri,
        bool decrypt = false,
        CancellationToken cancellationToken = default);

    Task DeleteBlobAsync(ContainerInfo containerInfo, string blobName, CancellationToken cancellationToken = default);
    Task DeleteBlobAsync(Uri sasUri, CancellationToken cancellationToken = default);
}
```

Supporting types:

```csharp
public class ContainerInfo
{
    public string ContainerName { get; set; } = null!;
    public ContainerPublicAccessType ContainerPublicAccessType { get; set; } = ContainerPublicAccessType.None;
    public bool CreateContainerIfNotExist { get; set; } = true;
}

public enum ContainerPublicAccessType
{
    None = 0,
    BlobContainer = 1,
    Blob = 2
}
```

### Project Repository Wrapper

```csharp
public interface I{Project}BlobRepository : IBlobRepository { }

public class {Project}BlobRepository : BlobRepositoryBase, I{Project}BlobRepository
{
    public {Project}BlobRepository(
        ILogger<{Project}BlobRepository> logger,
        IOptions<{Project}BlobRepositorySettings> settings,
        IAzureClientFactory<BlobServiceClient> clientFactory)
        : base(logger, settings, clientFactory) { }
}

public class {Project}BlobRepositorySettings : BlobRepositorySettingsBase { }
```

`BlobRepositorySettingsBase` requires `BlobServiceClientName`.

**Override the base stubs.** `BlobRepositoryBase.Upload/Download/DeleteAsync` are `virtual` and throw `NotImplementedException` in the feed package. The project wrapper above only inherits them - calling `_blobRepo.UploadAsync(...)` at runtime crashes unless the wrapper overrides each method actually used. Implement against the injected `IAzureClientFactory<BlobServiceClient>`:

```csharp
public override async Task<Uri> UploadAsync(
    string containerName, string blobName, Stream content, string contentType,
    CancellationToken ct = default)
{
    var container = _clientFactory.CreateClient(_settings.BlobServiceClientName)
        .GetBlobContainerClient(containerName);
    await container.CreateIfNotExistsAsync(cancellationToken: ct);
    var blob = container.GetBlobClient(blobName);
    await blob.UploadAsync(
        content,
        new BlobHttpHeaders { ContentType = contentType },
        cancellationToken: ct);
    return blob.Uri;
}

public override async Task<Stream> DownloadAsync(
    string containerName, string blobName, CancellationToken ct = default)
{
    var blob = _clientFactory.CreateClient(_settings.BlobServiceClientName)
        .GetBlobContainerClient(containerName)
        .GetBlobClient(blobName);
    var response = await blob.DownloadStreamingAsync(cancellationToken: ct);
    return response.Value.Content;
}
```

**`BlobContainerClient.GetBlobsAsync` signature gotcha.** The current Azure SDK requires **positional** arguments: `GetBlobsAsync(BlobTraits.None, BlobStates.None, prefix, cancellationToken)`. The named-argument form `GetBlobsAsync(prefix: "...", cancellationToken: ct)` that older Microsoft samples show **does not compile** - the method exposes no parameters by those names. Use positional, or assign through the well-named overload of `BlobContainerClient`.

If overrides are deferred (no caller exists yet), keep the wrapper inheriting the throwing stubs and rely on the *scaffold-skipped surface* exception in [../support/final-scaffold-checklist.md](../support/final-scaffold-checklist.md). The moment a service or endpoint calls `UploadAsync`, the override is mandatory.

### Configuration

`appsettings.json`

```json
{
  "ConnectionStrings": {
    "BlobStorage1": ""
  },
  "{Project}BlobRepositorySettings": {
    "BlobServiceClientName": "{Project}BlobClient"
  }
}
```

`appsettings.Development.json`

```json
{
  "ConnectionStrings": {
    "BlobStorage1": "UseDevelopmentStorage=true"
  }
}
```

### DI Registration

```csharp
private static void AddBlobStorageServices(IServiceCollection services, IConfiguration config)
{
    services.AddAzureClients(builder =>
    {
        builder.AddBlobServiceClient(config.GetConnectionString("BlobStorage1")!)
            .WithName("{Project}BlobClient");
    });

    services.Configure<{Project}BlobRepositorySettings>(
        config.GetSection("{Project}BlobRepositorySettings"));

    services.AddScoped<I{Project}BlobRepository, {Project}BlobRepository>();
}
```

### Usage Patterns

- **Server upload/download/delete:** repository with `ContainerInfo`.
- **Client direct upload/download:** generate temporary SAS URI with minimal permissions.
- **Large listings:** continuation-token paging or stream enumeration.
- **Cross-instance lock:** blob lease/distributed lock execution where needed.

Blob naming patterns:

- `{tenantId}/{entityType}/{entityId}/{filename}`
- `{guid}/{filename}`
- `{yyyy}/{MM}/{dd}/{filename}`

## Verification

- [ ] Repository derives from `BlobRepositoryBase`
- [ ] Settings derive from `BlobRepositorySettingsBase`
- [ ] Named `BlobServiceClient` registration exists
- [ ] Container names/access levels are explicit
- [ ] SAS generation uses least privilege + short expiry
- [ ] Download stream lifecycle is correctly disposed
- [ ] Local dev uses `UseDevelopmentStorage=true` (Azurite)
- [ ] Storage connection naming aligns with Aspire/IaC
