[CmdletBinding()]
param(
    [string]$InstallRoot = '',
    [string]$HubRoot = '',
    [switch]$DevSync,
    [switch]$NoDevSync,
    [switch]$Desktop,
    [switch]$PinToTaskbar,
    [switch]$RegisterTasks,
    [switch]$BuildGui,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $HubRoot) { $HubRoot = Split-Path -Parent $scriptDir }

. (Join-Path $scriptDir 'hub-common.ps1')
. (Join-Path $scriptDir 'lib\windows-app-install.ps1')

$profile = Get-InstallProfile -HubRoot $HubRoot
if (-not $InstallRoot) {
    $InstallRoot = Expand-InstallProfilePath -Template $profile.Windows.DefaultInstallRoot
}

$useDevSync = $profile.Windows.DevSyncDefault
if ($DevSync) { $useDevSync = $true }
if ($NoDevSync) { $useDevSync = $false }

$distSource = Join-Path $HubRoot ([string]$profile.Windows.DevSyncSourceRelative)
$packageScript = Join-Path $scriptDir 'package-suite.ps1'

Write-Host "[INSTALL] Building package dist..."
& $packageScript -OutputDir $distSource | Out-Host

if ($BuildGui) {
    $buildGui = Join-Path $scriptDir 'build-gui-exe.ps1'
    if (Test-Path -LiteralPath $buildGui) {
        Write-Host "[INSTALL] Building GUI exe..."
        & $buildGui | Out-Host
    }
}

# Copy launchers into dist root
foreach ($bat in @('Launch-Hub.bat', 'Launch-Transparency-Web.bat')) {
    $src = Join-Path $scriptDir $bat
    if (Test-Path -LiteralPath $src) {
        Copy-Item -LiteralPath $src -Destination (Join-Path $distSource $bat) -Force
    }
}

New-Item -Path $InstallRoot -ItemType Directory -Force | Out-Null
$appRoot = Get-HubAppRoot -InstallRoot $InstallRoot -AppSubdir $profile.Windows.AppSubdir

if ($useDevSync) {
    Write-Host "[INSTALL] Dev-sync junction -> $distSource"
    Set-HubDevSyncJunction -AppRoot $appRoot -SourceDistPath $distSource
}
else {
    Write-Host "[INSTALL] Mirror copy app to $appRoot"
    Copy-HubAppMirror -AppRoot $appRoot -SourceDistPath $distSource
}

Install-HubWindowsShortcuts -AppRoot $appRoot -Profile $profile -CreateDesktopShortcuts:$Desktop -PinToTaskbar:$PinToTaskbar

if ($RegisterTasks) {
    $ensureScript = Join-Path $appRoot 'scripts\ensure-powershell-core.ps1'
    if (Test-Path -LiteralPath $ensureScript) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $ensureScript `
            -ApplyTasksCoreOnly `
            -MonitorInstallerPath (Join-Path $appRoot 'scripts\install-monitor-task.ps1') `
            -CleanupInstallerPath (Join-Path $appRoot 'scripts\install-cleanup-task.ps1') | Out-Null
    }
    $orchScript = Join-Path $appRoot 'scripts\install-orchestrator-task.ps1'
    if (Test-Path -LiteralPath $orchScript) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $orchScript -HubRoot $appRoot | Out-Null
    }
}

$manifestPath = Write-HubInstallManifest -InstallRoot $InstallRoot -AppRoot $appRoot `
    -HubRoot $HubRoot -DevSync $useDevSync -DevSyncSource $(if ($useDevSync) { $distSource } else { '' })

Write-Host "[INSTALL] Complete."
Write-Host "  InstallRoot: $InstallRoot"
Write-Host "  AppRoot:     $appRoot"
Write-Host "  DevSync:     $useDevSync"
Write-Host "  Manifest:    $manifestPath"
Write-Host "  Start Menu:  $($profile.Windows.StartMenuFolder)"

if ($useDevSync) {
    Write-Host ""
    Write-Host "Dev-sync active: edit repo + run scripts\dev-sync-production.ps1 to refresh dist; installed app updates instantly."
}
