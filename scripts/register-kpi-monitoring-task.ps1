#Requires -RunAsAdministrator
<#
.SYNOPSIS
Register scheduled task to run KPI monitoring every 5 minutes during observation period.
Task triggers Wave 4 decision analysis when observation complete.

.PARAMETER TaskName
Default: "NVMe-KPI-Monitor-7Day"

.PARAMETER StartTime
Start monitoring at this time (default: now)

.PARAMETER MonitoringDurationDays
How many days to run monitoring (default: 7)
#>

param(
    [string]$TaskName = "NVMe-KPI-Monitor-7Day",
    [DateTime]$StartTime = (Get-Date),
    [int]$MonitoringDurationDays = 7
)

$ErrorActionPreference = "Stop"

function Register-KPIMonitoringTask {
    param(
        [string]$TaskName,
        [DateTime]$StartTime,
        [int]$DurationDays
    )
    
    $scriptPath = "C:\SystemOptimizerHub\active\scripts\monitor-nvme-kpi-7day.ps1"
    
    if (-not (Test-Path $scriptPath)) {
        throw "KPI monitoring script not found at: $scriptPath"
    }
    
    # PowerShell action: run monitoring script every 5 minutes
    $action = New-ScheduledTaskAction -Execute "pwsh.exe" `
        -Argument @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$scriptPath`"")
    
    # Trigger: every 5 minutes, starting now, for 7 days
    $endTime = $StartTime.AddDays($DurationDays)
    
    $trigger = New-ScheduledTaskTrigger -Once `
        -At $StartTime `
        -RepetitionInterval (New-TimeSpan -Minutes 5) `
        -RepetitionDuration (New-TimeSpan -Days $DurationDays)
    
    # Settings: run even if logged off, don't stop if running longer than 10 min
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RunOnlyIfNetworkAvailable:$false
    
    $settings.ExecutionTimeLimit = [TimeSpan]::FromMinutes(15)
    
    # Register task
    $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        Write-Host "Updating existing task: $TaskName" -ForegroundColor Yellow
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }
    
    $task = Register-ScheduledTask -TaskName $TaskName `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -RunLevel Highest `
        -Force
    
    Write-Host "✅ Scheduled task registered: $TaskName" -ForegroundColor Green
    Write-Host "   Start: $StartTime" -ForegroundColor White
    Write-Host "   End: $endTime" -ForegroundColor White
    Write-Host "   Interval: Every 5 minutes" -ForegroundColor White
    Write-Host "   Expected samples: $([math]::Ceiling((24 * $DurationDays) * 12)) over $DurationDays days" -ForegroundColor White
    
    return $task
}

try {
    Write-Host "🚀 Registering NVMe KPI monitoring task..." -ForegroundColor Cyan
    $task = Register-KPIMonitoringTask -TaskName $TaskName -StartTime $StartTime -DurationDays $MonitoringDurationDays
    
    Write-Host "`n📊 Monitoring now active. Review logs in: logs/kpi-observation-snapshot-*.json" -ForegroundColor Green
    Write-Host "`nDecision criteria (after 7 days):" -ForegroundColor Cyan
    Write-Host "  ✅ Go Wave 4: ≥30% NVMe write reduction + C: stable + no instability" -ForegroundColor Green
    Write-Host "  ⏸️  Hold: <30% reduction or instability detected" -ForegroundColor Yellow
    Write-Host "  ❌ Rollback: Wave 1-3 regression" -ForegroundColor Red
    
    exit 0
} catch {
    Write-Error "Failed to register KPI monitoring task: $_"
    exit 1
}
