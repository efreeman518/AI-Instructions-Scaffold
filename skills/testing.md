# Testing

Default test scaffolding skill for Phase 5a, 5b, and integration hosts. For Phase 5d quality gates and Playwright UI, load [testing-quality.md](testing-quality.md) instead.

Reference patterns: [../patterns/expected-output-index.md](../patterns/expected-output-index.md) (Testing).

## Never Silently Pass (applies to every tier)

A test that did not actually exercise its target must **never report green.** Whenever a default lane cannot run - missing Docker, browser, CLI, unresolved base URL, unsupported host, or fixture/infra startup failure - it must self-mark `Assert.Inconclusive` with a message naming the missing prerequisite and the fix. Exception: explicit enabled mobile lanes fail fast red when APK, emulator/device, Appium, or UiAutomator2 is missing or broken. Never:

- return early and let the test pass without an assertion,
- `[Ignore]` or no-op it so it counts as passed,
- swallow a startup exception and continue green.

`Inconclusive` is the only correct outcome for "could not run"; a genuine `Assert.*` failure stays red. MSTest serializes `Inconclusive` to TRX as `outcome="NotExecuted"`, so a healthy "couldn't run here" result is **0 passed / N not-executed, each carrying a message** - that is expected, not a failure to chase. Record any standing deferral in `HANDOFF.md` (section Deferred External Dependencies) so a not-executed count never hides invisible debt.

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
4. **Manual run command** (required for infra-dependent tiers - `Aspire`, `WasmUI`, `MobileUI`, `Integration`, `E2E`): the exact `dotnet test ... --filter ...` line for non-mobile tiers, or `src/Test/Test.Mobile/run-mobile-tests.ps1` for `MobileUI`, plus any opt-out var or prerequisite (start Docker, run `eng/test/start-local-test-stack.ps1`), so a developer reproduces the run without hunting docs.

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

## Profiles

| Profile | Include by default |
|---|---|
| `minimal` | Unit + Endpoint |
| `balanced` | Minimal + Integration (component) + Architecture + Test.Support + `Test.UI` when UI model/presentation coverage exists |
| `comprehensive` | Balanced + Aspire mesh + PlaywrightUI + Load + Benchmarks + Mutation |

