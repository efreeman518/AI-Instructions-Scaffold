# Test Template - Uno WASM Canvas Test Bridge (Phase 5c/5d, Skia-canvas only)

| | |
|---|---|
| **Generates** | `src/UI/{Project}.Uno/Testing/{Project}TestBridge.wasm.cs`, `Test/Test.PlaywrightUI/Uno/{Entity}CanvasTests.cs` (or `.ts` for Node Playwright) |
| **Requires** | An Uno WASM target that renders through the **Skia canvas** renderer (single `<canvas>`, no per-control DOM), a running Gateway for real local auth, [testing-quality.md](../skills/testing-quality.md) (Hosted Browser UI) |
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

## Bridge (representative shape)

### File: `src/UI/{Project}.Uno/Testing/{Project}TestBridge.wasm.cs`

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

## Playwright: wait on state, not DOM

### File: `Test/Test.PlaywrightUI/Uno/{Entity}CanvasTests.cs`

```csharp
/// <summary>
/// Skia-canvas WASM smoke for {Entity}. Tier: Test.PlaywrightUI (browser) - waits on the
/// globalThis.__{app}TestState bridge because the Skia renderer exposes no per-control DOM.
/// Boots the app once per class (WASM cold-start is slow); asserts on published state and
/// saves a screenshot artifact for visual confirmation.
/// Manual run (start the local stack first - see eng/test/start-local-test-stack.ps1):
///   rtk dotnet test src/Test/Test.PlaywrightUI/Test.PlaywrightUI.csproj --filter TestCategory=WasmUI
/// </summary>
[TestClass]
[TestCategory("WasmUI")]
public class {Entity}CanvasTests : PageTest
{
    private static readonly string BaseUrl =
        Environment.GetEnvironmentVariable("{APP}_UNO_BASE_URL") ?? "https://localhost:7069";

    public override BrowserNewContextOptions ContextOptions() => new() { IgnoreHTTPSErrors = true };

    [TestMethod]
    public async Task Given_TestMode_When_AppBoots_Then_ReachesTodaySectionAuthenticated()
    {
        var url = $"{BaseUrl}/?{app}TestMode=true&{app}TestAuth=true" +
                  $"&{app}TestEmail=wasm-test@local.test&{app}TestOnboarding=complete&{app}TestSection=today";
        await Page.GotoAsync(url);

        // Wait on published state, never on canvas pixels or DOM text.
        await Assertions.Expect(async () =>
        {
            var ready = await Page.EvaluateAsync<bool?>("() => globalThis.__{app}TestState?.ready === true");
            Assert.IsTrue(ready == true);
        }).ToPassAsync(new() { Timeout = 120_000 });

        var state = await Page.EvaluateAsync<JsonElement>("() => globalThis.__{app}TestState");
        Assert.AreEqual("authenticated", state.GetProperty("auth").GetString());
        Assert.AreEqual("today", state.GetProperty("section").GetString());

        await Page.ScreenshotAsync(new() { Path = "artifacts/{entity}-canvas-today.png", FullPage = true });
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
- [ ] Each canvas test saves a screenshot artifact.
- [ ] Canvas tests carry `[TestCategory("WasmUI")]` and a class `<summary>` with a manual-run command.
