# Phase 1 Worked Example - TaskFlow Interview

A condensed transcript of the Phase 1 interview that produced the TaskFlow reference app. Use this when the schema docs ([../ai/shared-understanding-interview.md](../ai/shared-understanding-interview.md), [../ai/domain-specification-schema.md](../ai/domain-specification-schema.md)) tell you *what* fields exist but you want to see *how* the conversation actually flows.

Read time: ~5 minutes. Goal: build a mental model of pacing, depth, and the developer-AI back-and-forth - not memorize TaskFlow.

---

## Setup

The developer comes in with a one-paragraph idea and an empty repo. The AI loads `START-AI.md`, sees no `HANDOFF.md`, and runs the Phase Router into Phase 1.

```text
DEV
Multi-tenant task-management app for an enterprise. Users organize work into
categories, manage task items with sub-tasks, comments, checklists, and file
attachments. Want it to demonstrate every pattern in the scaffold instruction
set so it's also a reference app.
```

Before starting questions, the AI states what it's about to do, picks a working name, and signals the branch order.

```text
AI
Working name TaskFlow (override anytime). I'll walk the standard Phase 1 branches:
Purpose -> Actors -> Language -> Entities -> Relationships -> Lifecycle -> Rules ->
Events/Workflows -> Data -> Security -> Interfaces -> Delivery. After each branch I'll
give a recap and ask you to confirm or correct it. Final outputs are
.scaffold/domain-specification.yaml, .scaffold/UBIQUITOUS-LANGUAGE.md, and .scaffold/DESIGN-DECISIONS.md.
```

Before the branches, the AI settles the two up-front structural decisions that fix the solution layout - `applicationStyle` and `projectNamePrefix`. Both have defaults, but the AI asks rather than assumes, because changing them after Phase 4 creates projects is expensive.

```text
AI
Two quick structural choices before we dig into the domain:
1. Endpoint style - service-injected (`ITaskItemService`), CQRS handlers, or a runtime switch? Default: service.
2. Project naming - prefix every project with the solution name (`TaskFlow.Domain.Model`, `TaskFlow.Api` - the reference-app convention), or bare names (`Domain.Model`, `Api`)? Default: solution-name prefix.

DEV
1. Service is fine.
2. Use the solution-name prefix - I want it to match the reference app.

AI
Recording the structural decisions:
- D-000a applicationStyle -> service; depends on: none.
- D-000b projectNamePrefix -> solution-name (projects + namespaces prefixed with `TaskFlow`); depends on: none. Solution file: `TaskFlow.slnx`.

(Had you chosen bare names, projects and root namespaces would drop the prefix - `Domain.Model`, `Api`, `DbContextTrxn` - and `OrganizationName` would not be applied.)
```

---

## Branch - Actors and Roles

Small batched questions. 3-7 per branch.

```text
AI
1. Who are the human roles? (e.g., end users, tenant admins, global admins, system actors)
2. Are there any cross-tenant operations a "super-admin" needs to run?
3. Is auth enterprise (workforce SSO) or consumer (B2C)?
4. Any role-specific capabilities I should capture early (e.g., only admin can reopen)?

DEV
- TenantMember (normal user), TenantAdmin, GlobalAdmin (cross-tenant).
- Yes - GlobalAdmin can read across tenants for support.
- Enterprise. EntraID for the API.
- TenantAdmin can cancel anyone's work-in-progress; TenantMember can only cancel their own. GlobalAdmin reopens completed/cancelled.
```

The AI now records terms it just learned. **Watch this:** every accepted term goes into `.scaffold/UBIQUITOUS-LANGUAGE.md` immediately, not at the end.

```text
AI [Branch recap]

Confirmed language:
- `TenantMember`, `TenantAdmin`, `GlobalAdmin` - accepted role terms.
- `EntraID` - external identity provider for API auth.

Decisions:
- D-001 Tenancy -> row-level multi-tenant; depends on: none.
- D-002 Auth -> EntraID enterprise scenario; depends on: D-001.
- D-003 Role capability matrix needed for Cancel/Reopen - defer detail to Rules branch.

Open conflicts: none.

Is this branch correct, or anything to change before I continue?

DEV
Looks right. Continue.
```

---

## Branch - Entities and Aggregates

The interview's longest branch. The AI asks for entities, aggregate boundaries, and tenant scope. Note how it pushes back on a term it spots a conflict on.

