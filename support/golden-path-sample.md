# Golden Path Sample

Use this sample as the canonical small scaffold when validating instruction changes. It is intentionally boring: one parent entity, one child entity, SQL, Aspire, API, no optional UI/functions.

The goal is not demo breadth. The goal is repeatable proof that the instructions still produce a buildable, testable, convention-compliant .NET/Aspire/Azure scaffold.

---

## Domain Prompt

```text
Scaffold a WorkBoard app for managing work projects and work items.
Projects have a name, description, status, and due date.
Work items belong to one project and have title, details, priority, status, due date, and completion date.
Users need CRUD and search for both entities.
Use row-level multi-tenancy.
No external APIs, no notifications, no UI, no Functions, no scheduler, no AI services.
```

---

## Expected Phase 1 Output

### `.scaffold/domain-specification.yaml`

```yaml
ProjectName: WorkBoard
ProjectDescription: Multi-tenant work tracking API
OrganizationName: Example
multiTenant: true
tenantIsolation: row-level
authProvider: EntraID
authScenario: enterprise
entities:
  - name: Project
    description: Work container owned by one tenant
    isTenantEntity: true
    properties:
      - name: Name
        kind: string
        required: true
      - name: Description
        kind: text
      - name: Status
        kind: enum
        required: true
        values: [Draft, Active, Completed, Archived]
      - name: DueDate
        kind: date
    children:
      - name: WorkItems
        entity: WorkItem
        relationship: one-to-many
        cascadeDelete: false
    rules:
      - name: ProjectNameRequired
        condition: Name is required and max 200 chars
  - name: WorkItem
    description: Trackable item of work under a project
    isTenantEntity: true
    properties:
      - name: ProjectId
        kind: identifier
        required: true
      - name: Title
        kind: string
        required: true
      - name: Details
        kind: text
      - name: Priority
        kind: enum
        required: true
        values: [Low, Normal, High, Critical]
      - name: Status
        kind: enum
        required: true
        values: [New, InProgress, Blocked, Done, Canceled]
      - name: DueDate
        kind: date
      - name: CompletedDate
        kind: date
    navigation:
      - name: Project
        entity: Project
        required: true
    rules:
      - name: CompletedDateRequiredWhenDone
        condition: CompletedDate is required when Status is Done
domainRules:
  - name: WorkItemBelongsToSameTenantAsProject
    appliesTo: [Project, WorkItem]
events: []
workflows: []
```

### `.scaffold/UBIQUITOUS-LANGUAGE.md`

```markdown
# Ubiquitous Language - WorkBoard

## Accepted Terms

| Term | Type | Meaning | Code/Naming Guidance |
|---|---|---|---|
| `Project` | aggregate | Tenant-owned work container. | Use `Project` in source names. |
| `WorkItem` | entity | Trackable item of work under a project. | Use `WorkItem`; avoid `Task`. |
| `Draft` | state | Project has not started. | Use as project status. |
| `Active` | state | Project is in active use. | Use as project status. |
| `Completed` | state | Project work is complete. | Use as project status. |
| `Archived` | state | Project is retained but inactive. | Use as project status. |
| `ProjectNameRequired` | policy | Project must have a usable name. | Use as domain rule name. |
| `GlobalAdmin` | role | Cross-tenant administrator. | Use for global admin role. |
| `EntraID` | external-system | Enterprise identity provider. | Use in auth config. |
| `enterprise` | auth scenario | Internal workforce auth scenario. | Use in domain spec. |

## Rejected Synonyms

| Rejected Term | Use Instead | Reason |
|---|---|---|
| `Task` | `WorkItem` | Avoid .NET type collision. |
```

### `.scaffold/DESIGN-DECISIONS.md`

```markdown
# Design Decisions - WorkBoard

## Decision Dependency Graph

D-001 --> D-002
D-001 --> D-003

## Decisions

| ID | Branch | Decision | Selected Option | Depends On | Status | Rationale | Affects |
|---|---|---|---|---|---|---|---|
| D-001 | Tenancy | Tenant model | row-level tenant isolation | none | confirmed | Simple shared schema for scaffold. | Phase 1, Phase 2 |
| D-002 | Auth | Auth provider | EntraID enterprise auth | D-001 | confirmed | Workforce SSO expected. | Phase 5e |
| D-003 | Naming | Work item term | WorkItem instead of Task | none | confirmed | Avoid .NET type collision. | All phases |
```

---

## Expected Phase 2 Output

```yaml
scaffoldMode: full
testingProfile: balanced
packageStrategy: feed
packagePrefix: EF
includeApi: true
includeGateway: false
includeFunctionApp: false
includeScheduler: false
includeUnoUI: false
includeBlazorUI: false
includeReactUI: false
includeNotifications: false
includeIaC: true
includeGitHubActions: false
includeAzd: false
includeAiServices: false
useAspire: true
database: AzureSQL
caching: FusionCache+Redis
includeKeyVault: false
deployTarget: ContainerApps
tenantIdType: Guid
customNugetFeeds:
  - https://nuget.pkg.github.com/{owner}/index.json
entities:
  - name: Project
    dataStore: sql
    properties:
      - name: Name
        type: string
        maxLength: 200
        required: true
      - name: Description
        type: string
        maxLength: 2000
      - name: Status
        type: ProjectStatus
        required: true
      - name: DueDate
        type: DateTimeOffset?
    children:
      - name: WorkItems
        entity: WorkItem
        relationship: one-to-many
  - name: WorkItem
    dataStore: sql
    properties:
      - name: ProjectId
        type: Guid
        required: true
      - name: Title
        type: string
        maxLength: 200
        required: true
      - name: Details
        type: string
        maxLength: 4000
      - name: Priority
        type: WorkItemPriority
        required: true
      - name: Status
        type: WorkItemStatus
        required: true
      - name: DueDate
        type: DateTimeOffset?
      - name: CompletedDate
        type: DateTimeOffset?
    navigation:
      - name: Project
        entity: Project
        required: true
        deleteRestrict: true
externalDependencyModes:
  sql: emulator
  redis: emulator
  serviceBus: no-op stub
  eventGrid: no-op stub
  keyVault: deployment-only
  blobStorage: no-op stub
  cosmosDb: no-op stub
  aiServices: deployment-only
```

