#Requires -RunAsAdministrator
<#
.SYNOPSIS
    PC-Maintenance.ps1 - Reusable scheduled maintenance script

.DESCRIPTION
    Two modes:
      -Mode Quick   Weekly. Fast (~5-10 min). Clears temp/cache, updates all
                    package sources (winget/choco/scoop/npm/pip/dotnet tools),
                    flushes DNS, checks for stale scheduled tasks.
      -Mode Deep    Monthly. Thorough (~20-40 min). Everything in Quick plus:
                    PowerShell module updates, DISM, SFC, disk optimization,
                    service drift check, event log archive, .NET SDK report,
                    large file scan, disk health check.

.PARAMETER Mode
    Quick | Deep  (default: Quick)

.PARAMETER LogPath
    Where to write the log file. Default: C:\Maintenance\Logs\

.EXAMPLE
    .\PC-Maintenance.ps1 -Mode Quick
    .\PC-Maintenance.ps1 -Mode Deep

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
    [string]$LogPath = "C:\Maintenance\Logs"
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
# Deep is a strict superset of Quick (sections 1-10 are identical), so a Quick run
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
Write-Section "1/10  Temp Files"

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
Write-Section "2/10  Browser Caches"

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
Write-Section "3/10  Windows Update Cache & Delivery Optimization"

Stop-Service wuauserv -Force
$totalFreed += Clear-Directory "C:\Windows\SoftwareDistribution\Download" "Windows Update Downloads"
Start-Service wuauserv
Write-Log "  [OK]     Windows Update service restarted" "Green"

Stop-Service DoSvc -Force
$totalFreed += Clear-Directory "C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache" "Delivery Optimization Cache"
Start-Service DoSvc


# --- 4. THUMBNAIL & ICON CACHE ------------------------------------------------
Write-Section "4/10  Thumbnail & Icon Cache"

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
Write-Section "5/10  DNS Cache"
ipconfig /flushdns | Out-Null
Write-Log "  [OK]     DNS cache flushed" "Green"


# --- 6. RECYCLE BIN -----------------------------------------------------------
Write-Section "6/10  Recycle Bin"
$shell  = New-Object -ComObject Shell.Application
$rb     = $shell.Namespace(0xa)
$rbSize = ($rb.Items() | Measure-Object -Property Size -Sum).Sum
Clear-RecycleBin -Force -ErrorAction SilentlyContinue
Write-Log "  [CLEAN]  Recycle Bin - freed $(Format-Bytes $rbSize)" "Green"
$totalFreed += $rbSize


# --- 7. ALL SOURCE APP UPDATES ------------------------------------------------
Write-Section "7/10  App Updates - All Sources"

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
Write-Section "8/10  Storage Sense"
$storageSenseKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy"
if (Test-Path $storageSenseKey) {
    Set-ItemProperty -Path $storageSenseKey -Name "01" -Value 1
    Write-Log "  [OK]     Storage Sense triggered" "Green"
} else {
    Write-Log "  [SKIP]   Storage Sense key not found" "DarkGray"
}


# --- 9. OLD MAINTENANCE LOGS -------------------------------------------------
Write-Section "9/10  Pruning Old Maintenance Logs (>90 days)"
$oldLogs = Get-ChildItem $LogPath -File -ErrorAction SilentlyContinue |
           Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-90) }
$oldLogs | Remove-Item -Force -ErrorAction SilentlyContinue
Write-Log "  [CLEAN]  Removed $($oldLogs.Count) old log file(s)" "Green"


# --- 10. STALE SCHEDULED TASKS -----------------------------------------------
Write-Section "10/10  Stale Scheduled Tasks - Broken File References"
# Reports tasks pointing to missing executables.
# Review flagged items in Autoruns and remove manually if appropriate.
$staleFound = 0
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
            Write-Log "  [STALE]  $($task.TaskPath)$($task.TaskName)" "Yellow"
            Write-Log "           Missing: $exe" "DarkGray"
            $staleFound++
        }
    }
}
if ($staleFound -eq 0) {
    Write-Log "  [OK]     No stale tasks found" "Green"
} else {
    Write-Log "  [NOTE]   $staleFound stale task(s) - review in Autoruns -> Scheduled Tasks tab" "Yellow"
}


# ===============================================================================
#  DEEP - monthly additional steps
# ===============================================================================

if ($Mode -eq "Deep") {

    # --- 11. POWERSHELL MODULE UPDATES ---------------------------------------
    Write-Section "11/19  PowerShell Module Updates (PSGallery)"
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
    Write-Section "12/19  DISM - Component Store Cleanup (may take 5-20 min)"
    Write-Log "  Running DISM /Online /Cleanup-Image /StartComponentCleanup ..." "Gray"
    & dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase 2>&1 |
        Select-Object -Last 5 | ForEach-Object { Write-Log "  $_" "DarkGray" }
    Write-Log "  [OK]     DISM component cleanup complete" "Green"


    # --- 13. SFC SCAN ---------------------------------------------------------
    Write-Section "13/19  SFC - System File Check"
    Write-Log "  Running sfc /scannow (may take 20-60 min) ..." "Gray"
    & sfc.exe /scannow 2>&1 |
        Select-Object -Last 3 | ForEach-Object { Write-Log "  $_" "DarkGray" }
    Write-Log "  [OK]     SFC scan complete" "Green"


    # --- 14. DISK OPTIMIZATION -----------------------------------------------
    Write-Section "14/19  Disk Optimization"
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
    Write-Section "15/19  Event Log - Archive Large Logs (>50MB)"
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
    Write-Section "16/19  Service Drift - Re-disabling Crept-Back Services"
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
    Write-Section "17/19  .NET SDK - Installed Version Report"
    Write-Log "  Installed SDKs:" "Gray"
    dotnet --list-sdks 2>&1 | ForEach-Object { Write-Log "    $_" "DarkGray" }
    Write-Log ""
    Write-Log "  To remove old versions via folder delete (elevated PS):" "Cyan"
    Write-Log "    Remove-Item 'C:\Program Files\dotnet\sdk\<version>' -Recurse -Force" "White"
    Write-Log "  Or via uninstall tool:" "Cyan"
    Write-Log "    & 'C:\Program Files (x86)\dotnet-core-uninstall\dotnet-core-uninstall.exe' list" "White"


    # --- 18. LARGE FILE REPORT -----------------------------------------------
    Write-Section "18/19  Large File Report (>500MB)"
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
    Write-Section "19/19  Disk Health"
    Get-PhysicalDisk | ForEach-Object {
        $color = if ($_.HealthStatus -eq "Healthy") { "Green" } else { "Red" }
        Write-Log ("  {0,-40} {1,-8} {2}" -f $_.FriendlyName, $_.MediaType, $_.HealthStatus) $color
    }

    # runs a quick scan of Windows Defender to check for malware - not a full scan since this is meant to be run weekly in Quick mode as well
    Start-MpScan -ScanType QuickScan

} # end Deep mode


# --- SUMMARY -----------------------------------------------------------------
$elapsed  = [math]::Round(((Get-Date) - $StartTime).TotalMinutes, 1)
$sections = if ($Mode -eq "Quick") { "10" } else { "19" }

Write-Section "Complete"
Write-Log "  Mode:        $Mode  ($sections sections)" "White"
Write-Log "  Total freed: $(Format-Bytes $totalFreed)" "Green"
Write-Log "  Duration:    $elapsed minutes" "White"
Write-Log "  Log saved:   $LogFile" "DarkGray"
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
