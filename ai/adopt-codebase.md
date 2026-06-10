# Adopt an Existing Codebase (Phase-1 Reverse Inference)

Use this skill when the scaffold is being adopted onto an **existing** C#/.NET solution rather than scaffolding a new one. It replaces the Phase-1 interview ([shared-understanding-interview.md](shared-understanding-interview.md)) with a **code-driven inference pass** that produces the same three Phase-1 artifacts by reading the live codebase.

Once `.scaffold/` is populated, the project hands off into the regular workflow: Phase 2 (Resource Definition), `/vertical-slice` for new entities, and the existing Phase-1 Artifact Lifecycle keeps the artifacts current going forward.

## When to use this skill

- The user has an existing C#/.NET solution and wants `.scaffold/` artifacts so future AI sessions reason from a project-specific shared model.
- A team wants to start using `/vertical-slice` against an existing solution; that command's pre-flight requires the three Phase-1 artifacts to exist.
- An audit of language/decision drift is needed - re-running this skill regenerates a snapshot from code and surfaces gaps against any existing `.scaffold/` artifacts.

**Do not use** for greenfield projects - those start at the regular Phase 1 interview.

## Authority

This skill is governed by the Phase-1 Artifact Lifecycle Rule in [../START-AI.md](../START-AI.md) section Phase-1 Artifact Lifecycle Rule. The rule's drift principle - *the artifact loses to code reality* - applies directly here: existing code is authoritative; the generated artifacts must match what the code actually declares, not what the team intended at some earlier point. Developer confirmation is solicited for ambiguity (terminology choices, decision rationale, deferred-vs-deliberate omissions), not for facts the code states plainly.

## Output Artifacts

Same three files as a greenfield Phase 1. Create `.scaffold/` at project root if absent.

1. `.scaffold/domain-specification.yaml` - schema: [domain-specification-schema.md](domain-specification-schema.md). Inferred from `Domain.Model`, EF configurations, repositories, and endpoints.
2. `.scaffold/UBIQUITOUS-LANGUAGE.md` - template: [../templates/ubiquitous-language-template.md](../templates/ubiquitous-language-template.md). Inferred from public type/property/method names across `Domain.Model`, `Application.Models`, `Application.Contracts`, and endpoint routes.
3. `.scaffold/DESIGN-DECISIONS.md` - template: [../templates/design-decisions-template.md](../templates/design-decisions-template.md). Inferred from DI registrations, `RegisterServices.cs`, Aspire `AppHost`, `nuget.config` / `Directory.Packages.props`, and visible architectural choices (dual DbContext, gateway presence, multi-tenancy filter, caching strategy, identity provider).

## Pre-Flight

- [ ] Solution builds: `dotnet build` exits 0. A non-building solution makes inference unreliable - fix or branch from a known-good commit first.
- [ ] Locate the solution file: `*.slnx` (preferred) or `*.sln` at project root.
- [ ] Identify the layer assignment of every project (Domain / Application / Infrastructure / Host / Test) by directory convention and project references.
- [ ] Confirm with the developer: "I'm going to derive Phase-1 artifacts from the existing code. Code wins on any conflict with prior intent. OK to proceed?"
- [ ] If `.scaffold/` already contains any of the three artifacts, ask whether to **replace** (full regenerate), **merge** (see Merge Decision Protocol below), or **abort**.

## Merge Decision Protocol

When the developer chooses **merge**, apply these rules per artifact:

- **Code-derived facts overwrite artifact facts.** Entities, properties, types, relationship types, and DI-visible decisions in the existing artifacts are replaced by what inspection finds. The Inference Rules above govern what counts as a fact.
- **Developer narrative is preserved verbatim.** Rationale text, decision context, and rejected-synonym reasoning in the existing artifacts carry forward unchanged unless the developer rewrites them.
- **Contradicted decisions are superseded, never rewritten.** When code contradicts an existing `D-###`, mark that entry superseded with a forward link and add a new code-inferred `D-###` (`inferred-from: file:line`). This matches the supersede rule in [../README.md](../README.md) section Phase-1 Artifact Lifecycle.
- **Artifact-only entries are removed or annotated.** Entities and terms present in the artifacts but absent from code are removed from `domain-specification.yaml`; their language entries move to Rejected Synonyms or gain a `removed - absent from code` note so the history stays visible.
- **Deferred decisions persist** unless code contradicts them - an undecided entry is not stale just because adoption ran.

