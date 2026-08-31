[CmdletBinding()]
param(
    [string]$ConfigPath = '',
    [int]$Port = 8765,
    [string]$BindAddress = '127.0.0.1',
    [switch]$OpenBrowser,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'hub-common.ps1')

$ensureScript = Join-Path $scriptDir 'ensure-transparency-web.ps1'
$pwshExe = Get-HubPwshExecutable

$args = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ensureScript,
    '-Port', "$Port", '-BindAddress', $BindAddress
)
if ($ConfigPath) { $args += @('-ConfigPath', $ConfigPath) }
if ($Quiet) { $args += '-Quiet' }

& $pwshExe @args
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

if ($OpenBrowser) {
    Start-Process "http://${BindAddress}:${Port}/" | Out-Null
}

exit 0
