#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Setup-MaintenanceSchedule.ps1
    Installs PC-Maintenance.ps1 as two Windows Scheduled Tasks:
      - Weekly Quick  - every Sunday at 2:00 AM
      - Monthly Deep  - 1st Sunday of each month at 3:00 AM

    Run this ONCE after placing PC-Maintenance.ps1 in C:\Maintenance\
    To change the schedule, edit the trigger settings below and re-run.

.NOTES
    IDEMPOTENT: safe to re-run at any time. Folders are created only if missing,
    the script is re-copied if a source is present, and BOTH tasks are unregistered
    before re-registration, so a re-run always converges on the settings below
    regardless of prior state.

    VISIBLE, PERSISTENT WINDOW:
      - Tasks run as the current user, Interactive, elevated, and are NOT -Hidden,
        so the console window appears on your desktop while the run executes.
      - pwsh is launched with -NoExit, so the window stays open after the script
        finishes - OR exits early (Deep-active / lock-held / yield-to-Deep) OR errors.
        In all cases you drop to a live prompt in the same window with output intact.
        (The script's own "Press any key to close" still fires on a normal finish;
        -NoExit is the backstop for the early-exit / error paths that skip it.)
      - INTERACTIVE means the window only paints once you are LOGGED IN. A run missed
        while the PC was off (-StartWhenAvailable) fires at next logon, and the window
        shows then - an interactive task cannot draw on a not-yet-logged-in machine.
      - ExecutionTimeLimit is 8h: long enough that a -NoExit window left open for
        review is not killed mid-afternoon, short enough that a genuinely hung run is
        still terminated. The maintenance mutex is released before the keypress prompt,
        so a left-open window never blocks the next scheduled run.
#>

$ErrorActionPreference = "Stop"

# --- CONFIG - edit these if needed -------------------------------------------
$MaintenanceDir  = "C:\Maintenance"
$ScriptName      = "PC-Maintenance.ps1"
$ScriptSource    = "$PSScriptRoot\$ScriptName"      # assumes both scripts are in same folder
$ScriptDest      = "$MaintenanceDir\$ScriptName"

$QuickTaskName   = "PC Maintenance - Weekly Quick"
$DeepTaskName    = "PC Maintenance - Monthly Deep"

$QuickSchedule   = "Sunday"          # day of week
$QuickTime       = "02:00"           # 2:00 AM
$DeepTime        = "03:00"           # 3:00 AM (1st Sunday of month)

$ExecTimeLimitHrs = 8                 # 0 = unlimited (a hung run would never auto-kill)


# --- SETUP FOLDER ------------------------------------------------------------
Write-Host ""
Write-Host "  Setting up maintenance infrastructure..." -ForegroundColor Cyan

