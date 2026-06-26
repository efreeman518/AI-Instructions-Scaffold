# Testing - Quality Gates & Hosted UI

Use this skill for Phase 5d quality suites and release hardening (architecture, hosted Playwright UI, load, benchmarks, mutation testing). For Phase 5a/5b unit/endpoint authoring and Aspire-hosted integration fixtures, load [testing.md](testing.md) instead.

## Quality Gate Suites

- `Test.Architecture`: layering rules (NetArchTest)
- `Test.PlaywrightUI`: hosted browser UI checks
- `Test.Load`: NBomber scenario thresholds
- `Test.Benchmarks`: BenchmarkDotNet regression tracking
- `Test.Mutation`: Stryker.NET mutation testing over high-value domain/service paths

## Architecture Rules

Assert:

- Domain does not depend on Infrastructure/Application/EF
- Application does not depend on Infrastructure
- API avoids direct persistence coupling

## Load Rules

- Start with one critical endpoint scenario.
- Define rps and duration explicitly.
- Track p50/p95/p99 and error rate.

## Benchmark Rules

- Use realistic setup and representative datasets.
- Benchmark hot paths only.
- Compare trends over time; do not use one-off numbers as hard pass/fail without baseline.
- Pin BenchmarkDotNet artifacts under the benchmark project, not the caller's CWD. BenchmarkDotNet defaults `ArtifactsPath` to the current directory, so running from the repo root drops a `BenchmarkDotNet.Artifacts/` folder there. Pass an explicit config: `DefaultConfig.Instance.WithArtifactsPath(...)` anchored to the solution root by walking up from `AppContext.BaseDirectory` to the `*.slnx`/`*.sln` marker, then into `src/Test/Test.Benchmarks/BenchmarkDotNet.Artifacts`.

## Mutation Testing Rules

- Generate `Test.Mutation` for the comprehensive profile or when explicitly requested for high-value domain/service logic.
- Keep mutation tests as normal MSTest `[TestClass]` / `[TestMethod]` tests with `[TestCategory("Mutation")]`.
- Run Stryker separately from ordinary `dotnet test`; Stryker mutates the configured target project and reruns the filtered MSTest suite.
- Configure `stryker-config.json` with `test-case-filter: TestCategory=Mutation` and a narrow `mutate` list. Do not point Stryker at the whole solution by default.
- Target boundaries, comparisons, boolean branches, collection behavior, state transitions, and exact failure messages. Weak assertions let equivalent, conditional, string, and collection mutants survive.
- Keep `StrykerOutput/` under the mutation test project and add `**/StrykerOutput/` to `.gitignore`.

## Deterministic Test Output Location

- Optional hardening - `.gitignore` already keeps `TestResults/` out of commits; this only buys a deterministic location (useful for CI artifact collection or when `dotnet test` runs from varying directories). Skip it if a single test props/targets file does not already exist.
- To pin test results, in the test-scoped `Directory.Build.props`/`.targets` under `src/Test/` (when one is present), inside the `IsTestProject` PropertyGroup set `<VSTestResultsDirectory>$(MSBuildThisFileDirectory)TestResults</VSTestResultsDirectory>`.
- `$(MSBuildThisFileDirectory)` resolves to the targets file's own absolute directory, so every test project writes to the same `src/Test/TestResults` regardless of the directory `dotnet test` runs from. `VSTestResultsDirectory` is the property the VSTest MSBuild task maps to `--results-directory`.
- Caveat: a raw `dotnet vstest <dll>` call bypasses MSBuild and honors only its own `--ResultsDirectory` flag.

## Optional Extras

- Coverage settings via `coverlet.runsettings` for stable CI behavior.

## Release Matrix

| Need | Recommended profile |
|---|---|
| Fast startup | `minimal` |
| Team default | `balanced` |
| Release hardening | `comprehensive` |

## Slice Gate by Profile

- `minimal`: Unit + Endpoint
- `balanced`: Unit + Endpoint + Integration + Architecture
- `comprehensive`: balanced + PlaywrightUI + Load + Benchmarks + Mutation (when scenario enabled)

If a slice spans multiple entities/stores, run at least one integration path that covers the full composite flow.

`minimal` does not prove EF query-translation correctness. Unit tests and WAF endpoint tests can pass while predicates over converted columns, owned-type filters, projections, or `Contains`/`LIKE` calls fail against SQL. In `balanced` and higher, include at least one real relational-provider search/list path per searchable aggregate, through `Test.E2E` when the behavior is HTTP workflow-shaped or `Test.Integration` when one repository/component is enough.

---

