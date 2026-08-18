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
- Pin BenchmarkDotNet artifacts under the benchmark project, not the caller's CWD. BenchmarkDotNet defaults `ArtifactsPath` to the current directory, so running from the repo root drops a `BenchmarkDotNet.Artifacts/` folder there. Pass an explicit config: `DefaultConfig.Instance.WithArtifactsPath(...)` anchored to the solution root by walking up from `AppContext.BaseDirectory` to the `*.slnx`/`*.sln` marker, then into `tests/Test.Benchmarks/BenchmarkDotNet.Artifacts`.

## Mutation Testing Rules

- Generate `Test.Mutation` for the comprehensive profile or when explicitly requested for high-value domain/service logic.
- Keep mutation tests as normal MSTest `[TestClass]` / `[TestMethod]` tests with `[TestCategory("Mutation")]`.
- Run Stryker separately from ordinary `dotnet test`; Stryker mutates the configured target project and reruns the filtered MSTest suite.
- Configure `stryker-config.json` with `test-case-filter: TestCategory=Mutation` and a narrow `mutate` list. Do not point Stryker at the whole solution by default.
- Target boundaries, comparisons, boolean branches, collection behavior, state transitions, and exact failure messages. Weak assertions let equivalent, conditional, string, and collection mutants survive.
- Keep `StrykerOutput/` under the mutation test project and add `**/StrykerOutput/` to `.gitignore`.

## Deterministic Test Output Location

- Optional hardening - `.gitignore` already keeps `TestResults/` out of commits; this only buys a deterministic location (useful for CI artifact collection or when `dotnet test` runs from varying directories). Skip it if a single test props/targets file does not already exist.
- To pin test results, in the test-scoped `Directory.Build.props`/`.targets` under `tests/` (when one is present), inside the `IsTestProject` PropertyGroup set `<VSTestResultsDirectory>$(MSBuildThisFileDirectory)TestResults</VSTestResultsDirectory>`.
- `$(MSBuildThisFileDirectory)` resolves to the targets file's own absolute directory, so every test project writes to the same `tests/TestResults` regardless of the directory `dotnet test` runs from. `VSTestResultsDirectory` is the property the VSTest MSBuild task maps to `--results-directory`.
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
- Never ship a hard-coded URL fallback or `[Ignore]`d tests pointed at a guessed URL. An explicit Playwright opt-out or failed Docker preflight is inconclusive; after Docker succeeds, unresolved named endpoints and AppHost/browser startup failures are red with shared-host diagnostics.
- Standalone Vite can use a conventional dev port, but hosted-stack Playwright must use the actual Aspire resource URL.

### Baseline Rules

- Use Page Object Model. **Language split:** author page objects in **C# only for stable, strongly-typed smoke paths that benefit from typed orchestration** - the Gateway/Blazor happy path is the canonical case. Keep React and Uno page/test helpers in **TypeScript** unless a concrete maintenance reason (e.g. an MSTest runner that must own the flow) justifies a C# wrapper. Do not port a working TypeScript suite to C# for uniformity's sake; the renderer-specific helpers (canvas bridge, coordinate-click) live more naturally in TS.
- Prefer stable selectors (`data-testid`).
- Every selector a post-deploy smoke test asserts must be pinned by a fast-lane component test (bUnit for Blazor) whose failure message names the smoke spec. A deploy-gated suite is the slowest possible place to discover a renamed selector: a refactor that drops the anchor passes CI green and only fails after the next deploy, and stays red until someone correlates the two.
- Settings-style DTOs (client writes, server validates, client re-reads) get one round-trip test: client-serialize -> server-validate -> client-parse. Route paths, validation limits, and enum wire-strings drift independently across client, server validator, and test mocks, and a catch-all route fallback makes the drift silent - four "settings don't save" incidents in one consumer week traced to exactly these.
- API smoke scripts that re-run against standing data classify expected business-rule rejections (cooldowns, daily limits) as WARN by exact message; anything unexpected still FAILs. In PowerShell, `Invoke-WebRequest` returns `application/problem+json` error bodies as raw `byte[]` - decode before matching, or message assertions silently never match and the gate goes false-green.
- Isolate test data with unique names/ids and delete or archive every smoke-created record in `finally` / fixture teardown. Cleanup failure is diagnostic evidence and must not mutate unrelated provider data.
- Assert structural UI strings, not data-dependent counts.
- Cover the real workflow surface: shell/navigation, create/read/update/delete, and nested child collections when DOM-capable UI exposes them. For Uno Skia canvas, use smoke plus app-owned bridge state transitions only; do not claim CRUD or nested-child correctness from pixels alone.

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

