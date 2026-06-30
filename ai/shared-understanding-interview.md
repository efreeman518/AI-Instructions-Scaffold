# Shared Understanding Interview (Phase 1)

Use this file during Phase 1 before writing `.scaffold/domain-specification.yaml`.

Goal: interview the developer until the AI and developer share the same domain model, vocabulary, and decision context. Do not rush to YAML. The YAML is only valid after the interview branches below are confirmed, defaulted, or explicitly deferred.

> **First time?** [`../support/phase-1-worked-example.md`](../support/phase-1-worked-example.md) shows a condensed transcript of the actual interview that produced the TaskFlow reference app - pacing, branch recaps, and how the AI handles a mid-interview correction.

## Output Artifacts

Phase 1 produces all three files under `.scaffold/` in the target project (create the directory at project root if absent):

1. `.scaffold/domain-specification.yaml`
2. `.scaffold/UBIQUITOUS-LANGUAGE.md`
3. `.scaffold/DESIGN-DECISIONS.md`

Use [../templates/ubiquitous-language-template.md](../templates/ubiquitous-language-template.md) and [../templates/design-decisions-template.md](../templates/design-decisions-template.md).

## Interview Rules

- Ask questions in small batches. Prefer 3-7 related questions per branch.
- After each branch, summarize the current understanding and ask the developer to correct it.
- Track every non-obvious choice in `.scaffold/DESIGN-DECISIONS.md`.
- Track every accepted domain term, rejected synonym, state, event, action, role, policy term, and value object in `.scaffold/UBIQUITOUS-LANGUAGE.md`.
- Model the domain before persistence, API DTOs, or UI screens. Ask what business action is allowed under what conditions before asking how it is stored or transported.
- Resolve dependent decisions in order. Do not finalize a child decision when its parent decision is open.
- Use canonical defaults only where the instruction set defines them. State the default and record it.
- If a decision is not needed for current scaffold correctness, mark it `deferred` with the phase that must revisit it.

## Clarification Quality Rules

Treat Phase 1 artifacts as tests for the conversation: another AI session should be able to generate Phase 2 resources without guessing at the domain.

- Classify ambiguity before asking. Use the taxonomy below so questions stay targeted.
- Ask only questions whose answer changes an artifact, a decision, a resource choice, a test, or a generated contract.
- Prefer one focused correction loop over broad brainstorming. After a recap, ask at most five targeted clarification questions before continuing.
- Use `[OPEN QUESTION: <single-sentence question>]` only when no safe default or deferral exists (**GR-10**). Place the marker inline in the relevant `.scaffold/` artifact (`domain-specification.yaml`, `UBIQUITOUS-LANGUAGE.md`, or `DESIGN-DECISIONS.md`) and mirror it to `HANDOFF.md` section Open Questions. Keep at most three active markers at any time.
- Resolve each marker before Phase 2, or convert it to a `deferred` decision with `Needed Before` set to the phase that must revisit it. A marker still present at the next phase gate halts the next phase until resolved or explicitly downgraded to non-blocking.
- Do not hide assumptions. Record the assumption, why it is reasonable, what could break if it is wrong, and whether the developer confirmed it.

## Ambiguity Taxonomy

Use these categories when deciding what to clarify:

| Category | Examples | Default Handling |
|---|---|---|
| Vocabulary | synonym conflict, overloaded term, abbreviation | record accepted term and rejected synonym |
| Actor and permission | unclear role, cross-tenant privilege, admin exception | ask before resource or endpoint planning |
| Entity boundary | aggregate root, owned child, reference, value object | ask before Phase 2 resource mapping and before Phase 4 contracts |
| Lifecycle | state names, allowed transitions, terminal state | ask before rules/tests |
| Business rule | invariant, quota, conflict resolution, validation | ask before domain test planning |
| Workflow | async reaction, compensation, scheduled process | defer only with `Needed Before` phase |
| External system | source of truth, emulator/no-op mode, failure handling | resolve before Phase 2 external dependency mode |
| Interface contract | API command, UI flow, search/filter semantics | resolve before Phase 4 contracts |
| Non-functional | audit, retention, compliance, cost, region, scale | resolve before Phase 2/3 resource planning |

