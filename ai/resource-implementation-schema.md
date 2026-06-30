# Resource Implementation Schema (Phase 2 Output)

Maps domain constructs from [domain-specification-schema.md](domain-specification-schema.md) to concrete Aspire/Azure resources, datatypes, and infrastructure.

When `useAspire: true`, resource selection must use the current Aspire integration catalog before declaring a dependency unsupported or inventing local wiring. Start with [skills/aspire.md](../skills/aspire.md) section Official Integration Catalog Awareness, then consult the linked Aspire docs for the selected service.

**JSON Schema:** [`schemas/resource-implementation.schema.json`](../schemas/resource-implementation.schema.json) - use for programmatic validation of `.scaffold/resource-implementation.yaml`.

**Prerequisite:** Complete Phase 1 domain definition first, including `.scaffold/domain-specification.yaml`, `.scaffold/UBIQUITOUS-LANGUAGE.md`, and `.scaffold/DESIGN-DECISIONS.md`.

## Output Contract

Write Phase 2 output to `.scaffold/resource-implementation.yaml` in the target project (create the `.scaffold/` directory at project root if absent). Do not write project artifacts under `.instructions/`; that directory is the installed runtime instruction payload.

## Canonical Defaults (Single Source of Truth)

All defaults used across this instruction set must reference this section. If another file disagrees, this section wins.

```yaml
scaffoldMode: full
testingProfile: balanced
functionProfile: starter      # starter | full
unoProfile: starter           # starter | full

packageStrategy: local        # feed | local | hybrid
packagePrefix: ""             # required; e.g. "EF", "Contoso", "AcmePay"
customNugetFeeds: []          # one or more URLs when feed/hybrid; must be [] when local
localPackageLayers: [Domain, Domain.Contracts, Data, Data.Contracts, Common, Common.Contracts]  # >=1 required when local or hybrid; must be [] when feed; add CQRS when applicationStyle warrants. Generated under src/Packages/<Prefix>.*

applicationStyle: service     # service | cqrs | switch
repositoryContractStyle: hybrid  # per-entity | hybrid | generic-only

includeApi: true
includeGateway: false
includeFunctionApp: false
includeScheduler: false
includeUnoUI: false
includeBlazorUI: false
includeReactUI: false
includeNotifications: false
includeFlowEngine: false
flowEngineDbStrategy: same-db-separate-schema  # same-db-separate-schema | separate-db

includeIaC: true
includeGitHubActions: false
includeAzd: false
includeAiServices: false
useAspire: true
```

## Scaffold Configuration

Use the canonical defaults above as the complete baseline. The reference tables below explain valid values and when to override them; do not duplicate a second defaults block here.

### Package Strategy Reference

| `packageStrategy` | `customNugetFeeds` | `localPackageLayers` | Effect |
|---|---|---|---|
| `feed` | one or more URLs | `[]` | Feed supplies the full base-contract set. No `src/Packages/` folder. |
| `local` | `[]` | full layer list | All base contracts generated as packable projects in `src/Packages/<Prefix>.*`. |
| `hybrid` | one or more URLs | layers the feed lacks | Feed supplies some layers; missing layers generated locally under the **same** prefix so they can later be pushed to the feed without renaming. |

Canonical layer names (must match `support/ef-packages-reference.md`): `Domain`, `Domain.Contracts`, `Data`, `Data.Contracts`, `Common`, `Common.Contracts`, `CQRS`. Add others (e.g., `Messaging.Contracts`, `Secrets`) when the reference file lists them.

### Application Style

| `applicationStyle` | Effect |
|---|---|
| `service` | Generate application services and service-backed Minimal API endpoints only. |
| `cqrs` | Generate CQRS request/handler pairs and CQRS-backed Minimal API endpoints only. |
| `switch` | Generate both service and CQRS endpoint sets. Runtime config `Application:Style` selects `Service` or `Cqrs`; `<APP>_APPLICATION_STYLE` may override host/test runs. |

When `applicationStyle` is `cqrs` or `switch`, include `CQRS` in the feed/local package layer set. In `packageStrategy: local`, generate `src/Packages/<packagePrefix>.CQRS` and consume it via `<ProjectReference>`; do not add a private feed.

### Repository Contract Style

`repositoryContractStyle` controls whether every entity gets a bespoke `I{Entity}RepositoryTrxn` / `I{Entity}RepositoryQuery` pair, or whether CRUD-only / append-only / join entities share a generic repository pair. Default: `hybrid`.

