# AI Search Template

Use this when the slice needs retrieval over existing data. Start with keyword or semantic search. Add vectorization only after search-quality testing shows a clear gap.

## Default Shape

- One search service
- One projection document
- One result model
- One upsert path from domain events or a batch job
- Index setup only for the fields you actually query

## Search Service Interface

```csharp
namespace {Org}.{Project}.Infrastructure.AI.Search;

public interface I{Project}SearchService
{
    Task<IReadOnlyList<{Entity}SearchResult>> SearchAsync(
        string query, SearchMode mode = SearchMode.Semantic, CancellationToken ct = default);

    Task UpsertAsync({Entity}SearchDocument document, CancellationToken ct = default);

    Task DeleteAsync(string documentId, CancellationToken ct = default);
}

public enum SearchMode
{
    Keyword,
    Semantic,
    Vector,
    Hybrid
}
```

If you are not using embeddings yet, keep usage to `Keyword` and `Semantic` only.

## Search Document Model

```csharp
namespace {Org}.{Project}.Infrastructure.AI.Search;

using Azure.Search.Documents.Indexes;
using Azure.Search.Documents.Indexes.Models;

public class {Entity}SearchDocument
{
    [SimpleField(IsKey = true, IsFilterable = true)]
    public string Id { get; set; } = null!;

    [SearchableField(AnalyzerName = LexicalAnalyzerName.Values.StandardLucene)]
    public string {Property1} { get; set; } = null!;

    [SearchableField(AnalyzerName = LexicalAnalyzerName.Values.StandardLucene)]
    public string {Property2} { get; set; } = null!;

    [SimpleField(IsFilterable = true, IsSortable = true)]
    public DateTimeOffset? LastModified { get; set; }

    [SimpleField(IsFilterable = true)]
    public string? TenantId { get; set; }

    // Add only when embeddings are enabled.
    [VectorSearchField(
        VectorSearchDimensions = 1536,
        VectorSearchProfileName = "default-vector-profile")]
    public ReadOnlyMemory<float>? {Property2}Vector { get; set; }
}
```

## Search Result Model

```csharp
namespace {Org}.{Project}.Infrastructure.AI.Search;

public class {Entity}SearchResult
{
    public string Id { get; set; } = null!;
    public string {Property1} { get; set; } = null!;
    public string {Property2} { get; set; } = null!;
    public double Score { get; set; }
    public double? RerankerScore { get; set; }
}
```

## Default Search Service

```csharp
namespace {Org}.{Project}.Infrastructure.AI.Search;

using Azure.Search.Documents;
using Azure.Search.Documents.Models;

internal sealed class {Project}SearchService : I{Project}SearchService
{
    private readonly SearchClient _searchClient;

    public {Project}SearchService(SearchClient searchClient)
    {
        _searchClient = searchClient;
    }

    public async Task<IReadOnlyList<{Entity}SearchResult>> SearchAsync(
        string query, SearchMode mode = SearchMode.Semantic, CancellationToken ct = default)
    {
        var options = BuildSearchOptions(mode, query);
        var response = await _searchClient.SearchAsync<{Entity}SearchDocument>(query, options, ct);

        var results = new List<{Entity}SearchResult>();
        await foreach (var result in response.Value.GetResultsAsync())
        {
            results.Add(new {Entity}SearchResult
            {
                Id = result.Document.Id,
                {Property1} = result.Document.{Property1},
                {Property2} = result.Document.{Property2},
                Score = result.Score ?? 0,
                RerankerScore = result.SemanticSearch?.RerankerScore
            });
        }

        return results;
    }

    public Task UpsertAsync({Entity}SearchDocument document, CancellationToken ct = default)
    {
        return _searchClient.MergeOrUploadDocumentsAsync([document], cancellationToken: ct);
    }

    public Task DeleteAsync(string documentId, CancellationToken ct = default)
    {
        return _searchClient.DeleteDocumentsAsync("Id", [documentId], cancellationToken: ct);
    }

    private static SearchOptions BuildSearchOptions(SearchMode mode, string query)
    {
        return mode switch
        {
            SearchMode.Keyword => new SearchOptions
            {
                QueryType = SearchQueryType.Simple,
                Size = 10
            },
            SearchMode.Semantic => new SearchOptions
            {
                QueryType = SearchQueryType.Semantic,
                SemanticSearch = new() { SemanticConfigurationName = "default" },
                Size = 10
            },
            SearchMode.Vector => new SearchOptions
            {
                VectorSearch = new()
                {
                    Queries =
                    {
                        new VectorizableTextQuery(query)
                        {
                            KNearestNeighborsCount = 5,
                            Fields = { "{Property2}Vector" }
                        }
                    }
                },
                Size = 10
            },
            SearchMode.Hybrid => new SearchOptions
            {
                QueryType = SearchQueryType.Semantic,
                SemanticSearch = new() { SemanticConfigurationName = "default" },
                VectorSearch = new()
                {
                    Queries =
                    {
                        new VectorizableTextQuery(query)
                        {
                            KNearestNeighborsCount = 5,
                            Fields = { "{Property2}Vector" }
                        }
                    }
                },
                Size = 10
            },
            _ => throw new ArgumentOutOfRangeException(nameof(mode))
        };
    }
}
```

## Add Vectorization Only If Needed

If embeddings are justified, add a projection updater that calls an embedding client and upserts the search document.

```csharp
internal sealed class {Entity}VectorizationHandler : IMessageHandler<{Entity}CreatedEvent>
{
    public async Task HandleAsync({Entity}CreatedEvent evt, CancellationToken ct)
    {
        var textToEmbed = $"{evt.{Property1}} {evt.{Property2}}";
        var embedding = await _embeddingClient.GenerateEmbeddingAsync(textToEmbed, cancellationToken: ct);

        await _searchService.UpsertAsync(new {Entity}SearchDocument
        {
            Id = evt.{Entity}Id.ToString(),
            {Property1} = evt.{Property1},
            {Property2} = evt.{Property2},
            {Property2}Vector = embedding.Value.ToFloats(),
            LastModified = DateTimeOffset.UtcNow,
            TenantId = evt.TenantId?.ToString()
        }, ct);
    }
}
```

Use a batch backfill instead of an on-write handler when eventual consistency is acceptable.

## Relevant Settings

```csharp
namespace {Org}.{Project}.Infrastructure.AI;

public class AiSettings
{
    public const string ConfigSectionName = "AiServices";

    public string SearchEndpoint { get; set; } = null!;
    public string SearchIndexName { get; set; } = null!;
    public string EmbeddingModelDeployment { get; set; } = ""; // only when embeddings are enabled
}
```

## Index Setup

Create only the fields you query. Add vector search configuration only when the document includes vector fields.

```csharp
var index = new SearchIndex("{entity}-index")
{
    Fields = new FieldBuilder().Build(typeof({Entity}SearchDocument)),
    SemanticSearch = new()
    {
        Configurations =
        {
            new SemanticConfiguration("default", new()
            {
                TitleField = new SemanticField("{Property1}"),
                ContentFields = { new SemanticField("{Property2}") }
            })
        }
    }
};

await indexClient.CreateOrUpdateIndexAsync(index);
```

When index naming is provided by resource mapping, use `{SearchIndex}` as the index name token.
