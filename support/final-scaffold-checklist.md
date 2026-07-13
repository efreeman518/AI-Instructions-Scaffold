# Final Scaffold Checklist

Load this file after the final enabled Phase 5 sub-phase. It converts "the scaffold seems done" into objective checks.

This is not production-readiness. It verifies that the generated app is a consistent, runnable scaffold.

---

## Required Commands

Run from the generated app root:

```powershell
dotnet restore
dotnet build
dotnet test
```

All three must exit 0. Then walk the **Completion Criteria** below.

If IaC is enabled:

```powershell
az bicep build --file infra/main.bicep
```

If Aspire is enabled:

```powershell
dotnet run --project src/Host/Aspire/AppHost
```

Verify the Aspire dashboard shows all enabled resources healthy before exercising endpoints.

**Live smoke deferral.** The live AppHost boot may be skipped at the final-checklist stage when **all** of the following are recorded in the most recent sub-phase `HANDOFF.md`:

- The sub-phase did not modify `Host/Aspire/AppHost` or the Aspire resource graph (record this fact explicitly, e.g., "AppHost / resource graph not modified this sub-phase").
- A prior sub-phase recorded a green Aspire live boot in `HANDOFF.md` section Validation since the last AppHost change.
- This session's `TestCategory=Unit`, `TestCategory=UI`/`Presentation` (when generated), `TestCategory=Endpoint`, and (where applicable) `TestCategory=Integration` runs were all green.

If any condition is missing, run the live boot. When deferred, copy the prior green boot's discovery evidence into this session's `HANDOFF.md` section Validation and mark the row `deferred - see <prior-sub-phase>`.

---

## API Smoke

Run against the API host or gateway, depending on scaffold mode.

For at least one tenant and one entity:

```text
POST   /v1/tenant/{tenantId}/{entity-route}        -> 201 or 200
GET    /v1/tenant/{tenantId}/{entity-route}/{id}   -> 200
POST   /v1/tenant/{tenantId}/{entity-route}/search -> 200
PUT    /v1/tenant/{tenantId}/{entity-route}/{id}   -> 200
DELETE /v1/tenant/{tenantId}/{entity-route}/{id}   -> 204 or 200
GET    /healthz                                    -> 200 (liveness)
GET    /readyz                                     -> 200 (readiness)
GET    /scalar/v1                                  -> 200
```

Use `curl`, HTTPie, REST Client, or Scalar. Record status codes and endpoint discovery method in `HANDOFF.md`; do not record ephemeral localhost URLs or Aspire-assigned ports.

---

## Completion Criteria