| `repositoryContractStyle` | Effect |
|---|---|
| `per-entity` | One `I{Entity}RepositoryTrxn` + `I{Entity}RepositoryQuery` per entity, registered individually. Explicit but verbose - every entity carries two interfaces even when they only re-expose generic CRUD under a typed name. |
| `hybrid` (default) | Generic open-generic pair `IRepositoryTrxn<TEntity, TId>` / `IRepositoryQuery<TEntity, TId>` for entities with **no bespoke read/write logic**; a bespoke `I{Entity}Repository*` only where read/write logic earns it. A bespoke read contract **extends** `IRepositoryQuery<TEntity, TId>` so generic get/list stay inherited and only the bespoke method (e.g. paged `Search`) is added. |
| `generic-only` | Never emit per-entity repository interfaces. Entities resolve the generic pair; bespoke reads are expressed as CQRS query objects / specifications under `Features/{Entity}` (natural fit when `applicationStyle: cqrs`). |

**An interface earns its place only when it adds logic beyond `RepositoryBase`.** Classify each entity in Phase 4:

- **Generic-coverable** (use the generic pair): join entities, append-only logs, simple CRUD - the repository needs only get-by-id, list-by-predicate, and the generic CRUD already on `RepositoryBase` / `IRepositoryBase`.
- **Bespoke** (emit a per-aggregate contract): multi-include aggregate loads, child-collection sync (`UpdateFromDto`), paged/projected `Search`, polymorphic or hierarchy queries, multi-key lookups.

A single aggregate may split: a pure-CRUD write side uses `IRepositoryTrxn<TEntity, TId>` while a search-bearing read side keeps a bespoke `I{Entity}RepositoryQuery : IRepositoryQuery<TEntity, TId>`. The generic pair is backed by real shared-package types (`IRepositoryTrxn<TEntity, TId>` / `IRepositoryQuery<TEntity, TId>` over `RepositoryTrxn` / `RepositoryQuery`) - see [../support/ef-packages-reference.md](../support/ef-packages-reference.md) and the wiring in [../templates/repository-template.md](../templates/repository-template.md). For `cqrs`, prefer query objects/specs under `Features/{Entity}` over adding repository query methods.

> **`repositoryContractStyle` never overrides aggregate roots with owned children (GR-15).** An aggregate root that owns child collections (it needs `Get{Root}Async(includeChildren)` + `UpdateFromDto` graph sync) **always** keeps a bespoke `I{Root}RepositoryTrxn` + `{Root}RepositoryTrxn` + `{Root}Updater`, **even under `generic-only`**. This is not a query-complexity judgment - it is structural: the include-load + child graph-sync can only live on a bespoke Trxn repo, and because the application/CQRS layer must not depend on Infrastructure (enforced by the `ApplicationCqrs_does_not_depend_on_Infrastructure` architecture test), the `I{Root}RepositoryTrxn` interface in `Application.Contracts/Repositories` is the only clean way to expose include-load + graph-sync to handlers. Dropping it forces child writes up into the application layer (the anemic-aggregate anti-pattern). A `generic-only` / "drop per-entity repos" directive applies to leaf/CRUD/log/join entities only. Phase-4 classification: an entity is **bespoke** if it is an aggregate root with owned children, full stop - regardless of query complexity.

## Decision Dependency Inputs

Before choosing resources, read `.scaffold/DESIGN-DECISIONS.md` and resolve any parent decisions that affect resource mapping:

- Tenant model before partition keys, schemas, databases, route shape, or query filters.
- Entity ownership before relationship mapping, cascade behavior, store selection, and repository order.
- Lifecycle/events before messaging channels, scheduled jobs, projections, notifications, or AI hooks.
- Compliance classification before retention, encryption, audit storage, and private endpoint choices.
- External dependency mode before local emulator/no-op/lazy-optional wiring.

If a resource choice changes Phase 1 language or ownership, reopen Phase 1 artifacts before finalizing `.scaffold/resource-implementation.yaml`.

## Policy Inputs (Optional)

```yaml
moneyCalculationPolicy:
  roundingMode: MidpointRounding.ToEven
  currencyScaleMap:
    USD: 2
  operationOrder: [proration, discount, tax]

timeBoundaryPolicy:
  canonicalTimeZone: UTC
  periodBoundaryMode: [start-inclusive, end-exclusive]
  daylightSavingHandling: normalize-to-utc

entitlementPolicy:
  sourcePriority: [Tier, Purchase, Promo]
  conflictResolution: highest-priority-wins
  revokeBehavior: source-scoped-revocation
```

