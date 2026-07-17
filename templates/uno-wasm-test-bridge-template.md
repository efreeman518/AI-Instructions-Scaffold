# Test Template - Uno WASM Canvas Test Bridge (Phase 5c/5d, Skia-canvas only)

| | |
|---|---|
| **Generates** | `src/UI/{Project}.Uno/Testing/{Project}TestBridge.cs`, `tests/Test.PlaywrightUI/Uno/WasmAppHost.cs`, `WasmTestHarness.cs`, `WasmTestSettings.cs`, `AssemblyInfo.cs`, `tests/Test.PlaywrightUI/Uno/{Entity}CanvasTests.cs` (or `.ts` for Node Playwright) |
| **Requires** | An Uno WASM target that renders through the **Skia canvas** renderer (single `<canvas>`, no per-control DOM), a Gateway for real local auth, an Aspire AppHost when the app needs API/resources, [testing-quality.md](../skills/testing-quality.md) (Hosted Browser UI) |
| **Phase** | Bridge added with the Uno host (5c); canvas tests authored in 5d |
| **Protocol** | Tests-after. The bridge is a browser-only diagnostic surface, never a production code path. |

---

## When you need this

Uno renders WASM two ways:

- **Managed/native DOM renderer** - each control maps to a DOM element carrying `xamltype` / `xamlautomationid`. The coordinate-click + `querySelectorAll` strategy in [../skills/ui-uno-platforms.md](../skills/ui-uno-platforms.md) (Playwright Testing Against Uno WASM) works here.
- **Skia canvas renderer** - the whole app paints into one `<canvas>`. There are **no per-control DOM nodes**. `querySelectorAll("p")`, `getBoundingClientRect()` on text, and DOM/role selectors all return nothing. Coordinate-clicking by scanning DOM text is impossible.

Skia tests must not use `getByText`, role selectors, labels, or body text for app text. Functional assertions must prefer app-owned bridge state such as `window.__AppTestState` / `globalThis.__{app}TestState`. If the bridge does not exist yet, limit proof to canvas paint: visible size, nonblank fingerprint/pixel hash, stable chrome click, and fingerprint delta. Pixel-only tests are smoke only; name specs/classes as smoke and do not claim CRUD, nested children, or persistence correctness. Full CRUD stays in DOM-capable UIs unless Uno exposes reliable bridge state for every asserted transition.

If the app paints to a Skia canvas, DOM selectors are not "flaky" - they are structurally absent. Use the bridge below: the app publishes its own state to `globalThis`, and Playwright waits on **state**, not DOM.

Hard rule: a Skia-canvas Uno WASM test that uses `getByText`, role selectors, labels, or DOM text assertions is wrong. The browser DOM cannot expose text painted inside the canvas.

Detect the renderer once: open the WASM app, run `document.querySelectorAll('[xamltype]').length` in the console. `0` with a single `<canvas>` present means Skia - use the bridge. Also assert at least one rendered canvas larger than 100x100; that proves the app painted something even though text is not in the DOM.

Name pixel-only specs/classes as smoke. They must not use CRUD, regression, workflow, or persistence wording unless bridge state proves each asserted transition.

## Bridge contract

The bridge exposes a single global the test harness polls:

```js
globalThis.__{app}TestState = {
  testMode: true,            // echoes the requested test mode
  page: "HomePage",          // current page/route name
  section: "home",           // selected section/tab
  hasToken: true,             // token/session present after test auth
  onboardingComplete: true,   // normalized boolean for common assertions
  status: "ready",            // "starting" | "authenticating" | "ready" | "error"
  error: null,                // { type, message } only when startup fails
  auth: "authenticated",     // "anonymous" | "authenticating" | "authenticated"
  onboarding: "complete",    // "fresh" | "in-progress" | "complete"
  adsVisible: false,         // any flag the test asserts on
  ready: true                // app finished first render + state hydration
};
```

Activation is **query-string gated** and **default-off**. Nothing is published unless the app is launched with the test-mode flag:

