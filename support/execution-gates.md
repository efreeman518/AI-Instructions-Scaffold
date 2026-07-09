# Execution Gates & Validation

Single source of truth for compile/test/run checkpoints across implementation phases.

Use this file for:
- phase-by-phase validation commands,
- exit criteria,
- pre-merge quality gates.

Run-once operator setup and the Phase 3 pre-flight live in [operator-setup.md](operator-setup.md).

If another file disagrees on validation gates or commands, this file wins. Session routing and load rules remain owned by [../START-AI.md](../START-AI.md) and [../ai/SKILL.md](../ai/SKILL.md). The 1-page binding-rule index (`GR-01`...`GR-17`) lives at [../GROUND-RULES.md](../GROUND-RULES.md); gates below cite the `GR-NN` they enforce.

---

## Operator Setup & Phase 3 Pre-Flight

Run-once machine/repo setup (scope selection, development tools, tracked-source validation, MCP servers) and the Phase 3 pre-flight (shared base-type / package-feed readiness, tooling verification, gate-time amendment protocol) moved to [operator-setup.md](operator-setup.md). Complete those before the Phase 4 build/test gates below run.

---

## Core Loop (Run After Each Scaffolding Sub-Phase)

Run from solution root. Default per-sub-phase loop:

```powershell
dotnet build
dotnet test --filter "TestCategory=Unit"   # or scope to current sub-phase (Endpoint, Integration, etc.)
```

Run `dotnet restore` only when one of the following is true (otherwise skip - it is wasted work):

- `Directory.Packages.props` or any `.csproj` changed since the last restore.
- Phase-boundary transition (Phase 4 -> 5a, 5a -> 5b, etc.).
- Operator forces a clean restore (e.g., feed change, lock-file corruption).

Phase-completion gates and the Pre-Merge Gate still run a full `dotnet restore` - see section Phase Gates and section Pre-Merge Gate.

Gate passes when build and the scoped test command succeed (plus any sub-phase-specific checks listed below).

**Full-solution build flakiness (WASM/browser UI):** when the solution includes a WASM/browser UI project, its build target can lock its output DLL (VBCSCompiler), so a concurrent full-solution `dotnet build` fails intermittently. Prefer building per-project, or run `dotnet build-server shutdown` before a full-solution build. See [troubleshooting.md](troubleshooting.md).

**TDD note:** For Phase 5a/5b, the TDD protocol expects tests to fail (red) before implementation and pass (green) after. The core loop verifies the green state. See [../ai/tdd-protocol.md](../ai/tdd-protocol.md).

---

## Verification Evidence Rule

A gate is only as trustworthy as the evidence behind it. Apply on every phase and sub-phase:

- A gate's `Result`, a `testStatus` value, a `hostGates` value, or a `Completed` entry stays blank (or `not-started`) until the command has actually run in this session.
- Paste observed output - passing/ignored/inconclusive counts, exit code, the resource-Running line - never the output you expect. If you did not run it, it is not green.
- `dotnet test` is not green on a non-zero exit code or any aborted assembly, regardless of individual test results.
- If a command was skipped (out of scope, blocked, deferred), say so explicitly with the reason - do not leave a reader to infer it passed.

This guards the most common handoff defect: a `HANDOFF.md` that reports success the session never demonstrated.

---

## Phase Gates

## 4 - Contract Scaffolding

