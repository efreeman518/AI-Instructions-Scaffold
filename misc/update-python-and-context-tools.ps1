#Requires -Version 5.1
<#
.SYNOPSIS
  Idempotent setup: clean Python environment, update RTK, Headroom, and the
  knowledge-graph tool (graphify) to LATEST stable versions resolved at runtime,
  disable all telemetry, and configure all agent harnesses
  (Claude Code, Codex, Copilot).

  Safe to re-run at any time. headroom-ai resolves to the latest release that has
  a Windows-installable wheel for a SUPPORTED Python ABI (cp312/cp313 today; NOT
  cp314) and never triggers a source build. graphify installs globally through
  the official uv tool flow (`uv tool install graphifyy`).

  This script updates the CONTEXT TOOLS only. It does NOT install or update the
  agent harnesses themselves (Claude Code, Codex, Copilot CLIs / extensions /
  desktop apps) - those self-update, and a given machine may deliberately run only
  some of them. The script configures whichever harnesses are present and skips
  the rest.

.PARAMETERS
  -DryRun              Audit all actions without making changes.
  -SkipPythonUpdate    Skip the Python Install Manager update step.
  -SkipVersionCheck    Use fallback versions instead of querying upstream.
  -HeadroomTimeout <n> Seconds to wait for headroom --version before giving up.
                       Default: 0 (wait forever). Pass 30 to cap cold-start waits.
  -ConfigureVsCodeGlobal  Also add the graphify global steering entry to VS Code user
                       settings.json (github.copilot.chat.codeGeneration.instructions).
                       Off by default because the write JSON-normalizes that file
                       (strips comments/formatting); without it the script only WARNS
                       with the exact entry to paste. See PHASE 8b.

.FALLBACK VERSIONS (used only when -SkipVersionCheck or a network query fails)
  headroom-ai : 0.20.15
  RTK         : 0.38.0
  graphify    : resolved live from PyPI; no pin (pure-Python, upgrade-in-place)

.PYTHON ABI NOTE
  headroom-ai ships cp312/cp313 wheels only - it has NO cp314 wheel as of 0.22.x.
  The Headroom runtime venv MUST be built on Python <= 3.13. The base-Python
  resolver below explicitly prefers the newest installed Python that is <= 3.13
  and refuses 3.14+. If only Python 3.14+ is present, a Headroom rebuild cannot
  succeed and the script warns loudly. graphify has no such limit - it prefers
  the newest Python available.