```text
?{app}TestMode=true
&{app}TestAuth=true
&{app}TestReset=true
&{app}TestEmail=wasm-test@local.test
&{app}TestOnboarding=complete
&{app}TestSection=home
&{app}TestGatewayBaseUrl={url-encoded-aspire-gateway-url}
```

Rules:

1. **Browser/WASM target only.** Guard the whole file with the WASM compilation symbol so it never ships in Android/iOS/desktop builds.
2. **Default-off.** Publish nothing unless `{app}TestMode=true` is present in the query string (or an equivalent test-only app setting). No flag -> the global is never defined -> production behaviour is untouched.
3. **Real local auth.** When `{app}TestAuth=true`, drive the **real** local auth flow through the Gateway with the supplied email. Do not inject a fake token - that bypasses the wiring the test exists to prove.
4. **Onboarding states.** Support at least `complete` and `fresh` so a test can exercise both the returning-user and first-run shells.
5. **Gateway URL override.** `{app}TestGatewayBaseUrl` is required for Aspire-backed tests. Without it, the app can fall back to a hard-coded dev port while Aspire assigned a dynamic gateway port.
6. **Reset support.** `{app}TestReset=true` clears test-local persisted auth/onboarding state before boot so reruns do not inherit an old browser session.
7. **Publish on every state transition.** Re-publish `__{app}TestState` after navigation, auth change, and onboarding change so the harness can await the next state without a full reboot.
8. **Startup error shape.** In the WASM startup path, publish exception type and message only. Avoid `Exception.ToString()` there; Mono can double fault while formatting stack traces after runtime/class-library mismatches.
9. **Local-auth scope only.** This bridge proves the configured local Gateway auth path. It does not execute MSAL interactive browser behavior, the COOP-proof `localStorage` callback channel, the browser HTTP factory, or a WASM `ICustomWebUi`; require one real interactive sign-in per enabled head from the published `Release` build before live-provider deployment.

## Bridge (representative shape)

### File: `src/UI/{Project}.Uno/Testing/{Project}TestBridge.cs`

> **Single-project caveat.** Do not use a `.wasm.cs` suffix for this file. Under `UnoSingleProject=true` the `.wasm.cs` platform-suffix convention is **not** auto-included in compilation, so the bridge type silently goes missing from the WASM build. Use a plain `{Project}TestBridge.cs` and gate the contents with `#if __WASM__` (as below) - the guard, not the filename, is what keeps the bridge out of Android/iOS/desktop builds.

```csharp
#if __WASM__
using System.Text.Json;
using Uno.Foundation; // WebAssemblyRuntime.InvokeJS

namespace {Project}.Uno.Testing;

/// <summary>
/// Browser-only test bridge for Skia-canvas WASM. Publishes app state to
/// globalThis.__{app}TestState so Playwright can wait on state instead of DOM
/// (the Skia renderer paints into one canvas - there are no per-control DOM nodes).
/// Default-off: nothing is published unless the app is launched with ?{app}TestMode=true.
/// Never compiled into Android/iOS/desktop builds (#if __WASM__).
/// </summary>
internal static class {Project}TestBridge
{
    private static bool _enabled;

    /// <summary>Call once at app startup, before the shell renders.</summary>
    public static void Initialize()
    {
        var query = WebAssemblyRuntime.InvokeJS("globalThis.location.search");
        var args = System.Web.HttpUtility.ParseQueryString(query);
        _enabled = string.Equals(args["{app}TestMode"], "true", StringComparison.OrdinalIgnoreCase);
        if (!_enabled) return; // production: bridge is inert

        // Honour onboarding / section / auth requests from the query string.
        TestOnboarding = args["{app}TestOnboarding"] ?? "complete";
        TestSection = args["{app}TestSection"] ?? "home";
        TestEmail = args["{app}TestEmail"];
        TestGatewayBaseUrl = args["{app}TestGatewayBaseUrl"];
        WantsReset = string.Equals(args["{app}TestReset"], "true", StringComparison.OrdinalIgnoreCase);
        WantsAuth = string.Equals(args["{app}TestAuth"], "true", StringComparison.OrdinalIgnoreCase);
    }

    public static string TestOnboarding { get; private set; } = "complete";
    public static string TestSection { get; private set; } = "home";
    public static string? TestEmail { get; private set; }
    public static string? TestGatewayBaseUrl { get; private set; }
    public static bool WantsReset { get; private set; }
    public static bool WantsAuth { get; private set; }

    /// <summary>Re-publish the snapshot after any page / auth / onboarding transition.</summary>
    public static void Publish(
        string page,
        string section,
        string auth,
        string onboarding,
        bool adsVisible,
        bool ready,
        string status,
        string? error = null)
    {
        if (!_enabled) return;

        var snapshot = JsonSerializer.Serialize(new
        {
            testMode = true,
            page,
            section,
            hasToken = auth == "authenticated",
            onboardingComplete = onboarding == "complete",
            status,
            error,
            auth,
            onboarding,
            adsVisible,
            ready
        });
        WebAssemblyRuntime.InvokeJS($"globalThis.__{app}TestState = {snapshot};");
    }
}
#endif
```