Set one `{APP}_WASM_STARTUP_TIMEOUT_SECONDS` wall-clock budget before test-owned restore. Restore, build, AppHost create/build/start, named resource health, endpoint resolution, Gateway warm-up, and browser launch all consume its remaining time. Per-operation caps may fail a step sooner but must never reset the global deadline. Default at least 1800 s for a cold first build; choose a lower verified budget when the generated app is lighter.

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
- **Run one TypeScript project per child process.** Invoke `node .../cli.js test --project <name>` for each generated project; do not launch one giant Playwright run that can burn the whole MSTest budget.
- **Use explicit timeout env vars.** Read per-project timeout from `{APP}_PLAYWRIGHT_PROJECT_TIMEOUT_SECONDS` and per-test/action timeout from `{APP}_PLAYWRIGHT_TEST_TIMEOUT_SECONDS`; defaults must fit inside the MSTest `[Timeout]` budget.
- **Invoke `node` against the local CLI, not `npx`.** Resolve `node_modules/@playwright/test/cli.js` relative to the project directory and start `node.exe`/`node` with it via `ProcessStartInfo.ArgumentList`. `npx` can resolve through a broken local npm shim and silently run the wrong binary; a missing `node` on PATH should surface as a clear `Node.js is not available on PATH` error, not a generic Win32 failure.
- **Fail fast with captured output.** On non-zero exit or timeout, fail the current MSTest immediately and include command, exit code, stdout, stderr, timeout value, and project name.
- **Capture stdout and stderr even on cancellation.** Start the async reads (`ReadToEndAsync`) before awaiting exit, and return both streams in the result on the cancellation path too - a Playwright failure that arrives as the test host cancels must still reach the TRX, not disappear.
- **Kill the entire process tree.** On `OperationCanceledException`, call `process.Kill(entireProcessTree: true)` (swallow `InvalidOperationException` if it already exited), then `await WaitForExitAsync(CancellationToken.None)` so orphaned browser/node children do not leak and hold locks.
- **Gate on the CLI being installed.** Check the explicit false opt-out before startup. Once the lane is selected, expose an `IsInstalled` check (`File.Exists(cliPath)`) and fail red with the install step when the suite has not been provisioned.
- **Do not use `--reporter=line` in captured child-process runs.** Its carriage-return progress output can hide the real failure in TRX/stdout capture. Use the default reporter, `list`, or `dot`.
- **Use latest stable `@playwright/test`** for generated Node suites. Older versions can add Node 26 `DEP0205 module.register()` deprecation noise to already-noisy browser output.
- **Build the wrapper project as a gate.** Namespace mismatches between wrapper tests and `TypeScriptPlaywrightRunner.cs` are scaffold defects. `dotnet build` or `dotnet test tests/Test.PlaywrightUI/Test.PlaywrightUI.csproj -m:1` must catch them before handoff.
- **Register the C# wrapper in the `.slnx`.** A `Test.PlaywrightUI` project with a .NET wrapper must be in the solution file or `dotnet test` over the solution silently skips it - the suite passes by being invisible. The TypeScript-only projects (React/Uno) are still run by their own Playwright config; only the .NET wrapper needs `.slnx` registration.

### Browser synchronization and lookup contract

- Do not click after only `DOMContentLoaded`, a splash disappearance, or a guessed delay. Wait for an explicit app-interactive marker owned by the UI, then begin actions.
- Detect the renderer before choosing selectors. Prefer roles, labels, test IDs, and other semantic DOM locators whenever real elements exist.
- Scope popover/menu locators to the currently visible/open container. Global selectors can hit stale, hidden overlays retained by the component framework.
- After a mutation, wait for a visible server-acknowledged state such as the returned ID, exact normalized row cell, success state, or refreshed detail. Do not start the next action on click completion alone.
- Locate created rows by returned ID or exact normalized cell text, never substring containment. Shared data can make a substring select the wrong row.
- Browser policy behavior that headless automation does not reproduce, including popup blocking and user-gesture rules, retains an explicit real-browser/manual acceptance check.