## Hosted Browser UI (Test.PlaywrightUI)

### Harness Contract

Playwright requires a real hosted stack. It cannot run on `WebApplicationFactory`. Run against Aspire AppHost locally, a docker-compose stack, or a preview deployment.

### Base URL Rules

- Configure one base URL per UI surface/project. Do not share a hard-coded URL across Blazor, Uno, and React.
- Make the base URL environment-driven (`{APP}_BLAZOR_BASE_URL`, `{APP}_WASM_BASE_URL` for Uno WASM, `{APP}_REACT_BASE_URL`, or equivalent) for externally hosted stacks (CI, docker-compose, preview deployments). The Uno var uses the `{APP}_WASM_*` family to match the standalone WASM test harness.
- When the app is Aspire-hosted, the C# suite resolves the URL programmatically: self-host the AppHost with `DistributedApplicationTestingBuilder`, wait for the UI resource to become healthy, then resolve its URL from `CreateHttpClient("{ui-resource}", "http").BaseAddress`. Full fixture shape: [../templates/test-templates-quality.md](../templates/test-templates-quality.md) section E2E Tests (Playwright). Vite/React resources may use a dynamic port; never assume `5173`, `5178`, or a prior run's URL.
- Never ship a hard-coded URL fallback or `[Ignore]`d tests pointed at a guessed URL - when no base URL can be resolved (env var absent, Docker/AppHost unavailable), mark tests `Assert.Inconclusive` with a precise message.
- Standalone Vite can use a conventional dev port, but hosted-stack Playwright must use the actual Aspire resource URL.

### Baseline Rules

- Use Page Object Model. **Language split:** author page objects in **C# only for stable, strongly-typed smoke paths that benefit from typed orchestration** - the Gateway/Blazor happy path is the canonical case. Keep React and Uno page/test helpers in **TypeScript** unless a concrete maintenance reason (e.g. an MSTest runner that must own the flow) justifies a C# wrapper. Do not port a working TypeScript suite to C# for uniformity's sake; the renderer-specific helpers (canvas bridge, coordinate-click) live more naturally in TS.
- Prefer stable selectors (`data-testid`).
- Isolate test data with unique names/ids.
- Assert structural UI strings, not data-dependent counts.
- Cover the real workflow surface: shell/navigation, create/read/update/delete, and nested child collections when the UI exposes them.

### Data-Dependent Assertion Anti-Pattern

Never assert seeded titles or exact row/page counts against shared dev DBs.

Bad: `"Showing 1 to 10 of 14 tasks"`, `"Page 1 of 2"`, specific seed task names.
Good: column headers, empty-state guidance text, static labels and landmarks.

### Uno WASM: Boot Once Per Describe

WASM cold-start is slow. Do not use the default `{ page }` fixture for Uno. Use serial describe + shared context/page in `beforeAll`.

```typescript
test.describe("EntityCrud", () => {
  test.describe.configure({ mode: "serial" });

  test.beforeAll(async ({ browser }) => {
    const baseURL = process.env.{APP}_WASM_BASE_URL;
    if (!baseURL) throw new Error("{APP}_WASM_BASE_URL is required for standalone Uno WASM Playwright runs");
    context = await browser.newContext({ ignoreHTTPSErrors: true });
    sharedPage = await context.newPage();
    await sharedPage.goto(baseURL);
    await waitForApp(sharedPage);
  });

  test.afterAll(async () => {
    await context.close();
  });
});
```

Set Playwright timeout to `120000` for suites containing Uno WASM cold-start.

`test.use({ viewport })` does not apply to `beforeAll`-owned contexts. Pass viewport to `browser.newContext({ viewport })`.

### React/Vite: Normal Page Fixture

React/Vite SPAs should use the normal Playwright page fixture unless the app has an unusually slow boot path. Add a dedicated Playwright project with an env-driven `baseURL`, then keep tests small and deterministic:

- One shell/navigation test, including theme persistence when the app has a theme toggle.
- One serial CRUD flow per high-value aggregate, using a unique test prefix and deleting created data.
- Child collection assertions in the same CRUD flow when create/edit screens support comments, checklist items, tags, attachments, or similar children.

If using Node Playwright and a shell wrapper mangles `npx`, invoke the local CLI directly with `node node_modules/@playwright/test/cli.js`.

### C# Host Wrapping a TypeScript Playwright Suite

**Scaffold rule: do NOT generate C# wrapper classes that directly invoke browser APIs (clicking, filling, navigating).** Generate TypeScript spec files and a single `TypeScriptPlaywrightRunner.cs` that orchestrates Node process lifecycle. The browser work stays in TypeScript; C# owns host lifecycle and MSTest integration only.