.TOOLING STRATEGY - two activation models

  This script installs THREE context tools machine-wide, but they fall into two
  groups with deliberately different activation models. Understand the split:

  GROUP A - rtk + headroom: AUTO-ENABLED, MACHINE-GLOBAL, ALWAYS ON
    - rtk      compresses CLI command output (Bash tool calls).
    - headroom compresses prompt inputs (tool output, history) via a local proxy.
    - This script wires both into every agent harness (Claude Code, Codex, Copilot):
      rtk hooks + RTK.md, headroom ANTHROPIC_BASE_URL/OPENAI_BASE_URL routing.
    - They apply to EVERY repo, EVERY session, with zero per-repo action.
    - Safe to apply blindly: universal, no per-repo cost or judgment call.
    - rtk's output compression is lossless; headroom is lossy by default, bypassable
      via --no-optimize / passthrough when exact output matters.

  GROUP B - graphify: GLOBAL STEERING auto-wired here; the GRAPH itself is OPT-IN PER REPO
    - The knowledge-graph tool. Lets an agent query code/doc relationships instead of
      grepping and reading raw files. It sits UPSTREAM of rtk/headroom (it reduces
      WHAT gets loaded; rtk/headroom compress what still does). No overlap.
    - graphify splits into a GLOBAL half (done here, machine-wide, idempotent) and a
      PER-REPO half (opt-in, done in the target repo):
        GLOBAL (this script - Phase 7 installs the CLI, Phase 8b wires steering):
          1. Install the CLI:             uv tool install graphifyy
          2. Install the /graphify skill: graphify install --platform claude; graphify copilot install
          3. Wire CONDITIONAL steering into each harness' GLOBAL config (hand-written here):
             - ~/.claude/CLAUDE.md + ~/.codex/AGENTS.md  (a "## graphify graph usage" block)
             - ~/.claude/settings.json                   (a PreToolUse grep-steering hook)
             - VS Code user settings.json                (only with -ConfigureVsCodeGlobal; else warns)
             ALL of it is GUARDED on `graphify-out/graph.json` existing in the working dir,
             so it stays INERT in every repo until that repo builds a graph. graphify's own
             `graphify <h> install` is deliberately NOT used for this: it writes the CURRENT
             REPO's TRACKED files (verified) and emits an unconditional block, so the global
             steering is hand-written here instead.
        PER-REPO (NOT done here - opt-in; see misc/apply-graphify-to-repo.txt):
          4. Enable repo harnesses (optional): graphify claude install --project, etc.
          5. Build the graph:                  graphify . from the repo root
    - The GRAPH is opt-in because it carries per-repo cost (build time, model spend on the
      doc layer, an artifact to maintain) and a per-repo CHOICE of layer (see below).
      Auto-building everywhere would burn that cost on repos where it does not pay. The
      GLOBAL steering is safe to wire everywhere precisely because it stays inert until a
      graph exists. To strip graphify wiring that leaked into a repo's tracked files, use
      misc/strip-graphify-repo-wiring.ps1.

  WHICH GRAPHIFY MODE (per repo, by LOC ratio)
    graphify is the single graph tool. The only per-repo decision is which LAYER to
    build, not which tool. Measure, excluding generated/transient files:
      KNOWLEDGE = LOC of .scaffold/ + docs/*.md
      CODE      = LOC of application src/ (*.cs,*.razor,*.ts,*.tsx,*.xaml)
      (.instructions/ and HANDOFF.md are excluded from measurement AND graph corpus:
       generic scaffold payload / transient resume state - see support/context-tooling.md)

      KNOWLEDGE >= CODE .............................. full (AST + semantic LLM)
      CODE > KNOWLEDGE but CODE < 3x KNOWLEDGE ....... full (AST + semantic LLM)
      CODE >= 3x KNOWLEDGE ........................... structure-only (AST, no LLM)
      No .scaffold/ and no docs/*.md ................. structure-only (AST, no LLM)
      Brownfield adoption (src/ exists, no .scaffold/) structure-only; re-eval after Phase 1

    WHY: the FULL layer adds LLM semantic extraction of markdown/YAML/infra on top of
    tree-sitter AST parsing - it sees the whole corpus, including the .scaffold/ +
    docs/ knowledge layer and .razor/.xaml markup, but spends model tokens. In a
    Claude Code / Claude VS Code session the host Claude session does that extraction
    directly - NO API key. Headless/CI uses Gemini via GEMINI_API_KEY/GOOGLE_API_KEY (or
    --backend on 'graphify extract'). The STRUCTURE-ONLY layer is AST-only, 100% local,
    zero model spend - blind to docs/YAML/markup but free. The choice is a deliberate
    cost/coverage call, not forced by key availability: a freshly scaffolded app is
    knowledge-heavy -> full; a mature app where code dwarfs the static doc layer ->
    structure-only, with an occasional full pass for spec<->code checks.

    Build at PHASE BOUNDARIES, not continuously (after Phase 1, after Phase 4, after a
    stabilized Phase 5 slice via 'graphify update .'). Drift rule: when artifact and
    code disagree, code wins - fix the artifact, then re-extract the affected slice.

  WHERE THE GUIDANCE LIVES (mirrors the activation split)
    - rtk/headroom: ambient rules in CLAUDE.md / agent.md (always loaded).
    - graphify     : support/context-tooling.md, behind a START-AI.md pointer
                    (consulted per repo when deciding whether/which layer to build).

  PYTHON ABI NOTE (also see .PYTHON ABI NOTE above)
    headroom-ai = cp312/cp313 wheels only (no cp314); runtime venv builds on
    Python <= 3.13. graphify is installed with uv as a global tool (pure-Python,
    prefers the newest Python available).

  PROMPT TO ENABLE GRAPHIFY IN A REPO USING SCAFFOLD INSTRUCTIONS
    Per support/context-tooling.md, measure the LOC ratio for this repo,
    recommend the structure-only or full graphify layer, and if I approve,
    initialize it: write .graphifyignore, optionally enable claude/codex/copilot,
    then build the graph (graphify . for the full layer, or the structure-only
    path) to produce graphify-out/graph.json. Optionally run 'graphify hook install'
    to auto-rebuild the code layer on every commit (harness-agnostic, AST-only,
    no extra commit; hook is untracked so it does not leak into scaffolded apps).

.NOTES
  - Run from a fresh PowerShell, not inside an activated .venv.
  - Does NOT require Administrator for the user-global path.
  - Headroom proxy is stopped before update and restarted after.
  - Restart Claude Code, Codex, and any IDE after this script so they
    inherit the updated setx env vars.

.REFERENCE
  - https://github.com/rtk-ai/rtk
  - https://github.com/chopratejas/headroom
  - https://github.com/safishamsi/graphify
#>

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$SkipPythonUpdate,
    [switch]$SkipVersionCheck,
    [int]$HeadroomTimeout = 0,  # 0 = wait forever; pass e.g. 30 to cap cold-start waits
    [switch]$ConfigureVsCodeGlobal  # opt-in: also add graphify steering to VS Code user settings.json (JSON-normalizes the file)
)

$ErrorActionPreference = "Continue"
Set-StrictMode -Off

# Suppress headroom telemetry in this session immediately - before any headroom call
$env:HEADROOM_TELEMETRY         = "off"
$env:HEADROOM_REQUIRE_RUST_CORE = "false"

# -- Fallback versions - used only if live upstream queries fail ----------------
$FallbackHeadroomVersion = "0.20.15"
$FallbackRtkVersion      = "0.38.0"

# -- Fixed config ---------------------------------------------------------------
$ProxyPort       = 8787
$RtkBinDir       = "$env:USERPROFILE\.local\bin"      # stable user bin dir for rtk, headroom, and uv tool shims
$HeadroomRoot    = "$env:USERPROFILE\.headroom"       # headroom home: runtime, shim scripts, config
$HeadroomRuntime = "$HeadroomRoot\runtime"            # isolated Python venv for headroom-ai
$PackageSpec     = "$HeadroomRoot\package-spec.txt"   # records the pinned headroom-ai version
$RunProxyCmd     = "$HeadroomRoot\run-proxy.cmd"      # full proxy launcher (used by shortcuts)
$EnsureProxyCmd  = "$HeadroomRoot\headroom-proxy-ensure.cmd"  # lightweight hook (used by Copilot/Codex)
$HeadroomShim    = "$RtkBinDir\headroom.cmd"          # user-facing headroom command shim
$ShimPs1         = "$HeadroomRoot\headroom-shim.ps1"  # PowerShell backend for the shim

$GraphifyPackage = "graphifyy"                        # PyPI package; CLI command is graphify

# -- Output helpers -------------------------------------------------------------
function Write-Step ([string]$m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Write-OK   ([string]$m) { Write-Host "  OK  : $m"  -ForegroundColor Green }
function Write-Warn ([string]$m) { Write-Host "  WARN: $m"  -ForegroundColor Yellow }
function Write-Fail ([string]$m) { Write-Host "  FAIL: $m"  -ForegroundColor Red }
function Write-Info ([string]$m) { Write-Host "  $m" }

# Wraps any action block - prints a dry-run notice instead of executing when -DryRun is set
function Invoke-Maybe ([scriptblock]$sb, [string]$desc) {
    if ($DryRun) { Write-Host "  [DryRun] $desc" -ForegroundColor DarkGray; return }
    & $sb
}

# Returns $true if version string $a is >= version string $b (strips non-numeric prefixes)
function Test-VersionGte ([string]$a, [string]$b) {
    try {
        $va = [version]($a -replace '^[^\d]*')
        $vb = [version]($b -replace '^[^\d]*')
        return ($va -ge $vb)
    } catch { return $false }
}

# Resolves the newest installed Python whose minor version is <= $MaxMinor.
# Used to keep the Headroom runtime on a Python with an installable wheel ABI
# (headroom-ai = cp312/cp313 only; passing -MaxMinor 13 refuses 3.14+).
# Pass -MaxMinor 0 for "newest available, no cap" (used by graphify, pure-Python).
# Returns the python.exe path, or $null if none qualifies.
function Resolve-PythonBase ([int]$MaxMinor = 0) {
    $candidates = @()

    # Enumerate via the py launcher (-0p lists installed runtimes with paths)
    try {
        $lines = & py -0p 2>$null
        foreach ($ln in $lines) {
            if ($ln -match '-V:3\.(\d+)\D.*?([A-Za-z]:\\[^\s].*python\.exe)') {
                $candidates += [pscustomobject]@{ Minor = [int]$Matches[1]; Path = $Matches[2].Trim() }
            }
        }
    } catch { }

    # Add common install locations as fallback discovery
    foreach ($glob in @(
        "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe",
        "C:\Python3*\python.exe"
    )) {
        Get-ChildItem -Path $glob -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.DirectoryName -match 'Python3(\d+)') {
                $candidates += [pscustomobject]@{ Minor = [int]$Matches[1]; Path = $_.FullName }
            }
        }
    }

    $eligible = $candidates |
        Where-Object { $_.Path -and (Test-Path -LiteralPath $_.Path) -and ($MaxMinor -le 0 -or $_.Minor -le $MaxMinor) } |
        Sort-Object Minor -Descending

    if ($eligible) { return $eligible[0].Path }
    return $null
}

# Stops any process listening on $port; returns $true if anything was stopped
function Stop-PortListener ([int]$port) {
    $listeners = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    if (-not $listeners) { return $false }
    foreach ($l in $listeners) {
        $proc = Get-Process -Id $l.OwningProcess -ErrorAction SilentlyContinue
        Write-Warn "Stopping PID $($l.OwningProcess) ($($proc.Name)) on :$port"
        Invoke-Maybe {
            Stop-Process -Id $l.OwningProcess -Force -ErrorAction SilentlyContinue
        } "stop PID $($l.OwningProcess)"
    }
    Start-Sleep -Seconds 2
    return $true
}

# Runs headroom --version, optionally with a timeout.
# $HeadroomTimeout = 0 means wait forever (default); any positive value caps via a background job.
# The shim cold-starts a Python runtime on first call, which can take several seconds.
function Get-HeadroomVersion {
    if ($HeadroomTimeout -gt 0) {
        $job = Start-Job { headroom --version 2>&1 }
        if (Wait-Job $job -Timeout $HeadroomTimeout) {
            $v = Receive-Job $job
        } else {
            $v = $null
            Write-Warn "headroom --version timed out after ${HeadroomTimeout}s (shim cold-start)"
        }
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        return $v
    } else {
        return (headroom --version 2>&1)
    }
}

# ==============================================================================
# PHASE 0 - Resolve latest versions from upstream sources
# ==============================================================================
Write-Step "PHASE 0 - Resolve latest versions"

# -- headroom-ai: PyPI JSON API ------------------------------------------------
# The /pypi/<pkg>/json endpoint returns ALL releases with their file lists.
# We iterate releases to find the highest stable version that ships a wheel
# installable on Windows without a source build (no MSVC required).
# Acceptable wheel tags:
#   cp313-cp313-win_amd64   compiled Windows wheel
#   py3-none-any            pure Python, any platform
#   cp313-none-any          compiled but platform-neutral
# Excluded: manylinux / linux / macos / darwin - these won't install on Windows.
# NOTE: headroom-ai ships cp312/cp313 only (no cp314). The runtime venv is built
# on Python <= 3.13 (see Resolve-PythonBase -MaxMinor 13 in Phase 5).
$HeadroomVersion = $null
if (-not $SkipVersionCheck) {
    Write-Info "Querying PyPI for latest headroom-ai with Windows-installable wheel..."
    try {
        $pypi = Invoke-RestMethod "https://pypi.org/pypi/headroom-ai/json" `
                    -TimeoutSec 15 -ErrorAction Stop

        # PyPI releases deserializes as PSCustomObject in PowerShell, not a hashtable.
        # Must iterate via .PSObject.Properties; .Keys returns null on PSCustomObject.
        $candidateVersions = $pypi.releases.PSObject.Properties | ForEach-Object {
            $ver   = $_.Name
            $files = $_.Value
            $hasInstallableWheel = $files | Where-Object {
                $_.filename -match '\.whl$' -and
                $_.filename -notmatch 'manylinux|linux|macos|darwin'
            }
            if ($hasInstallableWheel) { $ver }
        } | Where-Object { $_ -and $_ -notmatch 'a\d|b\d|rc\d' } |  # stable releases only
            ForEach-Object {
                try { [version]($_ -replace '^[^\d]*') } catch { $null }
            } | Where-Object { $_ -ne $null } |
            Sort-Object -Descending

        if ($candidateVersions) {
            $HeadroomVersion = $candidateVersions[0].ToString()
            Write-OK "headroom-ai latest with installable Windows wheel: $HeadroomVersion"
        } else {
            Write-Warn "No installable Windows wheel found in any release - falling back"
        }
    } catch {
        Write-Warn "PyPI query failed: $($_.Exception.Message)"
    }
}
if (-not $HeadroomVersion) {
    $HeadroomVersion = $FallbackHeadroomVersion
    Write-Warn "Using fallback headroom-ai version: $HeadroomVersion"
}
$HeadroomSpec = "headroom-ai[proxy]==$HeadroomVersion"

# -- RTK: GitHub Releases API --------------------------------------------------
# Queries the latest release and finds the Windows x86_64 MSVC zip asset.
# Falls back to constructing the canonical URL if the asset list doesn't match.
$RtkVersion     = $null
$RtkDownloadUrl = $null
if (-not $SkipVersionCheck) {
    Write-Info "Querying GitHub for latest RTK release..."
    try {
        $ghRelease  = Invoke-RestMethod `
                        "https://api.github.com/repos/rtk-ai/rtk/releases/latest" `
                        -TimeoutSec 15 -ErrorAction Stop
        $RtkVersion = $ghRelease.tag_name -replace '^v'
        $asset = $ghRelease.assets |
                 Where-Object { $_.name -match "x86_64.*windows.*msvc.*\.zip" -or
                                $_.name -match "windows.*x86_64.*\.zip" } |
                 Select-Object -First 1
        $RtkDownloadUrl = if ($asset) {
            $asset.browser_download_url
        } else {
            # Construct canonical URL if asset pattern didn't match
            "https://github.com/rtk-ai/rtk/releases/download/v$RtkVersion/rtk-x86_64-pc-windows-msvc.zip"
        }
        Write-OK "RTK latest: $RtkVersion  ($( if ($asset) { $asset.name } else { 'URL constructed' } ))"
    } catch {
        Write-Warn "GitHub API query failed: $($_.Exception.Message)"
    }
}
if (-not $RtkVersion) {
    $RtkVersion     = $FallbackRtkVersion
    $RtkDownloadUrl = "https://github.com/rtk-ai/rtk/releases/download/v$RtkVersion/rtk-x86_64-pc-windows-msvc.zip"
    Write-Warn "Using fallback RTK version: $RtkVersion"
}

# -- graphify (PyPI 'graphifyy') latest, for display ----------------------------
# Installed through uv tool; no wheel-ABI pinning like headroom (pure-Python).
$GraphifyLatest = $null
if (-not $SkipVersionCheck) {
    Write-Info "Querying PyPI for latest graphifyy..."
    try {
        $gp = Invoke-RestMethod "https://pypi.org/pypi/graphifyy/json" -TimeoutSec 15 -ErrorAction Stop
        $GraphifyLatest = $gp.info.version
        Write-OK "graphifyy latest: $GraphifyLatest"
    } catch { Write-Warn "PyPI graphifyy query failed: $($_.Exception.Message)" }
}

# -- Python: parse python.org downloads page for latest stable -----------------
# Used to give an accurate version comparison when checking if upgrade is needed.
# Not used to drive the actual install - that goes through py / Install Manager.
$PythonLatest = $null
if (-not $SkipVersionCheck -and -not $SkipPythonUpdate) {
    Write-Info "Querying python.org for latest stable Windows release..."
    try {
        $dlPage = Invoke-WebRequest "https://www.python.org/downloads/windows/" `
                      -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
        $stableVersions = [regex]::Matches($dlPage.Content, 'Python (3\.\d+\.\d+)</a>') |
            ForEach-Object { $_.Groups[1].Value } |
            Where-Object   { $_ -notmatch 'a\d|b\d|rc\d' } |  # exclude pre-releases
            ForEach-Object { [version]$_ } |
            Sort-Object -Descending
        if ($stableVersions) {
            $PythonLatest = $stableVersions[0].ToString()
            Write-OK "Python latest stable: $PythonLatest"
        }
    } catch {
        Write-Warn "python.org query failed: $($_.Exception.Message)"
    }
}

Write-Info ""
Write-Info "Versions for this run:"
Write-Info "  headroom-ai : $HeadroomVersion  (wheel-installable on Windows, cp<=313)"
Write-Info "  RTK         : $RtkVersion"
Write-Info "  graphify    : $(if ($GraphifyLatest)  { $GraphifyLatest }  else { '(resolve at install)' })"
Write-Info "  Python      : $(if ($PythonLatest) { $PythonLatest } else { '(Install Manager decides)' })"

# ==============================================================================
# PHASE 1 - Inventory
# ==============================================================================
Write-Step "PHASE 1 - Inventory"

Write-Info "Python executables on PATH:"
where.exe python 2>$null | ForEach-Object { Write-Info "  python => $_" }
where.exe py     2>$null | ForEach-Object { Write-Info "  py     => $_" }

Write-Info "Active Python:"
try { Write-Info "  $(python --version 2>&1)" } catch { Write-Warn "python not found" }

Write-Info "py launcher runtimes:"
try { py -0p 2>&1 | ForEach-Object { Write-Info "  $_" } } catch { Write-Warn "py not found" }

# headroom-ai has no cp314 wheel; warn if no Python <= 3.13 is available for a
# future Headroom runtime rebuild. The current runtime keeps working until a
# version bump forces a rebuild - this surfaces the latent break early.
$py313 = Resolve-PythonBase -MaxMinor 13
if (-not $py313) {
    Write-Warn "No Python <= 3.13 installed. Headroom runtime cannot be rebuilt"
    Write-Warn "(headroom-ai ships cp312/cp313 wheels only, no cp314). Install 3.13:"
    Write-Warn "  winget install Python.Python.3.13"
    Write-Warn "The current Headroom runtime keeps working until its next version bump."
} else {
    Write-OK "Headroom-capable Python present (<=3.13): $py313"
}

Write-Info "RTK:"
try { Write-Info "  $(rtk --version 2>&1)" } catch { Write-Warn "rtk not found" }

# headroom --version cold-starts the shim's Python runtime on first call.
# Get-HeadroomVersion respects -HeadroomTimeout (0 = no timeout, the default).
Write-Info "Headroom:"
try {
    $hrVer = Get-HeadroomVersion
    if ($hrVer) { Write-Info "  $hrVer" }
} catch { Write-Warn "headroom not found" }

Write-Info "Headroom proxy:"
try {
    $h = Invoke-RestMethod "http://127.0.0.1:$ProxyPort/health" -TimeoutSec 3 -ErrorAction Stop
    Write-Info "  status=$($h.status)  version=$($h.version)  rust_core=$($h.rust_core)"
} catch { Write-Info "  not responding (stopped or not yet started)" }

Write-Info "Knowledge-graph tool:"
try {
    $graphifyCmd = Get-Command graphify -ErrorAction SilentlyContinue
    if ($graphifyCmd) { Write-Info "  graphify: $(& $graphifyCmd.Source --version 2>&1)" } else { Write-Info "  graphify: not installed" }
} catch { Write-Info "  graphify: probe failed" }

Write-Info "Stale Python env vars:"
$staleFound = $false
foreach ($scope in "User","Machine") {
    foreach ($var in "PY_PYTHON","PY_PYTHON3","PYTHONHOME","PYTHONPATH","PYTHON_MANAGER_DEFAULT") {
        $val = [Environment]::GetEnvironmentVariable($var, $scope)
        if ($val) { Write-Warn "[$scope] $var=$val"; $staleFound = $true }
    }
}
if (-not $staleFound) { Write-OK "No stale Python env vars" }

# ==============================================================================
# PHASE 2 - Python cleanup: env pins + py.ini overrides
# ==============================================================================
Write-Step "PHASE 2 - Clear stale Python env pins and py.ini overrides"

$stamp = Get-Date -Format "yyyyMMddHHmmss"

# Clear user-scope env vars that can break a good Python install.
# PYTHONHOME / PYTHONPATH in particular cause "No module named encodings" errors
# if they point at a different Python version than the one being invoked.
foreach ($var in "PY_PYTHON","PY_PYTHON3","PYTHONHOME","PYTHONPATH","PYTHON_MANAGER_DEFAULT") {
    $val = [Environment]::GetEnvironmentVariable($var, "User")
    if ($val) {
        Write-Warn "Clearing [User] $var = $val"
        Invoke-Maybe { [Environment]::SetEnvironmentVariable($var, $null, "User") } "clear $var"
    }
}

# py.ini files can pin the launcher to an old minor version (e.g. [defaults] python=3.9).
# Back them up with a timestamp suffix before removing so they can be recovered if needed.
foreach ($ini in @("$env:LocalAppData\py.ini","$env:AppData\py.ini","C:\Windows\py.ini")) {
    if (Test-Path -LiteralPath $ini) {
        $content = Get-Content -LiteralPath $ini -Raw
        Write-Warn "Found py.ini at ${ini}: $($content.Trim())"
        Invoke-Maybe {
            Copy-Item -LiteralPath $ini -Destination "$ini.bak-$stamp" -Force
            Remove-Item -LiteralPath $ini -Force
            Write-OK "Backed up and removed: $ini"
        } "backup+remove $ini"
    }
}

# ==============================================================================
# PHASE 3 - Python runtime update
# ==============================================================================
Write-Step "PHASE 3 - Python runtime update"

if ($SkipPythonUpdate) {
    Write-Info "Skipping (-SkipPythonUpdate set)"
} else {
    # Distinguish the new Python Install Manager (supports 'py list', 'py install')
    # from the legacy Python Launcher (C:\Windows\py.exe) which only supports 'py -X.Y'.
    $isNewMgr = $false
    try {
        # Test 'py install --help' specifically - legacy py.exe emits "WARNING.*legacy" on
        # any 'install' subcommand, while the new Install Manager returns real help text.
        $installHelp = & py install --help 2>&1 | Out-String
        $isNewMgr = $installHelp -notmatch "WARNING.*legacy" -and $installHelp -notmatch "unavailable"
    } catch { }

    if ($isNewMgr) {
        Write-Info "Python Install Manager detected. Updating runtimes..."
        Invoke-Maybe {
            py install --configure -y 2>&1 | ForEach-Object { Write-Info "  $_" }
            if ($PythonLatest) {
                Write-Info "  Installing $PythonLatest ..."
                py install $PythonLatest 2>&1 | ForEach-Object { Write-Info "  $_" }
            }
            py install --update  2>&1 | ForEach-Object { Write-Info "  $_" }
            py install --refresh 2>&1 | ForEach-Object { Write-Info "  $_" }
        } "py install --update"
        Write-Info "Installed runtimes:"
        py -0p 2>&1 | ForEach-Object { Write-Info "  $_" }
    } else {
        # Legacy py.exe - cannot run 'py install'. Check if Python is at least current.
        Write-Warn "Legacy Python Launcher detected (C:\Windows\py.exe) - 'py install' unavailable."
        try {
            $current = ((python --version 2>&1) -replace 'Python ').Trim()
            Write-OK "Active Python: $current"
            if ($PythonLatest) {
                if (Test-VersionGte -a $current -b $PythonLatest) {
                    Write-OK "Already at or above latest stable ($PythonLatest) - no upgrade needed"
                } else {
                    Write-Warn "Installed: $current  |  Latest: $PythonLatest"
                    Write-Warn "To upgrade Python and unlock 'py install' management:"
                    Write-Warn "  1. Settings -> Installed Apps -> remove 'Python Launcher'"
                    Write-Warn "  2. winget install 9NQ7512CXL7T -e --accept-package-agreements --accept-source-agreements"
                    Write-Warn "  3. Re-run this script"
                }
            }
        } catch { Write-Warn "python not found on PATH" }
    }
}

Write-Info "Final Python state:"
try { Write-Info "  exe: $(python -c 'import sys;print(sys.executable)' 2>&1)" } catch { }
try { Write-Info "  ver: $(python --version 2>&1)" } catch { }
try { Write-Info "  pip: $(python -m pip --version 2>&1)" } catch { }

# ==============================================================================
# PHASE 4 - Stop Headroom proxy
# ==============================================================================
Write-Step "PHASE 4 - Stop Headroom proxy on :$ProxyPort"

# Must stop before updating the runtime so pip doesn't hit locked files.
Invoke-Maybe {
    $stopped = Stop-PortListener -port $ProxyPort
    if ($stopped) { Write-OK "Proxy stopped" }
    else          { Write-Info "No proxy was listening on :$ProxyPort" }
} "stop proxy"

# ==============================================================================
# PHASE 5 - Headroom shim files + runtime rebuild
# ==============================================================================
Write-Step "PHASE 5 - Headroom shim files and runtime (target: $HeadroomVersion)"

Invoke-Maybe {
    New-Item -ItemType Directory -Force -Path $RtkBinDir, $HeadroomRoot | Out-Null
} "create dirs"

# Check if runtime already matches target version - skip the venv rebuild if so.
# The venv rebuild wipes and recreates the entire runtime, which takes 1-3 minutes.
$runtimeHR    = "$HeadroomRuntime\Scripts\headroom.exe"
$needsRebuild = $true
if (Test-Path -LiteralPath $runtimeHR) {
    try {
        $installedHR = (& $runtimeHR --version 2>&1).Trim()
        if ($installedHR -match [regex]::Escape($HeadroomVersion)) {
            $needsRebuild = $false
            Write-OK "Runtime already at $HeadroomVersion - skipping rebuild"
        } else {
            Write-Info "Runtime is '$installedHR', target is $HeadroomVersion - rebuilding"
        }
    } catch { Write-Info "Runtime probe failed - rebuilding" }
}

# Always rewrite all shim files - they're small and idempotent. This ensures
# any behavioural fix (telemetry, hook fast-path, env vars) is always current.

Write-Info "Writing package-spec.txt..."
Invoke-Maybe {
    # Records the exact headroom-ai version installed in the runtime venv.
    # The shim's Reset-HeadroomRuntime function reads this to rebuild from scratch.
    Set-Content -LiteralPath $PackageSpec -Encoding ASCII -Value $HeadroomSpec
} "write package-spec.txt ($HeadroomSpec)"

Write-Info "Writing headroom.cmd..."
Invoke-Maybe {
    # Thin batch wrapper so 'headroom' resolves from any shell without needing
    # Python on PATH. Delegates to the PowerShell shim for all logic.
    Set-Content -LiteralPath $HeadroomShim -Encoding ASCII -Value @'
@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.headroom\headroom-shim.ps1" %*
exit /b %ERRORLEVEL%
'@
} "write headroom.cmd"

Write-Info "Writing headroom-shim.ps1..."
Invoke-Maybe {
    Set-Content -LiteralPath $ShimPs1 -Encoding UTF8 -Value @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$HeadroomArgs)
$ErrorActionPreference = "Stop"

$root            = Join-Path $env:USERPROFILE ".headroom"
$runtime         = Join-Path $root "runtime"
$runtimePython   = Join-Path $runtime "Scripts\python.exe"
$runtimeHeadroom = Join-Path $runtime "Scripts\headroom.exe"
$packageSpecPath = Join-Path $root "package-spec.txt"

# Finds the newest installed Python <= 3.13 for rebuilding the headroom runtime.
# headroom-ai ships cp312/cp313 wheels only (no cp314), so 3.14+ is refused -
# an --only-binary install on 3.14 would hard-fail. Prefers py -3.13, then
# enumerates py -0p and known install dirs for the highest minor <= 13.
function Resolve-BasePython {
    # Fast path: explicit 3.13 via launcher
    try {
        $p = & py -3.13 -c "import sys;print(sys.executable)" 2>$null
        $p = ($p | Select-Object -Last 1); if ($p) { $p = $p.Trim() }
        if ($LASTEXITCODE -eq 0 -and $p -and (Test-Path -LiteralPath $p)) { return $p }
    } catch { }
    # Enumerate launcher runtimes + known dirs, pick highest minor <= 13
    $cands = @()
    try {
        foreach ($ln in (& py -0p 2>$null)) {
            if ($ln -match '-V:3\.(\d+)\D.*?([A-Za-z]:\\[^\s].*python\.exe)') {
                $cands += [pscustomobject]@{ Minor = [int]$Matches[1]; Path = $Matches[2].Trim() }
            }
        }
    } catch { }
    foreach ($glob in @("$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe","C:\Python3*\python.exe")) {
        Get-ChildItem -Path $glob -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.DirectoryName -match 'Python3(\d+)') { $cands += [pscustomobject]@{ Minor = [int]$Matches[1]; Path = $_.FullName } }
        }
    }
    $hit = $cands | Where-Object { $_.Path -and (Test-Path -LiteralPath $_.Path) -and $_.Minor -le 13 } |
           Sort-Object Minor -Descending | Select-Object -First 1
    if ($hit) { return $hit.Path }
    throw "No Python <= 3.13 found for headroom runtime rebuild (headroom-ai has no cp314 wheel). Install 3.13: winget install Python.Python.3.13"
}

# Wipes and rebuilds the runtime venv from scratch using the current package-spec.txt.
# Uses --only-binary=:all: to guarantee no MSVC source build occurs.
function Reset-HeadroomRuntime {
    $base = Resolve-BasePython
    if (Test-Path -LiteralPath $runtime) { Remove-Item -LiteralPath $runtime -Recurse -Force }
    & $base -m venv $runtime
    & $runtimePython -m pip install --upgrade pip --quiet
    $spec = (Get-Content -LiteralPath $packageSpecPath -Raw).Trim()
    & $runtimePython -m pip install --upgrade --only-binary=:all: $spec
    if ($LASTEXITCODE -ne 0) { throw "headroom-ai install failed" }
}

# Checks that headroom.exe is present and runnable in the runtime venv.
function Test-HeadroomRuntime {
    if (-not (Test-Path -LiteralPath $runtimeHeadroom)) { return $false }
    & $runtimeHeadroom --version *> $null
    return ($LASTEXITCODE -eq 0)
}

# Checks if the proxy is already serving on :8787.
function Test-ProxyReady {
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:8787/readyz" -UseBasicParsing -TimeoutSec 2
        return ($r.StatusCode -ge 200 -and $r.StatusCode -lt 300)
    } catch { return $false }
}

# Manual runtime reset: headroom shim reset
if ($HeadroomArgs.Count -ge 2 -and
    $HeadroomArgs[0] -eq "shim" -and $HeadroomArgs[1] -eq "reset") {
    Reset-HeadroomRuntime; exit 0
}

# Self-heal: rebuild runtime if missing or broken before any real command
if (-not (Test-HeadroomRuntime)) { Reset-HeadroomRuntime }

# Fast-path hook: called by Copilot/Codex on every request to ensure the proxy is running.
# Skip full runtime load - just check the port directly and start proxy if needed.
# The lightweight headroom-proxy-ensure.cmd is now the preferred hook target (< 1s),
# but this branch handles the case where the shim is still invoked directly.
if ($HeadroomArgs.Count -ge 3 -and
    $HeadroomArgs[0] -eq "init" -and
    $HeadroomArgs[1] -eq "hook" -and
    $HeadroomArgs[2] -eq "ensure") {
    $listening = (netstat -an 2>$null | Select-String ":8787 " | Select-String "LISTENING")
    if (-not $listening) {
        Start-Process -FilePath "$root\run-proxy.cmd" `
            -WorkingDirectory $env:USERPROFILE -WindowStyle Hidden
    }
    exit 0
}

# Normal headroom command - pass through to the runtime executable
$env:HEADROOM_TELEMETRY         = "off"
$env:HEADROOM_REQUIRE_RUST_CORE = "false"
& $runtimeHeadroom @HeadroomArgs
exit $LASTEXITCODE
'@
} "write headroom-shim.ps1"

Write-Info "Writing run-proxy.cmd..."
Invoke-Maybe {
    # Full proxy launcher used by Desktop/Startup shortcuts.
    # Sets all noise-suppression env vars so the console window stays clean.
    Set-Content -LiteralPath $RunProxyCmd -Encoding ASCII -Value @'
@echo off
title Headroom Proxy (port 8787)
set HEADROOM_TELEMETRY=off
set HEADROOM_REQUIRE_RUST_CORE=false
set TRANSFORMERS_VERBOSITY=error
set TOKENIZERS_PARALLELISM=false
set HF_HUB_VERBOSITY=error
set HF_HUB_DISABLE_PROGRESS_BARS=1
set HUGGINGFACE_HUB_VERBOSITY=error
set HTTPX_LOG_LEVEL=warning
set PYTHONWARNINGS=ignore::UserWarning
echo === Headroom Proxy launching at %date% %time% ===
echo.
call "%USERPROFILE%\.local\bin\headroom.cmd" proxy --port 8787 --host 127.0.0.1 --no-telemetry --memory --learn --memory-db-path "%USERPROFILE%\.headroom\memory.db"
set EXITCODE=%errorlevel%
echo.
echo === Headroom Proxy exited (exit code %EXITCODE%) ===
echo Press any key to close...
pause >nul
'@
} "write run-proxy.cmd"

Write-Info "Writing headroom-proxy-ensure.cmd (lightweight hook for Copilot/Codex)..."
Invoke-Maybe {
    # This is the preferred hook target for Copilot and Codex.
    # The default 'headroom init hook ensure' routes through headroom.cmd -> PowerShell ->
    # Python runtime, which takes 3-8s on a cold start and trips Copilot's 15s hook timeout.
    # This .cmd does a direct netstat port check in <100ms with no PS or Python startup cost.
    Set-Content -LiteralPath $EnsureProxyCmd -Encoding ASCII -Value @'
@echo off
:: Lightweight proxy-ensure hook - no PowerShell startup, just a TCP port check.
:: Called by Copilot/Codex hooks on every request; must complete well under 15s.
set PORT=8787
netstat -an 2>nul | findstr /C:":%PORT% " | findstr /C:"LISTENING" >nul 2>&1
if %ERRORLEVEL% equ 0 exit /b 0
:: Port not listening - start the proxy hidden and exit immediately.
:: The proxy window opens asynchronously; the hook does not wait for it to be ready.
start "" /b cmd /c ""%USERPROFILE%\.headroom\run-proxy.cmd"" >nul 2>&1
exit /b 0
'@
} "write headroom-proxy-ensure.cmd"

# Ensure .local\bin is on user PATH so headroom.cmd, rtk.exe, and uv tool shims resolve from any shell
$userPath  = [Environment]::GetEnvironmentVariable("Path","User")
$pathParts = $userPath -split ";" | Where-Object { $_ }
if ($pathParts -notcontains $RtkBinDir) {
    Write-Warn "$RtkBinDir not on user PATH - adding"
    Invoke-Maybe {
        [Environment]::SetEnvironmentVariable("Path","$RtkBinDir;$userPath","User")
    } "add $RtkBinDir to user PATH"
}

# Rebuild the headroom runtime venv if the installed version doesn't match the target.
# Builds on the newest Python <= 3.13 - headroom-ai ships cp312/cp313 wheels only
# (no cp314), so a 3.14 base would hard-fail under --only-binary.
if ($needsRebuild) {
    Invoke-Maybe {
        $basePy = Resolve-PythonBase -MaxMinor 13
        if (-not $basePy) {
            Write-Fail "No Python <= 3.13 found. headroom-ai has no cp314 wheel, so the"
            Write-Fail "Headroom runtime cannot be (re)built on Python 3.14+."
            Write-Fail "Install Python 3.13 (winget install Python.Python.3.13) and re-run."
            return
        }

        Write-Info "Base Python: $basePy ($(& $basePy --version 2>&1))"
        $runtimePy = "$HeadroomRuntime\Scripts\python.exe"

        Write-Info "Wiping old runtime..."
        if (Test-Path -LiteralPath $HeadroomRuntime) {
            Remove-Item -LiteralPath $HeadroomRuntime -Recurse -Force
        }

        Write-Info "Creating venv..."
        & $basePy -m venv $HeadroomRuntime
        if ($LASTEXITCODE -ne 0) { Write-Fail "venv creation failed"; return }

        & $runtimePy -m pip install --upgrade pip --quiet

        # --only-binary=:all: prevents pip from attempting a source build.
        # Phase 0 already verified this version has an installable wheel, so this should succeed.
        Write-Info "Installing $HeadroomSpec (binary-only - wheel verified in Phase 0)..."
        & $runtimePy -m pip install --only-binary=:all: $HeadroomSpec
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "headroom-ai wheel install failed. Version $HeadroomVersion may lack a cp<=313 Windows wheel for this base Python."
            Write-Fail "Confirm a Python <= 3.13 is installed, then re-run."
            return
        }

        if (-not (Test-Path -LiteralPath $runtimeHR)) {
            Write-Fail "headroom.exe missing after install: $runtimeHR"; return
        }
        Write-OK "Runtime headroom: $(& $runtimeHR --version 2>&1)"
    } "rebuild headroom runtime to $HeadroomVersion"
}

# ==============================================================================
# PHASE 6 - RTK: install or skip if already at/above latest
# ==============================================================================
Write-Step "PHASE 6 - RTK (target: v$RtkVersion)"

$rtkExe     = "$RtkBinDir\rtk.exe"
$currentRtk = $null
try { $currentRtk = (& rtk --version 2>&1).Trim() } catch { }

# Skip download if already at or above the target - Test-VersionGte handles
# cases where RTK is newer than the resolved version (e.g. 0.39.0 vs 0.38.0).
if ($currentRtk -and (Test-VersionGte -a $currentRtk -b $RtkVersion)) {
    Write-OK "RTK already at or above v${RtkVersion}: $currentRtk - skipping download"
} else {
    Write-Info "Current RTK: '$currentRtk' - installing v${RtkVersion}..."
    Invoke-Maybe {
        $tmpZip = "$env:TEMP\rtk-$RtkVersion.zip"
        $tmpDir = "$env:TEMP\rtk-extract-$RtkVersion"

        Write-Info "  Downloading: $RtkDownloadUrl"
        try {
            Invoke-WebRequest -Uri $RtkDownloadUrl -OutFile $tmpZip -UseBasicParsing -ErrorAction Stop
        } catch {
            Write-Fail "Download failed: $($_.Exception.Message)"; return
        }

        if (Test-Path -LiteralPath $tmpDir) { Remove-Item -LiteralPath $tmpDir -Recurse -Force }
        Expand-Archive -LiteralPath $tmpZip -DestinationPath $tmpDir -Force

        $extracted = Get-ChildItem -LiteralPath $tmpDir -Filter "rtk.exe" -Recurse |
                     Select-Object -First 1
        if (-not $extracted) { Write-Fail "rtk.exe not found in zip at $tmpDir"; return }

        New-Item -ItemType Directory -Force -Path $RtkBinDir | Out-Null
        Copy-Item -LiteralPath $extracted.FullName -Destination $rtkExe -Force
        Remove-Item $tmpZip, $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-OK "RTK installed: $(& $rtkExe --version 2>&1)"
    } "download+install rtk v$RtkVersion"
}

# Sync any shadowing rtk.exe locations so PATH-resolved rtk always matches
# the canonical version in $RtkBinDir (e.g. a copy in OneDrive or another bin dir).
Invoke-Maybe {
    $env:Path = "$RtkBinDir;" + [Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                [Environment]::GetEnvironmentVariable("Path","User")
    $allInstances = @(where.exe rtk 2>$null) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    foreach ($inst in $allInstances) {
        if ($inst -ieq $rtkExe) { continue }
        Write-Warn "Shadowing rtk found: $inst - syncing to v$RtkVersion"
        # Stop any rtk.exe process running from this path before overwriting
        Get-Process -Name "rtk" -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -ieq $inst } |
            ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Milliseconds 300
        try {
            Copy-Item -LiteralPath $rtkExe -Destination $inst -Force -ErrorAction Stop
            Write-OK "Synced: $inst"
        } catch {
            Write-Fail "Could not sync $inst - $($_.Exception.Message)"
        }
    }
} "sync shadowing rtk locations"

# ==============================================================================
# PHASE 7 - Knowledge-graph tool: graphify (PyPI)
# ==============================================================================
Write-Step "PHASE 7 - Knowledge-graph tool (graphify)"

# -- graphify: PyPI package 'graphifyy' (double-y), CLI 'graphify'.
# Use Graphify's official global install path. Per-repo harness registration,
# layer choice (structure-only vs full), and graph creation are intentionally
# left to support/context-tooling.md.
$uv = Get-Command uv -ErrorAction SilentlyContinue
if (-not $uv) {
    Write-Warn "uv not on PATH - installing astral-sh.uv with winget"
    Invoke-Maybe {
        winget install astral-sh.uv -e --accept-package-agreements --accept-source-agreements 2>&1 |
            ForEach-Object { Write-Info "  $_" }
    } "winget install astral-sh.uv"
    $env:Path = "$RtkBinDir;" +
                [Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                [Environment]::GetEnvironmentVariable("Path","User")
    $uv = Get-Command uv -ErrorAction SilentlyContinue
}
if (-not $uv) {
    Write-Warn "uv unavailable - skipping graphify. Install manually: winget install astral-sh.uv; uv tool install graphifyy"
} else {
    Write-Info "Installing/updating graphifyy with uv tool..."
    Invoke-Maybe {
        & $uv.Source tool install --upgrade --force $GraphifyPackage 2>&1 |
            ForEach-Object { Write-Info "  $_" }
        if ($LASTEXITCODE -eq 0) {
            $legacyGraphifyShim = Join-Path $RtkBinDir "graphify.cmd"
            if (Test-Path -LiteralPath $legacyGraphifyShim) {
                $legacyText = Get-Content -LiteralPath $legacyGraphifyShim -Raw -ErrorAction SilentlyContinue
                if ($legacyText -match '\\.graphify\\runtime\\Scripts\\graphify\.exe') {
                    Remove-Item -LiteralPath $legacyGraphifyShim -Force -ErrorAction SilentlyContinue
                    Write-OK "Removed legacy graphify.cmd shim from previous isolated-venv install"
                }
            }
            $env:Path = "$RtkBinDir;" + $env:Path
            $graphifyCmd = Get-Command graphify -ErrorAction SilentlyContinue
            if ($graphifyCmd) {
                # Re-sync the /graphify skill to the just-upgraded CLI BEFORE probing
                # --version below. graphify stamps a .graphify_version into each skill
                # dir and warns "skill is from X, package is Y" on every invocation when
                # that stamp lags the CLI. Phase 8b is the canonical skill installer, but
                # the upgrade above bumps the package while the skill still reads the old
                # version - so the inventory probe (and any session until Phase 8b runs)
                # surfaces a transient mismatch warning. Syncing here clears it at the
                # source. Run from a throwaway temp cwd so 'graphify install' cannot stamp
                # the current repo's tracked files (same footgun Phase 8b guards against).
                $gfSyncTmp = Join-Path $env:TEMP "graphify-skill-sync-$PID"
                New-Item -ItemType Directory -Force -Path $gfSyncTmp | Out-Null
                Push-Location $gfSyncTmp
                try {
                    if (Test-Path -LiteralPath "$env:USERPROFILE\.claude") {
                        & $graphifyCmd.Source install --platform claude 2>&1 | ForEach-Object { Write-Info "  $_" }
                    }
                    if (Test-Path -LiteralPath "$env:USERPROFILE\.copilot") {
                        & $graphifyCmd.Source copilot install 2>&1 | ForEach-Object { Write-Info "  $_" }
                    }
                } finally {
                    Pop-Location
                    Remove-Item -LiteralPath $gfSyncTmp -Recurse -Force -ErrorAction SilentlyContinue
                }
                Write-OK "graphify: $(& $graphifyCmd.Source --version 2>&1)"
            } else {
                Write-Warn "graphify installed but not on PATH. Open a new shell or add $RtkBinDir to PATH."
            }
        } else {
            Write-Warn "graphifyy install failed - graphify unavailable this run (optional)"
        }
    } "uv tool install --upgrade --force graphifyy"
}

# ==============================================================================
# PHASE 8 - Disable telemetry + configure all agent harnesses
# ==============================================================================
Write-Step "PHASE 8 - Disable telemetry + configure all agent harnesses"

# Refresh session PATH so rtk + headroom resolve from their install locations
$env:Path = "$RtkBinDir;" +
            [Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
            [Environment]::GetEnvironmentVariable("Path","User")

# Disable RTK telemetry BEFORE any init calls - rtk init phones home once per day
# and hangs visibly for several seconds while doing so.
Write-Info "Disabling RTK telemetry..."
Invoke-Maybe {
    rtk telemetry disable 2>&1 | ForEach-Object { Write-Info "  $_" }
    Write-OK "RTK telemetry disabled"
} "rtk telemetry disable"

# Disable Headroom telemetry via CLI and also persist via setx so all future
# shells and the proxy window inherit HEADROOM_TELEMETRY=off automatically.
Write-Info "Disabling Headroom telemetry..."
Invoke-Maybe {
    $telOut = headroom telemetry disable 2>&1
    if ($LASTEXITCODE -eq 0) {
        $telOut | ForEach-Object { Write-Info "  $_" }
        Write-OK "Headroom telemetry CLI disabled"
    } else {
        Write-Warn "headroom telemetry subcommand not available in this version - using env var only"
    }
    setx HEADROOM_TELEMETRY "off" | Out-Null
    Write-OK "HEADROOM_TELEMETRY=off persisted via setx"
} "headroom telemetry disable"

# RTK harness init - registers hooks and instruction files for each agent.
# --auto-patch (Claude) and --codex are truly global: they write ~/.claude and
# $CODEX_HOME regardless of the current directory, so they are safe to run here.
foreach ($flag in "--auto-patch","--codex") {
    Write-Info "rtk init -g $flag"
    Invoke-Maybe {
        rtk init -g $flag 2>&1 | ForEach-Object { Write-Info "  $_" }
    } "rtk init -g $flag"
}

# --copilot is DIFFERENT and is the source of a real footgun: rtk's Copilot
# integration is project-scoped - even with -g it stamps .github/copilot-instructions.md
# and .github/hooks/rtk-rewrite.json into the CURRENT directory (the VS Code Copilot
# extension has no global instruction file). If this script is launched from inside a
# repo, that repo's tracked .github gets contaminated with rtk wiring (and, for the
# instruction repo, that wiring then rides the install payload into every scaffolded app).
# Run it from a throwaway temp directory: any genuine global writes still happen, but the
# cwd .github stamp lands in temp and is discarded. Per-repo Copilot rtk wiring is done
# deliberately via misc/enable-rtk-copilot-project.ps1; global Copilot steering (VS Code
# user settings) is handled per misc/apply-graphify-to-repo.txt.
Write-Info "rtk init -g --copilot (isolated temp cwd - avoids stamping a real repo's .github)"
Invoke-Maybe {
    $rtkCopilotTmp = Join-Path $env:TEMP "rtk-copilot-init-$PID"
    New-Item -ItemType Directory -Force -Path $rtkCopilotTmp | Out-Null
    Push-Location $rtkCopilotTmp
    try {
        rtk init -g --copilot 2>&1 | ForEach-Object { Write-Info "  $_" }
    } finally {
        Pop-Location
        Remove-Item -LiteralPath $rtkCopilotTmp -Recurse -Force -ErrorAction SilentlyContinue
    }
} "rtk init -g --copilot (isolated temp cwd)"
Invoke-Maybe {
    rtk init --show 2>&1 | ForEach-Object { Write-Info "  $_" }
} "rtk init --show"

# headroom init -g copilot reads ~/.copilot/config.json using plain json.loads().
# The Copilot CLI writes this file as JSONC (with // comments), which json.loads()
# rejects with "Expecting value: line 1 column 1 (char 0)".
# Strip comment lines before headroom runs; Copilot CLI re-adds them on next write.
$copilotConfig = "$env:USERPROFILE\.copilot\config.json"
if (Test-Path $copilotConfig) {
    $raw      = Get-Content $copilotConfig -Raw
    $stripped = ($raw -split "`n" | Where-Object { $_ -notmatch '^\s*//' }) -join "`n"
    if ($stripped -ne $raw) {
        Set-Content $copilotConfig $stripped -Encoding UTF8 -NoNewline
        Write-Warn "Stripped JSONC comments from $copilotConfig so headroom can parse it"
    }
}