Exit criteria:
- [ ] Solution structure matches `skills/solution-structure.md`
- [ ] Every entity from `.scaffold/resource-implementation.yaml` has: interface, DTO, entity shell, builders
- [ ] All no-op stubs satisfy their interfaces
- [ ] `RegisterServices.cs` wires all no-op stubs
- [ ] Test.Support contains `WebApplicationFactoryBase` (thin adapter over `EfWebApplicationFactoryBase`), `JsonTestOptions`, `InMemoryDbBuilder`, `TestConstants`, and `Builders/{Entity}Builder` shells; `LocalSqlSettings` lives in the AppHost project; unit tests are flat classes (no shared unit-test base)
- [ ] `Test.Endpoints/CustomApiFactory.cs` and `Test.E2E/SqlApiFactory.cs` inherit/use the shared `WebApplicationFactoryBase` (no duplicated swap-out plumbing); `Test.Integration/Infrastructure/*ContainerFixture` + `IntegrationTestSetup` (component) and `Test.Aspire/AspireTestHost` + `AspireMeshLifecycle` (mesh) all compile
- [ ] `{Entity}DtoBuilder` returns valid DTOs
- [ ] No domain logic in entity shells (only `throw new NotImplementedException`)
- [ ] `<packagePrefix>.*` shared base types are consumed from feed packages or `src/Packages/<packagePrefix>.*` projects per `packageStrategy` - never reimplemented in application/domain/host layers
- [ ] Phase 4 scaffold structure validator passes
- [ ] **Phase 4 test shells pass:** `dotnet test --filter "TestCategory=Unit|TestCategory=Endpoint"` exits 0 (no assemblies abort in `[AssemblyInitialize]`, no shells throw)

Commands:

```powershell
dotnet restore
dotnet build
dotnet test --filter "TestCategory=Unit|TestCategory=Endpoint"
```

---

## 5a - Foundation (TDD)

Exit criteria:
- [ ] Domain entities exist with real logic (shells replaced)
- [ ] Domain rule tests pass
- [ ] Repository tests pass with `InMemoryDbBuilder`
- [ ] `{Entity}Builder.Build()` activated (returns valid entities)
- [ ] No-op repository stubs replaced with real implementations in `RegisterServices.cs`
- [ ] DbContext files compile with EF configurations

Commands:

```powershell
dotnet build
dotnet test --filter "TestCategory=Unit"
dotnet test --filter "TestCategory=LiveAI" # only when a live provider is intentionally available
dotnet test src/Test/Test.FoundryLocal/Test.FoundryLocal.csproj --filter "TestCategory=LiveAI" # local live lane
```

Scaffold migration (remove old, create fresh baseline - see [../patterns/data-layer-wiring.md](../patterns/data-layer-wiring.md)):

> **Flow guard (GR-13):** The remove/recreate path below is greenfield `/scaffold` only. In `/scaffold-adopt` and `/vertical-slice` (brownfield, established app) do **not** run `migrations remove --force` - preserve existing migration history and add an additive migration instead: `dotnet ef migrations add <Change> --project ... --startup-project ... --context {App}DbContextTrxn`.

```powershell
# Greenfield /scaffold only: remove any existing migrations first
dotnet ef migrations remove --force `
  --project src/Infrastructure/{Project}.Infrastructure.Data `
  --startup-project src/Host/{Host}.Api

# Create a clean baseline
dotnet ef migrations add InitialCreate `
  --project src/Infrastructure/{Project}.Infrastructure.Data `
  --startup-project src/Host/{Host}.Api `
  --context {App}DbContextTrxn