**TypeScript spec files must import from shared utilities (`utils/blazorTestUtils.ts` or equivalent) rather than writing inline `page.click()` / `page.fill()` chains:**
```typescript
import { waitForPageReady, navigateToNewTask, clickSaveNewTask, fillField } from "../utils/blazorTestUtils";

// Use helpers instead of raw page.* chains
await waitForPageReady(page);
await fillField(page, "Name", "My Task");
await clickSaveNewTask(page);
```

**`playwright.config.ts` must use intelligent browser detection with env-var fallback.** Do not hard-code browser executable paths in generated specs.

When `Test.PlaywrightUI` is a C# MSTest project that drives an existing TypeScript Playwright suite (so Aspire can select runnable hosts in C#, then hand off browser execution to TS), the child-process runner must be disciplined or failures vanish into test-host timeout noise:

- **Use `TypeScriptPlaywrightRunner.cs` as the entry point.** It detects Playwright-managed Chromium vs. system Chrome, manages Node process lifecycle and cancellation, and returns `CommandResult` / `BrowserReadiness` records. Do not build a one-off per-test runner - a single shared runner class serves the whole project.
- **Invoke `node` against the local CLI, not `npx`.** Resolve `node_modules/@playwright/test/cli.js` relative to the project directory and start `node.exe`/`node` with it via `ProcessStartInfo.ArgumentList`. `npx` can resolve through a broken local npm shim and silently run the wrong binary; a missing `node` on PATH should surface as a clear `Node.js is not available on PATH` error, not a generic Win32 failure.
- **Capture stdout and stderr even on cancellation.** Start the async reads (`ReadToEndAsync`) before awaiting exit, and return both streams in the result on the cancellation path too - a Playwright failure that arrives as the test host cancels must still reach the TRX, not disappear.
- **Kill the entire process tree.** On `OperationCanceledException`, call `process.Kill(entireProcessTree: true)` (swallow `InvalidOperationException` if it already exited), then `await WaitForExitAsync(CancellationToken.None)` so orphaned browser/node children do not leak and hold locks.
- **Gate on the CLI being installed.** Expose an `IsInstalled` check (`File.Exists(cliPath)`) and mark the test `Assert.Inconclusive` with the install step when the suite has not been provisioned, never red.
- **Do not use `--reporter=line` in captured child-process runs.** Its carriage-return progress output can hide the real failure in TRX/stdout capture. Use the default reporter, `list`, or `dot`.
- **Pin `@playwright/test` to `1.61.1` or newer** for generated Node suites. Older versions can add Node 26 `DEP0205 module.register()` deprecation noise to already-noisy browser output.
- **Build the wrapper project as a gate.** Namespace mismatches between wrapper tests and `TypeScriptPlaywrightRunner.cs` are scaffold defects. `dotnet build` or `dotnet test` on `Test.PlaywrightUI` must catch them before handoff.
- **Register the C# wrapper in the `.slnx`.** A `Test.PlaywrightUI` project with a .NET wrapper must be in the solution file or `dotnet test` over the solution silently skips it - the suite passes by being invisible. The TypeScript-only projects (React/Uno) are still run by their own Playwright config; only the .NET wrapper needs `.slnx` registration.

### Uno WASM: DOM/Click Strategy (managed-DOM renderer)

Uno WASM with the **managed-DOM renderer** often needs coordinate-click interaction.

- Query Uno elements by attributes like `xamltype` or `xamlautomationid`.
- Compute center with `getBoundingClientRect()`.
- Use `page.mouse.click(x, y)` (or down/up) with retry loop.
- Filter target text with known prefix (for example `E2E-`) to avoid collisions.

```typescript
for (let attempt = 0; attempt < 20; attempt++) {
  const coords = await page.evaluate(() => {
    for (const p of Array.from(document.querySelectorAll("p"))) {
      const txt = (p.textContent ?? "").trim();
      if (!txt.startsWith("E2E-")) continue; // filter by known prefix to avoid overlapping elements
      const r = p.getBoundingClientRect();
      if (r.width > 0 && r.height > 0 && r.y > 0 && r.x > 0)
        return { x: r.x + r.width / 2, y: r.y + r.height / 2 };
    }
    return null;
  });
  if (coords) { await page.mouse.click(coords.x, coords.y); break; }
  await page.waitForTimeout(500);
}
```

### Uno WASM: Canvas Test Bridge (Skia renderer)

