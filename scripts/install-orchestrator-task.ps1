param(
    [string]$TaskName = 'SystemOptimizerHub-Orchestrator',
    [string]$OrchestratorScriptPath = '',
    [string]$ConfigPath = '',
    [switch]$RequireCore
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'hub-common.ps1')
$hub = Get-HubPaths
if ([string]::IsNullOrWhiteSpace($OrchestratorScriptPath)) {
    $OrchestratorScriptPath = Join-Path $hub.Scripts 'hub-orchestrator.ps1'
}
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = $hub.ConfigFile
}

if (-not (Test-Path -LiteralPath $OrchestratorScriptPath)) {
    throw "Orchestrator script not found: $OrchestratorScriptPath"
}

function Resolve-PowerShellRuntime {
    param([bool]$CoreOnly)
    $pwshCommand = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwshCommand) { return $pwshCommand.Path }
    if ($CoreOnly) { throw 'PowerShell Core (pwsh) not found.' }
    $windowsPsCommand = Get-Command powershell -ErrorAction SilentlyContinue
    if ($windowsPsCommand) { return $windowsPsCommand.Path }
    throw 'No PowerShell runtime found.'
}

$pwsh = Resolve-PowerShellRuntime -CoreOnly:$RequireCore.IsPresent
$arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$OrchestratorScriptPath`" -ConfigPath `"$ConfigPath`""
$action = New-ScheduledTaskAction -Execute $pwsh -Argument $arguments
$trigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -StartWhenAvailable
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest -LogonType ServiceAccount

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Write-Host "Scheduled task '$TaskName' installed using: $pwsh"
