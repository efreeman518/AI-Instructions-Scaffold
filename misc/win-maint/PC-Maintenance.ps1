#Requires -RunAsAdministrator
<#
.SYNOPSIS
    PC-Maintenance.ps1 - Reusable scheduled maintenance script

.DESCRIPTION
    Two modes:
      -Mode Quick   Weekly. Fast (~5-10 min). Clears temp/cache, updates all
                    package sources (winget/choco/scoop/npm/pip/dotnet tools),
                    flushes DNS, checks for stale scheduled tasks, and audits for
                    unauthorized remote-access servers / startup persistence.
      -Mode Deep    Monthly. Thorough (~20-40 min). Everything in Quick plus:
                    PowerShell module updates, DISM, SFC, disk optimization,
                    service drift check, event log archive, .NET SDK report,
                    large file scan, disk health check.

.PARAMETER Mode
    Quick | Deep  (default: Quick)

.PARAMETER LogPath
    Where to write the log file. Default: C:\Maintenance\Logs\

.PARAMETER ReBaseline
    Rewrite the security-audit baseline (under <LogPath parent>\Baseline) from the
    current state, then continue the run. Use this AFTER you intentionally install
    software so its new autostart/service/port entries stop being reported as NEW.
    Remote-access tripwires (VNC/AnyDesk/TeamViewer/etc.) still fire regardless of
    the baseline. The baseline is otherwise never auto-refreshed, so an intruder's
    persistence cannot quietly become "known".

    NOTE: baseline keys are version-normalized (see Get-NormPath). A version bump of
    already-known software (paths/services that embed a version, e.g.
    ...\OneDrive\26.088.0510.0004\..., Claude_1.11187.4.0_x64__..., or
    GoogleUpdaterService150.0.7863.0) no longer re-alerts as NEW and does NOT require
    -ReBaseline. A genuinely new package still alerts every run until -ReBaseline folds
    it into the known-good snapshot.

.EXAMPLE
    .\PC-Maintenance.ps1 -Mode Quick
    .\PC-Maintenance.ps1 -Mode Deep
    .\PC-Maintenance.ps1 -Mode Quick -ReBaseline   # after an intentional install

.NOTES
    ELEVATION: Must be run as Administrator, but via UAC elevation of your own
    account - NOT as a separate built-in Administrator account. The RTK/Headroom
    update step (section 7) writes to $env:USERPROFILE (shim files, venv, setx
    env vars). If you elevate as a different user, those paths point to the wrong
    profile and the updates land in the wrong place.

    Correct way to run:
      Right-click PowerShell (or Windows Terminal) -> "Run as administrator"
      Then: C:\Maintenance\PC-Maintenance.ps1 -Mode Quick

    Do NOT use: runas /user:Administrator (switches to a different user profile)

    SCHEDULED TASK (unattended / not logged in): The task runs as SYSTEM, which
    has no user profile. The RTK + Headroom update step is automatically skipped
    in that case. All other sections (temp cleanup, app updates, DNS, etc.) run
    normally. Run the script manually when logged in to pick up RTK/Headroom updates.
#>

param(
    [ValidateSet("Quick","Deep")]
    [string]$Mode = "Quick",
    [string]$LogPath = "C:\Maintenance\Logs",
    [switch]$ReBaseline
)

# --- SETUP --------------------------------------------------------------------

$ErrorActionPreference = "SilentlyContinue"
$WarningPreference     = "SilentlyContinue"
$StartTime             = Get-Date
$LogFile               = Join-Path $LogPath "Maintenance-$Mode-$(Get-Date -Format 'yyyy-MM-dd_HH-mm').log"

if (-not (Test-Path $LogPath)) { New-Item -Path $LogPath -ItemType Directory -Force | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Color = "White")
    $ts   = Get-Date -Format "HH:mm:ss"
    $line = "[$ts] $Message"
    Write-Host $line -ForegroundColor $Color
    Add-Content -Path $LogFile -Value $line
}

function Write-Section($title) {
    Write-Log ""
    Write-Log "==================================================" "Cyan"
    Write-Log "  $title" "Cyan"
    Write-Log "==================================================" "Cyan"
}

function Get-FolderSizeBytes($path) {
    if (-not (Test-Path $path)) { return 0 }
    (Get-ChildItem $path -Recurse -File -ErrorAction SilentlyContinue |
     Measure-Object -Property Length -Sum).Sum
}

function Format-Bytes($bytes) {
    if ($null -eq $bytes -or $bytes -eq 0) { return "0 MB" }
    if ($bytes -gt 1GB) { return "$([math]::Round($bytes/1GB,2)) GB" }
    return "$([math]::Round($bytes/1MB,0)) MB"
}

function Clear-Directory($path, $label, [switch]$FilesOnly) {
    if (-not (Test-Path $path)) {
        Write-Log "  [SKIP]   $label - path not found" "DarkGray"
        return 0
    }
    $before = Get-FolderSizeBytes $path
    if ($FilesOnly) {
        Get-ChildItem $path -File -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } else {
        Get-ChildItem $path -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
    $after = Get-FolderSizeBytes $path
    $freed = $before - $after
    Write-Log "  [CLEAN]  $label - freed $(Format-Bytes $freed)" "Green"
    return $freed
}

# --- SECURITY-AUDIT HELPERS (section 11) --------------------------------------
# Curated VNC + remote-access / RMM tool names. Case-insensitive regex, matched
# against service/process/file names and paths. These are the tools an attacker or
# tech-support scam typically installs for remote control. Add more as needed.
$RemoteAccessDeny = 'vnc|winvnc|tvnserver|uvnc|tigervnc|x11vnc|realvnc|tightvnc|ultravnc|anydesk|teamviewer|rustdesk|screenconnect|connectwise|splashtop|atera|ammyy|remoteutilit|dwagent|meshagent|supremo|getscreen|logmein|gotomypc|remotepc|netsupport|radmin|nomachine|parsec|dameware|aeroadmin'

# Remote tools you intentionally keep - silenced in the always-on tripwire scan.
# Each entry is a regex fragment matched against "<name> <path>". Example: you run
# RealVNC on purpose -> add 'realvnc'. Empty by default (flag everything).
$RemoteAccessAllow = @()

# State lives next to the logs, under the same maintenance root.
$MaintenanceRoot = Split-Path $LogPath -Parent
$BaselineDir     = Join-Path $MaintenanceRoot 'Baseline'
$BaselineFile    = Join-Path $BaselineDir 'autoruns-baseline.json'
$LastAuditFile   = Join-Path $BaselineDir 'last-audit.txt'
$AlertFile       = Join-Path $MaintenanceRoot "SecurityAlerts-$(Get-Date -Format 'yyyy-MM-dd').txt"
$script:auditFindings = 0

# Loud finding: log in red AND append to the dedicated alerts file (created lazily,
# only when there is something to report, so unattended runs surface real signal).
function Add-Alert {
    param([string]$Message)
    $script:auditFindings++
    Write-Log "  [ALERT]  $Message" "Red"
    if (-not (Test-Path $AlertFile)) {
        @(
            "PC-Maintenance Security Alerts",
            "Computer: $env:COMPUTERNAME   Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   Mode: $Mode",
            ("=" * 70)
        ) | Set-Content -Path $AlertFile -ErrorAction SilentlyContinue
    }
    Add-Content -Path $AlertFile -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message) -ErrorAction SilentlyContinue
}