```text
AI
What are the core entities and which is the aggregate root?

DEV
Task is the root. It has Comments, ChecklistItems, sub-Tasks, Tags, Attachments. There's also a Category for grouping.

AI
Two flags before I continue:
1. Naming conflict: `Task` collides with `System.Threading.Tasks.Task` in C#. Common alternatives: `TaskItem`, `WorkItem`, `Job`. Recommend `TaskItem` - keeps the domain term close to user vocabulary while avoiding the type clash. Confirm or pick another?
2. Attachment ownership: you mentioned attachments on tasks but discussion comments are common attachment owners too (screenshots, repro files). Should an Attachment belong to a TaskItem only, or polymorphically to either TaskItem or Comment?

DEV
- TaskItem.
- Polymorphic - both TaskItem and Comment.

AI
Recording:
- Rejected synonym: `Task` -> `TaskItem`. Reason: collision with .NET type.
- Polymorphic ownership confirmed for `Attachment`. I'll use `OwnerType` + `OwnerId` discriminator (no parent navigation collection); flag this in DESIGN-DECISIONS as it affects EF configuration.

Three more questions:
3. Sub-tasks - same TaskItem aggregate (self-reference) or separate? Max nesting depth?
4. Tag-to-TaskItem - many-to-many. Plain join table, or do you need metadata on the association (who tagged it, when)?
5. Category hierarchy - same self-reference question. Cap on depth?

DEV
- Self-reference, max 3 levels.
- I want metadata on tagging (who, when), so make TaskItemTag an explicit join entity.
- Self-reference, cap 5 levels.

AI [Branch recap]

Entities:
- `TaskItem` (aggregate root, tenant-scoped). Self-references via `ParentTaskItemId`, max 3 deep. Owns: Comments, ChecklistItems, Attachments (polymorphic), Tags (many-to-many through `TaskItemTag`).
- `Category` (root, tenant-scoped). Self-references via `ParentCategoryId`, max 5 deep.
- `Tag` (root, tenant-scoped). Many-to-many to TaskItem via TaskItemTag.
- `Comment` (child of TaskItem). Cascade-deletes with parent.
- `ChecklistItem` (child of TaskItem). Cascade-deletes with parent.
- `Attachment` (associated entity, polymorphic owner: TaskItem | Comment).
- `TaskItemTag` (explicit join entity).

Decisions:
- D-004 TaskItem self-reference depth = 3 (rule MaxSubTaskDepth).
- D-005 Category self-reference depth = 5 (rule MaxNestingDepth).
- D-006 Attachment ownership = polymorphic (OwnerType + OwnerId).
- D-007 Tag association via explicit join entity TaskItemTag (not implicit M2M).

Open conflicts: none. Confirm to move to Lifecycle?

DEV
Confirmed.
```

---

## Branch - Lifecycle (Mid-Interview Correction)

This branch shows what happens when an answer in a later branch invalidates an earlier one. Treat this as the model for *every* late-arriving change.

```text
AI
TaskItem states and transitions?

DEV
None -> Open -> InProgress -> Completed. Also Blocked, Cancelled.

AI
Eight transition questions to nail down the state machine:
1. Open -> InProgress trigger (action name)?
2. InProgress -> Blocked and back - same action both ways?
3. Can a Completed item be reopened? By whom?
4. Cancellation - from which states? Reversible?
5. Should "all checklist items complete" gate Completion?
6. Sub-tasks - does parent require all children Completed before it can Complete?
7. Are any transitions auto-triggered (scheduled, system) vs explicit user actions?
8. Initial state on Create - None or directly Open?

DEV
1. Action `Start`. 2. `Block` and `Unblock`. 3. Yes, GlobalAdmin only. 4. Cancel from Open, InProgress, Blocked; reversible by reopening (GlobalAdmin). 5. Yes - must require all checklist items complete. 6. Wait - yes, sub-tasks must all be complete too. 7. None auto-triggered. 8. Create from None to Open.

AI
Question 6 introduces a new domain rule. Recording:
- D-008 Domain rule `SubTaskCompletionRequired` - TaskItem can transition to Completed only when all sub-tasks are Completed. This adds to the existing `ChecklistCompletionRequired` rule. Both fire on the InProgress -> Completed guard.

This also retroactively affects branch "Entities" - the sub-task self-reference is now load-bearing for completion semantics. Updating UBIQUITOUS-LANGUAGE.md note for `TaskItem` to call this out, and tagging D-004 as parent of D-008.

DEV
Good catch.
```

