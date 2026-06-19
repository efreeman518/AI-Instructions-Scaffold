# AI Integration

Use this only when the current slice actually needs semantic retrieval, grounded Q&A, or bounded tool-driven automation. Default to search first, agent second, workflows or hosted agents last.

## Prerequisites

- [solution-structure.md](solution-structure.md)
- [bootstrapper.md](bootstrapper.md)
- [configuration-secrets.md](configuration-secrets.md)
- [identity-management.md](identity-management.md) (agents need auth context)
- [package-dependencies.md](package-dependencies.md)

### Local Runtime Prerequisites

For a real local AI run, verify the substrate before debugging application code:

```powershell
dotnet --version
docker info                 # or podman info
aspire --version            # install: dotnet tool install -g Aspire.Cli
func --version              # optional Functions run: npm i -g azure-functions-core-tools@4 --unsafe-perm true
```

The current local path is the SDK-direct API-host workaround and needs **no Foundry CLI or runtime on `PATH`** - `Microsoft.AI.Foundry.Local` is self-contained and downloads its execution providers and the model alias (`qwen2.5-0.5b`) on first run. The `foundry` CLI checks below apply only to the **future** `RunAsFoundryLocal()` path (after the Aspire fix):

```powershell
foundry --version           # install: winget install Microsoft.FoundryLocal
foundry service status
foundry model info qwen2.5-0.5b
foundry model download qwen2.5-0.5b
```

Notes:

- `foundry model list` can log catalog-processing errors on some Foundry Local versions even when explicit model lookup works; treat `foundry model info <alias>` plus `foundry service status` as the pragmatic verification path (future `RunAsFoundryLocal()` path only).
- Use a local model whose task list includes `tools` when any `ChatClientAgent` or FlowEngine agent node will call functions. `qwen2.5-0.5b` is small and supports `chat, tools`; `phi-4` is `chat` only.
- The first SDK-direct run downloads the `qwen2.5-0.5b` alias; expect added latency on the first AppHost run (the SDK manages the download - no separate pre-download step).
- Fully local model run: set an app-specific opt-in variable such as `$env:MYAPP_ENABLE_FOUNDRY_LOCAL = "true"`, then run `dotnet run --project src/Host/Aspire/AppHost`. The **target** path is Aspire `RunAsFoundryLocal()`; while it is broken against GA Foundry Local (see *Aspire Integration* -> *Known issue*), the **temporary** local path is the SDK-direct API-host bootstrap - the AppHost wires no `chat` resource and only forwards that variable to the API host, which drives the `Microsoft.AI.Foundry.Local` SDK directly. See *SDK-direct API-host bootstrap (temporary workaround)*.
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
13. **Scaffold mode is the default.** AI Search is `deployment-only` (no local emulator). Foundry models have a local path: a model runs on-device via Foundry Local, so chat, streaming, and code-hosted agents work with no Azure subscription (Foundry *Projects* and Foundry-*hosted* agents still require Azure). The **target** local path is Aspire `RunAsFoundryLocal()`; while that is broken against GA Foundry Local (see *Aspire Integration* -> *Known issue*), the local path is the **temporary** SDK-direct API-host bootstrap. When no model and no Foundry Local are wired, AI services must register as no-op stubs (including a no-op `IChatClient`) so the app boots without cloud credentials. A live model is wired only when a Foundry deployment is referenced; record any remaining Azure-only dependency (Search, Foundry Agent Service) in `HANDOFF.md`.
14. **Function-tool schemas must be provider-compatible.** Avoid nullable optional tool parameters such as `string? status = null` when targeting Azure AI Inference / Foundry Local. `AIFunctionFactory` can emit JSON Schema union types like `["string","null"]`, and some inference endpoints reject them. Prefer non-null optional strings with empty defaults (`string status = ""`) or explicit DTOs with provider-safe schema.

---

## Pragmatic Defaults

1. **Search-only first** when the requirement is findability, retrieval, or grounded Q&A over existing data.
2. **Single agent second** when the model must choose among a few application-service tools.
3. **Workflows last** when the process is durable, branching, resumable, or needs explicit approvals/checkpoints.
4. **Server-hosted Foundry agents only when justified** by hosted memory, centralized tool catalogs, portal/IaC-managed agent definitions, or operational requirements a code-hosted agent cannot meet. Server-hosted agents (Aspire `AddPromptAgent`, or pre-existing agents driven by the client SDK) always require Azure - start code-hosted.
5. **Keyword or semantic search before vector or hybrid**. Add embeddings only when search quality testing shows a clear gap.
6. **Do not scaffold empty AI folders**. Add only the Search, Agents, and Workflows folders that are enabled.

