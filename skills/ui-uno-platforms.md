# Uno Platform UI - Platform-Specific Rules

Platform-specific build, deploy, and debugging rules for Uno (WASM, Android), plus CI requirements. Loaded during Phase 5c when an Uno UI project is in scope and a specific target needs attention.

Companion files:
- [ui-uno.md](ui-uno.md) - index + decision table
- [ui-uno-shell.md](ui-uno-shell.md) - project setup, app hosting, shell control
- [ui-uno-mvux.md](ui-uno-mvux.md) - MVUX models, routing, XAML, business services, auth
- [ui-uno-navigation.md](ui-uno-navigation.md) - menu "always-to-top" wiring, cross-page dirty guard

---

## Platform Target Build Rules

Build one Uno target at a time. The project owns target selection through `TargetFrameworkOverride`; do not pass `-f`.

When the Uno project defaults to a fast single target such as browserwasm, restore all enabled Uno targets before Android/iOS package builds. `TargetFrameworkOverride` on build is not enough if `project.assets.json` was last restored for browserwasm only; the Android package can miss `Uno.WinUI.Runtime.Skia.Android` and crash before app code runs.

```powershell
dotnet restore src/UI/{Project}.Uno/{Project}.Uno.csproj -p:BuildAllUnoTargets=true -p:EnableUnoWasm=true
dotnet build src/UI/{Project}.Uno/{Project}.Uno.csproj -p:TargetFrameworkOverride=$(LatestStableTfm)-browserwasm -p:EnableUnoWasm=true --no-restore -m:1
dotnet build src/UI/{Project}.Uno/{Project}.Uno.csproj -p:TargetFrameworkOverride=$(LatestStableTfm)-android --no-restore -m:1
dotnet build src/UI/{Project}.Uno/{Project}.Uno.csproj -p:TargetFrameworkOverride=$(LatestStableTfm)-ios --no-restore -m:1
```

Use serial builds (`-m:1`) for platform sweeps. Uno platform targets share `obj/` assets and `project.assets.json`; parallel builds can race and produce misleading restore/build failures.

Before diagnosing a platform runtime failure, inspect the restored asset graph:

```powershell
Select-String -Path src/UI/{Project}.Uno/obj/project.assets.json -Pattern "Uno.WinUI.Runtime.Skia.Android"
```

If that package is absent for an Android Skia build, fix restore scope first. Do not switch to native renderer or rewrite platform startup code until a clean Skia template or reference app fails the same way.

Expected platform files:

- Android: `Platforms/Android/AndroidManifest.xml`, `Main.Android.cs`, `MainActivity.Android.cs`, `Resources/`.
- iOS: `Platforms/iOS/Info.plist`, `Entitlements.plist`, `Main.iOS.cs`, `PrivacyInfo.xcprivacy`, launch images.
- WebAssembly: `Platforms/WebAssembly/WasmScripts/AppManifest.js`.

Windows can keep an iOS compile gate when the .NET iOS workload is available, but iOS simulator/device UI testing requires macOS or a Mac build host.

## WASM Debugging Ladder

When a Uno WASM build or runtime failure occurs, follow this fixed validation order before applying broader hosting rewrites:

1. **Root document:** Does the WASM host page (`index.html`) load at all? Check for 404/500 on the base URL.
2. **Package/static assets:** Are CSS, images, and app-specific static files served? Check browser network tab for 404s.
3. **`/_framework` assets:** Do `dotnet.wasm`, `blazor.boot.json` / `uno-boot.json`, and framework DLLs load? Missing `/_framework` files indicate a build or publish issue, not a routing issue.
4. **Generated bootstrap/config:** Are `appsettings.json`, `AppManifest.js`, and generated host files present and correct? Do not rewrite these unless a specific file is confirmed missing or malformed.
5. **Browser console:** Check for JS errors, CORS failures, or WASM instantiation errors. These narrow the fault to runtime init vs asset serving.

Do not apply broad hosting or routing rewrites before completing this sequence.

## WASM Host Launch Requirements

These apply to `WasmAppHost` (the dev host launched by `dotnet run` in Uno WASM projects).

### AppManifest.js - Required Bootstrap File

`Uno.UI.js` does `define(["./AppManifest.js"])` via RequireJS at startup. If the file does not exist the splash screen never clears - no JS error is visible.

Every Uno WASM project MUST contain:

```
Platforms/WebAssembly/WasmScripts/AppManifest.js
```

Minimal content:

```js
var UnoAppManifest = {
    displayName: "{AppName}",
    splashScreenColor: "transparent"
};
```

Add this file during initial scaffold. Do not leave it absent and rely on the build to generate it - it is not generated automatically.

### Working Directory Sensitivity

