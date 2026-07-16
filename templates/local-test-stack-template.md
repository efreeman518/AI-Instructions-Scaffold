# Template - Local Test Stack Script (one-shot session bootstrap)

| | |
|---|---|
| **Generates** | `eng/test/start-local-test-stack.ps1`, `tests/Test.Mobile/run-mobile-tests.ps1` when mobile exists, `.vscode/tasks.json` entries (optional) |
| **Requires** | Aspire AppHost; Uno WASM and/or Android targets when those test tiers are generated |
| **Phase** | 5c/5d - generate once the host(s) and the `WasmUI` / `Test.Mobile` / `Test.Aspire` tiers exist |
| **Protocol** | Operator tooling. The script mutates **process** environment only - it never edits machine/user PATH. |

---

## Generate only for selected capabilities

This script and its `.vscode/tasks.json` entries are **derived from the early Phase 2 capability pick** (see [Capability-Gated Test Tiers](../skills/testing.md#capability-gated-test-tiers-the-early-decision-drives-the-rest)). Emit only the branches and tasks for tiers that were actually generated: no Uno -> no WASM/mobile branches; no `useAspire` -> no AppHost branch. An `api-only` scaffold needs none of this - skip the script entirely. A filtered command may support fast iteration, but final acceptance remains unfiltered and serial: `dotnet test .\{SolutionName}.slnx --no-build -m:1`. The `-Skip*` switches below toggle *within* the set of branches that exist; they are not a substitute for omitting unselected capabilities at generation time.

## Why one script

WASM and Aspire tests need a running local stack (built artifacts, a started AppHost, browsers). Mobile needs a dedicated runner because Android build, emulator readiness, Appium readiness, enable flag, `dotnet test`, and TRX output must stay in one fail-fast lane. Generate `eng/test/start-local-test-stack.ps1` for Aspire/WASM and `tests/Test.Mobile/run-mobile-tests.ps1` for mobile. Print exact endpoints and rerun commands. Required Aspire-backed infrastructure is inconclusive only for explicit opt-out or failed Docker preflight; selected-lane toolchain/AppHost failures are red. Optional LiveAI performs its provider preflight before host creation per [ai-integration.md](../skills/ai-integration.md). Explicit mobile runner lanes fail fast when mobile prerequisites are broken.

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
    try { & dotnet @Arguments }
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
        throw "Refusing to remove outside ${resolvedRoot}: $resolvedTarget"
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
    $pw = Join-Path $repo "tests/Test.PlaywrightUI/bin/Debug/$tfm/playwright.ps1"
    if (Test-Path $pw) { & $pw install chromium } else { Warn 'playwright.ps1 not found - build Test.PlaywrightUI first' }
}

# 3. Start Aspire AppHost (background) - the WASM host and mobile gateway hang off it.
#    Path uses the actual AppHost project name in this solution.
if (-not $SkipAspire) {
    Step 'Starting Aspire AppHost'
    $env:{APP}_ASPIRE_STARTUP_TIMEOUT_SECONDS = "$AspireStartupTimeoutSeconds"
    Start-Process pwsh -ArgumentList @(
        '-NoProfile','-Command',
        "dotnet run --project `"$repo/src/Host/Aspire/AppHost/AppHost.csproj`""
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
    if (-not (Wait-Endpoint "https://localhost:$GatewayPort/health")) { throw 'gateway not ready before the local-stack deadline; inspect AppHost resource state and logs' }
}
if (-not $SkipWasm) {
    if ($WasmUrl) {
        Step 'Waiting for standalone WASM UI'
        if (-not (Wait-Endpoint $WasmUrl)) { throw 'WASM UI not ready before the local-stack deadline; inspect host and browser diagnostics' }
    } else {
        Warn 'WASM UI URL not probed here. AppHost-backed WasmUI tests resolve the UI resource URL from Aspire named endpoints.'
    }
}

# 5. Mobile is owned by tests/Test.Mobile/run-mobile-tests.ps1.
if (-not $SkipMobile) {
    Step 'Mobile runner'
    Write-Host 'Run: powershell -NoProfile -File tests/Test.Mobile/run-mobile-tests.ps1'
    Write-Host 'Use -SkipBuild after the APK has already been built by that runner.'
}

# 10. Print endpoints and manual rerun commands.
Step 'Stack ready'
Write-Host @"
  Gateway:  https://localhost:$GatewayPort
  WASM UI:  $(if ($WasmUrl) { $WasmUrl } else { 'resolved by WasmUI fixture from Aspire named endpoint' })
  Mobile:   use tests/Test.Mobile/run-mobile-tests.ps1 (Android gateway from emulator: http://10.0.2.2:$GatewayPort/)

  Rerun individual tiers:
    dotnet test .\{SolutionName}.slnx -m:1
    dotnet test tests/Test.Aspire/Test.Aspire.csproj -m:1 --filter TestCategory=Aspire
    dotnet test tests/Test.PlaywrightUI/Test.PlaywrightUI.csproj -m:1 --filter TestCategory=WasmUI
    powershell -NoProfile -File tests/Test.Mobile/run-mobile-tests.ps1 -SkipBuild
"@ -ForegroundColor Green
```

> For standalone manual browser runs, set `{APP}_WASM_BASE_URL` to the actual wrapper host URL from `launchSettings.json` or process output. AppHost-backed `WasmUI` tests do not use fixed localhost fallbacks; they resolve the UI resource URL from Aspire named endpoints. Pin the gateway port only for Android emulator `10.0.2.2:<port>` usage.

## VS Code tasks

Generate into `.vscode/tasks.json` so Test Explorer users have one-click stack control. WASM tasks call the C# MSTest wrapper, which starts AppHost and runs bounded TypeScript one project per child process; never call `npm`, `npx`, or unbounded `playwright test` directly from VS Code tasks. Each mobile task calls the generated runner, not raw `dotnet test`:

```jsonc
{
  "version": "2.0.0",
  "tasks": [
    { "label": "Start local test stack", "type": "shell", "command": "pwsh -File eng/test/start-local-test-stack.ps1" },
    { "label": "Build WASM", "type": "shell", "command": "pwsh -File eng/test/start-local-test-stack.ps1 -SkipAspire -SkipMobile" },
    { "label": "Install Playwright Chromium", "type": "shell", "command": "pwsh tests/Test.PlaywrightUI/bin/Debug/net{X}.0/playwright.ps1 install chromium" },
    { "label": "Test: Mobile with build", "type": "shell", "command": "powershell -NoProfile -File tests/Test.Mobile/run-mobile-tests.ps1" },
    { "label": "Test: full serial acceptance", "type": "shell", "command": "dotnet test .\\{SolutionName}.slnx -m:1", "group": { "kind": "test", "isDefault": true } },
    { "label": "Test: Aspire", "type": "shell", "command": "dotnet test tests/Test.Aspire/Test.Aspire.csproj -m:1 --filter TestCategory=Aspire" },
    { "label": "Test: WASM", "type": "shell", "command": "dotnet test tests/Test.PlaywrightUI/Test.PlaywrightUI.csproj -m:1 --filter TestCategory=WasmUI" },
    { "label": "Test: Mobile", "type": "shell", "command": "powershell -NoProfile -File tests/Test.Mobile/run-mobile-tests.ps1 -SkipBuild" }
  ]
}
```

## Mobile runner (`run-mobile-tests.ps1`)

This runner owns the whole Android lane end-to-end. Test methods only connect; the runner does everything else. Responsibilities:

- **Pre-flight probe before starting Appium**, printing the exact resolved path or state for each: Docker, Android SDK path, `adb`, `emulator`, the AVD list, Appium CLI, installed Appium drivers, device boot state, resolved package name, resolved launch activity. Fail fast (red) on any missing prerequisite - do not degrade to inconclusive once the runner is invoked.
- **SDK discovery.** Do not assume the default SDK path. Accept `-AndroidSdk`, else discover common Windows locations (for example `%LOCALAPPDATA%\Android\Sdk`, `C:\Program Files (x86)\Android\android-sdk`), then export both `ANDROID_HOME` and `ANDROID_SDK_ROOT` (process env only, per the hard rule above) before starting Appium.
- **Build** the Android package with `-p:BuildAllUnoTargets=true` and the `-android` TFM override.
- **Visible emulator (`-VisibleEmulator`).** A cold boot can take 10-15 min. Use a long boot timeout and print an "emulator booting visibly" status line so the wait is not read as a hang.
- **One scoped launch retry.** For the known transient Android launch failure only (exact `Cannot start` plus `never started`): force-stop the app, recreate the session, retry once. No broad retries. (Doctrine: `../skills/testing-quality.md` section Uno Mobile: Test Split.)
- Set `{APP}_MOBILE_TESTS_ENABLED=true`, run `dotnet test`, write TRX.

## Verification

- [ ] `eng/test/start-local-test-stack.ps1` exists and runs end-to-end on a clean session.
- [ ] script mutates **process** env only (no `setx`, no machine/user PATH edits).
- [ ] `tests/Test.Mobile/run-mobile-tests.ps1` exists when mobile tier exists.
- [ ] Mobile runner meets the responsibilities in section Mobile runner (`run-mobile-tests.ps1`): resource probe with exact paths, SDK discovery + `ANDROID_HOME`/`ANDROID_SDK_ROOT` export, Android build, visible cold-boot handling, one scoped launch retry, `{APP}_MOBILE_TESTS_ENABLED=true`, `dotnet test`, TRX.
- [ ] script prints exact endpoints per-tier rerun commands, including mobile runner command.
- [ ] `.vscode/tasks.json` entries exist for: start stack, build WASM, install Playwright, run full serial acceptance, run Aspire/WASM, run Mobile via `run-mobile-tests.ps1`.