## Inspection Order

Walk these sources in order. Earlier sources establish the vocabulary; later sources refine it.

| Pass | Source | Extracts |
|---|---|---|
| 1 | `*.slnx` / `*.sln` | Project list, layer assignment (Domain/Application/Infrastructure/Host/Test), project-name prefix convention (`projectNamePrefix`) |
| 2 | `src/Domain/*Domain.Model/Entities/*.cs` | Entities, properties, types, navigations, aggregate root candidates |
| 3 | `src/Domain/*Domain.Model/Enums/*.cs` | Lifecycle states, status flags, role enumerations |
| 4 | `src/Domain/*Domain.Model/Rules/*.cs` | Invariants, state-transition rules, policy matrices |
| 5 | `src/Infrastructure/*Infrastructure.Data/EntityConfigurations/*.cs` | Relationships (1:N, M:N, owned), indexes, tenancy filters, soft-delete, audit |
| 6 | `src/Application/*Application.Models/**/*.cs` | DTO names, search filters, projection shapes - refines the term list |
| 7 | `src/Application/*Application.Contracts/Services/*.cs`, `.../Repositories/*.cs` | Service surface and read/write split, refines actions/commands vocabulary |
| 8 | `src/Application/*Application.Services/Services/*.cs` | Business operations, action verbs |
| 9 | `src/Host/*Api/Endpoints/*.cs` | Route shapes, HTTP-verb->action mapping, public API surface |
| 10 | `src/Host/*Bootstrapper/RegisterServices.cs` | DI shape - design decisions about caching, identity, multi-tenancy, gateway, scheduling, AI |
| 11 | `src/Host/Aspire/AppHost/**/*.cs` | Hosting model, resource list, external dependencies |
| 12 | `appsettings*.json`, `Directory.Packages.props`, `nuget.config` | Package strategy (feed/local/hybrid), `packagePrefix`, external integrations |

For each pass, summarize findings to the developer in a short recap (same shape as [shared-understanding-interview.md](shared-understanding-interview.md) section Branch Recap Format). Ask: *"Is this correct, or should anything change before I continue?"*

## Codebase-First Assumptions Mode

Do not ask the developer questions the code can answer. Inspect first, then ask only about ambiguity, rationale, or intent not visible in code.

When an inference is likely but not certain, present it as an assumption:

```markdown
### Assumption: {short title}

Evidence:
- `{file:line}` - {what the code states}

Assumption:
- {what will be recorded if accepted}

Risk if wrong:
- {what generated artifact, resource, test, or contract would be affected}

Confidence:
- high | medium | low

Confirm, correct, or mark deferred?
```

Keep at most five unresolved assumptions active. Before writing `.scaffold/` artifacts, each assumption must be confirmed, corrected, or converted to a deferred decision with `Needed Before` populated.

When the developer's answer remains ambiguous and a safe default is not available, drop an inline `[OPEN QUESTION: <single-sentence question>]` marker into the artifact where the gap will surface during later phases (**GR-10**), and mirror it to `HANDOFF.md` section Open Questions. The handoff into Phase 2 must include either a resolution or an explicit non-blocking deferral - markers do not silently carry forward.

## Inference Rules