# Authenticode status of a file ("Valid","NotSigned","HashMismatch",... / "unknown").
function Get-SigStatus {
    param([string]$Path)
    if (-not $Path) { return 'unknown' }
    $clean = $Path.Trim('"')
    if (-not (Test-Path $clean -PathType Leaf)) { return 'unknown' }
    try { (Get-AuthenticodeSignature $clean -ErrorAction Stop).Status.ToString() }
    catch { 'unknown' }
}

# True when a path sits in a user-writable / drop location malware favours.
function Test-SuspiciousPath {
    param([string]$Path)
    if (-not $Path) { return $false }
    $p = $Path.ToLower()
    return ($p -match '\\appdata\\' -or $p -match '\\temp\\' -or $p -match '\\downloads\\' -or $p -match '\\users\\public\\')
}

# Pull the executable out of a command line (handles quotes, args, env vars).
function Get-ExeFromCommand {
    param([string]$Cmd)
    if (-not $Cmd) { return $null }
    $c = $Cmd.Trim()
    if ($c.StartsWith('"')) {
        $end = $c.IndexOf('"', 1)
        if ($end -gt 1) { return $c.Substring(1, $end - 1) }
    }
    $c = [Environment]::ExpandEnvironmentVariables($c)
    return ($c -split '\s+')[0]
}

# Resolve a .lnk shortcut to the exe it points at (Startup-folder items are .lnk).
function Resolve-Target {
    param([string]$Target)
    if ($Target -and $Target.ToLower().EndsWith('.lnk') -and (Test-Path $Target)) {
        try { return (New-Object -ComObject WScript.Shell).CreateShortcut($Target).TargetPath }
        catch { return $Target }
    }
    return $Target
}

# Collapse embedded version numbers in a path/string so version bumps of the SAME
# software stop re-keying as NEW in the baseline diff. Only the numeric version
# segment is touched - the product name/folder that differentiates one package from
# another is preserved, so a genuinely new package still keys distinctly and alerts
# until -ReBaseline. Examples that normalize to a stable form:
#   ...\Microsoft OneDrive\26.088.0510.0004\OneDrive...  -> ...\Microsoft OneDrive\#\OneDrive...
#   ...\WindowsApps\Claude_1.11187.4.0_x64__hash\...      -> ...\WindowsApps\Claude_#_x64__hash\...
#   ...\Google\Chrome\Application\149.0.7827.54\...       -> ...\Google\Chrome\Application\#\...
# Tradeoff: a binary that mimics a versioned folder pattern blends in slightly more,
# but the independent remote-access tripwire layer (11a-11c) is unaffected.
function Get-NormPath {
    param([string]$Path)
    if (-not $Path) { return $Path }
    $p = $Path
    # WindowsApps / packaged versions: _1.2.3.4_  ->  _#_   (handles Name_1.2.3.4_x64__hash)
    $p = $p -replace '(_)\d+(\.\d+)+(_)', '${1}#${3}'
    # Bare version path segments: \26.088.0510.0004\  ->  \#\
    $p = $p -replace '\\\d+(\.\d+){1,}\\', '\#\'
    # Trailing version path segment with no closing slash: \149.0.7827.54  ->  \#
    $p = $p -replace '\\\d+(\.\d+){1,}$', '\#'
    return $p
}

# Collapse a trailing version embedded in a SERVICE NAME so versioned service names
# (e.g. GoogleUpdaterService150.0.7863.0, GoogleUpdaterInternalService150.0.7863.0)
# stop re-alerting on every version bump. Only a trailing dotted-version run is
# replaced; the descriptive name prefix is preserved.
function Get-NormName {
    param([string]$Name)
    if (-not $Name) { return $Name }
    return ($Name -replace '\d+(\.\d+)+$', '#')
}

# Normalize a service name for baseline keying. Windows user-service instances are
# named <Template>_<sessionLUIDhex> (e.g. CDPUserSvc_960a9); the LUID changes every
# logon session, so the raw name re-alerts on every reboot with zero software change.
# Stripping a trailing _<hex> keys on the template instead. We ALSO normalize a
# trailing dotted-version in the name (Get-NormName) and version segments in the path
# (Get-NormPath) so version bumps of the same software no longer re-key as NEW.
# Applied to both sides of the diff, so it stays consistent.
function Get-ServiceKey {
    param([string]$Name, [string]$Path)
    $norm = $Name -replace '_[0-9A-Fa-f]{4,}$', ''
    $norm = Get-NormName $norm
    return "$norm|$(Get-NormPath $Path)"
}

# Normalize a listener for baseline keying. spoolsv / services / lsass and transient
# dev tools bind random high ports in the dynamic range (49152-65535) that are
# reassigned every boot, so Port|Path re-alerts on every run. For dynamic-range ports,
# key on (normalized) Path only: a brand-new binary listening still alerts once, but
# port churn from an already-known binary does not. Below 49152 (well-known /
# registered) the exact port still matters, so it stays in the key. Path is
# version-normalized so a version bump of the listening binary does not re-alert.
function Get-ListenerKey {
    param($Port, [string]$Path)
    if ([int]$Port -ge 49152) { return "DYN|$(Get-NormPath $Path)" }
    return "$Port|$(Get-NormPath $Path)"
}

# Stable autoruns key. Source + Name + version-normalized Target. The OneDrive Run
# entry and OneDrive Startup tasks embed the version in the Target path, so without
# normalization each OneDrive update re-alerts; Get-NormPath collapses that.
function Get-AutorunKey {
    param([string]$Source, [string]$Name, [string]$Target)
    return "$Source|$Name|$(Get-NormPath $Target)"
}

