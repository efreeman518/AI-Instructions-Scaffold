# Testing

Default test scaffolding skill for Phase 5a, 5b, and integration hosts. For Phase 5d quality gates and Playwright UI, load [testing-quality.md](testing-quality.md) instead.

Reference patterns: [../patterns/expected-output-index.md](../patterns/expected-output-index.md) (Testing).

## Never Silently Pass (applies to every tier)

A test that did not actually exercise its target must **never report green.** `Assert.Inconclusive` is reserved for a named unmet prerequisite, not a product assertion failure. For required Aspire-backed infrastructure, that means only an explicit test-lane opt-out or failed Docker-compatible runtime preflight; once Docker preflight passes, missing tools, create/build/start/readiness/browser failures, and unhealthy/exited resources fail red with diagnostics. Optional live AI providers are the explicit exception owned by [ai-integration.md](ai-integration.md) -> *Optional Live-Provider Classification*: pre-Aspire eligibility, missing runtime, and bounded local-capacity outcomes follow that matrix. Never:

- return early and let the test pass without an assertion,
- `[Ignore]` or no-op it so it counts as passed,
- swallow a startup exception and continue green.

MSTest serializes `Inconclusive` to TRX as `outcome="NotExecuted"`; every such result must name the unmet prerequisite and its unblocking step. A genuine startup, readiness, routing, or assertion failure stays red. Record standing opt-outs in `HANDOFF.md` (section Deferred External Dependencies) so not-executed counts never hide invisible debt.

## TDD Protocol

Phases 5a and 5b use test-first TDD: red -> green -> refactor. See [../ai/tdd-protocol.md](../ai/tdd-protocol.md).
Phase 5c is tests-after for optional hosts. Phase 5d adds quality gate suites, mutation testing, and a full regression - see [testing-quality.md](testing-quality.md).

## BDD Naming Convention

All test methods use Given_When_Then:

```csharp
[TestMethod]
public async Task Given_ValidInput_When_EntityCreated_Then_ReturnsSuccess() { }
```

## Test Class Documentation Convention

Every `[TestClass]` carries a 3-6 line class-level `<summary>` answering:

1. **What is exercised** (one line).
2. **Tooling tier + why this tier** (what a lighter tier would miss).
3. **Non-obvious quirks** (only when applicable - retry loops, warm-up waits, fixture reuse).
4. **Manual run command** (required for infra-dependent tiers - `Aspire`, `WasmUI`, `MobileUI`, `Integration`, `E2E`): the exact `dotnet test ... --filter ...` line for non-mobile tiers, or `tests/Test.Mobile/run-mobile-tests.ps1` for `MobileUI`, plus any opt-out var or prerequisite (start Docker, run `eng/test/start-local-test-stack.ps1`), so a developer reproduces the run without hunting docs.

Method-level docs are **not** the convention - Given/When/Then names encode scenarios. Add per-method comments only for non-obvious quirks.

```csharp
/// <summary>
/// Exercises the {Entity} create->search->update->delete flow over HTTP.
/// Tier: Test.E2E (WAF + Testcontainers SQL) - InMemory provider would miss
/// shadow properties, raw SQL projection, and concurrency token behavior.
/// </summary>
[TestClass]
public class {Entity}WorkflowTests { ... }
```

## Cancellation-Token & TestContext Discipline (MSTEST0049)

MSTest's `MSTEST0049` is on by default at **info** severity - it does not fail the build, so token debt accumulates invisibly and only surfaces when a file is opened in the IDE (clean CLI build, Error List full on open). Generated test code MUST be token-clean at generation time. Rules:

- **Flow the `TestContext` cancellation token into every cancellable async call.** `HttpClient` calls (`PostAsJsonAsync`, `ReadFromJsonAsync`, `GetAsync`, `SendAsync`), service/repository async methods, and EF Core async calls all take `TestContext.CancellationToken` as the trailing/named cancellation-token argument. Do **not** use `CancellationToken.None` as a filler in tests.
- **Private helper methods count too.** A helper inside a test class that makes a cancellable call (e.g. one that creates a parent entity over HTTP) must accept and flow the token - this is the cluster generators and `dotnet format` miss most often.
- **Declare an instance `TestContext` property on any class with async test methods:** `public TestContext TestContext { get; set; } = null!;` (null-forgiving default). This is what the test methods and their helpers read the token from.
- **Static `[ClassInitialize]` hook vs. instance `TestContext` are two separate concerns that coexist.** `[ClassInitialize] static Task ClassInit(TestContext context)` receives its own parameter for class-level setup; the instance property is separate and is what per-test cancellation uses. A class with class-level init *and* async tests needs both - do not discard the `ClassInitialize` parameter (`TestContext _`) and assume the instance property is covered.
- **EF Core `FindAsync` in tests: array-wrap the key + token as the second argument** - `await db.{Entities}.FindAsync([id], TestContext.CancellationToken)`. The named-argument form (`FindAsync(id, cancellationToken: ct)`) binds to the wrong overload and is a **compile break**, not a warning: `FindAsync(object?[]? keyValues, CancellationToken)` needs the key array-wrapped.

```csharp
[TestClass]
public class {Entity}Tests
{
    public TestContext TestContext { get; set; } = null!;              // instance - per-test token

    [ClassInitialize]
    public static async Task ClassInit(TestContext context) { /* class-level setup */ }  // static - separate

    [TestMethod]
    public async Task Given_X_When_Y_Then_Z()
    {
        var ct = TestContext.CancellationToken;
        var resp = await client.PostAsJsonAsync("/api/v1/{entities}", dto, ct);
        var body = await resp.Content.ReadFromJsonAsync<{Entity}Dto>(ct);
        var row  = await db.{Entities}.FindAsync([body!.Id], ct);        // array-wrapped key + token
        var parentId = await CreateParentAsync(ct);                      // helper flows the token too
    }

    private async Task<Guid> CreateParentAsync(CancellationToken ct) { /* ... uses ct ... */ }
}
```

Severity policy for `MSTEST0049` (and the generation-time verify gate that enforces it) is owned by [solution-structure.md](solution-structure.md) section `.editorconfig` and [../support/execution-gates.md](../support/execution-gates.md) section Analyzer-Cleanliness Gate.

## Profiles

| Profile | Include by default |
|---|---|
| `minimal` | Unit + Endpoint |
| `balanced` | Minimal + Integration (component) + Architecture + Test.Support + `Test.UI` when UI model/presentation coverage exists |
| `comprehensive` | Balanced + Aspire mesh + PlaywrightUI + Load + Benchmarks + Mutation |