Wire `Initialize()` into the WASM startup path (before the shell renders) and call `Publish(...)` from the shell/navigation/auth view-models whenever the observed state changes. When local auth is requested (`WantsAuth`), trigger the same Gateway-backed sign-in the user would, with `TestEmail`.

> **MVUX state caveat (WASM).** Do not expose test-observed collections through MVUX state casts that work on desktop but throw under the WASM trimmer/runtime. Read from a browser-safe immutable surface (a plain snapshot or `IImmutableList`) when building the `Publish(...)` payload.

## WasmUI harness contract

When the app needs API, Gateway, SQL, Redis, storage, or auth, generate an AppHost-backed `WasmUI` harness. It must run by default in Test Explorer and only opt out when `{APP}_WASM_TESTS_ENABLED=false`.

Required fixture behavior:

- Use the shared `AspireTestHostContext` from [test-templates-aspire.md](test-templates-aspire.md). Its Docker preflight drains stdout and stderr concurrently. Explicit `{APP}_WASM_TESTS_ENABLED=false` or missing Docker is inconclusive; Docker success makes later toolchain/AppHost/resource/browser failures red with diagnostics.
- Clean both `bin/<configuration>/<tfm>-browserwasm` and `obj/<configuration>/<tfm>-browserwasm` before a test-owned rebuild.
- Restore with `BuildAllUnoTargets=true` and `EnableUnoWasm=true`.
- Build one target at a time with `TargetFrameworkOverride=<tfm>-browserwasm`, `EnableUnoWasm=true`, `--no-restore`, and `-m:1`. Do not use `-f`.
- Clear coverage/profiler environment variables for child `dotnet` commands; set profiling disabled flags and `MSBUILDDISABLENODEREUSE=1`.
- Write a test-owned stamp file after a successful clean rebuild. Freshness checks require that stamp so old developer builds are not silently accepted.
- Start the Aspire AppHost in testing mode. Keep required backing resources live. Disable only optional hosts such as scheduler, admin, external mappers, notifications, or other non-test-critical processes.
- Start the Aspire AppHost and rebuild the WASM head once per test assembly. Cache both the running app and the resolved base URL in static fields. On later tests, copy the static base URL into the fresh `WasmTestSettings` and reuse the running graph.
- Guard the lazy single-start on static fixture state (`_app != null && _staticBaseUrl != null`), not on the per-test `settings.BaseUrl`. A per-test settings guard re-enters the clean rebuild on the second test while the first `*.WasmHost.exe` still holds output files, causing `MSB3027` / `MSB3021` lock failures.
- Wait for required resources to become healthy before using them.
- Resolve Gateway and UI base URLs through named Aspire endpoints. Use `CreateHttpClient(resource, "http")`; do not assume fixed local ports.
- Warm up real Gateway auth before browser navigation by posting to the local login endpoint, for example `POST api/auth/login`, with the same test email the browser receives.
- Build browser URLs with `{app}TestMode=true`, `{app}TestAuth=true`, `{app}TestReset=true`, `{app}TestEmail`, `{app}TestOnboarding`, `{app}TestSection`, and `{app}TestGatewayBaseUrl`. The gateway URL must be URL-encoded and must come from Aspire's named Gateway endpoint.
- Start one `{APP}_WASM_STARTUP_TIMEOUT_SECONDS` budget before clean/restore. Restore, build, AppHost create/build/start, named health waits, endpoint resolution, Gateway auth warm-up, and browser launch consume its remaining time. Per-step caps may fail sooner but never reset the budget. Default at least 1800 s for a cold first build.
- Stop/dispose the Aspire graph in assembly cleanup. If explicit Docker cleanup is needed, scope it to this test run only.
- Reset the static base URL during assembly cleanup.
- Run `dotnet build` or `dotnet test tests/Test.PlaywrightUI/Test.PlaywrightUI.csproj -m:1` before handoff. Namespace mismatches between wrapper tests and shared runner types are scaffold defects, not runtime issues.