## Decision Order

- **Need retrieval over business data?** Start with Azure AI Search.
- **Need the model to call internal business operations?** Add one `ChatClientAgent` with a few function tools that delegate to existing application services.
- **Need long-running or branching AI processes?** Add `Microsoft.Agents.Workflows`.
- **Need hosted memory, portal/IaC-managed agent definitions, or Foundry-managed tools?** Use a server-hosted Foundry agent (Aspire `AddProject` + `AddPromptAgent`, or a pre-existing agent via the client SDK) after the simpler code-hosted path is proven insufficient.

## Technology Choices

- **Foundry Models / Azure OpenAI client:** default model host for completions, embeddings, and tool-calling.
- **Azure AI Search:** default retrieval tier.
- **Microsoft Agent Framework:** default code-side agent SDK (`ChatClientAgent` over the injected `IChatClient`).
- **Foundry projects + server-hosted agents:** optional hosted agent backend - Aspire `AddProject` + `AddPromptAgent`, or a pre-existing portal/IaC agent consumed via `AIProjectClient.AsAIAgent(...)`. Azure-only.
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
    - `Azure.AI.Projects` + `Microsoft.Agents.AI.Foundry` (prerelease) when consuming a Foundry **project** or **server-hosted/pre-existing agent** from app code (the `AIProjectClient.AsAIAgent(...)` path). `Microsoft.Agents.AI.Foundry` carries no stable release - pin with reason.
    - `Microsoft.AI.Foundry.Local` (pin `1.2.3`) + `OpenAI` + `Microsoft.Extensions.AI.OpenAI` (API host only) - **temporary** SDK-direct local-dev workaround while Aspire `RunAsFoundryLocal()` is broken (see *Aspire Integration* -> *Known issue*). `Microsoft.AI.Foundry.Local` is a native self-contained SDK: set `RuntimeIdentifiers` and reference with `PrivateAssets="all"`. `Microsoft.Extensions.AI.OpenAI` provides `.AsIChatClient()` over the OpenAI client. **Remove all three** when the Aspire fix lands (see *Migration: restoring `RunAsFoundryLocal()`*). See *SDK-direct API-host bootstrap (temporary workaround)*.
    - `Microsoft.Agents.Workflows` for workflow orchestration

Version all packages in `Directory.Packages.props`. The preview-only packages above (`Aspire.Hosting.Foundry`, `Aspire.Azure.AI.Inference`, `Microsoft.Agents.AI.Foundry`) carry no stable release; pin them with a one-line inline reason (the version-pinning exception). `Microsoft.AI.Foundry.Local` is pinned to `1.2.3` for a different reason - it is the version-specific workaround for the broken Aspire local path; pin it with that inline reason and remove it (with `OpenAI` and `Microsoft.Extensions.AI.OpenAI`) when Aspire bundles Foundry Local SDK >= 1.x.

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
- **Server-hosted Foundry agents:** use only when server-side memory, hosted tools, or centralized/portal-managed agent definitions are real requirements. See *Foundry Projects and Server-Hosted Agents* below.
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
    "FoundryEndpoint": "https://ai-foundry-{resource}.services.ai.azure.com/",
    "AgentModelDeployment": "gpt-4o-deploy",
    "EmbeddingModelDeployment": "embedding-deploy",
    "SearchEndpoint": "https://{search-resource}.search.windows.net",
    "SearchIndexName": "products-index",

    "FoundryResourceName": "",
    "FoundryResourceGroup": "",
    "FoundryProjectEndpoint": "",
    "FoundryAgentName": ""
  }
}
```

Endpoint keys by axis: `FoundryEndpoint` selects/configures the real Azure path (inference). `FoundryResourceName` + `FoundryResourceGroup` target an **existing** Azure Foundry account (the `RunAsExisting`/`PublishAsExisting` parameters). `FoundryProjectEndpoint` + `FoundryAgentName` drive the **server-hosted/pre-existing agent** client path (`AIProjectClient.AsAIAgent(...)`). All four are empty by default and opt-in.

> **Stub rule:** Generate all AI settings with `// TODO: [CONFIGURE]` comments. Use empty strings for endpoints - never hardcode real URLs.

