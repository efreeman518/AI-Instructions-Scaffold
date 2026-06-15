````markdown
# AI Integration

Use this only when the current slice actually needs semantic retrieval, grounded Q&A, or bounded tool-driven automation. Default to search first, agent second, workflows or hosted agents last.

## Prerequisites

- [solution-structure.md](solution-structure.md)
- [bootstrapper.md](bootstrapper.md)
- [configuration-secrets.md](configuration-secrets.md)
- [identity-management.md](identity-management.md) (agents need auth context)
- [package-dependencies.md](package-dependencies.md)

### Local Runtime Prerequisites

For a real local AI run through Aspire, verify the substrate before debugging application code:

```powershell
dotnet --version
docker info                 # or podman info
aspire --version            # install: dotnet tool install -g Aspire.Cli
foundry --version           # install: winget install Microsoft.FoundryLocal
foundry service status
foundry model info qwen2.5-0.5b
foundry model download qwen2.5-0.5b
func --version              # optional Functions run: npm i -g azure-functions-core-tools@4 --unsafe-perm true
```

Notes:

- `foundry model list` can log catalog-processing errors on some Foundry Local versions even when explicit model lookup works. Treat `foundry model info <alias>` plus `foundry service status` as the pragmatic verification path.
- Use a local model whose task list includes `tools` when any `ChatClientAgent` or FlowEngine agent node will call functions. In Foundry Local `0.8.119`, `phi-4` is `chat` only; `qwen2.5-0.5b` is small and supports `chat, tools`.
- Pre-download the selected local model before the AppHost run when possible so app startup is not confused with model download latency.
- Fully local model run: set an app-specific opt-in variable such as `$env:MYAPP_ENABLE_FOUNDRY_LOCAL = "true"`, then run `dotnet run --project src/Host/Aspire/AppHost`. The AppHost should call `RunAsFoundryLocal()` only when that variable is set.
- Real Azure Foundry run: set `AiServices:FoundryEndpoint` in AppHost user secrets/config or set an app-specific override such as `$env:MYAPP_USE_AZURE_FOUNDRY = "true"`. `aspire publish` should always select the real Azure Foundry path.
- Add the AppHost SQL password secret before launch when the AppHost has a secret `sql-password` parameter:
  ```powershell
  dotnet user-secrets init --project src/Host/Aspire/AppHost
  dotnet user-secrets set "Parameters:sql-password" "<StrongPassword>" --project src/Host/Aspire/AppHost
  ```

## Non-Negotiables

1. All AI services behind interfaces - testable, swappable.
2. Embedding generation is infrastructure, not domain.
3. Agent function tools delegate to existing `I{Entity}Service` application services - no domain logic in tools.
4. Search indexes are projections, not source of truth.
5. Use `DefaultAzureCredential` for Foundry/Search auth (no API keys in code). In production, prefer `ManagedIdentityCredential`.
6. Configuration-driven model selection (appsettings, not hardcoded deployment names).
7. Use **Microsoft Agent Framework** (`Microsoft.Agents.AI`) - the successor to Semantic Kernel and AutoGen. Do not scaffold with Semantic Kernel or AutoGen packages.
8. Agent sessions (`AgentSession`) must be scoped per user/conversation - never share sessions across tenants.
9. Start with one agent and a small tool set. Do not scaffold multi-agent orchestration until a single-agent path is proven insufficient.
10. System prompts live in files, not inline string literals spread through services.
11. **Read DTO source files before writing any property access against them.** Response/DTO types may not expose the properties you assume. Writing against an assumed shape (e.g., `snapshot.PreferredLanguage` on a type that has no such property) produces `CS1061` compile errors. Always call `read_file` on the DTO before generating tool wrapper code or snapshot records.
12. **Read the target class constructor before injecting new dependencies into scaffold agents or tool classes.** Generated constructors may differ from what session notes describe. Reading the actual constructor first avoids duplicate-parameter or mismatched-arity compile errors.
13. **Scaffold mode is the default.** AI Search is `deployment-only` (no local emulator). Foundry models have a local path: `AddFoundry(...).RunAsFoundryLocal()` runs a model on-device via Foundry Local, so chat, streaming, and code-hosted agents work with no Azure subscription (Foundry *Projects* and Foundry-*hosted* agents still require Azure). When no model and no Foundry Local are wired, AI services must register as no-op stubs (including a no-op `IChatClient`) so the app boots without cloud credentials. A live model is wired only when a Foundry deployment is referenced; record any remaining Azure-only dependency (Search, Foundry Agent Service) in `HANDOFF.md`.
14. **Function-tool schemas must be provider-compatible.** Avoid nullable optional tool parameters such as `string? status = null` when targeting Azure AI Inference / Foundry Local. `AIFunctionFactory` can emit JSON Schema union types like `["string","null"]`, and some inference endpoints reject them. Prefer non-null optional strings with empty defaults (`string status = ""`) or explicit DTOs with provider-safe schema.