If the app paints to a single Skia `<canvas>`, there are no per-control DOM nodes - DOM/text/role selectors and coordinate-clicking all fail structurally. Hard rule: a Skia-canvas Uno WASM test that uses `getByText`, role selectors, labels, or DOM text assertions is wrong. The browser DOM cannot expose text painted inside the canvas. Scaffold a browser-only test bridge that publishes app state to `globalThis.__{app}TestState` (query-string gated, default-off, real Gateway local auth) and have Playwright wait on state. The bridge state must include enough app-neutral fields for assertions: `page`, `section`, `hasToken`, `onboardingComplete`, `status`, and `error`. Tag these `[TestCategory("WasmUI")]`. Full pattern: [../templates/uno-wasm-test-bridge-template.md](../templates/uno-wasm-test-bridge-template.md). Detect the renderer with `document.querySelectorAll('[xamltype]').length` - `0` plus a lone `<canvas>` means Skia. Assert a rendered canvas larger than 100x100; never assert user-facing text with `getByText` against a Skia-canvas Uno app.

When the WASM app needs API, Gateway, SQL, Redis, storage, auth, or other Aspire resources, the `WasmUI` harness must start the AppHost graph. Do not treat it as a standalone browser-only suite, and do not require an external `{APP}_WASM_BASE_URL` for the default path. The harness starts Aspire in testing mode with `DistributedApplicationTestingBuilder.CreateAsync<Projects.{App}_AppHost>()`, disables only optional hosts, waits for required resources to become healthy, warms up auth through the real Gateway, and resolves UI/Gateway URLs from named Aspire endpoints. Use `CreateHttpClient(resource, "http")` for endpoint discovery and probes; never assume fixed local ports during a test run.

Build the WASM assets before browser navigation with `TargetFrameworkOverride=<tfm>-browserwasm` and `EnableUnoWasm=true`, then pass the dynamic Gateway endpoint to the browser through a test-only query parameter such as `{app}TestGatewayBaseUrl`. Without that override, a scaffolded app can accidentally call a fixed dev gateway port while Aspire assigned a dynamic port.

Every startup step must have its own timeout and progress log: Docker preflight, host lock, WASM restore, clean rebuild, AppHost builder creation, graph build, graph start, resource health, Gateway auth warm-up, UI endpoint readiness, and browser state wait. Missing Docker marks `Assert.Inconclusive` with the exact fix. Docker present means start Aspire and real backing resources.

Generated `WasmUI` assemblies must include `[assembly: DoNotParallelize]`. AppHost-backed browser classes fight over containers, ports, WASM output, and cold-start state when MSTest runs them in parallel.

The shared AppHost-backed `WasmAppHost` builds the WASM head and starts Aspire once per assembly. Its lazy single-start guard must use static fixture state, for example `_app != null && _staticBaseUrl != null`, then copy `_staticBaseUrl` into each test's fresh `WasmTestSettings`. Never guard on the per-test `settings.BaseUrl`; each test gets a new settings instance and would re-enter the clean rebuild while the first `*.WasmHost.exe` still holds the staged output. Reset the static URL during assembly cleanup. Symptom of the broken guard: the second `WasmUI` test fails with `MSB3027` / `MSB3021` copying a locked `*.WasmHost.exe`; after the fix, later tests skip rebuild and start in seconds.

### Uno WASM: Browser Diagnostics

Browser diagnostics are part of the harness, not an optional debugging add-on. Capture these on navigation failure, bridge-state timeout, page error, or Playwright exception:

- Console messages.
- Page errors.
- Failed requests.
- HTTP responses with status 400 or higher.
- `window.onerror`.
- `unhandledrejection`.
- Current URL.
- `document.readyState`.
- First HTML snippet.
- Script URL list.
- Canvas count.
- Body text snippet.
- Last bridge state JSON.

Install the `window.onerror` / `unhandledrejection` capture with `AddInitScriptAsync` before navigating so early Mono/WASM failures are retained.

### Uno WASM: Slow Router After Many Navigations

Increase late-lifecycle assertions to `60000` when page loads occur after several navigations in same shared page.

### Uno Mobile: Test Split

