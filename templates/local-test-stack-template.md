# Template - Local Test Stack Script (one-shot session bootstrap)

| | |
|---|---|
| **Generates** | `eng/test/start-local-test-stack.ps1`, `.vscode/tasks.json` entries (optional) |
| **Requires** | Aspire AppHost; Uno WASM and/or Android targets when those test tiers are generated |
| **Phase** | 5c/5d - generate once the host(s) and the `WasmUI` / `Test.Mobile` / `Test.Aspire` tiers exist |
| **Protocol** | Operator tooling. The script mutates **process** environment only - it never edits machine/user PATH. |

---

## Generate only for selected capabilities

This script and its `.vscode/tasks.json` entries are **derived from the early Phase 2 capability pick** (see [Capability-Gated Test Tiers](../skills/testing.md#capability-gated-test-tiers-the-early-decision-drives-the-rest)). Emit only the branches and tasks for tiers that were actually generated: no Uno -> no WASM/mobile branches; no `useAspire` -> no AppHost branch. An `api-only` scaffold needs none of this - skip the script entirely (a plain `dotnet test --filter "TestCategory!=Load"` suffices). The `-Skip*` switches below toggle *within* the set of branches that exist; they are not a substitute for omitting unselected capabilities at generation time.

## Why one script

WASM, mobile, and Aspire tests each need a running local stack (built artifacts, a started AppHost, browsers, an emulator, Appium). Scattering those steps across class comments means every developer re-derives them. Generate a single re-runnable bootstrap that brings the stack up, verifies prerequisites, and prints the exact endpoints and rerun commands. Run it once per session; the heavy test tiers then self-skip (`Inconclusive`) only if something it could not provide is still missing.

**Hard rule:** process-env only. The script sets `$env:PATH`, `ANDROID_HOME`, endpoint vars for the current process tree (and child test runs it launches). It must not call `setx` or edit machine/user PATH. A developer who never runs the script must still be able to build and run the app.

The generated `WasmUI` test fixture must still be self-sufficient for Visual Studio Test Explorer: if Docker is running, it starts the Aspire testing graph, resolves dynamic endpoints, and runs. This script is the ergonomic "start everything once" path, not a hidden enable flag.

## File: `eng/test/start-local-test-stack.ps1`

```powershell
#requires -Version 7
<#
  start-local-test-stack.ps1 - one-shot local test stack bootstrap for {ProjectName}.
  Process-env only: never edits machine/user PATH. Re-runnable and idempotent.
  Use the -Skip* switches to bring up only the tiers you need.
#>
[CmdletBinding()]
param(
    [switch]$SkipAspire,
    [switch]$SkipWasm,
    [switch]$SkipMobile,
    [int]$GatewayPort = 8080,
    [string]$WasmUrl = $env:{APP}_WASM_BASE_URL,
    [string]$Avd = $env:{APP}_ANDROID_AVD,
    [int]$AspireStartupTimeoutSeconds = 900
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot/../..").Path
$tfm  = 'net{X}.0'   # the solution's pinned TFM
$configuration = 'Debug'
$wasmTfm = "$tfm-browserwasm"
$wasmProject = Join-Path $repo "src/UI/{Project}.Uno/{Project}.Uno.csproj"
$wasmProjectRoot = Split-Path $wasmProject -Parent
$wasmStamp = Join-Path $wasmProjectRoot "bin/$configuration/$wasmTfm/.{app}-wasm-test-build.stamp"

function Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Warn($m) { Write-Host "  ! $m" -ForegroundColor Yellow }
function Invoke-DotNetCleanEnv([string[]]$Arguments) {
    $profileVars = @(
        'CORECLR_PROFILER',
        'CORECLR_PROFILER_PATH',
        'CORECLR_PROFILER_PATH_32',
        'CORECLR_PROFILER_PATH_64',
        'COR_PROFILER',
        'COR_PROFILER_PATH',
        'COR_PROFILER_PATH_32',
        'COR_PROFILER_PATH_64',
        'COVERLET_ENABLE_PROFILING',
        'COVERLET_PROFILER_PATH'
    )
    $saved = @{}
    foreach ($name in $profileVars) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process'); Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
    $saved['CORECLR_ENABLE_PROFILING'] = $env:CORECLR_ENABLE_PROFILING
    $saved['COR_ENABLE_PROFILING'] = $env:COR_ENABLE_PROFILING
    $saved['MSBUILDDISABLENODEREUSE'] = $env:MSBUILDDISABLENODEREUSE
    $saved['DOTNET_CLI_TELEMETRY_OPTOUT'] = $env:DOTNET_CLI_TELEMETRY_OPTOUT
    $saved['DOTNET_NOLOGO'] = $env:DOTNET_NOLOGO
    $env:CORECLR_ENABLE_PROFILING = '0'
    $env:COR_ENABLE_PROFILING = '0'
    $env:MSBUILDDISABLENODEREUSE = '1'
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    $env:DOTNET_NOLOGO = '1'
    try { & rtk dotnet @Arguments }
    finally {
        foreach ($name in $saved.Keys) {
            if ($null -eq $saved[$name]) { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
            else { Set-Item "Env:$name" $saved[$name] }
        }
    }
    if ($LASTEXITCODE -ne 0) { throw "dotnet $($Arguments -join ' ') failed with exit code $LASTEXITCODE" }
}
function Remove-Under([string]$Target, [string]$AllowedRoot) {
    $resolvedTarget = [IO.Path]::GetFullPath($Target)
    $resolvedRoot = [IO.Path]::GetFullPath($AllowedRoot)
    $prefix = if ($resolvedRoot.EndsWith([IO.Path]::DirectorySeparatorChar)) { $resolvedRoot } else { $resolvedRoot + [IO.Path]::DirectorySeparatorChar }
    if (-not $resolvedTarget.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove outside $resolvedRoot: $resolvedTarget"
    }
    if (Test-Path $resolvedTarget) { Remove-Item -LiteralPath $resolvedTarget -Recurse -Force }
}

# 1. Build required app artifacts (fresh WASM output so Playwright never loads a stale build).
if (-not $SkipWasm) {
    Step 'Building Uno WASM target'
    $freshBin = Join-Path $wasmProjectRoot "bin/$configuration/$wasmTfm"
    $freshObj = Join-Path $wasmProjectRoot "obj/$configuration/$wasmTfm"
    $stale = Join-Path $wasmProjectRoot "bin/$configuration/browser-wasm"
    foreach ($path in @($freshBin, $freshObj, $stale)) {
        if (Test-Path $path) { Warn "removing stale $path" }
    }
    Remove-Under $freshBin (Join-Path $wasmProjectRoot 'bin')
    Remove-Under $freshObj (Join-Path $wasmProjectRoot 'obj')
    Remove-Under $stale (Join-Path $wasmProjectRoot 'bin')
    Invoke-DotNetCleanEnv @('restore', $wasmProject, '-p:BuildAllUnoTargets=true', '-p:EnableUnoWasm=true', '--disable-build-servers')
    Invoke-DotNetCleanEnv @('build', $wasmProject, "-p:TargetFrameworkOverride=$wasmTfm", '-p:EnableUnoWasm=true', "-p:Configuration=$configuration", '--no-restore', '-m:1', '--disable-build-servers')
    New-Item -ItemType Directory -Force -Path (Split-Path $wasmStamp -Parent) | Out-Null
    Set-Content -Path $wasmStamp -Value ([DateTimeOffset]::UtcNow.ToString('O'))
}

# 2. Install Playwright browsers if missing.
if (-not $SkipWasm) {
    Step 'Ensuring Playwright Chromium'
    $pw = Join-Path $repo "src/Test/Test.PlaywrightUI/bin/Debug/$tfm/playwright.ps1"
    if (Test-Path $pw) { & $pw install chromium } else { Warn 'playwright.ps1 not found - build Test.PlaywrightUI first' }
}

# 3. Start Aspire AppHost (background) - the WASM host and mobile gateway hang off it.
#    Path uses the actual AppHost project name in this solution.
if (-not $SkipAspire) {
    Step 'Starting Aspire AppHost'
    $env:{APP}_ASPIRE_STARTUP_TIMEOUT_SECONDS = "$AspireStartupTimeoutSeconds"
    Start-Process pwsh -ArgumentList @(
        '-NoProfile','-Command',
        "rtk dotnet run --project `"$repo/src/Host/Aspire/AppHost/AppHost.csproj`""
    ) | Out-Null
}