foreach ($dir in @($MaintenanceDir, "$MaintenanceDir\Logs", "$MaintenanceDir\EventLogArchive", "$MaintenanceDir\Baseline")) {
    if (-not (Test-Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
        Write-Host "  [CREATED] $dir" -ForegroundColor Green
    } else {
        Write-Host "  [EXISTS]  $dir" -ForegroundColor DarkGray
    }
}

# Copy script to maintenance folder (only when a source copy is present and differs
# from the destination, so re-runs from the install folder refresh it, but a re-run
# from elsewhere with the script already in place is a no-op rather than an error).
if (Test-Path $ScriptSource) {
    $needCopy = $true
    if ((Resolve-Path $ScriptSource).Path -ieq (Resolve-Path $ScriptDest -ErrorAction SilentlyContinue).Path) {
        $needCopy = $false   # source IS the destination - nothing to copy
    }
    if ($needCopy) {
        Copy-Item $ScriptSource $ScriptDest -Force
        Write-Host "  [COPIED]  $ScriptName -> $MaintenanceDir" -ForegroundColor Green
    } else {
        Write-Host "  [OK]      Source is already the installed script: $ScriptDest" -ForegroundColor DarkGray
    }
} elseif (-not (Test-Path $ScriptDest)) {
    Write-Host "  [ERROR]   Cannot find $ScriptSource" -ForegroundColor Red
    Write-Host "            Place PC-Maintenance.ps1 in the same folder as this script and re-run." -ForegroundColor Yellow
    exit 1
} else {
    Write-Host "  [OK]      Script already in place: $ScriptDest" -ForegroundColor DarkGray
}


# --- TASK SETTINGS ------------------------------------------------------------
# Run as the current user, interactive (window shows on desktop), elevated.
$principal = New-ScheduledTaskPrincipal `
    -UserId    "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType Interactive `
    -RunLevel  Highest

# -StartWhenAvailable: runs at next opportunity if the machine was off at the
#   scheduled time (fires at next logon for an interactive task).
# NO -Hidden: we WANT the console window visible on the desktop.
# ExecutionTimeLimit: see .NOTES. New-TimeSpan -Hours 0 => unlimited.
$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit    (New-TimeSpan -Hours $ExecTimeLimitHrs) `
    -MultipleInstances     IgnoreNew `
    -StartWhenAvailable

$psExe = "C:\Program Files\PowerShell\7\pwsh.exe"
if (-not (Test-Path $psExe)) {
    $psExe = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
    Write-Host "  [NOTE]    PS7 not found at default path - using Windows PowerShell 5.1" -ForegroundColor Yellow
}

# -NoExit keeps the window open after the script ends / exits early / errors.
# -NoProfile avoids dragging in profile scripts that could slow or alter the run.
$quickArgs = "-NoExit -NoProfile -ExecutionPolicy Bypass -File `"$ScriptDest`" -Mode Quick"
$deepArgs  = "-NoExit -NoProfile -ExecutionPolicy Bypass -File `"$ScriptDest`" -Mode Deep"


# --- WEEKLY QUICK TASK -------------------------------------------------------
Write-Host ""
Write-Host "  Registering: $QuickTaskName" -ForegroundColor Cyan

$quickAction  = New-ScheduledTaskAction  -Execute $psExe -Argument $quickArgs
$quickTrigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $QuickSchedule -At $QuickTime

# Idempotent: remove any existing instance before re-registering.
Unregister-ScheduledTask -TaskName $QuickTaskName -TaskPath "\Maintenance\" -Confirm:$false -ErrorAction SilentlyContinue

Register-ScheduledTask `
    -TaskName   $QuickTaskName `
    -TaskPath   "\Maintenance\" `
    -Action     $quickAction `
    -Trigger    $quickTrigger `
    -Principal  $principal `
    -Settings   $settings `
    -Description "Weekly quick PC maintenance: temp cleanup, browser cache, DNS flush, app updates." |
    Out-Null

Write-Host "  [OK]  $QuickTaskName - every $QuickSchedule at $QuickTime (visible window, stays open)" -ForegroundColor Green


# --- MONTHLY DEEP TASK -------------------------------------------------------
Write-Host ""
Write-Host "  Registering: $DeepTaskName" -ForegroundColor Cyan

$deepAction = New-ScheduledTaskAction -Execute $psExe -Argument $deepArgs

# Monthly: 1st Sunday of each month. PowerShell has no native "first Sunday"
# trigger, so register a scaffold task with a weekly Sunday trigger (to capture
# the principal/settings/action as valid Task Scheduler XML), then swap its weekly
# schedule for a MonthlyDayOfWeek schedule (Week 1, Sunday, all 12 months) and
# re-register from the patched XML.
$deepTrigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At $DeepTime

# Idempotent: remove any existing instance before re-registering the scaffold.
Unregister-ScheduledTask -TaskName $DeepTaskName -TaskPath "\Maintenance\" -Confirm:$false -ErrorAction SilentlyContinue

Register-ScheduledTask `
    -TaskName   $DeepTaskName `
    -TaskPath   "\Maintenance\" `
    -Action     $deepAction `
    -Trigger    $deepTrigger `
    -Principal  $principal `
    -Settings   $settings `
    -Description "Monthly deep PC maintenance: DISM, SFC, disk optimize, event log archive, large file report." |
    Out-Null

# Swap the weekly schedule for a true "1st Sunday of month" (MonthlyDOW) schedule.
# The .*? match is Singleline so it spans the multi-line <ScheduleByWeek> block;
# <StartBoundary> (which carries $DeepTime) is left intact. Re-register from the
# patched XML with -Force to overwrite the scaffold. Re-running this whole script
# re-creates the scaffold first, so the regex always has a <ScheduleByWeek> to match.
$monthlyDow = '<ScheduleByMonthDayOfWeek><Weeks><Week>1</Week></Weeks><DaysOfWeek><Sunday /></DaysOfWeek><Months><January /><February /><March /><April /><May /><June /><July /><August /><September /><October /><November /><December /></Months></ScheduleByMonthDayOfWeek>'
$deepXml = Export-ScheduledTask -TaskName $DeepTaskName -TaskPath "\Maintenance\"
$deepXml = [regex]::Replace($deepXml, '<ScheduleByWeek>.*?</ScheduleByWeek>', $monthlyDow, [System.Text.RegularExpressions.RegexOptions]::Singleline)
Register-ScheduledTask -Xml $deepXml -TaskName $DeepTaskName -TaskPath "\Maintenance\" -Force | Out-Null

Write-Host "  [OK]  $DeepTaskName - 1st Sunday of each month at $DeepTime (visible window, stays open)" -ForegroundColor Green


# --- VERIFY -------------------------------------------------------------------
Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  Scheduled Tasks Registered" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

Get-ScheduledTask -TaskPath "\Maintenance\" | ForEach-Object {
    $info = $_ | Get-ScheduledTaskInfo
    Write-Host ("  {0,-45} Next: {1}" -f $_.TaskName,
        $(if ($info.NextRunTime -gt (Get-Date).AddYears(-5)) { $info.NextRunTime.ToString("yyyy-MM-dd HH:mm") } else { "n/a" })
    ) -ForegroundColor White
}

Write-Host ""
Write-Host "  Window behavior:" -ForegroundColor White
Write-Host "    - Console is VISIBLE on your desktop during the run (not hidden)." -ForegroundColor DarkGray
Write-Host "    - Window STAYS OPEN after the run (-NoExit), even on early exit / error." -ForegroundColor DarkGray
Write-Host "    - A run missed while powered off fires at next LOGON, and shows then." -ForegroundColor DarkGray
Write-Host "    - Window is auto-closed after $ExecTimeLimitHrs h (ExecutionTimeLimit)." -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Files installed:" -ForegroundColor White
Write-Host "    $ScriptDest" -ForegroundColor DarkGray
Write-Host "    $MaintenanceDir\Logs\     <- maintenance logs land here" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  To run manually at any time:" -ForegroundColor White
Write-Host "    .\PC-Maintenance.ps1 -Mode Quick" -ForegroundColor Cyan
Write-Host "    .\PC-Maintenance.ps1 -Mode Deep" -ForegroundColor Cyan
Write-Host ""
Write-Host "  To update the script:" -ForegroundColor White
Write-Host "    Just replace $ScriptDest - tasks auto-pick up the new version" -ForegroundColor DarkGray
Write-Host ""