```

> **Scaffold rule (GR-13):** During a greenfield scaffold, always start fresh. Do not accumulate incremental migrations until the baseline is established and the project is in production. Brownfield/slice flows are additive - see the flow guard above.

## 5b - App Core + Runtime/Edge (TDD for app/API, tests-after for runtime)

Exit criteria:
- [ ] Service unit tests pass (mock-based, via Moq)
- [ ] Endpoint integration tests pass (via `CustomApiFactory` + `WebApplicationFactory`)
- [ ] No-op service stubs replaced with real implementations in `RegisterServices.cs`
- [ ] API endpoint mappings added in `WebApplicationBuilderExtensions.cs`
- [ ] `DbSet<{Entity}>` exists in Trxn + Query DbContexts
- [ ] API host builds cleanly

Commands:

```powershell
dotnet build
dotnet test --filter "TestCategory=Unit|TestCategory=Endpoint"
```

### Runtime / Edge concerns (within 5b, tests-after)

Required:
- host startup path is healthy for enabled runtime concerns,
- Aspire wiring works when enabled,
- infrastructure tests written and passing (health checks, configuration loading, caching).

Runtime/Host checks (enabled features only):

### Aspire AppHost

Preflight (run before first launch - see [../skills/aspire.md](../skills/aspire.md) section Preflight):
- [ ] Docker running (`docker info` succeeds)
- [ ] No stale containers holding required ports (`docker ps`)
- [ ] `dotnet restore` on AppHost succeeds

Gate:
- [ ] `src/Host/Aspire/AppHost/AppHost.csproj` uses `Aspire.AppHost.Sdk` MSBuild SDK
- [ ] Required Aspire CLI env vars are set before terminal `dotnet run`
- [ ] `dotnet build src/Host/Aspire/AppHost` succeeds
- [ ] `dotnet run --project src/Host/Aspire/AppHost` starts resources
- [ ] Dashboard reachable (URL from console output - do not reuse prior session URLs)
- [ ] **All registered resources reach Running with no `Error`/`Critical` log entries from project-owned categories**
- [ ] Health probes return 200: `/healthz` (liveness - all checks) and `/readyz` (readiness - only checks tagged `ready`) on every API/host project once that host declares itself ready (Aspire-registered UIs that don't expose health probes count as healthy when their root URL renders without exception). Gate readiness on `/readyz` plus Aspire `WaitForResourceHealthyAsync`, not on a resource merely reaching `Running` - `Running` precedes the host accepting requests.
- [ ] Data-plane spot check: at least one backing store (SQL tables exist, Redis reachable, seed rows present) verified directly - not just via dashboard liveness
- [ ] **Stub-mode external dependencies (`emulator`, `lazy-optional`, `no-op stub`, `deployment-only`) respond without throwing** - live cloud credentials are not required for this gate

### Gateway

- [ ] Gateway build succeeds
- [ ] Gateway can route to API via configured cluster/service discovery

Commands:

```powershell
dotnet build
dotnet test --filter "TestCategory=Unit|TestCategory=Endpoint"
dotnet run --project src/Host/Aspire/AppHost
```

After Aspire verification, write infrastructure tests (health checks, config loading, caching) and re-run `dotnet test --filter "TestCategory=Unit|TestCategory=Endpoint"` to confirm. Do not run an unfiltered `dotnet test` here - service-level integration tests live in `Test.Integration` and are scoped to the Phase 5d quality regression.

## 5c - Optional Hosts (Tests-After)

Run only for enabled hosts.

> **Scaffold vs Complete:** Mark 5c complete only when each enabled host has a validated build AND its host-specific gate result recorded below. Build-only success is recorded as `scaffolded` or `partially-validated`, never `validated` - the handoff must reflect per-host gate status.

Function App:

- [ ] `local.settings.json` contains required runtime keys and trigger bindings
- [ ] Azurite/dev-tunnel/ngrok started if required by triggers

```powershell
func host start --verbose
```

Uno UI:

- [ ] `uno-check` validates workloads
- [ ] Gateway/OpenAPI endpoint reachable for client generation
- [ ] Kiota client generation completes (if used)
- [ ] UI builds one selected Uno target at a time through `TargetFrameworkOverride`
- [ ] Browserwasm wrapper host builds if the Uno app is registered in Aspire

```powershell
uno-check
Remove-Item -Recurse -Force src/UI/{Project}.Uno/bin/Debug/$(LatestStableTfm)-browserwasm, src/UI/{Project}.Uno/obj/Debug/$(LatestStableTfm)-browserwasm -ErrorAction SilentlyContinue
dotnet restore src/UI/{Project}.Uno/{Project}.Uno.csproj -p:BuildAllUnoTargets=true -p:EnableUnoWasm=true
dotnet build src/UI/{Project}.Uno/{Project}.Uno.csproj -p:TargetFrameworkOverride=$(LatestStableTfm)-browserwasm -p:EnableUnoWasm=true --no-restore -m:1
dotnet build src/UI/{Project}.Uno/{Project}.Uno.csproj -p:TargetFrameworkOverride=$(LatestStableTfm)-android --no-restore -m:1
dotnet build src/UI/{Project}.Uno/{Project}.Uno.csproj -p:TargetFrameworkOverride=$(LatestStableTfm)-ios --no-restore -m:1
dotnet build src/Host/{Project}.Uno.WasmHost/{Project}.Uno.WasmHost.csproj
```

Run only the targets selected in `.scaffold/resource-implementation.yaml`. Keep platform builds serial (`-m:1`) to avoid shared `obj/` asset races. The `BuildAllUnoTargets=true` restore is required when the project defaults to browserwasm; it prevents mobile builds from packaging a browser-only NuGet asset graph.

For Uno WASM, clean both target `bin` and target `obj` before a validation rebuild. If `WasmUI` tests are generated, run one smoke test before marking the UI validated:

```powershell
dotnet test src/Test/Test.PlaywrightUI/Test.PlaywrightUI.csproj --filter TestCategory=WasmUI
```

The `WasmUI` harness is default-on. It starts Aspire in testing mode when Docker is present and marks tests `Assert.Inconclusive` only when prerequisites are missing or `{APP}_WASM_TESTS_ENABLED=false`.

If targeting Android (`<tfm>-android`):
- [ ] Android Studio or SDK command-line tools installed with Platform-Tools, Emulator, one recent platform, and one AVD
- [ ] Android SDK path resolved (see `skills/ui-uno-platforms.md` section Android SDK Discovery)
- [ ] Android restore/build uses `dotnet restore ... -p:BuildAllUnoTargets=true` followed by `dotnet build ... -p:TargetFrameworkOverride=$(LatestStableTfm)-android --no-restore`
- [ ] `project.assets.json` contains `Uno.WinUI.Runtime.Skia.Android` for Skia Android targets before runtime debugging starts
- [ ] `<EmbedAssembliesIntoApk>true</EmbedAssembliesIntoApk>`, `<AndroidEnableAssemblyCompression>false</AndroidEnableAssemblyCompression>`, and `.so` uncompressed file extension settings are set if manual ADB/Appium sideloading is used
- [ ] Emulator host networking uses `10.0.2.2` for local backend calls (see `skills/ui-uno-platforms.md` section Emulator Host Networking)
- [ ] MSTest/Appium mobile smoke passes when native Android UI testing is in scope: `powershell -NoProfile -File src/Test/Test.Mobile/run-mobile-tests.ps1`
- [ ] **Final green rule (mobile in scope):** do not declare green until the visible mobile suite passes on its own with mobile enabled (runner sets `{APP}_MOBILE_TESTS_ENABLED=true`), and then the full non-load solution run exits 0 (`dotnet test .\{SolutionName}.slnx --filter "TestCategory!=Load"`). Two separate passing runs, in that order. This is the canonical mobile completion gate; other files point here rather than restating it.

> **Starter-library escape hatch:** If the repo currently contains only a single-TFM starter library or shell-contract scaffold instead of a real Uno multi-target app, Phase 5c for Uno must be recorded as **blocked**. `NETSDK1139` on `<tfm>-browserwasm` is expected in that scenario and is evidence that Uno scaffolding is still missing - not an environment glitch. Do not debug/workaround it; record the status as `blocked - Uno multi-target not yet created` and move on.

If targeting iOS (`<tfm>-ios`):
- [ ] Windows compile gate status recorded
- [ ] Simulator/device UI test gate recorded as `blocked - macOS required` unless a Mac host or macOS CI runner is available

Also verify:
- Gateway/OpenAPI endpoint is reachable for client generation
- Kiota client generation completes (if used)
- the selected Uno target runs successfully

Scheduler:

- [ ] Scheduler connection string configured
- [ ] Scheduler operational tables exist (verify schema ownership - see [troubleshooting.md](troubleshooting.md) section Third-Party Operational Store Schema Triage)

```powershell
dotnet run --project src/Host/{Host}.Scheduler
```

> **AppHost/config dependency:** When the scheduler depends on AppHost-provided resources (e.g., connection strings via service discovery), either run it through AppHost or provide equivalent local connection strings (e.g., `ConnectionStrings:{DatabaseName}`) before using direct `dotnet run`. Record which path was validated in the handoff.

Blazor UI (if `includeBlazorUI: true`):

- [ ] Blazor host project builds (`dotnet build src/UI/{Project}.Blazor`)
- [ ] Gateway/OpenAPI endpoint reachable for Refit client generation
- [ ] **Standalone clean start:** `dotnet run --project src/UI/{Project}.Blazor` reaches `Application started`, `/healthz` returns 200, the root URL renders without exceptions in console logs, and at least one entity list page loads (empty or seeded - both valid)
- [ ] **Aspire-registered clean start (when Blazor is added to AppHost):** the Blazor resource reaches Running, dashboard logs are exception-free, and a Refit call from the Blazor host through the Gateway to the API returns data (or a typed empty state) - not a console exception
- [ ] Auth path matches `AuthMode` (scaffold principal or live provider per Phase 5e)

```powershell
dotnet build src/UI/{Project}.Blazor
dotnet run --project src/UI/{Project}.Blazor
```

React UI (if `includeReactUI: true`):

- [ ] React project builds (`npm run build`) and lints (`npm run lint`) from `src/UI/{Project}.React`
- [ ] Vite proxy or runtime config points UI API calls at the Gateway, not the API host directly when Gateway is enabled
- [ ] **Standalone clean start:** `npm run dev -- --host 127.0.0.1` serves the root URL, layout renders, and one API-backed page loads against the configured Gateway/API base
- [ ] **Aspire-registered clean start:** AppHost includes `Aspire.Hosting.JavaScript`, registers the Vite app, passes `VITE_API_BASE_URL` from the Gateway endpoint (or API endpoint when Gateway is disabled), and the React resource root URL from the Aspire dashboard renders without exception
- [ ] Playwright React project uses an env-driven base URL (for example `{APP}_REACT_BASE_URL`) because Aspire may assign a dynamic Vite port

```powershell
npm ci
npm run lint
npm run build
dotnet build src/Host/Aspire/AppHost
```

Uno UI startup (post-build, in addition to the platform-target checks above):

- [ ] Fast headless UI tests pass when UI model/presentation coverage exists: `dotnet test src/Test/Test.UI/Test.UI.csproj --filter "TestCategory=UI|TestCategory=Presentation"`

- [ ] **Standalone clean start:** the selected Uno target (`<tfm>-browserwasm` / `<tfm>-android` / `<tfm>-ios`) launches or builds to the available local gate and renders the shell with no WASM load errors / no Android startup crashes / no compile failures
- [ ] **Aspire-registered clean start (when an Uno host is added to AppHost):** AppHost registers the ASP.NET Core WASM wrapper host, not the Uno SDK project; the resource reaches Running and serves its entry point without exception
- [ ] At least one entity list page loads against the Gateway/API (empty or seeded data - both valid), proving the Kiota/Refit client resolves the configured backend URL

A scaffold may declare 5c complete with `[Ignore]` UI tests for unresolved external auth/AI deps, but **not** with a UI host that throws on startup. See [../ai/SKILL.md](../ai/SKILL.md) section Scaffold Definition of Done.

Notifications (if `includeNotifications: true`):

- [ ] Notification service interface registered in DI
- [ ] Channel transports declared in `.scaffold/resource-implementation.yaml` have a stub or live implementation per their `externalDependencyMode`
- [ ] Notification triggers (domain events from `notifications:` block) are wired to handlers
- [ ] Notification unit tests pass (`dotnet test --filter "TestCategory=Unit&FullyQualifiedName~Notification"`)

For deployment-only channels (e.g., real Azure Communication Services), record blocker in `HANDOFF.md`; the no-op stub is sufficient for scaffold completion.

## 5d - Quality Gates + Delivery

Unit, service, endpoint, and integration tests already exist from Phases 5a/5b/5c. Phase 5d adds quality gate tests and runs a full regression.

**New tests in this phase:**
- Architecture tests (NetArchTest layering rules)
- Load tests (NBomber, if comprehensive profile)
- Benchmarks (BenchmarkDotNet, if comprehensive profile)
- Mutation tests (Stryker.NET, if comprehensive profile)
- E2E Playwright tests (if comprehensive profile + UI enabled)

**Also in this phase:**
- IaC (Bicep), CI/CD pipeline YAML, Dockerfile, coverage settings

Required profile gate (full regression):
- `minimal`: Unit + Endpoint
- `balanced`: Unit + UI/Presentation (when generated) + Endpoint + Integration + Architecture
- `comprehensive`: Balanced + E2E/Load/Benchmark/Mutation (when enabled)

Commands:

```powershell
dotnet test
```

Run mutation test prerequisites from repo root when the project exists:

```powershell
dotnet tool restore
dotnet test src/Test/Test.Mutation/Test.Mutation.csproj
```

Then run Stryker from `src/Test/Test.Mutation`:

```powershell
dotnet tool run dotnet-stryker
```

IaC (if enabled):

```powershell
az bicep build --file infra/main.bicep
```

Delivery checks:
- [ ] Full test suite passes (regression - not first-time creation for unit/endpoint/integration)
- [ ] Architecture tests enforce layering rules
- [ ] `az bicep build --file infra/main.bicep` succeeds *(if IaC enabled)*
- [ ] Aspire <-> IaC names/connection strings are aligned

## 5e - Integration (Auth + AI)

### Authentication Finalization (within 5e)

**Scaffold mode is the default.** Authentication finalization is complete when the app builds, tests pass, and auth works with the config-driven scaffold principal. Live identity provider setup is supplemental hardening - it does **not** block scaffold completion.

| Mode | Required |
|---|---|
| Scaffold (default) | `AuthMode` toggle present in config (`Scaffold` vs provider name); app boots and all endpoints reachable with scaffold principal; auth stubs/no-op passthrough removed or gated behind `AuthMode`; endpoint tests pass against the scaffold auth path |
| Live provider (only when intentionally provisioned) | Auth provider configured with real tenant values; authenticated endpoint behavior verified against live tokens; scaffold stub gated by config so it does not activate in production |

Commands:

```powershell
dotnet build
dotnet test --filter "TestCategory=Endpoint"
```

If live Entra setup is not yet performed, log it in `HANDOFF.md` as a deployment-only dependency and continue.

### AI Integration (within 5e, when `includeAiServices: true`)

**Scaffold mode is the default.** AI integration is complete when AI-backed interfaces compile, resolve from DI, and tests pass with stubs or no-op implementations. Live Foundry/AI Search endpoints are deployment-only dependencies and do not block scaffold completion.

Provider contract: Azure Foundry when configured, else Foundry Local when available, else no-op. No-op is valid for non-live tests only. `Test.Aspire` sets `AiServices:DisableFoundryLocal=true` and proves Azure live smoke only when configured. `Test.FoundryLocal` sets `AiServices:RequireFoundryLocal=true`, starts the API host directly, checks `/api/v1/ai/status`, and is inconclusive only when Foundry Local runtime is missing/undiscoverable; no-op fallback, timeout, or wrong status is failure.

| Mode | Required |
|---|---|
| Scaffold (default) | AI service interfaces compile and resolve from DI; absent config sections register as no-op stubs (not throws/missing-registration); AI DI/configuration compiles |
| Live endpoints (only when provisioned) | Search service responds; agent endpoint responds; integration tests pass against live resources |

Commands:

```powershell
dotnet build
dotnet test --filter "TestCategory=Unit"
```

If live AI endpoints are not yet provisioned, log them in `HANDOFF.md` as deployment-only dependencies.

---

## Compiler-Warning Policy

`dotnet build` exits 0 is the gate. **Fix warnings at the source - never hide them.** `NoWarn`, `#pragma warning disable`, analyzer severity downgrades, and `WarningLevel` reductions are suppression, not fixes. Suppression is reserved for warnings whose root cause is outside the repo (SDK-generated code, third-party analyzers) and always requires an `.scaffold/INSTRUCTION-GAPS.md` entry with owner and rationale. `TreatWarningsAsErrors` is **off by default**; teams may opt in via `Directory.Build.props` once the codebase is warning-clean.