`WasmAppHost` resolves the hashed `package_<hash>/` directory relative to CWD. It only produces the correct `index.html` and static-asset paths when run **from the Uno project directory**, not from the solution root or a parent directory.

Always run:

```powershell
Set-Location 'src\UI\{Project}.Uno'
dotnet run
```

Never use `dotnet run --project <path>` from an unrelated working directory - the static asset paths in the output will be wrong and all `package_<hash>/*` requests will 404.

### Port Exclusion on Windows (Hyper-V / WSL)

Windows reserves port ranges for Hyper-V and WSL (shown as PID 4 owning ports in `Listen` state). These ports cannot be bound by user-space processes - attempts fail silently or with error 10013.

Diagnose before changing launchSettings:

```powershell
netsh int ipv4 show excludedportrange protocol=tcp | Select-String '5555[0-9]'
```

If a port used in `launchSettings.json` is listed, change it to a port confirmed absent from the exclusion list.

**Known-bad port**: `55552` is routinely in the excluded range on Hyper-V/Docker Desktop hosts.
**Standard local Uno endpoints**: HTTPS `https://localhost:7069`, HTTP `http://localhost:5189`.

When scaffolding a new Uno project's `launchSettings.json`, use:

```json
"applicationUrl": "https://localhost:7069;http://localhost:5189"
```

Also update the Gateway `CorsSettings.AllowedOrigins` to include both `https://localhost:7069` and `http://localhost:5189`.

### Freeing a Stuck Dev Port on Windows (from bash/Git Bash)

When `dotnet run` fails with `AddressInUseException` because a previous `WasmAppHost` process is still holding the port (crash, orphaned debugger, terminated IDE), find and kill it. In Git Bash / MSYS bash, `taskkill` requires **double-slash** flags:

```bash
# Find PID holding the port
netstat -ano | grep :7069
# Kill (bash: // not /)
taskkill //F //PID <pid>
```

A `TIME_WAIT` entry on the client side is harmless - it's a closed socket awaiting TCP drain and will clear on its own. Only `LISTENING` entries block a new bind.

Do **not** change the launch port to work around a stuck process - find and kill it instead. Rotating ports invalidates CORS config, Playwright baseURL, and bookmark URLs.

### Post-Rebuild Browser Refresh

After any rebuild, `WasmAppHost` serves a new `package_<hash>/` directory. The old hash is instantly stale. Always open a **new browser tab** to the HTTPS origin - never reload an existing tab. Existing tabs will 404 all their `package_*` asset requests until a full address-bar navigation occurs.

### Serve Fresh WASM Output

A standalone WASM server (the one Playwright targets) must serve static assets from the **current** `bin/<config>/net{X}.0-browserwasm/wwwroot` output, not a stale `bin/<config>/browser-wasm/wwwroot` folder left by an older Uno/SDK build. When both exist, builds and test runs disagree about which assets are live and Playwright loads yesterday's app. Build the WASM target explicitly before browser tests, then point the server at the fresh output:

```powershell
dotnet restore src/UI/{Project}.Uno/{Project}.Uno.csproj -p:BuildAllUnoTargets=true -p:EnableUnoWasm=true
dotnet build src/UI/{Project}.Uno/{Project}.Uno.csproj -p:TargetFrameworkOverride=net{X}.0-browserwasm -p:EnableUnoWasm=true --no-restore -m:1
```

If a `browser-wasm/` sibling lingers, delete it so it cannot win asset resolution. The local test stack script ([../templates/local-test-stack-template.md](../templates/local-test-stack-template.md)) does this build step for you.

### Clean Browser WASM Output Before Test-Owned Rebuilds

When a test fixture rebuilds Uno WASM, clean both target-specific output roots before the build:

```text
src/UI/{Project}.Uno/bin/<configuration>/net{X}.0-browserwasm
src/UI/{Project}.Uno/obj/<configuration>/net{X}.0-browserwasm
```

Cleaning only `bin/` can leave stale WebCIL/runtime intermediates in `obj/`. If the browser reports `Your mono runtime and class libraries are out of sync` and names `System.Private.CoreLib.dll`, suspect stale mixed WASM output first. Clean both folders, then restore/build with `TargetFrameworkOverride`; do not switch renderers or rewrite startup code until this is ruled out.

After a test-owned clean rebuild succeeds, write a stamp file inside the fresh target output, for example `bin/Debug/net{X}.0-browserwasm/.{app}-wasm-test-build.stamp`. Freshness checks must require that stamp plus current source timestamps. This prevents Test Explorer from silently accepting an old developer build that happens to have `index.html`.

### Child Dotnet Build Environment