### Uno WASM: DOM/Click Strategy (managed-DOM renderer)

Uno WASM with the **managed-DOM renderer** uses semantic locators first. Coordinate clicking is a renderer-specific fallback only after a visible DOM element is proven but normal Playwright click dispatch does not reach the Uno event handler.

- Prefer roles, labels, test IDs, then Uno attributes such as `xamltype` or `xamlautomationid`.
- Compute center with `getBoundingClientRect()`.
- Use `page.mouse.click(x, y)` (or down/up) only as the bounded fallback.
- Match exact normalized target text or a returned ID. A known prefix is useful for isolation but is not an exact row selector.

```typescript
const expectedExactText = "E2E-created-row";
let clicked = false;
for (let attempt = 0; attempt < 20; attempt++) {
  const coords = await page.evaluate((expected) => {
    for (const p of Array.from(document.querySelectorAll("p"))) {
      const txt = (p.textContent ?? "").trim();
      if (txt !== expected) continue;
      const r = p.getBoundingClientRect();
      if (r.width > 0 && r.height > 0 && r.y > 0 && r.x > 0)
        return { x: r.x + r.width / 2, y: r.y + r.height / 2 };
    }
    return null;
  }, expectedExactText);
  if (coords) { await page.mouse.click(coords.x, coords.y); clicked = true; break; }
  await page.waitForTimeout(500);
}
if (!clicked) throw new Error(`Visible exact row not found: ${expectedExactText}`);
```

### Uno WASM: Canvas Test Bridge (Skia renderer)

If the app paints to a single Skia `<canvas>`, there are no per-control DOM nodes - DOM/text/role selectors and coordinate-clicking all fail structurally. Hard rule: a Skia-canvas Uno WASM test that uses `getByText`, role selectors, labels, or DOM text assertions is wrong. The browser DOM cannot expose text painted inside the canvas. Scaffold a browser-only test bridge that publishes app state to `globalThis.__{app}TestState` (query-string gated, default-off, real Gateway local auth) and have Playwright wait on state. The bridge state must include enough app-neutral fields for assertions: `page`, `section`, `hasToken`, `onboardingComplete`, `status`, and `error`. Tag these `[TestCategory("WasmUI")]`. Full pattern: [../templates/uno-wasm-test-bridge-template.md](../templates/uno-wasm-test-bridge-template.md). Detect the renderer with `document.querySelectorAll('[xamltype]').length` - `0` plus a lone `<canvas>` means Skia. Assert a rendered canvas larger than 100x100; never assert user-facing text with `getByText` against a Skia-canvas Uno app.

Canvas-only fingerprint or visual-delta tests are valid only as `WasmUI` smoke and must be named as smoke, not CRUD/workflow coverage.

The bridge cannot see whether anything was actually drawn: a brand mark with an unresolvable image source renders blank while `page`, `section`, and `hasToken` all report correct - every tier passes and a human finds the hole in production. For image-bearing chrome (logo, wordmark, splash mark), add one cheap non-visual guard an existing tier can carry: assert the control's asset request returns `200` (Playwright `page.on('response')` filtered to the asset path; **no request at all** is the failure signature, since an unresolved source never fetches). Deterministic, no golden image; keep visual-delta as smoke-only layout coverage.

Recommended Uno WASM generation rule:

- Detect renderer first.
- If Skia canvas: generate bridge-backed functional tests plus canvas smoke. If bridge state does not exist yet, generate only smoke-named canvas checks.
- If managed DOM: coordinate-click and XAML attribute selectors acceptable.
- Never generate DOM text selectors until renderer proves text exists in DOM.
- C# wrapper starts AppHost and runs TypeScript; no browser-clicking C# page objects for Uno.

Canvas-first fallback hierarchy:

1. Prefer app-owned bridge state for functional assertions (`window.__AppTestState` / `globalThis.__{app}TestState`): page, section, auth/session, onboarding, status, error, and any app-specific state transition under test.
2. If bridge does not exist yet, limit test to canvas paint, stable chrome click, and fingerprint/pixel delta from blank; name specs/classes as smoke.
3. Do not claim CRUD correctness, nested-child correctness, or persisted workflow correctness from pixel-only tests.