- [ ] `dotnet restore`, `dotnet build`, and `dotnet test` pass. The full `dotnet test` (no filter) is green - every category the scaffold produces is either passing or `Assert.Inconclusive` / `[Ignore]` with a recorded reason. No test assembly aborts in `[AssemblyInitialize]`.
- [ ] Every test that is `[Ignore]`'d or marked `Assert.Inconclusive` for a deferred external dep is named in `HANDOFF.md` section Scaffold Acceptance with the unblocking step.
- [ ] Shared `<packagePrefix>.*` layers resolve according to `packageStrategy`: feed/hybrid feed layers restore from configured private feed (`NUGET_AUTH_TOKEN` or credential provider); local/hybrid local layers exist under `src/Packages/<packagePrefix>.*` and are consumed via `<ProjectReference>`.
- [ ] `.scaffold/UBIQUITOUS-LANGUAGE.md` and `.scaffold/DESIGN-DECISIONS.md` still match the generated entity, service, and endpoint names. Mechanical check: `python {instructionsRoot}/scripts/check-artifact-drift.py --root .` reports no drift (advisory - review each finding against GR-01: fix the artifact first, then code).
- [ ] Generated solution shape matches `skills/solution-structure.md` (no missing project, no orphan no-op stub).
- [ ] `HANDOFF.md` resume state is current: `currentPhase`, `currentSubPhase`, gate result, blockers, next load set.
- [ ] `.scaffold/implementation-plan.md` open questions resolved or explicitly deferred with TODO.
- [ ] Every enabled host has a recorded status in `HANDOFF.md`: `validated`, `partially-validated`, or `blocked` with reason.
- [ ] At least one entity CRUD/search smoke cycle succeeds.
- [ ] `/healthz` and `/readyz` both return 200 on every API/server host that exposes probes; a dependency-failure test makes only `/readyz` unhealthy. UI resources without probes pass when their root URL renders without exception.
- [ ] OpenAPI/Scalar loads.
- [ ] Human acceptance smoke was attempted for at least one primary workflow. Any gap is recorded in `HANDOFF.md` section UAT / Acceptance Gaps with source, current evidence, root cause, and closure plan.
- [ ] **Aspire AppHost clean startup:** `dotnet run --project src/Host/Aspire/AppHost` reaches the dashboard with every registered resource in **Running** state, no exceptions in resource logs, and `/healthz` plus `/readyz` returning 200 on every API/server host that exposes probes. UI resources without probes pass when their root URL renders without exception. Stub-mode external deps (`emulator`, `lazy-optional`, `no-op stub`, `deployment-only`) count as healthy when their stub/emulator path responds.
- [ ] **AI provider lanes (when enabled):** `/api/v1/ai/status` reports Azure Foundry when configured, else Foundry Local when available, else no-op. `Test.Aspire` sets `AiServices:DisableFoundryLocal=true` and only proves Azure live smoke. `Test.FoundryLocal` sets `AiServices:RequireFoundryLocal=true`; missing runtime may be `Assert.Inconclusive`, but installed/discovered runtime with no-op fallback, timeout, or wrong status is failure.
- [ ] **Every UI host starts cleanly - Aspire-registered AND standalone:**
  - Blazor (when enabled): standalone `dotnet run` reaches `Application started` + root URL renders; when added to AppHost, the resource reaches Running and a Refit call returns data (or typed empty state).
  - React/Vite (when enabled): `npm run lint` + `npm run build` pass; standalone Vite root renders; when added to AppHost, the resource reaches Running on its current dynamic URL and one Gateway/API-backed page loads.
  - Uno (when enabled): the selected platform target (`<tfm>-browserwasm` / `<tfm>-android` / `<tfm>-ios`) builds through `TargetFrameworkOverride` and launches where local tooling supports it; browserwasm validation cleans both target `bin` and target `obj` before rebuild; before Android/iOS package builds, restore with `-p:BuildAllUnoTargets=true`; when added to AppHost, the ASP.NET Core WASM wrapper resource reaches Running.
  - Uno `WasmUI` (when generated): at least one `TestCategory=WasmUI` smoke runs. Docker missing may mark `Assert.Inconclusive` with a fix; Docker present starts Aspire testing mode, keeps required resources live, resolves named endpoints, and reaches bridge-ready state.
  - Backend connectivity from UI: at least one entity list page loads against the Gateway/API without console exceptions (empty or typed-empty state acceptable for secondary surfaces).
