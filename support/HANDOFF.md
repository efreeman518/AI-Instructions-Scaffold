# HANDOFF.md

Create this file in the **target project root** at the end of every phase and each Phase 5 sub-phase session. The next AI session loads `START-AI.md` + this file only - nothing else - and resumes from `currentPhase` / `currentSubPhase`.

```yaml
instructionVersion: ""
currentPhase: ""           # next phase to run: 1 | 2 | 3 | 4 | 5
currentSubPhase: ""        # next Phase 5 sub-phase to run: 5a | 5b | 5c | 5d | 5e (blank before Phase 5)
scaffoldMode: ""           # full | lite | api-only - drives load-set sizing (see ai/SKILL.md section Load-Set Sizing)
testingProfile: ""         # minimal | balanced | comprehensive
contractsScaffolded: false # set true after Phase 4 completes
enabledFeatures:
  includeApi: true
  useAspire: true
  includeGateway: false
  includeScheduler: false
  includeFunctionApp: false
  includeUnoUI: false
  includeBlazorUI: false
  includeReactUI: false
  includeNotifications: false
  includeIaC: true
  includeGitHubActions: false
  includeAzd: false
  includeAiServices: false
testStatus:                # updated per sub-phase - keys match TestCategory values
  unitTests: not-started   # TestCategory=Unit       - not-started | red | green
  uiTests: not-started     # TestCategory=UI         - not-started | red | green
  presentationTests: not-started # TestCategory=Presentation - not-started | red | green
  endpointTests: not-started # TestCategory=Endpoint
  integrationTests: not-started # TestCategory=Integration (Phase 5d; Testcontainers SQL / real external services)
hostGates:                 # Phase 5c per-host status: not-started | scaffolded | partially-validated | validated | blocked
  scheduler: not-started
  functionApp: not-started
  unoUI: not-started       # always a dedicated session
  blazorUI: not-started
  reactUI: not-started
  notifications: not-started
resumeCommand: ""          # exact prompt to paste at the next session start
toolingNotes: ""           # CLIs/MCPs discovered in Phase 3; note any missing or unavailable
instructionGapsPath: ".scaffold/INSTRUCTION-GAPS.md"
```

## Production Deployment TODOs

Populated by the **final enabled Phase 5 sub-phase session** as the first section a developer reads; leave as `<not yet at final sub-phase>` until then. The scaffold is complete and runnable locally (stubs/emulators), but it is **not deployable** until every item here is done. Derive the list from [final-scaffold-checklist.md](final-scaffold-checklist.md) section Post-Scaffold Deployment Handoff and the Deferred External Dependencies table below; typical entries:

- [ ] Provision live Azure infrastructure (hand-written Bicep deploy or `azd provision` - see `skills/iac.md`)
- [ ] Set CI/CD secrets, variables, and environments; enable `push` triggers on `cd.yml`/`provision.yml` (currently `workflow_dispatch`-only)
- [ ] Flip each deployment-only stub: provision the resource (auth tenant, AI endpoints, ...), fill its config section, remove/gate the `// TODO: [CONFIGURE]` stub, re-enable its `[Ignore]`/inconclusive tests
- [ ] Run the production DB migration path

## Last Session Summary

Three to five lines for the next agent resuming cold: what this session actually built or changed, the key decisions made (cite `D-###` from `.scaffold/DESIGN-DECISIONS.md`), and any non-obvious gotcha not captured by the state fields above. Narrative only - do not restate `Completed`, `Next Step`, or the YAML state. Leave as `<first session>` until a phase has closed.

- <first session>

## Next Step

- <none>

## Next Load Set

Load only these files next session (do not load anything else until this list is confirmed):

- `START-AI.md`
- `HANDOFF.md`
- <none>

## Environment Setup

Run before `dotnet restore` in any new session:

- <none>

## Current Objective

- Goal:
- Scope for this session:

## Open Questions

Mirror every `[OPEN QUESTION: ...]` marker present in `.scaffold/*` at session close (**GR-10**). One row per marker; resolve or downgrade before the next phase gate.

