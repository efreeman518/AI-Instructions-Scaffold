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

## Mutation Testing Rules

- Generate `Test.Mutation` for the comprehensive profile or when explicitly requested for high-value domain/service logic.
- Keep mutation tests as normal MSTest `[TestClass]` / `[TestMethod]` tests with `[TestCategory("Mutation")]`.
- Run Stryker separately from ordinary `dotnet test`; Stryker mutates the configured target project and reruns the filtered MSTest suite.
- Configure `stryker-config.json` with `test-case-filter: TestCategory=Mutation` and a narrow `mutate` list. Do not point Stryker at the whole solution by default.
- Target boundaries, comparisons, boolean branches, collection behavior, state transitions, and exact failure messages. Weak assertions let equivalent, conditional, string, and collection mutants survive.
- Keep `StrykerOutput/` under the mutation test project and add `**/StrykerOutput/` to `.gitignore`.

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

---

## Hosted Browser UI (Test.PlaywrightUI)

### Harness Contract

Playwright requires a real hosted stack. It cannot run on `WebApplicationFactory`. Run against Aspire AppHost locally, a docker-compose stack, or a preview deployment.

### Base URL Rules

- Configure one base URL per UI surface/project. Do not share a hard-coded URL across Blazor, Uno, and React.
- Make the base URL environment-driven (`{APP}_BLAZOR_BASE_URL`, `{APP}_UNO_BASE_URL`, `{APP}_REACT_BASE_URL`, or equivalent).
- When running through Aspire, read the UI resource URL from the current dashboard/console output. Vite/React resources may use a dynamic port; do not assume `5173`, `5178`, or a prior run's URL.
- Standalone Vite can use a conventional dev port, but hosted-stack Playwright must use the actual Aspire resource URL.

### Baseline Rules

- Use Page Object Model.
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
    context = await browser.newContext({ ignoreHTTPSErrors: true });
    sharedPage = await context.newPage();
    await sharedPage.goto("https://localhost:7069");
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

### Uno WASM: DOM/Click Strategy (managed-DOM renderer)

Uno WASM with the **managed-DOM renderer** often needs coordinate-click interaction.

- Query Uno elements by attributes like `xamltype` or `xamlautomationid`.
- Compute center with `getBoundingClientRect()`.
- Use `page.mouse.click(x, y)` (or down/up) with retry loop.
- Filter target text with known prefix (for example `E2E-`) to avoid collisions.

### Uno WASM: Canvas Test Bridge (Skia renderer)

If the app paints to a single Skia `<canvas>`, there are no per-control DOM nodes - DOM/text/role selectors and coordinate-clicking all fail structurally. Scaffold a browser-only test bridge that publishes app state to `globalThis.__{app}TestState` (query-string gated, default-off, real Gateway local auth) and have Playwright wait on state. Tag these `[TestCategory("WasmUI")]`. Full pattern: [../templates/uno-wasm-test-bridge-template.md](../templates/uno-wasm-test-bridge-template.md). Detect the renderer with `document.querySelectorAll('[xamltype]').length` - `0` plus a lone `<canvas>` means Skia.

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
- **Opt out with false-only env vars** when you do not want a *generated* heavy tier locally - only the vars for present tiers exist: `{APP}_RUN_ASPIRE_TESTS=false` (if Aspire), `{APP}_WASM_TESTS_ENABLED=false` (if Uno WASM), `{APP}_MOBILE_TESTS_ENABLED=false` (if Uno mobile). Default (unset) runs the tier; it self-marks `Inconclusive` if its prerequisite is missing (see [Capability-Gated Test Tiers](testing.md#capability-gated-test-tiers-the-early-decision-drives-the-rest)).
- **Generate `.vscode/tasks.json`** with tasks for the present tiers only (start stack, build WASM, install Playwright Chromium, build Android APK, run all non-load, run Aspire/WASM/Mobile). Task definitions are in the [local test stack template](../templates/local-test-stack-template.md).

## Verification Checklist

- [ ] Architecture tests enforce layering rules.
- [ ] Load scenarios track p50/p95/p99 and error rate against an explicit baseline.
- [ ] Benchmark suites use representative datasets; results compared to a baseline, not measured in isolation.
- [ ] Mutation suite uses normal MSTest classes, `TestCategory=Mutation`, focused Stryker mutate globs, and ignored `StrykerOutput/`.
- [ ] Hosted Playwright stack is reachable and base URL is correct.
- [ ] Aspire-hosted UI tests use the current resource URL, not a stale dashboard URL or default Vite port.
- [ ] Selector strategy is stable for the target UI tech.
- [ ] UI assertions are structural, not seed/count-dependent.
- [ ] Timeout profile matches UI runtime behavior (Uno WASM cold-start: 120s).
- [ ] Test output folder is inside the test project.