Generated assembly:

```csharp
// tests/Test.PlaywrightUI/AssemblyInfo.cs
[assembly: DoNotParallelize]
```

Required files:

- `WasmTestSettings.cs`: reads `{APP}_WASM_TESTS_ENABLED`, `{APP}_WASM_BROWSER`, `{APP}_WASM_HEADLESS`, `{APP}_WASM_TEST_EMAIL`, `{APP}_WASM_STARTUP_TIMEOUT_SECONDS`, and `{APP}_WASM_PAGE_LOAD_TIMEOUT_SECONDS`. Treat only `false`, `0`, or `no` as opt-out. The startup value is one end-to-end wall-clock budget, default at least 1800 s.
- `WasmAppHost.cs`: configures the graph and build arguments but delegates Docker preflight, cumulative deadline, resource waits, diagnostics, and cleanup to `AspireTestHostContext`.
- `WasmTestHarness.cs`: owns Playwright startup, browser diagnostics, URL building, bridge-state polling, canvas assertions, screenshot artifacts, and failure messages.

`WasmAppHost` should expose one entry point:

```csharp
internal static Task<WasmTestSettings> EnsureStartedAsync(WasmTestSettings settings, TestContext context);
```

`WasmTestHarness` should expose one test wrapper:

```csharp
internal static Task RunAsync(
    WasmTestSettings settings,
    TestContext context,
    Func<WasmTestSettings, IPage, Task> test);
```

Browser diagnostics captured by the harness:

- Console messages.
- Page errors.
- Failed requests.
- HTTP responses with status 400 or higher.
- `window.onerror`.
- `unhandledrejection`.
- Current URL and `document.readyState`.
- HTML snippet, script list, canvas count, body text.
- Last `__{app}TestState` JSON.

Node/TypeScript runner rules:

- Use latest stable `@playwright/test`. Older versions can emit Node 26 `DEP0205 module.register()` deprecation noise that hides useful failure output.
- Run one TypeScript project per child process (`node .../cli.js test --project <name>`). Do not run every Playwright project in one process.
- Read `{APP}_PLAYWRIGHT_PROJECT_TIMEOUT_SECONDS` and `{APP}_PLAYWRIGHT_TEST_TIMEOUT_SECONDS` as subordinate caps; also pass the shared startup-deadline token so neither can extend the end-to-end budget. Fail fast with command, exit code, stdout, stderr, and timeout value.
- On timeout/cancellation, kill the child process tree (`Kill(entireProcessTree: true)`) before returning failure.
- Do not pass `--reporter=line` from a C# or CI child-process runner. Its carriage-return progress output can hide failure detail in captured stdout/stderr. Use `list`, `dot`, or the default reporter when output is captured.
- Keep C# runner namespaces and TypeScript runner namespaces aligned with the generated project. The solution build is the gate.

## Playwright: wait on state, not DOM

### File: `tests/Test.PlaywrightUI/Uno/{Entity}CanvasTests.cs`