| Marker text | Artifact:Line | Blocks phase | Disposition (resolved / deferred D-### / non-blocking) |
|---|---|---|---|
| | | | |

## Deferred

Out of scope for this session - do not attempt unless explicitly re-scoped:

- <none>

## Blockers

- None

## Notes

- Keep `domain-specification.yaml`, `resource-implementation.yaml`, `UBIQUITOUS-LANGUAGE.md`, and `DESIGN-DECISIONS.md` under `.scaffold/` in the target project. `HANDOFF.md` itself stays at project root.
- `currentPhase` and `currentSubPhase` always describe the next work to run, not the phase just completed. Record completed gate evidence in `Completed` and `Validation` per [execution-gates.md](execution-gates.md) section Verification Evidence Rule (observed output only, never anticipated).
- At Phase 1 close, summarize unresolved/deferred design decisions and confirm they do not block Phase 2.
- Keep `enabledFeatures` flags in sync with `.scaffold/resource-implementation.yaml` canonical hosting/IaC/AI toggles.
- For Phase 4, set `currentPhase: 5`, `currentSubPhase: 5a`, and `contractsScaffolded: true` after the gate passes. Phase 5a/5b require this flag.
- For Phase 5a/5b, update `testStatus` as tests transition: `not-started` -> `red` (tests written, failing) -> `green` (implementation complete, tests passing). This tracks TDD progress across sessions.
- For Phase 5c (Optional Hosts), update `hostGates` per-host as each host moves through `scaffolded` -> `partially-validated` -> `validated` or `blocked`. Do not mark the sub-phase complete until all enabled hosts reach `validated` or have a recorded blocker.
- Note unresolved infra/auth/package-feed issues here rather than retrying them repeatedly.
- Record instruction gaps in `.scaffold/INSTRUCTION-GAPS.md`, not inside `.instructions/`, during consumer app scaffolding.
- Keep entries short so the next AI turn can resume without reloading unnecessary docs.
- Verify HANDOFF.md is well-formed (correct sub-phase, gate result, next-load-set populated, blockers itemized) before ending a phase session.
- **AI-client wiring currency.** When AI provider wiring changed this session, re-derive the AI-client lines in `Last Session Summary` and any `D-###` AI-client decision references from the **current** code - never carry a removed helper name forward (e.g. a deleted `AddEF...`-style chat-client registration). The AI-client (provider bootstrap, `IChatClient` registration, `AiProviderInfo`/status wiring) is a recurring drift point; cross-check against [skills/ai-integration.md](../skills/ai-integration.md) before closing.
- **Ephemeral URLs:** Do not record Aspire dashboard URLs, proxy ports, or host endpoints. These are assigned at runtime and change between launches. Instead, record the discovery method (e.g., "read dashboard URL from `dotnet run` output, then check resource list for host URLs").

## Phase-1 Artifact Currency

Verify before closing the session. Per [../START-AI.md](../START-AI.md) section Phase-1 Artifact Lifecycle Rule, *fix the artifact first, then the code; when drift exists, the artifact loses to code reality.*

- [ ] No new domain term, role, event, or action was introduced this session without an entry in `.scaffold/UBIQUITOUS-LANGUAGE.md`.
- [ ] No new entity, relationship, lifecycle state, or schema change was introduced without updating `.scaffold/domain-specification.yaml`.
- [ ] No new design decision (or revision of an earlier one) was introduced without an entry in `.scaffold/DESIGN-DECISIONS.md` (mark superseded entries; do not silently rewrite).
- [ ] If drift was discovered between code and artifacts, the artifacts were updated to match accepted reality before closing.

Notes on artifact updates this session (term added, decision superseded, schema reshaped):

- <none>

## Residual Environment Note

Known local or CI quirks not resolved this session:

- <none>

## Validation Findings Resolved

Issues encountered and fixed this session (so the next session does not re-investigate):

- <none>

## UAT / Acceptance Gaps

Use this for human smoke-test or review findings. Do not mix these with instruction gaps unless the root cause is bad scaffold guidance.

| Source | Gap | Current Evidence | Root Cause | Closure Plan | Status |
|--------|-----|------------------|------------|--------------|--------|
| | | | | | |

## Completed

- <none>

## Validation

- Command:
- Result:
- Notes:

### Validation since the last AppHost change

Use this section for Phase 5b runtime/Aspire evidence. Leave blank when `useAspire: false`.

- AppHost changed:
- Command:
- Result:
- Evidence:
- Data-plane spot check:

### Per-Host Gate Status (Phase 5c)

For each enabled optional host, record its individual gate result. Use `validated`, `scaffolded`, `partially-validated`, or `blocked` - never claim Phase 5c complete if any enabled host is only scaffolded. Gateway is a Phase 5b runtime concern, not a Phase 5c host - record its status under section Validation, not here.

| Host | Build | Host-Specific Gate | Status | Notes |
|------|-------|--------------------|--------|-------|
| Scheduler | | | | |
| Function App | | | | |
| Uno UI | | | | |
| Blazor UI | | | | |
| React UI | | | | |
| Notifications | | | | |

## Scaffold Acceptance

Filled out at the end of the final enabled Phase 5 sub-phase, before closing the scaffold. Records evidence for [final-scaffold-checklist.md](final-scaffold-checklist.md); it does not redefine the criteria.

| Gate | Command | Result | Notes |
|------|---------|--------|-------|
| Build | `dotnet build` | | |
| Tests (all categories, unfiltered serial) | `dotnet test .\{SolutionName}.slnx --no-build -m:1` | | Include passing count, ignored count, inconclusive count |
| Aspire AppHost startup | `dotnet run --project src/Host/Aspire/AppHost` | | Confirm every resource reached Running and `/healthz` plus `/readyz` return 200 |
| Blazor host (when enabled) | `dotnet run --project src/UI/{Project}.Blazor` | | Standalone + Aspire-registered (both) |
| Uno host (when enabled) | Clean target browserwasm `bin` + `obj`, then `dotnet restore src/UI/{Project}.Uno/{Project}.Uno.csproj -p:BuildAllUnoTargets=true -p:EnableUnoWasm=true`; build selected target with `dotnet build ... -p:TargetFrameworkOverride=<target> --no-restore -m:1` + launch/wrapper-host check | | Per chosen platform target; iOS simulator/device requires macOS |
| API smoke (one entity) | curl/HTTPie/Scalar against the gateway or API | | Record discovery method, not the ephemeral URL |

### Deferred External Dependencies

For every `[Ignore]` test or `Assert.Inconclusive` branch left in the scaffold, record: what it gates, what step unblocks it, and the named test/assembly that turns green when unblocked.

| Test / Assembly | Gates | Unblocking Step | Owner |
|-----------------|-------|-----------------|-------|
| | | | |