The lesson: the AI doesn't quietly accept an answer that contradicts an earlier branch. It calls it out, names the back-edit, and stamps the dependency in `DESIGN-DECISIONS.md` so the chain stays traceable.

---

## Final Artifacts (Trimmed Excerpts)

After all twelve branches, the YAML and the two markdown docs are written. See the full files in the reference app:

- [TaskFlow `.scaffold/domain-specification.yaml`](https://github.com/efreeman518/AI-Instructions-ReferenceApp/blob/main/.scaffold/domain-specification.yaml)
- [TaskFlow `.scaffold/UBIQUITOUS-LANGUAGE.md`](https://github.com/efreeman518/AI-Instructions-ReferenceApp/blob/main/.scaffold/UBIQUITOUS-LANGUAGE.md)
- [TaskFlow `.scaffold/DESIGN-DECISIONS.md`](https://github.com/efreeman518/AI-Instructions-ReferenceApp/blob/main/.scaffold/DESIGN-DECISIONS.md)

Trimmed YAML fragment showing how the conversation lands as schema:

```yaml
ProjectName: TaskFlow
projectNamePrefix: solution-name
multiTenant: true
tenantIsolation: row-level
authProvider: EntraID
authScenario: enterprise

entities:
  - name: TaskItem
    isTenantEntity: true
    properties:
      - { name: Title, required: true }
      - { name: Status, kind: enum, values: [None, Open, InProgress, Blocked, Completed, Cancelled] }
    children:
      - { name: SubTasks, entity: TaskItem, relationship: self-referencing, selfReferenceKey: ParentTaskItemId }
      - { name: Comments, entity: Comment, relationship: one-to-many, cascadeDelete: true }
      - { name: Attachments, entity: Attachment, relationship: polymorphic-join, polymorphicEntityTypes: [TaskItem, Comment] }
      - { name: Tags, entity: Tag, relationship: many-to-many }
    rules:
      - { name: MaxSubTaskDepth, condition: "Sub-task hierarchy must not exceed 3 levels deep" }
    stateMachine:
      field: Status
      initial: None
      transitions:
        - { from: Open, to: InProgress, action: Start }
        - { from: InProgress, to: Completed, action: Complete, guard: AllChecklistItemsComplete }
        # ... (full state machine in TaskFlow's domain-specification.yaml)

domainRules:
  - name: ChecklistCompletionRequired
    appliesTo: [TaskItem, ChecklistItem]
  - name: SubTaskCompletionRequired
    appliesTo: [TaskItem]
```

---

## What This Example Is Showing

| Pattern | Where it shows up |
|---|---|
| Up-front structural decisions asked, not assumed (`applicationStyle`, `projectNamePrefix`) | Setup, before the branches |
| Small batches (3-7 questions per branch) | Every branch above |
| Branch recap + confirmation before moving on | End of Actors and Entities branches |
| AI flags naming conflicts immediately, doesn't silently rename | "Task vs TaskItem" exchange in Entities |
| AI proposes alternatives with rationale, not just "what would you like" | Same exchange |
| Decision IDs (`D-###`) with explicit `depends on` | Throughout |
| Late-arriving facts trigger back-edits to prior branches | Lifecycle branch question 6 |
| Rejected synonyms are first-class - recorded, not just dropped | `Task` -> `TaskItem`, `Todo` -> `ChecklistItem`, etc. |
| Domain rules surface during Lifecycle, not invented in Phase 5 | `ChecklistCompletionRequired`, `SubTaskCompletionRequired` |
| Decisions that affect EF configuration are flagged for downstream phases | Polymorphic `Attachment`, explicit `TaskItemTag` join entity |

---

## What This Example Is Not

This is not a script. The branches and question counts adapt to the project - a single-entity API will have a 3-line Entities branch and skip Workflows entirely. Use the [Minimum Viable Scaffold](minimum-viable-scaffold.md) prompts for that path.

If your interview is going on for hours, you're either over-asking (cut to canonical defaults and record the assumption) or the developer doesn't have answers yet (mark branches `deferred` and continue).
