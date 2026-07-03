param(
    [string]$TaskName = "StorageCleanupSafe",
    [string]$CleanupScriptPath = "",
    [int]$TempRetentionDays = 0,
    [int]$LogRetentionDays = 0,
    [string]$ConfigPath = "",
    [switch]$RequireCore
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot 'hub-common.ps1')
$hub = Get-HubPaths
if ([string]::IsNullOrWhiteSpace($CleanupScriptPath)) {
    $CleanupScriptPath = Join-Path $hub.Scripts 'cleanup-storage-safe.ps1'
}
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = $hub.ConfigFile
}

if (Test-Path -LiteralPath $ConfigPath) {
    $cfg = Get-MaintenanceConfig -ConfigPath $ConfigPath
    $cleanupCfg = Get-ConfigSection -Config $cfg -SectionName 'Cleanup'
    if ($TempRetentionDays -le 0 -and $cleanupCfg.TempRetentionDays) {
        $TempRetentionDays = [int]$cleanupCfg.TempRetentionDays
    }
    if ($LogRetentionDays -le 0 -and $cleanupCfg.LogRetentionDays) {
        $LogRetentionDays = [int]$cleanupCfg.LogRetentionDays
    }
}
if ($TempRetentionDays -le 0) { $TempRetentionDays = 7 }
if ($LogRetentionDays -le 0) { $LogRetentionDays = 30 }

if (-not (Test-Path -LiteralPath $CleanupScriptPath)) {
    throw "Cleanup script not found: $CleanupScriptPath"
}

function Resolve-PowerShellRuntime {
    param([bool]$CoreOnly)

    $pwshCommand = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwshCommand) {
        return $pwshCommand.Path
    }

    if ($CoreOnly) {
        throw "PowerShell Core (pwsh) not found in PATH. Run ensure-powershell-core.ps1 first."
    }

    $windowsPsCommand = Get-Command powershell -ErrorAction SilentlyContinue
    if ($windowsPsCommand) {
        return $windowsPsCommand.Path
    }

    throw "No PowerShell runtime found in PATH."
}

$pwsh = Resolve-PowerShellRuntime -CoreOnly:$RequireCore.IsPresent

$arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$CleanupScriptPath`" -Execute -ConfigPath `"$ConfigPath`" -TempRetentionDays $TempRetentionDays -LogRetentionDays $LogRetentionDays"
$action = New-ScheduledTaskAction -Execute $pwsh -Argument $arguments
$trigger = New-ScheduledTaskTrigger -Daily -At 3:15am
$settings = New-ScheduledTaskSettingsSet -RestartCount 2 -RestartInterval (New-TimeSpan -Minutes 5) -AllowStartIfOnBatteries -StartWhenAvailable
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest -LogonType ServiceAccount

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Write-Host "Scheduled task '$TaskName' installed successfully using runtime: $pwsh"
