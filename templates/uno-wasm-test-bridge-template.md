# Test Template - Uno WASM Canvas Test Bridge (Phase 5c/5d, Skia-canvas only)

| | |
|---|---|
| **Generates** | `src/UI/{Project}.Uno/Testing/{Project}TestBridge.cs`, `Test/Test.PlaywrightUI/Uno/WasmAppHost.cs`, `WasmTestHarness.cs`, `WasmTestSettings.cs`, `AssemblyInfo.cs`, `Test/Test.PlaywrightUI/Uno/{Entity}CanvasTests.cs` (or `.ts` for Node Playwright) |
| **Requires** | An Uno WASM target that renders through the **Skia canvas** renderer (single `<canvas>`, no per-control DOM), a Gateway for real local auth, an Aspire AppHost when the app needs API/resources, [testing-quality.md](../skills/testing-quality.md) (Hosted Browser UI) |
| **Phase** | Bridge added with the Uno host (5c); canvas tests authored in 5d |
| **Protocol** | Tests-after. The bridge is a browser-only diagnostic surface, never a production code path. |

---

## When you need this

Uno renders WASM two ways:

- **Managed/native DOM renderer** - each control maps to a DOM element carrying `xamltype` / `xamlautomationid`. The coordinate-click + `querySelectorAll` strategy in [../skills/ui-uno-platforms.md](../skills/ui-uno-platforms.md) (Playwright Testing Against Uno WASM) works here.
- **Skia canvas renderer** - the whole app paints into one `<canvas>`. There are **no per-control DOM nodes**. `querySelectorAll("p")`, `getBoundingClientRect()` on text, and DOM/role selectors all return nothing. Coordinate-clicking by scanning DOM text is impossible.

If the app paints to a Skia canvas, DOM selectors are not "flaky" - they are structurally absent. Use the bridge below: the app publishes its own state to `globalThis`, and Playwright waits on **state**, not DOM.

Detect the renderer once: open the WASM app, run `document.querySelectorAll('[xamltype]').length` in the console. `0` with a single `<canvas>` present means Skia - use the bridge.

## Bridge contract

The bridge exposes a single global the test harness polls:

```js
globalThis.__{app}TestState = {
  testMode: true,            // echoes the requested test mode
  page: "TodayPage",         // current page/route name
  section: "today",          // selected section/tab
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
&{app}TestEmail=wasm-test@local.test
&{app}TestOnboarding=complete
&{app}TestSection=today
```

Rules:

1. **Browser/WASM target only.** Guard the whole file with the WASM compilation symbol so it never ships in Android/iOS/desktop builds.
2. **Default-off.** Publish nothing unless `{app}TestMode=true` is present in the query string (or an equivalent test-only app setting). No flag -> the global is never defined -> production behaviour is untouched.
3. **Real local auth.** When `{app}TestAuth=true`, drive the **real** local auth flow through the Gateway with the supplied email. Do not inject a fake token - that bypasses the wiring the test exists to prove.
4. **Onboarding states.** Support at least `complete` and `fresh` so a test can exercise both the returning-user and first-run shells.
5. **Publish on every state transition.** Re-publish `__{app}TestState` after navigation, auth change, and onboarding change so the harness can await the next state without a full reboot.
6. **Startup error shape.** In the WASM startup path, publish exception type and message only. Avoid `Exception.ToString()` there; Mono can double fault while formatting stack traces after runtime/class-library mismatches.

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
        TestSection = args["{app}TestSection"] ?? "today";
        TestEmail = args["{app}TestEmail"];
        WantsAuth = string.Equals(args["{app}TestAuth"], "true", StringComparison.OrdinalIgnoreCase);
    }

    public static string TestOnboarding { get; private set; } = "complete";
    public static string TestSection { get; private set; } = "today";
    public static string? TestEmail { get; private set; }
    public static bool WantsAuth { get; private set; }

    /// <summary>Re-publish the snapshot after any page / auth / onboarding transition.</summary>
    public static void Publish(string page, string section, string auth, string onboarding, bool adsVisible, bool ready)
    {
        if (!_enabled) return;

        var snapshot = JsonSerializer.Serialize(new
        {
            testMode = true, page, section, auth, onboarding, adsVisible, ready
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

- Check Docker with a short timeout. Missing Docker returns `Assert.Inconclusive` with the exact fix. Docker present means start Aspire and real resources.
- Clean both `bin/<configuration>/<tfm>-browserwasm` and `obj/<configuration>/<tfm>-browserwasm` before a test-owned rebuild.
- Restore with `BuildAllUnoTargets=true` and `EnableUnoWasm=true`.
- Build one target at a time with `TargetFrameworkOverride=<tfm>-browserwasm`, `EnableUnoWasm=true`, `--no-restore`, and `-m:1`. Do not use `-f`.
- Clear coverage/profiler environment variables for child `dotnet` commands; set profiling disabled flags and `MSBUILDDISABLENODEREUSE=1`.
- Write a test-owned stamp file after a successful clean rebuild. Freshness checks require that stamp so old developer builds are not silently accepted.
- Start the Aspire AppHost in testing mode. Keep required backing resources live. Disable only optional hosts such as scheduler, admin, external mappers, notifications, or other non-test-critical processes.
- Wait for required resources to become healthy before using them.
- Resolve Gateway and UI base URLs through named Aspire endpoints. Use `CreateHttpClient(resource, "http")`; do not assume fixed local ports.
- Warm up real Gateway auth before browser navigation.
- Bound every startup step with its own timeout and progress log.
- Stop/dispose the Aspire graph in assembly cleanup. If explicit Docker cleanup is needed, scope it to this test run only.

Generated assembly:

```csharp
// Test/Test.PlaywrightUI/AssemblyInfo.cs
[assembly: DoNotParallelize]
```

Required files:

- `WasmTestSettings.cs`: reads `{APP}_WASM_TESTS_ENABLED`, `{APP}_WASM_BROWSER`, `{APP}_WASM_HEADLESS`, `{APP}_WASM_TEST_EMAIL`, `{APP}_WASM_STARTUP_TIMEOUT_SECONDS`, and `{APP}_WASM_PAGE_LOAD_TIMEOUT_SECONDS`. Treat only `false`, `0`, or `no` as opt-out.
- `WasmAppHost.cs`: owns Docker preflight, clean restore/build, AppHost startup, resource health waits, named endpoint resolution, Gateway auth warm-up, and cleanup.
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

## Playwright: wait on state, not DOM

### File: `Test/Test.PlaywrightUI/Uno/{Entity}CanvasTests.cs`

```csharp
/// <summary>
/// Skia-canvas WASM smoke for {Entity}. Tier: Test.PlaywrightUI (browser) - waits on the
/// globalThis.__{app}TestState bridge because the Skia renderer exposes no per-control DOM.
/// The shared WasmAppHost fixture starts Aspire, restores/builds browserwasm, and resolves
/// dynamic endpoints. The test asserts on published state and saves a screenshot artifact.
/// Manual run (Docker must be running; local stack script is optional):
///   dotnet test src/Test/Test.PlaywrightUI/Test.PlaywrightUI.csproj --filter TestCategory=WasmUI
/// </summary>
[TestClass]
[TestCategory("WasmUI")]
public class {Entity}CanvasTests
{
    public TestContext TestContext { get; set; } = null!;

    [TestMethod]
    [Timeout(300000)]
    public async Task Given_TestMode_When_AppBoots_Then_ReachesTodaySectionAuthenticated()
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
                section: "today");

            await WasmTestHarness.NavigateAsync(page, activeSettings, url);
            var state = await WasmTestHarness.WaitForStateAsync(
                page,
                activeSettings,
                s => s.Status == "ready" && s.Auth == "authenticated" && s.Section == "today",
                "ready authenticated today");

            Assert.AreEqual("authenticated", state.Auth);
            Assert.AreEqual("today", state.Section);
            await WasmTestHarness.AssertCanvasRenderedAsync(page, activeSettings);
            await WasmTestHarness.SaveScreenshotAsync(page, activeSettings, TestContext, "{entity}-canvas-today");
        });
    }
}
```

For Node/TS Playwright, the same shape applies: `await page.waitForFunction(() => globalThis.__{app}TestState?.ready === true, { timeout: 120000 })`, then read fields off the returned handle. Keep the 120 s timeout for WASM cold-start ([../skills/testing-quality.md](../skills/testing-quality.md)).

## Verification

- [ ] Bridge file is guarded by the WASM compilation symbol and absent from Android/iOS/desktop output.
- [ ] With no `{app}TestMode=true`, `globalThis.__{app}TestState` is undefined (production untouched).
- [ ] `{app}TestAuth=true` drives **real** Gateway local auth, not an injected token.
- [ ] Both `complete` and `fresh` onboarding states are reachable via the query string.
- [ ] Tests await `__{app}TestState` fields; no DOM/role/text selector is used against the canvas.
- [ ] `WasmUI` tests start Aspire in testing mode when the app needs AppHost resources.
- [ ] Docker missing marks `Assert.Inconclusive` with a fix; Docker present starts real resources.
- [ ] Child `dotnet` restore/build commands clear profiler env vars.
- [ ] WASM clean rebuild deletes both target `bin` and target `obj`, then writes a test-owned stamp.
- [ ] Named Aspire endpoints are used for Gateway/UI URLs; no fixed local port fallback ships in tests.
- [ ] Browser diagnostics are included in every navigation/state-timeout failure.
- [ ] Assembly-level `[DoNotParallelize]` exists for AppHost-backed `WasmUI`.
- [ ] Each canvas test saves a screenshot artifact.
- [ ] Canvas tests carry `[TestCategory("WasmUI")]` and a class `<summary>` with a manual-run command.