Restore-time vulnerability warnings (`NU1901`-`NU1904`) are fixed by version movement, never by `NoWarn` - see section Vulnerability Audit for the transitive-pin pattern.

| Blocks the gate | Does not block |
|---|---|
| `dotnet build` returns nonzero exit code | Warnings from third-party packages |
| A warning suppressed without an entry in `.scaffold/INSTRUCTION-GAPS.md` | SDK-generated code warnings (EF migrations, source generators); documented warnings with owner and target resolution date |
| A vulnerability warning silenced with `NoWarn` | A vulnerable transitive lifted by a commented direct pin (see section Vulnerability Audit) |

---

## Analyzer-Cleanliness Gate

`dotnet build` exit 0 does not prove the generated code is analyzer-clean: default-`info` diagnostics (e.g. `MSTEST0049`) never fail the build and surface only when a file is opened in the IDE. Close that loop at generation time - run an analyzer pass at **info** severity with verify-no-changes:

```powershell
dotnet format analyzers --severity info --verify-no-changes
```

Nonzero exit means the generated code is not actually clean; it just has not been opened in the IDE yet. Fix the code at the source (flow the `TestContext` token per [../skills/testing.md](../skills/testing.md) Cancellation-Token discipline; set the deliberate severity per [../skills/solution-structure.md](../skills/solution-structure.md) `.editorconfig`) - do not lower the severity to make the gate pass. Run this as part of the Phase 5d quality regression and any payload change that touches generated test code, so residual info/suggestion-level analyzer debt is a deliberate, verified decision rather than invisible default-info debt.