---

## Pragmatic Defaults

1. **Search-only first** when the requirement is findability, retrieval, or grounded Q&A over existing data.
2. **Single agent second** when the model must choose among a few application-service tools.
3. **Workflows last** when the process is durable, branching, resumable, or needs explicit approvals/checkpoints.
4. **Foundry Agent Service only when justified** by hosted memory, centralized tool catalogs, or operational requirements that a code-hosted agent cannot meet.
5. **Keyword or semantic search before vector or hybrid**. Add embeddings only when search quality testing shows a clear gap.
6. **Do not scaffold empty AI folders**. Add only the Search, Agents, and Workflows folders that are enabled.

## Decision Order

- **Need retrieval over business data?** Start with Azure AI Search.
- **Need the model to call internal business operations?** Add one `ChatClientAgent` with a few function tools that delegate to existing application services.
- **Need long-running or branching AI processes?** Add `Microsoft.Agents.Workflows`.
- **Need hosted memory or Foundry-managed tools?** Add Foundry Agent Service after the simpler code-hosted path is proven insufficient.

## Technology Choices

- **Foundry Models / Azure OpenAI client:** default model host for completions, embeddings, and tool-calling.
- **Azure AI Search:** default retrieval tier.
- **Microsoft Agent Framework:** default code-side agent SDK.
- **Foundry Agent Service:** optional hosted agent backend.
- **Agent Framework Workflows:** optional explicit orchestration layer.

Useful primitives:
- `ChatClientAgent` (`Microsoft.Agents.AI`) for the default single-agent path
- `AIFunctionFactory.Create()` (`Microsoft.Extensions.AI`) for application-service tools
- `AsAIAgent()` (`OpenAI.Chat` extension in `Microsoft.Agents.AI.OpenAI` package) to create a `ChatClientAgent` from a `ChatClient`
- `AgentSession` for per-conversation state
- `Microsoft.Agents.Workflows` for explicit orchestration only when needed

---

## Packages

- Baseline for any AI capability (Aspire Foundry path):
    - `Aspire.Hosting.Foundry` (AppHost) - preview-only, pin with reason
    - `Aspire.Azure.AI.Inference` (host project) - preview-only, pin with reason; provides the `IChatClient`
    - `Microsoft.Extensions.AI` - `IChatClient`, `AIFunctionFactory`
    - `Microsoft.Agents.AI` - `ChatClientAgent`
    - `Azure.Identity` - managed identity for real Azure
- Add only when enabled:
    - `Azure.Search.Documents` + `Aspire.Hosting.Azure.Search` for search
    - `Azure.AI.OpenAI` only if a component needs the Azure OpenAI client directly (embeddings, a FlowEngine Azure-OpenAI connector)
    - `Azure.AI.Agents.Persistent` for Foundry Agent Service
    - `Microsoft.Agents.Workflows` for workflow orchestration