- [ ] **Primary-actor vertical slice runs end-to-end with seeded data (not just green unit tests).** With the AppHost booted and the Development seeder run, the primary actor's main flow works through the actual UI: the primary list/detail surface shows the seeded records (not an empty list), and one primary-actor action (create/submit/the core domain verb) completes against the running stack. UI interactivity is live (Blazor: interactive render mode opted in, not static SSR; Uno: commands fire and chrome renders). See [../ai/SKILL.md](../ai/SKILL.md) section Scaffold Definition of Done, item 4.
- [ ] If `applicationStyle: switch`, both `Application:Style=Service` and `Application:Style=Cqrs` have at least one endpoint-mode smoke test. The two modes expose the same route templates and response envelopes.
- [ ] No generated source file outside the **scaffold-skipped surface** contains `throw new NotImplementedException`. The skipped surface is limited to: (a) `NoOp*` fallback stubs in `Infrastructure.Stubs/` (or equivalent) registered via `TryAddSingleton`/`TryAddScoped` for entities the scaffold contracts but does not activate, and (b) override methods on `<packagePrefix>.*` repository/storage base types that are only reachable through those `NoOp*` stubs. Per [../ai/contract-scaffolding.md](../ai/contract-scaffolding.md), even these stubs should prefer safe defaults (`Result.Success`, empty collections, completed `Task`) - throwing is permitted only when no safe default exists for the return shape.
- [ ] No scaffold placeholders remain in source/config.
- [ ] No `<packagePrefix>.*` shared base type is reimplemented in application/domain/host layers - they live in feed packages or `src/Packages/<packagePrefix>.*` projects only, per `packageStrategy`.
- [ ] **One public type per file** across all generated `.cs` files in `src/` (including `src/Packages/<Prefix>.*`). File name matches the type. Lumped files (multiple top-level public/internal types) are a failure unless they fall under the exception list in [../skills/solution-structure.md](../skills/solution-structure.md) section Non-Negotiables.
- [ ] Deployment-only dependencies are recorded as non-blocking residuals.
- [ ] **Harness entrypoints are finalized for steady state** (see section Finalize Harness Entrypoints below). `AGENTS.md` carries an app-specific summary **outside** the `<!-- ai-scaffold: start --> ... <!-- ai-scaffold: end -->` markers; `CLAUDE.md` stays an `@AGENTS.md` import stub and `.github/copilot-instructions.md` stays a thin stub pointing at `AGENTS.md`. The `AGENTS.md` marked block keeps only the durable vertical-slice + demoted scaffold/adopt pointers and the conditional graphify block.
- [ ] **Project root is clean.** Only the following files/dirs are expected at the project root after scaffold completion:
  - **Markdown:** `README.md`, `AGENTS.md`, `CLAUDE.md`, `HANDOFF.md`
  - **.NET config:** `global.json`, `nuget.config`, `dotnet-tools.json`, `Directory.Packages.props`, `Directory.Build.props`, `*.slnx`
  - **Ignore files:** `.gitignore`, `.dockerignore`, `.editorconfig`, `.gitattributes`
  - **Dirs:** `src/`, `infra/` (when IaC enabled), `docs/` (optional - when `docs/tech-design.md` is generated, diagrams follow [tech-design-diagrams.md](tech-design-diagrams.md)), `.azure/` (optional), `.github/`, `.instructions/`, `.scaffold/`, `.vscode/` (optional), `.claude/` (optional)
  - All Phase 1/2/3 generated artifacts (`domain-specification.yaml`, `resource-implementation.yaml`, `UBIQUITOUS-LANGUAGE.md`, `DESIGN-DECISIONS.md`, `implementation-plan.md`, `INSTRUCTION-GAPS.md`) live under `.scaffold/`, not at root.
  - No tool output folders left at the repo root: `TestResults/` (after `dotnet test`), and - when the profile includes them - `BenchmarkDotNet.Artifacts/` (comprehensive only) and `.graphify_detect.json` (only if graphify was initialized). Each must land under its owning project, not root. If one appears at root, the output path is not pinned - see [../skills/testing-quality.md](../skills/testing-quality.md) section Deterministic Test Output Location. Pinning the location is optional hardening; `.gitignore` already prevents committing these regardless.
  - Anything else at root (`FOLLOWUP-PLAN.md`, `*.log`, `*.tmp`, ad-hoc notes) is leakage - investigate before declaring the scaffold complete. `FOLLOWUP-PLAN.md` is not a recognized scaffold artifact; if present, ask the developer where it came from.

---

## Finalize Harness Entrypoints

The installer writes the scaffold-routing block into `AGENTS.md` and
`.github/copilot-instructions.md` inside `<!-- ai-scaffold: start --> ... <!-- ai-scaffold: end -->`
markers; `CLAUDE.md`'s marked block is a single `@AGENTS.md` import, so Claude Code
reads whatever `AGENTS.md` says. At the final enabled Phase 5 sub-phase, give these
always-loaded files a steady-state shape so ordinary post-scaffold sessions are not
taxed with one-time bootstrap routing.

Author a short **app-specific** section **outside** the `ai-scaffold` markers in
`AGENTS.md` (above the marked block) - and only there. Claude Code receives it
through the `CLAUDE.md` import, and Copilot agent surfaces read `AGENTS.md`
natively; `.github/copilot-instructions.md` stays a thin stub for older/non-agent
Copilot surfaces, so do not copy the summary into it or into `CLAUDE.md` (add only
harness-specific notes there, outside the markers, if any exist). Keep it short -
the `.scaffold/` docs remain the source of truth; this section is an orientation
pointer, not a copy:

- App name + one-line purpose.
- Architecture/layering in 1-3 lines, or a pointer to the generated solution shape (see [../skills/solution-structure.md](../skills/solution-structure.md)).
- Build / test / run commands for this app (e.g. `dotnet build`, `dotnet test`, `dotnet run --project src/Host/Aspire/AppHost`).
- Pointers to `.scaffold/UBIQUITOUS-LANGUAGE.md`, `.scaffold/DESIGN-DECISIONS.md`, and `README.md`.