---

## Focused AI/Aspire Schema Fixture

This is a schema-only fixture for high-churn Aspire and AI resource declarations. It is not the default golden-path app shape.

```yaml
scaffoldMode: full
testingProfile: comprehensive
packageStrategy: local
packagePrefix: WorkBoard
customNugetFeeds: []
localPackageLayers:
  - Domain
  - Domain.Contracts
  - Data
  - Data.Contracts
  - Common
  - Common.Contracts
includeApi: true
includeGateway: false
includeFunctionApp: false
includeScheduler: false
includeUnoUI: false
includeBlazorUI: false
includeReactUI: false
includeNotifications: false
includeIaC: true
includeGitHubActions: false
includeAzd: false
includeAiServices: true
useAspire: true
database: AzureSQL
caching: FusionCache+Redis
includeKeyVault: false
deployTarget: ContainerApps
tenantIdType: Guid
entities:
  - name: WorkItem
    dataStore: sql
    properties:
      - name: Title
        type: string
        maxLength: 200
        required: true
      - name: DueDate
        type: "DateTimeOffset?"
aspireResources:
  - name: foundry
    service: Microsoft Foundry
    appHostApi: AddFoundry
    localMode: sdk-direct-api-host    # temporary workaround; preferred RunAsFoundryLocal() broken (dotnet/aspire#12750)
    publishMode: provision
    connectionNames: [chat]
    docs: https://aspire.dev/integrations/azureai/
  - name: search
    service: Azure AI Search
    appHostApi: AddAzureSearch
    localMode: deployment-only
    publishMode: provision
    connectionNames: [Search]
    docs: https://aspire.dev/integrations/cloud/azure/azureai-search/
aiServices:
  foundry:
    projectName: workboard-ai
    lifecycle: local-or-provision
    localRuntimeMode: sdk-direct-api-host   # current local path; RunAsFoundryLocal is preferred-after-fix
    connectionName: chat
    models:
      - name: gpt-4o
        purpose: agent-reasoning
        deploymentName: gpt-4o
        localModel: Qwen2505b
      - name: text-embedding-3-small
        purpose: embedding
        deploymentName: embeddings
    agentHosting: code-hosted
  search:
    provider: AzureAISearch
    indexes:
      - name: workitems-index
        sourceEntity: WorkItem
    embeddingModel: text-embedding-3-small
    embeddingDimensions: 1536
    vectorizationStrategy: on-write
  agents:
    framework: AgentFramework
    agents:
      - name: WorkItemTriageAgent
        type: ChatClientAgent
        model: gpt-4o
        systemPrompt: WorkItemTriageAgent.system-prompt.txt
        tools: [SearchWorkItems]
        groundingSource: workitems-index
        humanInLoop: false
externalDependencyModes:
  sql: emulator
  redis: emulator
  keyVault: deployment-only
  aiServices: lazy-optional
```

---

## Validation Commands

Run these from the generated app root.

After Phases 1-3, developer reviews the YAML artifacts (`.scaffold/domain-specification.yaml`, `.scaffold/UBIQUITOUS-LANGUAGE.md`, `.scaffold/DESIGN-DECISIONS.md`, `.scaffold/resource-implementation.yaml`, `.scaffold/implementation-plan.md`) against their schemas in `ai/`.

After Phase 4:

```powershell
dotnet restore
dotnet build
```

After the final enabled Phase 5 sub-phase:

```powershell
dotnet restore
dotnet build
dotnet test
```

Then walk through `support/final-scaffold-checklist.md`.

---

## Expected Final Shape

- `Project` and `WorkItem` have complete domain models, EF configurations, repositories, DTOs, mappers, services, endpoints, builders, service tests, and endpoint tests.
- Shared base types live in `<packagePrefix>.*` only (feed packages and/or `src/Packages/<packagePrefix>.*` projects per `packageStrategy`), never reimplemented in application/domain/host layers.
- `Directory.Packages.props` owns all NuGet versions (feed-supplied `<packagePrefix>.*` packages plus transitive deps).
- For `packageStrategy: feed` or `hybrid`: `nuget.config` maps `<packagePrefix>.*` to the private feed and `dotnet-ef` to `nuget.org`. For `local`: `nuget.config` only needs `nuget.org` (or may be absent).
- App starts through Aspire and API health returns 200.
- No `NotImplementedException` remains in generated source, except inside the scaffold-skipped surface allowed by `support/final-scaffold-checklist.md` (`NoOp*` fallback stubs and base-type overrides reachable only through them).