Version all packages in `Directory.Packages.props`. The two preview-only Aspire packages above carry no stable release; pin them with a one-line inline reason (the version-pinning exception).

---

## Project Structure

Generate only the folders used by the enabled feature set.

```
src/Infrastructure/{Project}.Infrastructure.AI/
|-- {Project}.Infrastructure.AI.csproj
|-- Search/                                   # Only if useSearch: true
|   |-- I{Project}SearchService.cs
|   |-- {Project}SearchService.cs
|   |-- {Entity}SearchIndexDefinition.cs
|   `-- {Entity}VectorizationHandler.cs
|-- Agents/                                   # Only if useAgents: true
|   |-- I{Agent}Agent.cs
|   |-- {Agent}AgentService.cs
|   |-- Tools/
|   |   `-- {Tool}Tool.cs
|   |-- Middleware/
|   `-- Prompts/
|-- Workflows/                                 # Only if workflow.enabled: true
|-- {Project}AiSettings.cs
`-- ServiceCollectionExtensions.cs
```

---

## Agent Patterns

### Simple Agent (ChatClientAgent)

This is the default agent pattern. Wrap an Azure OpenAI / Foundry model with a small number of function tools that delegate to existing application services.

```csharp
public sealed class SupportTriageAgentService : ISupportTriageAgent
{
    private readonly ChatClientAgent _agent;

    public SupportTriageAgentService(
        IChatClient chatClient,
        ITicketService ticketService)
    {
        // Load system prompt from embedded resource
        var assembly = Assembly.GetExecutingAssembly();
        var resourceName = assembly.GetManifestResourceNames()
            .First(n => n.EndsWith("SupportTriageAgent.system-prompt.txt"));
        using var stream = assembly.GetManifestResourceStream(resourceName)!;
        using var reader = new StreamReader(stream);
        var systemPrompt = reader.ReadToEnd();

        _agent = new ChatClientAgent(
            chatClient,
            instructions: systemPrompt,
            name: "SupportTriageAgent",
            tools:
            [
                AIFunctionFactory.Create(  // Microsoft.Extensions.AI
                    (string ticketId) =>
                        ticketService.GetTicketHistoryAsync(ticketId, CancellationToken.None),
                    "GetTicketHistory",
                    "Get the history of a support ticket")
            ]);
    }

    public async Task<AgentChatResponse> TriageAsync(string userMessage, AgentSession? session = null, CancellationToken ct = default)
    {
        session ??= await _agent.CreateSessionAsync();
        var response = await _agent.RunAsync(userMessage, session, cancellationToken: ct);
        return new AgentChatResponse { Message = response.ToString() };
    }
}
```

### Escalate Only When Needed

- **Middleware:** add only after the core run path works and there is a concrete need for logging, redaction, authorization, or safety interception.
- **Agent-as-tool composition:** add only when one agent owns a distinct bounded capability that should stay isolated from the outer agent.
- **Foundry Agent Service:** use only when server-side memory, hosted tools, or centralized management are real requirements.
- **Workflows:** use only for branching, resumable, or human-in-the-loop flows. Do not introduce workflows for a single linear task.

If you add one of these escalations, keep the first pass narrow: one middleware policy, one subordinate agent, or one workflow path.

---

## Search Patterns

### Search Rollout Order

1. Start with keyword or semantic search.
2. Add vector search only if search-quality testing shows that lexical or semantic ranking is inadequate.
3. Add hybrid search only after both lexical and vector behavior are individually understood.

### Azure AI Search Client