# Point-in-time snapshot of services, autostart entries, and listening ports.
function Get-AuditSnapshot {
    $services = Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
        ForEach-Object { [pscustomobject]@{ Name = $_.Name; Path = $_.PathName; StartMode = $_.StartMode } }

    $autoruns = @()
    $runKeys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
               'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
               'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
               'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
               'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
    foreach ($k in $runKeys) {
        if (Test-Path $k) {
            $vals = Get-ItemProperty $k -ErrorAction SilentlyContinue
            foreach ($p in (Get-Item $k -ErrorAction SilentlyContinue).Property) {
                $autoruns += [pscustomobject]@{ Source = $k; Name = $p; Target = [string]$vals.$p }
            }
        }
    }
    $startupDirs = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup",
                   "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Startup"
    foreach ($d in $startupDirs) {
        Get-ChildItem $d -File -ErrorAction SilentlyContinue | ForEach-Object {
            $autoruns += [pscustomobject]@{ Source = $d; Name = $_.Name; Target = $_.FullName }
        }
    }
    Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object { $_.Triggers | Where-Object { $_.CimClass.CimClassName -match 'LogonTrigger|BootTrigger' } } |
        ForEach-Object {
            $t = $_
            foreach ($a in $t.Actions) {
                if ($a.Execute) {
                    $autoruns += [pscustomobject]@{ Source = "Task:$($t.TaskPath)$($t.TaskName)"; Name = $t.TaskName; Target = $a.Execute }
                }
            }
        }

    $listeners = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        ForEach-Object {
            $proc = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
            [pscustomobject]@{ Port = $_.LocalPort; Proc = $proc.ProcessName; Path = $proc.Path }
        } | Sort-Object Port -Unique

    [pscustomobject]@{ services = $services; autoruns = $autoruns; listeners = $listeners }
}

$totalFreed = 0

Write-Log ""
Write-Log "  PC Maintenance - $Mode Mode" "White"
Write-Log "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  |  $env:COMPUTERNAME" "DarkGray"
Write-Log "  Log: $LogFile" "DarkGray"


# ===============================================================================
#  SINGLE-INSTANCE GUARD - one run at a time, Deep takes precedence
# ===============================================================================
# Both scheduled tasks use -StartWhenAvailable, so when the PC boots after being
# off across both scheduled times, Task Scheduler fires BOTH missed runs at once.
# Deep is a strict superset of Quick (sections 1-11 are identical), so a Quick run
# alongside Deep is pure redundancy AND races on shared resources: wuauserv/DoSvc
# stop-start, explorer kill/restart, winget/choco global installer locks, and the
# RTK/Headroom updater writing the same profile paths. Rule enforced here: only one
# run at a time, and Deep always wins. The lock is released before the keypress
# prompt at the end (see SUMMARY) so a finished window never holds it open.
$mutex    = New-Object System.Threading.Mutex($false, "Global\PC-Maintenance-Run")
$haveLock = $false

