#Requires -Version 5.1
<#
.SYNOPSIS
  Unified token-savings / efficiency report across the context-optimization tools:
  rtk (CLI output filtering), headroom (LLM proxy: prefix cache + compression),
  and graphify (knowledge-graph coverage).

  Pulls real data from each tool, scoped to a time window, and prints a single
  dashboard (or JSON / CSV for piping).

.DESCRIPTION
  Data sources:
    rtk       SQLite history at  %LOCALAPPDATA%\rtk\history.db  (table: commands).
              Queried directly so day/week/month/all windows and per-command
              top-savers are exact, and -Project can filter to one repo.
    headroom  HTTP /stats on the local proxy (default http://127.0.0.1:8787).
              Reports prefix-cache savings (the proxy's real win), compression,
              and the current session. These are LIFETIME / session figures -
              the proxy does not expose a per-day savings series, so they are
              labeled as such instead of being forced into the window.
    graphify  Filesystem scan for graphify-out\graph.json under -RepoRoot.
              graphify has NO token-savings metric (it is an AST extractor), so
              this is coverage only: graph count, node/edge counts, freshness.

  IMPORTANT - no double counting:
    headroom observes and re-reports rtk's CLI-filtering number. That overlap is
    shown for reconciliation but is NOT added into the combined total. The
    combined "unique token reduction" = rtk saved + headroom compression (two
    distinct mechanisms). Cache savings is reported separately as a cost
    discount in USD.

.PARAMETER Window
  Time window for rtk: day | week | month | all. Default: all.
  (1 day = last 24h, week = 7d, month = 30d.)

.PARAMETER Days
  Arbitrary window override in days (e.g. -Days 3). Takes precedence over -Window.

.PARAMETER Format
  Output format: text (default), json, or csv.

.PARAMETER Project
  Filter rtk stats to the current working directory's repo (prefix match on the
  recorded project_path). headroom/graphify are global regardless.

.PARAMETER RepoRoot
  Root to scan for graphify-out\graph.json. Default: <home>\source\repos.

.PARAMETER HeadroomUrl
  Base URL of the headroom proxy. Default: http://127.0.0.1:8787.

.PARAMETER Top
  Number of rtk top-saving command groups to list. Default: 6.

.PARAMETER NoColor
  Disable ANSI color in text output.

.EXAMPLE
  .\token-savings-report.ps1
  Lifetime dashboard across all three tools.

.EXAMPLE
  .\token-savings-report.ps1 -Window week
  Last 7 days for rtk; headroom lifetime/session; graphify coverage.

.EXAMPLE
  .\token-savings-report.ps1 -Window day -Project
  Last 24h, rtk scoped to the current repo.

.EXAMPLE
  .\token-savings-report.ps1 -Format json | ConvertFrom-Json
  Machine-readable merged object.
#>

[CmdletBinding()]
param(
  [ValidateSet('day', 'week', 'month', 'all')]
  [string]$Window = 'all',

  [int]$Days = 0,

  [ValidateSet('text', 'json', 'csv')]
  [string]$Format = 'text',

  [switch]$Project,

  [string]$RepoRoot = (Join-Path $HOME 'source\repos'),

  [string]$HeadroomUrl = 'http://127.0.0.1:8787',

  [int]$Top = 6,

  [switch]$NoColor
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Formatting helpers
# ---------------------------------------------------------------------------

function Format-Count {
  param([double]$n)
  if ($null -eq $n) { return 'n/a' }
  $a = [math]::Abs($n)
  if ($a -ge 1e6) { return ('{0:0.0}M' -f ($n / 1e6)) }
  if ($a -ge 1e3) { return ('{0:0.0}K' -f ($n / 1e3)) }
  return ('{0:0}' -f $n)
}

function Format-Usd {
  param([double]$n)
  if ($null -eq $n) { return 'n/a' }
  return ('${0:N2}' -f $n)
}

function Format-Ms {
  param([double]$ms)
  if (-not $ms -or $ms -le 0) { return '0ms' }
  if ($ms -ge 60000) {
    $m = [math]::Floor($ms / 60000); $s = [math]::Round(($ms % 60000) / 1000)
    return ('{0}m {1}s' -f $m, $s)
  }
  if ($ms -ge 1000) { return ('{0:0.0}s' -f ($ms / 1000)) }
  return ('{0:0}ms' -f $ms)
}

function Format-Age {
  param([datetime]$when)
  $ts = (Get-Date) - $when
  if ($ts.TotalDays -ge 1) { return ('{0:0}d ago' -f $ts.TotalDays) }
  if ($ts.TotalHours -ge 1) { return ('{0:0}h ago' -f $ts.TotalHours) }
  if ($ts.TotalMinutes -ge 1) { return ('{0:0}m ago' -f $ts.TotalMinutes) }
  return 'just now'
}

# Color writer (respects -NoColor and output redirection)
$script:UseColor = (-not $NoColor) -and (-not [Console]::IsOutputRedirected)
function Write-Line {
  param([string]$Text = '', [string]$Color = 'Gray')
  if ($script:UseColor) { Write-Host $Text -ForegroundColor $Color }
  else { Write-Host $Text }
}

# ---------------------------------------------------------------------------
# Window resolution (rtk timestamps are stored in UTC)
# ---------------------------------------------------------------------------

$nowUtc = (Get-Date).ToUniversalTime()
$cutUtc = $null
$windowLabel = 'lifetime'
if ($Days -gt 0) {
  $cutUtc = $nowUtc.AddDays(-$Days)
  $windowLabel = "past ${Days}d"
}
else {
  switch ($Window) {
    'day'   { $cutUtc = $nowUtc.AddDays(-1);  $windowLabel = 'past 24h' }
    'week'  { $cutUtc = $nowUtc.AddDays(-7);  $windowLabel = 'past 7d' }
    'month' { $cutUtc = $nowUtc.AddDays(-30); $windowLabel = 'past 30d' }
    'all'   { $cutUtc = $null;                $windowLabel = 'lifetime' }
  }
}
$cutStr = if ($cutUtc) { $cutUtc.ToString('yyyy-MM-ddTHH:mm:ss') } else { $null }
$scopeLabel = if ($Project) { 'this repo' } else { 'global' }

# ---------------------------------------------------------------------------
# rtk  (SQLite history.db)
# ---------------------------------------------------------------------------

function Get-RtkStats {
  $result = [ordered]@{
    available = $false; window = $windowLabel
    commands = 0; input = 0; output = 0; saved = 0
    pct = 0.0; exec_ms = 0; top = @(); note = $null
  }
  $sqlite = Get-Command sqlite3 -ErrorAction SilentlyContinue
  $db = Join-Path $env:LOCALAPPDATA 'rtk\history.db'
  if (-not $sqlite) { $result.note = 'sqlite3 not on PATH'; return $result }
  if (-not (Test-Path $db)) { $result.note = "no history.db at $db"; return $result }

  # Build WHERE clause
  $where = '1=1'
  if ($cutStr) { $where += " AND timestamp >= '$cutStr'" }
  if ($Project) {
    $cwd = (Get-Location).Path.Replace("'", "''")
    # stored project_path carries a \\?\ long-path prefix
    $where += " AND replace(project_path, '\\?\', '') LIKE '$cwd%'"
  }

  try {
    $agg = & sqlite3 $db "SELECT COUNT(*), COALESCE(SUM(input_tokens),0), COALESCE(SUM(output_tokens),0), COALESCE(SUM(saved_tokens),0), COALESCE(SUM(exec_time_ms),0) FROM commands WHERE $where;"
    if ($agg) {
      $p = $agg.Split('|')
      $result.commands = [int64]$p[0]
      $result.input    = [int64]$p[1]
      $result.output   = [int64]$p[2]
      $result.saved    = [int64]$p[3]
      $result.exec_ms  = [int64]$p[4]
      if ($result.input -gt 0) { $result.pct = [math]::Round($result.saved * 100.0 / $result.input, 1) }
      $result.available = $true
    }

    # Top saving command groups (group by the tool word after "rtk ")
    $topSql = @"
WITH base AS (
  SELECT TRIM(substr(rtk_cmd, instr(rtk_cmd,' ')+1)) AS rest, saved_tokens
  FROM commands WHERE $where AND rtk_cmd LIKE 'rtk %'
)
SELECT CASE WHEN instr(rest,' ')>0 THEN substr(rest,1,instr(rest,' ')-1) ELSE rest END AS tool,
       SUM(saved_tokens) AS s, COUNT(*) AS c
FROM base GROUP BY tool HAVING s > 0 ORDER BY s DESC LIMIT $Top;
"@
    $rows = & sqlite3 $db $topSql
    foreach ($r in $rows) {
      if (-not $r) { continue }
      $f = $r.Split('|')
      $result.top += [ordered]@{ cmd = ('rtk ' + $f[0]); saved = [int64]$f[1]; count = [int]$f[2] }
    }
  }
  catch { $result.note = "query failed: $($_.Exception.Message)" }
  return $result
}

# ---------------------------------------------------------------------------
# headroom  (HTTP /stats)
# ---------------------------------------------------------------------------

function Get-HeadroomStats {
  $result = [ordered]@{
    available = $false; url = $HeadroomUrl; mode = $null
    cache_usd = 0.0; cache_hit_pct = 0.0; cache_read_tokens = 0
    comp_tokens = 0; comp_usd = 0.0
    life_requests = 0; life_input = 0; life_cost_usd = 0.0
    cli_filtering_tokens = 0
    session = $null; note = $null
  }
  try {
    $s = Invoke-RestMethod -Uri "$HeadroomUrl/stats" -TimeoutSec 5 -ErrorAction Stop
  }
  catch {
    $result.note = 'proxy unreachable (is headroom running?)'
    return $result
  }
  $result.available = $true
  $result.mode = $s.summary.mode

  if ($s.prefix_cache -and $s.prefix_cache.totals) {
    $t = $s.prefix_cache.totals
    $result.cache_usd         = [double]$t.net_savings_usd
    $result.cache_hit_pct     = [double]$t.hit_rate
    $result.cache_read_tokens = [int64]$t.cache_read_tokens
  }
  if ($s.persistent_savings -and $s.persistent_savings.lifetime) {
    $l = $s.persistent_savings.lifetime
    $result.comp_tokens   = [int64]$l.tokens_saved
    $result.comp_usd      = [double]$l.compression_savings_usd
    $result.life_requests = [int64]$l.requests
    $result.life_input    = [int64]$l.total_input_tokens
    $result.life_cost_usd = [double]$l.total_input_cost_usd
  }
  if ($s.cli_filtering) { $result.cli_filtering_tokens = [int64]$s.cli_filtering.tokens_saved }
  if ($s.display_session) {
    $d = $s.display_session
    $result.session = [ordered]@{
      requests = [int64]$d.requests
      input    = [int64]$d.total_input_tokens
      cost_usd = [double]$d.total_input_cost_usd
      started  = $d.started_at
    }
  }
  return $result
}

# ---------------------------------------------------------------------------
# graphify  (coverage scan - no token metric)
# ---------------------------------------------------------------------------

function Get-GraphifyCoverage {
  $result = [ordered]@{
    root = $RepoRoot; scanned = $false; graphs = @(); note = $null
  }
  if (-not (Test-Path $RepoRoot)) { $result.note = "root not found: $RepoRoot"; return $result }
  $result.scanned = $true
  try {
    $files = Get-ChildItem -Path $RepoRoot -Recurse -Depth 3 -Filter 'graph.json' -ErrorAction SilentlyContinue |
      Where-Object { $_.DirectoryName -like '*graphify-out*' }
  }
  catch { $files = @() }

  foreach ($f in $files) {
    $entry = [ordered]@{
      repo = (Split-Path (Split-Path $f.DirectoryName -Parent) -Leaf)
      path = $f.FullName; nodes = $null; edges = $null
      built = $f.LastWriteTime; age = (Format-Age $f.LastWriteTime)
    }
    try {
      $g = Get-Content $f.FullName -Raw | ConvertFrom-Json
      if ($g.nodes) { $entry.nodes = @($g.nodes).Count }
      if ($g.edges) { $entry.edges = @($g.edges).Count }
      elseif ($g.links) { $entry.edges = @($g.links).Count }
    }
    catch { $entry.note = 'unparseable graph.json' }
    $result.graphs += $entry
  }
  return $result
}

# ---------------------------------------------------------------------------
# Gather
# ---------------------------------------------------------------------------

$rtk      = Get-RtkStats
$headroom = Get-HeadroomStats
$graphify = Get-GraphifyCoverage

# Combined reconciliation (no double counting)
# headroom cache/compression are lifetime-only (the proxy exposes no per-window savings
# series), so under a window they are kept OUT of the combined token figure and labeled.
$windowed = ($null -ne $cutUtc)
if ($windowed) {
  $uniqueTokens = [int64]$rtk.saved
}
else {
  $uniqueTokens = [int64]$rtk.saved + [int64]$headroom.comp_tokens
}
$combined = [ordered]@{
  windowed               = $windowed
  unique_token_reduction = $uniqueTokens
  rtk_saved              = [int64]$rtk.saved
  headroom_comp_tokens   = [int64]$headroom.comp_tokens
  headroom_comp_scope    = 'lifetime'
  cache_discount_usd     = [double]$headroom.cache_usd
  cache_discount_scope   = 'lifetime'
  overlap_note           = "headroom cli_filtering ($($headroom.cli_filtering_tokens)) mirrors rtk - not added"
}

# ---------------------------------------------------------------------------
# Render
# ---------------------------------------------------------------------------

if ($Format -eq 'json') {
  [ordered]@{
    generated_at = (Get-Date).ToString('s')
    window       = $windowLabel
    scope        = $scopeLabel
    rtk          = $rtk
    headroom     = $headroom
    graphify     = $graphify
    combined     = $combined
  } | ConvertTo-Json -Depth 8
  return
}

if ($Format -eq 'csv') {
  $rows = New-Object System.Collections.Generic.List[object]
  function Add-Row($tool, $metric, $val, $scope) {
    $rows.Add([pscustomobject]@{ tool = $tool; metric = $metric; scope = $scope; value = $val })
  }
  Add-Row 'rtk' 'commands'        $rtk.commands  $windowLabel
  Add-Row 'rtk' 'saved_tokens'    $rtk.saved     $windowLabel
  Add-Row 'rtk' 'savings_pct'     $rtk.pct       $windowLabel
  Add-Row 'rtk' 'exec_ms'         $rtk.exec_ms   $windowLabel
  Add-Row 'headroom' 'cache_usd'           $headroom.cache_usd          'lifetime'
  Add-Row 'headroom' 'cache_hit_pct'       $headroom.cache_hit_pct      'lifetime'
  Add-Row 'headroom' 'cache_read_tokens'   $headroom.cache_read_tokens  'lifetime'
  Add-Row 'headroom' 'compression_tokens'  $headroom.comp_tokens        'lifetime'
  Add-Row 'headroom' 'lifetime_input'      $headroom.life_input         'lifetime'
  Add-Row 'graphify' 'graphs_found'        $graphify.graphs.Count       'current'
  Add-Row 'combined' 'unique_token_reduction' $combined.unique_token_reduction $windowLabel
  Add-Row 'combined' 'cache_discount_usd'  $combined.cache_discount_usd 'lifetime'
  $rows | ConvertTo-Csv -NoTypeInformation
  return
}

# --- text dashboard ---
$bar = ('=' * 60)
$dash = ('-' * 60)
Write-Line $bar 'DarkCyan'
Write-Line (" TOKEN SAVINGS  -  window: {0}  -  scope: {1}" -f $windowLabel, $scopeLabel) 'Cyan'
Write-Line (" generated {0}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm')) 'DarkGray'
Write-Line $bar 'DarkCyan'
Write-Line

# rtk
Write-Line 'rtk  (CLI output filtering)' 'Yellow'
if ($rtk.available) {
  Write-Line ("  saved      {0} tokens   ({1}% of input)" -f (Format-Count $rtk.saved), $rtk.pct) 'Green'
  Write-Line ("  commands   {0:N0}           exec {1}" -f $rtk.commands, (Format-Ms $rtk.exec_ms))
  if ($rtk.top.Count -gt 0) {
    $topStr = ($rtk.top | ForEach-Object { '{0} {1}' -f ($_.cmd -replace '^rtk ', ''), (Format-Count $_.saved) }) -join ' | '
    Write-Line ("  top saved  {0}" -f $topStr)
  }
}
else {
  Write-Line ("  unavailable: {0}" -f $rtk.note) 'DarkGray'
}
Write-Line

# headroom
$hdrState = if ($headroom.available) { '[online]' } else { '[offline]' }
$hdrColor = if ($headroom.available) { 'Yellow' } else { 'DarkGray' }
Write-Line ("headroom  (proxy: {0})   {1}" -f $headroom.url, $hdrState) $hdrColor
if ($headroom.available) {
  $lifeTag = if ($windowed) { '(lifetime, not windowed)' } else { '(lifetime)' }
  Write-Line ("  cache        {0} saved   {1}% hit   {2} read tokens   {3}" -f (Format-Usd $headroom.cache_usd), $headroom.cache_hit_pct, (Format-Count $headroom.cache_read_tokens), $lifeTag) 'Green'
  Write-Line ("  compression  {0} tokens   {1}   {2}" -f (Format-Count $headroom.comp_tokens), (Format-Usd $headroom.comp_usd), $lifeTag)
  if ($headroom.session) {
    Write-Line ("  session      {0} reqs   {1} input   {2}   (since {3})" -f $headroom.session.requests, (Format-Count $headroom.session.input), (Format-Usd $headroom.session.cost_usd), $headroom.session.started) 'DarkGray'
  }
  Write-Line ("  note: headroom's CLI-filtering tally ({0}) mirrors rtk above - not added twice." -f (Format-Count $headroom.cli_filtering_tokens)) 'DarkGray'
}
else {
  Write-Line ("  {0}" -f $headroom.note) 'DarkGray'
}
Write-Line

# graphify
Write-Line 'graphify  (knowledge-graph coverage - no token metric)' 'Yellow'
if (-not $graphify.scanned) {
  Write-Line ("  {0}" -f $graphify.note) 'DarkGray'
}
elseif ($graphify.graphs.Count -eq 0) {
  Write-Line ("  scanned {0} (depth 3)" -f $graphify.root) 'DarkGray'
  Write-Line "  no graphify-out\graph.json found" 'DarkGray'
}
else {
  Write-Line ("  scanned {0}" -f $graphify.root) 'DarkGray'
  Write-Line ("  {0,-24} {1,7} {2,7}  {3}" -f 'repo', 'nodes', 'edges', 'built')
  foreach ($g in $graphify.graphs) {
    $n = if ($null -ne $g.nodes) { '{0:N0}' -f $g.nodes } else { '-' }
    $e = if ($null -ne $g.edges) { '{0:N0}' -f $g.edges } else { '-' }
    Write-Line ("  {0,-24} {1,7} {2,7}  {3}" -f $g.repo, $n, $e, $g.age)
  }
}
Write-Line

# combined
Write-Line $dash 'DarkCyan'
if ($windowed) {
  Write-Line ("COMBINED ({0})" -f $windowLabel) 'Cyan'
  Write-Line ("  unique token reduction   ~{0}   (rtk, windowed)" -f (Format-Count $combined.unique_token_reduction)) 'Green'
  Write-Line ("  note: cache discount ({0}) and compression ({1} tokens) shown above are LIFETIME totals -" -f (Format-Usd $combined.cache_discount_usd), (Format-Count $combined.headroom_comp_tokens)) 'DarkGray'
  Write-Line "        headroom exposes no per-window savings series, so they do not change with -Window." 'DarkGray'
}
else {
  Write-Line 'COMBINED (lifetime)' 'Cyan'
  Write-Line ("  unique token reduction   ~{0}   (rtk {1} + headroom comp {2})" -f (Format-Count $combined.unique_token_reduction), (Format-Count $combined.rtk_saved), (Format-Count $combined.headroom_comp_tokens)) 'Green'
  Write-Line ("  cost discount (cache)    ~{0}   (headroom)" -f (Format-Usd $combined.cache_discount_usd)) 'Green'
}
Write-Line $bar 'DarkCyan'