---

## Aspire Integration (Azure AI Foundry)

Only wire AI resources through Aspire if the solution already uses an AppHost. Do not introduce Aspire solely for AI.

> **Known issue - the preferred local path (`RunAsFoundryLocal()`) is temporarily broken (as of 2026-06).** `RunAsFoundryLocal()` is the **target/long-term** local model path and should be restored as soon as `Aspire.Hosting.Foundry` bundles Foundry Local SDK >= 1.x. It does not work today: every `Aspire.Hosting.Foundry` release (through `13.4.5-preview.1.26316.12`) pins **`Microsoft.AI.Foundry.Local` 0.3.0**, whose endpoint discovery shells `foundry service status` and regex-matches `is running on (http://...)`. That only matches the stale `0.8.119` runtime; the GA `1.x` runtime (SDK `1.2.x`; `cli-preview-0.10.0` even renamed `service` -> `server`) does not, so Aspire injects an empty `Endpoint=` connection string and the host throws `Azure AI Inference chat client endpoint is invalid` (dotnet/aspire#12750). **Until then, the local path is the SDK-direct API-host bootstrap below - a temporary workaround, not the target architecture.** The Azure path (`AddFoundry` provision/existing + `AddAzureChatCompletionsClient("chat")` over `ConnectionStrings:chat`) is unaffected and remains the Aspire path.

Use the Foundry hosting integration (`Aspire.Hosting.Foundry`) for the **Azure path** - it provisions Foundry on publish and connects to it in run mode. This package and the Inference client (`Aspire.Azure.AI.Inference`) are preview-only - pin them with an inline reason in `Directory.Packages.props` (the version-pinning exception). The deployment resource name (`"chat"` below) is the connection name consumers bind to. The current **local** path does not share this graph (see *Known issue*): it is the SDK-direct API-host workaround with no `chat` Aspire resource. Restoring `RunAsFoundryLocal()` after the Aspire fix is what brings local back onto the same graph.

### Two axes: lifecycle x consumption

"Aspire Foundry" is two independent choices. Keeping them apart removes the confusion:

- **Axis 1 - where the Foundry resource comes from** (the `AddFoundry` lifecycle).
- **Axis 2 - what you consume** (raw model inference vs. a project + server-hosted agents).

**Axis 1 - lifecycle** (`FoundryResource : AzureProvisioningResource`, so the general `Aspire.Hosting.Azure` existing-resource APIs apply):

| Mode | AppHost call | Result | Azure? |
|---|---|---|---|
| Foundry Local - `RunAsFoundryLocal` (preferred, target) | `AddFoundry("foundry").RunAsFoundryLocal().AddDeployment("chat", FoundryModel.Local.Qwen2505b)` | **Preferred/target** local path: runs the model on-device, inference only, injects `ConnectionStrings:chat`. **Temporarily broken** against GA Foundry Local (dotnet/aspire#12750, see *Known issue*) - restore after the Aspire fix. | No |
| Foundry Local - `sdk-direct-api-host` (temporary, current) | No `AddFoundry` resource; AppHost forwards the opt-in env var to the API host, which drives `Microsoft.AI.Foundry.Local` directly. | **Temporary workaround** in effect now - no `chat` resource, no `ConnectionStrings:chat`. See *SDK-direct API-host bootstrap*. | No |
| Provision new | `AddFoundry("foundry").AddDeployment("chat", FoundryModel.OpenAI.Gpt4oMini)` | Bicep creates the account + deploys the model on publish (and in run mode when `Azure:SubscriptionId/ResourceGroupPrefix/Location` provisioning secrets are set). | Yes (your sub) |
| Connect to existing | `AddFoundry("foundry").RunAsExisting(nameParam, rgParam)` (also `PublishAsExisting`, `AsExisting`) then `.AddDeployment("chat", ...)` | Points at an account you already provisioned; provisions nothing. The deployment name must match a model already deployed there. | Yes (existing) |
| Disabled | (no `AddFoundry`) | No `chat` resource is wired; app registers no-op AI services. | No |

**Axis 2 - consumption:** raw inference (`IChatClient` over a `FoundryDeploymentResource`, below) is the default and works with all three lifecycle modes. Projects + server-hosted agents are an escalation - see *Foundry Projects and Server-Hosted Agents*.

```csharp
// AppHost. Publish (or configured real endpoint/override) -> Azure deployment;
// otherwise local Foundry via the SDK-direct API-host workaround; otherwise no model.
IResourceBuilder<FoundryDeploymentResource>? chat = null;
var azureConfigured = builder.ExecutionContext.IsPublishMode
    || !string.IsNullOrWhiteSpace(builder.Configuration["AiServices:FoundryEndpoint"])
    || Environment.GetEnvironmentVariable("MYAPP_USE_AZURE_FOUNDRY") == "true";
var foundryLocalEnabled =
    Environment.GetEnvironmentVariable("MYAPP_ENABLE_FOUNDRY_LOCAL") == "true";

if (azureConfigured)
{
    chat = builder.AddFoundry("foundry").AddDeployment("chat", FoundryModel.OpenAI.Gpt4oMini);

    // Connect to an EXISTING Azure Foundry account instead of provisioning a new one:
    // the deployment "chat" must already exist in that account. RunAsExisting binds in run
    // mode; PublishAsExisting binds the published graph. Parameters resolve from config/secrets.
    // var name = builder.AddParameter("foundry-name");
    // var rg = builder.AddParameter("foundry-rg");
    // chat = builder.AddFoundry("foundry").RunAsExisting(name, rg)
    //     .AddDeployment("chat", FoundryModel.OpenAI.Gpt4oMini);
}
// No local Foundry branch here: RunAsFoundryLocal() is broken today (dotnet/aspire#12750).
// The local workaround forwards the opt-in var to the API host below; restore the
// RunAsFoundryLocal() branch after the Aspire fix (see Future restored path).

var api = builder.AddProject<Projects.MyApp_Api>("api");

// Azure: wire the deployment (ConnectionStrings:chat + CHAT_* env). Local workaround: NO chat resource -
// forward the opt-in var so the API host bootstraps Microsoft.AI.Foundry.Local directly.
if (chat is not null)
    api = api.WithReference(chat);
else if (foundryLocalEnabled)
    api = api.WithEnvironment("MYAPP_ENABLE_FOUNDRY_LOCAL", "true");
```

Register the **Azure-path** client at the **host** (`IHostApplicationBuilder`, not the `IServiceCollection` AI extension). The `connectionName` must equal the deployment resource name; this runs only when an Azure `chat` deployment was wired. The local workaround instead registers `IChatClient` via the SDK-direct bootstrap (see *SDK-direct API-host bootstrap (temporary workaround)*):

```csharp
// Program.cs - Azure path: run only when the AppHost wired a "chat" reference.
// Local workaround sets IChatClient via the SDK-direct bootstrap; absent both, AddAiServices adds a no-op.
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
# Fully local model run (SDK-direct host bootstrap - NOT RunAsFoundryLocal(); see Known issue)
$env:MYAPP_ENABLE_FOUNDRY_LOCAL = "true"
dotnet run --project src/Host/Aspire/AppHost   # forward the var to the API host (see subsection below)

# Real Azure Foundry local run
dotnet user-secrets set "AiServices:FoundryEndpoint" "https://<your-foundry-resource>.services.ai.azure.com/" --project src/Host/Aspire/AppHost
dotnet run --project src/Host/Aspire/AppHost
```

If the target Azure environment requires keyless managed-identity inference instead of the generated connection secret, update the host-side `AddAzureChatCompletionsClient("chat")` registration to use the required credential overload. Do that before classifying failures as model or prompt failures.

### SDK-direct API-host bootstrap (temporary workaround)

> **This is a temporary workaround, not the target architecture.** Use it only while the preferred path (`RunAsFoundryLocal()`) is broken (see *Known issue*). When Aspire ships the fix, migrate back per *Migration: restoring `RunAsFoundryLocal()`* below.

In this mode the **AppHost wires no Foundry/`chat` resource at all** - there is no `AddFoundry`, no `RunAsFoundryLocal()`, and **no `ConnectionStrings:chat`**. The AppHost only forwards the opt-in env var to the API host; the API host references the self-contained **`Microsoft.AI.Foundry.Local` 1.2.3** SDK and drives it directly (the SDK starts the Foundry Local service, loads a model, and exposes a local OpenAI-compatible endpoint wrapped as `IChatClient`). The Azure path is untouched and stays on Aspire - `AddFoundry` (provision/existing) + host-side `AddAzureChatCompletionsClient("chat")` over `ConnectionStrings:chat`.

**Why version-pinned here (baseline exception):** the failure is version-specific - Aspire's bundled `0.3.0` discovery only matches the stale `0.8.119` runtime, and only `Microsoft.AI.Foundry.Local` `>= 1.2.x` works against the GA `1.x` runtime. Pin `1.2.3` with an inline reason and drop the pin when Aspire ships against a current SDK.

**AppHost (local workaround branch).** Wire no `chat` resource; just forward the opt-in var to the API host:

```csharp
// AppHost. Azure path stays on Aspire (provision/existing -> ConnectionStrings:chat).
// Local workaround: NO Foundry/chat resource; forward the opt-in var to the API host, which
// bootstraps Microsoft.AI.Foundry.Local directly. Restore the RunAsFoundryLocal() branch after the Aspire fix.
var foundryLocalEnabled =
    Environment.GetEnvironmentVariable("MYAPP_ENABLE_FOUNDRY_LOCAL") == "true";

if (foundryLocalEnabled)
    api = api.WithEnvironment("MYAPP_ENABLE_FOUNDRY_LOCAL", "true"); // no WithReference(chat)
```

**Packaging (API host `.csproj`).** `Microsoft.AI.Foundry.Local` is a native, self-contained package - it needs a RID and must not flow transitively:

```xml
<PropertyGroup>
  <RuntimeIdentifiers>win-x64;linux-x64;osx-arm64</RuntimeIdentifiers>
</PropertyGroup>
<ItemGroup>
  <!-- TEMPORARY workaround refs - remove when Aspire RunAsFoundryLocal() is restored (see Migration).
       PrivateAssets=all keeps the native package out of downstream refs.
       Pinned: Aspire's bundled 0.3.0 cannot discover the GA 1.x runtime (dotnet/aspire#12750). -->
  <PackageReference Include="Microsoft.AI.Foundry.Local" PrivateAssets="all" />
  <PackageReference Include="OpenAI" />
  <PackageReference Include="Microsoft.Extensions.AI.OpenAI" /> <!-- .AsIChatClient() over the OpenAI client -->
</ItemGroup>
```

**Bootstrap (API host `Program.cs`).** Gate on the forwarded var and register the resulting `IChatClient`; everything downstream (`AddAiServices` gating, `ChatClientAgent`) is unchanged because it keys off `IChatClient` presence - there is no `ConnectionStrings:chat` to read in this mode:

```csharp
using Microsoft.AI.Foundry.Local;                // FoundryLocalManager, Configuration
using Microsoft.Extensions.AI;                   // AddChatClient, AsIChatClient (via Microsoft.Extensions.AI.OpenAI)
using Microsoft.Extensions.Logging.Abstractions; // NullLogger
using OpenAI;                                    // OpenAIClient
using System.ClientModel;                        // ApiKeyCredential

// TEMPORARY local-dev workaround, opt-in only - replaced by RunAsFoundryLocal() after the Aspire fix.
if (Environment.GetEnvironmentVariable("MYAPP_ENABLE_FOUNDRY_LOCAL") == "true")
{
    var foundryConfig = new Configuration { AppName = appName };
    await FoundryLocalManager.CreateAsync(foundryConfig, NullLogger.Instance);
    var manager = FoundryLocalManager.Instance;

    var catalog = await manager.GetCatalogAsync();
    var model = await catalog.GetModelAsync("qwen2.5-0.5b")          // tool-capable local model
        ?? throw new InvalidOperationException("Foundry Local model 'qwen2.5-0.5b' not found.");
    if (!await model.IsCachedAsync()) await model.DownloadAsync();
    await model.LoadAsync();
    await manager.StartWebServiceAsync();                            // local OpenAI-compatible endpoint

    var openAi = new OpenAIClient(
        new ApiKeyCredential("not-needed"),                         // Foundry Local needs no key
        new OpenAIClientOptions { Endpoint = new Uri(foundryConfig.Web!.Urls + "/v1") });
    services.AddChatClient(openAi.GetChatClient(model.Id).AsIChatClient());
}
```

**Opt-in var must reach the API host.** This gate runs in the API host process (not the AppHost), so forward the var as shown above, or run the API project directly for pure local dev. When the var is unset, no SDK call runs and `AddAiServices` registers the no-op `IChatClient`, so the app still boots offline.

### Future restored path (after Aspire fix): `RunAsFoundryLocal()`

This is the **preferred/target** local path - restore it once `Aspire.Hosting.Foundry` bundles Foundry Local SDK >= 1.x. Do **not** copy it into a live AppHost before then; it is broken against GA Foundry Local today (see *Known issue*).

```csharp
// AppHost - PREFERRED local path, usable only AFTER the Aspire fix. Broken today (dotnet/aspire#12750).
else if (foundryLocalEnabled)
{
    chat = builder.AddFoundry("foundry").RunAsFoundryLocal()
        .AddDeployment("chat", FoundryModel.Local.Qwen2505b);       // re-injects ConnectionStrings:chat
}
// ...and the API host returns to: builder.AddAzureChatCompletionsClient("chat").AddChatClient();
```

### Migration: restoring `RunAsFoundryLocal()`

When `Aspire.Hosting.Foundry` bundles Foundry Local SDK >= 1.x:

1. Remove the API-host workaround refs - `Microsoft.AI.Foundry.Local`, `OpenAI`, `Microsoft.Extensions.AI.OpenAI` - and the `RuntimeIdentifiers` added for them.
2. Delete the API-host SDK bootstrap block; the API host returns to host-side `AddAzureChatCompletionsClient("chat").AddChatClient()` gated on `ConnectionStrings:chat`.
3. Restore the AppHost `RunAsFoundryLocal()` branch (above) so local mode again wires a `chat` resource via `WithReference(chat)`.
4. Set `foundry.localRuntimeMode: RunAsFoundryLocal` in the resource implementation and drop the temporary env-var-forward branch.

---

## Foundry Projects and Server-Hosted Agents

The default agent path is **code-hosted**: a `ChatClientAgent` running in your process over the injected `IChatClient` (above). It works with every Axis-1 lifecycle mode and boots offline as a no-op. Escalate to a **server-hosted** Foundry agent only for hosted memory, centralized/portal-managed tool catalogs, or versioned agent definitions managed outside your code. Server-hosted agents are **Azure-only** - they have no Foundry Local path.

A Foundry **project** is the container that deployments, agents, connections, and tools live under. `RunAsFoundryLocal()` does not support projects or server-hosted agents.

### Aspire-modeled project + prompt agent

`Aspire.Hosting.Foundry` models the project and a declarative **prompt agent**. Tools are project-level resources, reusable across agents. The project reference injects `PROJ_URI` (the project endpoint, `https://<acct>.services.ai.azure.com/api/projects/<project>`), `PROJ_CONNECTIONSTRING`, and `PROJ_APPLICATIONINSIGHTSCONNECTIONSTRING`.

> **Prompt agents always deploy to Azure Foundry, even under `aspire run`** - local services talk to the cloud-provisioned agent. There is no offline mode. Keep this behind an explicit opt-in so a default run still boots without Azure.

```csharp
// AppHost - opt-in, Azure-only.
var foundry = builder.AddFoundry("foundry");
var project = foundry.AddProject("proj");
var chat = project.AddModelDeployment("chat", FoundryModel.OpenAI.Gpt41);

// Tools are project resources (reusable across agents).
var codeInterp = project.AddCodeInterpreterTool("code-interp");
var webSearch = project.AddWebSearchTool("web-search");
// var aiSearch = project.AddAISearchTool("search-tool").WithReference(search);

var agent = project.AddPromptAgent(chat, "assistant-agent",
        instructions: "You are an assistant for {Project}.")
    .WithTool(codeInterp)
    .WithTool(webSearch);

api.WithReference(agent);   // or .WithReference(project) to consume the project endpoint directly
```

### Pre-existing agents via the client SDK

When agents are created in the Foundry portal or by IaC, do not model them in Aspire. Connect to the existing project endpoint (Axis-1 existing mode, or `builder.AddConnectionString(...)`) and drive the agent with the Microsoft Agent Framework Foundry client. Add `Azure.AI.Projects` + `Microsoft.Agents.AI.Foundry` (prerelease) + `Azure.Identity`.

```csharp
using Azure.AI.Projects;
using Azure.Identity;
using Microsoft.Agents.AI;

var project = new AIProjectClient(new Uri(projectEndpoint), new DefaultAzureCredential());

// Code-first responses agent (no server-side agent resource is created):
AIAgent responsesAgent = project.AsAIAgent(
    model: agentModelDeployment, name: "Assistant", instructions: systemPrompt);

// Or bind to a pre-existing versioned agent created in the portal/IaC, by name:
var record = await project.AgentAdministrationClient.GetAgentAsync(agentName);
AIAgent foundryAgent = project.AsAIAgent(record);
```

Both results are standard `AIAgent` instances (sessions, tools, middleware, streaming) - the same surface the code-hosted `ChatClientAgent` exposes, so the application-facing `I{Agent}Agent` contract is unchanged. Use `DefaultAzureCredential` (prefer `ManagedIdentityCredential` in production); the project endpoint comes from `AiServices:FoundryProjectEndpoint` (or the Aspire-injected `PROJ_URI`).

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

### Provider Test Tiers (Azure / Local / no-op)

Keep the tiers distinct - the model provider must not leak into the fast tiers.

- **Application / service / endpoint tests use a fake `IChatClient`** (a small deterministic stand-in, or a Moq double) - never a real Azure or Foundry Local model. Cover with fakes: the response contract, the parse guard (model JSON wrapped in extra text, or non-parseable output), the no-write path (a triage/draft that must not persist), and the write behavior (a parseable response that does persist). These live in `Test.Unit` / `Test.Endpoints`.
- **Cover the no-op fallback explicitly.** Assert that with no provider wired, `AddAiServices` registers the no-op `IChatClient` (and no-op search/agent), and that each AI endpoint returns its `isConfigured: false` contract without persisting. A no-op path that is never asserted is an untested fallback.
- **Live model tests are smoke only** and belong in the mesh tier (`Test.Aspire`). They assert response contracts (status, `isConfigured: true`, non-empty/typed fields), not exact model text.
- **One active-provider lane, not one lane per provider.** Smoke the active provider only - Azure Foundry when configured, else Foundry Local when it bootstraps. Do not copy every app contract once for Azure and again for Local. The active-provider smoke set is: chat, the tool-calling agent, one safe AI write-adjacent path (e.g. triage with `apply=false`, or a draft that may create), and one FlowEngine agent-workflow run. Reserve an `AzureFoundry` category for genuinely Azure-specific behavior (resource selection / provisioning), never for a second copy of a provider-neutral contract. Add a provider-specific copy only when the behavior actually differs by provider.
- **Never silently pass a live AI test on no-op.** When no real provider is active, the live smoke is `Assert.Inconclusive` with a message naming the absent provider - never green. (See [testing.md](testing.md) -> Never Silently Pass.) The no-op contract tests above cover that state; the live smokes do not.

Provider selection priority (the lane mirrors the app's own order):

1. Azure Foundry configured -> use Azure.
2. else Foundry Local requested / available -> use Local.
3. else no-op AI.

### Deciding the Live Lane Without Probing the CLI

Do **not** shell the `foundry` CLI (`foundry service status`, `foundry model info ...`) to decide whether the Local smoke lane runs. The current local path is the self-contained SDK-direct bootstrap (no CLI on `PATH`), and `foundry` catalog/CLI behavior is brittle across versions - a CLI probe can wrongly disable a lane the SDK would have bootstrapped fine. Instead:

1. When Azure is absent, **request Foundry Local by default** (set the local opt-in var for the test graph) and let the API host attempt the SDK bootstrap.
2. **Inspect `GET /api/v1/ai/status`** to learn the active provider, and gate the lane on that result.

Expose a minimal status endpoint for this (and for ops). It reports the provider resolved from the live object graph - `azure` / `local` / `none` - based on which bootstrap path wired `IChatClient`, recorded once at startup. It must not run a CLI probe or call the model. Do not infer the provider by sniffing a connection string: the SDK-direct local path wires no `chat` connection at all, so a connection-string heuristic reports `none` for a working local model.

```csharp
// At bootstrap, whichever path wires IChatClient also records the provider name
// (no CLI, no model call): services.AddSingleton(new AiProviderInfo("azure" | "local" | "none"));

// GET /api/v1/ai/status - honest, side-effect-free provider signal for tests and ops.
group.MapGet("/status", (
    [FromServices] IChatClient chatClient,
    [FromServices] AiProviderInfo provider) =>
    Results.Ok(new { provider = provider.Name, isConfigured = chatClient is not NoOpChatClient }))
    .WithName("AiStatus");
```

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
