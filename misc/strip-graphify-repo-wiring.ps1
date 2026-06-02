#Requires -Version 5.1
<#
.SYNOPSIS
  Strip graphify WIRING from a repo's TRACKED files (concern C: de-contamination).

  graphify global steering lives in your machine-global config and is wired by
  misc/update-python-and-context-tools.ps1. It must NEVER be committed into a repo's
  tracked files - if it is, it rides the install payload into every app scaffolded from
  a template repo. This script removes graphify steering that leaked into the CURRENT
  repo's tracked files, while leaving the machine-global steering and the built graph
  (graphify-out/) untouched.

  What it removes (repo-local only):
    - CLAUDE.md                          graphify section
    - AGENTS.md                          graphify section
    - .github/copilot-instructions.md    graphify section (manual strip - so the GLOBAL
                                         Copilot skill is never removed)
    - .cursor/rules/graphify.mdc         deleted
    - .claude/settings.json              graphify PreToolUse hook
    - .codex/hooks.json                  graphify hook entries

  What it PRESERVES:
    - machine-global instruction files (~/.claude/CLAUDE.md, ~/.claude/settings.json,
      ~/.codex/AGENTS.md) are hash-snapshotted before any graphify uninstall and RESTORED
      if an uninstall reaches outside the repo.
    - the global graphify skills (~/.claude/skills/graphify, ~/.copilot/skills/graphify) are
      never touched: this script never runs `graphify copilot uninstall` or the blanket
      `graphify uninstall`, and it refuses to run against a global config root (guard below).
    - the built graph at graphify-out/ (the graph itself is not "wiring"). To delete
      the graph too, run `graphify uninstall --purge` or remove graphify-out/ by hand.

  Mechanism: prefers `graphify claude uninstall` / `graphify codex uninstall` (they know
  their own block + hook format) and falls back to deterministic text/JSON stripping if
  the graphify CLI is absent or leaves residue. vscode is ALWAYS stripped manually so the
  global skill survives (`graphify vscode uninstall` can remove it).

.PARAMETER Path
  Repo root to clean. Default: current directory.

.PARAMETER DryRun
  Report what would change without writing.

.NOTES
  Idempotent: safe to run on a clean repo (no-op). Prefer running under pwsh 7; on
  Windows PowerShell 5.1 the JSON serializer can collapse a single-element array, so the
  settings.json fallback validates the result shape and refuses to write if it would.
#>
[CmdletBinding()]
param(
    [string]$Path = ".",
    [switch]$DryRun
)

$ErrorActionPreference = "Continue"
Set-StrictMode -Off