---

## Vulnerability Audit

Run after `dotnet restore`:

```powershell
dotnet list package --vulnerable --include-transitive
```

| Severity | Policy |
|---|---|
| High | Fix (upgrade the direct dependency, or lift the transitive - pattern below) **or** record in `.scaffold/INSTRUCTION-GAPS.md` as a blocked deployment dependency with owner and target resolution date |
| Moderate | Log in `.scaffold/INSTRUCTION-GAPS.md`; tracked, does not block |
| Low | Team discretion |

The audit is mandatory before pre-merge gate and as part of the Phase 5d quality regression. CI workflows must include the audit step (see [../skills/cicd.md](../skills/cicd.md)).

### Vulnerable Transitive Lift (canonical pattern)

When the vulnerable package is transitive and a fixed version exists, promote it to a direct pinned reference at the fixed version - never `NoWarn` the `NU19xx`. Both edits carry a comment so the pin is self-explaining and removable:

```xml
<!-- Directory.Packages.props -->
<!-- Temporary direct pin: lifts a vulnerable transitive (NU1903) above the version its parent
     package resolves. Remove when the parent ships a fixed dependency and the audit is clean. -->
<PackageVersion Include="{VulnerablePackage}" Version="<latest-stable>" />
```

```xml
<!-- {Project}.csproj - every project that pulls the vulnerable transitive -->
<!-- Temporary direct reference lifting a vulnerable transitive - see Directory.Packages.props. -->
<PackageReference Include="{VulnerablePackage}" />
```