TypeScript Uno tests that try list CRUD by text/role selectors are structurally invalid for Skia canvas, even when they sometimes pass in another renderer.

When the WASM app needs API, Gateway, SQL, Redis, storage, auth, or other Aspire resources, the `WasmUI` harness must start the AppHost graph. Do not treat it as a standalone browser-only suite, and do not require an external `{APP}_WASM_BASE_URL` for the default path. The harness starts Aspire in testing mode with `DistributedApplicationTestingBuilder.CreateAsync<Projects.{App}_AppHost>()`, disables only optional hosts, waits for required resources to become healthy, warms up auth through the real Gateway, and resolves UI/Gateway URLs from named Aspire endpoints. Use `CreateHttpClient(resource, "http")` for endpoint discovery and probes; never assume fixed local ports during a test run.

Build the WASM assets before browser navigation with `TargetFrameworkOverride=<tfm>-browserwasm` and `EnableUnoWasm=true`, then pass the dynamic Gateway endpoint to the browser through a test-only query parameter such as `{app}TestGatewayBaseUrl`. Without that override, a scaffolded app can accidentally call a fixed dev gateway port while Aspire assigned a dynamic port.

Start one monotonic `{APP}_WASM_STARTUP_TIMEOUT_SECONDS` deadline before Docker preflight or test-owned restore. Docker preflight, host lock, WASM restore/build, AppHost create/build/start, named health waits, Gateway warm-up, UI readiness, and browser launch consume the same remaining budget. Step caps may fail sooner but never reset or extend the deadline. Missing Docker marks `Assert.Inconclusive` with the exact fix; after preflight, tooling and startup failures are red with diagnostics.

Generated `WasmUI` assemblies must include `[assembly: DoNotParallelize]`. AppHost-backed browser classes fight over containers, ports, WASM output, and cold-start state when MSTest runs them in parallel.

The shared AppHost-backed `WasmAppHost` builds the WASM head and starts Aspire once per assembly. Its lazy single-start guard must use static fixture state, for example `_app != null && _staticBaseUrl != null`, then copy `_staticBaseUrl` into each test's fresh `WasmTestSettings`. Never guard on the per-test `settings.BaseUrl`; each test gets a new settings instance and would re-enter the clean rebuild while the first `*.WasmHost.exe` still holds the staged output. Reset the static URL during assembly cleanup. The guard must cache the boot **failure** too: a failed boot that clears the cached state makes every remaining test re-boot the full graph (observed: 22 tests x a doomed Aspire boot = hours to report nothing) - record the failure and fail the rest fast with the original diagnostics. Fixtures resolve the repo/source root by walking up to the `*.slnx`/`*.sln` marker, never by a fixed number of parent segments - any relocation of the test tree kills every hard-coded climb. Symptom of the broken guard: the second `WasmUI` test fails with `MSB3027` / `MSB3021` copying a locked `*.WasmHost.exe`; after the fix, later tests skip rebuild and start in seconds.

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
- Server/resource notices and host diagnostics for the affected resource.
- Full DOM snapshot and screenshot.
- The resolved artifact directory and a check that every expected artifact file exists there before upload.

Install the `window.onerror` / `unhandledrejection` capture with `AddInitScriptAsync` before navigating so early Mono/WASM failures are retained.

CI uploads failure diagnostics with `if: failure() || cancelled()` and `if-no-files-found: error`. Successful benchmark, mutation, or other evidence artifacts still upload on success. The producer and uploader must use the same resolved path; an upload step pointing at a different repo-relative `TestResults` folder is a harness failure.

### Uno WASM: Published Release Cold-Start Proof

At least one preview/deployment smoke uses the published `Release` Skia browser-WASM output and a fresh browser profile/context with cache, service workers, local storage, and other site data empty. Install console/page-error capture before the first navigation, then require the splash to clear and the first canvas/bridge-ready state to appear without a fatal startup exception.