Rule: start balanced, then add hosted UI and performance suites when slices stabilize. Separate two switches that are easy to conflate (see [Capability-Gated Test Tiers](#capability-gated-test-tiers-the-early-decision-drives-the-rest)): **generation** (does the test project exist?) is driven by the early Phase 2 capability pick + `testingProfile`; **runtime gating** (does a generated tier run, or self-skip?) is default-on for a selected tier with a local false-only opt-out - except `Test.Mobile`, which is opt-IN (default off) because its emulator/Appium/APK preconditions are too heavy for the canonical lane.

The `resource-implementation.yaml` test booleans drive **generation**: `comprehensive` implies `includeAspireTests` + `includePlaywrightUITests` (plus Load/Benchmarks/Mutation) when those flags are omitted. Setting a flag explicitly overrides the profile default. `includeMobileTests` (`Test.Mobile`, Uno native Appium) and the Skia-canvas `WasmUI` bridge tier require `includeUnoUI`; generate them in balanced+ when Uno is in scope. Generate `Test.UI` when UI model/presentation coverage exists; it is the fast headless UI lane for UI services, theme/catalog logic, presentation models, and MVUX state/feed tests. Do not confuse `includeE2ETests` (`Test.E2E`, WebApplicationFactory + Testcontainers SQL) with `includePlaywrightUITests` (`Test.PlaywrightUI`, browser-driven) - they are distinct tiers.

EF query-translation correctness requires a real relational provider. `minimal` (Unit + Endpoint) does not cover translated predicates, projections, owned-type filters, or value-converted columns because endpoint tests use the in-memory WAF path. In `balanced` and higher, add at least one real-SQL search/list path per searchable aggregate: `Test.E2E` for HTTP workflow coverage or `Test.Integration` for repository/component coverage.

## Capability-Gated Test Tiers (the early decision drives the rest)

The early Phase 2 capability pick - `scaffoldMode` plus the `include*UI` / `useAspire` host flags ([resource-implementation-schema.md](../ai/resource-implementation-schema.md) Question 2) - determines which tiers exist **at all**. An `api-only` / no-UI scaffold has none of the rows below: no project, no category, no env var, no setup-script branch, no VS Code task. Do not default these on; a tier appears only because a capability was selected early.

| Early Phase 2 pick | Tier (project / category) | Local gating var | Stack-script branch + VS Code tasks |
|---|---|---|---|
| `api-only` / no UI | none of Test.UI / PlaywrightUI / WasmUI / Mobile | - | - |
| UI model/presentation coverage exists | `Test.UI` / `UI` or `Presentation` (headless) | none | none |
| `includeBlazorUI` / `includeReactUI` (+ comprehensive or `includePlaywrightUITests`) | `Test.PlaywrightUI` / `PlaywrightUI` (DOM) | none (generation-gated) | Playwright install |
| `includeUnoUI`, Skia renderer (+ comprehensive or `includePlaywrightUITests`) | `Test.PlaywrightUI` / `WasmUI` (canvas bridge) | `{APP}_WASM_TESTS_ENABLED` (opt-out; default on) | Build WASM, Playwright install; tasks: Build WASM, Test: WASM |
| `includeUnoUI` (+ balanced or `includeMobileTests`) | `Test.Mobile` / `MobileUI` (Appium) | `{APP}_MOBILE_TESTS_ENABLED` (opt-IN; default off) | `src/Test/Test.Mobile/run-mobile-tests.ps1`; tasks: Test: Mobile |
| `useAspire: true` (+ comprehensive or `includeAspireTests`) | `Test.Aspire` / `Aspire` (mesh) | `{APP}_RUN_ASPIRE_TESTS` (opt-out; default on) | AppHost start; task: Test: Aspire |

This table is the single source of truth. Phase 2 records the selected tiers (Question 9), [../ai/contract-scaffolding.md](../ai/contract-scaffolding.md) generates exactly those projects, and the [local test stack](../templates/local-test-stack-template.md) script / VS Code tasks expose only their branches.

**For a tier the early decision generated:**

- **Runs by default (Aspire + WasmUI).** Each is discoverable in Test Explorer and runs under `--filter "TestCategory!=Load"`. Its `{APP}_*_TESTS` var is a **local convenience** to silence it (treat any value other than a case-insensitive `false` as "run") - not an enable flag the developer must know to turn the tier on.
- **Exception - `Test.Mobile` is opt-IN, default off.** Mobile needs an emulator/device, Appium + UiAutomator2, and a built platform APK - too heavy for the canonical lane. Treat `{APP}_MOBILE_TESTS_ENABLED` as an **enable** flag: only a case-insensitive `true` (or `1`/`yes`) activates the tier; unset/false makes each test self-mark `Assert.Inconclusive` with a message saying the tier is opt-in and how to enable it - **never a silent pass.** A skipped-as-passed mobile test reads as green coverage that never ran. MSTest serializes `Inconclusive` to TRX as `outcome="NotExecuted"`, so the expected healthy default-off result is **0 passed / N not-executed, each carrying an Inconclusive message** - success, not failure. Keep `[TestCategory("MobileUI")]` on every test so a lane can also exclude it by filter. This is the one tier that defaults off; Aspire and WasmUI stay default-on per the bullet above.
- **Explicit mobile lane fails fast.** `src/Test/Test.Mobile/run-mobile-tests.ps1` owns Android restore/build, emulator readiness, Appium readiness, `{APP}_MOBILE_TESTS_ENABLED=true`, and TRX output. Once that runner activates the tier, missing/broken APK, emulator/device, Appium, or UiAutomator2 is red, not `Assert.Inconclusive`. Default `dotnet test` without the enable flag remains dependency-free inconclusive.
- **Self-skips, never red - and never silently green** (see [Never Silently Pass](#never-silently-pass-applies-to-every-tier)). Degrade to `Assert.Inconclusive` for default-lane prerequisite gaps - Docker/AppHost, WASM host/browser, opt-in flag unset, base URL unresolved, or fixture startup failed. The message names the cause and the fix (start Docker, run `eng/test/start-local-test-stack.ps1`, use the mobile runner, or set the opt-out). No vague "skipped", and never an assertion-free early return that passes.
- **CI lanes set the opt-out.** Fast lanes that must not pay Docker/emulator cost set `{APP}_RUN_ASPIRE_TESTS=false` (etc.). `--filter "TestCategory!=Load"` stays safe because absent-infra default tiers self-skip; explicit mobile workflow_dispatch uses the runner and fails fast.
- The mesh preflight helper shape is in [../templates/test-templates-aspire.md](../templates/test-templates-aspire.md) (Opt-out + preflight). Mirror it for `WasmUI`; mobile uses generated runner plus method-level default-off preflight.
- **AppHost-backed WasmUI is real mesh UI.** If the Uno WASM app depends on API, Gateway, SQL, Redis, storage, or auth, the `WasmUI` fixture starts the Aspire AppHost in testing mode, keeps required resources live, disables only optional hosts, and resolves Gateway/UI URLs from named endpoints. Do not generate standalone browser tests against guessed local ports for that case.
- **Bound heavy startup.** `Aspire`, `WasmUI`, and `MobileUI` flows log every long startup step and apply explicit per-step timeouts. A single hanging restore, AppHost start, browser navigation, bridge-state wait, emulator boot, Appium session, or UiAutomator2 wait must fail that step with diagnostics, not hang Test Explorer.

### Container Runtime (Docker) for Mesh / Component Tiers

The container-backed tiers - `Test.Aspire` (mesh) and `Test.Integration` / `Test.E2E` (Testcontainers) - require a working container runtime; the fast tiers do not.

- **Gate on a generic container-capability check, not a Docker-Desktop probe.** Treat the runtime as available when the Testcontainers/Docker client can connect (or `docker info` succeeds). Docker Desktop, WSL Docker Engine, Rancher Desktop, and a Podman-compatible Docker socket are all valid - never special-case a product or probe for Docker Desktop specifically in test code.
- **No runtime -> `Assert.Inconclusive`** with a message naming the missing container runtime and the fix (see [Never Silently Pass](#never-silently-pass-applies-to-every-tier)). This is the `StartupError`-captured path in the standalone fixtures and the Aspire fixture preflight.
- **Never silently downgrade a mesh or component test to an in-memory provider.** Swapping a Testcontainers SQL / Aspire mesh test to EF InMemory when Docker is absent makes it pass while exercising none of the real-infra failure modes it exists to catch - that hides infra failures behind green. Self-skip (`Inconclusive`); do not rewrite it to a lighter store.
- **Unit, endpoint, and fake-`IChatClient` AI tests run with no Docker at all** - they must never take a container dependency.

Suspect container resource pressure before editing test logic when health checks flap; the resource floor, WSL `.wslconfig`, and runtime-restart guidance live in [../support/troubleshooting.md](../support/troubleshooting.md) -> Docker / Container Runtime.

## Project Layout

```text
Test/
  Test.Support/
  Test.Unit/
  Test.UI/
  Test.Integration/      # component: one class vs one real store (standalone Testcontainers)
  Test.Aspire/           # mesh: full AppHost graph over HTTP (lazy-started)
  Test.Endpoints/
  Test.E2E/
  Test.Architecture/
  Test.PlaywrightUI/
  Test.Load/
  Test.Benchmarks/
  Test.Mutation/
```

When any of `Test.Aspire`, the `WasmUI` bridge tier, or `Test.Mobile` is in scope, generate re-runnable operator tooling: `eng/test/start-local-test-stack.ps1` (process-env only - no permanent PATH edits), `.vscode/tasks.json`, and `src/Test/Test.Mobile/run-mobile-tests.ps1` when mobile exists. The stack script builds WASM, installs Playwright browsers, starts Aspire AppHost, waits endpoints, and prints rerun commands. The mobile runner owns Android build, emulator/Appium readiness, enable flag, `dotnet test`, and TRX output. Full shape: [../templates/local-test-stack-template.md](../templates/local-test-stack-template.md). Default heavy tiers self-skip (`Inconclusive`) when prerequisites are missing; explicit mobile runner fails fast on broken mobile prerequisites.

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

`Test.Aspire` AI smoke is Azure Foundry only when configured; it must set `AiServices:DisableFoundryLocal=true` and never attempt Foundry Local. `Test.FoundryLocal` starts API host directly, sets `AiServices:RequireFoundryLocal=true`, checks `/api/v1/ai/status`, and is inconclusive when runtime is missing/undiscoverable or when a healthy provider's model generation runs past the per-request budget (capacity, not failure). Installed/discovered runtime that falls back to no-op, returns bad HTTP or an invalid/missing contract, or reports wrong status is failure.

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

The project-local `AssertionExtensions` class (in `Test.Support/AssertionExtensions.cs`) provides `.Should()` syntax via `global using` in `Test.Unit/GlobalUsings.cs`. Use it; do not import FluentAssertions to get the same syntax.

Prefer specific MSTest asserts over generic `Assert.IsTrue`.

## Categories and Command Split

Use these categories: `Unit`, `UI`, `Presentation`, `Endpoint`, `Integration`, `Aspire`, `E2E`, `PlaywrightUI`, `WasmUI`, `MobileUI`, `Architecture`, `Load`, `Benchmark`, `Mutation`. When AI is scaffolded, the live model smoke lane adds `LiveAI` (plus `FoundryLocal` / `AzureFoundry` to scope a smoke to a single provider).

Category boundaries that matter:

- **`UI` / `Presentation`** fast headless UI tier (`Test.UI`) for UI services, theme/catalog logic, presentation models, MVUX state/feed tests. Never tag these `Unit`, and never reference a Uno.Sdk app head.
- **`Aspire`** is the mesh tier (`Test.Aspire`), distinct from **`Integration`** (component, `Test.Integration`). Never tag mesh tests `Integration` - that would boot the full graph on a `--filter TestCategory=Integration` run.
- **`PlaywrightUI`** is DOM-based browser UI (MudBlazor/React/managed-DOM Uno). **`WasmUI`** is the Skia-canvas Uno bridge tier. **`MobileUI`** is Appium. None of these is `E2E` (`E2E` is WAF + Testcontainers SQL).
- **`LiveAI`** is the model-backed AI smoke lane in `Test.Aspire` - one active-provider lane (Azure if configured, else Foundry Local if it bootstraps), `Inconclusive` (never green) when no real provider is active. Fast AI coverage (contract, parse guard, no-write, write, no-op fallback) uses a fake `IChatClient` in `Test.Unit` / `Test.Endpoints` and carries no AI category. `AzureFoundry` is for Azure-specific selection/provisioning only, not a second copy of a provider-neutral contract. Doctrine: [ai-integration.md](ai-integration.md) -> Provider Test Tiers.

```powershell
# Canonical "all normal tests" - excludes Load (NBomber). Heavy tiers (Aspire/WasmUI/MobileUI)
# self-mark Inconclusive when Docker/emulator/Appium is absent, so this is safe to run anywhere.
dotnet test .\{SolutionName}.slnx --filter "TestCategory!=Load"

# Scoped runs
dotnet test --filter "TestCategory=Unit"
dotnet test --filter "TestCategory=UI"
dotnet test --filter "TestCategory=Presentation"
dotnet test --filter "TestCategory=Endpoint"
dotnet test --filter "TestCategory=Integration"
dotnet test --filter "TestCategory=Aspire"
dotnet test --filter "TestCategory=E2E"
dotnet test --filter "TestCategory=PlaywrightUI"
dotnet test --filter "TestCategory=WasmUI"
dotnet test --filter "TestCategory=MobileUI"
dotnet test --filter "TestCategory=LiveAI"        # active-provider AI smoke; Inconclusive when no real provider
dotnet test src/Test/Test.Mutation/Test.Mutation.csproj --filter "TestCategory=Mutation"
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

`[AssemblyInitialize]` methods must **never throw**. A throwing `AssemblyInitialize` causes MSTest to abort the entire assembly - including tests that have no dependency on the failed setup.

For test assemblies that start external infrastructure (e.g., Testcontainers), apply this pattern:

```csharp
[AssemblyInitialize]
public static async Task AssemblyInit(TestContext context)
{
    try
    {
        await _fixture.InitializeAsync();
    }
    catch (Exception ex)
    {
        _startupError = ex;
        // Do not rethrow - let individual tests mark themselves inconclusive
    }
}
```

In each test that depends on the infrastructure, check readiness at the start:

```csharp
[TestInitialize]
public void TestSetup()
{
    if (_startupError != null)
        Assert.Inconclusive($"Infrastructure startup failed: {_startupError.Message}");
}
```

This isolates startup flakiness (e.g., `RegexMatchTimeoutException` from Testcontainers image parsing under CPU contention) to affected tests only, and keeps unrelated tests runnable.

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

When `includeUnoUI: true`, test MVUX presentation records from `src/UI/{Project}.Uno.Presentation/Presentation` in `Test.UI/Presentation`. The test project references `{Project}.Uno.Core` and `{Project}.Uno.Presentation` only, never the `{Project}.Uno` `Uno.Sdk` app head. Use [../templates/test-templates-presentation.md](../templates/test-templates-presentation.md) for the `SourceContext` harness, stub `HttpMessageHandler`, and local nullable-warning suppressions. Tag classes `UI`; tag presentation-specific methods `Presentation`.

### Endpoint (Test.Endpoints)

Use `WebApplicationFactory` and validate status code, response shape, validation, and auth contract for one endpoint at a time.

### Workflow E2E (Test.E2E)

Use WAF + real SQL (often Testcontainers) for create->search->update->delete business flows through HTTP.

### Blazor - Three-Layer Coverage

When `includeBlazorUI: true`, scaffold three tiers so failures localize:

1. **In-isolation host smoke** (`Test.Endpoints/BlazorHostSmokeTests`) - `WebApplicationFactory<{Project}.Blazor.Program>` builds the host with no Refit backend. Catches DI / Refit registration / MudBlazor service-provider failures at startup. Fast (no Aspire, no SQL).
2. **Aspire-mesh smoke** (`Test.Aspire/BlazorMeshSmokeTests`) - Blazor opt-in via `{APP}_INCLUDE_BLAZOR=true`; verifies the full graph (Gateway routing + Refit + tenant header) by hitting one page that round-trips through the API. Calls `AspireTestHost.EnsureStartedAsync` from `[ClassInitialize]`.
3. **Hosted Playwright** (`Test.PlaywrightUI/BlazorSmokeTests`) - real browser against a hosted stack; comprehensive profile only.

Each tier owns a different failure mode. Without tier 1, MudBlazor DI breakage is invisible until tier 2 / tier 3 fails with a misleading "page didn't load" symptom.

## Test Data Builders

Place fluent builders in `Test.Support/Builders/`.

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

1. **One shared app per assembly.** Start once in `[AssemblyInitialize]` and reuse. Never per test class.
2. **Set scoped flags (e.g., `TASKFLOW_ASPIRE_TESTING`, `TASKFLOW_INCLUDE_FUNCTIONS`) before `CreateAsync`** - only for things AppHost reads via `Environment.GetEnvironmentVariable`. **Save and restore originals** in cleanup for hermeticity.
3. **Pass parameters via `configureBuilder`, not env-var mutation.** AppHost binds `Parameters:*` through `IConfiguration` - write them into `hostSettings.Configuration` so test isolation stays clean.
4. **Conditional Functions inclusion.** Detect `func.exe` once in fixture before startup. Set the include flag there, not per test class. Tests that require Functions call `Assert.Inconclusive` when the resource is absent.
5. **Timeout mandatory.** `[Timeout]` on every Aspire integration test method (`300000` for full multi-service, `120000` for single-service). The fixture's build/start/health-gate deadline is **separate** and configurable via `{APP}_ASPIRE_STARTUP_TIMEOUT_SECONDS` (default 600 s) - cold SQL + storage containers (first image pull, post-prune) routinely exceed a hardcoded 5 min.
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

- **Per-call `.WaitAsync(timeout, ct)` on every async Aspire call.** Not a single umbrella `CancellationTokenSource(timeout)` - per-call so a hung step fails *that* step.
- **Gate on health, not status.** Aspire reports `Running` before SQL accepts connections / Azurite serves first request / Functions warms up. Call `WaitForResourceHealthyAsync(name, ct)` before talking to a resource.
- **`GetConnectionStringAsync` returns `ValueTask<string?>`** - wrap as `.AsTask().WaitAsync(timeout, ct)`. `ValueTask` has no `WaitAsync` extension.
- **Bound shutdown.** `[AssemblyCleanup(TestContext)]` (MSTest 3.x overload - use `testContext.CancellationToken`); call `StopAsync(...).WaitAsync(CleanupTimeout)` and catch `TimeoutException` so a stuck teardown does not hang CI.

### Fixture skeleton

The build/start/health-gate/connection-string mechanics live in [../templates/test-templates-aspire.md](../templates/test-templates-aspire.md) section AspireTestHost. The lazy `EnsureStartedAsync` above runs them on first use, and `[AssemblyCleanup]` lives in `AspireMeshLifecycle`. Key rules preserved here: pass `Parameters:*` via `configureBuilder` host configuration (never env vars), set `DisableDashboard = true` explicitly, give every async Aspire call its own `.WaitAsync(timeout, ct)`, and bound `[AssemblyCleanup]` with `CleanupTimeout`, catching `TimeoutException`.

**Resource logging off by default.** Set `appOptions.EnableResourceLogging = false` for test hosts - the logs flood the TRX and bury real failures. Read resource *state* from `AspireApp.ResourceNotifications` in failure diagnostics (always available), and expose raw logs only through an internal diagnostic override (`{APP}_ASPIRE_RESOURCE_LOGGING=true`) that belongs in troubleshooting docs, not the normal test opt-in surface. This is a diagnostic switch, not a test-selection flag - keep it out of the capability-gated tier table. Full pattern: [../templates/test-templates-aspire.md](../templates/test-templates-aspire.md) section *Resource logging off by default*.

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
- [ ] `[AssemblyInitialize]` does not throw; infrastructure failures mark dependent tests `Inconclusive`.
- [ ] `Test.Integration` (component) references no `AppHost`/`Aspire.Hosting.Testing`; tests instantiate one class vs one standalone Testcontainer and guard on `StartupError` (Inconclusive on failure).
- [ ] `Test.Aspire` (mesh) starts the graph lazily via `EnsureStartedAsync` (`[ClassInitialize]`); `AspireMeshLifecycle.[AssemblyCleanup]` stops it once, bounded by `.WaitAsync(CleanupTimeout)`.
- [ ] Mesh tests carry `[TestCategory("Aspire")]` (not `Integration`); startup deadline reads `{APP}_ASPIRE_STARTUP_TIMEOUT_SECONDS`.
- [ ] Aspire/WasmUI tiers are default-on with false-only opt-out; `Test.Mobile` is opt-IN (`{APP}_MOBILE_TESTS_ENABLED=true` activates; default off self-marks `Inconclusive` per test, never a silent pass; TRX shows 0 passed / N not-executed). Explicit mobile runner fails fast when APK, emulator/device, Appium, or UiAutomator2 is missing/broken.
- [ ] `dotnet test --filter "TestCategory!=Load"` is documented as the canonical local "all normal tests" run.
- [ ] (AI scaffolded) Fast AI coverage (contract, parse guard, no-write, write, no-op fallback) uses a fake `IChatClient` in `Test.Unit`/`Test.Endpoints`; live model tests are smoke-only in `Test.Aspire` as one active-provider lane (`LiveAI`), `Inconclusive` (never green) on no-op. The lane decides the provider via `GET /api/v1/ai/status`, not a `foundry` CLI probe or connection-string sniff. No per-provider copies of provider-neutral contracts. See [ai-integration.md](ai-integration.md) -> Provider Test Tiers.
- [ ] Mesh tests are `[DoNotParallelize]`; no endpoint-contract tests in either integration project.
- [ ] Every test class has a class-level `<summary>` (scope / tier + why / quirks).
- [ ] Aspire host passes `Parameters:*` via `configureBuilder.hostSettings.Configuration`, not env vars.
- [ ] Every async Aspire call has its own `.WaitAsync(timeout, ct)` (no umbrella CTS); tests gate on `WaitForResourceHealthyAsync`.
- [ ] Env vars set for AppHost are scoped/restored (e.g., via `EnvironmentVariableScope`).
- [ ] Aspire-tier fixture is named for what it wraps (`AspireTestHost`, not `DatabaseFixture`).

## Pitfalls

- Horizontal slicing of tests across an entity (write all unit tests, then all endpoint tests, then all integration tests) - breaks the red/green/refactor loop and lets unverified entities accumulate. Slice vertically: one entity, all its tiers, green, next entity.
- Marking a test `Assert.Inconclusive` without recording the deferral in `HANDOFF.md` section Deferred External Dependencies - turns silent gaps into invisible debt that never returns to green.
- Aborting an `[AssemblyInitialize]` when infrastructure fails to start - flips the entire assembly red and hides genuine code failures. Use the assembly-initializer safety pattern (mark dependents `Inconclusive` instead).
- Adding FluentAssertions or another commercial-licensed assertion package - violates the assertion baseline (**GR-04**). Use MSTest built-in assertions plus the approved options in this skill.
- Sharing a single Aspire fixture across assemblies - couples startup costs and obscures which assembly owns which env vars; create one fixture per assembly that needs it.
- Skipping the `<summary>` on a `[TestClass]` - test classes without scope/tier/quirks notes accumulate dead weight nobody can re-evaluate.

## CQRS Test Routing

For `applicationStyle: switch`, run endpoint and E2E tests in both modes by overriding `Application:Style` or `<APP>_APPLICATION_STYLE`. The same HTTP contract tests should pass against service endpoints and CQRS endpoints. For `applicationStyle: cqrs`, run the same HTTP contract suite against CQRS endpoints as the only mapped endpoint set.

Add CQRS handler tests for use-case flow and validation decorator tests where custom validators exist.
