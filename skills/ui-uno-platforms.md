# Uno Platform UI - Platform-Specific Rules

Platform-specific build, deploy, and debugging rules for Uno (WASM, Android), plus CI requirements. Loaded during Phase 5c when an Uno UI project is in scope and a specific target needs attention.

Companion files:
- [ui-uno.md](ui-uno.md) - index + decision table
- [ui-uno-shell.md](ui-uno-shell.md) - project setup, app hosting, shell control
- [ui-uno-mvux.md](ui-uno-mvux.md) - MVUX models, routing, XAML, business services, auth

---

## Platform Target Build Rules

Build one Uno target at a time. The project owns target selection through `TargetFrameworkOverride`; do not pass `-f`.

When the Uno project defaults to a fast single target such as browserwasm, restore all enabled Uno targets before Android/iOS package builds. `TargetFrameworkOverride` on build is not enough if `project.assets.json` was last restored for browserwasm only; the Android package can miss `Uno.WinUI.Runtime.Skia.Android` and crash before app code runs.

```powershell
dotnet restore src/UI/{Project}.Uno/{Project}.Uno.csproj -p:BuildAllUnoTargets=true
dotnet build src/UI/{Project}.Uno/{Project}.Uno.csproj -p:TargetFrameworkOverride=$(LatestStableTfm)-browserwasm --no-restore -m:1
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
rtk dotnet build src/UI/{Project}.Uno/{Project}.Uno.csproj -f net{X}.0-browserwasm -p:EnableUnoWasm=true
```

If a `browser-wasm/` sibling lingers, delete it so it cannot win asset resolution. The local test stack script ([../templates/local-test-stack-template.md](../templates/local-test-stack-template.md)) does this build step for you.

---

## Playwright Testing Against Uno WASM

These rules apply to `Test.PlaywrightUI` tests that drive a running Uno WASM host.

### Boot Once Per Describe Block

WASM cold-start takes 20-45 seconds. Never use the default `{ page }` Playwright fixture for Uno tests - it boots a new page per test and compounds wall-clock time.

Use `test.describe.configure({ mode: "serial" })` with a shared `BrowserContext`/`Page` created in `beforeAll`. Call `waitForApp(sharedPage)` once in `beforeAll`, then reuse `sharedPage` across all tests in the block. Re-call `waitForApp` after in-test navigation - it re-checks without a full re-boot.

```typescript
test.describe("EntityCrud", () => {
  test.describe.configure({ mode: "serial" });

  test.beforeAll(async ({ browser }) => {
    const context = await browser.newContext({ ignoreHTTPSErrors: true });
    sharedPage = await context.newPage();
    await sharedPage.goto("https://localhost:7069");
    await waitForApp(sharedPage);
  });
});
```

`test.use({ viewport })` does **not** apply to a `beforeAll`-owned context. Pass viewport directly:

```typescript
context = await browser.newContext({ viewport: { width: 390, height: 844 }, ignoreHTTPSErrors: true });
```

Set `--timeout=120000` on any suite containing Uno WASM cold-start:

```json
"test:full": "npx playwright test --retries=0 --max-failures=4 --timeout=120000"
```

### Renderer Decides the Strategy

Uno WASM ships two renderers and they need different test strategies:

- **Managed/native DOM renderer** - controls map to DOM elements with `xamltype` / `xamlautomationid`. Use the coordinate-click approach below.
- **Skia canvas renderer** - the app paints into a single `<canvas>` with **no per-control DOM**. DOM/text/role selectors return nothing and coordinate-clicking by scanning DOM text is impossible. Use the WASM canvas test bridge instead (see below); do not try to coordinate-click a canvas.

Detect once: in the running app's console run `document.querySelectorAll('[xamltype]').length`. `0` with a lone `<canvas>` present means Skia.

### Coordinate-Click for Invisible Elements (managed-DOM renderer)

Standard Playwright visibility checks and `.click()` fail on Uno's canvas/shadow DOM. Use `getBoundingClientRect()` via `page.evaluate()` and `page.mouse.click()`. Retry in a loop since elements render asynchronously:

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

Filter by a known text prefix (e.g. `"E2E-"`) to avoid hitting status chips or other `<p>` elements that overlap the target.

### Canvas Test Bridge (Skia renderer)

When the app paints to a Skia canvas, there is nothing to coordinate-click. Scaffold a **browser-only test bridge** that publishes app state to `globalThis.__{app}TestState` and let Playwright wait on state, not DOM. The bridge is query-string gated (`?{app}TestMode=true`), default-off, browser-target only, and uses **real** Gateway local auth (no injected token). Full shape, contract, and a state-polling Playwright test: [../templates/uno-wasm-test-bridge-template.md](../templates/uno-wasm-test-bridge-template.md). Tag these tests `[TestCategory("WasmUI")]`.

### Slow Router After Many Navigations

After several in-session navigations, the WASM router can lag. Increase assertion timeouts for pages loaded later in the shared-page lifecycle (use 60 s after 3+ prior navigations).

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
appium
```

`Test.Mobile` exists only when `includeUnoUI` was selected in Phase 2 (see [Capability-Gated Test Tiers](testing.md#capability-gated-test-tiers-the-early-decision-drives-the-rest)). When it is generated, it **runs by default** with a local false-only opt-out: discoverable in Test Explorer, self-marking `Assert.Inconclusive` - never red - when no emulator/device is online, Appium is not listening, or `{APP}_MOBILE_TESTS_ENABLED=false`. The `Inconclusive` message must name the missing prerequisite and the fix (run `eng/test/start-local-test-stack.ps1`). Do not require an enable flag to turn the tier on.

```powershell
$env:{APP}_MOBILE_TESTS_ENABLED = "false"   # opt OUT; default (unset) runs the suite
$env:{APP}_MOBILE_PLATFORM = "Android"
$env:{APP}_ANDROID_APP_PATH = "src/UI/{Project}.Uno/bin/Debug/$(LatestStableTfm)-android/{package-id}-Signed.apk"
dotnet test src/Test/Test.Mobile/Test.Mobile.csproj --filter TestCategory=MobileUI
```

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