If the first load reports `BrowserRenderer.requestRender` / `NullReferenceException` but refresh succeeds, keep the cold-start smoke red and follow [ui-uno-platforms.md](ui-uno-platforms.md) section Skia Browser-WASM Cold-Start Renderer Race. Warm-storage or refresh-only proof cannot substitute for first-visit acceptance.

### Uno WASM: Slow Router After Many Navigations

Increase late-lifecycle assertions to `60000` when page loads occur after several navigations in same shared page.

### Uno Mobile: Test Split

- Use Playwright mobile viewports against Uno WASM for fast responsive checks on Windows.
- Use Android emulator UI smoke tests only for native startup, native surface, first-viewport accessibility, and one reliable text-entry smoke. Do not drive deep CRUD, search persistence, child collections, or long-scroll Skia forms with Appium/UiAutomator2; cover those in API, integration, unit, and Playwright lanes.
- When the repo uses MSTest, scaffold mobile native smoke tests as MSTest + Appium (`Test.Mobile`) instead of introducing NUnit. Keep default `dotnet test` dependency-free: unset `{APP}_MOBILE_TESTS_ENABLED` makes methods `Assert.Inconclusive` without starting Appium, emulator, or building APKs.
- Generate `tests/Test.Mobile/run-mobile-tests.ps1`. The runner owns Android restore/build with `-p:BuildAllUnoTargets=true`, emulator readiness, Appium readiness, `{APP}_MOBILE_TESTS_ENABLED=true`, `dotnet test`, and TRX output. Explicit enabled mobile runs fail fast red if APK, emulator/device, Appium, or UiAutomator2 is missing/broken.
- Test methods must not start Appium, start an Android Emulator, or build APKs. They connect to the prepared device/server, use method-level `[Timeout]`, and capture a screenshot on failure.
- Use `MobileBy.AccessibilityId` for exact `AutomationProperties.Name` lookups. Avoid broad XPath except fallback probing after diagnostics show no accessibility id is exposed.
- In runner setup, verify `appium`, `uiautomator2`, `adb`, `emulator`, `ANDROID_HOME`, and `JAVA_HOME` with `appium driver doctor uiautomator2` before blaming app code.
- Treat iOS simulator/device UI tests as macOS-only. On Windows, record iOS compile status and mark simulator/device execution as blocked unless a Mac host or macOS CI runner is available.

**Mobile oracle and assertions (Uno/Skia).** Skia renders to a canvas, so the accessibility tree is thin and unreliable.

- Screenshot is the primary no-crash oracle. Appium page source and element taps are best-effort only unless the app exposes explicit accessibility hooks.
- Do not assert against the mobile accessibility tree for Skia-rendered controls. Capture a screenshot, assert the artifact is non-empty, and log missing accessibility text as context, not a failure.
- Set UiAutomator2 `settings[waitForIdleTimeout]=0` for animated/canvas apps so idle-wait never blocks on continuous redraw. Set `settings[enforceXPath1]=true` only if XPath snapshots hang.
- Use the resolved Android activity for `appActivity` and `appWaitActivity`. Avoid broad `*` waits unless genuinely needed.

**Mobile failure handling.** Keep app/environment failures distinct from test failures.

- Session-creation failure -> fix runner/driver setup. Page-source hang -> fix Appium settings or test strategy (see UiAutomator2 settings above). Empty screenshot -> real test failure.
- Allow one scoped retry only for the known transient Android launch failure (exact `Cannot start` plus `never started`): force-stop the app, recreate the session, retry once. No broad retries.
- Debug loop for a red mobile lane: read TRX -> read Appium log -> isolate one failing test -> patch root cause -> rerun that one test -> rerun full mobile -> rerun full non-load suite.

### MudBlazor Timing Rules

- Before fill/click on a field after navigation, wait for visibility first.
- Confirmation dialogs may need `15000` timeout.

```typescript
await field.first().waitFor({ state: "visible" });
await expect(dialog).toBeVisible({ timeout: 15_000 });
```

### Interactive IdP Login Helpers (hosted-provider sign-in)

Any generated helper that drives a hosted IdP's real login pages (Entra, B2C, Auth0) hits the same trap: after a good password the IdP self-submits a `form_post` back to the app, the credential view disappears immediately, but `page.url()` keeps reporting the IdP URL until the navigation commits. A helper that samples `page.url()` to ask "am I still on the IdP?" gets a stale answer during the redirect window and runs its next step against a page that is already the application.

