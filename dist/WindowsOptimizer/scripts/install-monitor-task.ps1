param(
    [string]$TaskName = "SystemResourceMonitor",
    [string]$MonitorScriptPath = "C:\\scripts\\monitor-resources.ps1",
    [string]$ConfigPath = "C:\\config\\sys-maintenance.json",
    [switch]$RequireCore
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$pwsh = $null

if (-not (Test-Path -LiteralPath $MonitorScriptPath)) {
    throw "Monitor script not found: $MonitorScriptPath"
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

$arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$MonitorScriptPath`" -ConfigPath `"$ConfigPath`""
$action = New-ScheduledTaskAction -Execute $pwsh -Argument $arguments
$trigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -StartWhenAvailable
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest -LogonType ServiceAccount

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Write-Host "Scheduled task '$TaskName' installed successfully using runtime: $pwsh"
