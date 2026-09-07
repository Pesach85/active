#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RollbackJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $RollbackJson)) { throw "Rollback not found: $RollbackJson" }
$rb = Get-Content -LiteralPath $RollbackJson -Raw | ConvertFrom-Json

Write-Host "[RESTORE] Defender rollback from $RollbackJson"

foreach ($path in @($rb.ExclusionPathsAdded)) {
    try {
        Remove-MpPreference -ExclusionPath ([string]$path) -ErrorAction Stop
        Write-Host "Removed exclusion: $path"
    } catch {
        Write-Warning $_.Exception.Message
    }
}

try {
    Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction SilentlyContinue
    Write-Host 'Real-time monitoring re-enabled.'
} catch {
    Write-Warning $_.Exception.Message
}

foreach ($svcState in @($rb.ServiceStates)) {
    $name = [string]$svcState.Name
    if ($name -eq 'WinDefend') {
        try {
            Set-Service -Name WinDefend -StartupType Automatic -ErrorAction Stop
            Start-Service -Name WinDefend -ErrorAction Stop
            Write-Host 'WinDefend service restored to Automatic/Running.'
        } catch {
            Write-Warning $_.Exception.Message
        }
    }
}

if ($rb.ScheduledTaskName) {
    Unregister-ScheduledTask -TaskName ([string]$rb.ScheduledTaskName) -Confirm:$false -ErrorAction SilentlyContinue
}

Write-Host '[RESTORE] Complete. Verify Windows Security status manually.'