# Headroom harness init - writes global instruction files / provider wiring per agent.
#
# IDEMPOTENCY + AUTH FIX (codex): `headroom init -g codex` is NOT idempotent and
# emits a broken provider block. Two distinct failures it causes:
#   1. DUPLICATE KEYS: it APPENDS its provider block (model_provider +
#      [model_providers.headroom]) to $CODEX_HOME\config.toml on EVERY run with no
#      presence check. Re-running this script stacks duplicate
#      [model_providers.headroom] tables -> Codex aborts with a TOML
#      "duplicate key" parse error and will not start.
#   2. WRONG SCOPE + SPURIOUS env_key: the block is appended at EOF, after existing
#      [tables], so the bare `model_provider = "headroom"` key silently nests under
#      whatever table precedes it (e.g. desktop.model_provider) instead of being a
#      root key - the proxy routing never takes effect. The block also writes
#      `env_key = "OPENAI_API_KEY"` alongside `requires_openai_auth = true`; for a
#      ChatGPT-login Codex (auth_mode = chatgpt, no API key) that env_key makes Codex
#      demand a variable that does not exist -> "Missing environment variable:
#      OPENAI_API_KEY". With requires_openai_auth = true the bearer already comes
#      from Codex's own login, so env_key is wrong and must be dropped.
#
# Fix is two-part:
#   1. Guard the codex init: only invoke it when no [model_providers.headroom]
#      block exists yet (first-time wiring). Stops new duplicates being appended.
#   2. Repair-CodexHeadroomProvider (always, after init): collapse any duplicate
#      Headroom blocks down to one, strip the env_key line, and relocate the block
#      ABOVE the first [table] so model_provider parses at root scope. Internal
#      block structure is otherwise preserved as Headroom emits it.
$codexHome   = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { "$env:USERPROFILE\.codex" }
$codexConfig = Join-Path $codexHome "config.toml"