## Branch Order

Walk these branches in order. Revisit earlier branches when a later answer changes them.

| Branch | Resolve | Key Dependencies |
|---|---|---|
| Purpose | business problem, success criteria, primary users | none |
| Actors and roles | human roles, system actors, permissions vocabulary | purpose |
| Ubiquitous language | accepted terms, rejected synonyms, naming conflicts | purpose, actors |
| Entities and aggregates | entities, ownership, aggregate roots, tenant scope | language |
| Value objects | meaningful values, validation, equality, primitive-confusion risks | entities |
| Relationships | ownership, reference, self-reference, many-to-many, polymorphic ownership | entities |
| Lifecycle | states, transitions, commands/actions, terminal states | entities, relationships |
| Rules and policies | invariants, policy matrices, quotas, conflict handling | lifecycle |
| Events and workflows | business events, async reactions, scheduled work, compensation | lifecycle, rules |
| Data and resources | store fit, external dependencies, local emulator/no-op posture | entities, workflows |
| Security and compliance | tenancy, auth scenario, audit, retention, sensitive data | actors, entities, resources |
| Interfaces | API, UI, background hosts, integrations, AI capabilities | actors, workflows, resources |
| Delivery constraints | scaffold mode, test profile, regions, cost, team constraints | all prior branches |

> **Heads-up - Phase 2 will open with packaging strategy.** The very first Phase 2 question asks whether the project has a private NuGet feed for shared base contracts (e.g., `EF.*`) or whether the scaffold should generate equivalent packable projects under `src/Packages/<Prefix>.*`. Flag any constraints here (corporate feed policy, prefix conventions) so Phase 2 doesn't re-discover them. Full details: [resource-implementation-schema.md section Discovery Conversation Pattern](resource-implementation-schema.md#discovery-conversation-pattern).

