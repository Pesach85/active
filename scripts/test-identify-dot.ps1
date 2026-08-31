Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$hubRoot = Split-Path -Parent $PSScriptRoot
$logs = Join-Path $hubRoot 'logs'
$out = Join-Path $logs 'test-identify-dot-out.json'
$err = Join-Path $logs 'test-identify-dot.err'
$req = Join-Path $logs 'test-identify-dot-req.json'

$body = @{
    processId = 8480
    processName = 'vmware-vmx'
    whatItIs = 'Host VMware VM'
    whatItDoes = 'Allocates guest RAM'
    category = 'Virtualization'
    priority = 'Keep'
    businessHint = ''
    note = ''
    password = 'fake.password.with.dots'
} | ConvertTo-Json -Depth 4
[System.IO.File]::WriteAllText($req, $body)

. (Join-Path $PSScriptRoot 'hub-common.ps1')
$pwsh = Get-HubPwshExecutable
$script = Join-Path $PSScriptRoot 'identify-unknown-process.ps1'

$args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script, '-RequestJsonPath', $req, '-OutputJson', $out, '-Quiet', '-HubRoot', $hubRoot)
Write-Host "Args count: $($args.Count)"
$p = Start-Process -FilePath $pwsh -ArgumentList $args -Wait -PassThru -WindowStyle Hidden -RedirectStandardError $err -WorkingDirectory $hubRoot
Write-Host "Exit: $($p.ExitCode)"
if (Test-Path $out) { Get-Content $out -Raw }
if (Test-Path $err) { Write-Host "ERR:"; Get-Content $err -Raw }
