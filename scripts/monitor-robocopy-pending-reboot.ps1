<#
.SYNOPSIS
    Monitor robocopy status and plan post-reboot Wave 3 verification.

.DESCRIPTION
    Checks if robocopy is still running. If complete, suggests reboot timing.
    Generates status JSON for tracking and prepares post-reboot verify task.

.PARAMETER StatusJsonPath
    Path to write robocopy/reboot status tracker.

.PARAMETER SchedulePostBootTask
    If true, creates scheduled task to run verify script on next boot.

.EXAMPLE
    .\monitor-robocopy-pending-reboot.ps1 -StatusJsonPath logs/robocopy-reboot-status.json -SchedulePostBootTask
#>
param(
    [string]$StatusJsonPath = 'logs/robocopy-reboot-status.json',
    [switch]$SchedulePostBootTask
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

function Write-Progress2 {
    param([string]$Message)
    Write-Host "[ROBOCOPY-MONITOR] $Message"
}

$status = [ordered]@{
    Timestamp = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
    RobocopyRunning = $false
    RobocopyProcesses = @()
    PagefileConfigReady = $false
    RebootPending = $false
    NextAction = ''
}

try {
    # Check for active robocopy processes
    $roboCopyProcs = @(Get-Process -Name 'robocopy' -ErrorAction SilentlyContinue)
    $status.RobocopyRunning = $roboCopyProcs.Count -gt 0
    if ($roboCopyProcs.Count -gt 0) {
        $status.RobocopyProcesses = @($roboCopyProcs | Select-Object -Property Name, Id, StartTime | ConvertTo-Json)
        Write-Progress2 "Found $($roboCopyProcs.Count) robocopy process(es) still running."
    } else {
        Write-Progress2 "No active robocopy processes detected."
    }

    # Verify pagefile config is in registry (from S80)
    $regPath = 'HKLM:\System\CurrentControlSet\Control\Session Manager\Memory Management'
    $pagingFilesValue = $null
    if (Test-Path -LiteralPath $regPath) {
        $pagingFilesValue = Get-ItemProperty -Path $regPath -Name 'PagingFiles' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty PagingFiles
    }
    $status.PagefileConfigReady = $null -ne $pagingFilesValue -and ($pagingFilesValue -like "*C:\DataHub\Pagefile\pagefile.sys*")
    Write-Progress2 "Pagefile registry config ready: $($status.PagefileConfigReady)"

    # Determine reboot readiness
    if (-not $status.RobocopyRunning) {
        $status.RebootPending = $true
        $status.NextAction = 'Robocopy complete. Ready for reboot to activate pagefile relocation. Run: shutdown /s /t 300 /c "NVMe write-offload Wave 3 reboot"'
        Write-Progress2 "Robocopy complete. Reboot recommended to activate Wave 3 pagefile relocation."
    } else {
        $status.NextAction = 'Robocopy still in progress. Check status with: Get-Process robocopy | Select-Object Id,StartTime,Name'
        Write-Progress2 "Robocopy still running. Defer reboot until it completes."
    }

    # Schedule post-boot task if requested
    if ($SchedulePostBootTask -and $status.PagefileConfigReady) {
        try {
            $taskName = 'NVMe-WriteOffload-PostBootVerify'
            $scriptPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) 'verify-nvme-writeoffload-postboot.ps1'
            $logPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) '..\logs\writeoffload-verify-postboot.json'

            # Create task action to run verification script
            $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File ""$scriptPath"" -OutputJson ""$logPath"""
            $trigger = New-ScheduledTaskTrigger -AtStartup

            # Register task (overwrites if exists)
            if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
                Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
            }
            Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -RunLevel Highest -Force | Out-Null
            $status.PostBootTaskScheduled = $true
            Write-Progress2 "Scheduled task '$taskName' to run post-reboot verification."
        }
        catch {
            Write-Progress2 "Warning: Could not schedule post-boot task: $_"
            $status.PostBootTaskScheduled = $false
        }
    }
}
catch {
    Write-Progress2 "Error during monitoring: $_"
    $status.Error = $_.Exception.Message
}
finally {
    $folder = Split-Path -Parent $StatusJsonPath
    if (-not (Test-Path -LiteralPath $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }
    $json = $status | ConvertTo-Json -Depth 6 -Compress:$false
    [System.IO.File]::WriteAllText($StatusJsonPath, $json, [System.Text.Encoding]::UTF8)
    Write-Progress2 "Status saved to $StatusJsonPath"
}