> **Heads-up - the Interfaces branch decides UI topology.** When the Actors-and-roles branch found more than one persona (e.g. a distinct admin/operator role vs the primary end user), the Interfaces branch must decide whether a **separate admin portal** is needed - not just which single UI stack to use. Resolve this before Phase 2 sets the host flags; a second head retrofitted after Phase 4 is expensive. See [Multi-Head UI Decision](#multi-head-ui-decision) below.

## Branch Recap Format

After each branch, use this exact structure:

```markdown
### Branch: {name}

Current understanding:
- ...

Confirmed language:
- `{Term}` means ...

Decisions:
- `D-###` {decision} -> {selected option}; depends on: {D-### or none}

Assumptions:
- None

Open conflicts:
- None

Deferred:
- None
```

Ask: `Is this branch correct, or should anything change before I continue?`

## Decision Dependency Rules

Parent decisions must close before child decisions:

- Tenant model -> auth scenario -> tenant filters -> resource partitioning -> endpoint route shape.
- Entity ownership -> relationship type -> storage mapping -> repository order -> vertical slice order.
- Lifecycle states -> commands/actions -> events -> messaging/scheduler -> notification/AI hooks.
- Compliance classification -> audit/retention/encryption -> data store -> tests/IaC.
- UI/client needs -> API shape -> DTO/search filters -> endpoint tests.
- External dependency mode -> local boot behavior -> no-op stubs/emulators -> final scaffold gate.

If a child branch exposes a parent conflict, pause and reopen the parent branch.

## Shared Understanding Gate

Before writing Phase 1 outputs, confirm:

- [ ] Each branch is `confirmed`, `defaulted`, or `deferred`.
- [ ] `applicationStyle` and `projectNamePrefix` are confirmed (or explicitly defaulted) and recorded in `.scaffold/DESIGN-DECISIONS.md`.
- [ ] Every entity, state, event, command/action, role, policy, and value object has a language entry.
- [ ] Each value object is justified by business meaning, validation, behavior, equality, or dangerous primitive confusion; otherwise keep primitive property.
- [ ] Every rejected synonym or ambiguous term is recorded.
- [ ] Every non-obvious design choice has a decision record with dependencies.
- [ ] No open decision blocks Phase 2 resource mapping.
- [ ] No unresolved `[OPEN QUESTION: ...]` marker blocks Phase 2 (**GR-10**). Any remaining uncertainty is recorded as a non-blocking deferred decision with `Needed Before` set, and is mirrored in `HANDOFF.md` section Open Questions.
- [ ] At most three `[OPEN QUESTION: ...]` markers remain (the GR-10 working cap from Clarification Quality Rules above).
- [ ] Every deferred branch names the phase that revisits it (`Needed Before`).
- [ ] Every defaulted value maps to a canonical default in [resource-implementation-schema.md](resource-implementation-schema.md) section Canonical Defaults, with the assumption stated inline.
- [ ] Each success criterion is measurable in business terms, not implementation terms.
- [ ] Developer has reviewed the final recap.

Only then write `.scaffold/domain-specification.yaml`, `.scaffold/UBIQUITOUS-LANGUAGE.md`, and `.scaffold/DESIGN-DECISIONS.md`.

## Application Style Decision

Capture this up front in Phase 1: `applicationStyle: service | cqrs | switch` (default `service`). Explain whether HTTP endpoints should inject `I{Entity}Service`, specific CQRS handlers, or both behind a runtime switch. If `cqrs` or `switch`, preserve DTO/routes unless the domain discovery proves a route change is required.

## Project Naming Decision

Capture this up front in Phase 1, alongside `ProjectName`: `projectNamePrefix: solution-name | none` (default `solution-name`). It decides whether every generated project, folder, and root namespace is prefixed with the solution name - the reference app does this (`TaskFlow.Domain.Model`, `TaskFlow.Api`), but it is **not** required.

Ask the developer explicitly - do not assume the reference-app convention:

> Should generated projects be prefixed with the solution name (`{Project}.Domain.Model`, `{Host}.Api` - the TaskFlow convention), or use bare names (`Domain.Model`, `Api`)?

- `solution-name` (default) - prefix on. Backward-compatible with every template and the reference app.
- `none` - bare project names and namespaces; `OrganizationName` is not applied. Note the trade-off: bare top-level namespaces (`Domain.Model`, `Application.Services`) are generic and can collide when the assembly is consumed alongside other solutions.

Either way the solution file is `{SolutionName}.slnx`. Record the choice as a decision in `.scaffold/DESIGN-DECISIONS.md` (it is structural and hard to reverse after Phase 4 creates the projects). Token mechanics: [placeholder-tokens.md - Derivation Rules](placeholder-tokens.md#derivation-rules).

## Multi-Head UI Decision

The web UI is **not** always a single surface. When the Actors-and-roles branch produced more than one actor persona - especially a distinct admin/operator role alongside the primary end user - resolve the UI topology here, in the Interfaces branch, before Phase 4 fixes the solution layout. Retrofitting a second UI head after Phase 4 is materially more expensive than declaring it now.

Ask explicitly: do the management personas need a **separate admin portal** distinct from the main end-user app, or is one UI with role-gated screens sufficient? Default-suggest **Blazor Server** for an internal/data-dense management head (single deployable, server-owned HttpClient, fastest to scaffold) even when the end-user app is a different stack (e.g. React/Vite or Uno WASM for the public app).

Record a **persona -> UI-surface mapping** in `.scaffold/DESIGN-DECISIONS.md`, for example:

```markdown
- end-user (primary) -> `{App}` React SPA (public)
- admin/operator     -> `{App}.Admin` Blazor Server (internal)
```

Mechanically, a second head means enabling a second per-stack host flag (`includeUnoUI` / `includeBlazorUI` / `includeReactUI`) - see [resource-implementation-schema.md section Discovery Conversation Pattern](resource-implementation-schema.md#discovery-conversation-pattern) (Question 2) and the sibling-layout guidance in [../skills/ui-blazor.md](../skills/ui-blazor.md). No schema change is required; the decision must record which persona drives which head. If the answer is deferred, mark it `deferred` with `Needed Before: Phase 2` (the host flags are set in Phase 2), not later - the topology cannot float into Phase 4.