```csharp
/// <summary>
/// Skia-canvas WASM smoke for {Entity}. Tier: Test.PlaywrightUI (browser) - waits on the
/// globalThis.__{app}TestState bridge because the Skia renderer exposes no per-control DOM.
/// The shared WasmAppHost fixture starts Aspire, restores/builds browserwasm, and resolves
/// dynamic endpoints. The test asserts on published state and saves a screenshot artifact.
/// Manual run (Docker must be running; local stack script is optional):
///   dotnet test tests/Test.PlaywrightUI/Test.PlaywrightUI.csproj --filter TestCategory=WasmUI -m:1
/// </summary>
[TestClass]
[TestCategory("WasmUI")]
public class {Entity}CanvasTests
{
    public TestContext TestContext { get; set; } = null!;

    [TestMethod]
    [Timeout(300000)]
    public async Task Given_TestMode_When_AppBoots_Then_ReachesHomeSectionAuthenticated()
    {
        var settings = WasmTestSettings.From(TestContext);
        if (!settings.Enabled)
        {
            Assert.Inconclusive(settings.DisabledMessage);
        }

        await WasmTestHarness.RunAsync(settings, TestContext, async (activeSettings, page) =>
        {
            var url = WasmTestHarness.BuildUrl(
                activeSettings,
                onboarding: "complete",
                section: "home");

            await WasmTestHarness.NavigateAsync(page, activeSettings, url);
            var state = await WasmTestHarness.WaitForStateAsync(
                page,
                activeSettings,
                s => s.Status == "ready" && s.Auth == "authenticated" && s.Section == "home",
                "ready authenticated home");

            Assert.AreEqual("authenticated", state.Auth);
            Assert.AreEqual("home", state.Section);
            await WasmTestHarness.AssertCanvasRenderedAsync(page, activeSettings);
            await WasmTestHarness.SaveScreenshotAsync(page, activeSettings, TestContext, "{entity}-canvas-home");
        });
    }
}
```

For Node/TS Playwright, the same shape applies: `await page.waitForFunction(() => globalThis.__{app}TestState?.status === "ready", { timeout: remainingStartupMilliseconds })`, then read fields off the returned handle. The fixture owns one startup deadline across restore, build, AppHost, readiness, and browser launch; per-step caps may be shorter but cannot reset it ([../skills/testing-quality.md](../skills/testing-quality.md)).

## Verification

- [ ] Bridge file is guarded by the WASM compilation symbol and absent from Android/iOS/desktop output.
- [ ] With no `{app}TestMode=true`, `globalThis.__{app}TestState` is undefined (production untouched).
- [ ] `{app}TestAuth=true` drives **real** Gateway local auth, not an injected token.
- [ ] `{app}TestGatewayBaseUrl` is passed from Aspire's dynamic Gateway endpoint; no hard-coded dev gateway port remains.
- [ ] Gateway auth is warmed before navigation.
- [ ] `{app}TestReset=true` prevents stale browser state from satisfying the smoke.
- [ ] Both `complete` and `fresh` onboarding states are reachable via the query string.
- [ ] Tests await `__{app}TestState` fields; no DOM/role/text selector is used against the canvas.
- [ ] Tests assert a rendered canvas larger than 100x100 and a nonblank fingerprint/pixel hash.
- [ ] `WasmUI` tests start Aspire in testing mode when the app needs AppHost resources.
- [ ] Docker missing marks `Assert.Inconclusive` with a fix; Docker present starts real resources.
- [ ] Child `dotnet` restore/build commands clear profiler env vars and consume the shared remaining startup budget; any per-step cap is subordinate.
- [ ] WASM clean rebuild deletes both target `bin` and target `obj`, then writes a test-owned stamp.
- [ ] Lazy single-start guard checks static `_app` / base URL state, not per-test `WasmTestSettings.BaseUrl`.
- [ ] Named Aspire endpoints are used for Gateway/UI URLs; no fixed local port fallback ships in tests.
- [ ] Browser diagnostics are included in every navigation/state-timeout failure.
- [ ] Assembly-level `[DoNotParallelize]` exists for AppHost-backed `WasmUI`.
- [ ] Each canvas test saves a screenshot artifact.
- [ ] Canvas tests carry `[TestCategory("WasmUI")]` and a class `<summary>` with a manual-run command.
- [ ] Node runner uses latest stable `@playwright/test`, one project per process, bounded timeout env vars, process-tree kill, captured stdout/stderr, and no `--reporter=line`.
- [ ] Generated `Test.PlaywrightUI` compiles in the solution before handoff.