# True when the Deep scheduled task is currently running or queued. The name/path
# must match Setup-MaintenanceSchedule.ps1; if they ever drift this returns $false
# and the mutex alone still prevents genuinely concurrent runs.
function Test-DeepActive {
    $deep = Get-ScheduledTask -TaskName "PC Maintenance - Monthly Deep" `
        -TaskPath "\Maintenance\" -ErrorAction SilentlyContinue
    return [bool]($deep -and ($deep.State -eq 'Running' -or $deep.State -eq 'Queued'))
}

if ($Mode -eq "Quick") {
    if (Test-DeepActive) {
        Write-Log "  [SKIP]   Deep maintenance is active - skipping Quick (Deep is a superset)." "Yellow"
        $mutex.Dispose(); exit 0
    }
    # Non-blocking: if any run already holds the lock, skip rather than wait.
    try { $haveLock = $mutex.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { $haveLock = $true }  # prior run crashed; we own it now
    if (-not $haveLock) {
        Write-Log "  [SKIP]   Another maintenance run holds the lock - skipping Quick." "Yellow"
        $mutex.Dispose(); exit 0
    }
    # Boot co-launch grace: at boot both tasks can start within the same second, so
    # Quick may have grabbed the lock a hair before Deep's process became visible.
    # Pause, then re-check; if Deep has since appeared, release and yield to it.
    Start-Sleep -Seconds 45
    if (Test-DeepActive) {
        Write-Log "  [YIELD]  Deep maintenance started - releasing lock and skipping Quick." "Yellow"
        $mutex.ReleaseMutex(); $mutex.Dispose(); exit 0
    }
}
else {
    # Deep always wins: wait (bounded) for an in-flight Quick to finish, then take the lock.
    try { $haveLock = $mutex.WaitOne([TimeSpan]::FromMinutes(20)) }
    catch [System.Threading.AbandonedMutexException] { $haveLock = $true }
    if (-not $haveLock) {
        Write-Log "  [WARN]   Timed out waiting for the maintenance lock - another run appears stuck. Exiting." "Red"
        $mutex.Dispose(); exit 1
    }
}


# ===============================================================================
#  QUICK - runs in both modes
# ===============================================================================

# --- 1. TEMP FILES ------------------------------------------------------------
Write-Section "1/11  Temp Files"

$totalFreed += Clear-Directory $env:TEMP                          "User Temp (%TEMP%)"
$totalFreed += Clear-Directory "C:\Windows\Temp"                  "Windows Temp"
$totalFreed += Clear-Directory "$env:LOCALAPPDATA\Temp"           "LocalAppData Temp"
$totalFreed += Clear-Directory "C:\Windows\Prefetch"              "Prefetch"
$totalFreed += Clear-Directory "$env:LOCALAPPDATA\CrashDumps"     "Crash Dumps"
$totalFreed += Clear-Directory "$env:LOCALAPPDATA\Microsoft\Windows\INetCache" "IE/Edge Cache"
$totalFreed += Clear-Directory "$env:LOCALAPPDATA\Microsoft\Windows\WER\ReportArchive" "WER Report Archive"
$totalFreed += Clear-Directory "$env:LOCALAPPDATA\Microsoft\Windows\WER\ReportQueue"   "WER Report Queue"
$totalFreed += Clear-Directory "C:\ProgramData\Microsoft\Windows\WER\ReportArchive"    "WER System Archive"
$totalFreed += Clear-Directory "C:\ProgramData\Microsoft\Windows\WER\ReportQueue"      "WER System Queue"


# --- 2. BROWSER CACHES --------------------------------------------------------
Write-Section "2/11  Browser Caches"

foreach ($base in @(
    "$env:LOCALAPPDATA\Google\Chrome\User Data",
    "$env:LOCALAPPDATA\Microsoft\Edge\User Data"
)) {
    $browser = if ($base -like "*Chrome*") { "Chrome" } else { "Edge" }
    if (Test-Path $base) {
        Get-ChildItem $base -Directory |
            Where-Object { $_.Name -eq "Default" -or $_.Name -like "Profile*" } |
            ForEach-Object {
                $totalFreed += Clear-Directory "$($_.FullName)\Cache"       "$browser $($_.Name) Cache"
                $totalFreed += Clear-Directory "$($_.FullName)\Cache2"      "$browser $($_.Name) Cache2"
                $totalFreed += Clear-Directory "$($_.FullName)\GPUCache"    "$browser $($_.Name) GPUCache"
                $totalFreed += Clear-Directory "$($_.FullName)\Code Cache"  "$browser $($_.Name) Code Cache"
                $totalFreed += Clear-Directory "$($_.FullName)\DawnCache"   "$browser $($_.Name) DawnCache"
                $totalFreed += Clear-Directory "$($_.FullName)\ShaderCache" "$browser $($_.Name) ShaderCache"
            }
        $totalFreed += Clear-Directory "$base\ShaderCache" "$browser ShaderCache (global)"
    }
}


# --- 3. WINDOWS UPDATE & DELIVERY OPTIMIZATION -------------------------------
Write-Section "3/11  Windows Update Cache & Delivery Optimization"

Stop-Service wuauserv -Force
$totalFreed += Clear-Directory "C:\Windows\SoftwareDistribution\Download" "Windows Update Downloads"
Start-Service wuauserv
Write-Log "  [OK]     Windows Update service restarted" "Green"

Stop-Service DoSvc -Force
$totalFreed += Clear-Directory "C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache" "Delivery Optimization Cache"
Start-Service DoSvc


# --- 4. THUMBNAIL & ICON CACHE ------------------------------------------------
Write-Section "4/11  Thumbnail & Icon Cache"

Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
$thumbDB = "$env:LOCALAPPDATA\Microsoft\Windows\Explorer"
Get-ChildItem $thumbDB -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like "thumbcache_*" -or $_.Name -like "iconcache_*" } |
    ForEach-Object {
        Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path $_.FullName)) {
            Write-Log "  [CLEAN]  $($_.Name)" "Green"
        }
    }
Start-Process explorer


# --- 5. DNS FLUSH -------------------------------------------------------------
Write-Section "5/11  DNS Cache"
ipconfig /flushdns | Out-Null
Write-Log "  [OK]     DNS cache flushed" "Green"


# --- 6. RECYCLE BIN -----------------------------------------------------------
Write-Section "6/11  Recycle Bin"
$shell  = New-Object -ComObject Shell.Application
$rb     = $shell.Namespace(0xa)
$rbSize = ($rb.Items() | Measure-Object -Property Size -Sum).Sum
Clear-RecycleBin -Force -ErrorAction SilentlyContinue
Write-Log "  [CLEAN]  Recycle Bin - freed $(Format-Bytes $rbSize)" "Green"
$totalFreed += $rbSize


# --- 7. ALL SOURCE APP UPDATES ------------------------------------------------
Write-Section "7/11  App Updates - All Sources"

# -- winget --------------------------------------------------------------------
Write-Log "  [winget]  Refreshing source index..." "Gray"
winget source update 2>&1 | Out-Null
Write-Log "  [winget]  Upgrading all..." "Gray"
winget upgrade --all --silent --accept-package-agreements --accept-source-agreements 2>&1 |
    Where-Object { $_ -match '\S' } |
    ForEach-Object { Write-Log "    $_" "DarkGray" }
Write-Log "  [OK]      winget complete" "Green"

# -- Chocolatey ----------------------------------------------------------------
if (Get-Command choco -ErrorAction SilentlyContinue) {
    Write-Log "  [choco]   Upgrading all..." "Gray"
    choco upgrade all -y --no-progress 2>&1 |
        Where-Object { $_ -match "upgraded|already up to date|ERROR|WARNING" } |
        ForEach-Object { Write-Log "    $_" "DarkGray" }
    choco optimize --reduce-nupkg-only 2>&1 | Out-Null
    Write-Log "  [OK]      Chocolatey complete" "Green"
}

# -- Scoop ---------------------------------------------------------------------
if (Get-Command scoop -ErrorAction SilentlyContinue) {
    Write-Log "  [scoop]   Updating all..." "Gray"
    scoop update 2>&1 | Out-Null
    scoop update * 2>&1 |
        Where-Object { $_ -match '\S' } |
        ForEach-Object { Write-Log "    $_" "DarkGray" }
    scoop cleanup * 2>&1 | Out-Null
    Write-Log "  [OK]      Scoop complete" "Green"
}

# -- npm global packages -------------------------------------------------------
if (Get-Command npm -ErrorAction SilentlyContinue) {
    Write-Log "  [npm]     Updating global packages..." "Gray"
    npm update -g 2>&1 |
        Where-Object { $_ -match '\S' } |
        ForEach-Object { Write-Log "    $_" "DarkGray" }
    Write-Log "  [OK]      npm complete" "Green"
}

# -- pip global packages -------------------------------------------------------
if (Get-Command pip -ErrorAction SilentlyContinue) {
    Write-Log "  [pip]     Updating outdated packages..." "Gray"
    $outdated = pip list --outdated --format=json 2>&1 | ConvertFrom-Json -ErrorAction SilentlyContinue
    if ($outdated) {
        foreach ($pkg in $outdated) {
            pip install --upgrade $pkg.name --quiet 2>&1 | Out-Null
            Write-Log "    [OK] $($pkg.name)  $($pkg.version) -> $($pkg.latest_version)" "Green"
        }
    } else {
        Write-Log "    All pip packages up to date" "DarkGray"
    }
    Write-Log "  [OK]      pip complete" "Green"
}

# -- dotnet global tools -------------------------------------------------------
if (Get-Command dotnet -ErrorAction SilentlyContinue) {
    Write-Log "  [dotnet]  Updating global tools..." "Gray"
    $tools = dotnet tool list --global 2>&1 | Select-Object -Skip 2
    foreach ($line in $tools) {
        $toolName = ($line -split '\s+')[0]
        if ($toolName -and $toolName.Trim() -ne '') {
            $result = dotnet tool update --global $toolName 2>&1 | Select-Object -Last 1
            if ($result) { Write-Log "    $result" "DarkGray" }
        }
    }
    Write-Log "  [OK]      dotnet tools complete" "Green"
}


# -- RTK + Headroom -----------------------------------------------------------
# Skipped when running as SYSTEM (scheduled task without logged-in user).
# SYSTEM has no user profile - shim files, venv, and setx vars would land in
# C:\Windows\System32\config\systemprofile instead of the user's profile.
# Run PC-Maintenance.ps1 manually when logged in to update RTK and Headroom.
$contextScript = "C:\Maintenance\update-python-and-context-tools.ps1"
if ([Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) {
    Write-Log "  [SKIP]    RTK + Headroom - running as SYSTEM (run script manually when logged in)" "Yellow"
} elseif (Test-Path $contextScript) {
    Write-Log "  [context] Updating RTK and Headroom..." "Gray"
    & $contextScript -SkipPythonUpdate
    Write-Log "  [OK]      RTK + Headroom complete (exit: $LASTEXITCODE)" "Green"
} else {
    Write-Log "  [SKIP]    $contextScript not found" "DarkGray"
}


# --- 8. STORAGE SENSE --------------------------------------------------------
Write-Section "8/11  Storage Sense"
$storageSenseKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy"
if (Test-Path $storageSenseKey) {
    Set-ItemProperty -Path $storageSenseKey -Name "01" -Value 1
    Write-Log "  [OK]     Storage Sense triggered" "Green"
} else {
    Write-Log "  [SKIP]   Storage Sense key not found" "DarkGray"
}


# --- 9. OLD MAINTENANCE LOGS -------------------------------------------------
Write-Section "9/11  Pruning Old Maintenance Logs (>90 days)"
$oldLogs = Get-ChildItem $LogPath -File -ErrorAction SilentlyContinue |
           Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-90) }
$oldLogs | Remove-Item -Force -ErrorAction SilentlyContinue
Write-Log "  [CLEAN]  Removed $($oldLogs.Count) old log file(s)" "Green"


# --- 10. STALE SCHEDULED TASKS -----------------------------------------------
Write-Section "10/11  Stale Scheduled Tasks - Broken File References"
# Reports tasks pointing to missing executables.
# Review flagged items in Autoruns and remove manually if appropriate.
#
# TRANSIENT-UPDATE SUPPRESSION: right after an in-place app update (OneDrive is the
# classic case), the old scheduled task can still point at the previous versioned
# path for a short window before the installer rewrites it - e.g.
#   Missing: C:\Program Files\Microsoft OneDrive\26.070.0414.0001\OneDriveLauncher.exe
# while the new task already points at ...\26.088.0510.0004\OneDriveLauncher.exe.
# To avoid that false positive, before flagging a missing exe we check whether the
# SAME task (or another task) has an action whose version-normalized path matches and
# DOES resolve. If a version-normalized sibling exists on disk, the missing entry is
# just a stale pointer mid-update - we note it quietly instead of raising [STALE].
$staleFound = 0

# Pre-build a set of version-normalized paths for every task action whose exe exists,
# so a missing versioned path can be matched against a present sibling.
$presentNormTargets = @{}
Get-ScheduledTask -ErrorAction SilentlyContinue | ForEach-Object {
    foreach ($action in $_.Actions) {
        $exe = $action.Execute `
            -replace '"',            '' `
            -replace '%SystemRoot%', $env:SystemRoot `
            -replace '%windir%',     $env:SystemRoot `
            -replace '%ProgramFiles%', $env:ProgramFiles
        if ($exe) {
            $exists = if ($exe -match '[\\/]') { Test-Path $exe } else { [bool](Get-Command $exe -ErrorAction SilentlyContinue) }
            if ($exists) { $presentNormTargets[(Get-NormPath $exe)] = $true }
        }
    }
}

Get-ScheduledTask -ErrorAction SilentlyContinue | ForEach-Object {
    $task = $_
    foreach ($action in $task.Actions) {
        $exe = $action.Execute `
            -replace '"',            '' `
            -replace '%SystemRoot%', $env:SystemRoot `
            -replace '%windir%',     $env:SystemRoot `
            -replace '%ProgramFiles%', $env:ProgramFiles
        # Resolve existence PATH-aware. A bare filename (e.g. BthUdTask.exe) lives in
        # System32 and resolves through PATH at runtime, but Test-Path on a bare name
        # only checks the current directory, so it would always report "missing" - a
        # false positive. Names with a path separator are checked directly as before.
        $exeExists = if ($exe -match '[\\/]') {
            Test-Path $exe
        } else {
            [bool](Get-Command $exe -ErrorAction SilentlyContinue)
        }
        if ($exe -and
            $exe -notlike "*.dll"        -and
            $exe -ne "cmd.exe"           -and
            $exe -ne "sc.exe"            -and
            $exe -notlike "*\cmd.exe"    -and
            $exe -notlike "*powershell*" -and
            $exe -notlike "*pwsh*"       -and
            -not $exeExists) {

            # Transient mid-update pointer? A version-normalized sibling resolves on disk.
            if ($presentNormTargets.ContainsKey((Get-NormPath $exe))) {
                Write-Log "  [NOTE]   $($task.TaskPath)$($task.TaskName) - stale versioned path (newer version present, transient post-update)" "DarkGray"
                Write-Log "           Old: $exe" "DarkGray"
            } else {
                Write-Log "  [STALE]  $($task.TaskPath)$($task.TaskName)" "Yellow"
                Write-Log "           Missing: $exe" "DarkGray"
                $staleFound++
            }
        }
    }
}
if ($staleFound -eq 0) {
    Write-Log "  [OK]     No stale tasks found" "Green"
} else {
    Write-Log "  [NOTE]   $staleFound stale task(s) - review in Autoruns -> Scheduled Tasks tab" "Yellow"
}


# --- 11. REMOTE-ACCESS & STARTUP AUDIT ---------------------------------------
Write-Section "11/11  Remote-Access & Startup Audit"
# Report-only detection of unauthorized remote-control servers (VNC/AnyDesk/etc.)
# and unexpected startup persistence. Nothing is stopped or removed - findings are
# logged as [ALERT] and written to a SecurityAlerts file for you to review in
# Autoruns. Two layers: always-on tripwires (known remote-access tools by name or
# VNC port) and a baseline diff (anything NEW since the recorded clean snapshot).
# Scheduled runs are interactive as you (see Setup-MaintenanceSchedule.ps1), so HKCU
# autoruns reflect your profile. If ever run as SYSTEM, HKCU is SYSTEM's hive; the
# HKLM / all-users / services / ports checks (the high-value targets) are unaffected.
# On a managed WORK PC, do NOT remove IT-deployed tools - confirm with IT first.
#
# Baseline keys are VERSION-NORMALIZED (Get-NormPath / Get-NormName), so a version
# bump of already-known software does NOT re-alert and does NOT need -ReBaseline.
# A genuinely new package still alerts every run until -ReBaseline folds it in. The
# tripwire layer below is independent of the baseline and always fires.

if (-not (Test-Path $BaselineDir)) { New-Item -Path $BaselineDir -ItemType Directory -Force | Out-Null }

$snapshot   = Get-AuditSnapshot
$allowRegex = if ($RemoteAccessAllow.Count) { ($RemoteAccessAllow -join '|') } else { $null }

# -- 11a. Tripwire: known remote-access servers (services, processes, ports) ---
foreach ($svc in $snapshot.services) {
    if (($svc.Name -match $RemoteAccessDeny -or $svc.Path -match $RemoteAccessDeny) -and
        -not ($allowRegex -and "$($svc.Name) $($svc.Path)" -match $allowRegex)) {
        Add-Alert "Remote-access SERVICE '$($svc.Name)' ($($svc.StartMode)) -> $($svc.Path) [sig: $(Get-SigStatus (Get-ExeFromCommand $svc.Path))]"
    }
}
Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessName -match $RemoteAccessDeny } |
    ForEach-Object {
        if (-not ($allowRegex -and "$($_.ProcessName) $($_.Path)" -match $allowRegex)) {
            Add-Alert "Remote-access PROCESS '$($_.ProcessName)' (pid $($_.Id)) -> $($_.Path)"
        }
    }
foreach ($l in $snapshot.listeners) {
    $isVncPort   = ($l.Port -eq 5800 -or ($l.Port -ge 5900 -and $l.Port -le 5906))
    $isRemoteSvc = ($l.Proc -match $RemoteAccessDeny -or $l.Path -match $RemoteAccessDeny)
    if (($isVncPort -or $isRemoteSvc) -and
        -not ($allowRegex -and "$($l.Proc) $($l.Path)" -match $allowRegex)) {
        Add-Alert "Listening port $($l.Port) -> $($l.Proc) [$($l.Path)]$(if ($isVncPort) { ' (VNC port)' })"
    }
}

# -- 11b. Tripwire: remote-access services installed since last audit (7045) ---
# Catches an install-then-uninstall a live snapshot would miss. Denylist only.
$since = (Get-Date).AddDays(-14)
if (Test-Path $LastAuditFile) {
    $prev = Get-Content $LastAuditFile -ErrorAction SilentlyContinue | Select-Object -First 1
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse($prev, [ref]$parsed)) { $since = $parsed }
}
Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 7045; StartTime = $since } -ErrorAction SilentlyContinue |
    ForEach-Object {
        if ($_.Message -match $RemoteAccessDeny) {
            # Line-based extraction - robust across the multi-line 7045 message format.
            $lines   = $_.Message -split "`n"
            $svcName = (($lines | Where-Object { $_ -match 'Service Name:' } | Select-Object -First 1) -replace '.*Service Name:\s*', '').Trim()
            $svcFile = (($lines | Where-Object { $_ -match 'File Name:'    } | Select-Object -First 1) -replace '.*File Name:\s*', '').Trim()
            Add-Alert "Remote-access service INSTALLED $($_.TimeCreated.ToString('yyyy-MM-dd HH:mm')): '$svcName' -> $svcFile (event 7045)"
        }
    }