```csharp
public class ProjectSearchService : IProjectSearchService
{
    private readonly SearchClient _searchClient;

    public async Task<IReadOnlyList<SearchResult<SearchDocument>>> SearchAsync(
        string query, SearchMode mode, CancellationToken ct)
    {
        SearchOptions options = mode switch
        {
            SearchMode.Keyword => new() { QueryType = SearchQueryType.Simple },
            SearchMode.Semantic => new()
            {
                QueryType = SearchQueryType.Semantic,
                SemanticSearch = new() { SemanticConfigurationName = "default" }
            },
            SearchMode.Vector => new()
            {
                VectorSearch = new()
                {
                    Queries = { new VectorizableTextQuery(query) { KNearestNeighborsCount = 5, Fields = { "DescriptionVector" } } }
                }
            },
            SearchMode.Hybrid => new()
            {
                QueryType = SearchQueryType.Semantic,
                SemanticSearch = new() { SemanticConfigurationName = "default" },
                VectorSearch = new()
                {
                    Queries = { new VectorizableTextQuery(query) { KNearestNeighborsCount = 5, Fields = { "DescriptionVector" } } }
                }
            },
            _ => throw new ArgumentOutOfRangeException(nameof(mode))
        };

        var response = await _searchClient.SearchAsync<SearchDocument>(query, options, ct);
        return [.. response.Value.GetResults()];
    }
}
```

### Vectorization Pipeline

#### On-Write (Domain Event Handler)

- Use an event handler only when search freshness matters enough to justify write-path work.
- Index only projection fields plus the vector field. Always keep the primary entity ID in the document.
- Call a dedicated embedding service abstraction from the handler or job. Do not generate embeddings in domain code.

#### Batch (Function App / Scheduler)

Use when vectorizing large existing datasets or when eventual consistency is acceptable. Prefer batch backfill first when introducing embeddings to an existing system.

---

## DI Registration

AI services use conditional registration - absent config -> no-op stubs registered, app boots without cloud credentials.

```csharp
public static class AiServiceCollectionExtensions
{
    public static IServiceCollection AddAiServices(this IServiceCollection services, IConfiguration config)
    {
        var aiSection = config.GetSection(AiSettings.ConfigSectionName);
        services.AddOptions<AiSettings>()
            .Bind(aiSection)
            .ValidateDataAnnotations()
            .ValidateOnStart();

        var settings = aiSection.Get<AiSettings>() ?? new AiSettings();

        // The model client (IChatClient) is registered at the HOST via Aspire (see Aspire section).
        // Its presence - not raw config - gates live AI here.
        var hasChatClient = services.Any(d => d.ServiceType == typeof(IChatClient));

        // Azure AI Search (if configured) - Search has no local emulator (deployment-only).
        if (settings.UseSearch && !string.IsNullOrWhiteSpace(settings.SearchEndpoint))
        {
            services.AddSingleton(new SearchClient(
                new Uri(settings.SearchEndpoint),
                settings.SearchIndexName,
                new DefaultAzureCredential()));

            services.AddScoped<IProjectSearchService, ProjectSearchService>();
        }
        else if (settings.UseSearch)
        {
            // TODO: [CONFIGURE] AI Search endpoint - set AiServices:SearchEndpoint for live search
            services.AddScoped<IProjectSearchService, NoOpSearchService>();
        }

        // Agent services - once the agent feature exists, live behavior follows IChatClient presence.
        // Without a model, keep the no-op stub so local scaffold runs still boot.
        if (hasChatClient)
            services.AddScoped<ISupportTriageAgent, SupportTriageAgentService>();
        else
            services.AddScoped<ISupportTriageAgent, NoOpSupportTriageAgent>();

        // IChatClient fallback so AI endpoints/consumers resolve and the app boots offline.
        if (!hasChatClient)
            services.AddSingleton<IChatClient, NoOpChatClient>();

        return services;
    }
}
```

No-op stubs return empty results or a `Result.Failure("AI service not configured")` and log a warning; they do not throw on DI resolution.

---

## Configuration (appsettings)