# 4. Wait for gateway + WASM UI endpoints.
function Wait-Endpoint($url, $seconds = 180) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        try { if ((Invoke-WebRequest $url -SkipCertificateCheck -TimeoutSec 5).StatusCode -lt 500) { return $true } } catch { }
        Start-Sleep -Seconds 3
    }
    return $false
}
if (-not $SkipAspire) {
    Step 'Waiting for gateway'
    if (-not (Wait-Endpoint "https://localhost:$GatewayPort/health")) { Warn 'gateway not ready - Aspire tests will mark Inconclusive' }
}
if (-not $SkipWasm) {
    if ($WasmUrl) {
        Step 'Waiting for standalone WASM UI'
        if (-not (Wait-Endpoint $WasmUrl)) { Warn 'WASM UI not ready - WasmUI tests will mark Inconclusive' }
    } else {
        Warn 'WASM UI URL not probed here. AppHost-backed WasmUI tests resolve the UI resource URL from Aspire named endpoints.'
    }
}

# 5-9. Android: discover SDK, mutate PROCESS PATH, verify Appium, start emulator, wait for boot.
if (-not $SkipMobile) {
    Step 'Resolving Android SDK'
    $sdk = @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT,
             'C:\Program Files (x86)\Android\android-sdk',
             (Join-Path $env:LOCALAPPDATA 'Android\Sdk')) |
           Where-Object { $_ -and (Test-Path (Join-Path $_ 'platform-tools\adb.exe')) } |
           Select-Object -First 1
    if (-not $sdk) { Warn 'Android SDK not found - Mobile tests will mark Inconclusive'; }
    else {
        $env:ANDROID_HOME = $sdk; $env:ANDROID_SDK_ROOT = $sdk
        # PROCESS PATH ONLY - never setx.
        $env:PATH = "$sdk\platform-tools;$sdk\emulator;$env:PATH"

        Step 'Verifying Appium uiautomator2'
        if (-not ((appium driver list --installed 2>$null) -match 'uiautomator2')) { rtk appium driver install uiautomator2 }

        Step 'Ensuring Appium server (127.0.0.1:4723)'
        try { $null = Invoke-WebRequest 'http://127.0.0.1:4723/status' -TimeoutSec 3 }
        catch { Start-Process pwsh -ArgumentList '-NoProfile','-Command','rtk appium --address 127.0.0.1 --port 4723' | Out-Null }

        Step 'Ensuring an online emulator'
        if (-not ((adb devices) -match 'device$')) {
            $avd = if ($Avd) { $Avd } else { (emulator -list-avds | Select-Object -First 1) }
            if ($avd) {
                Start-Process emulator -ArgumentList "-avd",$avd | Out-Null
                Step "Booting $avd - waiting for sys.boot_completed"
                adb wait-for-device
                $deadline = (Get-Date).AddMinutes(5)
                while ((Get-Date) -lt $deadline) {
                    if ((adb shell getprop sys.boot_completed 2>$null).Trim() -eq '1') { break }
                    Start-Sleep -Seconds 3
                }
                # sys.boot_completed=1 can precede package-manager readiness; poll `pm` before installing.
                Step 'Waiting for package manager'
                $deadline = (Get-Date).AddMinutes(2)
                while ((Get-Date) -lt $deadline) {
                    if ((adb shell cmd package list packages 2>$null) -match 'package:') { break }
                    Start-Sleep -Seconds 2
                }
            } else { Warn 'no AVD found - create one in Android Studio' }
        }
    }
}

