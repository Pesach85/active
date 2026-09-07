[CmdletBinding()]
param(
    [string]$InstallRoot = "",
    [string]$SourceRoot = "",
    [switch]$CoreInstallIfMissing,
    [switch]$Desktop,
    [switch]$DevSync,
    [switch]$NoDevSync,
    [switch]$RegisterTasks
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
    $SourceRoot = Split-Path $scriptDir -Parent
}

$installArgs = @{
    HubRoot = $SourceRoot
    Desktop = $true
}
if ($InstallRoot) { $installArgs['InstallRoot'] = $InstallRoot }
if ($DevSync) { $installArgs['DevSync'] = $true }
if ($NoDevSync) { $installArgs['NoDevSync'] = $true }
if ($RegisterTasks -or $CoreInstallIfMissing) { $installArgs['RegisterTasks'] = $true }

& (Join-Path $scriptDir 'install-windows-app.ps1') @installArgs