```json
{
  "AiServices": {
    "UseSearch": true,
    "UseAgents": false,
    "UseVectorSearch": false,
    "UseFoundryAgentService": false,
    "FoundryEndpoint": "https://ai-foundry-{resource}.services.ai.azure.com/",
    "AgentModelDeployment": "gpt-4o-deploy",
    "EmbeddingModelDeployment": "embedding-deploy",
    "SearchEndpoint": "https://{search-resource}.search.windows.net",
    "SearchIndexName": "products-index",
    "FoundryAgentServiceEndpoint": ""
  }
}
```

> **Stub rule:** Generate all AI settings with `// TODO: [CONFIGURE]` comments. Use empty strings for endpoints - never hardcode real URLs.

---

## Aspire Integration (Azure AI Foundry)

Only wire AI resources through Aspire if the solution already uses an AppHost. Do not introduce Aspire solely for AI.

Use the Foundry hosting integration (`Aspire.Hosting.Foundry`) so the same model graph runs locally on Foundry Local and provisions Azure on publish. This package and the Inference client (`Aspire.Azure.AI.Inference`) are preview-only - pin them with an inline reason in `Directory.Packages.props` (the version-pinning exception). The deployment resource name (`"chat"` below) is the connection name consumers bind to.

Recommended modes:

| Mode | AppHost condition | Result |
|---|---|---|
| Foundry Local | app-specific env var, e.g. `MYAPP_ENABLE_FOUNDRY_LOCAL=true`, and no Azure mode selected | Runs local model with `RunAsFoundryLocal()`; no Azure subscription needed. |
| Real Azure AI Foundry | publish mode, `AiServices:FoundryEndpoint`, or app-specific env var, e.g. `MYAPP_USE_AZURE_FOUNDRY=true` | Provisions or connects to an Azure Foundry deployment. |
| Disabled | neither local nor Azure mode selected | No `chat` resource is wired; app registers no-op AI services. |

```csharp
// AppHost. Publish (or configured real endpoint/override) -> Azure deployment;
// otherwise explicit Foundry Local; otherwise no model.
IResourceBuilder<FoundryDeploymentResource>? chat = null;
var azureConfigured = builder.ExecutionContext.IsPublishMode
    || !string.IsNullOrWhiteSpace(builder.Configuration["AiServices:FoundryEndpoint"])
    || Environment.GetEnvironmentVariable("MYAPP_USE_AZURE_FOUNDRY") == "true";
var foundryLocalEnabled =
    Environment.GetEnvironmentVariable("MYAPP_ENABLE_FOUNDRY_LOCAL") == "true";

if (azureConfigured)
{
    chat = builder.AddFoundry("foundry").AddDeployment("chat", FoundryModel.OpenAI.Gpt4oMini);
}
else if (foundryLocalEnabled)
{
    chat = builder.AddFoundry("foundry").RunAsFoundryLocal()
        .AddDeployment("chat", FoundryModel.Local.Qwen2505b); // tool-capable local model
}

var api = builder.AddProject<Projects.MyApp_Api>("api");
if (chat is not null) api = api.WithReference(chat); // injects ConnectionStrings:chat and CHAT_* env values
```

Register the client at the **host** (`IHostApplicationBuilder`, not the `IServiceCollection` AI extension). The `connectionName` must equal the deployment resource name:

```csharp
// Program.cs - run only when the AppHost wired a "chat" reference; else AddAiServices adds a no-op.
if (!string.IsNullOrWhiteSpace(builder.Configuration.GetConnectionString("chat")))
    builder.AddAzureChatCompletionsClient("chat").AddChatClient(); // registers Microsoft.Extensions.AI.IChatClient
```

`AddAiServices` then gates live AI on **IChatClient presence** (not raw config) and registers a no-op `IChatClient` when none was wired, so demos/endpoints resolve and the app boots offline:

```csharp
var hasChatClient = services.Any(d => d.ServiceType == typeof(IChatClient));
if (hasChatClient)
    services.AddScoped<IAssistantAgent, AssistantAgentService>();
else
    services.AddScoped<IAssistantAgent, NoOpAssistantAgent>();
if (!hasChatClient)
    services.AddSingleton<IChatClient, NoOpChatClient>();
```