# Normalize the Headroom provider block in codex config.toml: keep a single copy,
# drop the spurious env_key, and hoist it above the first table so model_provider
# is root-scoped. No-op when already correct, or when no marked Headroom block is
# present (unmarked legacy installs are left untouched to avoid guesswork).
function Repair-CodexHeadroomProvider {
    param([string]$ConfigPath, [string]$Stamp)
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        Write-Info "codex config.toml absent - nothing to repair ($ConfigPath)"; return
    }
    $orig = Get-Content -LiteralPath $ConfigPath -Raw
    if ($null -eq $orig) { return }
    $text = $orig -replace "`r`n", "`n"

    # Marker-AGNOSTIC: operate on the [model_providers.headroom] TABLE and the
    # model_provider key directly, so it fixes the block whether or not Headroom wrapped
    # it in "# --- Headroom init provider ---" comments (different versions/tools differ).
    if ($text -notmatch '(?m)^[ \t]*\[model_providers\.headroom\]') {
        Write-Info "no [model_providers.headroom] in codex config - nothing to repair ($ConfigPath)"; return
    }

    # Auth shape from the Codex LOGIN MODE (auth.json next to config.toml), NOT from what
    # the block contains - a block can carry env_key AND/OR requires_openai_auth=false and
    # still break a Codex/ChatGPT subscription login.
    #   chatgpt / oauth login  -> no API key exists. The provider MUST be
    #       requires_openai_auth=true with NO env_key, else Codex aborts at startup with
    #       "Missing environment variable: OPENAI_API_KEY".
    #   api-key login          -> env_key is the real credential; leave the table alone.
    # Fall back to the subscription shape when auth.json is absent AND no OPENAI_API_KEY
    # is set anywhere - the only state where env_key can break startup.
    $authMode = $null; $keyInAuth = $false
    $authPath = Join-Path (Split-Path -Parent $ConfigPath) 'auth.json'
    if (Test-Path -LiteralPath $authPath) {
        try {
            $aj        = Get-Content -LiteralPath $authPath -Raw | ConvertFrom-Json -ErrorAction Stop
            $authMode  = $aj.auth_mode
            $keyInAuth = -not [string]::IsNullOrWhiteSpace($aj.OPENAI_API_KEY)
        } catch { }
    }
    # A usable API key exists only if it's actually set somewhere (env in any scope, or a
    # non-empty OPENAI_API_KEY inside auth.json). Keep env_key ONLY in that case - it is the
    # real credential. With no key anywhere, env_key is GUARANTEED to break startup, so the
    # one safe shape is requires_openai_auth=true and NO env_key (subscription/OAuth login).
    # A chatgpt auth_mode forces subscription even if a stale key lingers in the environment.
    $haveKey = $keyInAuth `
        -or [bool][Environment]::GetEnvironmentVariable('OPENAI_API_KEY', 'User') `
        -or [bool][Environment]::GetEnvironmentVariable('OPENAI_API_KEY', 'Machine') `
        -or [bool]$env:OPENAI_API_KEY
    $subscriptionMode = ($authMode -eq 'chatgpt') -or (-not $haveKey)

    # 1) DEDUP duplicate [model_providers.headroom] tables (the TOML duplicate-key crash):
    #    keep the first, delete the rest. Table = header + following non-table, non-comment
    #    lines. Remove from last to first so earlier match offsets stay valid.
    $tblRx = '(?ms)^[ \t]*\[model_providers\.headroom\][ \t]*\n(?:(?![ \t]*\[)(?![ \t]*#)[^\n]*\n?)*'
    $tbls  = [regex]::Matches($text, $tblRx)
    $dupCount = $tbls.Count
    if ($tbls.Count -gt 1) {
        for ($i = $tbls.Count - 1; $i -ge 1; $i--) { $text = $text.Remove($tbls[$i].Index, $tbls[$i].Length) }
    }

    # Headroom writes a codex_hooks flag per init too; collapse stacked copies to the first
    # so they cannot become a duplicate key once the provider tables are deduped.
    $chRx = '(?m)^[ \t]*codex_hooks[ \t]*=[ \t]*(?:true|false)[ \t]*\n?'
    $chs  = [regex]::Matches($text, $chRx)
    if ($chs.Count -gt 1) {
        for ($i = $chs.Count - 1; $i -ge 1; $i--) { $text = $text.Remove($chs[$i].Index, $chs[$i].Length) }
    }

    # 2) Normalize provider keys for the auth mode (line-level - these keys live only in the
    #    headroom provider table). Subscription: drop env_key, force requires_openai_auth=true.
    if ($subscriptionMode) {
        $text = [regex]::Replace($text, '(?m)^[ \t]*env_key[ \t]*=.*\n?', '')
        if ($text -match '(?m)^[ \t]*requires_openai_auth[ \t]*=') {
            $text = [regex]::Replace($text, '(?m)^[ \t]*requires_openai_auth[ \t]*=.*$', 'requires_openai_auth = true')
        } else {
            # No such key - inject right after the table header (TOML key order is free).
            $text = [regex]::Replace($text, '(?m)^([ \t]*\[model_providers\.headroom\][ \t]*)$', "`$1`nrequires_openai_auth = true")
        }
    }

    # 3) ROOT-SCOPE model_provider = "headroom": it must appear before the first table
    #    header, else it nests under the preceding table (e.g. desktop.model_provider) and
    #    routing silently never applies.
    $firstTblIdx = [regex]::Match($text, '(?m)^[ \t]*\[').Index
    $mp = [regex]::Match($text, '(?m)^[ \t]*model_provider[ \t]*=[ \t]*"headroom"[ \t]*$')
    if (-not ($mp.Success -and $mp.Index -lt $firstTblIdx)) {
        $text = [regex]::Replace($text, '(?m)^[ \t]*model_provider[ \t]*=[ \t]*"headroom"[ \t]*\n?', '')
        $firstTblIdx = [regex]::Match($text, '(?m)^[ \t]*\[').Index
        if ($firstTblIdx -ge 0) {
            $text = $text.Substring(0, $firstTblIdx).TrimEnd() + "`nmodel_provider = `"headroom`"`n`n" + $text.Substring($firstTblIdx)
        } else {
            $text = 'model_provider = "headroom"' + "`n" + $text
        }
    }

    $text = ([regex]::Replace($text, "`n{3,}", "`n`n")).TrimEnd() + "`n"

    if ($text -eq (($orig -replace "`r`n", "`n").TrimEnd() + "`n")) {
        Write-OK "codex Headroom provider already correct (single, root-scoped, auth shape matches login) - no change"
        return
    }
    Copy-Item -LiteralPath $ConfigPath -Destination "$ConfigPath.bak-$Stamp" -Force
    # Write UTF-8 without BOM + CRLF (TOML rejects a BOM; Codex wrote CRLF originally).
    [System.IO.File]::WriteAllText($ConfigPath, ($text -replace "`n", "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    $shape   = if ($subscriptionMode) { "subscription/OAuth (requires_openai_auth=true, env_key removed)" } else { "api-key (env_key preserved)" }
    $dupNote = if ($dupCount -gt 1) { "collapsed $dupCount duplicate provider tables; " } else { "" }
    Write-OK "codex config.toml normalized: ${dupNote}auth shape -> $shape (backup: $ConfigPath.bak-$Stamp)"
}

foreach ($agent in "claude","codex","copilot") {
    if ($agent -eq "codex") {
        # Skip the non-idempotent CLI init once the provider is wired - re-running it
        # only appends another duplicate [model_providers.headroom] table. The repair
        # step below keeps the existing block correct.
        $codexWired = (Test-Path -LiteralPath $codexConfig) -and
                      ((Get-Content -LiteralPath $codexConfig -Raw) -match '\[model_providers\.headroom\]')
        if ($codexWired) {
            Write-Info "headroom init -g codex - SKIP (provider already wired; repair step normalizes it)"
            continue
        }
    }
    Write-Info "headroom init -g $agent"
    Invoke-Maybe {
        $initOut = headroom init -g $agent 2>&1
        $initOut | ForEach-Object { Write-Info "  $_" }
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "headroom init -g $agent exited $LASTEXITCODE - continuing"
        }
    } "headroom init -g $agent"
}