- Use Playwright mobile viewports against Uno WASM for fast responsive checks on Windows.
- Use Android emulator UI smoke tests for native startup, shell navigation, platform config, and local-backend networking. Start with mocks (`/p:UseMocks=true`), then add a tiny live Aspire-backed suite for Gateway/API wiring.
- When the repo uses MSTest, scaffold mobile native smoke tests as MSTest + Appium (`Test.Mobile`) instead of introducing NUnit. Keep them opt-in through runsettings/environment variables so normal `dotnet test` does not require an emulator.
- For Android Appium runs, restore the Uno project with all platform targets before the Android build: `dotnet restore src/UI/{Project}.Uno/{Project}.Uno.csproj -p:BuildAllUnoTargets=true`, then build with `TargetFrameworkOverride=$(LatestStableTfm)-android --no-restore`.
- In Android test setup, verify `appium`, `uiautomator2`, `adb`, `emulator`, `ANDROID_HOME`, and `JAVA_HOME` with `appium driver doctor uiautomator2` before blaming app code.
- Treat iOS simulator/device UI tests as macOS-only. On Windows, record iOS compile status and mark simulator/device execution as blocked unless a Mac host or macOS CI runner is available.

### MudBlazor Timing Rules

- Before fill/click on a field after navigation, wait for visibility first.
- Confirmation dialogs may need `15000` timeout.

```typescript
await field.first().waitFor({ state: "visible" });
await expect(dialog).toBeVisible({ timeout: 15_000 });
```

### Playwright Config Output Location

Set `outputDir` under `Test/Test.PlaywrightUI`, not under app project directories.

## Visual Studio & VS Code Test Explorer

All test projects must be registered in the `.slnx` so both Test Explorers discover them. Generate a short test README (or top-of-class comments) stating the local workflow. **Only include the env vars, tasks, and stack steps for tiers this scaffold actually generated** - an `api-only` / no-UI scaffold has no Aspire/WASM/Mobile rows, so do not document their env vars or tasks (see [Capability-Gated Test Tiers](testing.md#capability-gated-test-tiers-the-early-decision-drives-the-rest)).

- **Start the stack once per session.** When the scaffold has Aspire/WASM/mobile tiers, run `eng/test/start-local-test-stack.ps1` ([../templates/local-test-stack-template.md](../templates/local-test-stack-template.md)) before those tests - it starts the AppHost and provisions browsers/emulator/Appium.
- **Filter by category in Test Explorer:** among the tiers present, plus exclude `Load`. The canonical local run is `dotnet test --filter "TestCategory!=Load"`.
- **Opt out with false-only env vars** for the default-on heavy tiers when you do not want one locally - only the vars for present tiers exist: `{APP}_RUN_ASPIRE_TESTS=false` (if Aspire), `{APP}_WASM_TESTS_ENABLED=false` (if Uno WASM). Default (unset) runs the tier; it self-marks `Inconclusive` if its prerequisite is missing. **`Test.Mobile` is the exception: opt-IN.** It defaults off (emulator/Appium/APK are too heavy for the canonical lane) - set `{APP}_MOBILE_TESTS_ENABLED=true` to activate it; unset/false self-marks `Assert.Inconclusive` per test (never a silent pass; serializes to TRX as not-executed) (see [Capability-Gated Test Tiers](testing.md#capability-gated-test-tiers-the-early-decision-drives-the-rest)).
- **Generate `.vscode/tasks.json`** with tasks for the present tiers only (start stack, build WASM, install Playwright Chromium, build Android APK, run all non-load, run Aspire/WASM/Mobile). Task definitions are in the [local test stack template](../templates/local-test-stack-template.md).

## Verification Checklist

- [ ] Architecture tests enforce layering rules.
- [ ] Load scenarios track p50/p95/p99 and error rate against an explicit baseline.
- [ ] Benchmark suites use representative datasets; results compared to a baseline, not measured in isolation.
- [ ] Mutation suite uses normal MSTest classes, `TestCategory=Mutation`, focused Stryker mutate globs, and ignored `StrykerOutput/`.
- [ ] Hosted Playwright stack is reachable and base URL is correct.
- [ ] Aspire-hosted UI tests use the current resource URL, not a stale dashboard URL or default Vite port.
- [ ] AppHost-backed `WasmUI` tests start the Aspire graph in testing mode, keep required resources live, and disable only optional hosts.
- [ ] AppHost-backed `WasmUI` fixture caches the resolved base URL in static state and guards on static `_app` / URL state, not per-test settings.
- [ ] `WasmUI` tests use named Aspire endpoints and `CreateHttpClient(resource, "http")`, not fixed local ports.
- [ ] `WasmUI` assemblies are `[assembly: DoNotParallelize]`.
- [ ] WASM browser diagnostics capture console, errors, failed requests, response errors, URL, HTML, scripts, canvas count, body text, and bridge state.
- [ ] Selector strategy is stable for the target UI tech.
- [ ] UI assertions are structural, not seed/count-dependent.
- [ ] Timeout profile matches UI runtime behavior (Uno WASM cold-start: 120s).
- [ ] Test output folder is inside the test project.