WASM test fixtures often shell out to `dotnet restore` / `dotnet build` from inside a test runner. Clear coverage/profiler variables for those child processes so Visual Studio Test Explorer or coverage tools do not leak profiler hooks into MSBuild:

```text
CORECLR_PROFILER
CORECLR_PROFILER_PATH
CORECLR_PROFILER_PATH_32
CORECLR_PROFILER_PATH_64
COR_PROFILER
COR_PROFILER_PATH
COR_PROFILER_PATH_32
COR_PROFILER_PATH_64
COVERLET_ENABLE_PROFILING
COVERLET_PROFILER_PATH
```

Also set `CORECLR_ENABLE_PROFILING=0`, `COR_ENABLE_PROFILING=0`, `MSBUILDDISABLENODEREUSE=1`, `DOTNET_CLI_TELEMETRY_OPTOUT=1`, and `DOTNET_NOLOGO=1` in the child process environment.

---

## Playwright Testing Against Uno WASM

The Playwright-against-WASM test strategy - boot-once-per-describe, renderer detection (managed-DOM vs Skia canvas), coordinate-click for the managed-DOM renderer, the Skia canvas test bridge, browser diagnostics, and the slow-router timeout rule - is canonical in [testing-quality.md](testing-quality.md) section Hosted Browser UI (Test.PlaywrightUI). Use the `{APP}_WASM_BASE_URL` env var (the `{APP}_WASM_*` family) for standalone runs.

Platform-build specifics that affect those tests (clean `bin`+`obj`, stale-asset rebuild, targeted-build command) live in this file's Build sections above.

## Mobile Test Strategy

Use a layered strategy instead of trying to make every test run on every device target:

- **WASM mobile viewport smoke**: Playwright with iPhone/Pixel-sized viewports validates responsive shell, navigation, forms, and empty/error states quickly on Windows.
- **Android emulator smoke**: Prefer MSTest + Appium when the scaffold's test stack is MSTest. Run against a Debug Android build with `/p:UseMocks=true` first. Prove launch, shell render, first navigation, and one create/edit workflow before live backend tests.
- **Android live E2E**: Keep a tiny Aspire-backed suite for Gateway/API connectivity. Use `10.0.2.2` for local backend URLs and avoid broad CRUD duplication already covered by service/API tests.
- **iOS UI tests**: Plan for macOS CI or a Mac host. Windows can maintain compile checks and shared MVUX/service tests, but cannot run iOS simulator/device UI tests locally.

Prefer mocks for deterministic native smoke tests and reserve live mobile tests for wiring risks: host networking, auth, TLS/certs, and platform startup.

Recommended Android local test flow:

```powershell
dotnet restore src/UI/{Project}.Uno/{Project}.Uno.csproj -p:BuildAllUnoTargets=true
dotnet build src/UI/{Project}.Uno/{Project}.Uno.csproj -p:TargetFrameworkOverride=$(LatestStableTfm)-android -p:UseMocks=true --no-restore -m:1

npm install -g appium
appium driver install uiautomator2
appium driver doctor uiautomator2

# Appium 3: --relaxed-security is replaced by a scoped --allow-insecure list.
# This harness needs the uiautomator2 adb_shell feature for `mobile: shell` fallbacks
# (input text, statusbar collapse). Use the exact form:
appium --address 127.0.0.1 --port 4723 --allow-insecure=uiautomator2:adb_shell
```

**Visible vs headless emulator.** An agent often boots the emulator with `-no-window` (headless) to save resources; a human watching expects a visible window. State which you are launching, because they fail differently: headless still drives via Appium but produces no on-screen view, and some software-GPU crashes only reproduce in one mode. For an interactive/human run launch a visible emulator (no `-no-window`); for unattended/agent runs `-no-window` is fine - just record it in the run notes so a blank screen is not mistaken for a hung app.

**Runner readiness checks before explicit mobile lane.** `src/Test/Test.Mobile/run-mobile-tests.ps1` owns these checks and fails fast after it sets `{APP}_MOBILE_TESTS_ENABLED=true` if any fail:

```powershell
adb devices -l                                              # device present and not "offline"
adb -s emulator-5554 shell getprop sys.boot_completed       # must print 1
curl http://127.0.0.1:4723/status                           # Appium server reachable
```