# Always normalize/repair the codex provider block: dedups any leftovers from prior
# non-idempotent runs, strips env_key, hoists model_provider to root. Idempotent.
Invoke-Maybe { Repair-CodexHeadroomProvider -ConfigPath $codexConfig -Stamp $stamp } "repair/dedup codex Headroom provider block"

# Patch the Copilot hook to use the lightweight proxy-ensure.cmd instead of the
# default 'headroom init hook ensure' command. The default routes through the PS
# shim + Python runtime and can take 3-8s, tripping Copilot's 15s hook timeout.
# headroom-proxy-ensure.cmd does a netstat port check in under 100ms.
Write-Info "Patching Copilot hook to use lightweight proxy-ensure.cmd..."
Invoke-Maybe {
    # Headroom writes its Copilot hook config to a global location during init.
    # We patch it to point at the lightweight ensure cmd if the key exists.
    $globalHook = "$env:USERPROFILE\.config\headroom\copilot-hook.json"
    foreach ($f in @($globalHook)) {
        if (Test-Path -LiteralPath $f) {
            $json = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
            if ($json.hookCommand -or $json.hook_command) {
                $json | Add-Member -Force -NotePropertyName "hookCommand" -NotePropertyValue $EnsureProxyCmd
                $json | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $f -Encoding UTF8
                Write-OK "Patched hook config: $f"
            }
        }
    }
    # Also persist the path via setx so any hook runner that reads this env var
    # can find the lightweight cmd without needing the full headroom chain.
    setx HEADROOM_ENSURE_CMD $EnsureProxyCmd | Out-Null
    Write-OK "HEADROOM_ENSURE_CMD set to: $EnsureProxyCmd"
} "patch copilot hook to lightweight ensure cmd"

# Set durable routing env vars so all agents send requests through the proxy.
# setx writes to the registry - effective in all new shells and agent processes.
#
# AUTH MODEL (per Headroom docs - this script sets ROUTING only, never provider keys):
#   - Routing is by base URL. These two BASE_URLs are the complete set of vars that
#     point the harnesses at the proxy (docs: `ANTHROPIC_BASE_URL=...:8787 claude`,
#     `OPENAI_BASE_URL=...:8787/v1`). We use 127.0.0.1 over the docs' `localhost` so
#     it can't resolve to an IPv6 ::1 that misses the 127.0.0.1-bound listener.
#   - OPENAI_API_KEY / ANTHROPIC_API_KEY are the PROXY's UPSTREAM credentials,
#     "used when proxying to OpenAI/Anthropic" (API-key mode) - conditional on the
#     backend, NOT a routing input. The script neither sets nor clears them; if you
#     run the proxy in API-key mode, put your REAL keys in the env the proxy inherits.
#   - This machine runs the OTHER mode: subscription / OAuth pass-through
#     (auth_mode=chatgpt, ~/.headroom/subscription_state.json present, no API keys).
#     Each harness forwards its OWN login - Claude Code via ANTHROPIC_BASE_URL, Codex
#     its ChatGPT token via the provider's requires_openai_auth=true (NOT an env_key).
#     A placeholder OPENAI_API_KEY is 401'd, and a client-side env_key on a ChatGPT
#     login is exactly what yields "Missing environment variable: OPENAI_API_KEY" -
#     which is why the Phase 8 codex repair strips env_key when requires_openai_auth.
Write-Info "Setting ANTHROPIC_BASE_URL + OPENAI_BASE_URL via setx..."
Invoke-Maybe {
    setx ANTHROPIC_BASE_URL "http://127.0.0.1:$ProxyPort"    | Out-Null
    setx OPENAI_BASE_URL    "http://127.0.0.1:$ProxyPort/v1" | Out-Null
    Write-OK "Routing env vars set (effective in new shells/agents)"
} "setx routing vars"