### Profile Inputs

| Input | Default | Values | Applies when |
|---|---|---|---|
| `scaffoldMode` | `full` | `full`, `lite`, `api-only` | always |
| `testingProfile` | `balanced` | `minimal`, `balanced`, `comprehensive` | always |
| `functionProfile` | `starter` | `starter`, `full` | `includeFunctionApp: true` |
| `unoProfile` | `starter` | `starter`, `full` | `includeUnoUI: true` |

## Entity-to-Store Mapping

Assign each entity a data store and define implementation-level property details.

For `ReasonCode`-style fields, prefer enum for stable fixed sets and catalog entities for evolving/localized sets.

```yaml
entities:
  - name: TodoItem
    dataStore: sql                          # sql | cosmosdb | table | blob
    partitionKeyProperty: TenantId          # cosmosdb/table only
    throughputProfile: standard             # optional (e.g., low|standard|high|burst)
    retentionPolicy: keep-forever           # optional (e.g., 30d|180d|archive-after-30d)
    replayWindow: "PT24H"                  # optional for event-driven entities
    properties:
      - { name: Title, type: string, maxLength: 200, required: true }
      - { name: Description, type: string, maxLength: 2000, required: false }
      - { name: DueDate, type: "DateTimeOffset?", required: false }
      - { name: Priority, type: enum }
      - { name: Status, type: flags_enum }
      - { name: Amount, type: decimal, precision: 10, scale: 4 }
    children:
      - { name: Tags, entity: Tag, relationship: many-to-many, joinEntity: TodoItemTag }
    navigation:
      - { name: Category, entity: Category, required: false, deleteRestrict: true }
    embedded:                               # cosmosdb only
      - name: Schedule
        properties:
          - { name: StartDate, type: "DateTimeOffset?" }
```

Quote nullable type tokens (`type: "DateTimeOffset?"`) inside YAML flow mappings. A bare trailing `?` is a YAML complex-key indicator and fails `yaml.safe_load`.

### Compliance Metadata (Optional)

```yaml
compliance:
  defaultClassification: Internal
  entities:
    - name: PatientProfile
      dataClassification: PHI
      retention: "P7Y"
      encryptionRequired: true
      auditRequired: true
      properties:
        - { name: DateOfBirth, dataClassification: PII }
```

### Data Store Quick Rules

Binary content -> `blob`. Relational + complex queries -> `sql`. Simple key lookups -> `table`. Document aggregates -> `cosmosdb`. Uncertain -> default to `sql`. For detailed selection guidance, see [skills/data-persistence.md](../skills/data-persistence.md) and [skills/azure-data-storage.md](../skills/azure-data-storage.md).

If a non-default database/search/vector store is selected because the Aspire catalog supports it locally (for example PostgreSQL, MongoDB, Qdrant, Meilisearch, Elasticsearch, or ClickHouse), record both the domain reason and the Aspire integration URL. Do not replace SQL as the source of truth with a search/vector service unless `.scaffold/DESIGN-DECISIONS.md` explicitly records that choice.

### SQL Type Defaults

| Domain kind | SQL type | Notes |
|---|---|---|
| `string` | `nvarchar(N)` | always specify maxLength |
| `text` | `nvarchar(max)` | large text |
| `number` | `int` or `long` | |
| `money` | `decimal(P,S)` | always specify precision+scale |
| `date` | `datetime2` or `DateTimeOffset` | |
| `boolean` | `bit` | |
| `identifier` | `Guid` or `int` | |
| `enum` | `int` | stored as int, C# enum |
| `flags_enum` | `int` | bitwise flags |

## Relationship Configuration

Phase 1 defines the business relationship. Phase 2 adds EF configuration details.

### One-to-many
```csharp
builder.HasMany(e => e.Comments)
    .WithOne()
    .HasForeignKey("TodoItemId")
    .OnDelete(DeleteBehavior.Cascade);
```

### Many-to-many (explicit join)
```csharp
builder.HasKey(e => new { e.TodoItemId, e.TagId });
```

### Self-referencing
```csharp
builder.HasOne(e => e.Parent)
    .WithMany(e => e.Children)
    .HasForeignKey(e => e.ParentId)
    .OnDelete(DeleteBehavior.Restrict);
```