Rules:
- The pin is temporary by definition: on every package-update pass, retry removing it and re-run the audit.
- The direct reference goes only into projects whose dependency graph pulls the vulnerable version (`dotnet list package --vulnerable --include-transitive` names them).
- When no fixed version exists anywhere, this pattern cannot apply - use the severity table above (gap entry with owner and target date).
- TaskFlow proof: `MessagePack` lifted above the version `NBomber` resolves (`src/Directory.Packages.props` + `src/Test/Test.Load/Test.Load.csproj`).

---

## Pre-Merge Gate

Must pass before merge:

```powershell
dotnet restore
dotnet build
dotnet test
```

Plus a manual walk-through of [final-scaffold-checklist.md](final-scaffold-checklist.md) covering: solution structure shape, no-op stub coverage, host startup smoke checks, and HANDOFF.md completeness.

If IaC is part of scope:

```powershell
az bicep build --file infra/main.bicep
```

---

## Failure Handling

- Code-generation failures: one focused AI fix pass, then re-run failing gate.
- Infra/environment failures: log in `HANDOFF.md`, classify blocker, continue non-blocked scope.
- Instruction gaps: in a consumer app, append to `.scaffold/INSTRUCTION-GAPS.md`; in this instruction repository, fold the fix directly into the owning instruction file (maintainer skill `/fold-feedback`).
- If a step fails, log the blocker in `HANDOFF.md` (see [HANDOFF.md template](HANDOFF.md)) and continue with non-blocked work.
- Pattern reference: [../ai/SKILL.md](../ai/SKILL.md) section Non-Negotiables - pattern index for composition wiring.

