# Execution Gates & Validation

Single source of truth for compile/test/run checkpoints across implementation phases.

Use this file for:
- operator setup and preflight verification,
- phase-by-phase validation commands,
- exit criteria,
- pre-merge quality gates.

If another file disagrees on validation gates or commands, this file wins. Session routing and load rules remain owned by [../START-AI.md](../START-AI.md) and [../ai/SKILL.md](../ai/SKILL.md). The 1-page binding-rule index (`GR-01`...`GR-12`) lives at [../GROUND-RULES.md](../GROUND-RULES.md); gates below cite the `GR-NN` they enforce.

---

## Operator Setup (Pre-Scaffold)

Run once per machine/repo before beginning any scaffolding phase.

### Scope Selection (Pick One)

- [ ] **API-only baseline**: Foundation + App Core + API verification
- [ ] **API + services**: API baseline + Gateway/Aspire/Scheduler as enabled
- [ ] **Full app**: API + services + Function App + Uno/Blazor/React UI + IaC as enabled

### Development Tools

- [ ] Git repo initialized with `.gitignore` for .NET, **patched** for this scaffold's `src/Packages/` source folder and `Test.E2E/` project (see [../skills/solution-structure.md](../skills/solution-structure.md) section Required Root Files (Cross-Platform Hygiene))
- [ ] Current machine- or user-global Python 3 installed for scaffold helper scripts. Verify from a fresh shell per [python-setup.md](python-setup.md); do not rely on a repo `.venv` as the machine launcher.
- [ ] Tracked-source validation runs after `git add .` - see [Tracked-Source Validation](#tracked-source-validation) below.
- [ ] `.NET SDK` installed (`dotnet --version`)
- [ ] Docker running (if Aspire uses SQL/Redis containers)
- [ ] `nuget.config` includes `nuget.org` + all custom/private feeds (see Private Feed Auth below)
- [ ] EF tools available (`dotnet ef --version`; prefer repo-local tool manifest, user-global `dotnet-ef` is acceptable)
- [ ] Functions Core Tools installed (`func --version`) *(if using Functions)*
- [ ] Uno templates installed (`dotnet new install Uno.Templates`) *(if using Uno UI)*
- [ ] Uno.Check installed (`dotnet tool install -g uno.check`) *(if using Uno UI)*
- [ ] Uno browserwasm workload installed (`dotnet workload install wasm-tools`) *(if using Uno browserwasm)*
- [ ] Uno Android workload installed (`dotnet workload install android`) and Android SDK/emulator tools available *(if using Uno Android)*
- [ ] Appium CLI + UiAutomator2 driver installed and `appium driver doctor uiautomator2` passes required checks *(if running Uno Android device/emulator UI tests)*
- [ ] Uno iOS workload installed (`dotnet workload install ios`) and macOS runner/Mac host identified for simulator/device tests *(if using Uno iOS beyond compile planning)*
- [ ] Kiota CLI installed (`dotnet tool install -g Microsoft.OpenApi.Kiota`) *(if using Uno UI)*
- [ ] Node.js LTS/npm available (`node --version`, `npm --version`) *(if using React UI)*

### Tracked-Source Validation

Post-generation check: every `.csproj` under `src/` must be tracked by git. Run after `git add .`:

```powershell
$expected = Get-ChildItem -Recurse -Filter *.csproj src/ | ForEach-Object { (Resolve-Path $_.FullName).Path }
$tracked  = git ls-files 'src/**/*.csproj' | ForEach-Object { (Resolve-Path $_).Path }
$missing  = Compare-Object $expected $tracked -PassThru | Where-Object SideIndicator -eq '<='
if ($missing) { throw ".csproj files excluded by .gitignore: $missing" }
```

Failure means a `.gitignore` rule is silently shadowing a source folder. Fix the `.gitignore` (do **not** force-add the excluded files - the next scaffold folder will hit the same hidden rule). This generalizes: any future folder whose name collides with stock VS ignore patterns surfaces here, not on a CI fresh clone.

### Shared Base-Type Readiness (Phase 3 Pre-Flight)

The required steps depend on `packageStrategy` (set in `.scaffold/resource-implementation.yaml`).

#### When `packageStrategy: feed` or `hybrid`

Feed-supplied layers require package read access before Phase 4 restore/build can pass.

**Step 1:** Ask the user to set or confirm:
- Feed URL (e.g., `https://nuget.pkg.github.com/{owner}/index.json`)
- Auth method: `NUGET_AUTH_TOKEN` environment variable (recommended) or credential provider
- `packagePrefix` matches the feed (e.g., `EF`, `Contoso`)

**Step 2:** Generate `nuget.config`. First probe the user-global config (`%APPDATA%\NuGet\nuget.config` on Windows; `~/.nuget/NuGet/NuGet.Config` on Linux/Mac) for a `<packageSource>` whose `value` is the **same feed URL**, then branch:

| Global config has this feed URL | Action |
|---|---|
| Found | Author a **secret-free** repo `nuget.config`: copy the global source key into `<packageSources>`, add the prefix entry to `<packageSourceMapping>`, emit **no** `<packageSourceCredentials>` block (a repo credential block would shadow working global creds). NuGet resolves the PAT from the global store locally; CI injects `NUGET_AUTH_TOKEN`. Skip Step 3. |
| Not found | Run Step 2b below to write the `%NUGET_AUTH_TOKEN%` credential block. |

**Step 2b - write the credential-bearing config** (only when the probe found no global creds). Use the feed helper:

```powershell
python .instructions/scripts/configure-ef-packages-feed.py --root . --feed-url https://nuget.pkg.github.com/{owner}/index.json --username {username} --prefix {packagePrefix}
```

The helper writes `%NUGET_AUTH_TOKEN%` only; it must never write the PAT value.

Manual equivalent (substitute `{packagePrefix}` for your prefix, e.g., `EF`):

```xml
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" />
    <add key="privatefeed" value="https://nuget.pkg.github.com/{owner}/index.json" />
  </packageSources>

  <packageSourceMapping>
    <packageSource key="nuget.org">
      <package pattern="*" />
    </packageSource>
    <packageSource key="privatefeed">
      <package pattern="{packagePrefix}.*" />
    </packageSource>
  </packageSourceMapping>

  <packageSourceCredentials>
    <privatefeed>
      <add key="Username" value="{username}" />
      <add key="ClearTextPassword" value="%NUGET_AUTH_TOKEN%" />
    </privatefeed>
  </packageSourceCredentials>
</configuration>
```

**Step 3:** Set the auth token via environment variable (Step 2b path only - skip when Step 2a reused working global credentials):

```powershell
# PowerShell - session-scoped (recommended for local dev)
$env:NUGET_AUTH_TOKEN = "<package-read-token>"

# Or persist in user profile (PowerShell $PROFILE)
[Environment]::SetEnvironmentVariable("NUGET_AUTH_TOKEN", "<package-read-token>", "User")
```

> **Security:** Never commit PATs to source control or ask the user to paste one into chat. Use `%VARIABLE%` syntax in `nuget.config` (Windows) or `$VARIABLE` (Linux/Mac) for credential interpolation. Add `.env` and `nuget.config.local` to `.gitignore`.

**Step 4:** Verify:

```powershell
dotnet restore
```

Gate: `dotnet restore` exits 0. All feed-supplied `{packagePrefix}.*` packages resolve, the prefix pattern maps to the private feed, and `dotnet-ef` maps to `nuget.org` when package source mapping is enabled.

#### When `packageStrategy: local`

No private feed is required. `nuget.config` only needs `nuget.org` (auto-default if the file is absent). Confirm:

- `packagePrefix` is set in `.scaffold/resource-implementation.yaml`.
- `localPackageLayers` covers every layer in [`ef-packages-reference.md`](ef-packages-reference.md).
- Phase 4 will generate one packable project per layer under `src/Packages/<packagePrefix>.<Layer>` with `IsPackable=true` and `<PackageId>=<packagePrefix>.<Layer>`.

Gate: `dotnet restore` exits 0 against `nuget.org` only.

#### When `packageStrategy: hybrid`

Both blocks above apply. The feed supplies the layers it covers; layers in `localPackageLayers` are generated locally under the **same** `packagePrefix` so they can be published into the feed later without renaming.

### AI Assistant - MCP Servers

Configure these in your AI client (VS Code `settings.json` or Claude Desktop config) so the AI can look up current docs and interact with tools during scaffolding.

- [ ] MCP servers configured per [../README.md](../README.md) (Essential + phase-relevant)

### Tooling Verification (Phase 3 Gate)

Phase 3 must populate the **Tooling & Environment Readiness** section of `.scaffold/implementation-plan.md`. Before closing Phase 3:

- [ ] Artifact consistency check in `.scaffold/implementation-plan.md` is complete: language, domain spec, resource mapping, decisions, and Phase 4 tasks agree
- [ ] `HANDOFF.md` `enabledFeatures` flags equal the host toggles in `.scaffold/resource-implementation.yaml` (`includeApi`, `includeGateway`, `includeScheduler`, `includeFunctionApp`, `includeUnoUI`, `includeBlazorUI`, `includeReactUI`, `includeNotifications`, `includeIaC`, ...). Any mismatch means a flag flipped without a re-sync - run the Gate-time Amendment Protocol below before proceeding to Phase 4
- [ ] No `[OPEN QUESTION: ...]` marker blocks Phase 4 contract scaffolding (**GR-10**). Run a literal-string scan across `.scaffold/domain-specification.yaml`, `.scaffold/UBIQUITOUS-LANGUAGE.md`, `.scaffold/DESIGN-DECISIONS.md`, and `.scaffold/implementation-plan.md`; classify any remaining marker as **blocking Phase 4** (halt) or **non-blocking deferred** (record in `HANDOFF.md` section Open Questions and proceed).
- [ ] All CLIs required by resource YAML technology choices are identified with install commands
- [ ] MCP server discovery completed (npm search, MCP registry) for project-specific libraries
- [ ] CLI preference applied: CLIs chosen over MCP servers where both exist (lower token cost)
- [ ] Each CLI entry has a verified checkbox or an install command the operator can run before Phase 4
- [ ] `dotnet restore` exits 0 (with `NUGET_AUTH_TOKEN` set when `packageStrategy: feed` or `hybrid`)
- [ ] Developer reviews `.scaffold/UBIQUITOUS-LANGUAGE.md` and `.scaffold/DESIGN-DECISIONS.md` for completeness against `.scaffold/domain-specification.yaml`
- [ ] Developer reviews `.scaffold/implementation-plan.md` against `ai/implementation-plan.md` schema

### Gate-time Amendment Protocol

A host or topology flag can still flip at a pre-code gate after Phase 2 closes (e.g., enabling `includeBlazorUI: true` because the multi-head UI decision surfaced late - see [../ai/shared-understanding-interview.md](../ai/shared-understanding-interview.md) section Multi-Head UI Decision). When any host/topology flag changes at a pre-code gate, **re-sync all four canonical artifacts before continuing** - do not let Phase 4 start until they agree:

- [ ] `.scaffold/resource-implementation.yaml` - the changed feature flag(s) are set (this is the canonical source of truth for hosting topology)
- [ ] `.scaffold/DESIGN-DECISIONS.md` - add a new decision row for the change and update the decision dependency graph / affected-decisions list (see [../templates/design-decisions-template.md](../templates/design-decisions-template.md))
- [ ] `.scaffold/implementation-plan.md` - update the solution layout, Phase 4/5 steps, test plan, tooling readiness, and risks the new host introduces (see [../ai/implementation-plan.md](../ai/implementation-plan.md))
- [ ] `HANDOFF.md` - update `enabledFeatures`, `hostGates`, and `resumeCommand`; these mirror the resource YAML and must match it exactly (HANDOFF already requires `enabledFeatures` to stay in sync - see [HANDOFF.md](HANDOFF.md))

Then re-run the `HANDOFF.md enabledFeatures == resource YAML` consistency check above. A flag that flips without this re-sync is a Phase 4 defect, not a Phase 5 surprise.

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

**TDD note:** For Phase 5a/5b, the TDD protocol expects tests to fail (red) before implementation and pass (green) after. The core loop verifies the green state. See [../ai/tdd-protocol.md](../ai/tdd-protocol.md).

---

## Phase Gates

## 4 - Contract Scaffolding

Exit criteria:
- [ ] Solution structure matches `skills/solution-structure.md`
- [ ] Every entity from `.scaffold/resource-implementation.yaml` has: interface, DTO, entity shell, builders
- [ ] All no-op stubs satisfy their interfaces
- [ ] `RegisterServices.cs` wires all no-op stubs
- [ ] Test.Support contains `UnitTestBase`, `InMemoryDbBuilder`, `DbSupport`, `Utility`, `TestConstants`, `JsonTestOptions`, `LocalSqlSettings`, `WebApplicationFactoryBase`
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
- [ ] Health probes return 200: `/healthz` on every API/host project once that host declares itself ready (Aspire-registered UIs that don't expose health probes count as healthy when their root URL renders without exception)
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
dotnet restore src/UI/{Project}.Uno/{Project}.Uno.csproj -p:BuildAllUnoTargets=true
dotnet build src/UI/{Project}.Uno/{Project}.Uno.csproj -p:TargetFrameworkOverride=$(LatestStableTfm)-browserwasm --no-restore -m:1
dotnet build src/UI/{Project}.Uno/{Project}.Uno.csproj -p:TargetFrameworkOverride=$(LatestStableTfm)-android --no-restore -m:1
dotnet build src/UI/{Project}.Uno/{Project}.Uno.csproj -p:TargetFrameworkOverride=$(LatestStableTfm)-ios --no-restore -m:1
dotnet build src/Host/{Project}.Uno.WasmHost/{Project}.Uno.WasmHost.csproj
```

Run only the targets selected in `.scaffold/resource-implementation.yaml`. Keep platform builds serial (`-m:1`) to avoid shared `obj/` asset races. The `BuildAllUnoTargets=true` restore is required when the project defaults to browserwasm; it prevents mobile builds from packaging a browser-only NuGet asset graph.

If targeting Android (`<tfm>-android`):
- [ ] Android Studio or SDK command-line tools installed with Platform-Tools, Emulator, one recent platform, and one AVD
- [ ] Android SDK path resolved (see `skills/ui-uno-platforms.md` section Android SDK Discovery)
- [ ] Android restore/build uses `dotnet restore ... -p:BuildAllUnoTargets=true` followed by `dotnet build ... -p:TargetFrameworkOverride=$(LatestStableTfm)-android --no-restore`
- [ ] `project.assets.json` contains `Uno.WinUI.Runtime.Skia.Android` for Skia Android targets before runtime debugging starts
- [ ] `<EmbedAssembliesIntoApk>true</EmbedAssembliesIntoApk>`, `<AndroidEnableAssemblyCompression>false</AndroidEnableAssemblyCompression>`, and `.so` uncompressed file extension settings are set if manual ADB/Appium sideloading is used
- [ ] Emulator host networking uses `10.0.2.2` for local backend calls (see `skills/ui-uno-platforms.md` section Emulator Host Networking)
- [ ] MSTest/Appium mobile smoke passes when native Android UI testing is in scope: `dotnet test src/Test/Test.Mobile/Test.Mobile.csproj --filter TestCategory=MobileUI`

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
- `balanced`: Unit + Endpoint + Integration + Architecture
- `comprehensive`: Balanced + E2E/Load/Benchmark/Mutation (when enabled)

Commands:

```powershell
rtk dotnet test
```

Run mutation test prerequisites from repo root when the project exists:

```powershell
rtk dotnet tool restore
rtk dotnet test src/Test/Test.Mutation/Test.Mutation.csproj
```

Then run Stryker from `src/Test/Test.Mutation`:

```powershell
rtk dotnet tool run dotnet-stryker
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

`dotnet build` exits 0 is the gate. New compiler/analyzer warnings introduced by generated code are either resolved or recorded in `.scaffold/INSTRUCTION-GAPS.md` with owner and rationale. `TreatWarningsAsErrors` is **off by default**; teams may opt in via `Directory.Build.props` once the codebase is warning-clean.

| Blocks the gate | Does not block |
|---|---|
| `dotnet build` returns nonzero exit code | Warnings from third-party packages |
| A warning suppressed without an entry in `.scaffold/INSTRUCTION-GAPS.md` | SDK-generated code warnings (EF migrations, source generators); documented warnings with owner and target resolution date |

---

## Vulnerability Audit

Run after `dotnet restore`:

```powershell
dotnet list package --vulnerable --include-transitive
```

| Severity | Policy |
|---|---|
| High | Fix (upgrade direct dependency or pin transitive) **or** record in `.scaffold/INSTRUCTION-GAPS.md` as a blocked deployment dependency with owner and target resolution date |
| Moderate | Log in `.scaffold/INSTRUCTION-GAPS.md`; tracked, does not block |
| Low | Team discretion |

The audit is mandatory before pre-merge gate and as part of the Phase 5d quality regression. CI workflows must include the audit step (see [../skills/cicd.md](../skills/cicd.md)).

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
- Instruction gaps: in a consumer app, append to `.scaffold/INSTRUCTION-GAPS.md`; in this instruction repository, append to `support/UPDATE-INSTRUCTIONS.md`.
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