### Polymorphic join
```csharp
builder.Property(e => e.EntityType).HasConversion<string>().HasMaxLength(50).IsRequired();
builder.Property(e => e.EntityId).IsRequired();
builder.HasIndex(e => new { e.EntityType, e.EntityId });
```

> **CRITICAL - No navigation collections on parent entities.** Parent entities that participate in a polymorphic join (e.g., `TaskItem` and `Comment` both owning `Attachment`) must NOT declare `ICollection<PolymorphicChild>` navigation properties. EF convention-generates a real FK from each navigation, creating multiple conflicting FK constraints on the shared `EntityId`/`OwnerId` column. The polymorphic child references its owner via `EntityType` + `EntityId` properties only - no EF relationship is configured. Query polymorphic children explicitly: `db.Attachments.Where(a => a.OwnerType == type && a.OwnerId == id)`.

## Infrastructure Resources

### Aspire Integration Selection

When `useAspire: true`, map every external dependency through the Aspire catalog:

```yaml
aspireResources:
  - name: sql
    service: Azure SQL Database
    appHostApi: AddAzureSqlServer
    localMode: RunAsContainer
    publishMode: provision
    connectionNames: [{Project}DbContextTrxn, {Project}DbContextQuery]
    docs: https://aspire.dev/integrations/cloud/azure/azuresql/
  - name: servicebus
    service: Azure Service Bus
    appHostApi: AddAzureServiceBus
    localMode: RunAsEmulator
    publishMode: provision
    connectionNames: [ServiceBus1]
    docs: https://aspire.dev/integrations/cloud/azure/azureservicebus/
```

Use this optional `aspireResources` block when the resource map includes anything beyond the baseline SQL/Redis/Storage set, or when a service has a non-obvious local mode. The block is documentation for later phases; it does not replace the concrete first-class fields below.

Selection rules:

- Azure-managed publish target: prefer `AddAzure*` plus `RunAsEmulator`, `RunAsContainer`, `RunAsFoundryLocal`, or existing-resource APIs as documented.
- Local-only dependency: use the service-specific non-Azure `Add*` integration.
- Cloud-only dependency: declare `deployment-only` or `lazy-optional` plus no-op stubs so the scaffold still boots locally.
- AI Search, Foundry Agent Service, Key Vault, platform resources, and observability sinks must not block local scaffold completion unless Phase 2 explicitly requires a live endpoint.

### Database & Storage

| Input | Default | Values |
|---|---|---|
| `database` | `AzureSQL` | `AzureSQL`, `SQLServer` |
| `caching` | `FusionCache+Redis` | `FusionCache+Redis`, `DistributedMemory`, `None` |
| `includeKeyVault` | `false` | |

### Messaging

```yaml
messagingProviders:
  - { name: ServiceBus, type: AzureServiceBus }
messagingChannels:
  - { name: DomainEvents, provider: ServiceBus, pattern: topic }
messagingSemantics:
  - { channel: DomainEvents, deliveryMode: at-least-once, outboxEnabled: true, idempotencyKey: MessageId, deduplicationWindow: "PT1H" }
```

Options: Azure Service Bus, Event Grid, Event Hubs. See [skills/messaging.md](../skills/messaging.md).

### Hosting