# -- 11c. Tripwire: startup entries matching the remote-access denylist --------
foreach ($a in $snapshot.autoruns) {
    if (($a.Target -match $RemoteAccessDeny -or $a.Name -match $RemoteAccessDeny) -and
        -not ($allowRegex -and "$($a.Name) $($a.Target)" -match $allowRegex)) {
        Add-Alert "Remote-access STARTUP '$($a.Name)' from $($a.Source) -> $($a.Target)"
    }
}

# -- 11d. Baseline diff: anything NEW since the recorded clean snapshot --------
# The baseline is created on first run and only rewritten with -ReBaseline, so an
# intruder's persistence cannot silently be absorbed as "known". Keys are
# version-normalized so version bumps of known software do not re-alert.
if ($ReBaseline -or -not (Test-Path $BaselineFile)) {
    $snapshot | ConvertTo-Json -Depth 6 | Set-Content -Path $BaselineFile -ErrorAction SilentlyContinue
    $n    = @($snapshot.services).Count + @($snapshot.autoruns).Count + @($snapshot.listeners).Count
    $verb = if ($ReBaseline) { 'refreshed on request' } else { 'established' }
    Write-Log "  [BASELINE] $verb ($n items) -> $BaselineFile" "Cyan"
} else {
    $base = Get-Content $BaselineFile -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
    if ($base) {
        $baseSvc = @{}; foreach ($s in $base.services)  { $baseSvc[(Get-ServiceKey $s.Name $s.Path)] = $true }
        $baseAut = @{}; foreach ($a in $base.autoruns)  { $baseAut[(Get-AutorunKey $a.Source $a.Name $a.Target)] = $true }
        $basePrt = @{}; foreach ($l in $base.listeners) { $basePrt[(Get-ListenerKey $l.Port $l.Path)] = $true }

        foreach ($s in $snapshot.services) {
            if (-not $baseSvc.ContainsKey((Get-ServiceKey $s.Name $s.Path))) {
                Add-Alert "NEW service since baseline: '$($s.Name)' ($($s.StartMode)) -> $($s.Path)"
            }
        }
        foreach ($a in $snapshot.autoruns) {
            if (-not $baseAut.ContainsKey((Get-AutorunKey $a.Source $a.Name $a.Target))) {
                $exe  = Get-ExeFromCommand (Resolve-Target $a.Target)
                $sig  = Get-SigStatus $exe
                $note = if ((Test-SuspiciousPath $exe) -and $sig -ne 'Valid') { "  (!) unsigned in user-writable path [sig: $sig]" } else { '' }
                Add-Alert "NEW startup since baseline: '$($a.Name)' from $($a.Source) -> $($a.Target)$note"
            }
        }
        foreach ($l in $snapshot.listeners) {
            if (-not $basePrt.ContainsKey((Get-ListenerKey $l.Port $l.Path))) {
                Add-Alert "NEW listening port since baseline: $($l.Port) -> $($l.Proc) [$($l.Path)]"
            }
        }
    }
}