# 10. Print endpoints and manual rerun commands.
Step 'Stack ready'
Write-Host @"
  Gateway:  https://localhost:$GatewayPort
  WASM UI:  $(if ($WasmUrl) { $WasmUrl } else { 'resolved by WasmUI fixture from Aspire named endpoint' })
  Appium:   http://127.0.0.1:4723  (Android gateway from emulator: http://10.0.2.2:$GatewayPort/)

  Rerun individual tiers:
    rtk dotnet test .\{SolutionName}.slnx --filter "TestCategory!=Load"
    rtk dotnet test src/Test/Test.Aspire/Test.Aspire.csproj           --filter TestCategory=Aspire
    rtk dotnet test src/Test/Test.PlaywrightUI/Test.PlaywrightUI.csproj --filter TestCategory=WasmUI
    rtk dotnet test src/Test/Test.Mobile/Test.Mobile.csproj           --filter TestCategory=MobileUI
"@ -ForegroundColor Green
```

> For standalone manual browser runs, set `{APP}_WASM_BASE_URL` to the wrapper host URL from `launchSettings.json` (the Uno default in this scaffold is `https://localhost:7069`; see [../skills/ui-uno-platforms.md](../skills/ui-uno-platforms.md) Port Exclusion). AppHost-backed `WasmUI` tests do not use this fixed port; they resolve the UI resource URL from Aspire named endpoints. Pin the gateway port only for Android emulator `10.0.2.2:<port>` usage.