function Write-Step ([string]$m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Write-OK   ([string]$m) { Write-Host "  OK  : $m"  -ForegroundColor Green }
function Write-Warn ([string]$m) { Write-Host "  WARN: $m"  -ForegroundColor Yellow }
function Write-Fail ([string]$m) { Write-Host "  FAIL: $m"  -ForegroundColor Red }
function Write-Info ([string]$m) { Write-Host "  $m" }

$repo = (Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue).Path
if (-not $repo) { Write-Fail "Path not found: $Path"; exit 1 }

# Refuse to run against a machine-global config root. This script strips REPO-local wiring
# only; the manual strip writes Join-Path $repo files directly, so pointing -Path at
# ~/.claude (etc.) would edit global config. Global steering is owned by
# update-python-and-context-tools.ps1 - never strip it here.
$globalRoots = @("$env:USERPROFILE\.claude", "$env:USERPROFILE\.codex", "$env:USERPROFILE\.copilot")
if ($env:CODEX_HOME) { $globalRoots += $env:CODEX_HOME }
$repoNorm = $repo.TrimEnd('\', '/').ToLowerInvariant()
foreach ($gr in $globalRoots) {
    $grPath = (Resolve-Path -LiteralPath $gr -ErrorAction SilentlyContinue).Path
    if (-not $grPath) { continue }
    $grNorm = $grPath.TrimEnd('\', '/').ToLowerInvariant()
    if ($repoNorm -eq $grNorm -or $repoNorm.StartsWith($grNorm + '\')) {
        Write-Fail "Refusing to run: -Path '$repo' is (under) a machine-global config root ($gr)."
        Write-Fail "This script strips REPO-local graphify wiring only. Global steering is managed by misc/update-python-and-context-tools.ps1."
        exit 1
    }
}

Write-Step "Strip graphify repo wiring: $repo  $(if ($DryRun) { '(DryRun)' })"

# -- Removes a markdown 'graphify' section (any heading level) from a file -------------
# Section runs from the first '# graphify'/'## graphify...' heading to the next heading
# of any level that is NOT itself a graphify heading (Claude's block has both '# graphify'
# and '## graphify graph usage', so consecutive graphify headings stay in one section).
function Remove-GraphifyMarkdownSection {
    param([string]$File)
    if (-not (Test-Path -LiteralPath $File)) { return $false }
    $lines = @(Get-Content -LiteralPath $File)
    $out = New-Object System.Collections.Generic.List[string]
    $inSection = $false; $removed = $false
    foreach ($ln in $lines) {
        if ($ln -match '^#{1,6}\s*graphify\b') { $inSection = $true; $removed = $true; continue }
        if ($inSection -and $ln -match '^#{1,6}\s+\S') { $inSection = $false }   # next non-graphify heading ends it
        if (-not $inSection) { $out.Add($ln) }
    }
    if (-not $removed) { return $false }
    while ($out.Count -gt 0 -and [string]::IsNullOrWhiteSpace($out[$out.Count - 1])) { $out.RemoveAt($out.Count - 1) }
    if (-not $DryRun) {
        Copy-Item -LiteralPath $File -Destination "$File.graphify-bak" -Force
        Set-Content -LiteralPath $File -Value $out -Encoding UTF8
    }
    Write-OK "stripped graphify section: $File$(if ($DryRun) { ' (would)' })"
    return $true
}

# -- Removes graphify PreToolUse hook entries from a project hooks/settings JSON --------
function Remove-GraphifyHookFromJson {
    param([string]$File)
    if (-not (Test-Path -LiteralPath $File)) { return $false }
    $raw = Get-Content -LiteralPath $File -Raw
    if ($raw -notmatch 'graphify') { return $false }
    try { $json = $raw | ConvertFrom-Json -ErrorAction Stop }
    catch { Write-Warn "$File does not parse - skipping (strip graphify hook by hand)"; return $false }
    if (-not ($json.hooks -and $json.hooks.PSObject.Properties['PreToolUse'])) { return $false }
    $before = @($json.hooks.PreToolUse).Count
    $kept = @($json.hooks.PreToolUse | Where-Object {
        $cmds = (@($_.hooks) | ForEach-Object { $_.command }) -join "`n"
        $cmds -notmatch 'graphify'
    })
    if ($kept.Count -eq $before) { return $false }
    if ($DryRun) { Write-OK "would strip graphify hook from: $File ($before -> $($kept.Count) PreToolUse entries)"; return $true }
    $json.hooks.PreToolUse = $kept
    $outJson = $json | ConvertTo-Json -Depth 100
    # Shape guard: a 5.1 serializer can collapse a 1-element (or empty) array. Refuse to
    # write a result whose PreToolUse stopped being an array when we still expect one.
    $reparsed = $outJson | ConvertFrom-Json
    if ($kept.Count -ge 1 -and ($reparsed.hooks.PreToolUse -isnot [System.Array])) {
        Write-Warn "JSON round-trip collapsed PreToolUse to a non-array (PowerShell 5.1 quirk). Not writing $File."
        Write-Warn "Re-run under pwsh 7, or remove the graphify PreToolUse hook from $File by hand."
        return $false
    }
    Copy-Item -LiteralPath $File -Destination "$File.graphify-bak" -Force
    Set-Content -LiteralPath $File -Value $outJson -Encoding UTF8
    Write-OK "stripped graphify hook: $File ($before -> $($kept.Count) PreToolUse entries)"
    return $true
}

# == Snapshot machine-global config so we can detect/undo any out-of-repo write =========
$globalFiles = @(
    "$env:USERPROFILE\.claude\CLAUDE.md",
    "$env:USERPROFILE\.claude\settings.json",
    $(if ($env:CODEX_HOME) { "$env:CODEX_HOME\AGENTS.md" } else { "$env:USERPROFILE\.codex\AGENTS.md" })
)
$snap = @{}
foreach ($g in $globalFiles) {
    if (Test-Path -LiteralPath $g) {
        $snap[$g] = @{ Hash = (Get-FileHash -LiteralPath $g).Hash; Backup = "$env:TEMP\stripgf-$([IO.Path]::GetFileName($g))-$PID.bak" }
        Copy-Item -LiteralPath $g -Destination $snap[$g].Backup -Force
    }
}

# == 1. Manual strip of repo-tracked files (clean, heading-anchored; runs FIRST so the
#       whole graphify section is removed before graphify's own uninstall sees it, and so
#       it works even when the CLI is absent or the block is in the global-style format) =
Write-Step "Manual strip of repo-tracked files"
$changed = $false
$changed = (Remove-GraphifyMarkdownSection (Join-Path $repo "CLAUDE.md")) -or $changed
$changed = (Remove-GraphifyMarkdownSection (Join-Path $repo "AGENTS.md")) -or $changed
$changed = (Remove-GraphifyMarkdownSection (Join-Path $repo ".github\copilot-instructions.md")) -or $changed
$changed = (Remove-GraphifyHookFromJson    (Join-Path $repo ".claude\settings.json")) -or $changed
$changed = (Remove-GraphifyHookFromJson    (Join-Path $repo ".codex\hooks.json")) -or $changed

$cursorRule = Join-Path $repo ".cursor\rules\graphify.mdc"
if (Test-Path -LiteralPath $cursorRule) {
    if (-not $DryRun) { Remove-Item -LiteralPath $cursorRule -Force }
    Write-OK "removed $cursorRule$(if ($DryRun) { ' (would)' })"; $changed = $true
}

# graphify .github hook artifacts (some platforms write these)
$ghHooks = Join-Path $repo ".github\hooks"
if (Test-Path -LiteralPath $ghHooks) {
    Get-ChildItem -LiteralPath $ghHooks -Filter "*graphify*" -ErrorAction SilentlyContinue | ForEach-Object {
        if (-not $DryRun) { Remove-Item -LiteralPath $_.FullName -Force }
        Write-OK "removed $($_.FullName)$(if ($DryRun) { ' (would)' })"; $changed = $true
    }
}

# == 2. Secondary: graphify's own per-platform uninstall (claude, codex), as a catch for
#       any format the manual strip missed. Runs in the repo cwd; the global snapshot
#       above + the restore below guard against an uninstall reaching outside the repo. ==
$gf = Get-Command graphify -ErrorAction SilentlyContinue
if ($gf) {
    Write-Step "graphify uninstall (claude, codex) - secondary catch"
    Push-Location $repo
    try {
        foreach ($h in @("claude", "codex")) {
            if ($DryRun) { Write-Info "[DryRun] graphify $h uninstall"; continue }
            $o = & $gf.Source $h uninstall 2>&1 | Out-String
            $o.Trim().Split("`n") | Where-Object { $_ } | ForEach-Object { Write-Info "  $_" }
        }
    } finally { Pop-Location }
} else {
    Write-Warn "graphify CLI not on PATH - manual strip only"
}

# == 3. Safety net: restore any machine-global file an uninstall touched ================
Write-Step "Verify machine-global config untouched"
$globalTouched = $false
foreach ($g in $snap.Keys) {
    if (-not (Test-Path -LiteralPath $g)) {
        Write-Warn "GLOBAL file vanished: $g - restoring from snapshot"
        Copy-Item -LiteralPath $snap[$g].Backup -Destination $g -Force; $globalTouched = $true; continue
    }
    if ((Get-FileHash -LiteralPath $g).Hash -ne $snap[$g].Hash) {
        if ($DryRun) {
            Write-Warn "GLOBAL file WOULD have changed: $g (a graphify uninstall reached outside the repo)"
        } else {
            Write-Warn "GLOBAL file changed: $g - restoring from snapshot (uninstall reached global config)"
            Copy-Item -LiteralPath $snap[$g].Backup -Destination $g -Force
        }
        $globalTouched = $true
    }
}
if (-not $globalTouched) { Write-OK "machine-global config unchanged" }
foreach ($g in $snap.Keys) { Remove-Item -LiteralPath $snap[$g].Backup -Force -ErrorAction SilentlyContinue }

# == Report ============================================================================
Write-Step "Done"
if ($changed -and $DryRun) {
    Write-Info "Repo graphify wiring WOULD be stripped (no files written; re-run without -DryRun to apply)."
} elseif ($changed) {
    Write-Info "Repo graphify wiring stripped (originals saved as *.graphify-bak alongside each edited file)."
} else {
    Write-Info "No repo graphify wiring found - nothing to strip."
}
$gfOut = Join-Path $repo "graphify-out"
if (Test-Path -LiteralPath $gfOut) {
    Write-Info "Note: the built graph at graphify-out/ was preserved (not wiring). Delete it by hand or run 'graphify uninstall --purge' to remove the graph too."
}
Write-Info "Global graphify steering (machine-wide) is unaffected and stays inert until a repo builds a graph."