# Stamp the window for the next 7045 scan.
(Get-Date).ToString('o') | Set-Content -Path $LastAuditFile -ErrorAction SilentlyContinue

if ($script:auditFindings -eq 0) {
    Write-Log "  [OK]     No remote-access servers or unexpected startup items found" "Green"
} else {
    Write-Log "  [NOTE]   $($script:auditFindings) finding(s) - see $AlertFile and review in Autoruns" "Yellow"
    Write-Log "           Disable a rogue service:  sc.exe config <name> start= disabled  (do NOT remove IT-managed tools on a work PC)" "DarkGray"
}


# ===============================================================================
#  DEEP - monthly additional steps
# ===============================================================================

if ($Mode -eq "Deep") {

    # --- 11. POWERSHELL MODULE UPDATES ---------------------------------------
    Write-Section "12/20  PowerShell Module Updates (PSGallery)"
    Write-Log "  Checking installed modules for updates..." "Gray"

    $modUpdated = 0
    $modules    = Get-InstalledModule -ErrorAction SilentlyContinue
    foreach ($mod in $modules) {
        try {
            $latest = Find-Module $mod.Name -ErrorAction SilentlyContinue
            if ($latest -and [version]$latest.Version -gt [version]$mod.Version) {
                Write-Log "  Updating: $($mod.Name)  $($mod.Version) -> $($latest.Version)" "Gray"
                Update-Module $mod.Name -Force -ErrorAction Stop
                Write-Log "  [OK]      $($mod.Name) updated" "Green"
                $modUpdated++
            }
        } catch {
            Write-Log "  [SKIP]    $($mod.Name) - $($_.Exception.Message)" "DarkGray"
        }
    }
    Write-Log "  [OK]     $modUpdated module(s) updated" "Green"

    # Remove superseded module versions
    Write-Log "  Pruning old module versions..." "Gray"
    $modPruned = 0
    Get-InstalledModule -ErrorAction SilentlyContinue | ForEach-Object {
        $allVersions = Get-InstalledModule $_.Name -AllVersions -ErrorAction SilentlyContinue |
                       Sort-Object Version -Descending
        if ($allVersions.Count -gt 1) {
            $allVersions | Select-Object -Skip 1 | ForEach-Object {
                try {
                    Uninstall-Module $_.Name -RequiredVersion $_.Version -Force -ErrorAction Stop
                    Write-Log "  [REMOVED] $($_.Name) v$($_.Version) (superseded)" "Green"
                    $modPruned++
                } catch {
                    Write-Log "  [SKIP]    $($_.Name) v$($_.Version) - in use or locked" "DarkGray"
                }
            }
        }
    }
    Write-Log "  [OK]     $modPruned old module version(s) removed" "Green"


    # --- 12. DISM COMPONENT STORE CLEANUP ------------------------------------
    Write-Section "13/20  DISM - Component Store Cleanup (may take 5-20 min)"
    Write-Log "  Running DISM /Online /Cleanup-Image /StartComponentCleanup ..." "Gray"
    & dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase 2>&1 |
        Select-Object -Last 5 | ForEach-Object { Write-Log "  $_" "DarkGray" }
    Write-Log "  [OK]     DISM component cleanup complete" "Green"


    # --- 13. SFC SCAN ---------------------------------------------------------
    Write-Section "14/20  SFC - System File Check"
    Write-Log "  Running sfc /scannow (may take 20-60 min) ..." "Gray"
    & sfc.exe /scannow 2>&1 |
        Select-Object -Last 3 | ForEach-Object { Write-Log "  $_" "DarkGray" }
    Write-Log "  [OK]     SFC scan complete" "Green"


    # --- 14. DISK OPTIMIZATION -----------------------------------------------
    Write-Section "15/20  Disk Optimization"
    Get-Volume | Where-Object { $_.DriveLetter -and $_.FileSystemType -eq "NTFS" } |
        ForEach-Object {
            $vol    = $_
            $letter = "$($vol.DriveLetter):"
            $disk   = Get-PhysicalDisk | Where-Object {
                (Get-Partition -DriveLetter $vol.DriveLetter -ErrorAction SilentlyContinue |
                 Get-Disk -ErrorAction SilentlyContinue).SerialNumber -eq $_.SerialNumber
            } | Select-Object -First 1

            if ($disk.MediaType -eq "SSD" -or $disk.BusType -eq "NVMe") {
                Write-Log "  Retrim: $letter (SSD/NVMe)" "Gray"
                Optimize-Volume -DriveLetter $vol.DriveLetter -ReTrim -Verbose 2>&1 |
                    Select-Object -Last 5 | ForEach-Object { Write-Log "  $_" "DarkGray" }
            } else {
                Write-Log "  Defrag analysis: $letter (HDD)" "Gray"
                Optimize-Volume -DriveLetter $vol.DriveLetter -Analyze -Verbose 2>&1 |
                    Select-Object -Last 2 | ForEach-Object { Write-Log "  $_" "DarkGray" }
            }
            Write-Log "  [OK]     $letter optimized" "Green"
        }


    # --- 15. EVENT LOG ARCHIVE -----------------------------------------------
    Write-Section "16/20  Event Log - Archive Large Logs (>50MB)"
    $archivePath = "C:\Maintenance\EventLogArchive"
    if (-not (Test-Path $archivePath)) { New-Item -Path $archivePath -ItemType Directory -Force | Out-Null }

    Get-WinEvent -ListLog * -ErrorAction SilentlyContinue |
        Where-Object { $_.FileSize -gt 50MB -and $_.LogName -notlike "Microsoft*" } |
        ForEach-Object {
            $archiveFile = Join-Path $archivePath "$($_.LogName -replace '[/\\]','_')-$(Get-Date -Format 'yyyy-MM').evtx"
            try {
                wevtutil epl $_.LogName $archiveFile /ow:true 2>&1 | Out-Null
                wevtutil cl  $_.LogName 2>&1 | Out-Null
                Write-Log "  [ARCHIVE] $($_.LogName) -> $(Split-Path $archiveFile -Leaf)" "Green"
            } catch {
                Write-Log "  [SKIP]    $($_.LogName) - could not archive" "DarkGray"
            }
        }

    Get-ChildItem $archivePath -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-180) } |
        Remove-Item -Force
    Write-Log "  [OK]     Event log archives pruned (>6 months)" "Green"


    # --- 16. SERVICE DRIFT CHECK ---------------------------------------------
    Write-Section "17/20  Service Drift - Re-disabling Crept-Back Services"
    # Windows updates and app installers sometimes silently re-enable
    # disabled services. This section detects and corrects drift automatically.

    $shouldBeDisabled = @(
        "DiagTrack",                        # Windows telemetry
        "AdobeARMservice",                  # Adobe Acrobat update service
        "SQLTELEMETRY",                     # SQL Server CEIP telemetry
        "SQLWriter",                        # SQL VSS Writer (SQL 2019 remnant)
        "HPPrintScanDoctorService",         # HP Print Scan Doctor
        "DellTechHub",                      # Dell TechHub bloatware
        "DDPMNetworkKVMService",            # Dell network KVM service
        "MicrosoftCopilotElevationService", # Copilot elevation service
        "CDPSvc",                           # Connected Devices Platform (Phone Link)
        "PhoneSvc",                         # Phone Link
        "Ollama"                            # Local LLM server - start manually when needed
    )

    $driftFound = 0
    foreach ($svcName in $shouldBeDisabled) {
        $svc = Get-Service $svcName -ErrorAction SilentlyContinue
        if ($svc -and $svc.StartType -ne "Disabled" -and $svc.StartType -ne "Manual") {
            Write-Log "  [DRIFT]  $($svc.DisplayName) is '$($svc.StartType)' - re-disabling" "Yellow"
            Stop-Service $svc.Name -Force -ErrorAction SilentlyContinue
            Set-Service  $svc.Name -StartupType Disabled -ErrorAction SilentlyContinue
            $driftFound++
        }
    }

    # Also remove Ollama startup registry entry if it crept back
    $ollamaStartup = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -ErrorAction SilentlyContinue |
                     Get-Member -MemberType NoteProperty | Where-Object { $_.Name -like "*ollama*" }
    if ($ollamaStartup) {
        Remove-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name $ollamaStartup.Name -Force
        Write-Log "  [DRIFT]  Ollama startup registry entry removed" "Yellow"
        $driftFound++
    }

    if ($driftFound -eq 0) {
        Write-Log "  [OK]     No service drift detected" "Green"
    } else {
        Write-Log "  [FIXED]  $driftFound item(s) re-disabled" "Yellow"
    }


    # --- 17. .NET SDK REPORT -------------------------------------------------
    Write-Section "18/20  .NET SDK - Installed Version Report"
    Write-Log "  Installed SDKs:" "Gray"
    dotnet --list-sdks 2>&1 | ForEach-Object { Write-Log "    $_" "DarkGray" }
    Write-Log ""
    Write-Log "  To remove old versions via folder delete (elevated PS):" "Cyan"
    Write-Log "    Remove-Item 'C:\Program Files\dotnet\sdk\<version>' -Recurse -Force" "White"
    Write-Log "  Or via uninstall tool:" "Cyan"
    Write-Log "    & 'C:\Program Files (x86)\dotnet-core-uninstall\dotnet-core-uninstall.exe' list" "White"


    # --- 18. LARGE FILE REPORT -----------------------------------------------
    Write-Section "19/20  Large File Report (>500MB)"
    Write-Log "  Scanning profile for large files..." "Gray"
    $largeFiles = Get-ChildItem "C:\Users\$env:USERNAME" -Recurse -File -ErrorAction SilentlyContinue |
                  Where-Object { $_.Length -gt 500MB } |
                  Sort-Object Length -Descending |
                  Select-Object -First 20

    if ($largeFiles) {
        Write-Log "  Files over 500MB in your profile:" "Yellow"
        $largeFiles | ForEach-Object {
            Write-Log ("    {0,8} MB  {1}" -f [math]::Round($_.Length/1MB,0), $_.FullName) "DarkGray"
        }
    } else {
        Write-Log "  [OK]     No files over 500MB found" "Green"
    }


    # --- 19. DISK HEALTH CHECK -----------------------------------------------
    Write-Section "20/20  Disk Health"
    Get-PhysicalDisk | ForEach-Object {
        $color = if ($_.HealthStatus -eq "Healthy") { "Green" } else { "Red" }
        Write-Log ("  {0,-40} {1,-8} {2}" -f $_.FriendlyName, $_.MediaType, $_.HealthStatus) $color
    }

    # runs a quick scan of Windows Defender to check for malware - not a full scan since this is meant to be run weekly in Quick mode as well
    Start-MpScan -ScanType QuickScan

} # end Deep mode


