[CmdletBinding()]
param(
    [string]$HubRoot = '',
    [switch]$BuildGui,
    [switch]$RegisterTasks
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $HubRoot) { $HubRoot = Split-Path -Parent $scriptDir }

. (Join-Path $scriptDir 'lib\windows-app-install.ps1')
$profile = Get-InstallProfile -HubRoot $HubRoot
$installRoot = Expand-InstallProfilePath -Template $profile.Windows.DefaultInstallRoot
$manifest = Read-HubInstallManifest -InstallRoot $installRoot

if (-not $manifest) {
    Write-Warning "No install manifest at $installRoot - run install-windows-app.ps1 first."
}

$distSource = Join-Path $HubRoot ([string]$profile.Windows.DevSyncSourceRelative)
& (Join-Path $scriptDir 'package-suite.ps1') -OutputDir $distSource | Out-Host

if ($BuildGui) {
    & (Join-Path $scriptDir 'build-gui-exe.ps1') | Out-Host
}

foreach ($bat in @('Launch-Hub.bat', 'Launch-Transparency-Web.bat')) {
    Copy-Item -LiteralPath (Join-Path $scriptDir $bat) -Destination (Join-Path $distSource $bat) -Force
}

$appRoot = Get-HubAppRoot -InstallRoot $installRoot -AppSubdir $profile.Windows.AppSubdir
if ($manifest -and [bool]$manifest.DevSync) {
    if (-not (Test-HubDevSyncJunction -AppRoot $appRoot)) {
        Write-Host "[DEV-SYNC] Recreating junction..."
        Set-HubDevSyncJunction -AppRoot $appRoot -SourceDistPath $distSource
    }
    Write-Host "[DEV-SYNC] Production app updated via junction -> $distSource"
}
elseif (Test-Path -LiteralPath $appRoot) {
    Write-Host "[DEV-SYNC] Mirror refresh (non-junction install)..."
    Copy-HubAppMirror -AppRoot $appRoot -SourceDistPath $distSource
}

if ($RegisterTasks -and (Test-Path -LiteralPath $appRoot)) {
    $ensureScript = Join-Path $appRoot 'scripts\ensure-powershell-core.ps1'
    if (Test-Path -LiteralPath $ensureScript) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $ensureScript -ApplyTasksCoreOnly `
            -MonitorInstallerPath (Join-Path $appRoot 'scripts\install-monitor-task.ps1') `
            -CleanupInstallerPath (Join-Path $appRoot 'scripts\install-cleanup-task.ps1') | Out-Null
    }
}

Write-Host "[DEV-SYNC] Done. Installed app at $appRoot reflects latest dist."
