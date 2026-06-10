# Prompt Catalog

Human-facing prompt catalog for starting or resuming scaffolding sessions.

Use this file as a convenience layer only. [START-AI.md](../START-AI.md) remains the canonical operational bootstrap for the AI session router, version checks, phase loading rules, and session boundaries.

## How To Use

1. Start from [START-AI.md](../START-AI.md).
2. Copy the prompt for the current phase or resume path.
3. Replace `{...}` placeholders with real values.
4. Keep the one-phase-per-session rule from [START-AI.md](../START-AI.md).

**First time?** Start with [minimum-viable-scaffold.md](minimum-viable-scaffold.md) instead - it bundles a pruned prompt path for an API-only, single-entity scaffold. Come back here when you outgrow it.

Reference-app rules (when to consult, local vs MCP, do-not-copy-wholesale) live in [reference-app.md](reference-app.md); the phase -> area pointer map is [taskflow-proof-map.md](taskflow-proof-map.md). [START-AI.md](../START-AI.md) only routes to those files.

## Phase 1 - Domain Discovery (Session 1)

```text
Load .instructions/START-AI.md. This is a new project - no HANDOFF.md yet.
Run the Tooling Check from START-AI.md; use Microsoft Docs or Context7 only if current docs are needed.
Generate a domain-specification YAML for a new application called {ProjectName}.
The business is: {one-sentence business description}.
Key entities: {entity list}.
Follow .instructions/ai/shared-understanding-interview.md before writing final artifacts.
Create .scaffold/domain-specification.yaml, .scaffold/UBIQUITOUS-LANGUAGE.md, and .scaffold/DESIGN-DECISIONS.md (create the .scaffold/ directory at project root if absent).
Review each artifact against the Phase 1 schema before closing the session.
When the artifacts are complete and reviewed, write HANDOFF.md to the project root and close the session.
```

## Phase 2 - Resource Definition (Session 2)

```text
Load .instructions/START-AI.md and HANDOFF.md from the project root.
Run the Tooling Check; use Microsoft Docs or Context7 only if current docs are needed.
Generate the resource implementation YAML per .instructions/ai/resource-implementation-schema.md.
Read .scaffold/DESIGN-DECISIONS.md first and resolve any parent decisions that affect resource mapping.
Mode: {full|lite|api-only}. Testing profile: {minimal|balanced|comprehensive}.
Declare externalDependencyModes for every external dependency before finalizing.
When the YAML is complete and reviewed, update HANDOFF.md and close the session.
```

## Phase 3 - Implementation Plan (Session 3)

```text
Load .instructions/START-AI.md and HANDOFF.md from the project root.
Run the Tooling Check; use GitHub or Azure tooling only if this phase needs repo or cloud access.
Generate an implementation plan per .instructions/ai/implementation-plan.md template.
Read .scaffold/UBIQUITOUS-LANGUAGE.md and .scaffold/DESIGN-DECISIONS.md first. Populate the Decision Dependency Graph.
Run the Phase 3 pre-flight from START-AI.md section Phase Router (branches on packageStrategy).
Confirm `dotnet restore` exits 0 in all modes. Verify `dotnet ef` is available.
Flag open questions before writing .scaffold/implementation-plan.md.
When the plan is reviewed and open questions resolved, update HANDOFF.md and close the session.
```

## Phase 4 - Contract Scaffolding (Session 4)

```text
Load .instructions/START-AI.md and HANDOFF.md from the project root.
Run the Tooling Check; use GitHub tooling only if this phase needs repo access.
Load the Phase 4 file set listed in START-AI.md section Phase Router.
Generate the contract scaffold per .instructions/ai/contract-scaffolding.md:
  solution structure, interfaces, DTOs, entity shells, test infrastructure, no-op DI stubs.
Gate: `dotnet build` succeeds on the full solution including test projects.
When gate passes, set currentPhase: 5, currentSubPhase: 5a, and contractsScaffolded: true in HANDOFF.md and close the session.
```

## Phase 5 - Session Start

Start every Phase 5 sub-phase with:

```text
Load .instructions/START-AI.md and HANDOFF.md from the project root.
Run the Tooling Check for this sub-phase.
Read the Phase 5 file table in .instructions/ai/SKILL.md and load the files for the current sub-phase.
```

Then append the relevant sub-phase block below.

### 5a - Foundation (TDD)

```text
Follow .instructions/ai/tdd-protocol.md: write domain/rule/repository tests first (red), then implement to green.
Contracts and entity shells already exist from Phase 4. Activate builders after entity logic is implemented.
Gate: `dotnet build` + `dotnet test --filter TestCategory=Unit`.
When gate passes, update HANDOFF.md (currentSubPhase: 5b) and close session.
```

### 5b - App Core + Runtime/Edge (TDD for app/API, tests-after for runtime)

```text
Follow .instructions/ai/tdd-protocol.md for application/API code: write service tests (red), implement services (green),
write endpoint tests (red), implement endpoints (green). Replace no-op DI stubs with real implementations.
Then scaffold the enabled runtime concerns ({gateway/aspire/caching/observability/security/multi-tenant}) and add their tests.
Gate: `dotnet build` + `dotnet test --filter TestCategory=Unit|TestCategory=Endpoint` + app starts via Aspire (when enabled).
When gate passes, update HANDOFF.md and close session.
```

### 5c - Optional Hosts (Tests-After)

```text
Scaffold only the enabled optional hosts named in .scaffold/resource-implementation.yaml: {scheduler/functionapp/uno-ui/blazor-ui/react-ui/notifications}.
Update hostGates in HANDOFF.md per host as each reaches scaffolded -> validated.
Close session when all enabled hosts are validated (or blockers are recorded for deployment-only deps).
```

Note: Uno UI is always a dedicated session within 5c. Use the same session start prompt but scope only to Uno UI.

### 5d - Quality Gates + Delivery

```text
Unit/endpoint/integration tests already exist from 5a/5b/5c.
Scaffold quality gate tests (architecture, load, benchmarks, mutation per profile: {minimal|balanced|comprehensive}), IaC, CI/CD, Dockerfile.
Run full regression: `dotnet test`. Also `az bicep build --file infra/main.bicep` (if IaC enabled).
Update HANDOFF.md and close session.
```

### 5e - Integration (Auth + AI)

```text
Finalize auth: replace stubs with config-driven scaffold principal ({Entra|OAuth2|social|hybrid}).
If `includeAiServices: true`, also scaffold AI integration: {search indexing/agent service} as enabled in .scaffold/resource-implementation.yaml.
Gate: `dotnet build` + `dotnet test --filter TestCategory=Endpoint` (auth) + `dotnet test --filter TestCategory=Unit` (AI). When all enabled capabilities pass, update HANDOFF.md and close session.
```

## Final Scaffold Validation

```text
Load .instructions/support/final-scaffold-checklist.md.
Walk through the checklist manually: build, test, run smoke checks for each enabled host.
Record exact results, blockers, and deployment-only residuals in HANDOFF.md.
```

## Resume From HANDOFF

```text
Load .instructions/START-AI.md and HANDOFF.md from the project root.
Resume from currentPhase/currentSubPhase. Load the files listed in Next Load Set. Check Blockers before proceeding.
```

## Add New Entity (Existing Project)

```text
Load .instructions/START-AI.md. No HANDOFF.md needed - this is an add-entity operation.
Add entity {Entity} to the existing solution using .instructions/support/vertical-slice-checklist.md fast-path.
Follow patterns established by {ExistingEntity}.
```