- Wait for the URL to actually leave the IdP with `waitForURL` (it follows in-flight navigations); never poll `page.url()`.
- Fresh users hit first-run interstitials (consent, "stay signed in?") after the password step. Loop the primary action button through interstitials **until the URL leaves the IdP host**, not a fixed screen sequence.
- Locate IdP fields by role + accessible name, not `input[type=email]`/`[type=password]`: hosted login pages keep hidden inputs from other views in the DOM, so type selectors match nothing or a hidden element.
- Scope broad fallback actions (`button[type="submit"]`, blind Enter) to the IdP's own origin. On the provider's form they are safe; one navigation later the only submit button may be the app's sign-out form, and the helper signs the test out then waits on a page it just discarded. The failure is intermittent - it reproduces only when the redirect is slow - and masquerades as a cold-start hang.

### Playwright Config Output Location

Set `outputDir` under `tests/Test.PlaywrightUI`, not under app project directories.

## Visual Studio & VS Code Test Explorer

All test projects must be registered in the `.slnx` so both Test Explorers discover them. Generate a short test README (or top-of-class comments) stating the local workflow. **Only include the env vars, tasks, and stack steps for tiers this scaffold actually generated** - an `api-only` / no-UI scaffold has no Aspire/WASM/Mobile rows, so do not document their env vars or tasks (see [Capability-Gated Test Tiers](testing.md#capability-gated-test-tiers-the-early-decision-drives-the-rest)).

- **Document proof commands and pass rules.** README/test README must list exact commands for generated tiers and expected pass conditions, including which prerequisites yield `Assert.Inconclusive` and which status/provider mismatches are failures. Put durable rationale in `docs/tech-design.md`; keep README operational.

- **Start the stack once per session.** When the scaffold has Aspire/WASM tiers, run `eng/test/start-local-test-stack.ps1` ([../templates/local-test-stack-template.md](../templates/local-test-stack-template.md)) before those tests. For mobile, run `tests/Test.Mobile/run-mobile-tests.ps1`; it owns Android build, emulator/Appium readiness, enable flag, `dotnet test`, and TRX output.
- **Filter by category in Test Explorer:** among the tiers present, plus exclude `Load`. The canonical local run is `dotnet test --filter "TestCategory!=Load"`.
- **Opt out with false-only env vars** for the default-on heavy tiers when you do not want one locally - only the vars for present tiers exist: `{APP}_RUN_ASPIRE_TESTS=false` (if Aspire), `{APP}_WASM_TESTS_ENABLED=false` (if Uno WASM). Default (unset) runs required infrastructure; only failed Docker preflight self-marks `Inconclusive`. Missing selected-lane tooling and post-preflight failures are red. Optional LiveAI uses [ai-integration.md](ai-integration.md) section Optional Live-Provider Classification. **`Test.Mobile` is the exception: opt-IN.** It defaults off (emulator/Appium/APK are too heavy for the canonical lane) - unset/false self-marks `Assert.Inconclusive` per test. The generated mobile runner sets `{APP}_MOBILE_TESTS_ENABLED=true`; after that, broken mobile prerequisites are red.
- **Generate `.vscode/tasks.json`** with tasks for the present tiers only (start stack, build WASM, install Playwright Chromium, build Android APK, run all non-load, run Aspire/WASM/Mobile). Task definitions are in the [local test stack template](../templates/local-test-stack-template.md).

## Verification Checklist

- [ ] Mesh tests obey the one-AppHost-graph rule ([testing.md](testing.md#heavy-aspire-mesh-graph-rule)): opt-in branches use cheap topology guards, live-provider coverage lives in lighter dedicated lanes - no duplicate infrastructure graphs.

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
- [ ] Published Release Uno WASM cold-start smoke begins with empty browser site data and reaches first render without `BrowserRenderer.requestRender` startup failure.
- [ ] Selector strategy is stable for the target UI tech.
- [ ] UI assertions are structural, not seed/count-dependent.
- [ ] Uno WASM uses one startup budget, default at least 1800 s for cold restore/build plus AppHost and browser launch; step caps never extend it.
- [ ] Test output folder is inside the test project.