`Test.Mobile` exists only when `includeUnoUI` was selected in Phase 2 (see [Capability-Gated Test Tiers](testing.md#capability-gated-test-tiers-the-early-decision-drives-the-rest)). The mobile tier is **opt-in**: default `dotnet test` with `{APP}_MOBILE_TESTS_ENABLED` unset/false makes each test self-mark `Assert.Inconclusive` without starting Appium, starting an emulator, or building an APK. Explicit mobile runs use `src/Test/Test.Mobile/run-mobile-tests.ps1`; once that runner sets `{APP}_MOBILE_TESTS_ENABLED=true`, missing/broken APK, emulator/device, Appium, or UiAutomator2 is a red failure. Keep `[TestCategory("MobileUI")]` on every test so normal lanes can exclude it by filter (`--filter TestCategory!=MobileUI`).

Generate one native mobile lane:

- **Launch smoke** - app launch, native surface, first-viewport accessibility, and one reliable text-entry smoke. This is the default and CI mobile lane.
- **Do not use Appium for deep workflows.** Do not drive deep CRUD, search persistence, child collections, or long-scroll Skia forms with Appium/UiAutomator2. Cover those in API, integration, unit, and Playwright lanes.

**Make env paths robust - the test process working directory is not the repo root.** Resolve `{APP}_ANDROID_APP_PATH` and any path env var by accepting both an absolute path and a repo-root-relative path like `src/UI/{Project}.Uno/...`: probe the path as-given, then re-probe against the resolved repo root (walk up for the `.slnx`/`.git` marker). Do not assume `Directory.GetCurrentDirectory()` is the repo root.

**On constrained machines, run one mobile test first through the runner** (`powershell -NoProfile -File src/Test/Test.Mobile/run-mobile-tests.ps1 -SkipBuild -Filter "FullyQualifiedName~<OneTest>"`) before running the whole `MobileUI` category. Per-test runs make failure mode legible.

**Preserve diagnostics by default, not only on a debug switch.** On every mobile run write the screenshot, Appium `PageSource`, and the Appium server log to a test-output artifacts folder. These artifacts are what separates "this Cloud PC cannot handle it" from "selector/scroll/Appium-config problem" - without them the two are indistinguishable.

```powershell
powershell -NoProfile -File src/Test/Test.Mobile/run-mobile-tests.ps1
powershell -NoProfile -File src/Test/Test.Mobile/run-mobile-tests.ps1 -SkipBuild
powershell -NoProfile -File src/Test/Test.Mobile/run-mobile-tests.ps1 -SkipBuild -Filter "FullyQualifiedName~<OneTest>"
```

### Appium Selector Rules (Uno on Android)

Uno renders to a Skia canvas, not native widgets, so the accessibility tree Appium sees is narrow and specific. These rules are load-bearing - guessing wastes whole emulator runs:

- **Target by `AutomationProperties.Name` via `MobileBy.AccessibilityId`.** On Android, Name surfaces as `content-desc`; AutomationId does **not** surface as `resource-id`. Add `AutomationProperties.Name` to every control test drives (text boxes, buttons, list rows). Bind a row Name to title (`AutomationProperties.Name="{Binding Title}"`) so rows are addressable. Keep AutomationId too - WASM Playwright keys on it, so one annotation pass serves both.
- **Avoid broad XPath except fallback probing.** Prefer exact `MobileBy.AccessibilityId(value)` lookups. If diagnostics show no accessibility id is exposed, use a bounded fallback probe against `content-desc` or `text`, then capture page source before changing selectors.
- **`ComboBox` renders as `android.widget.Spinner`; its dropdown options are not reliably exposed to uiautomator2.** Treat priority/status/category selection as **best-effort** (try, short timeout, dismiss-and-continue on miss) - never a hard assertion that can fail the whole lifecycle. Assert CRUD on title, description, checklist, comment, and list presence instead.
- **Scroll off-screen controls with a bounded content-area swipe - never `UiScrollable`/a top-edge swipe.** Form sections below the fold (checklist, comments) are absent from the tree until scrolled, but `UiScrollable.scrollIntoView` (and any swipe that starts near the top of the screen) is read by Android as "pull down the notification shade," which then covers the app and makes every subsequent find time out. Instead drive `mobile: swipeGesture` over an explicit rectangle kept well below the status bar (e.g. top at 35% of height) and re-check between swipes.
- **Never press the Android Back button to dismiss a popup.** Uno intercepts Back for page navigation, so `driver.Navigate().Back()` to close a Spinner dropdown or keyboard instead leaves the current page entirely. Dismiss by leaving the dropdown open (return best-effort) or tapping a neutral on-screen element - never Back.
- **Keep recovery bounded, then fail the explicit lane.** A software-GPU emulator under Skia load can drop the notification shade, stall the Skia surface, or crash the uiautomator2 instrumentation process. Collapse the shade (`mobile: shell` -> `cmd statusbar collapse`) inside bounded waits and allow one targeted session recreate for a known first-start instrumentation crash. If recovery fails, the explicit runner lane is red with screenshot/page-source/Appium logs; do not turn broken Appium/UiAutomator2 or missing controls into `Assert.Inconclusive`.
- **Diagnose with Appium `PageSource`, not `adb shell uiautomator dump`.** The adb dump fails with `ERROR: could not get idle state` because the Skia canvas never reports idle; Appium's uiautomator2 disables idle waits and returns a usable tree. Save the page source on failure and read it to confirm how a control surfaces before adjusting selectors.
- **Text entry works via `SendKeys`** (Uno text boxes surface as `EditText`). Start Appium with `--allow-insecure=uiautomator2:adb_shell` so a `mobile: shell` -> `input text` fallback is available for the rare field that rejects `SendKeys`.
- **Backend reachability + boot stability.** The app reaches a local backend at `http://10.0.2.2:{gatewayHttpPort}` (the Android gateway base URL), not `localhost`. A freshly booted software-GPU emulator often throws a transient "System UI isn't responding" ANR - dismiss it and disable the three animation scales before driving the app.

### Mobile Appium Harness Setup (Uno on Android)

The selector rules above assume the app is already up and driveable. Getting there on a Skia/Android emulator is a separate fight; these are the harness lessons:

- **Pragmatic baseline: neutralize the backend at compile time, not with a launch-time bridge.** For a reachability-only smoke tier (launch, render, navigate, one CRUD via UI - no backend-data assertions), the simplest proven path is to build the test APK with `-p:UseMocks=true` so a compile-time `USE_MOCKS` constant swaps the `HttpClient` primary handler to an in-process mock, and gate an offline auth path behind the **same** flag so login issues a local token without a gateway. This reuses the WASM/desktop mock handler and needs no per-TFM bridge. The reference app does exactly this. Adopt the per-TFM `Intent.Extras` bridge below only when you need ONE APK to toggle backend/auth at launch (e.g. a shared smoke + live-E2E build) - its launch-time toggle buys nothing a reachability tier uses, and the per-TFM `Compile Remove/Include` juggling is a real footgun.
- **The security boundary is the backend auth gate, not the UI login.** Gate the *backend* so an unconfigured build cannot accept forged tokens - the reference app does this by config: the API's `AuthMode` (default `Scaffold` = dev passthrough; else real Entra JWT) and the Gateway's `EntraExternal` section (absent = dev passthrough; present = real Entra validation). The Uno UI's login (`ProcessCredentials`) is a dev/sample **stub** that mints a local token for any username; that is fine and intentionally ungated, because the non-mocked dev loop (UI + Aspire dev gateway) needs to log in, and a configured production backend rejects the stub token regardless. Do NOT gate the UI stub behind `USE_MOCKS` (it breaks the dev loop) - instead mark it clearly and replace it with a real interactive MSAL/Entra login for production.
- **Test-mode bridge must be per-TFM - the WASM hook does not transfer to mobile.** A WASM UI test typically drives the app via URL query params read by a test bridge, backed by a real (Aspire-hosted) gateway for login. Mobile has neither a query string nor a backend, so the app stalls on the first gated screen (login/onboarding). Ship one bridge per target with the same public surface: WASM reads `location.search` + env and publishes to JS globals; Android reads a static dictionary populated from the launch `Intent.Extras`; a Noop default (desktop) returns disabled. Wire per-TFM in the csproj with `Compile Remove` + conditional `Compile Include` (`$(TargetFramework.Contains('-android'))`); forgetting the Remove half yields duplicate-type build errors.
- **Mobile needs an offline auth path.** The mobile harness has no gateway, so calling the real `LoginAsync` hangs. Give the bridge a `BypassAuth` flag (default on for mobile when no gateway URL is supplied) and fabricate the auth/session response locally - mobile UI tests assert UI reachability, not backend data.
- **Android intent-extras plumbing.** Appium passes flags via the `optionalIntentArguments` capability (`--es key value ...`). `MainActivity.OnCreate` must copy `Intent.Extras` into the static dict the bridge reads BEFORE calling `base.OnCreate`. Use case-insensitive keys.
- **Export the Android SDK to the Appium SERVER process, not the test process.** UiAutomator2 shells out to `adb` from the `appium` process. If only the dotnet-test shell has `ANDROID_HOME`/`ANDROID_SDK_ROOT`, every test fails in ~8s with "Neither ANDROID_HOME nor ANDROID_SDK_ROOT ... exported." Set them in the shell that launches `appium`, then restart the server.
- **Raise cold-start Appium capabilities for a large APK under software GPU.** A hundreds-of-MB APK's first cold foreground launch exceeds Appium's 20s default and fails session creation in `am start-activity -W`. Set in the driver factory: `adbExecTimeout=120000`, `appWaitDuration=60000`, `androidInstallTimeout=180000`, `uiautomator2ServerLaunchTimeout=90000`, `uiautomator2ServerInstallTimeout=90000`, `disableWindowAnimation=true`.
- **Size the driver's `StartupTimeout` for worst-case session creation, not just for waits.** The Appium .NET client uses the command timeout (set from `StartupTimeout`) as the per-command HTTP timeout for `POST /session` itself. If it is shorter than a cold-start session creation, the client aborts the request before the session is established - and before any in-test re-create/retry logic can run, because that logic only triggers on a returned `WebDriverException`, not on a client-side timeout. Set `StartupTimeout` to cover the slowest cold start (reuse `{APP}_MOBILE_STARTUP_TIMEOUT_SECONDS`, e.g. 180s on a software-GPU emulator), at least as large as the server-side caps above.
- **Recover from a first-test instrumentation crash; do not score it red.** The `io.appium.uiautomator2.server` instrumentation often dies on the crash-prone first cold start (find / page-source calls report "instrumentation process is not running"). Prefer a one-shot re-create + retry: when a `WebDriverException` matches that signature, dispose the dead session, create a fresh driver, reset the deadline, and RETURN the new driver so each suite reassigns its `driver` local (cleanup `finally` blocks must target the live session). A throwaway warmup session before the suite also works; degrading to Inconclusive (selector rules above) is the fallback when re-create still fails.
- **Suppress and tap through ANR overlays during warmup.** Cold boot throws "System UI isn't responding" / "<app> isn't responding" overlays that hijack taps and poison screenshots. Belt-and-suspenders: `adb shell settings put global hide_error_dialogs 1` once per run (it suppresses app dialogs, NOT reliably the SystemUI ANR), AND in the shared boot-wait loop detect the dialog (`android:id/aerr_wait` / `aerr_close`) and tap "Wait" each iteration until the app surface renders. Never auto-dismiss a dialog that names the app under test - that is a real failure to surface.
- **Software GPU + cold boot.** The host/default GPU can crash the emulator (e.g. access violation in the Intel iGPU driver) after extended runs. Launch with `-gpu swiftshader_indirect`, and cold-boot with `-no-snapshot` after a crash. Software GPU is CPU-heavy and worsens cold-start ANRs - budget a long startup timeout (`{APP}_MOBILE_STARTUP_TIMEOUT_SECONDS=180`, reused as the Appium command timeout) and run the mobile suite isolated, not parallel with WASM, to avoid CPU contention.
- **Centralize boot-wait + dialog dismissal in one shared session helper.** When each suite carries its own near-identical boot-wait, only the one that dismisses dialogs is reliable and the rest flake behind overlays. Routing every suite through one helper makes "all UIs exercised through the same startup workflow" a maintenance property, not a copy-paste checklist.
- **Runner owns operator preconditions.** `src/Test/Test.Mobile/run-mobile-tests.ps1` discovers Android SDK, prepares process env, builds/restores the APK, starts or verifies the emulator, starts or verifies Appium, verifies UiAutomator2, sets `{APP}_MOBILE_TESTS_ENABLED=true`, runs `dotnet test`, and writes TRX. Test methods connect to prepared state and fail fast when that state is broken.

---

## Generated Code Intervention Rule

For generator-driven stacks (Uno, Kiota, Resizetizer, and similar toolchains):

- **Preserve generated conventions by default.** Do not rewrite generated bootstrap, host plumbing, or build targets unless a specific symptom proves the generated assumption is wrong.
- **Patch minimally.** Fix only the smallest confirmed incompatibility. One targeted MSBuild property override or one config fixup - not a full rewrite of the generated file.
- **Document the justification.** Every patch to generated code must carry an inline comment citing the exact symptom (e.g., `<!-- Workaround: Resizetizer 1.12.1 manifest-path bug -->`).

If you cannot identify the specific failing assumption, do not modify generated code - escalate to the engineer.

## Environment Detection Rule

When distinguishing browser, Electron, desktop-webview, or similar runtime environments, prefer **capability or runtime-object checks** over raw user-agent string matching. User-agent strings are unreliable in embedded browsers, IDE preview panes, and WebView2 hosts.

Example: check for `window.__TAURI__` or `navigator.userAgentData` rather than parsing `navigator.userAgent`.

---

## .NET for Android - Build & Deploy Rules

These rules apply when targeting any `<tfm>-android` Uno, MAUI, or bare .NET for Android target (where `<tfm>` is the project's pinned .NET TFM).

### Android SDK Discovery (Windows)

Before writing any `emulator`, `adb`, or SDK tool command, resolve the actual SDK root:

1. Check `ANDROID_HOME` / `ANDROID_SDK_ROOT` env vars.
2. If unset, check `C:\Program Files (x86)\Android\android-sdk` (Android Studio default) and `%LOCALAPPDATA%\Android\Sdk` (standalone SDK manager default).
3. Verify `emulator\emulator.exe` and `platform-tools\adb.exe` exist at the resolved path.
4. Set `ANDROID_HOME` explicitly in the shell session before invoking any SDK tools.

Do not assume SDK tools are on `PATH`.

Install requirements on Windows:

- Android Studio or command-line SDK tools.
- Android SDK Platform-Tools, Android Emulator, and a recent Android platform.
- A recent x64 or arm64 system image and an AVD.
- Hardware virtualization enabled in BIOS/Windows features.
- `dotnet workload install android` for Android builds.

### Embedded Assemblies for Sideloading

When building for manual ADB sideloading (`dotnet build` + `adb install`), always set in the Android TFM `PropertyGroup`:

```xml
<EmbedAssembliesIntoApk>true</EmbedAssembliesIntoApk>
<AndroidEnableAssemblyCompression>false</AndroidEnableAssemblyCompression>
<AndroidStoreUncompressedFileExtensions>.so;$(AndroidStoreUncompressedFileExtensions)</AndroidStoreUncompressedFileExtensions>
```

The default Debug mode uses **Fast Deployment**, which expects the .NET tooling to push managed assemblies to the device separately after install. A bare APK installed without that push crashes immediately with _"No assemblies found ... Assuming this is part of Fast Deployment"_. Lock this property into the project file permanently for any project that supports manual sideloading - do not rely on a command-line override.

When installing a built APK directly, prefer a full install:

```powershell
adb install --no-incremental -r "src/UI/{Project}.Uno/bin/Debug/$(LatestStableTfm)-android/{package-id}-Signed.apk"
```

If the app crashes before app code runs, collect logcat and classify the failure:

- `No assemblies found ... Assuming this is part of Fast Deployment`: APK was built/installed with fast-deployment assumptions. Fix the Android packaging properties above.
- `System.MethodAccessException` inside `Uno.UI.Xaml.Controls.NativeWindowWrapper`: check the NuGet asset graph first. A browserwasm-only restore can omit Android Skia runtime packages even when the Android build later succeeds.

### APK Selection, Install, and Boot Readiness

Hard-won rules for the install path - a test harness or setup script should encode these:

- **Pick the current APK, not a stale one.** A build can leave multiple signed APKs: the root `bin/Debug/{tfm}-android/{package-id}-Signed.apk` and per-RID copies under `bin/Debug/{tfm}-android/{rid}/`. Stale RID-folder APKs can advertise an old launch activity and silently install yesterday's build. Prefer the **root `{tfm}-android` signed APK when it is the newest**; fall back to a RID-folder APK only when it is genuinely newer (compare write times). Default local RID for the emulator is `android-x64`.
- **Embedded assemblies for sideload.** Manual `adb install` needs a complete APK (`EmbedAssembliesIntoApk=true`, above). That makes the APK much larger - plan emulator storage accordingly (next bullet).
- **`INSTALL_FAILED_INSUFFICIENT_STORAGE` is usually the AVD, not the APK.** The fix is the emulator's data partition, not the APK path. Use an AVD with at least a 10 GB data partition and wipe emulator data once. Do not chase APK-path theories when this is the error.
- **Install once per test process.** Install the app one time per run; do not reinstall before every test. Use Appium's reset behaviour or explicit `pm clear <package-id>` for fresh-onboarding state, not a reinstall loop.
- **Detect "already installed" tolerantly.** `adb shell pm path <package-id>` may return only `package:/data/app/.../base.apk` without echoing the package id. Treat **any** valid `package:` line as installed.
- **Reinstall on build change, not just on absence.** `pm path <package-id>` reports a stale build as "installed", so an install step that checks presence only silently runs yesterday's code after every rebuild. The factory must detect a changed build and reinstall: compute a cheap build identity from the APK file (size + last-write-time ticks; escalate to a content hash only if a build can rewrite the APK without changing either), persist it on the device with `adb push` to `/data/local/tmp/{app}-apk-<package-id>.id` (push, not `echo >` redirection - shell quoting differs across adb shells), and reinstall with `adb install -r -g` whenever the package is absent or the marker mismatches; `-r` covers both fresh install and in-place replace, so one path handles both. Do not rely on `dumpsys package ... lastUpdateTime` - its local-time string is awkward to compare against a file mtime. Keep an in-process installed-keys set so the device check runs at most once per test run.
- **Wait for the package manager, not just boot.** After a wipe or first boot of a Play Store AVD, `sys.boot_completed=1` can arrive before package services are stable. Poll `adb shell cmd package list packages` (or retry the install once on transient failure) before installing.

```powershell
# Prefer the newest valid signed APK (root over stale RID folders).
$apk = Get-ChildItem "src/UI/{Project}.Uno/bin/Debug/$(LatestStableTfm)-android" -Recurse -Filter '*-Signed.apk' |
       Sort-Object LastWriteTime -Descending | Select-Object -First 1
adb install --no-incremental -r $apk.FullName
```

### Emulator Host Networking

Apps running on the Android emulator that call local backend services must use `10.0.2.2` in place of `localhost` / `127.0.0.1`. Gate this with a compile-time check so WASM/desktop builds continue to use `localhost`:

```csharp
#if __ANDROID__
    const string LocalHost = "10.0.2.2";
#else
    const string LocalHost = "localhost";
#endif
```

Quick validation from emulator shell (no running service required):
```bash
adb shell "echo TEST | nc 10.0.2.2 <PORT>"
```

### Activity Class Name Discovery

.NET for Android generates a CRC-based Java class name for activities (e.g., `crc64<hash>.MainActivity`) that differs from the C# class name. Do not guess it from source.

When launching via `adb shell am start -n`, first resolve the registered launch activity. Prefer `resolve-activity --brief` (one clean line); fall back to `dumpsys` parsing:

```bash
# Preferred: prints "<package-id>/<activity>" directly.
adb shell cmd package resolve-activity --brief <package-id> | tail -n 1
# Fallback:
adb shell dumpsys package <package-id> | grep -A 3 "MAIN"
```

Use the class name from the output - the generated name cannot be predicted from C# source alone.

---

## Known Build Issues / Workarounds

### Resizetizer File Naming Rules

Uno.Resizetizer requires asset filenames to be **lowercase**, containing only alphanumeric characters or underscores, and starting/ending with a letter. Files like `SplashScreen.svg` or `my-icon.png` will fail the build.

### UnoSplashScreen WASM Build Failure (Resizetizer 1.12.1)

**Symptom:** Adding `<UnoSplashScreen Include="Assets\splashscreen.svg" />` causes `GenerateWasmSplashAssets` to fail silently on WASM. Even without `UnoSplashScreen`, ShellTask may crash with `DirectoryNotFoundException` on clean builds.

**Root cause:** Resizetizer line 529 constructs a fallback PWA manifest path using `GetFileName($(WasmPWAManifestFile))`. When `WasmPWAManifestFile` is unset, `GetFileName("")` returns empty, producing a bare directory path (`unoresizetizer\`). MSBuild `Exists()` returns true for directories, so `UnoResizetizerPwaManifest` gets set to a directory. ShellTask then calls `File.ReadAllText` on that directory and crashes.

**Workaround:** Add this target to the UI `.csproj`:

```xml
<!-- Workaround: Resizetizer 1.12.1 sets WasmPWAManifestFile to a directory
     path when no UnoSplashScreen is configured. Clear it so ShellTask doesn't
     call File.ReadAllText on a directory. -->
<Target Name="_FixWasmPwaManifestPath"
        BeforeTargets="GenerateUnoWasmAssets"
        AfterTargets="ProcessResizedImagesWasm"
        Condition="$(TargetFramework.Contains('browserwasm'))">
  <PropertyGroup>
    <WasmPWAManifestFile Condition="'$(WasmPWAManifestFile)' != '' AND !$([System.IO.File]::Exists('$(WasmPWAManifestFile)'))"></WasmPWAManifestFile>
  </PropertyGroup>
</Target>
```

**Important:** Do NOT place standalone splash screen asset files (`splashscreen.png`, `splashscreen.svg`) in Assets without a corresponding `<UnoSplashScreen>` item - the resizetizer will produce duplicate static web asset conflicts.

### ExtendedSplashScreen vs UnoSplashScreen

- `UnoSplashScreen` = native splash (Android/iOS) generated by Resizetizer. Broken on WASM in 1.12.1.
- `ExtendedSplashScreen` = Uno Toolkit XAML control in `ShellControl.xaml` for the in-app loading screen. This is the recommended WASM splash approach.
- The "Didn't find UnoSplashScreen" warning from Resizetizer is **harmless** - it just means no native splash is configured.

## CI Requirements

When the solution includes a Uno WASM project, CI workflows must install the `wasm-tools` workload before build. Add `android` when Android is in scope. Add iOS build jobs only on macOS runners.

```yaml
- name: Install required workloads
  run: dotnet workload install wasm-tools android
```

Without this, the build fails with `UNOWA0001: Native WebAssembly assets were detected, but the wasm-tools workload could not be located.`

Add this step after `actions/setup-dotnet@v4` and before `dotnet restore`. See [cicd.md](cicd.md) for the full CI template.