## VS Code tasks

Generate these into `.vscode/tasks.json` so Test Explorer users have one-click stack control. Each task is a thin wrapper over the script or a single `dotnet test`/build command:

```jsonc
{
  "version": "2.0.0",
  "tasks": [
    { "label": "Start local test stack", "type": "shell", "command": "pwsh -File eng/test/start-local-test-stack.ps1" },
    { "label": "Build WASM",            "type": "shell", "command": "pwsh -File eng/test/start-local-test-stack.ps1 -SkipAspire -SkipMobile" },
    { "label": "Install Playwright Chromium", "type": "shell", "command": "pwsh src/Test/Test.PlaywrightUI/bin/Debug/net{X}.0/playwright.ps1 install chromium" },
    { "label": "Build Android APK",     "type": "shell", "command": "rtk dotnet restore src/UI/{Project}.Uno/{Project}.Uno.csproj -p:BuildAllUnoTargets=true; rtk dotnet build src/UI/{Project}.Uno/{Project}.Uno.csproj -p:TargetFrameworkOverride=net{X}.0-android -p:EnableUnoMobileTargets=true --no-restore -m:1" },
    { "label": "Test: all non-load",    "type": "shell", "command": "rtk dotnet test .\\{SolutionName}.slnx --filter \"TestCategory!=Load\"", "group": { "kind": "test", "isDefault": true } },
    { "label": "Test: Aspire",          "type": "shell", "command": "rtk dotnet test src/Test/Test.Aspire/Test.Aspire.csproj --filter TestCategory=Aspire" },
    { "label": "Test: WASM",            "type": "shell", "command": "rtk dotnet test src/Test/Test.PlaywrightUI/Test.PlaywrightUI.csproj --filter TestCategory=WasmUI" },
    { "label": "Test: Mobile",          "type": "shell", "command": "rtk dotnet test src/Test/Test.Mobile/Test.Mobile.csproj --filter TestCategory=MobileUI" }
  ]
}
```

## Verification

- [ ] `eng/test/start-local-test-stack.ps1` exists and runs end-to-end on a clean session.
- [ ] The script mutates **process** env only (no `setx`, no machine/user PATH edits).
- [ ] Android SDK is resolved from `ANDROID_HOME` / `ANDROID_SDK_ROOT` / Program Files / `%LOCALAPPDATA%\Android\Sdk`, and `platform-tools` + `emulator` are added to the process PATH.
- [ ] Appium `uiautomator2` is verified/installed and the server is started if not already listening on `127.0.0.1:4723`.
- [ ] After first boot, the script waits for package-manager readiness, not just `sys.boot_completed=1`.
- [ ] The script prints exact endpoints and per-tier rerun commands.
- [ ] `.vscode/tasks.json` entries exist for: start stack, build WASM, install Playwright, build APK, run non-load, run Aspire/WASM/Mobile.