Build agents as a `ChatClientAgent` over the injected `IChatClient` (Microsoft Agent Framework), not over an `AzureOpenAIClient`. Keep an `AzureOpenAIClient` registration only if a component needs it directly (e.g. a FlowEngine Azure-OpenAI connector or embedding generation) - it is independent of the `IChatClient` chat/agent path.

```csharp
_agent = new ChatClientAgent(chatClient, instructions: systemPrompt, name: "Assistant", tools: [ /* AIFunctionFactory.Create(...) */ ]);
```

For embeddings or AI Search, add `builder.AddAzureSearch("search")` and reference it the same way; Search has no local emulator, so it stays `deployment-only` with a no-op stub.

Copy-paste configuration examples:

```powershell
# Fully local model run
$env:MYAPP_ENABLE_FOUNDRY_LOCAL = "true"
dotnet run --project src/Host/Aspire/AppHost

# Real Azure Foundry local run
dotnet user-secrets set "AiServices:FoundryEndpoint" "https://<your-foundry-resource>.services.ai.azure.com/" --project src/Host/Aspire/AppHost
dotnet run --project src/Host/Aspire/AppHost
```

If the target Azure environment requires keyless managed-identity inference instead of the generated connection secret, update the host-side `AddAzureChatCompletionsClient("chat")` registration to use the required credential overload. Do that before classifying failures as model or prompt failures.

---

## Inference Use-Case Taxonomy

When a slice needs inference, pick the pattern by concept and avoid building several that overlap:

- **Basic completion** - prompt to text via `IChatClient.GetResponseAsync`.
- **Streaming completion** - token UX via `IChatClient.GetStreamingResponseAsync` over Server-Sent Events.
- **Conversational tool-calling agent** - multi-turn `ChatClientAgent` with function tools that delegate to application services.
- **Structured-output decisioning** - prompt for JSON, parse a typed result that drives a deterministic branch (classification/triage).
- **Inline enrichment in a write** - one inference step inside an application command (e.g. draft fields before persisting).
- **Asynchronous event-driven inference** - reason in a background/event handler off a domain event, with the side effect on a different surface.
- **Read-only multi-tool reasoning** - an agent composes read-only tools to recommend, with no persistence.
- **Orchestrated workflow** - a durable workflow engine runs an agent node as one step of a branching, resumable process.

The first three are foundational; the rest embed inference inside application use cases. Start narrow and add a pattern only when the concept is genuinely new.

---

## Testing

Cover the smallest useful surface first:

1. Search service returns expected fields and ordering for the selected search mode.
2. Agent tools call the intended application services and do not bypass business rules.
3. Prompt loading works from file-based system prompts.
4. Disabled AI features do not register or resolve their services.

### Agent Tests

```csharp
// ChatClientAgent requires IChatClient - use a mock or test double
// For function tool tests, test tools directly (they're plain C# methods)
var tools = new TaskItemTools(NullLogger<TaskItemTools>.Instance, mockService.Object, mockSearch.Object);
var result = await tools.SearchTasks("overdue");
Assert.IsTrue(result.Contains("expected text"));
```

### Search Tests

Mock `SearchClient` or use an integration test against a real test index. Verify index schema and field names match the projected entity shape.

### Function Tool Tests

Test function tools independently - they are plain C# methods that wrap domain services. Use standard unit test patterns with mocked `I{Entity}Service`.

---

## References

- [Microsoft Foundry](https://learn.microsoft.com/en-us/azure/ai-foundry/what-is-foundry)
- [Agent Framework Overview](https://learn.microsoft.com/en-us/agent-framework/overview/)
- [Agent Framework - Workflows](https://learn.microsoft.com/en-us/agent-framework/workflows/)
- [Azure AI Search - .NET SDK](https://learn.microsoft.com/en-us/azure/search/search-howto-dotnet-sdk)
````
