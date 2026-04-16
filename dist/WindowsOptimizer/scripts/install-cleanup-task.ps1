param(
    [string]$TaskName = "StorageCleanupSafe",
    [string]$CleanupScriptPath = "C:\\scripts\\cleanup-storage-safe.ps1",
    [int]$TempRetentionDays = 7,
    [int]$LogRetentionDays = 30,
    [switch]$RequireCore
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$pwsh = $null

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

$arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$CleanupScriptPath`" -Execute -TempRetentionDays $TempRetentionDays -LogRetentionDays $LogRetentionDays"
$action = New-ScheduledTaskAction -Execute $pwsh -Argument $arguments
$trigger = New-ScheduledTaskTrigger -Daily -At 3:15am
$settings = New-ScheduledTaskSettingsSet -RestartCount 2 -RestartInterval (New-TimeSpan -Minutes 5) -AllowStartIfOnBatteries -StartWhenAvailable
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest -LogonType ServiceAccount

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Write-Host "Scheduled task '$TaskName' installed successfully using runtime: $pwsh"