# --- SUMMARY -----------------------------------------------------------------
$elapsed  = [math]::Round(((Get-Date) - $StartTime).TotalMinutes, 1)
$sections = if ($Mode -eq "Quick") { "11" } else { "20" }

Write-Section "Complete"
Write-Log "  Mode:        $Mode  ($sections sections)" "White"
Write-Log "  Total freed: $(Format-Bytes $totalFreed)" "Green"
Write-Log "  Duration:    $elapsed minutes" "White"
Write-Log "  Log saved:   $LogFile" "DarkGray"
if ($script:auditFindings -gt 0) {
    Write-Log "  SECURITY:    $($script:auditFindings) audit finding(s) - review $AlertFile" "Red"
}
Write-Log ""

$drive   = Get-PSDrive C
$freeGB  = [math]::Round($drive.Free/1GB, 1)
$freePct = [math]::Round(($drive.Free / ($drive.Used + $drive.Free)) * 100, 0)
$color   = if ($freePct -lt 15) { "Red" } elseif ($freePct -lt 25) { "Yellow" } else { "Green" }
Write-Log "  C: free now: $freeGB GB  ($freePct%)" $color
Write-Log ""

# Release the single-instance lock now - BEFORE the keypress wait below - so a
# completed window left sitting on the prompt never blocks the other task.
if ($haveLock) {
    try { $mutex.ReleaseMutex() }
    catch { Write-Log "  [NOTE]   Mutex release skipped: $($_.Exception.Message)" "DarkGray" }
    $mutex.Dispose()
}

Write-Host "  Press any key to close..." -ForegroundColor Cyan
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")