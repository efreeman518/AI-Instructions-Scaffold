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
- Fully local model run: just `dotnet run --project src/Host/Aspire/AppHost` - when Azure is absent the API host attempts the local bootstrap by default (no opt-in var); set `AiServices:DisableFoundryLocal=true` to force no-op. The **target** path is Aspire `RunAsFoundryLocal()`; while it is broken against GA Foundry Local (see *Aspire Integration* -> *Known issue*), the **temporary** local path is the SDK-direct API-host bootstrap - the AppHost wires no `chat` resource and forwards no opt-in var; the API host drives the `Microsoft.AI.Foundry.Local` SDK directly. See *SDK-direct API-host bootstrap (temporary workaround)*.
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
15. **AI provider contract explicit.** Runtime order is Azure Foundry when `ConnectionStrings:chat`/configured Foundry endpoint exists, else Foundry Local when available and not disabled, else no-op. No-op allowed for non-live AI tests and offline boot only. Live AI tests never green on `none` or `stub`.

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
    // environment gates the opt-in dev-stub tier (Development only); callers pass builder.Environment.
    public static IServiceCollection AddAiServices(this IServiceCollection services, IConfiguration config, IHostEnvironment environment)
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

        // Opt-in dev-stub: a deterministic IChatClient for manual local runs/demos, so the agent and
        // AI surfaces render populated content with no model. Development-only, off by default, and only
        // when no live provider was wired. Never a deployed environment (see Configuration -> DevStubContent).
        var devStub = !hasChatClient && settings.DevStubContent && environment.IsDevelopment();
        var usableChatClient = hasChatClient || devStub;

        // Agent services - once the agent feature exists, live behavior follows a usable IChatClient.
        // Without a model (and no dev-stub), keep the no-op stub so local scaffold runs still boot.
        if (usableChatClient)
            services.AddScoped<ISupportTriageAgent, SupportTriageAgentService>();
        else
            services.AddScoped<ISupportTriageAgent, NoOpSupportTriageAgent>();

        // IChatClient fallback so AI endpoints/consumers resolve and the app boots offline.
        if (devStub)
            services.AddSingleton<IChatClient, StubContentChatClient>(); // deterministic dev/demo content
        else if (!hasChatClient)
            services.AddSingleton<IChatClient, NoOpChatClient>();

        // Provider signal for GET /ai/status. Each IChatClient bootstrap branch (Azure host path,
        // SDK-direct local path) already registered AiProviderInfo("azure"|"local"); the dev-stub path
        // records "stub". TryAddSingleton keeps whichever was set and falls back to "none" when no
        // provider was wired (the no-op case above).
        if (devStub)
            services.TryAddSingleton(new AiProviderInfo("stub"));
        services.TryAddSingleton(new AiProviderInfo("none")); // Microsoft.Extensions.DependencyInjection.Extensions

        return services;
    }
}
```

No-op stubs return empty results or a `Result.Failure("AI service not configured")` and log a warning; they do not throw on DI resolution. Scaffold `AiProviderInfo` and the `GET /ai/status` endpoint **by default** whenever `includeAiServices: true` - it is the live-lane gate (see *Testing*) and an ops signal, and is easy to skip because the agents work without it.

**Runtime synthesized content is deliberately not a default.** The honest default with no provider wired is the no-op contract - empty results, `AiProviderInfo("none")`, `isConfigured: false` - so an offline boot never fabricates content that looks like model output. Fast test tiers do not need this default to be populated: they inject a deterministic fake `IChatClient` (see *Testing* -> *Provider Test Tiers*), so they already assert full response contracts with no model. The one gap that justifies more is the **manual** local run / demo (a real `dotnet run` / Aspire boot, where no fake is injected): with no provider it shows empty AI surfaces. The opt-in `AiServices:DevStubContent` flag (above) closes only that gap - Development-only, off by default, registering a small deterministic `StubContentChatClient` (the same deterministic-stand-in shape the test tiers use, promoted to an opt-in app registration, not a second generator). It surfaces as a distinct provider `stub` via `GET /ai/status`, so a UI can banner it as synthesized and it is never mistaken for a model, and the live smoke treats `stub` like `none` (Inconclusive, never green - see *Testing*). Leave it off unless a populated local/demo experience is actually wanted.

**Multi-host wiring.** When more than one host consumes AI (e.g. API and Functions), factor the provider selection into one shared path both hosts call - do not duplicate the Azure/local/no-op branch in each `Program.cs`. Register the AI consumer services (`AddAiServices` - agents, demos, the `AiProviderInfo` fallback) through the shared Bootstrapper as a feature-scoped `Register{Ai}Services` extension with per-host opt-in, per [bootstrapper.md](bootstrapper.md) (Conditional Per-Host Dependency Pattern); keep the host-builder client bootstrap (the Azure `AddAzureChatCompletionsClient`, or the async SDK-direct local bootstrap, both of which are host/RID-bound) in one shared routine the opting-in hosts share. The inline `Program.cs` examples above are the single-host shorthand.

---

## Configuration (appsettings)

```json
{
  "AiServices": {
    "UseSearch": true,
    "UseAgents": false,
    "UseVectorSearch": false,
    "DisableFoundryLocal": false,
    "RequireFoundryLocal": false,
    "LocalModel": "qwen2.5-0.5b",
    "LocalWebUrl": "http://127.0.0.1:52415",
    "DevStubContent": false,
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

`DisableFoundryLocal` is the local-path **opt-out** (default `false`). The API host attempts the SDK-direct local bootstrap whenever Azure is absent; set this `true` to skip the attempt and force no-op AI. It is the switch RID-free / offline test tiers set on both API boot paths (see *Testing* -> *Deciding the Live Lane*); it has no effect when Azure is wired. Unlike the other keys here, it is **read host-side via `config.GetValue<bool>("AiServices:DisableFoundryLocal")` in `Program.cs`, not bound on `AiSettings`** - deliberately, because it gates the RID-bound host bootstrap that runs before (and outside) the shared RID-free `Infrastructure.AI` settings binding. The tradeoff: a host knob has no bind-time validation, so a typo in the key silently no-ops. Keep the spelling exact. Shortcut: a single host-read bool; if host-only AI knobs proliferate, promote them to a small host-local options record so they are not stringly-typed in two places.

`DevStubContent` is the manual-local/demo **opt-in** (default `false`). When `true`, in a Development environment, and only when no live provider (Azure or Foundry Local) was wired, the API registers a deterministic `StubContentChatClient` instead of the no-op client and records `AiProviderInfo("stub")` - so a real `dotnet run`/Aspire boot renders populated AI surfaces without a model. It has no effect outside Development, no effect when a real provider is wired, and never greens a live smoke (`stub` is treated like `none`; see *DI Registration* and *Testing* -> *Provider Test Tiers*). Leave it `false` to keep the honest empty/`isConfigured: false` state.

`RequireFoundryLocal` is a live-test host knob, default `false`. Set it `true` only in `Test.FoundryLocal` so SDK bootstrap failure throws for the test harness to classify: missing/undiscoverable runtime -> `Assert.Inconclusive`; installed/discovered runtime that falls back no-op, returns bad HTTP or an invalid/missing contract, or reports wrong `/api/v1/ai/status` -> `Assert.Fail`. A healthy provider (`provider: local`, `isConfigured: true`) whose model generation exceeds the per-request budget is `Assert.Inconclusive` - that is machine capacity, not a contract failure. `LocalModel` and `LocalWebUrl` feed the SDK-direct bootstrap.

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
| Foundry Local - `sdk-direct-api-host` (temporary, current) | No `AddFoundry` resource; when Azure is absent the API host attempts the local SDK bootstrap by default (no opt-in var), driving `Microsoft.AI.Foundry.Local` directly. Offline / RID-free tiers opt out via `AiServices:DisableFoundryLocal`. | **Temporary workaround** in effect now - no `chat` resource, no `ConnectionStrings:chat`. See *SDK-direct API-host bootstrap*. | No |
| Provision new | `AddFoundry("foundry").AddDeployment("chat", FoundryModel.OpenAI.Gpt4oMini)` | Bicep creates the account + deploys the model on publish (and in run mode when `Azure:SubscriptionId/ResourceGroupPrefix/Location` provisioning secrets are set). | Yes (your sub) |
| Connect to existing | `AddFoundry("foundry").RunAsExisting(nameParam, rgParam)` (also `PublishAsExisting`, `AsExisting`) then `.AddDeployment("chat", ...)` | Points at an account you already provisioned; provisions nothing. The deployment name must match a model already deployed there. | Yes (existing) |
| Disabled | (no `AddFoundry`) | No `chat` resource is wired; app registers no-op AI services. | No |

**Axis 2 - consumption:** raw inference (`IChatClient` over a `FoundryDeploymentResource`, below) is the default and works with all three lifecycle modes. Projects + server-hosted agents are an escalation - see *Foundry Projects and Server-Hosted Agents*.

```csharp
// AppHost. Publish (or configured real endpoint/override) -> Azure deployment;
// otherwise the API host attempts local Foundry via the SDK-direct workaround; otherwise no model.
IResourceBuilder<FoundryDeploymentResource>? chat = null;
var azureConfigured = builder.ExecutionContext.IsPublishMode
    || !string.IsNullOrWhiteSpace(builder.Configuration["AiServices:FoundryEndpoint"])
    || Environment.GetEnvironmentVariable("MYAPP_USE_AZURE_FOUNDRY") == "true";

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
// There is NO local opt-in var to forward: when Azure is absent the API host attempts the
// SDK-direct bootstrap on its own (see SDK-direct API-host bootstrap). Restore the
// RunAsFoundryLocal() branch after the Aspire fix (see Future restored path).

var api = builder.AddProject<Projects.MyApp_Api>("api");

// Azure: wire the deployment (ConnectionStrings:chat + CHAT_* env). Local: nothing to wire -
// the API host decides at boot. A TESTING AppHost forces no-op so the RID-free mesh never
// starts a model (see Testing): api = api.WithEnvironment("AiServices__DisableFoundryLocal", "true");
if (chat is not null)
    api = api.WithReference(chat);
```

Register the **Azure-path** client at the **host** (`IHostApplicationBuilder`, not the `IServiceCollection` AI extension). The `connectionName` must equal the deployment resource name; this runs only when an Azure `chat` deployment was wired. The local workaround instead registers `IChatClient` via the SDK-direct bootstrap (see *SDK-direct API-host bootstrap (temporary workaround)*):

```csharp
// Program.cs - Azure path: run only when the AppHost wired a "chat" reference.
// Local workaround sets IChatClient via the SDK-direct bootstrap; absent both, AddAiServices adds a no-op.
if (!string.IsNullOrWhiteSpace(builder.Configuration.GetConnectionString("chat")))
{
    builder.AddAzureChatCompletionsClient("chat").AddChatClient(); // registers Microsoft.Extensions.AI.IChatClient
    builder.Services.AddSingleton(new AiProviderInfo("azure"));    // record provider for /ai/status (see Testing)
}
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
# Fully local model run (SDK-direct host bootstrap - NOT RunAsFoundryLocal(); see Known issue).
# No opt-in var: with Azure absent the API host attempts the local bootstrap by default.
dotnet run --project src/Host/Aspire/AppHost
# Force no-op (skip the local attempt - offline / fast iteration):
$env:AiServices__DisableFoundryLocal = "true"; dotnet run --project src/Host/Aspire/AppHost

# Real Azure Foundry local run
dotnet user-secrets set "AiServices:FoundryEndpoint" "https://<your-foundry-resource>.services.ai.azure.com/" --project src/Host/Aspire/AppHost
dotnet run --project src/Host/Aspire/AppHost
```

If the target Azure environment requires keyless managed-identity inference instead of the generated connection secret, update the host-side `AddAzureChatCompletionsClient("chat")` registration to use the required credential overload. Do that before classifying failures as model or prompt failures.

### SDK-direct API-host bootstrap (temporary workaround)

> **This is a temporary workaround, not the target architecture.** Use it only while the preferred path (`RunAsFoundryLocal()`) is broken (see *Known issue*). When Aspire ships the fix, migrate back per *Migration: restoring `RunAsFoundryLocal()`* below.

> **The snippet below is verified against `Microsoft.AI.Foundry.Local` `1.2.3` only** (the pin), by the RID-bound `Test.FoundryLocal` live lane (provider `local`, real `qwen2.5-0.5b` completion). The preview SDK surface has shifted across releases - `CreateAsync` returns `Task` (get the manager from the static `Instance`), `StartWebServiceAsync()` needs `Configuration.Web` set first and the bound endpoint reads back from `manager.Urls`, and `IModel.GetChatClientAsync()` is not a `Microsoft.Extensions.AI` client. Re-verify against the installed version before relying on it; treat it as illustrative, not version-agnostic.

In this mode the **AppHost wires no Foundry/`chat` resource at all** - there is no `AddFoundry`, no `RunAsFoundryLocal()`, and **no `ConnectionStrings:chat`**. The AppHost only forwards the opt-in env var to the API host; the API host references the self-contained **`Microsoft.AI.Foundry.Local` 1.2.3** SDK and drives it directly (the SDK starts the Foundry Local service, loads a model, and exposes a local OpenAI-compatible endpoint wrapped as `IChatClient`). The Azure path is untouched and stays on Aspire - `AddFoundry` (provision/existing) + host-side `AddAzureChatCompletionsClient("chat")` over `ConnectionStrings:chat`.

**Why version-pinned here (baseline exception):** the failure is version-specific - Aspire's bundled `0.3.0` discovery only matches the stale `0.8.119` runtime, and only `Microsoft.AI.Foundry.Local` `>= 1.2.x` works against the GA `1.x` runtime. Pin `1.2.3` with an inline reason and drop the pin when Aspire ships against a current SDK.

**AppHost (local workaround branch).** Wire no `chat` resource and forward no opt-in var; when Azure is absent the API host attempts the local bootstrap on its own. The only thing an AppHost ever forwards for this path is the **testing** opt-out:

```csharp
// AppHost. Azure path stays on Aspire (provision/existing -> ConnectionStrings:chat).
// Local workaround: NO Foundry/chat resource and NO opt-in var - the API host attempts
// Microsoft.AI.Foundry.Local on its own when Azure is absent. Restore RunAsFoundryLocal() after the Aspire fix.
//
// A TESTING AppHost forces no-op so the RID-free mesh never starts a model (see Testing):
//   api = api.WithEnvironment("AiServices__DisableFoundryLocal", "true");
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

**The RID-bound test lane needs its own direct reference.** The native payload (`Microsoft.AI.Foundry.Local.Core`) ships in a separate RID-bound transitive package, and `PrivateAssets="all"` deliberately stops it flowing into downstream refs - including an in-process `WebApplicationFactory` test host that references the API host project. So the `Test.FoundryLocal` lane (see *Testing* -> *Deciding the Live Lane*) must declare its **own** direct `Microsoft.AI.Foundry.Local` `PackageReference` plus matching `RuntimeIdentifiers`; it cannot inherit the native payload transitively. The RID-free fast tiers never reference it.

**Bootstrap (API host `Program.cs`).** Attempt the local bootstrap by default when Azure is absent and the opt-out is unset, and register the resulting `IChatClient`. A failed bootstrap **falls back to no-op** rather than throwing, so the app still boots. Exception: when `AiServices:RequireFoundryLocal=true` (set only by `Test.FoundryLocal`), rethrow so live-local tests can fail instead of masking provider drift. Everything downstream (`AddAiServices` gating, `ChatClientAgent`) is unchanged because it keys off `IChatClient` presence - there is no `ConnectionStrings:chat` to read in this mode:

```csharp
using Microsoft.AI.Foundry.Local;                // FoundryLocalManager, Configuration
using Microsoft.Extensions.AI;                   // AddChatClient, AsIChatClient (via Microsoft.Extensions.AI.OpenAI)
using Microsoft.Extensions.Logging.Abstractions; // NullLogger
using OpenAI;                                    // OpenAIClient
using System.ClientModel;                        // ApiKeyCredential

// TEMPORARY local-dev workaround - replaced by RunAsFoundryLocal() after the Aspire fix.
// Availability-driven, NO opt-in: attempt local when Azure is absent and the opt-out is unset.
// Fast / RID-free test tiers set AiServices:DisableFoundryLocal=true (see Testing) so they never reach here.
var azureWired = !string.IsNullOrWhiteSpace(builder.Configuration.GetConnectionString("chat"));
// Host-read on purpose (not a bound AiSettings property): this gates the RID-bound host bootstrap,
// which runs before the RID-free Infrastructure.AI settings binding. Tradeoff: no bind-time
// validation, so a typo in the key silently no-ops - keep the spelling exact. (See Configuration.)
var disableLocal = builder.Configuration.GetValue<bool>("AiServices:DisableFoundryLocal");
var requireLocal = builder.Configuration.GetValue<bool>("AiServices:RequireFoundryLocal");
if (!azureWired && !disableLocal)
{
    try
    {
        // Web bind config is REQUIRED before StartWebServiceAsync(), or it throws "Web service
        // configuration was not provided." Port 0 = ephemeral. This is the INPUT bind address; the
        // ACTUAL bound endpoint comes from manager.Urls after startup (do not reuse this value).
        var foundryConfig = new Configuration
        {
            AppName = appName,
            Web = new Configuration.WebService { Urls = "http://127.0.0.1:0" }
        };
        await FoundryLocalManager.CreateAsync(foundryConfig, NullLogger.Instance); // returns Task (void)
        var manager = FoundryLocalManager.Instance;                               // get the singleton, not a return value

        var catalog = await manager.GetCatalogAsync();
        var model = await catalog.GetModelAsync("qwen2.5-0.5b")          // tool-capable local model
            ?? throw new InvalidOperationException("Foundry Local model 'qwen2.5-0.5b' not found.");
        if (!await model.IsCachedAsync()) await model.DownloadAsync();
        await model.LoadAsync();
        await manager.StartWebServiceAsync();                            // starts the local OpenAI-compatible endpoint; populates manager.Urls

        // Use the official OpenAI SDK over the BOUND address (manager.Urls is a string[] populated only
        // after startup) - NOT foundryConfig.Web.Urls (the ephemeral input) and NOT IModel.GetChatClientAsync()
        // (which returns a non-Microsoft.Extensions.AI client). .AsIChatClient() comes from Microsoft.Extensions.AI.OpenAI.
        var openAi = new OpenAIClient(
            new ApiKeyCredential("not-needed"),                         // Foundry Local needs no key
            new OpenAIClientOptions { Endpoint = new Uri(manager.Urls[0] + "/v1") });
        services.AddChatClient(openAi.GetChatClient(model.Id).AsIChatClient());
        services.AddSingleton(new AiProviderInfo("local"));             // record provider for /ai/status
    }
    catch (Exception ex)
    {
        // Bootstrap failed (no runtime, offline, model unavailable) -> fall back to no-op
        // unless Test.FoundryLocal set RequireFoundryLocal=true.
        if (requireLocal) throw;
        // Log via your bootstrap logger. AddAiServices then records
        // AiProviderInfo("none") and registers NoOpChatClient, so the app still boots.
        _ = ex;
    }
}
```

**The bootstrap runs in the API host process** (not the AppHost), where the RID-bound `Microsoft.AI.Foundry.Local` package lives - so it works whether you launch the AppHost or run the API project directly. When Azure is wired, when `AiServices:DisableFoundryLocal` is set, or when the bootstrap throws, no live client is registered and `AddAiServices` registers the no-op `IChatClient` (and `AiProviderInfo("none")`), so the app still boots offline.

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
4. Set `foundry.localRuntimeMode: RunAsFoundryLocal` in the resource implementation and drop the availability-driven SDK bootstrap, the `AiServices:DisableFoundryLocal` opt-out, and the RID-bound `Test.FoundryLocal` live lane.
5. **After changing the gate, grep the removed tokens across comments and docs, not just code.** A gating-mechanism change (here: availability-driven -> `RunAsFoundryLocal`, dropping `DisableFoundryLocal`) is done only when the old token is gone from inline comments and XML doc comments too - not just executable logic. `HANDOFF.md` records the high-level change; the recurring miss is a stale doc comment that still names a removed flag and now actively contradicts the logic. This applies to any gating refactor, in either direction.

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

### Deterministic agents for tests

When the app's primary workflow invokes an AI agent, the primary-journey E2E
([../templates/test-templates-e2e.md](../templates/test-templates-e2e.md) section Primary domain-journey E2E)
must run that agent deterministically and offline - no model call. Gate the live model behind a config
switch so a booted host can swap a scripted agent for the real one. A config switch (not just an injected
fake) is what makes this work where the test cannot reach the host's DI - the Aspire mesh and any
separately-launched host - and it is the simplest path for the journey test.

- Add `{App}:AiServices:UseScriptedAgent` (default false). When true, `AddAiServices` registers a scripted
  `IChatClient`/agent returning canned, deterministic responses (and a fixed tool-call sequence) instead of
  the live or no-op client.
- Set it in the E2E/journey host config (the `SqlApiFactory` config, or the Aspire AppHost testing branch
  alongside `AiServices:DisableFoundryLocal=true`) so the journey is repeatable and needs no provider.
- It is a test mechanism, distinct from `AiServices:DevStubContent` (a manual demo aid). Like the stub and
  no-op, the scripted agent reports `isConfigured: false` on `GET /ai/status`, so a live smoke stays
  `Assert.Inconclusive`, never green, while it is active. In-process unit/service/endpoint tests still
  inject a fake `IChatClient` directly (see Provider Test Tiers below) - the switch is for the booted-host
  tiers.

### Provider Test Tiers (Azure / Local / no-op)

Keep the tiers distinct - the model provider must not leak into the fast tiers.

- **Application / service / endpoint tests use a fake `IChatClient`** (a small deterministic stand-in, or a Moq double) - never a real Azure or Foundry Local model. Cover with fakes: the response contract, the parse guard (model JSON wrapped in extra text, or non-parseable output), the no-write path (a triage/draft that must not persist), and the write behavior (a parseable response that does persist). These live in `Test.Unit` / `Test.Endpoints`.
- **Cover the no-op fallback explicitly.** Assert that with no provider wired, `AddAiServices` registers the no-op `IChatClient` (and no-op search/agent) with `AiProviderInfo("none")`, that `GET /ai/status` reports `provider: none`, and that each AI endpoint returns its `isConfigured: false` contract without persisting. A no-op path that is never asserted is an untested fallback.
- **Live model tests are smoke only.** The **Azure** live smoke is HTTP-only (no RID) and may run in the mesh tier (`Test.Aspire`). The **Foundry Local** live smoke must run in a dedicated **RID-bound `Test.FoundryLocal`** project, never in the RID-free mesh (see *Deciding the Live Lane* for why). Both assert response contracts (status, `isConfigured: true`, non-empty/typed fields), not exact model text.
- **Status mismatch fails live local.** `Test.FoundryLocal` sets `AiServices:RequireFoundryLocal=true`, starts the API host directly, calls `/api/v1/ai/status`, and requires `provider: local` plus `isConfigured: true` before chat/tool smoke. `Assert.Inconclusive` when Foundry Local runtime is missing or undiscoverable, or when a healthy provider (`provider: local`, `isConfigured: true`) has model generation that exceeds the per-request budget - that is machine capacity, not a contract failure. If the runtime is installed/discovered but the provider falls back to `none`, reports `stub`, returns bad HTTP, an invalid contract, or missing required schema, lies about status, or fails to start after runtime discovery, call `Assert.Fail`.
- **One active-provider lane, not one lane per provider.** Smoke the active provider only - Azure Foundry when configured, else Foundry Local when it bootstraps. Do not copy every app contract once for Azure and again for Local. The active-provider smoke set is: chat, the tool-calling agent, one safe AI write-adjacent path (e.g. triage with `apply=false`, or a draft that may create), and one FlowEngine agent-workflow run. Reserve an `AzureFoundry` category for genuinely Azure-specific behavior (resource selection / provisioning), never for a second copy of a provider-neutral contract. Add a provider-specific copy only when the behavior actually differs by provider.
- **Never silently pass a live AI test on no-op.** When no real provider is active, the live smoke is `Assert.Inconclusive` with a message naming the absent provider - never green. (See [testing.md](testing.md) -> Never Silently Pass.) The no-op contract tests above cover that state; the live smokes do not.
- **The dev-stub provider is treated like no-op for tests.** `AiServices:DevStubContent` (see *DI Registration* / *Configuration*) is a manual local/demo aid, not a test mechanism - test hosts inject the fake `IChatClient` (so `hasChatClient` is true and the stub never activates). For the live lane, `provider: stub` reports `isConfigured: false` and is `Inconclusive`, exactly like `none` - never green. If you cover it at all, assert that `stub` maps to `isConfigured: false`; do not smoke synthesized content as if it were a model.

Provider selection priority (the lane mirrors the app's own order):

1. Azure Foundry configured -> use Azure.
2. else Foundry Local requested / available -> use Local.
3. else dev-stub if `DevStubContent` is set in Development -> provider `stub` (manual/demo only; never green).
4. else no-op AI.

`Test.Aspire` runs RID-free with `AiServices:DisableFoundryLocal=true`; its live AI smoke is Azure-only and inconclusive when Azure Foundry is not configured. `Test.FoundryLocal` owns local live proof and is the only tier allowed to load native Foundry Local packages. Unit/endpoint tests use fake or no-op clients and never native Foundry Local.

### Deciding the Live Lane Without Probing the CLI

Do **not** shell the `foundry` CLI (`foundry service status`, `foundry model info ...`) to decide whether the Local smoke lane runs. The current local path is the self-contained SDK-direct bootstrap (no CLI on `PATH`), and `foundry` catalog/CLI behavior is brittle across versions - a CLI probe can wrongly disable a lane the SDK would have bootstrapped fine.

**The RID constraint decides the lane architecture - it is not a preference.** `Microsoft.AI.Foundry.Local` is a native, RID-forcing package (`RuntimeIdentifiers` + `PrivateAssets="all"`) confined to the API host project. The fast tiers are deliberately **RID-free**: the in-memory `WebApplicationFactory` base (`Test.Support`) loads the API into the RID-free test process, and the Aspire mesh (`Test.Aspire`) is likewise RID-free. They **physically cannot load the local SDK at runtime** - so "request Foundry Local for the test graph" is impossible there, not merely undesirable. Two consequences:

1. **Every API-booting tier that is RID-free must force no-op.** Set `AiServices:DisableFoundryLocal=true` so the API host skips the local attempt and registers the no-op `IChatClient`. Set it on **both** boot paths - the in-memory `WebApplicationFactory` base (`CustomApiFactory` / `SqlApiFactory` config) **and** the Aspire AppHost testing branch (`WithEnvironment("AiServices__DisableFoundryLocal", "true")`). Setting one and missing the other lets that tier silently try to start a model.
2. **The live-local smoke is its own RID-bound project, `Test.FoundryLocal`.** It targets the API host's RIDs, boots the API host directly (not the mesh), **assumes local**, and asserts `Assert.Inconclusive` **only when the SDK cannot bootstrap** (offline, no runtime) - never green on no-op. Category `[TestCategory("LiveAI")]` (plus `FoundryLocal`). The RID-free mesh handles the **Azure** live smoke (HTTP-only); it never hosts a local model. It must declare its **own** direct `Microsoft.AI.Foundry.Local` package reference - `PrivateAssets="all"` on the API host stops the native payload flowing transitively (see *Packages* -> *SDK-direct API-host bootstrap*).

**Gate the live lane on `GET /ai/status`, not on a connection string.** The endpoint reports the provider resolved from the live object graph - `azure` / `local` / `none` - based on which bootstrap path wired `IChatClient`, recorded once at startup. It must not run a CLI probe or call the model. Do not infer the provider by sniffing a connection string: the SDK-direct local path wires no `chat` connection at all, so a connection-string heuristic reports `none` for a working local model. Scaffold it by default whenever AI is enabled.

**A self-contained provider-proof test owns its graph.** A test that claims to prove a specific provider/config path (local fallback, Azure-only, no-op) constructs its own isolated AppHost graph - as `Test.FoundryLocal` boots the API host directly rather than joining the shared mesh - instead of flipping env vars on a shared graph. AppHost env vars are read at graph-construction time and baked in once the graph starts, so a shared, lazily-started graph cannot re-flip them per test (see [test-templates-aspire.md](../templates/test-templates-aspire.md) section Aspire fixture non-negotiables). External opt-in env vars are fine for selecting which lane runs in CI; they are not a substitute for an isolated graph in a self-contained test.

```csharp
// At bootstrap, whichever path wires IChatClient also records the provider name (no CLI, no
// model call); AddAiServices supplies the dev-stub and "none" fallbacks. See DI Registration + Aspire.
//   Azure host path:   services.AddSingleton(new AiProviderInfo("azure"));
//   SDK-direct local:  services.AddSingleton(new AiProviderInfo("local"));
//   dev-stub (opt-in):  services.TryAddSingleton(new AiProviderInfo("stub"));
//   no provider wired: services.TryAddSingleton(new AiProviderInfo("none"));

// GET /ai/status - honest, side-effect-free provider signal for tests and ops.
// isConfigured is provider-derived (a real model only): "stub" and "none" report false, so synthesized
// dev content is never mistaken for a model and the live smoke stays Inconclusive on stub.
group.MapGet("/status", (
    [FromServices] AiProviderInfo provider) =>
    Results.Ok(new { provider = provider.Name, isConfigured = provider.Name is "azure" or "local" }))
    .WithName("AiStatus");
```

### Agent Tests

Code-hosted agent tests must control tool use through request/options, not prompt wording. Add request flag such as `UseTools` (default `true`). No-tool smoke sets `UseTools=false` and maps to `ChatOptions.ToolMode = ChatToolMode.None`. Tool-calling tests set `UseTools=true`, use `ChatToolMode.Auto`, and bound the model call itself with a per-request `CancellationTokenSource.CancelAfter(...)` - the MSTest `[Timeout]` is a backstop only, since a local model can otherwise generate until the method timeout fires. Never rely on prompts like "do not call tools" as control flow.

**Bound generation deterministically.** Every structured or demo AI call - agent runs, seeded/demo content, live smokes - sets deterministic `ChatOptions` with at minimum `Temperature = 0` and a small `MaxOutputTokens`, so a local model cannot generate without end; the agent run path shows the concrete shape ([agent-template.md](../templates/agent-template.md)).

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
