Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$hubRoot = 'D:\SystemOptimizerHub\active'
$scriptDir = Join-Path $hubRoot 'scripts'
. (Join-Path $scriptDir 'hub-common.ps1')
. (Join-Path $scriptDir 'lib\operator-auth.ps1')
$hub = Get-HubPaths -HubRoot $hubRoot
$resolveScript = Join-Path $scriptDir 'resolve-unknown-process.ps1'
$pwshExe = Get-HubPwshExecutable

$reqBody = @{ action = 'Advisory'; offline = $true; processId = 8480; processName = 'vmware-vmx' }
$run = Invoke-HubProcessScriptViaRequest -ScriptPath $resolveScript -RequestBody $reqBody -LogsDir $hub.Logs -PwshExe $pwshExe -HubRoot $hubRoot
Write-Host "Exit: $($run.ExitCode) Payload: $($null -ne $run.Payload) Stderr: $($run.Stderr)"
if ($run.Payload) { Write-Host "Outcome: $($run.Payload.Outcome)" }