Rule: start balanced, then add hosted UI and performance suites when slices stabilize. Separate two switches that are easy to conflate (see [Capability-Gated Test Tiers](#capability-gated-test-tiers-the-early-decision-drives-the-rest)): **generation** (does the test project exist?) is driven by the early Phase 2 capability pick + `testingProfile`; **runtime gating** (does a generated tier run, or self-skip?) is default-on for a selected tier with a local false-only opt-out - except `Test.Mobile`, which is opt-IN (default off) because its emulator/Appium/APK preconditions are too heavy for the canonical lane.

The `resource-implementation.yaml` test booleans drive **generation**: `comprehensive` implies `includeAspireTests` + `includePlaywrightUITests` (plus Load/Benchmarks/Mutation) when those flags are omitted. Setting a flag explicitly overrides the profile default. `includeMobileTests` (`Test.Mobile`, Uno native Appium) and the Skia-canvas `WasmUI` bridge tier require `includeUnoUI`; generate them in balanced+ when Uno is in scope. Generate `Test.UI` when UI model/presentation coverage exists; it is the fast headless UI lane for UI services, theme/catalog logic, presentation models, and MVUX state/feed tests. Do not confuse `includeE2ETests` (`Test.E2E`, WebApplicationFactory + Testcontainers SQL) with `includePlaywrightUITests` (`Test.PlaywrightUI`, browser-driven) - they are distinct tiers.

EF query-translation correctness requires a real relational provider. `minimal` (Unit + Endpoint) does not cover translated predicates, projections, owned-type filters, or value-converted columns because endpoint tests use the in-memory WAF path. In `balanced` and higher, add at least one real-SQL search/list path per searchable aggregate: `Test.E2E` for HTTP workflow coverage or `Test.Integration` for repository/component coverage.

The real provider must be the **deployed** provider. When configured `databaseProviders` differ between the test default and the deployment target (e.g. tests default to SQL Server, production runs PostgreSQL), a green run proves nothing about deployed-provider query translation - shaper and translation failures are provider-specific. Run the relational integration suite against the deployed provider at least once per release, and on every change to query projections.

## Capability-Gated Test Tiers (the early decision drives the rest)

The early Phase 2 capability pick - `scaffoldMode` plus the `include*UI` / `useAspire` host flags ([resource-implementation-schema.md](../ai/resource-implementation-schema.md) Question 2) - determines which tiers exist **at all**. An `api-only` / no-UI scaffold has none of the rows below: no project, no category, no env var, no setup-script branch, no VS Code task. Do not default these on; a tier appears only because a capability was selected early.

| Early Phase 2 pick | Tier (project / category) | Local gating var | Stack-script branch + VS Code tasks |
|---|---|---|---|
| `api-only` / no UI | none of Test.UI / PlaywrightUI / WasmUI / Mobile | - | - |
| UI model/presentation coverage exists | `Test.UI` / `UI` or `Presentation` (headless) | none | none |
| `includeBlazorUI` / `includeReactUI` (+ comprehensive or `includePlaywrightUITests`) | `Test.PlaywrightUI` / `PlaywrightUI` (DOM) | none (generation-gated) | Playwright install |
| `includeUnoUI`, Skia renderer (+ comprehensive or `includePlaywrightUITests`) | `Test.PlaywrightUI` / `WasmUI` (canvas bridge) | `{APP}_WASM_TESTS_ENABLED` (opt-out; default on) | Build WASM, Playwright install; tasks: Build WASM, Test: WASM |
| `includeUnoUI` (+ balanced or `includeMobileTests`) | `Test.Mobile` / `MobileUI` (Appium) | `{APP}_MOBILE_TESTS_ENABLED` (opt-IN; default off) | `tests/Test.Mobile/run-mobile-tests.ps1`; tasks: Test: Mobile |
| `useAspire: true` (+ comprehensive or `includeAspireTests`) | `Test.Aspire` / `Aspire` (mesh) | `{APP}_RUN_ASPIRE_TESTS` (opt-out; default on) | AppHost start; task: Test: Aspire |

This table is the single source of truth. Phase 2 records the selected tiers (Question 9), [../ai/contract-scaffolding.md](../ai/contract-scaffolding.md) generates exactly those projects, and the [local test stack](../templates/local-test-stack-template.md) script / VS Code tasks expose only their branches.

**For a tier the early decision generated:**

- **Runs by default (Aspire + WasmUI).** Each is discoverable in Test Explorer and runs under `--filter "TestCategory!=Load"`. Its `{APP}_*_TESTS` var is a **local convenience** to silence it (treat any value other than a case-insensitive `false` as "run") - not an enable flag the developer must know to turn the tier on.
- **Exception - `Test.Mobile` is opt-IN, default off.** Mobile needs an emulator/device, Appium + UiAutomator2, and a built platform APK - too heavy for the canonical lane. Treat `{APP}_MOBILE_TESTS_ENABLED` as an **enable** flag: only a case-insensitive `true` (or `1`/`yes`) activates the tier; unset/false makes each test self-mark `Assert.Inconclusive` with a message saying the tier is opt-in and how to enable it - **never a silent pass.** A skipped-as-passed mobile test reads as green coverage that never ran. MSTest serializes `Inconclusive` to TRX as `outcome="NotExecuted"`, so the expected healthy default-off result is **0 passed / N not-executed, each carrying an Inconclusive message** - success, not failure. Keep `[TestCategory("MobileUI")]` on every test so a lane can also exclude it by filter. This is the one tier that defaults off; Aspire and WasmUI stay default-on per the bullet above.
- **Explicit mobile lane fails fast.** `tests/Test.Mobile/run-mobile-tests.ps1` owns Android restore/build, emulator readiness, Appium readiness, `{APP}_MOBILE_TESTS_ENABLED=true`, and TRX output. Once that runner activates the tier, missing/broken APK, emulator/device, Appium, or UiAutomator2 is red, not `Assert.Inconclusive`. Default `dotnet test` without the enable flag remains dependency-free inconclusive.
- **Narrow inconclusive boundary** (see [Never Silently Pass](#never-silently-pass-applies-to-every-tier)). Required Aspire/Playwright/WasmUI infrastructure marks inconclusive only for an explicit false opt-out or a failed Docker preflight. If the lane is selected and Docker works, missing Node/browser/workload, unresolved named endpoint, AppHost/container failure, or unhealthy resource is red with diagnostics. Mobile keeps its separately documented default-off rule; optional live AI uses the canonical classification in [ai-integration.md](ai-integration.md).
- **CI lanes may set explicit opt-outs.** Fast lanes that must not pay Docker/emulator/model cost set the generated false-only variables. Those flags are shortcuts, not mandatory configuration for absent optional AI providers. Docker-unavailable preflight may self-skip container tiers; required selected lanes do not self-skip missing tools. Explicit mobile workflow_dispatch uses the runner and fails fast.
- The mesh preflight helper shape is in [../templates/test-templates-aspire.md](../templates/test-templates-aspire.md) (Opt-out + preflight). Mirror it for `WasmUI`; mobile uses generated runner plus method-level default-off preflight.
- **AppHost-backed WasmUI is real mesh UI.** If the Uno WASM app depends on API, Gateway, SQL, Redis, storage, or auth, the `WasmUI` fixture starts the Aspire AppHost in testing mode, keeps required resources live, disables only optional hosts, and resolves Gateway/UI URLs from named endpoints. Do not generate standalone browser tests against guessed local ports for that case.
- **One startup budget, then subordinate step caps.** Start one monotonic deadline before Docker preflight or test-owned restore. Every create/build/start, named-resource wait, endpoint resolution, Gateway warm-up, and browser launch consumes the same remaining budget. A per-operation timeout may be shorter, but never resets or extends the global deadline. On failure, dump resource name/state/health/exit code/start/stop timestamps by default; include resource logs only when the diagnostic logging switch is enabled.
- **Serialize full-stack projects.** `Test.Aspire` and `Test.PlaywrightUI`/`WasmUI` are resource-heavy and may build or boot overlapping AppHost/container/UI graphs. Full-solution acceptance uses unfiltered `dotnet test <solution>.slnx --no-build -m:1`; CI keeps their steps/jobs non-overlapping and adds `-m:1` to any solution-wide test command. `[DoNotParallelize]` still protects classes inside each assembly.

### Container Runtime (Docker) for Mesh / Component Tiers

The container-backed tiers - `Test.Aspire` (mesh) and `Test.Integration` / `Test.E2E` (Testcontainers) - require a working container runtime; the fast tiers do not.

- **Gate on a generic container-capability check, not a Docker-Desktop probe.** Treat the runtime as available when the Testcontainers/Docker client can connect (or `docker info` succeeds). Docker Desktop, WSL Docker Engine, Rancher Desktop, and a Podman-compatible Docker socket are all valid - never special-case a product or probe for Docker Desktop specifically in test code.
- **No runtime -> `Assert.Inconclusive`** with a message naming the missing container runtime and the fix (see [Never Silently Pass](#never-silently-pass-applies-to-every-tier)). Run `docker info` with a short timeout and begin asynchronous drains of both stdout and stderr before waiting for exit; redirected pipes can otherwise fill and deadlock the preflight. Docker available transfers control to the real host, where later startup/readiness failures are red.
- **Never silently downgrade a mesh or component test to an in-memory provider.** Swapping a Testcontainers SQL / Aspire mesh test to EF InMemory when Docker is absent makes it pass while exercising none of the real-infra failure modes it exists to catch - that hides infra failures behind green. Self-skip (`Inconclusive`); do not rewrite it to a lighter store.
- **Unit, endpoint, and fake-`IChatClient` AI tests run with no Docker at all** - they must never take a container dependency.

Suspect container resource pressure before editing test logic when health checks flap; the resource floor, WSL `.wslconfig`, and runtime-restart guidance live in [../support/troubleshooting.md](../support/troubleshooting.md) -> Docker / Container Runtime.

## Project Layout

```text
tests/
  Test.Support/
  Test.Unit/
  Test.UI/
  Test.Integration/      # component: one class vs one real store (standalone Testcontainers)
  Test.Integration.{Project}.FlowEngine/ # optional workflow-definition validation
  Test.Aspire/           # mesh: full AppHost graph over HTTP (lazy-started)
  Test.FoundryLocal/     # optional RID-bound local AI lane
  Test.Endpoints/
  Test.E2E/
  Test.Architecture/
  Test.PlaywrightUI/
  Test.Mobile/           # optional Appium native lane
  Test.Load/
  Test.Benchmarks/
  Test.Mutation/
```

When any of `Test.Aspire`, the `WasmUI` bridge tier, or `Test.Mobile` is in scope, generate re-runnable operator tooling: `eng/test/start-local-test-stack.ps1` (process-env only - no permanent PATH edits), `.vscode/tasks.json`, and `tests/Test.Mobile/run-mobile-tests.ps1` when mobile exists. The stack script builds WASM, installs Playwright browsers, starts Aspire AppHost, waits endpoints, and prints rerun commands. The mobile runner owns Android build, emulator/Appium readiness, enable flag, `dotnet test`, and TRX output. Full shape: [../templates/local-test-stack-template.md](../templates/local-test-stack-template.md). Aspire-backed tiers use the shared host pattern in [../templates/test-templates-aspire.md](../templates/test-templates-aspire.md); missing selected-lane tooling and host failures are red after Docker succeeds.

> A nested `Test.Integration.{Project}.FlowEngine` project also exists when `includeFlowEngine: true` - a deliberate exception to the flat `Test.<X>` peer naming, because it is a distinct workflow-definition guard suite with its own template ([flowengine-test-template.md](../templates/flowengine-test-template.md)) and no shared fixtures.

## Harness Tiers (Critical)

| Project | Harness | Test scope | Template |
|---|---|---|---|
| `Test.Unit` | Pure CLR + Moq | Domain rules, mappers, application services with mocks | [test-templates-domain.md](../templates/test-templates-domain.md), [test-templates-repository.md](../templates/test-templates-repository.md), [test-templates-service.md](../templates/test-templates-service.md) |
| `Test.UI` | Pure CLR + Moq, no app head | Headless UI services, theme/catalog logic, presentation models, MVUX state/feed tests. References `{Project}.Uno.Core` and `{Project}.Uno.Presentation`, never `{Project}.Uno`. | [test-templates-presentation.md](../templates/test-templates-presentation.md) |
| `Test.Endpoints` | `WebApplicationFactory<TProgram>` + EF InMemory | Single endpoint contract: status code, response shape, validation, auth | [test-templates-endpoint.md](../templates/test-templates-endpoint.md) |
| `Test.E2E` | `WebApplicationFactory<TProgram>` + Testcontainers SQL | Multi-endpoint workflows against real SQL: paged search distinct-page, projection round-trip, FK constraints, child aggregate lifecycle | [test-templates-e2e.md](../templates/test-templates-e2e.md) |
| `Test.Integration` | Standalone Testcontainers (SQL / Azurite / Redis) | Component: one class vs one real store - repo CRUD/migrations, tenant filter, M:N, audit-repo round-trip, projection pipeline | [test-templates-integration.md](../templates/test-templates-integration.md) |
| `Test.Aspire` | Aspire `DistributedApplicationTestingBuilder` | Mesh: full AppHost graph over HTTP - API/Function audit pipelines, Service Bus -> Function -> projection, Blazor-mesh smoke | [test-templates-aspire.md](../templates/test-templates-aspire.md) |
| `Test.PlaywrightUI` | Real hosted stack (Aspire / docker-compose / preview) | Browser-driven UI - hosts both the `PlaywrightUI` DOM lane and the `WasmUI` canvas-bridge lane (`WasmUI` is a category here, not a separate project) | [testing-quality.md](testing-quality.md) section Hosted Browser UI |
| `Test.Architecture` | `NetArchTest.Rules` | Layer dependency rules | [test-templates-quality.md](../templates/test-templates-quality.md) |
| `Test.Load` | NBomber | Throughput / latency baselines | [test-templates-quality.md](../templates/test-templates-quality.md) |
| `Test.Benchmarks` | BenchmarkDotNet | Per-operation micro-benchmarks | [test-templates-quality.md](../templates/test-templates-quality.md) |
| `Test.Mutation` | Stryker.NET + MSTest | Focused mutation testing for high-value domain/service paths | [test-templates-quality.md](../templates/test-templates-quality.md) |

Rule: PlaywrightUI is a different harness. Never merge it with WAF tests.

Real-SQL tiers are the only tiers that prove EF translation. Use them for predicates over value-converted properties (`TenantId`, nullable typed FKs, `Email`, `Locale`), projections, `Contains` / `LIKE`, and owned-type filters. Unit, endpoint, and model-validation tests can all stay green while SQL translation would throw at runtime.

**AI live-local smoke is a separate RID-bound tier.** When `includeAiServices: true` and the Foundry Local provider is in scope, its live smoke runs in a dedicated RID-bound `Test.FoundryLocal` project - the RID-free mesh (`Test.Aspire`) and in-memory WAF base physically cannot load the native `Microsoft.AI.Foundry.Local` SDK. Every other API-booting tier forces no-op via `AiServices:DisableFoundryLocal` (set on both the WAF base and the AppHost testing branch). Owner: [ai-integration.md](ai-integration.md) section Deciding the Live Lane Without Probing the CLI.

`Test.Aspire` AI smoke is Azure Foundry only; it sets `AiServices:DisableFoundryLocal=true`, checks Azure eligibility before AppHost creation, and never attempts Foundry Local. `Test.FoundryLocal` starts the API host directly after its runtime preflight, sets `AiServices:RequireFoundryLocal=true`, and checks `/api/v1/ai/status`. Exact inconclusive-versus-red outcomes belong only to [ai-integration.md](ai-integration.md) section Optional Live-Provider Classification.

**Tier ladder - pick the cheapest tier that catches the failure mode you're testing.**

```
Pure unit (Test.Unit)
 -> Headless UI (Test.UI)
 -> CustomApiFactory (Test.Endpoints, WAF + InMemory)
    -> SqlApiFactory (Test.E2E, WAF + Testcontainers SQL)
      -> Standalone store fixtures (Test.Integration, component - one class vs one Testcontainer)
        -> AspireTestHost (Test.Aspire, mesh - full distributed app over HTTP)
          -> Hosted Playwright (Test.PlaywrightUI)
Mutation overlay (Test.Mutation, Stryker over focused MSTest suite)
```

Phase 4 generates the WAF base in `Test.Support`, the `CustomApiFactory` / `SqlApiFactory` shells, the `Test.Integration` store fixtures (`SqlContainerFixture` / `AzuriteContainerFixture` + `IntegrationTestSetup`), and the `Test.Aspire` mesh shells (`AspireTestHost` + `AspireMeshLifecycle`) so the ladder is wired before any Phase 5 tests are written - profile-gated tiers (`Test.E2E`, `Test.Aspire`) get shells only when the Capability-Gated table above generates them. See [../ai/contract-scaffolding.md](../ai/contract-scaffolding.md) (`### 4. Test Infrastructure`).

### Heavy Aspire Mesh Graph Rule

`Test.Aspire` owns one assembly-scoped `DistributedApplicationTestingBuilder`/AppHost graph per mesh run - the lazy `AspireTestHost` graph (see [../templates/test-templates-aspire.md](../templates/test-templates-aspire.md)). Do not stand up a second AppHost graph, in a separate class or fixture, to prove optional provider wiring, UI smokes, or feature-specific branches. Prove AppHost opt-in branches with a cheap topology guard instead: set the opt-in env/config flag before builder creation, inspect the resulting resource/provider shape or status setting, then stop. Put live-provider behavior in dedicated lighter lanes such as `Test.FoundryLocal`, a direct API-host smoke, or externally hosted Playwright, so mesh coverage never duplicates infrastructure graphs.

This is the canonical statement of the rule; the Aspire template and the testing-quality checklist point here rather than restating it.

### Component vs Mesh split

The integration surface is two separate projects, never one mixed assembly:

- **`Test.Integration` (component)** - one class vs one real store, instantiated directly against a standalone Testcontainer (`SqlContainerFixture` / `AzuriteContainerFixture` / `RedisContainerFixture`, started in parallel by `IntegrationTestSetup`). No HTTP, no `AppHost`/`Aspire.Hosting.Testing` reference. See [../templates/test-templates-integration.md](../templates/test-templates-integration.md).
- **`Test.Aspire` (mesh)** - the full production AppHost graph over HTTP, started lazily by `AspireTestHost.EnsureStartedAsync` and torn down by `AspireMeshLifecycle`. See [../templates/test-templates-aspire.md](../templates/test-templates-aspire.md).

Keeping them in separate assemblies means the fast component tier never pays the ~60-90 s graph boot; the mesh boots once per run, only when a mesh test executes. Do **not** reintroduce a single `Test.Integration` that piggybacks component tests on a shared `AspireTestHost`.

## Dependencies

- MSTest: `MSTest.TestFramework`, `MSTest.TestAdapter`
- Mocks: `Moq`
- Endpoint/E2E harness: `Microsoft.AspNetCore.Mvc.Testing`
- Architecture: `NetArchTest.Rules`
- Hosted UI: `Microsoft.Playwright.MSTest`
- Load: `NBomber`
- Benchmarks: `BenchmarkDotNet`
- Mutation: `dotnet-stryker` local tool

Keep versions centralized in `Directory.Packages.props`.

## Assertion Policy

**Do not use FluentAssertions.** Version 8+ requires a commercial license. Do not add it as a NuGet reference under any circumstance. If `nuget.config` contains a `<package pattern="FluentAssertions" />` allowlist entry, remove it - its presence is a license-policy violation waiting to happen.

Allowed options:

| Option | Package | License |
|---|---|---|
| MSTest built-ins (default) | none | MIT |
| Shouldly | `Shouldly` | MIT |
| `AssertionExtensions` in Test.Support | none | n/a |

The project-local `AssertionExtensions` class (in `tests/Test.Support/AssertionExtensions.cs`) provides `.Should()` syntax via `global using` in `tests/Test.Unit/GlobalUsings.cs`. Use it; do not import FluentAssertions to get the same syntax.

Prefer specific MSTest asserts over generic `Assert.IsTrue`.

## Categories and Command Split

Use these categories: `Unit`, `UI`, `Presentation`, `Endpoint`, `Integration`, `Aspire`, `E2E`, `PlaywrightUI`, `WasmUI`, `MobileUI`, `Architecture`, `Load`, `Benchmark`, `Mutation`. When AI is scaffolded, the live model smoke lane adds `LiveAI` (plus `FoundryLocal` / `AzureFoundry` to scope a smoke to a single provider).

Category boundaries that matter:

- **`UI` / `Presentation`** fast headless UI tier (`Test.UI`) for UI services, theme/catalog logic, presentation models, MVUX state/feed tests. Never tag these `Unit`, and never reference a Uno.Sdk app head.
- **`Aspire`** is the mesh tier (`Test.Aspire`), distinct from **`Integration`** (component, `Test.Integration`). Never tag mesh tests `Integration` - that would boot the full graph on a `--filter TestCategory=Integration` run.
- **`PlaywrightUI`** is DOM-based browser UI (MudBlazor/React/managed-DOM Uno). **`WasmUI`** is the Skia-canvas Uno bridge tier. **`MobileUI`** is Appium. None of these is `E2E` (`E2E` is WAF + Testcontainers SQL).
- **`LiveAI`** marks model-backed smoke tests. RID-free `Test.Aspire` owns Azure Foundry; RID-bound `Test.FoundryLocal` owns the local provider. Fast AI coverage (provider selection, contract, parse guard, no-write, write, no-op fallback) uses a fake `IChatClient` in `Test.Unit` / `Test.Endpoints` and carries no AI category. `AzureFoundry` is for Azure-specific selection/provisioning only, not a second copy of a provider-neutral contract. Classification and doctrine: [ai-integration.md](ai-integration.md) -> Provider Test Tiers.

```powershell
# Canonical "all normal tests" - excludes Load (NBomber). Use explicit false opt-outs for heavy
# lanes not provisioned on this machine. Optional LiveAI also performs its canonical provider preflight.
dotnet test .\{SolutionName}.slnx --filter "TestCategory!=Load" -m:1

# Scoped runs
dotnet test --filter "TestCategory=Unit"
dotnet test --filter "TestCategory=UI"
dotnet test --filter "TestCategory=Presentation"
dotnet test --filter "TestCategory=Endpoint"
dotnet test --filter "TestCategory=Integration"
dotnet test tests/Test.Aspire/Test.Aspire.csproj --filter "TestCategory=Aspire" -m:1
dotnet test --filter "TestCategory=E2E"
dotnet test tests/Test.PlaywrightUI/Test.PlaywrightUI.csproj --filter "TestCategory=PlaywrightUI" -m:1
dotnet test tests/Test.PlaywrightUI/Test.PlaywrightUI.csproj --filter "TestCategory=WasmUI" -m:1
dotnet test --filter "TestCategory=MobileUI"
dotnet test --filter "TestCategory=LiveAI"        # optional-provider smoke; absent provider may be inconclusive per ai-integration.md
dotnet test tests/Test.Mutation/Test.Mutation.csproj --filter "TestCategory=Mutation"
```

> `Test.Benchmarks` uses BenchmarkDotNet `[Benchmark]`, not `[TestMethod]`, so `dotnet test` discovers nothing there - it never pollutes the `TestCategory!=Load` run. `Test.Mutation` samples are ordinary fast MSTest and may run under the canonical filter; Stryker itself is the separate runner.

## Test Class Field Declarations

Fields assigned inside `[TestInitialize]` (not the constructor) must be declared with `= null!` to suppress CS8618. The nullable analyzer does not recognise `[TestInitialize]` as a guaranteed initializer.

```csharp
private Mock<IMyDependency> _mockDep = null!;
private MyService _service = null!;

[TestInitialize]
public void Setup()
{
    _mockDep = new Mock<IMyDependency>();
    _service = new MyService(_mockDep.Object);
}
```

Apply `= null!` to every non-nullable field in every generated test class.

## Assembly Initializer Safety

`[AssemblyInitialize]` methods must **never throw**. A throwing `AssemblyInitialize` causes MSTest to abort the entire assembly - including tests that have no dependency on the failed setup. Preserve the failure, but classify only Docker-unavailable as inconclusive.

For test assemblies that start external infrastructure (e.g., Testcontainers), apply this pattern:

```csharp
[AssemblyInitialize]
public static async Task AssemblyInit(TestContext context)
{
    _dockerUnavailableReason = await DockerRuntimePreflight.GetUnavailableReasonAsync(
        TimeSpan.FromSeconds(10),
        context.CancellationToken);
    if (_dockerUnavailableReason is not null)
        return;

    try
    {
        await _fixture.InitializeAsync();
    }
    catch (Exception ex)
    {
        _startupFailure = ex;
        // Do not rethrow - dependent tests fail with the original startup diagnostics.
    }
}
```

In each test that depends on the infrastructure, check readiness at the start:

```csharp
[TestInitialize]
public void TestSetup()
{
    if (_dockerUnavailableReason is not null)
        Assert.Inconclusive(_dockerUnavailableReason);

    if (_startupFailure is not null)
        Assert.Fail($"Infrastructure startup failed after Docker preflight: {_startupFailure}");
}
```

Apply the readiness check only to infrastructure-dependent tests so unrelated tests remain runnable. Do not downgrade Testcontainers image parsing, pull, create, or container startup failures after a successful preflight.

## Core Patterns

### Test.Support

- `WebApplicationFactoryBase` - thin adapter over the package base (host-replacement swap lives in EF.IntegrationTesting)
- `JsonTestOptions` - shared test-side JSON options (see skills/api.md JSON Contract)
- `InMemoryDbBuilder` for in-memory/sqlite with seed hooks
- `TestConstants` + `Builders/{Entity}Builder` for config and data generation
- Unit tests are flat classes: per-class `Mock<T>` fields + a `CreateService` helper, no shared unit-test base

### Unit (Test.Unit)

Cover domain invariants, rules/specifications, service success/failure/not-found paths, mapper consistency.

**Mapper Projection <-> ToDto agreement.** Every mapper with both an EF-translatable `Projection` expression and a `ToDto` method needs a pin test that asserts both produce equivalent DTOs for the same entity. This catches the silent divergence where `Projection` (used by `Search`/`Get` query paths) omits a field or flattens a value object differently than `ToDto` (used by `Create`/`Update` response paths). Watch especially for owned types (`DateRange`, `Money`) - the projection's flat property access often disagrees with `ToDto`'s nested record construction.

```csharp
[TestMethod]
public void Projection_And_ToDto_Agree()
{
    var entity = new {Entity}Builder().Build();
    var projected = new[] { entity }.AsQueryable().Select({Entity}Mapper.Projection).Single();
    var mapped    = {Entity}Mapper.ToDto(entity);
    Assert.AreEqual(JsonSerializer.Serialize(mapped), JsonSerializer.Serialize(projected));
}
```

**Tenant-admin bypass.** When `enableMultiTenant: true`, pin both paths: `X-{App}-Admin: true` flips `DbContext.BypassTenantFilter` end-to-end (admin sees cross-tenant rows); non-admin cross-tenant access returns 404. The negative path must be a separate test so a regression in either direction surfaces independently.

### Uno MVUX Presentation UI Tests

When `includeUnoUI: true`, test MVUX presentation records from `src/UI/{Project}.Uno.Presentation/Presentation` in `tests/Test.UI/Presentation`. The test project references `{Project}.Uno.Core` and `{Project}.Uno.Presentation` only, never the `{Project}.Uno` `Uno.Sdk` app head. Use [../templates/test-templates-presentation.md](../templates/test-templates-presentation.md) for the `SourceContext` harness, stub `HttpMessageHandler`, and local nullable-warning suppressions. Tag classes `UI`; tag presentation-specific methods `Presentation`.

### Endpoint (Test.Endpoints)

Use `WebApplicationFactory` and validate status code, response shape, validation, and auth contract for one endpoint at a time.

### Workflow E2E (Test.E2E)

Use WAF + real SQL (often Testcontainers) for create->search->update->delete business flows through HTTP.

### Blazor - Three-Layer Coverage

When `includeBlazorUI: true`, scaffold three tiers so failures localize:

1. **In-isolation host smoke** (`tests/Test.Endpoints/BlazorHostSmokeTests`) - `WebApplicationFactory<{Project}.Blazor.Program>` builds the host with no Refit backend. Catches DI / Refit registration / MudBlazor service-provider failures at startup. Fast (no Aspire, no SQL).
2. **Aspire-mesh smoke** (`tests/Test.Aspire/BlazorMeshSmokeTests`) - Blazor opt-in via `{APP}_INCLUDE_BLAZOR=true`; verifies the full graph (Gateway routing + Refit + tenant header) by hitting one page that round-trips through the API. Calls `AspireTestHost.EnsureStartedAsync` from `[ClassInitialize]`.
3. **Hosted Playwright** (`tests/Test.PlaywrightUI/BlazorSmokeTests`) - real browser against a hosted stack; comprehensive profile only.

Each tier owns a different failure mode. Without tier 1, MudBlazor DI breakage is invisible until tier 2 / tier 3 fails with a misleading "page didn't load" symptom.

## Test Data Builders

Place fluent builders in `tests/Test.Support/Builders/`.

- One builder per entity and per DTO.
- Defaults must be valid by domain rules.
- Tests override only scenario-relevant properties.

---

## Service-Level Integration vs Endpoint Tests

`Test.Integration` is **not** for endpoint contract tests.

- Integration (`Test.Integration`, component): one class vs one real store (SQL/Redis/Azurite). Cross-process broker/Function flows belong to the mesh tier in `Test.Aspire`.
- Endpoint: HTTP contract tests via `WebApplicationFactory` in `Test.Endpoints`.

If the test posts JSON to an API and asserts HTTP response shape, it belongs in `Test.Endpoints`.

## Aspire Test Host (recipe)

The Aspire mesh host lives in `Test.Aspire` - see [../templates/test-templates-aspire.md](../templates/test-templates-aspire.md) for the full file shapes. Name the fixture for what it wraps: if it owns the full `DistributedApplication` (DB + Functions + Storage + lifecycle), call it `AspireTestHost` - not `DatabaseFixture`. The component tier's per-store context helpers live on the standalone fixtures in `Test.Integration` (e.g. `SqlContainerFixture.CreateTrxnContext()`), not on the mesh host.

### Shared environment rules

1. **One shared app per assembly.** Start lazily through a guarded fixture and reuse. Never build one graph per test class.
2. **Set scoped flags (e.g., `TASKFLOW_ASPIRE_TESTING`, `TASKFLOW_INCLUDE_FUNCTIONS`) before `CreateAsync`** - only for things AppHost reads via `Environment.GetEnvironmentVariable`. **Save and restore originals** in cleanup for hermeticity.
3. **Pass parameters via `configureBuilder`, not env-var mutation.** AppHost binds `Parameters:*` through `IConfiguration` - write them into `hostSettings.Configuration` so test isolation stays clean.
4. **Conditional Functions inclusion.** Detect `func.exe` once before startup and set the include flag there. If a selected Functions test lacks the tool, fail with its install step; only an explicit `{APP}_RUN_FUNCTIONS_TESTS=false` opt-out is inconclusive.
5. **One startup budget mandatory.** `[Timeout]` remains a coarse test-host ceiling. `AspireTestHostContext` reads `{APP}_ASPIRE_STARTUP_TIMEOUT_SECONDS` once (default 900 s) and spends it across Docker preflight, create/build/start, named health waits, endpoint/connection resolution, and browser launch.
6. **`local.settings.json` override trap.** Hardcoded DB connection strings in Functions `local.settings.json` beat Aspire injection. Remove them (keep safe Azurite-style values only).
7. **Keep `using Aspire.Hosting.Testing;`** in every file calling `CreateHttpClient()` or `GetConnectionStringAsync()` (they are extension methods).

### Assertion Surface - Prefer Downstream Effects

When the Aspire mesh test needs to verify that a message flowed (an event was published, a webhook was processed), **assert against a persistent downstream effect** - a row in SQL, a document in Cosmos, an entry in Table Storage - rather than against the message bus itself.

```csharp
// PREFER - poll the audit row that the message handler writes
await Wait.Until(
    () => tableClient.QueryAsync<AuditRow>(r => r.PartitionKey == correlationId).AnyAsync(),
    timeout: TimeSpan.FromSeconds(30));

// AVOID - poll the topic/queue directly
await Wait.Until(
    async () => await receiver.ReceiveMessageAsync(TimeSpan.FromSeconds(2)) is not null,
    timeout: TimeSpan.FromSeconds(180));
```

**Why.** Aspire's Service Bus emulator under `DistributedApplicationTestingBuilder` does not always propagate topic->subscription routing within bounded test windows; queue trigger plumbing on Functions is similarly best-effort under emulator-mode. Verifying via the downstream artifact is robust against this class of tooling gap *and* exercises more of the production path (the message handler actually ran end-to-end). When the downstream effect is genuinely unavailable (no consumer wired in this test scope), `[Ignore]` the test with a reason rather than asserting against the bus and accepting flakes.

### Lazy Aspire Fixture Startup (canonical for `Test.Aspire`)

`Test.Aspire` starts the graph lazily: wrap startup in an `EnsureStartedAsync()` helper guarded by a `SemaphoreSlim`, called from each mesh test class's `[ClassInitialize]`, instead of an eager `[AssemblyInitialize]`. The graph boots on the first mesh class to run:

```csharp
public static class AspireTestHost
{
    private static DistributedApplication? _app;
    private static readonly SemaphoreSlim _gate = new(1, 1);

    public static async Task<DistributedApplication> EnsureStartedAsync(TestContext ctx)
    {
        if (_app is not null) return _app;
        await _gate.WaitAsync(ctx.CancellationToken);
        try
        {
            if (_app is not null) return _app;
            _app = await BuildAndStartAsync(ctx);
            return _app;
        }
        finally { _gate.Release(); }
    }
}

[TestClass]
public class BlazorMeshSmokeTests
{
    [ClassInitialize]
    public static Task ClassInit(TestContext ctx) => AspireTestHost.EnsureStartedAsync(ctx);
}
```

Teardown is owned by `AspireMeshLifecycle.[AssemblyCleanup]` in `Test.Aspire`, which stops/disposes the graph once regardless of which mesh class warmed it up. The component store fixtures live in the separate `Test.Integration` assembly and are started/stopped by their own `IntegrationTestSetup` `[AssemblyInitialize]`/`[AssemblyCleanup]` - the two assemblies never share a fixture.

### Opt-In Graph Scope via Env Flag

When the production AppHost graph includes resources that aren't needed for every test run (Gateway + Blazor UI, React/Vite UI, Function App, Notifications), gate their `AddProject` / `AddViteApp` calls in `AppHost.cs` on an env var the test fixture sets **before** `CreateAsync`:

```csharp
// AppHost.cs
if (Environment.GetEnvironmentVariable("{APP}_INCLUDE_BLAZOR") == "true")
{
    builder.AddProject<Projects.{App}_Blazor>("blazor").WithReference(gateway);
}

// Test fixture
SetEnvVar("{APP}_INCLUDE_BLAZOR", "true");
```

This mirrors the reference app's `TASKFLOW_INCLUDE_FUNCTIONS`/`TASKFLOW_ASPIRE_TESTING` flags. Each opt-in flag is **default-off in tests** (kept on for `dotnet run --project AppHost`). The `IsAspireTesting()` check in AppHost decides the default-off; the test fixture flips one flag per resource it needs. Document the flag set in `HANDOFF.md` so the next session knows the env-var contract.

For React/Vite, use the same pattern around `AddViteApp(...)` and pass the Gateway endpoint (or API endpoint when Gateway is disabled) through `VITE_API_BASE_URL`. Browser tests still use the actual Vite resource URL as their base URL.

### Async call discipline

- **Run every startup operation through one `AspireTestHostContext`.** It computes remaining time from a monotonic deadline, passes a linked token, and applies `WaitAsync(remaining, ct)`. A shorter per-step cap is allowed but cannot extend the global budget.
- **Gate on health, not status.** Aspire reports `Running` before SQL accepts connections / Azurite serves first request / Functions warms up. Call `WaitForResourceHealthyAsync(name, ct)` before talking to a resource.
- **Connection/endpoint lookup consumes remaining time.** Convert a `ValueTask` to `Task` only when the shared runner requires it; never grant a fresh timeout.
- **Bound shutdown and disposal together.** `[AssemblyCleanup(TestContext)]` calls `StopAndDisposeAsync(testContext.CancellationToken)`; one cleanup deadline covers both operations, and environment restoration remains in `finally`.

### Fixture skeleton

The Docker/deadline/wait/diagnostic/cleanup mechanics live in [../templates/test-templates-aspire.md](../templates/test-templates-aspire.md) section Shared Aspire test-host context. The lazy `EnsureStartedAsync` configures the mesh-specific graph, and `[AssemblyCleanup]` lives in `AspireMeshLifecycle`. Admin/browser and WasmUI adapters consume the same context instead of cloning fixture lifecycle code.

**State diagnostics on; resource logs optional.** On every host/start/wait failure, print named resource state, health, exit code, and start/stop timestamps before rethrowing. Raw logs remain opt-in via `{APP}_ASPIRE_RESOURCE_LOGGING=true` because they flood TRX output. This is a diagnostic switch, not a test-selection flag. Full pattern: [../templates/test-templates-aspire.md](../templates/test-templates-aspire.md) section *State diagnostics on by default; resource logs optional*.

---

## Template Map

| Template | Phase | Purpose |
|---|---|---|
| [../templates/test-templates-domain.md](../templates/test-templates-domain.md) | 5a | Domain entity + rule tests |
| [../templates/test-templates-repository.md](../templates/test-templates-repository.md) | 5a | Repository tests (in-memory unit) |
| [../templates/test-templates-integration.md](../templates/test-templates-integration.md) | 5a / 5b | Component: `SqlContainerFixture` / `AzuriteContainerFixture` + `IntegrationTestSetup`, `{Entity}RepositoryIntegrationTests`, `AuditLogRepositoryAzuriteTests`, `DomainEventPipelineTests` |
| [../templates/test-templates-aspire.md](../templates/test-templates-aspire.md) | 5b | Mesh: `AspireTestHost` (lazy) + `AspireMeshLifecycle`, `ApiAuditPipelineTests`, `FunctionAuditPipelineTests` |
| [../templates/test-templates-service.md](../templates/test-templates-service.md) | 5b | Service + mapper tests + consolidated `MapperProjectionParityTests` |
| [../templates/test-templates-endpoint.md](../templates/test-templates-endpoint.md) | 5b | Endpoint contract tests via WAF + InMemory; `WebApplicationFactoryBase` reference |
| [../templates/test-templates-e2e.md](../templates/test-templates-e2e.md) | 5b | `SqlApiFactory` + multi-endpoint `{Entity}WorkflowTests` against Testcontainers SQL |
| [../templates/test-templates-presentation.md](../templates/test-templates-presentation.md) | 5c | Uno MVUX presentation model tests in the fast `Test.Unit` lane |
| [../templates/test-templates-quality.md](../templates/test-templates-quality.md) | 5d | Architecture / Playwright / Load / Benchmarks / Mutation - load `testing-quality.md` instead |
| [../templates/test-templates.md](../templates/test-templates.md) | on-demand | Full-reference fallback |

## Verification Checklist

- [ ] Unit tests pass.
- [ ] Endpoint tests run via WAF in-memory host.
- [ ] Each searchable aggregate has at least one real relational-provider search/list path in `balanced` or higher.
- [ ] Harness split is respected (WAF vs hosted Playwright).
- [ ] Categories match intended command filters.
- [ ] Mutation tests use `TestCategory=Mutation` and the Stryker config uses the same test-case filter.
- [ ] Search tests always set `PageSize` and `PageIndex`.
- [ ] Rate limiter is disabled in test factory when API enables rate limiting.
- [ ] No FluentAssertions NuGet reference exists; no `<package pattern="FluentAssertions" />` in `nuget.config`.
- [ ] Every test field assigned in `[TestInitialize]` is declared with `= null!`.
- [ ] `[AssemblyInitialize]` does not hide infrastructure failures; preflight-confirmed Docker unavailability is `Inconclusive`, while container/AppHost startup failures after successful preflight remain red with diagnostics.
- [ ] `Test.Integration` (component) references no `AppHost`/`Aspire.Hosting.Testing`; tests instantiate one class vs one standalone Testcontainer and distinguish failed Docker preflight from a real container startup failure.
- [ ] `Test.Aspire` (mesh) starts the graph lazily via `EnsureStartedAsync` (`[ClassInitialize]`); `AspireMeshLifecycle.[AssemblyCleanup]` calls shared bounded stop/dispose cleanup once.
- [ ] Mesh tests carry `[TestCategory("Aspire")]` (not `Integration`); startup deadline reads `{APP}_ASPIRE_STARTUP_TIMEOUT_SECONDS`.
- [ ] Aspire/WasmUI tiers are default-on with false-only opt-out; `Test.Mobile` is opt-IN (`{APP}_MOBILE_TESTS_ENABLED=true` activates; default off self-marks `Inconclusive` per test, never a silent pass; TRX shows 0 passed / N not-executed). Explicit mobile runner fails fast when APK, emulator/device, Appium, or UiAutomator2 is missing/broken.
- [ ] `dotnet test --filter "TestCategory!=Load"` is documented as the canonical local "all normal tests" run.
- [ ] (AI scaffolded) Fast AI coverage (provider selection, contract, parse guard, no-write, write, no-op fallback) uses a fake `IChatClient` in `Test.Unit`/`Test.Endpoints`; live model tests are smoke-only (`LiveAI`) and follow [ai-integration.md](ai-integration.md) section Optional Live-Provider Classification. Determine an active provider via `GET /api/v1/ai/status`, not a `foundry` CLI probe or connection-string sniff. Require fresh CLI reproduction before changing deterministic tests; no duplicate provider-neutral contracts.
- [ ] Mesh tests are `[DoNotParallelize]`; no endpoint-contract tests in either integration project.
- [ ] Every test class has a class-level `<summary>` (scope / tier + why / quirks).
- [ ] Aspire host passes `Parameters:*` via `configureBuilder.hostSettings.Configuration`, not env vars.
- [ ] One shared startup deadline begins before Docker preflight/test-owned build and bounds Aspire create/build/start, named health waits, endpoint resolution, warm-up, and browser launch; subordinate caps cannot reset it.
- [ ] Env vars set for AppHost are scoped/restored (e.g., via `EnvironmentVariableScope`).
- [ ] Aspire-tier fixture is named for what it wraps (`AspireTestHost`, not `DatabaseFixture`).

## Pitfalls

- Horizontal slicing of tests across an entity (write all unit tests, then all endpoint tests, then all integration tests) - breaks the red/green/refactor loop and lets unverified entities accumulate. Slice vertically: one entity, all its tiers, green, next entity.
- Marking a test `Assert.Inconclusive` without recording the deferral in `HANDOFF.md` section Deferred External Dependencies - turns silent gaps into invisible debt that never returns to green.
- Aborting an `[AssemblyInitialize]` when infrastructure fails to start - hides individual diagnostics. Use the assembly-initializer safety pattern: Docker-unavailable dependents are inconclusive; post-preflight startup failures fail the dependent tests red.
- Adding FluentAssertions or another commercial-licensed assertion package - violates the assertion baseline (**GR-04**). Use MSTest built-in assertions plus the approved options in this skill.
- Sharing a single Aspire fixture across assemblies - couples startup costs and obscures which assembly owns which env vars; create one fixture per assembly that needs it.
- Skipping the `<summary>` on a `[TestClass]` - test classes without scope/tier/quirks notes accumulate dead weight nobody can re-evaluate.

## CQRS Test Routing

For `applicationStyle: switch`, run endpoint and E2E tests in both modes by overriding `Application:Style` or `<APP>_APPLICATION_STYLE`. The same HTTP contract tests should pass against service endpoints and CQRS endpoints. For `applicationStyle: cqrs`, run the same HTTP contract suite against CQRS endpoints as the only mapped endpoint set.

Add CQRS handler tests for use-case flow and validation decorator tests where custom validators exist.