| Input | Default | Values |
|---|---|---|
| `deployTarget` | `ContainerApps` | `ContainerApps`, `AppService`, `AKS` |
| `useAspire` | `true` | local orchestration |
| `includeApi` | `true` | |
| `includeGateway` | `false` | |
| `includeFunctionApp` | `false` | |
| `includeScheduler` | `false` | |
| `includeUnoUI` | `false` | |
| `includeBlazorUI` | `false` | |
| `includeReactUI` | `false` | |
| `applicationStyle` | `service` | `service`, `cqrs`, `switch` |
| `repositoryContractStyle` | `hybrid` | `per-entity`, `hybrid`, `generic-only` (see [Repository Contract Style](#repository-contract-style)) |
| `includeNotifications` | `false` | |
| `includeFlowEngine` | `false` | Enables `EF.FlowEngine` (durable JSON workflow orchestration). Generates a dedicated FE DbContext + registration partial + workflow seeding + admin endpoints + test project. See [../skills/flowengine.md](../skills/flowengine.md). |
| `flowEngineDbStrategy` | `same-db-separate-schema` | `same-db-separate-schema` (Variant A - preserves atomic outbox; default), `separate-db` (Variant B/C - outbox best-effort). See [../support/ef-packages-reference.md](../support/ef-packages-reference.md) section FlowEngine Data-Layout Variants. |

### UI Hosting (if applicable)

| Platform | Hosting |
|---|---|
| Mobile (iOS/Android) | App store distribution |
| Web (WASM / SPA) | Azure Static Web Apps / Container Apps |
| Desktop (Windows) | MSIX / direct distribution |

### Security

| Input | Default |
|---|---|
| `gatewayAuth` | `EntraExternal` |
| `apiAuth` | `EntraID` |
| `tokenRelay` | `true` |
| `tenantIdType` | `Guid` |

### IaC / Pipeline

| Input | Default |
|---|---|
| `includeIaC` | `true` |
| `azureRegion` | `eastus2` |
| `iacEnvironments` | `[dev, staging, prod]` |
| `includeGitHubActions` | `false` |
| `includeAzd` | `false` |
| `usePrivateEndpoints` | `false` |

### AI Services

Define AI integration resources when `includeAiServices: true`. Maps Phase 1 `aiCapabilities` to concrete Azure resources and code frameworks.

```yaml
aiServices:
  # --- Microsoft Foundry ---
  foundry:
    projectName: ""                    # Microsoft Foundry project name (only when using a project + agents)
    lifecycle: local-or-provision      # local-or-provision | existing
                                       #   local-or-provision: runs a model on-device in run mode (no Azure) via
                                       #     the localRuntimeMode below, and provisions a new Azure account on publish.
                                       #   existing: RunAsExisting/PublishAsExisting/AsExisting against an
                                       #     already-provisioned account; deployment names must already exist there.
    localRuntimeMode: sdk-direct-api-host  # RunAsFoundryLocal (preferred, after Aspire fix) | sdk-direct-api-host (current).
                                       #   Why + wiring + migration: skills/ai-integration.md (canonical owner). sdk-direct-api-host
                                       #   wires no chat resource (no ConnectionStrings:chat); no effect on the Azure/publish path.
    resourceName: ""                   # existing only: Azure Foundry account name (RunAsExisting/AsExisting param)
    resourceGroup: ""                  # existing only: resource group of the existing account
    connectionName: chat               # Aspire deployment resource name; clients bind AddAzureChatCompletionsClient(<connectionName>)
    models:
      - name: gpt-4o
        purpose: agent-reasoning       # agent-reasoning | embedding | completion
        deploymentName: gpt-4o-deploy
        localModel: qwen2.5-0.5b       # sdk-direct (current): Foundry Local catalog alias.
        localWebUrl: http://127.0.0.1:52415 # sdk-direct (current): local OpenAI-compatible bind URL.
                                       #   future RunAsFoundryLocal path uses the FoundryModel.Local.Qwen2505b constant.
      - name: text-embedding-3-small
        purpose: embedding
        deploymentName: embedding-deploy
    agentHosting: code-hosted          # code-hosted | prompt-agent | pre-existing
                                       #   code-hosted: ChatClientAgent over the injected IChatClient (default, offline-capable).
                                       #   prompt-agent: Aspire AddProject + AddPromptAgent (Azure-only, deploys even on aspire run).
                                       #   pre-existing: agent created in portal/IaC, consumed via AIProjectClient.AsAIAgent(...).
    projectEndpoint: ""                # prompt-agent / pre-existing only: project URI (or Aspire-injected PROJ_URI)

  # --- Semantic Search ---
  search:
    provider: AzureAISearch            # AzureAISearch | None
    indexes:
      - name: products-index
        sourceEntity: Product
        fields:
          - { name: Name, type: searchable, analyzer: standard }
          - { name: Description, type: searchable, analyzer: standard }
          - { name: DescriptionVector, type: vector, dimensions: 1536, algorithm: hnsw }
        searchMode: hybrid             # keyword | vector | hybrid
        semanticConfig: true
    embeddingModel: text-embedding-3-small
    embeddingDimensions: 1536
    vectorizationStrategy: on-write    # on-write | batch | change-feed

  # --- Agent Framework ---
  agents:
    framework: AgentFramework          # AgentFramework (Microsoft Agent Framework)
    agents:
      - name: SupportTriageAgent
        type: ChatClientAgent          # ChatClientAgent (code-hosted) | FoundryAgent (prompt-agent/pre-existing, Azure-only) | CustomAgent
        model: gpt-4o
        systemPrompt: "You are a support triage agent..."
        tools: [SearchKnowledgeBase, GetTicketHistory, ClassifyUrgency]
        groundingSource: products-index  # optional: search index for RAG
        humanInLoop: false
      - name: ContentSummaryAgent
        type: ChatClientAgent
        model: gpt-4o
        tools: [SummarizeText]

    # --- Multi-Agent Workflow (if needed) ---
    workflow:
      enabled: false
      pattern: sequential              # sequential | concurrent | supervisory | handoff
      agents: [SupportTriageAgent, EscalationAgent]
      checkpointing: false             # persist workflow state for long-running processes
```

For AI services selection guidance and agent framework concepts, see [skills/ai-integration.md](../skills/ai-integration.md).

### Testing

| Input | Default |
|---|---|
| `testingProfile` | `balanced` |
| `includeArchitectureTests` | `false` |
| `includeE2ETests` | `false` |
| `includeLoadTests` | `false` |
| `includeBenchmarkTests` | `false` |
| `includeMutationTests` | `false` |
| `includeAspireTests` | `false` (derived: `comprehensive` enables) |
| `includePlaywrightUITests` | `false` (derived: `comprehensive` enables) |
| `includeMobileTests` | `false` (needs `includeUnoUI`; generate in balanced+ when Uno is in scope) |

These booleans control **generation** (whether the test project is scaffolded), and follow the early capability pick: the UI/host flags chosen in Question 2 plus `testingProfile` decide which tiers exist. The [Capability-Gated Test Tiers](../skills/testing.md#capability-gated-test-tiers-the-early-decision-drives-the-rest) table in `skills/testing.md` is the single source of truth for the mapping (e.g. UI model/presentation coverage generates `Test.UI`; `includeMobileTests`/`WasmUI` require `includeUnoUI`; `Test.Aspire` requires `useAspire`; `api-only` -> none). For a **generated** tier, runtime is default-on with a local false-only opt-out (`{APP}_RUN_ASPIRE_TESTS`, `{APP}_WASM_TESTS_ENABLED`) and self-marks `Inconclusive` when prerequisites are missing - except `Test.Mobile`, which is opt-IN (default off) because its emulator/Appium/APK preconditions are too heavy for the canonical lane. The generated `src/Test/Test.Mobile/run-mobile-tests.ps1` sets `{APP}_MOBILE_TESTS_ENABLED=true`, owns Android build/emulator/Appium readiness, and fails fast when mobile prerequisites are broken. `includeE2ETests` is `Test.E2E` (WebApplicationFactory + Testcontainers SQL, multi-endpoint workflows) - not the browser tier; declare headless UI model/presentation tests in `Test.UI` with `UI`/`Presentation`, DOM-browser UI tests with `includePlaywrightUITests` (`Test.PlaywrightUI`, category `PlaywrightUI`), Skia-canvas Uno tests as the `WasmUI` category in the same project, and the full-mesh tier with `includeAspireTests` (`Test.Aspire`, category `Aspire`).

### Optional Integrations

- `externalApis` - external API integrations ([skills/external-api.md](../skills/external-api.md))
- `includeGrpc` - gRPC services
- `seedData` - initial data seeding

#### Notifications

```yaml
notifications:
  - name: TaskOverdueNotification
    trigger: TodoItemOverdueSuspected          # domain event name
    channel: email                              # email | push | sms | in-app
    template: "task-overdue"                    # template identifier
    recipients: [AssignedMember, TeamLead]
  - name: TaskCompletedNotification
    trigger: TodoItemCompleted
    channel: in-app
    template: "task-completed"
    recipients: [Creator]
```

See [skills/notifications.md](../skills/notifications.md).

#### Scheduled Jobs

```yaml
scheduledJobs:
  - name: OverdueTaskCheck
    schedule: "0 */6 * * *"                     # cron expression
    description: "Check for overdue tasks and raise TodoItemOverdueSuspected events"
    targetService: TodoItemService
    method: CheckOverdueItemsAsync
  - name: DailyDigest
    schedule: "0 8 * * 1-5"
    description: "Send daily task summary to team leads"
    targetService: NotificationService
    method: SendDailyDigestAsync
```

#### Function Definitions

```yaml
functionDefinitions:
  - name: ProcessTaskEvent
    trigger: serviceBusTopic                    # serviceBusTopic | httpTrigger | timerTrigger | blobTrigger | queueTrigger
    channel: DomainEvents                       # messaging channel name (if topic/queue trigger)
    subscription: task-events                   # subscription name (if topic trigger)
    description: "Process domain events for task lifecycle changes"
  - name: GenerateReport
    trigger: timerTrigger
    schedule: "0 0 1 * *"
    description: "Generate monthly task completion report"
```

### High-Ingest Operational Controls (Optional)

- `throughputProfile` - expected RU/TU profile and autoscale behavior per entity/channel
- `retentionPolicy` - TTL/archival expectations for time-series or audit data
- `replayWindow` - expected replay/backfill window for event-driven processing

### Ingestion Semantics (Optional)

```yaml
ingestionSemantics:
  eventTimePolicy: event-time
  orderingExpectation: per-partition-ordered
  allowedLateness: "PT10M"
  watermarkStrategy: fixed-lag
  outOfOrderHandling: reconcile-window
```

---

## External Dependency Scaffold Modes

**Declare a scaffold mode for every external dependency before Phase 3.** This locks the local-run strategy at design time and prevents inconsistent stub generation in Phase 4 (contract scaffolding) and Phase 5 (implementation).

Valid modes:

| Mode | Meaning |
|---|---|
| `emulator` | Aspire-hosted or local emulator available (SQL, Redis, Azure Storage Emulator, Service Bus emulator) |
| `lazy-optional` | Config-driven; service activates only when config section is present/non-empty; absent = no-op passthrough |
| `no-op stub` | Compile-time stub satisfies the interface and returns safe defaults; no cloud call made |
| `deployment-only` | Live integration deferred to deployment; a no-op stub must still be generated so the solution compiles locally |

```yaml
externalDependencyModes:
  sql: emulator                   # emulator | deployment-only
  redis: emulator                 # emulator | lazy-optional | deployment-only
  serviceBus: no-op stub          # emulator | no-op stub | deployment-only
  eventGrid: no-op stub
  keyVault: lazy-optional
  blobStorage: emulator
  cosmosDb: emulator
  aiServices: lazy-optional       # Foundry Local in run mode, or Azure when configured/published; no-op IChatClient when neither is wired. AI Search stays deployment-only.
  externalApis:
    - name: PaymentGateway
      mode: no-op stub
    - name: IdentityProvider
      mode: deployment-only
```

> **Rule:** Every `deployment-only` entry requires a `no-op stub` generated in Phase 5 and a blocker recorded in `HANDOFF.md`. The scaffold is not complete until the solution compiles and boots without any manual cloud setup.

---

## Discovery Conversation Pattern

Work through these in order during Phase 2. **Question 1 is asked first and must be resolved before any other Phase 2 work** - downstream gates, pre-flight, and Phase 4 scaffolding all branch on the answer.

1. **Package strategy & prefix** - Do you have private NuGet feed(s) for shared/base packages (e.g., entity bases, repository bases, request context, results, paged response, specifications, messaging interfaces)?
   - **Yes (`feed`)** - supply feed URL(s) and the package prefix (e.g., `EF.*`, `Contoso.*`). Then walk the layer table in [`../support/ef-packages-reference.md`](../support/ef-packages-reference.md) and confirm the feed provides every layer. If any layers are missing, the strategy is promoted to **`hybrid`** and the missing layers go into `localPackageLayers`; they will be generated under the same prefix as the feed so they can be pushed into the feed later without renaming. The feed URL(s) are written to `customNugetFeeds`.
   - **No (`local`)** - supply only a package prefix (e.g., `Contoso`). All base-contract layers are added to `localPackageLayers` and generated in Phase 4 under `src/Packages/<Prefix>.*` as packable projects (consumed via `<ProjectReference>`). `customNugetFeeds` stays empty. The developer may publish these to a feed later without restructuring.

   `packagePrefix` is required in every mode. `EF` is the canonical example prefix used throughout these instructions, not a default.
2. **Scaffold mode** - full, lite, or api-only? What optional hosts are needed? For web UI, choose Blazor, Uno WASM, React/Vite SPA, or explicit siblings; do not add a second UI stack by default. **Exception - multi-head by persona:** if Phase 1 produced a persona -> UI-surface mapping that calls for a distinct admin/operator portal alongside the end-user app (see [shared-understanding-interview.md section Multi-Head UI Decision](shared-understanding-interview.md#multi-head-ui-decision)), enable the second per-stack host flag deliberately and offer explicit siblings under `src/UI/` (e.g. a React end-user app plus a Blazor Server admin head). Multi-head = two of `includeUnoUI` / `includeBlazorUI` / `includeReactUI` set true; record which persona drives which head in `DESIGN-DECISIONS.md`.
3. **Data store mapping** - for each entity: SQL (default), Cosmos, Table, or Blob? Binary content -> blob, relational -> sql, key-value -> table, document aggregates -> cosmosdb.
4. **Property details** - add types, maxLength, precision/scale to every property. Resolve ambiguous Phase 1 kinds.
5. **Relationship config** - join entities for many-to-many, cascade behavior, FK naming.
6. **External dependencies** - declare a scaffold mode for each (emulator, lazy-optional, no-op stub, deployment-only). When `useAspire: true`, consult [skills/aspire.md](../skills/aspire.md) section Official Integration Catalog Awareness and record any non-baseline service in `aspireResources` with docs URL, local mode, publish mode, and connection names.
7. **Messaging & events** - which events need Service Bus topics? Which are in-process channel dispatches?
8. **AI services** - if enabled: which entities need search indexes? Which decisions need agents? What models?
9. **Testing profile & surfaces** - minimal, balanced, or comprehensive? Which optional test types (E2E, architecture, load)? **Test surfaces are derived from the hosts/UI chosen in Question 2, not asked independently:** UI model/presentation coverage -> `Test.UI`; Uno -> `WasmUI` (Skia canvas bridge) + `Test.Mobile`; Blazor/React -> `Test.PlaywrightUI` (DOM); `useAspire` + comprehensive (or explicit `includeAspireTests`) -> `Test.Aspire` mesh; `api-only` / no UI -> none of these. Record the resulting tier set; the [Capability-Gated Test Tiers](../skills/testing.md#capability-gated-test-tiers-the-early-decision-drives-the-rest) table is authoritative for the mapping.

---

## Phase 2 -> 3 Transition Gate

Before moving to Phase 3 (Implementation Plan), verify all of the following:

- [ ] Every Phase 1 entity has a `dataStore` assignment (`sql`, `cosmosdb`, `table`, `blob`)
- [ ] Every `string` property has `maxLength` defined
- [ ] Every `decimal`/`money` property has `precision` and `scale`
- [ ] `scaffoldMode` is set (`full`, `lite`, or `api-only`)
- [ ] At least one host is enabled (`includeApi`, `includeGateway`, etc.)
- [ ] If `many-to-many` relationship exists, `joinEntity` is specified
- [ ] `testingProfile` is set (`minimal`, `balanced`, or `comprehensive`)
- [ ] `repositoryContractStyle` is set (`per-entity`, `hybrid`, or `generic-only`); for `hybrid`/`generic-only`, each entity is classified generic-coverable vs bespoke
- [ ] Test tiers are consistent with the selected hosts/UI: no UI -> no `Test.UI`/`Test.PlaywrightUI`/`WasmUI`/`Test.Mobile`; no UI model/presentation coverage -> no `Test.UI`; no Uno -> no `WasmUI`/`Test.Mobile`; `useAspire: false` or profile below `comprehensive` (without explicit `includeAspireTests`) -> no `Test.Aspire` mesh
- [ ] `packageStrategy` is set (`feed`, `local`, or `hybrid`)
- [ ] `packagePrefix` is set and non-empty (used to name packages/projects under the chosen prefix, e.g., `<Prefix>.Domain`)
- [ ] If `packageStrategy: feed` - `customNugetFeeds` has at least one entry; `localPackageLayers` is `[]`
- [ ] If `packageStrategy: local` - `customNugetFeeds` is `[]`; `localPackageLayers` covers every layer in [`../support/ef-packages-reference.md`](../support/ef-packages-reference.md)
- [ ] If `packageStrategy: hybrid` - `customNugetFeeds` has at least one entry **and** `localPackageLayers` lists only the layers the feed does not provide
- [ ] `externalDependencyModes` declared for every external dependency
- [ ] If `useAspire: true`, Aspire-hosted dependencies are checked against [skills/aspire.md](../skills/aspire.md) and any non-baseline service has package/API/local-mode notes recorded
- [ ] If `includeAiServices: true`: at least one model defined, each agent references a defined model, search indexes reference defined entities; `lifecycle: existing` sets `resourceName`/`resourceGroup`; `agentHosting: prompt-agent`/`pre-existing` sets `projectName`/`projectEndpoint`

## applicationStyle

Optional. Values: `service`, `cqrs`, or `switch`. Default: `service`. Choose before Phase 4 so scaffolding emits service implementations/endpoints, CQRS request records/handlers/endpoints, or both endpoint sets behind the `Application:Style` runtime selector.
