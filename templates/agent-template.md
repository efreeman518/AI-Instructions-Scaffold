# Agent Template

Use this only when search alone is not enough and a single model needs to choose among a few bounded application-service tools. Default to one `ChatClientAgent`. Add middleware, agent-to-agent composition, or a server-hosted Foundry agent only after the simple path is proven insufficient.

This template is self-contained. Do not load `service-template.md` just to confirm the application-service contract for `GetAsync(...)`.

## Code-Hosted vs Server-Hosted Agents

- **Code-hosted (`ChatClientAgent`) - default.** The agent runs in your process over the injected `IChatClient`. Works with every Foundry lifecycle mode (Local / provision-new / existing) and boots offline as a no-op. This template builds this shape.
- **Server-hosted Foundry agent - escalation, Azure-only.** Either modeled in the AppHost (`project.AddPromptAgent(...)`, always deploys to Azure even under `aspire run`) or created in the portal/IaC and consumed by the client SDK. The application-facing `I{Agent}Agent` contract is identical because both produce a `Microsoft.Agents.AI.AIAgent`; only construction differs:

```csharp
// Server-hosted: connect to a Foundry project and bind to a pre-existing agent by name,
// or create a code-first responses agent. Endpoint comes from AiServices:FoundryProjectEndpoint
// (or the Aspire-injected PROJ_URI). Requires Azure.AI.Projects + Microsoft.Agents.AI.Foundry.
var project = new AIProjectClient(new Uri(projectEndpoint), new DefaultAzureCredential());
var record = await project.AgentAdministrationClient.GetAgentAsync(agentName);
AIAgent agent = project.AsAIAgent(record);   // or: project.AsAIAgent(model, name, instructions)
```

See [../skills/ai-integration.md](../skills/ai-integration.md) -> *Foundry Projects and Server-Hosted Agents*. The rest of this template covers the default code-hosted shape.

## Default Shape

- One interface
- One service
- A small tool set that delegates to existing application services
- Prompt files in `Prompts/`
- One DI registration
- One API endpoint only if the slice exposes chat directly

## Agent Interface

```csharp
namespace {Org}.{Project}.Infrastructure.AI.Agents;

using Microsoft.Agents.AI;

public interface I{Agent}Agent
{
    Task<AgentResponse> RunAsync(string userMessage, AgentSession? session = null, CancellationToken ct = default);

    Task<AgentSession> CreateSessionAsync(CancellationToken ct = default);
}
```

## Expected Application-Service Contract

The tool examples assume the existing application service already exposes the standard read method below. Keep the agent tool aligned to this signature.

```csharp
public interface I{Entity}Service
{
    Task<Result<DefaultResponse<{Entity}Dto>>> GetAsync(Guid id, CancellationToken ct = default);
}
```

## Default Agent Service

```csharp
namespace {Org}.{Project}.Infrastructure.AI.Agents;

using System.ComponentModel;
using Microsoft.Agents.AI;
using Microsoft.Extensions.AI;

internal sealed class {Agent}AgentService : I{Agent}Agent
{
    private readonly AIAgent _agent;

    // Inject the IChatClient registered by AddAzureChatCompletionsClient("chat").AddChatClient().
    // The model/deployment is bound at that registration, not here. When no chat client is wired,
    // AddAiServices registers a no-op IChatClient, so this service still constructs and boots offline.
    public {Agent}AgentService(
        IChatClient chatClient,
        I{Entity}Service entityService)
    {
        var systemPrompt = EmbeddedResource.Read("Prompts.{Agent}.system-prompt.txt");

        _agent = new ChatClientAgent(
            chatClient,
            instructions: systemPrompt,
            name: "{Agent}",
            tools:
            [
                AIFunctionFactory.Create(
                    async ([Description("The {entity} ID (GUID)")] string id, CancellationToken ct) =>
                        await entityService.GetAsync(Guid.Parse(id), ct),
                    "Get{Entity}",
                    "Get a {entity} by ID")
            ]);
    }

    public async Task<AgentResponse> RunAsync(
        string userMessage, AgentSession? session = null, CancellationToken ct = default)
    {
        session ??= await _agent.CreateSessionAsync();
        return await _agent.RunAsync(userMessage, session, cancellationToken: ct);
    }

    public async Task<AgentSession> CreateSessionAsync(CancellationToken ct = default)
    {
        return await _agent.CreateSessionAsync();
    }
}
```

## Add Search Only If Needed

If the agent must ground answers in indexed data, add one search tool that delegates to the search service.

```csharp
AIFunctionFactory.Create(
    async ([Description("The search query")] string query, CancellationToken ct) =>
        await searchService.SearchAsync(query, SearchMode.Semantic, ct),
    "Search{Entity}s",
    "Search for {entity}s by natural language query")
```

Keep the first pass narrow. Do not register tools that bypass application services or duplicate domain logic.

## Optional Tool Helper

```csharp
namespace {Org}.{Project}.Infrastructure.AI.Agents.Tools;

using System.ComponentModel;

internal static class {Agent}Tools
{
    [Description("Search for {entity}s matching a natural language query")]
    public static async Task<object> Search{Entity}s(
        [Description("The search query")] string query,
        I{Project}SearchService searchService,
        CancellationToken ct)
    {
        var results = await searchService.SearchAsync(query, SearchMode.Semantic, ct);
        return results.Select(r => new { r.Id, r.{Property1}, r.Score });
    }

    [Description("Get details of a specific {entity}")]
    public static async Task<object?> Get{Entity}(
        [Description("The {entity} ID (GUID)")] string id,
        I{Entity}Service entityService,
        CancellationToken ct)
    {
        return await entityService.GetAsync(Guid.Parse(id), ct);
    }
}
```

## Prompt File

Create `Prompts/{Agent}.system-prompt.txt`:

```text
You are {Agent}, an AI assistant for {Project}.

## Role
{Describe the bounded business task this agent owns}

## Rules
- Use tools only when they materially improve the answer
- Cite IDs or other traceable references from tool results
- Respect tenant and authorization boundaries
- If available tools do not support the request, say so clearly
```

## Escalate Only If Needed

- Middleware: add only for a concrete cross-cutting need such as auth propagation, redaction, or audit logging.
- Agent-as-tool composition: add only when another agent owns a distinct bounded capability that should stay isolated.
- Server-hosted Foundry agent: switch only when hosted memory, hosted tools, or portal/IaC-managed agent definitions are real requirements (see *Code-Hosted vs Server-Hosted Agents* above).

## DI Registration

```csharp
services.AddScoped<I{Agent}Agent, {Agent}AgentService>();
```

## API Endpoint

```csharp
group.MapPost("/agent/{agent-route}/chat", async (
    [FromBody] AgentChatRequest request,
    I{Agent}Agent agent,
    CancellationToken ct) =>
{
    var session = await agent.CreateSessionAsync(ct);
    var response = await agent.RunAsync(request.Message, session, ct);

    return TypedResults.Ok(new AgentChatResponse
    {
        Messages = response.Messages.Select(m => m.Text).ToList(),
        SessionId = session.ToString()
    });
})
.WithName("Chat{Agent}")
.WithSummary("Send a message to the {Agent} agent");
```
