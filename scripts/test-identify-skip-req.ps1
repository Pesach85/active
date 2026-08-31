Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$hubRoot = Split-Path -Parent $PSScriptRoot
$logs = Join-Path $hubRoot 'logs'
$req = Join-Path $logs 'test-identify-skip-req.json'
$out = Join-Path $logs 'test-identify-skip-out.json'

$body = @{
    processName = 'vmware-vmx'
    processId = 8480
    whatItIs = 'Host VMware VM'
    whatItDoes = 'Allocates guest RAM'
    category = 'Virtualization'
    priority = 'Keep'
} | ConvertTo-Json -Depth 4
[System.IO.File]::WriteAllText($req, $body)

. (Join-Path $PSScriptRoot 'hub-common.ps1')
$pwsh = Get-HubPwshExecutable
$script = Join-Path $PSScriptRoot 'identify-unknown-process.ps1'

$args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script,
    '-RequestJsonPath', $req, '-OutputJson', $out, '-SkipAuth', '-Quiet', '-HubRoot', $hubRoot)
$p = Start-Process -FilePath $pwsh -ArgumentList $args -Wait -PassThru -WindowStyle Hidden -WorkingDirectory $hubRoot
Write-Host "Exit: $($p.ExitCode)"
if (Test-Path $out) { Get-Content $out -Raw }
