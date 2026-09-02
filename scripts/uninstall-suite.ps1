[CmdletBinding()]
param(
    [string]$InstallRoot = "",
    [switch]$RemoveInstallRoot,
    [switch]$UnregisterTasks
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = $PSScriptRoot
$hubRoot = Split-Path $scriptDir -Parent

$uninstallArgs = @{
    HubRoot = $hubRoot
    RemoveDesktopShortcuts = $true
    UnregisterTasks = $true
}
if ($InstallRoot) { $uninstallArgs['InstallRoot'] = $InstallRoot }
if ($RemoveInstallRoot) { $uninstallArgs['RemoveApp'] = $true }

& (Join-Path $scriptDir 'uninstall-windows-app.ps1') @uninstallArgs