Do not edit inside the markers - that block is installer-managed and is overwritten
on re-install. It already carries the durable vertical-slice pointer, the single
demoted full-scaffold/adopt pointer (`load .instructions/START-AI.md`), and a
conditional graphify block that activates only when `graphify-out/graph.json` exists.
Content outside the markers is preserved across re-installs, so the app summary is
safe there.

---

## Post-Scaffold Deployment Handoff

Scaffold completion is local-complete per **GR-11**; deployment is a separate, human-triggered track. At the final enabled Phase 5 sub-phase, copy the applicable items below into the **Production Deployment TODOs** section at the top of `HANDOFF.md` (see [HANDOFF.md](HANDOFF.md)) so the remaining work is the first thing a developer reads. When the team is ready to go live:

- **Provision live infrastructure per IaC** - [../skills/iac.md](../skills/iac.md) section Deployment, plus the manual items in section One-time, account-bound steps (resource group, federated credentials, registry wiring).
- **Configure CI/CD** - [../skills/cicd.md](../skills/cicd.md) section Required Secrets, plus the Required Variables and Environments sections in the same file.
- **Flip deployment-only stubs** - walk the deferred external dependencies recorded in `HANDOFF.md`: provision each, fill its config section, remove or gate the `// TODO: [CONFIGURE]` stub, and re-enable the named `[Ignore]`/`Assert.Inconclusive` tests (see [../ai/SKILL.md](../ai/SKILL.md) section Scaffold Definition of Done, item 6).
- **Production DB migration** - [../skills/cicd.md](../skills/cicd.md) section Production DB Migration (Migrator Job) (one-shot migrator job before image swap; schema leads code).

---

## Post-Scaffold Recommendations (Optional)

Alongside the deployment TODOs, copy the item below into `HANDOFF.md` as an optional TODO. It is a recommendation for the operator to consider, never a completion criterion.

- **Consider initializing graphify for this repo** - post-scaffold is the cheapest build point: the knowledge layer (`.scaffold/` + `docs/`) is at its peak and `src/` is at its smallest, and future sessions already prefer the graph once `graphify-out/graph.json` exists. Corpus is `.scaffold/` + `docs/` + `src/` (tests included); exclude `.instructions/` and `HANDOFF.md` via `.graphifyignore`. Pick the layer by the `.scaffold`+`docs` vs `src/` LOC ratio and follow the setup, ignore-file, and post-commit-hook guidance in [context-tooling.md](context-tooling.md). Operator opt-in: the full layer spends model tokens and harness enablement is a per-operator choice.
  - **Full layer: build with `graphify . --wiki`** to also emit the local agent-crawlable wiki (`graphify-out/wiki/index.md` + one article per community + god nodes). Value: it is the cheap orientation entry point - agents skim the wiki before spending graph queries or file reads. When: emit it in the initial full-layer pass (clustering already runs, so the wiki is nearly free there); after later code changes regenerate it with `graphify export wiki` (renders from `graph.json`, zero model cost), and rerun a full `graphify . --wiki` at phase boundaries to refresh the semantic layer and wiki together. Keep `graphify-out/wiki/` gitignored per the split in [context-tooling.md](context-tooling.md) - it is regenerable, so it stays out of git unless explicitly requested. Skip `--wiki` for a structure-only layer: no communities, little to render.

---

## If A Check Fails

- Build/test failure: one focused fix pass, rerun the exact failing command.
- Feed failure: fix `nuget.config`, `Directory.Packages.props`, or project package references before changing code.
- Structure failure: generate the missing scaffold artifact instead of loosening the validator.
- Language failure: update `.scaffold/UBIQUITOUS-LANGUAGE.md` or `.scaffold/DESIGN-DECISIONS.md` to match the accepted domain model before changing code names.
- Host/runtime failure: record blocker in `HANDOFF.md`, continue only if the failed host is optional or dependency-only.
- Acceptance gap: record the gap in `HANDOFF.md` section UAT / Acceptance Gaps, identify whether it is product behavior, test coverage, environment, or instruction guidance, then fix only the blocking class for the current scaffold scope.
- Instruction gap: append to `.scaffold/INSTRUCTION-GAPS.md` in the generated app.