---

## Mid-Session Rollback Protocol

See [OPERATIONS.md](OPERATIONS.md) section Mid-Session Rollback Protocol.

---

## Post-Scaffold Smoke Test

Run after all Phase 5 sub-phases complete (before the Pre-Merge Gate) to validate the scaffold works end-to-end:

Load [final-scaffold-checklist.md](final-scaffold-checklist.md) for the canonical final acceptance checklist.

### 1. Build & Test
```powershell
dotnet restore
dotnet build
dotnet test
```

### 2. Host Startup
```powershell
# API host (required)
dotnet run --project src/Host/{Host}.Api -- --urls "http://localhost:5100"
# Verify: GET http://localhost:5100/health -> 200 OK (Ctrl+C after)

# Aspire (if enabled)
dotnet run --project src/Host/Aspire/AppHost
# Verify: Aspire dashboard loads, all resources show healthy

# Scheduler (if enabled)
dotnet run --project src/Host/{Host}.Scheduler

# Function App (if enabled)
func host start --port 7100
```

### 3. API Endpoint Smoke
For each scaffolded entity, verify the CRUD cycle per [final-scaffold-checklist.md](final-scaffold-checklist.md) section API Smoke (canonical route list). Use `http` (HTTPie), `curl`, or the Scalar UI at `/scalar/v1`.

### 4. Checklist
- [ ] All hosts start without errors
- [ ] Health endpoint returns 200
- [ ] At least one entity CRUD cycle completes successfully
- [ ] OpenAPI/Scalar UI loads at `/scalar/v1`
- [ ] No unresolved `// TODO: [CONFIGURE]` stubs remain in production paths (stubs in auth/external-API are expected until Phase 5e)
- [ ] Aspire dashboard shows all registered resources (if enabled)
- [ ] Compiler-warning policy applied (see section Compiler-Warning Policy below)
- [ ] Vulnerability audit run (see section Vulnerability Audit below)
