# Domain Specification Schema (Phase 1 Output)

Pure business domain model - no implementation details, no datatypes, no databases.

**JSON Schema:** [`schemas/domain-specification.schema.json`](../schemas/domain-specification.schema.json) - use for programmatic validation of `.scaffold/domain-specification.yaml`.

## Output Contract

Write Phase 1 output to `.scaffold/domain-specification.yaml` in the target project (create the `.scaffold/` directory at project root if absent). Do not write project artifacts under `.instructions/`; that directory is the installed runtime instruction payload.

Phase 1 also writes:

- `.scaffold/UBIQUITOUS-LANGUAGE.md` - shared domain vocabulary for future AI/developer sessions.
- `.scaffold/DESIGN-DECISIONS.md` - decision log and dependency graph for design choices.

Run the shared understanding interview before finalizing this YAML. See [shared-understanding-interview.md](shared-understanding-interview.md).

## Project Identity

```yaml
ProjectName: ""
ProjectDescription: ""
OrganizationName: ""               # optional namespace prefix (host/UI projects only)
projectNamePrefix: solution-name   # solution-name (default) | none
```

`projectNamePrefix` controls whether generated project names, folders, and root namespaces carry the solution-name prefix. Confirm it with the developer in Phase 1 (see [shared-understanding-interview.md - Project Naming Decision](shared-understanding-interview.md#project-naming-decision)).

- `solution-name` (default) - matches the TaskFlow reference app: `{Project}.Domain.Model`, `{Host}.Api`, `{App}DbContextTrxn`.
- `none` - bare project names and namespaces: `Domain.Model`, `Api`, `DbContextTrxn`; `OrganizationName` is not applied.

Either way the solution file is named `{SolutionName}.slnx`. Token mechanics: [placeholder-tokens.md - Derivation Rules](placeholder-tokens.md#derivation-rules).

## Entities

Define what the business calls things, their lifecycle, and how they relate.

> **WARNING Naming Conflicts:** Avoid entity names that collide with C# framework types. Common conflicts:
> - `Task` -> conflicts with `System.Threading.Tasks.Task` - use `WorkItem`, `ProjectTask`, or `JobTask`
> - `Thread` -> conflicts with `System.Threading.Thread` - use `Discussion`, `Conversation`
> - `Timer` -> conflicts with `System.Threading.Timer` - use `Reminder`, `Schedule`
> - `Type` -> conflicts with `System.Type` - use `Category`, `Classification`
> - `String`, `Object`, `Action`, `Attribute`, `File`, `Path` -> all conflict with System types
>
> These collisions cause subtle compilation errors or require `global::` disambiguations throughout the codebase.

```yaml
entities:
  - name: TodoItem
    description: "A unit of work assigned to a team member"
    isTenantEntity: true
    properties:
      - { name: Title, required: true, description: "Short summary" }
      - { name: Description, required: false }
      - { name: DueDate, required: false }
      - { name: Priority, kind: enum, values: [Low, Medium, High, Critical] }
      - { name: Status, kind: flags_enum, values: [None, IsStarted, IsCompleted] }
    children:
      - { name: Comments, entity: Comment, relationship: one-to-many, cascadeDelete: true }
      - { name: Tags, entity: Tag, relationship: many-to-many }
    navigation:
      - { name: Category, entity: Category, required: false }
      - { name: AssignedTo, entity: TeamMember, required: false }
```

### Property Rules

- `kind`: `string` (default) | `enum` | `flags_enum` | `number` | `date` | `boolean` | `identifier` | `money` | `text` | `value_object`
- No `type`, `maxLength`, `precision` here - those are Phase 2 concerns
- `required`: business requirement, not database nullability
- For `kind: value_object`, set `valueObject: {ValueObjectName}` and define it under top-level `valueObjects`
- For operational reason fields (`ReasonCode` style), prefer:
  - fixed, stable set -> `enum`
  - evolving/managed set -> dedicated catalog entity (for localization/versioning)

## Value Objects

Use `valueObjects` for concepts where a primitive would hide business meaning, validation, behavior, or equality. Do not wrap every string or number by default. Good candidates: money, date range, call window, email address, phone number, percentage, or values easy to confuse with the same primitive.

Value objects are domain-side types. DTO/API contracts stay primitive/Guid-friendly by default; mappers flatten fields into DTOs and create value objects through domain factories.

```yaml
valueObjects:
 - name: DateRange
   description: Start and optional end date for scheduled work
   fields:
    - { name: StartDate, kind: date, required: true }
    - { name: EndDate, kind: date, required: false }
   rules:
    - name: EndAfterStart
      condition: EndDate absent or after StartDate
   usedBy:
    - { entity: Project, property: Schedule }

entities:
 - name: Project
   properties:
    - { name: Schedule, kind: value_object, valueObject: DateRange, required: false }
```

### Modeling a Named-Value / Status / Classification Field

When a field holds one of several named values, a status, or a classification, pick the model before writing the spec. Default to the simplest row that fits.

| Model | Choose when | Wrong-choice smell |
|-------|-------------|--------------------|
| `enum` | Fixed closed set; values are interchangeable labels; no transition rules; no per-value structure | A `switch` on the enum keeps growing; some values are only valid after others |
| `flags_enum` | Same as enum, but several values can be true at once (combinable states/features) | Modeling combinations as extra enum members (`ReadAndWrite`) |
| `stateMachine` | Values have allowed transitions, guards, or trigger events (a lifecycle/status) | Transition checks scattered in service code; invalid status jumps slip through |
| Separate entities | Different values carry different properties, relationships, lifecycles, or rules | Nullable columns that only apply to one `Type`; `if (Type == X)` branching everywhere |
| Catalog / reference entity | The set evolves at runtime or needs localization, versioning, or admin management | Shipping code to add a value; translators editing an enum |
| Value object | The field carries behavior and equality over data, not a label (money, date range, address) | Primitive obsession; equality/validation logic copied at each use site |

Enums are appropriate for a **fixed, closed set of named values** with no transition logic. Two misuses to avoid:

**1. Do not use an enum in place of a state machine.**
If the values have allowed transitions, guards, or trigger events, model it as a `stateMachine` (see State Machines section). An enum with transition logic buried in service code is a state machine in disguise - it will accumulate `switch` statements and invariant violations across the codebase.

Wrong: `Status: enum [Draft, Active, Suspended, Closed]` when only certain transitions are valid.
Right: declare a `stateMachine` with explicit `states`, `transitions`, and guards.

**2. Do not collapse multiple domain entities into one entity by misusing an enum discriminator.**
If objects with different `Type` values have different properties, relationships, lifecycles, or rules, they are separate entities - not one entity with a `Kind`/`Type` enum. Collapsing them produces nullable columns, conditional logic everywhere, and violated invariants.

Wrong: a single `Notification` entity with `Type: enum [Email, SMS, Push]` where each type has different required fields and delivery rules.
Right: a shared `Notification` base entity (or interface) with separate `EmailNotification`, `SmsNotification`, `PushNotification` entities.

Apply enum freely when the values are genuinely interchangeable labels with no structural or behavioral difference between them.

### Relationship Types

- `one-to-many` - parent owns children. Specify cascade behavior.
  ```yaml
  children:
    - { name: Comments, entity: Comment, relationship: one-to-many, cascadeDelete: true }
  ```
- `one-to-one` - parent owns exactly one child (1:1 ownership). Materializes as a unique FK on the child, a single (non-collection) navigation on the parent, and cascade delete. Prefer this over `one-to-many` plus an "at most one" entity rule.
  ```yaml
  children:
    - { name: Detail, entity: TodoItemDetail, relationship: one-to-one, cascadeDelete: true }
  ```
- `many-to-many` - peer association. Join entity details are Phase 2.
  ```yaml
  children:
    - { name: Tags, entity: Tag, relationship: many-to-many }
  ```
- `self-referencing` - hierarchical structures within the same entity.
  ```yaml
  children:
    - { name: Children, entity: TodoItem, relationship: self-referencing, selfReferenceKey: ParentId }
  ```
- `polymorphic-join` - shared attachment pattern across parent types.
  ```yaml
  children:
    - { name: Attachments, entity: Attachment, relationship: polymorphic-join, polymorphicEntityTypes: [TodoItem, Comment] }
  ```
- Reference navigation (no ownership):
  ```yaml
  navigation:
    - { name: Category, entity: Category, required: false }
  ```

### Aggregate Roots vs Owned Children (drives the generated write surface)

The `children` / `navigation` structure already encodes aggregate ownership; this section makes it **normative for generation** so downstream phases apply the DDD default (GR-15) instead of treating every entity as an independent root.

**Default classification (derive it, do not ask):**

- An entity that appears as the `entity` target of another entity's `one-to-many` or `one-to-one` `children` relationship is an **owned child** of that aggregate (e.g. `Comment`, `ChecklistItem` owned by a task). It has no identity or lifecycle outside its parent.
- A `many-to-many` relationship produces a **junction** that is an owned child (membership) of the declaring root; the **associated** entity (e.g. `Tag`) remains an independent **root**.
- A `self-referencing` relationship keeps the entity a **root** (it owns a tree of itself).
- A `polymorphic-join` child (e.g. `Attachment`) is its **own root** with a polymorphic owner reference - not an owned child.
- Every entity not owned by any parent is an **aggregate root**.

**Explicit override (only when the default is wrong):** add `aggregateRole` to an entity to pin the classification - `root`, `owned-child` (name the `aggregateParent`), or `join`. Use it for a shared child owned by more than one parent, or a child that genuinely has an independent lifecycle.

```yaml
entities:
  - name: Comment
    aggregateRole: owned-child       # no standalone write slice; mutated through TaskItem
    aggregateParent: TaskItem
  - name: Tag
    aggregateRole: root              # independent aggregate; full slice
```

**Generation consequence (GR-15, default-on - opt out only on explicit instruction):** an **owned child** gets entity + EF config + DbSet + the root's `Add*`/`Remove*` methods + `{Root}Updater` wiring + DTO + mapper + optional read query (`Get`/`Search`). It gets **no** standalone create/update/delete command, handler, service write method, or write endpoint - those become nested sub-resource routes on the root (see [../skills/domain-model.md](../skills/domain-model.md) section Aggregate Roots vs Internal Children). An **aggregate root** gets the full slice. A developer may override this per entity, but the override must be recorded in `.scaffold/DESIGN-DECISIONS.md`.

## Business Rules

```yaml
entities:
  - name: TodoItem
    rules:
      - { name: TitleRequired, condition: "Title must not be empty", errorMessage: "Title is required." }
      - { name: DueDateFuture, condition: "DueDate must be in the future when set", errorMessage: "Due date must be future." }

domainRules:
  - { name: TenantQuotaNotExceeded, appliesTo: [TodoItem], dependsOn: [TenantQuotaPolicy], errorMessage: "Tenant quota exceeded." }
```

Rules use business language here. Exact C# conditions are Phase 3/4 concerns.

### Policy Matrix (Optional)

Use for actor/state dependent outcomes that are difficult to represent as isolated rules.

```yaml
policyMatrices:
  - name: CancellationPolicyMatrix
    dimensions: [RequestedByRole, CurrentStatus]
    outputs: [Allowed, FeePolicy, RefundPolicy]
    rows:
      - { RequestedByRole: Customer, CurrentStatus: Placed, Allowed: true, FeePolicy: None, RefundPolicy: Full }
      - { RequestedByRole: Customer, CurrentStatus: InTransit, Allowed: true, FeePolicy: Partial, RefundPolicy: Partial }
```

## State Machines

Define lifecycle states and valid transitions in business terms. States = named business conditions. Transitions = allowed moves with named actions. Guards = business rules that gate transitions.

```yaml
entities:
  - name: TodoItem
    stateMachine:
      field: Status
      initial: None
      states: [None, InProgress, Completed, Cancelled]
      transitions:
        - { from: None, to: InProgress, action: Start }
    customActions:
      - { name: Reschedule, params: [{ name: NewDueDate }] }
```

## Events

### Trigger Types

| Trigger | Description |
|---------|-------------|
| `afterCreate` | Raised after an entity is created |
| `afterUpdate` | Raised after any property is updated |
| `afterStatusChange` | Raised after a state machine transition completes |
| `afterAction(<ActionName>)` | Raised after a named custom domain action (e.g., `afterAction(Reschedule)`) |
| `afterDelete` | Raised after an entity is (soft-)deleted |
| `scheduled` | Emitted by a background job or scheduler on a time-based trigger |

```yaml
events:
  - name: TodoItemCreated
    raisedBy: TodoItem
    trigger: afterCreate
    payload: [TenantId, TodoItemId, Title]
  - name: TodoItemCompleted
    raisedBy: TodoItem
    trigger: afterStatusChange
    payload: [TenantId, TodoItemId, CompletedBy]
  - name: TodoItemOverdueSuspected
    raisedBy: TodoItem
    trigger: scheduled
    payload: [TenantId, TodoItemId, DueDate]
  - name: TodoItemRescheduled
    raisedBy: TodoItem
    trigger: afterAction(Reschedule)
    payload: [TenantId, TodoItemId, NewDueDate]
```

## Workflows

```yaml
workflows:
  - name: TodoItemEscalation
    pattern: orchestrator
    involvedEntities: [TodoItem, Team, TeamMember, Reminder]
    steps:
      - "Check overdue items"
      - "Notify member"
      - "Escalate after threshold"
    compensationRequired: true
    compensation:
      rollbackOrder: reverse-step-order
      rules:
        - { onFailureOfStep: "Notify member", compensationAction: "Cancel queued notification" }
        - { onFailureOfStep: "Escalate after threshold", compensationAction: "Revoke escalation and reset status" }
    notes: "Thresholds configurable per tenant"
```

Skip workflows when CRUD + state transitions suffice. Add workflows when multiple entities must coordinate in sequence, steps may fail and need compensation, or async waits/escalations are involved.

### Ingestion Semantics (Optional)

For event/time-series workflows, capture business-level ordering and lateness expectations.

```yaml
ingestionSemantics:
  eventTimePolicy: event-time
  orderingExpectation: per-entity-ordered
  allowedLateness: "PT10M"
  outOfOrderHandling: reconcile-window
```

### Entitlement Policy (Optional)

Use when multiple grant sources (tier/purchase/promo) must be combined deterministically.

```yaml
entitlementPolicy:
  sourcePriority: [Tier, Purchase, Promo]
  conflictResolution: highest-priority-wins
  revokeBehavior: source-scoped-revocation
```

### Content Lifecycle Policy (Optional)

Use for publish/schedule/rollback scenarios.

```yaml
contentLifecyclePolicy:
  supportsDraftSnapshot: true
  supportsPublishedSnapshot: true
  rollbackStrategy: prior-published-version
  scheduledPublishIdempotent: true
```

### UGC Lifecycle Policy (Optional)

Use for comments/favorites and moderation-sensitive interactions.

```yaml
ugcLifecyclePolicy:
  moderationMode: post-moderation
  visibilityStates: [Visible, Hidden, Removed]
  softDeleteEnabled: true
  authorRedactionSupported: true
```

## AI Capabilities (Optional)

Capture business-level intent for AI-powered features. No implementation details - those are Phase 2 concerns.

### Semantic Search

Identify entities where users should find results by meaning, not just exact keywords.

```yaml
aiCapabilities:
  search:
    - entity: Product
      searchableFields: [Name, Description, Tags]
      intent: "Users find products by describing what they need, not exact keywords"
    - entity: KnowledgeArticle
      searchableFields: [Title, Body, Summary]
      intent: "Support agents find relevant articles from customer problem descriptions"
```

### Agent Workflows

Identify decisions or processes where an AI agent could assist. Focus on what the agent should accomplish, not how.

```yaml
  agentWorkflows:
    - name: CustomerSupportTriage
      description: "Classify incoming support requests and route to the right team"
      involvedEntities: [SupportTicket, Team, KnowledgeArticle]
      humanInLoop: true
      decisions:
        - "Determine urgency and category"
        - "Find relevant knowledge articles"
        - "Suggest resolution or escalation path"
    - name: ContentSummarizer
      description: "Generate summaries of long-form content for preview cards"
      involvedEntities: [Article]
      humanInLoop: false
      decisions:
        - "Extract key points from article body"
```

Add AI capabilities when search should be meaning-based (not just keyword filters), decisions involve classification/ranking/NL reasoning, or content generation/summarization is needed. Implementation details (models, indexes, prompts) are Phase 2/4 concerns - see [skills/ai-integration.md](../skills/ai-integration.md).

---

## Tenancy & Auth Model

```yaml
multiTenant: true
tenantIsolation: "row-level"     # row-level | schema | database
globalAdminRole: GlobalAdmin
authProvider: EntraID             # EntraID | EntraExternal | Google | Facebook | Apple | OAuth2 | None
authScenario: enterprise          # enterprise | external | hybrid
```

Auth provider options:
- **Enterprise / internal:** `EntraID` - SSO, conditional access, group-based roles
- **External / consumer:** `EntraExternal`, `Google`, `Facebook`, `Apple`, `OAuth2` - social/OIDC providers
- **Hybrid:** combine `EntraID` for internal with `EntraExternal` or social providers for external users

> **Note:** Authentication is configured in the final integration phase (Phase 5e). During earlier phases, auth is stubbed. See [skills/identity-management.md](../skills/identity-management.md).

---

## Discovery Conversation Pattern

Work through these in order during Phase 1 after loading [shared-understanding-interview.md](shared-understanding-interview.md):

1. **Core entities** - what does the business call things?
2. **Relationships and ownership** - who owns what? What references what? Which entities are aggregate roots?
3. **Value objects** - which values carry business meaning, validation, behavior, or equality beyond their primitive fields?
4. **Lifecycle** - what states does each entity go through?
5. **Rules and invariants** - what must be true? What constraints belong inside the domain model?
6. **Events** - what happened that other parts of the system care about?
7. **Workflows** - what multi-step processes exist beyond CRUD?
8. **AI capabilities** - what searches should be "smart"? What decisions could an agent help with? What content should be generated or summarized?
9. **Tenancy/auth** - who can see/do what?

After each branch, recap the current understanding, confirmed language, design decisions, open conflicts, and deferred items. Do not write final YAML until every branch is confirmed, defaulted, or deferred.

---

## Phase 1 -> 2 Transition Gate

Before moving to Phase 2 (Resource Definition), verify all of the following:

- [ ] Every entity has `name`, at least one `property`, and `isTenantEntity` set
- [ ] Every relationship references an entity defined in this file
- [ ] Each entity is classified aggregate **root** or **owned child** (derived from `children`/`navigation`, or pinned via `aggregateRole`); any non-default `aggregateRole` override is recorded in `.scaffold/DESIGN-DECISIONS.md` (drives GR-15 write-surface generation)
- [ ] Every `kind: value_object` property references a `valueObjects[].name`; each value object has fields, rules if any, and `usedBy` references existing entity properties
- [ ] No entity names collide with C# reserved types (`Task`, `Thread`, `Timer`, `Type`, `String`, `Object`, `Action`, `Attribute`, `File`, `Path`)
- [ ] State machine `states` list matches `transitions` from/to values (no orphaned states or transitions)
- [ ] Every event `raisedBy` references a defined entity
- [ ] `ProjectName` is set and valid (PascalCase, no spaces)
- [ ] `projectNamePrefix` is set (`solution-name` or `none`), confirmed with the developer, and recorded in `.scaffold/DESIGN-DECISIONS.md`
- [ ] At least one entity is defined
- [ ] If `aiCapabilities` is defined: every referenced entity exists, every `agentWorkflows` entry references defined entities, and `searchableFields` reference defined properties
- [ ] `.scaffold/UBIQUITOUS-LANGUAGE.md` contains every entity, state, event, command/action, role, policy, and value object name from this file
- [ ] `.scaffold/DESIGN-DECISIONS.md` records non-obvious choices and marks each blocking Phase 2 decision `confirmed`, `defaulted`, or `deferred`