- **Code statements are facts; developer answers are rationale.** When code says `class Order : Entity` and the developer says "Order isn't really an aggregate root," record both: code-asserted aggregate, developer-flagged ambiguity. Do not silently override the code.
- **Public type/property names map directly to ubiquitous-language terms.** Capture the casing exactly; record rejected synonyms only when the developer names them explicitly.
- **DI registrations are design decisions.** A `services.AddFusionCache(...)` call is a `D-###` decision ("caching strategy: FusionCache + Redis backplane"), even if no markdown ever documented it. Record it with `inferred-from: src/Host/{Project}.Bootstrapper/RegisterServices.cs:NN`.
- **Missing-but-expected features become deferred decisions.** If the scaffold's canonical patterns expect a gateway, multi-tenancy filter, or observability wiring and none is present, record a `D-###` decision with status `deferred` and `inferred-from: absence`. Do not invent the feature.
- **Schema relationships are authoritative for relationship type.** EF `WithMany(...).WithOne(...)` says 1:N; junction tables with composite keys say M:N. Ignore developer claims that contradict the schema.
- **`projectNamePrefix` is read from existing project names, never defaulted.** Inspect the Pass-1 project list. If layer projects carry the solution-name prefix (`{Solution}.Domain.Model`, `{Solution}.Api`), record `projectNamePrefix: solution-name`. If they are bare (`Domain.Model`, `Api`), record `projectNamePrefix: none`. `inferred-from` the `.slnx` project list. Mixed/partial prefixing (some layers prefixed, some bare) is recorded as the observed fact plus an `[OPEN QUESTION]` for the canonical convention going forward - do not silently pick one. Token mechanics: [placeholder-tokens.md - Derivation Rules](placeholder-tokens.md#derivation-rules).
- **State machines are inferred from enums + transitions enforced in services.** If `OrderStatus` exists but no transition rule is enforced anywhere, record the state machine as "implicit / unguarded" and surface it for developer confirmation.

## Decision Confirmation Loop

For every `D-###` decision inferred, present a short block to the developer:

```markdown
### Inferred D-###: {decision title}

Code evidence:
- `{file:line}` - {what the code states}

Inferred selection: {choice}
Inferred rationale: {best guess from code shape, or "unknown - please confirm"}

Confirm, supersede, or correct?
```

Record the developer's answer in the final `DESIGN-DECISIONS.md`. Decisions where the developer says "we never decided that, the code just ended up that way" should be recorded as accepted-by-default with a note - they are still binding going forward.

## Handoff to Existing Workflow

When inference completes and the three artifacts are written:

1. Write `HANDOFF.md` at project root with `currentPhase: 2`, `currentSubPhase: ""`, `contractsScaffolded: false`. Note in section Completed: "Phase 1 adopted from existing codebase via `ai/adopt-codebase.md` inference."
2. Stop. The next session resumes at Phase 2 (Resource Definition) by reading the freshly written `.scaffold/DESIGN-DECISIONS.md` and `.scaffold/domain-specification.yaml`, exactly as a greenfield project would.
3. New entities going forward use `/vertical-slice`; the existing Phase-1 Artifact Lifecycle Rule keeps the three artifacts current.

## Gate

Before declaring the adopt session complete:

- [ ] `.scaffold/domain-specification.yaml` exists and validates against [domain-specification-schema.md](domain-specification-schema.md).
- [ ] `.scaffold/UBIQUITOUS-LANGUAGE.md` and `.scaffold/DESIGN-DECISIONS.md` exist, follow their templates, and satisfy the coverage checks below.
- [ ] Every entity in `Domain.Model/Entities/` appears in `domain-specification.yaml`.
- [ ] Every public type/property name in `Domain.Model` and `Application.Models` is either in `UBIQUITOUS-LANGUAGE.md` or explicitly excluded (e.g., framework base types).
- [ ] At least one `D-###` exists for each visible architectural choice: package strategy, persistence stack, identity provider (if present), caching (if present), gateway (if present), multi-tenancy (if present), hosting model.
- [ ] Every assumption raised during inspection is confirmed, corrected, or deferred with `Needed Before`.
- [ ] `HANDOFF.md` written with `currentPhase: 2`.

## Non-Goals

- **No code is generated by this skill.** Adoption produces docs only. Use `/vertical-slice` for code afterward.
- **No refactoring suggestions.** Even if code violates the scaffold's canonical patterns (e.g., DTO bleed into Domain layer), record the choice as a `D-###` and surface it. Refactoring is a separate decision.
- **No retroactive test generation.** If the existing project lacks tests in a category the scaffold normally produces, record `testingProfile: minimal` (or the closest match) and a deferred decision for promoting later.

## References

- Phase-1 Artifact Lifecycle Rule: [../START-AI.md](../START-AI.md) section Phase-1 Artifact Lifecycle Rule
- Canonical lifecycle detail: [../README.md](../README.md) section Phase-1 Artifact Lifecycle
- Schema: [domain-specification-schema.md](domain-specification-schema.md)
- Templates: [../templates/ubiquitous-language-template.md](../templates/ubiquitous-language-template.md), [../templates/design-decisions-template.md](../templates/design-decisions-template.md)
- Branch recap format (reuse for inspection recaps): [shared-understanding-interview.md](shared-understanding-interview.md) section Branch Recap Format