# ==============================================================================
# PHASE 8b - graphify GLOBAL harness steering (skill + conditional block + grep hook)
# ==============================================================================
# graphify has NO global-steering installer. Verified behavior:
#   - `graphify install --platform <p>` copies ONLY the skill to a GLOBAL config dir.
#   - `graphify <h> install`            writes the CURRENT REPO's TRACKED files
#                                       (./CLAUDE.md, ./.claude/settings.json, ...) and
#                                       emits an UNCONDITIONAL block - wrong for global.
# So the conditional steering block + Claude grep hook are written HERE, by hand, into
# GLOBAL config, idempotently (marker presence-check). Everything is GUARDED on
# `graphify-out/graph.json`, so it stays INERT in any repo until that repo builds a graph.
# This runs AFTER rtk/headroom init (Phase 8) so the global instruction files already
# exist. The PreToolUse append uses @($json.hooks.PreToolUse) + $entry, which forces a real
# array, so ConvertTo-Json serializes it as a JSON array regardless of entry count - no
# Windows PowerShell 5.1 single-element-array quirk even if graphify is the only entry.
Write-Step "PHASE 8b - graphify global harness steering"

$gfCmd = Get-Command graphify -ErrorAction SilentlyContinue
if (-not $gfCmd) {
    Write-Warn "graphify not on PATH - skipping global harness steering"
} else {
    $claudeDir      = "$env:USERPROFILE\.claude"
    $claudeMd       = "$claudeDir\CLAUDE.md"
    $claudeSettings = "$claudeDir\settings.json"
    $copilotDir     = "$env:USERPROFILE\.copilot"
    $codexHome      = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { "$env:USERPROFILE\.codex" }
    $codexAgents    = "$codexHome\AGENTS.md"

    # Canonical conditional steering block (shared). Claude also gets a skill pointer.
    $gfUsageBlock = @'
## graphify graph usage (applies in any repo that has a graph)
These rules are conditional - they activate only when `graphify-out/graph.json` exists in the working directory, and are inert otherwise.
- For codebase questions (architecture, structure, where/what/how things relate), first run `graphify query "<question>"`. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for a focused concept. These return a scoped subgraph, usually far smaller than raw grep/file reads.
- If `graphify-out/wiki/index.md` exists, use it for broad navigation instead of browsing source.
- Read `graphify-out/GRAPH_REPORT.md` only for broad architecture review, or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).
- No API key needed: inside a coding-agent session (Claude Code, Claude VS Code, Codex, Copilot) the harness model performs graphify's LLM extraction. `GEMINI_API_KEY`/`GOOGLE_API_KEY` apply to headless/CI runs only, and graphify never reads `ANTHROPIC_API_KEY`/`OPENAI_API_KEY`. Ignore any prompt to supply an API key for graphify.
'@

    $gfClaudeHeader = @'
# graphify
- **graphify** (`~/.claude/skills/graphify/SKILL.md`) - any input to knowledge graph. Trigger: `/graphify`
When the user types `/graphify`, invoke the Skill tool with `skill: "graphify"` before doing anything else.
'@

    # PreToolUse grep-steering hook command (Bash). Single-quoted here-string => literal;
    # the inner single quotes, double quotes, and backticks need no escaping.
    $gfGrepHookCmd = @'
