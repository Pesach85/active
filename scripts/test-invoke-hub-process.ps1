Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$hubRoot = 'D:\SystemOptimizerHub\active'
$scriptDir = Join-Path $hubRoot 'scripts'
. (Join-Path $scriptDir 'hub-common.ps1')
. (Join-Path $scriptDir 'lib\operator-auth.ps1')
$hub = Get-HubPaths -HubRoot $hubRoot
$resolveScript = Join-Path $scriptDir 'resolve-unknown-process.ps1'
$pwshExe = Get-HubPwshExecutable

function Invoke-HubProcessScript {
    param([string]$ScriptPath, [string[]]$ArgumentList)
    $tmpOut = Join-Path $hub.Logs ("web-api-{0}.json" -f ([guid]::NewGuid().ToString('N')))
    $errLog = Join-Path $hub.Logs ("web-api-{0}.err" -f ([guid]::NewGuid().ToString('N')))
    $resolved = Resolve-HubProcessScriptArguments -ArgumentList $ArgumentList -LogsDir $hub.Logs
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + $resolved.ArgumentList + @('-OutputJson', $tmpOut, '-Quiet', '-HubRoot', $hubRoot)
    Write-Host "Args: $($args -join ' | ')"
    $proc = Start-Process -FilePath $pwshExe -ArgumentList $args -Wait -PassThru -WindowStyle Hidden -RedirectStandardError $errLog -WorkingDirectory $hubRoot
    Write-Host "Exit: $($proc.ExitCode)"
    if (Test-Path $errLog) { Write-Host "ERR:"; Get-Content $errLog -Raw }
    if (Test-Path $tmpOut) { Write-Host "OUT ok, len:" (Get-Item $tmpOut).Length }
}

$args = @('-Action', 'Advisory', '-Offline', '-ProcessId', '8480', '-ProcessName', 'vmware-vmx')
Invoke-HubProcessScript -ScriptPath $resolveScript -ArgumentList $args