CMD=$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('tool_input',d).get('command',''))" 2>/dev/null || true); case "$CMD" in *grep*|*rg\ *|*ripgrep*|*find\ *|*fd\ *|*ack\ *|*ag\ *)   [ -f graphify-out/graph.json ] &&   echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"graphify: knowledge graph at graphify-out/. For focused questions, run `graphify query \"<question>\"` (scoped subgraph, usually much smaller than GRAPH_REPORT.md) instead of grepping raw files. Read GRAPH_REPORT.md only for broad architecture context."}}'   || true ;; esac
'@

    $gfBlockMarker = '## graphify graph usage'
    $gfHookMarker  = 'graphify: knowledge graph at graphify-out/'

    # Append a marked block to a global instruction file if its marker is absent.
    function Initialize-GraphifyBlock {
        param([string]$Path, [string]$Marker, [string]$Block)
        if (-not (Test-Path -LiteralPath $Path)) { Write-Info "Not present, skipping: $Path"; return }
        $raw = Get-Content -LiteralPath $Path -Raw
        if ($raw -and ($raw -match [regex]::Escape($Marker))) { Write-OK "graphify steering already present: $Path"; return }
        Add-Content -LiteralPath $Path -Value ("`n" + $Block.Trim() + "`n") -Encoding UTF8
        Write-OK "graphify steering appended: $Path"
    }

    # Append the graphify grep hook to ~/.claude/settings.json PreToolUse if absent.
    function Initialize-GraphifyGrepHook {
        param([string]$Path, [string]$HookCmd, [string]$Marker)
        if (-not (Test-Path -LiteralPath $Path)) { Write-Info "Not present, skipping: $Path"; return }
        $raw = Get-Content -LiteralPath $Path -Raw
        if ($raw -and ($raw -match [regex]::Escape($Marker))) { Write-OK "graphify grep hook already present: $Path"; return }
        try { $json = $raw | ConvertFrom-Json -ErrorAction Stop }
        catch { Write-Fail "settings.json does not parse - leaving untouched: $($_.Exception.Message)"; return }
        if (-not $json.hooks) { $json | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) -Force }
        if (-not $json.hooks.PSObject.Properties['PreToolUse']) { $json.hooks | Add-Member -NotePropertyName PreToolUse -NotePropertyValue @() -Force }
        $entry = [pscustomobject]@{ matcher = 'Bash'; hooks = @([pscustomobject]@{ type = 'command'; command = $HookCmd }) }
        $json.hooks.PreToolUse = @($json.hooks.PreToolUse) + $entry
        $out = $json | ConvertTo-Json -Depth 100
        try { $null = $out | ConvertFrom-Json -ErrorAction Stop } catch { Write-Fail "Refusing to write malformed settings.json"; return }
        Copy-Item -LiteralPath $Path -Destination "$Path.bak-$stamp" -Force
        Set-Content -LiteralPath $Path -Value $out -Encoding UTF8
        Write-OK "graphify grep hook appended to PreToolUse (backup: $Path.bak-$stamp)"
    }

    # VS Code Copilot global steering (user settings.json). Off by default; -ConfigureVsCodeGlobal opts in.
    function Initialize-GraphifyVsCodeSteering {
        $vs = "$env:APPDATA\Code\User\settings.json"
        $entryText = 'When graphify-out/graph.json exists in the workspace, first run `graphify query "<question>"` (or `graphify path`/`explain`) for codebase questions instead of grepping raw files; prefer graphify-out/wiki/index.md for broad navigation; run `graphify update .` after code changes. Inert when no graph is present.'
        if (-not (Test-Path -LiteralPath $vs)) { Write-Info "VS Code user settings.json not found - skipping ($vs)"; return }
        $raw = Get-Content -LiteralPath $vs -Raw
        if ($raw -and ($raw -match 'graphify-out/graph\.json')) { Write-OK "VS Code global graphify steering already present: $vs"; return }
        if (-not $ConfigureVsCodeGlobal) {
            Write-Warn "VS Code has no global instruction file (known GAP). Add graphify steering manually under"
            Write-Warn "  github.copilot.chat.codeGeneration.instructions  in $vs :"
            Write-Warn "    { ""text"": ""$entryText"" }"
            Write-Warn "  Or re-run with -ConfigureVsCodeGlobal to let this script add it (settings.json gets JSON-normalized)."
            return
        }
        $stripped = ($raw -split "`n" | Where-Object { $_ -notmatch '^\s*//' }) -join "`n"
        try { $json = $stripped | ConvertFrom-Json -ErrorAction Stop }
        catch { Write-Warn "VS Code settings.json could not be parsed safely (JSONC) - add the entry manually (see above)."; return }
        $key = 'github.copilot.chat.codeGeneration.instructions'
        $entry = [pscustomobject]@{ text = $entryText }
        if ($json.PSObject.Properties[$key]) { $json.$key = @($json.$key) + $entry }
        else { $json | Add-Member -NotePropertyName $key -NotePropertyValue @($entry) -Force }
        $out = $json | ConvertTo-Json -Depth 100
        try { $null = $out | ConvertFrom-Json -ErrorAction Stop } catch { Write-Fail "Refusing to write malformed VS Code settings.json"; return }
        Copy-Item -LiteralPath $vs -Destination "$vs.bak-$stamp" -Force
        Set-Content -LiteralPath $vs -Value $out -Encoding UTF8
        Write-Warn "VS Code global graphify steering added (backup: $vs.bak-$stamp). Comments/formatting were normalized by JSON round-trip."
    }

    # Re-patch the vendored /graphify SKILL Step 3 so it never prompts for an API key.
    # `graphify install` rewrites SKILL.md from the package on every run, so this correction
    # is re-applied each time. The key-check region is matched by anchors (no literal em-dash
    # needed); if upstream reworded it the match fails and this no-ops - the conditional
    # steering block still carries the no-key note.
    function Repair-GraphifySkillApiKey {
        param([string]$SkillPath)
        if (-not (Test-Path -LiteralPath $SkillPath)) { return }
        $skillRaw = (Get-Content -LiteralPath $SkillPath -Raw -Encoding UTF8) -replace "`r`n", "`n"
        if ($skillRaw -match '\*\*No API key is needed\.\*\*') {
            Write-OK "graphify SKILL Step 3 already no-key: $SkillPath"; return
        }
        if ($skillRaw -notmatch '(?s)\*\*Before dispatching subagents:\*\*.*?\*\*Run Part A \(AST\)') {
            Write-Info "  graphify SKILL Step 3 anchors not found (upstream reworded?) - relying on steering block: $SkillPath"; return
        }
        $newRegion = (@'
**No API key is needed.** You are running inside a coding-agent session (Claude Code, Claude VS Code, Copilot) where the host session itself is the LLM: dispatch the Part B subagents below and they perform the semantic extraction directly. Do NOT check for, ask for, or prompt the user to set any API key, and do NOT pause to install anything. graphify does **not** read `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, or any other provider key. If any prompt to supply an API key for extraction appears, it is a misread of this skill - ignore it and dispatch subagents as written.

**Headless/CI fallback only (no host session):** if and only if `GEMINI_API_KEY` or `GOOGLE_API_KEY` is already present in the environment, you may use `graphify.llm.extract_corpus_parallel(files, backend="gemini")` instead of subagent dispatch (default model `gemini-3-flash-preview`; override via `GRAPHIFY_GEMINI_MODEL` or `--model`). Never prompt the user to set these; if they are unset, fall straight through to subagent dispatch.
'@ -replace "`r`n", "`n").TrimEnd("`n") + "`n`n"
        $patched = [regex]::Replace($skillRaw, '(?s)\*\*Before dispatching subagents:\*\*.*?(?=\*\*Run Part A \(AST\))', ({ param($m) $newRegion }).GetNewClosure())
        [System.IO.File]::WriteAllText($SkillPath, $patched, (New-Object System.Text.UTF8Encoding($false)))
        Write-OK "graphify SKILL Step 3 re-patched (no API-key prompt): $SkillPath"
    }

    # 1. Global SKILL install (skill files only -> GLOBAL config dir). From a temp cwd so
    #    no stray files land in a real repo. Skip a harness whose home dir is absent.
    Invoke-Maybe {
        $gfSkillTmp = Join-Path $env:TEMP "graphify-skill-init-$PID"
        New-Item -ItemType Directory -Force -Path $gfSkillTmp | Out-Null
        Push-Location $gfSkillTmp
        try {
            if (Test-Path -LiteralPath $claudeDir) {
                & $gfCmd.Source install --platform claude 2>&1 | ForEach-Object { Write-Info "  $_" }
            } else { Write-Info "  ~/.claude absent - skipping claude skill" }
            if (Test-Path -LiteralPath $copilotDir) {
                & $gfCmd.Source copilot install 2>&1 | ForEach-Object { Write-Info "  $_" }
            } else { Write-Info "  ~/.copilot absent - skipping copilot skill" }
        } finally {
            Pop-Location
            Remove-Item -LiteralPath $gfSkillTmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    } "install /graphify skill globally (claude, copilot)"

    # 1b. Re-patch each freshly installed SKILL.md so Step 3 never prompts for an API key.
    Invoke-Maybe {
        Repair-GraphifySkillApiKey -SkillPath (Join-Path $claudeDir  'skills\graphify\SKILL.md')
        Repair-GraphifySkillApiKey -SkillPath (Join-Path $copilotDir 'skills\graphify\SKILL.md')
    } "re-patch /graphify SKILL Step 3 (no API-key prompt)"

    # 2. Conditional steering block into the global instruction files (idempotent).
    Invoke-Maybe { Initialize-GraphifyBlock -Path $claudeMd    -Marker $gfBlockMarker -Block ($gfClaudeHeader.Trim() + "`n`n" + $gfUsageBlock.Trim()) } "ensure graphify steering in ~/.claude/CLAUDE.md"
    Invoke-Maybe { Initialize-GraphifyBlock -Path $codexAgents -Marker $gfBlockMarker -Block ($gfUsageBlock.Trim()) } "ensure graphify steering in $codexAgents"

    # 3. Claude grep-steering PreToolUse hook (idempotent, validated, backed up).
    Invoke-Maybe { Initialize-GraphifyGrepHook -Path $claudeSettings -HookCmd $gfGrepHookCmd -Marker $gfHookMarker } "ensure graphify grep hook in ~/.claude/settings.json"

    # 4. VS Code Copilot global steering (opt-in via -ConfigureVsCodeGlobal; else warns).
    Invoke-Maybe { Initialize-GraphifyVsCodeSteering } "ensure graphify VS Code global steering"
}

# ==============================================================================
# PHASE 8c - global harness base rules (always-on, unconditional)
# ==============================================================================
# Canonical Critical Rules + MCP / RTK / Headroom guidance, written to the TOP of each
# harness' GLOBAL instruction file as a marker-delimited managed region:
#   ~/.claude/CLAUDE.md, ~/.codex/AGENTS.md (or $CODEX_HOME), ~/.copilot/copilot-instructions.md
# Unlike the graphify steering in 8b, these rules are UNCONDITIONAL (no graphify-out/ guard)
# and do NOT depend on graphify being installed, so they get their own phase outside the
# graphify gate. Idempotent: the first run prepends the block to the top of the file; a
# re-run refreshes the text BETWEEN the markers in place. HTML-comment markers avoid
# colliding with any hand-written heading text already in those files.
Write-Step "PHASE 8c - global harness base rules"

$hrBeginMarker = '<!-- BEGIN managed:global-harness-rules -->'
$hrEndMarker   = '<!-- END managed:global-harness-rules -->'

$hrBlock = @'
## Critical Rules

- Accuracy, pragmatism, and honesty are critical. State facts; avoid unsupported opinions.
- Be concise and focused. Short, direct responses. No filler, no preamble, no trailing summaries.
- Use caveman compression principles. Strip articles, connectives, filler, and passive voice. Keep facts, numbers, names, technical terms, commands, paths, and constraints.
- Compress working notes harder than final answers. Plans, scratch text, and progress updates may use fragments. Final user-facing answers must stay readable.
- Never trade brevity for ambiguity. If compression would hide risk, uncertainty, or a blocker, state it plainly.

## MCP Servers

- Prefer CLI tools over MCP servers when an equivalent CLI is available. Use MCP only when it provides session-specific value that the CLI does not.
- Global MCP servers may be configured, but keep them disabled by default. Enable a specific MCP server only when the current session needs it, then disable it again when that need is gone.

## RTK - Token-Optimized Commands

- Prefer `rtk` for external CLI commands when available. Unknown commands pass through unchanged, so RTK is safe for normal command use.
- Prefix command chains segment-by-segment. Example: `rtk git status && rtk dotnet test`.
- Common commands: `rtk git`, `rtk gh`, `rtk dotnet`, `rtk npm`, `rtk pnpm`, `rtk npx`, `rtk cargo`, `rtk docker`, `rtk kubectl`, `rtk curl`, `rtk grep`, `rtk ls`, `rtk find`.
- Useful wrappers: `rtk summary <cmd>`, `rtk err <cmd>`, `rtk log <file>`, `rtk json <file>`, `rtk diff`, `rtk proxy <cmd>`.

## Headroom

- Headroom is globally used as the context optimization layer alongside RTK.
- Headroom proxy runs at system startup and normally listens on `http://127.0.0.1:8787`.
- Default startup mode: token optimization enabled, caching enabled, rate limiting enabled, telemetry disabled, memory enabled (multi-provider), OSS license.
- Health endpoints include `/livez`, `/readyz`, `/health`, `/stats`, `/stats-history`, and `/metrics`.
- Codex/OpenAI-compatible traffic routes through `/v1/responses` and `/v1/chat/completions` via `http://127.0.0.1:8787/v1`.
- Use `rtk headroom ...` for Headroom CLI calls. Common commands: `rtk headroom memory list`, `rtk headroom memory stats`, `rtk headroom diff`, `rtk headroom sg`, `rtk headroom loc`, `rtk headroom perf`, and `rtk headroom install status`.
- If model calls fail with proxy/connectivity errors, check Headroom health/listening state before changing model/provider configuration.
'@

# Prepend (first run) or refresh-in-place (re-run) a marker-delimited managed block.
# Skips a harness whose global file is absent; backs up before any write; refuses to
# touch a file whose markers are malformed (only one of the pair present).
function Initialize-ManagedBlock {
    param([string]$Path, [string]$BeginMarker, [string]$EndMarker, [string]$Block)
    if (-not (Test-Path -LiteralPath $Path)) { Write-Info "Not present, skipping: $Path"; return }
    $raw = Get-Content -LiteralPath $Path -Raw
    if ($null -eq $raw) { $raw = '' }
    $managed = $BeginMarker + "`n" + $Block.Trim() + "`n" + $EndMarker
    $bi = $raw.IndexOf($BeginMarker)
    $ei = $raw.IndexOf($EndMarker)
    if ($bi -ge 0 -and $ei -gt $bi) {
        $new = $raw.Substring(0, $bi) + $managed + $raw.Substring($ei + $EndMarker.Length)
        if ($new -eq $raw) { Write-OK "harness base rules already current: $Path"; return }
        Copy-Item -LiteralPath $Path -Destination "$Path.bak-$stamp" -Force
        Set-Content -LiteralPath $Path -Value $new -Encoding UTF8
        Write-OK "harness base rules refreshed: $Path (backup: $Path.bak-$stamp)"
    } elseif ($bi -lt 0 -and $ei -lt 0) {
        Copy-Item -LiteralPath $Path -Destination "$Path.bak-$stamp" -Force
        Set-Content -LiteralPath $Path -Value ($managed + "`n`n" + $raw.TrimStart()) -Encoding UTF8
        Write-OK "harness base rules prepended: $Path (backup: $Path.bak-$stamp)"
    } else {
        Write-Warn "managed markers malformed in $Path - leaving untouched (fix or remove the markers by hand)"
    }
}

$hrClaudeMd     = "$env:USERPROFILE\.claude\CLAUDE.md"
$hrCodexAgents  = if ($env:CODEX_HOME) { "$env:CODEX_HOME\AGENTS.md" } else { "$env:USERPROFILE\.codex\AGENTS.md" }
$hrCopilotInstr = "$env:USERPROFILE\.copilot\copilot-instructions.md"

Invoke-Maybe { Initialize-ManagedBlock -Path $hrClaudeMd     -BeginMarker $hrBeginMarker -EndMarker $hrEndMarker -Block $hrBlock } "ensure global harness rules in ~/.claude/CLAUDE.md"
Invoke-Maybe { Initialize-ManagedBlock -Path $hrCodexAgents  -BeginMarker $hrBeginMarker -EndMarker $hrEndMarker -Block $hrBlock } "ensure global harness rules in $hrCodexAgents"
Invoke-Maybe { Initialize-ManagedBlock -Path $hrCopilotInstr -BeginMarker $hrBeginMarker -EndMarker $hrEndMarker -Block $hrBlock } "ensure global harness rules in ~/.copilot/copilot-instructions.md"

# ==============================================================================
# PHASE 9 - Desktop + Startup shortcuts
# ==============================================================================
Write-Step "PHASE 9 - Desktop and Startup shortcuts"

# Create shortcuts in both Desktop and Startup so the proxy can be launched
# manually and also auto-starts on Windows login.
Invoke-Maybe {
    $shell = New-Object -ComObject WScript.Shell
    foreach ($dir in @([Environment]::GetFolderPath("Desktop"),
                       [Environment]::GetFolderPath("Startup"))) {
        $lnk = "$dir\Headroom Proxy.lnk"
        $sc  = $shell.CreateShortcut($lnk)
        $sc.TargetPath       = $RunProxyCmd
        $sc.WorkingDirectory = $env:USERPROFILE
        $sc.WindowStyle      = 1
        $sc.Save()
        Write-OK "Shortcut: $lnk"
    }
} "create Desktop + Startup shortcuts"

# ==============================================================================
# PHASE 10 - Start Headroom proxy
# ==============================================================================
Write-Step "PHASE 10 - Start Headroom proxy"

Invoke-Maybe {
    # Clear the port first in case anything is still holding it from before Phase 4
    Stop-PortListener -port $ProxyPort | Out-Null

    $env:HEADROOM_TELEMETRY         = "off"
    $env:HEADROOM_REQUIRE_RUST_CORE = "false"
    Start-Process -FilePath $RunProxyCmd -WorkingDirectory $env:USERPROFILE -WindowStyle Normal

    # Poll /readyz for up to 20s - proxy needs a few seconds to initialize
    Write-Info "Proxy window launched. Polling /readyz (up to 20s)..."
    $ready = $false
    for ($i = 0; $i -lt 5 -and -not $ready; $i++) {
        Start-Sleep -Seconds 4
        try {
            $null = Invoke-RestMethod "http://127.0.0.1:$ProxyPort/readyz" `
                        -TimeoutSec 3 -ErrorAction Stop
            $ready = $true
        } catch { }
    }

    if ($ready) { Write-OK "Proxy ready on :$ProxyPort" }
    else        { Write-Warn "Proxy did not respond to /readyz - check the console window" }
} "start headroom proxy"

# ==============================================================================
# PHASE 11 - Final verification
# ==============================================================================
Write-Step "PHASE 11 - Final verification"

# Reload PATH so verification uses the same state any new shell will see
$env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
            [Environment]::GetEnvironmentVariable("Path","User")

Write-Info ""
Write-Info "-- Target versions resolved this run ----------------------"
Write-Info "  headroom-ai : $HeadroomVersion  (wheel-installable on Windows, cp<=313)"
Write-Info "  RTK         : $RtkVersion"
Write-Info "  graphify    : $(if ($GraphifyLatest)  { $GraphifyLatest }  else { '(resolved at install)' })"
Write-Info "  Python      : $(if ($PythonLatest) { $PythonLatest } else { '(Install Manager managed)' })"

Write-Info ""
Write-Info "-- Python -------------------------------------------------"
try {
    Write-Info "  where    : $((where.exe python 2>$null) -join ' | ')"
    $pyInfo = python -c "import sys,encodings; print(sys.executable, '|', sys.version.split()[0])" 2>&1
    Write-Info "  python   : $pyInfo"
    Write-Info "  pip      : $(python -m pip --version 2>&1)"
    py -0p 2>&1 | ForEach-Object { Write-Info "  $_" }
} catch { Write-Warn "python probe: $_" }

try {
    $pyListFinal = & py list 2>&1
    if ($pyListFinal -match "WARNING.*legacy") {
        # Only escalate to WARN if Python itself is also out of date.
        # If Python is current, the legacy launcher is a cosmetic issue, not an action item.
        $currentPyVer    = ((python --version 2>&1) -replace 'Python ').Trim()
        $pythonOutOfDate = $PythonLatest -and -not (Test-VersionGte -a $currentPyVer -b $PythonLatest)
        if ($pythonOutOfDate) {
            Write-Warn "Legacy Python Launcher + Python out of date (installed: $currentPyVer, latest: $PythonLatest)."
            Write-Warn "To upgrade and enable 'py install' management:"
            Write-Warn "  1. Settings -> Installed Apps -> remove 'Python Launcher'"
            Write-Warn "  2. winget install 9NQ7512CXL7T -e --accept-package-agreements --accept-source-agreements"
            Write-Warn "  3. Re-run this script"
        } else {
            Write-Info "  Note: legacy py.exe launcher active (C:\Windows\py.exe); Python $currentPyVer is current."
            Write-Info "  Optional: replace launcher with Install Manager for 'py install' support."
        }
    }
} catch { }

# headroom-ai needs Python <= 3.13 (no cp314 wheel). Confirm one is available so
# the next Headroom version bump can rebuild the runtime.
$py313Final = Resolve-PythonBase -MaxMinor 13
if ($py313Final) { Write-OK "Headroom-capable Python (<=3.13): $py313Final" }
else { Write-Warn "No Python <=3.13 - Headroom cannot rebuild on next version bump. Install: winget install Python.Python.3.13" }

Write-Info ""
Write-Info "-- RTK ----------------------------------------------------"
try {
    Write-Info "  version  : $(rtk --version 2>&1)"
    rtk gain 2>&1 | Select-Object -First 5 | ForEach-Object { Write-Info "  $_" }
    rtk init --show 2>&1 | ForEach-Object { Write-Info "  $_" }
} catch { Write-Warn "rtk probe: $_" }

Write-Info ""
Write-Info "-- Headroom (shim) ----------------------------------------"
try {
    Write-Info "  version  : $(Get-HeadroomVersion)"

    # 'No deployment profile named default' is expected - it means headroom is not
    # installed as a Windows service or scheduled task, which is correct here.
    # We use the Startup folder shortcut instead, which is simpler and more visible.
    $hsStatus = headroom install status 2>&1
    $hsStatus | Where-Object { $_ -notmatch "No deployment profile" } |
        ForEach-Object { Write-Info "    $_" }
    if ($hsStatus -match "No deployment profile") {
        Write-Info "    (no managed service profile - using Startup shortcut, which is correct)"
    }
} catch { Write-Warn "headroom probe: $_" }

Write-Info ""
Write-Info "-- Knowledge-graph tool -----------------------------------"
try {
    $graphifyCmd = Get-Command graphify -ErrorAction SilentlyContinue
    if ($graphifyCmd) {
        $gv = & $graphifyCmd.Source --version 2>&1
        if ($LASTEXITCODE -eq 0) { Write-OK "graphify : $gv" } else { Write-Info "  graphify : probe failed (optional)" }
    } else { Write-Info "  graphify : not installed (optional)" }
} catch { Write-Info "  graphify : not installed (optional)" }

Write-Info ""
Write-Info "-- graphify global steering (inert until a repo has graphify-out/graph.json) --"
$vGfClaudeMd       = "$env:USERPROFILE\.claude\CLAUDE.md"
$vGfClaudeSettings = "$env:USERPROFILE\.claude\settings.json"
$vGfCodexAgents    = if ($env:CODEX_HOME) { "$env:CODEX_HOME\AGENTS.md" } else { "$env:USERPROFILE\.codex\AGENTS.md" }
$vGfClaudeSkill    = "$env:USERPROFILE\.claude\skills\graphify"
$vGfCopilotSkill   = "$env:USERPROFILE\.copilot\skills\graphify"
function Test-FileContains([string]$p, [string]$m) {
    return ((Test-Path -LiteralPath $p) -and ((Get-Content -LiteralPath $p -Raw) -match [regex]::Escape($m)))
}
if (Test-Path -LiteralPath $vGfClaudeSkill)  { Write-OK "skill (claude)  : $vGfClaudeSkill" }  else { Write-Info "  skill (claude)  : not installed" }
if (Test-Path -LiteralPath $vGfCopilotSkill) { Write-OK "skill (copilot) : $vGfCopilotSkill" } else { Write-Info "  skill (copilot) : not installed" }
if (Test-FileContains $vGfClaudeMd '## graphify graph usage')    { Write-OK "steering        : ~/.claude/CLAUDE.md" }    else { Write-Warn "steering MISSING: ~/.claude/CLAUDE.md" }
if (Test-FileContains $vGfCodexAgents '## graphify graph usage') { Write-OK "steering        : $vGfCodexAgents" }       else { Write-Info "  steering        : $vGfCodexAgents (codex absent or not wired)" }
if (Test-FileContains $vGfClaudeSettings 'graphify: knowledge graph at graphify-out/') { Write-OK "grep hook       : ~/.claude/settings.json" } else { Write-Warn "grep hook MISSING: ~/.claude/settings.json" }
if (Test-Path -LiteralPath "$vGfClaudeSkill\SKILL.md")  { if (Test-FileContains "$vGfClaudeSkill\SKILL.md" 'No API key is needed.')  { Write-OK "skill no-key    : ~/.claude/skills/graphify/SKILL.md" }  else { Write-Warn "skill no-key MISSING: ~/.claude/skills/graphify/SKILL.md (Step 3 may prompt for an API key)" } }
if (Test-Path -LiteralPath "$vGfCopilotSkill\SKILL.md") { if (Test-FileContains "$vGfCopilotSkill\SKILL.md" 'No API key is needed.') { Write-OK "skill no-key    : ~/.copilot/skills/graphify/SKILL.md" } else { Write-Warn "skill no-key MISSING: ~/.copilot/skills/graphify/SKILL.md (Step 3 may prompt for an API key)" } }

Write-Info ""
Write-Info "-- global harness base rules (always-on, unconditional) ---"
$vHrMarker      = '<!-- BEGIN managed:global-harness-rules -->'
$vHrCopilot     = "$env:USERPROFILE\.copilot\copilot-instructions.md"
if (Test-FileContains $vGfClaudeMd $vHrMarker)    { Write-OK "base rules      : ~/.claude/CLAUDE.md" }                else { Write-Warn "base rules MISSING: ~/.claude/CLAUDE.md" }
if (Test-FileContains $vGfCodexAgents $vHrMarker) { Write-OK "base rules      : $vGfCodexAgents" }                    else { Write-Info "  base rules      : $vGfCodexAgents (codex absent or not wired)" }
if (Test-FileContains $vHrCopilot $vHrMarker)     { Write-OK "base rules      : ~/.copilot/copilot-instructions.md" } else { Write-Info "  base rules      : ~/.copilot/copilot-instructions.md (copilot absent or not wired)" }

Write-Info ""
Write-Info "-- Proxy endpoints ----------------------------------------"
foreach ($ep in "/livez","/readyz","/health","/stats") {
    try {
        $resp = Invoke-RestMethod "http://127.0.0.1:$ProxyPort$ep" -TimeoutSec 4 -ErrorAction Stop
        switch ($ep) {
            "/livez"  { Write-OK "/livez  : status=$($resp.status) alive=$($resp.alive) version=$($resp.version)" }
            "/readyz" { Write-OK "/readyz : status=$($resp.status) ready=$($resp.ready) version=$($resp.version) rust_core=$($resp.rust_core)" }
            "/health" { Write-OK "/health : status=$($resp.status) version=$($resp.version) rust_core=$($resp.rust_core)" }
            "/stats"  {
                # Extract named scalar fields only - avoids JSON depth truncation warnings
                # that occur when serializing the full nested stats object.
                Write-OK "/stats  : requests_total=$($resp.requests_total) tokens_saved_total=$($resp.tokens_saved_total) cache_hits=$($resp.cache_hits) uptime_seconds=$($resp.uptime_seconds)"
            }
        }
    } catch { Write-Warn "${ep} : $($_.Exception.Message)" }
}

Write-Info ""
Write-Info "-- Routing + telemetry env vars (user scope) --------------"
Write-Info "  ANTHROPIC_BASE_URL  : $([Environment]::GetEnvironmentVariable('ANTHROPIC_BASE_URL','User'))"
Write-Info "  OPENAI_BASE_URL     : $([Environment]::GetEnvironmentVariable('OPENAI_BASE_URL','User'))"
Write-Info "  HEADROOM_TELEMETRY  : $([Environment]::GetEnvironmentVariable('HEADROOM_TELEMETRY','User'))"
Write-Info "  HEADROOM_ENSURE_CMD : $([Environment]::GetEnvironmentVariable('HEADROOM_ENSURE_CMD','User'))"

# -- Harness routing + config integrity ---------------------------------------
# Confirms the harnesses are actually pointed at the local proxy and that no init
# (this script OR another process) left a harness config malformed. Detection only:
# a warning here means "re-run this script", which self-heals via the Phase 8 repair.
Write-Info ""
Write-Info "-- Harness routing + config integrity ---------------------"

# Claude + Codex must point at the local proxy via the BASE_URL vars (the proxy holds
# no keys; each harness forwards its own auth). Verify they are set, not just print.
$expectAnthropic = "http://127.0.0.1:$ProxyPort"
$expectOpenAI    = "http://127.0.0.1:$ProxyPort/v1"
$curAnthropic    = [Environment]::GetEnvironmentVariable('ANTHROPIC_BASE_URL','User')
$curOpenAI       = [Environment]::GetEnvironmentVariable('OPENAI_BASE_URL','User')
if ($curAnthropic -eq $expectAnthropic) { Write-OK "ANTHROPIC_BASE_URL -> proxy (Claude Code routing)" }
else { Write-Warn "ANTHROPIC_BASE_URL is '$curAnthropic' (expected $expectAnthropic) - Claude Code will NOT route through the proxy" }
if ($curOpenAI -eq $expectOpenAI) { Write-OK "OPENAI_BASE_URL -> proxy (Codex / OpenAI-protocol routing)" }
else { Write-Warn "OPENAI_BASE_URL is '$curOpenAI' (expected $expectOpenAI) - Codex / OpenAI clients will NOT route through the proxy" }

# Codex config.toml: single, root-scoped Headroom provider, no spurious env_key.
$icCodex = if ($env:CODEX_HOME) { "$env:CODEX_HOME\config.toml" } else { "$env:USERPROFILE\.codex\config.toml" }
if (Test-Path -LiteralPath $icCodex) {
    $ct = (Get-Content -LiteralPath $icCodex -Raw) -replace "`r`n", "`n"
    $provCount = ([regex]::Matches($ct, '(?m)^[ \t]*\[model_providers\.headroom\]')).Count
    if ($provCount -gt 1) {
        Write-Warn "codex config.toml: $provCount [model_providers.headroom] tables -> TOML duplicate-key crash. Re-run this script to auto-repair."
    } elseif ($provCount -eq 1) {
        $mpIdx  = $ct.IndexOf('model_provider = "headroom"')
        $tblM   = [regex]::Match($ct, '(?m)^[ \t]*\[')
        $tblIdx = if ($tblM.Success) { $tblM.Index } else { -1 }
        if ($mpIdx -lt 0) {
            Write-Warn "codex config.toml: provider table present but no model_provider directive - Codex will not select it."
        } elseif ($tblIdx -ge 0 -and $mpIdx -gt $tblIdx) {
            Write-Warn "codex config.toml: model_provider nested under a table, not root - routing inactive. Re-run to auto-repair."
        } elseif (($ct -match '(?m)^[ \t]*env_key[ \t]*=[ \t]*"OPENAI_API_KEY"') -and ($ct -match 'requires_openai_auth[ \t]*=[ \t]*true')) {
            Write-Warn "codex config.toml: env_key set with requires_openai_auth -> 'Missing OPENAI_API_KEY' on ChatGPT login. Re-run to auto-repair."
        } else {
            Write-OK "codex config.toml: single root-scoped Headroom provider, no spurious env_key"
        }
    } else {
        Write-Info "  codex config.toml: no Headroom provider (codex absent / not wired)"
    }
} else {
    Write-Info "  codex config.toml: not present"
}

# JSON harness configs must parse - a malformed hook file silently disables the harness.
foreach ($jc in @(
    @{ Name = "~/.claude/settings.json"; Path = "$env:USERPROFILE\.claude\settings.json" },
    @{ Name = "~/.copilot/config.json";  Path = "$env:USERPROFILE\.copilot\config.json"  }
)) {
    if (Test-Path -LiteralPath $jc.Path) {
        try { $null = Get-Content -LiteralPath $jc.Path -Raw | ConvertFrom-Json -ErrorAction Stop; Write-OK "$($jc.Name): valid JSON" }
        catch { Write-Warn "$($jc.Name): does NOT parse - $($_.Exception.Message)" }
    } else { Write-Info "  $($jc.Name): not present" }
}

Write-Host "`n=== Done ===" -ForegroundColor Green
Write-Host @"

Pass criteria:
  python    -> resolves to intended runtime, import encodings OK
  pip       -> works
  rtk       -> v$RtkVersion or newer, telemetry disabled
  headroom  -> v$HeadroomVersion (wheel-installable, shim runtime), telemetry disabled
  graphify  -> installed globally with uv tool (`graphifyy` package, `graphify` CLI)
  graphify global steering -> skill + conditional block (CLAUDE.md / AGENTS.md) +
            grep hook (settings.json) wired GLOBALLY but INERT until a repo has
            graphify-out/graph.json. VS Code global steering is opt-in (-ConfigureVsCodeGlobal).
  global harness base rules -> Critical Rules + MCP/RTK/Headroom block written to the
            top of CLAUDE.md / AGENTS.md / copilot-instructions.md as a marked managed
            region (always-on; re-runs refresh in place between the markers).
  /livez + /readyz -> healthy
  /health   -> ready (rust_core:disabled is OK on Python without Rust wheel)
  /stats    -> counters visible
  ANTHROPIC_BASE_URL + OPENAI_BASE_URL -> set via setx
  HEADROOM_TELEMETRY -> off
  HEADROOM_ENSURE_CMD -> points to lightweight proxy-ensure.cmd
  Python <=3.13 present -> required for future Headroom runtime rebuilds (no cp314 wheel)

Action required after this script:
  Restart Claude Code, Codex, and any IDE so they pick up the new setx vars.
  This script does NOT update the harness binaries themselves - they self-update,
  and a machine may run only some of them.
  Global graphify steering IS wired now (skill + conditional block + grep hook), but
  stays inert in a repo until that repo builds a graph.
  Per-repo (opt-in, not done here): in a repo that warrants a graph, paste
  misc/apply-graphify-to-repo.txt - it measures the layer, optionally enables the
  claude/codex/copilot repo harnesses, and builds the graph from the repo root
  ('graphify .' for the full AST + semantic layer, or the structure-only AST-only
  path) to create graphify-out/graph.json. See support/context-tooling.md for the
  layer choice. To strip graphify wiring that leaked into a repo's tracked files, run
  misc/strip-graphify-repo-wiring.ps1 from that repo.
"@
