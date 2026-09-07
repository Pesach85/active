[CmdletBinding()]
param(
    [string]$InstallRoot = '',
    [string]$HubRoot = '',
    [switch]$RemoveApp,
    [switch]$RemoveDesktopShortcuts,
    [switch]$UnregisterTasks
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $HubRoot) { $HubRoot = Split-Path -Parent $scriptDir }

. (Join-Path $scriptDir 'lib\windows-app-install.ps1')

$profile = Get-InstallProfile -HubRoot $HubRoot
if (-not $InstallRoot) {
    $InstallRoot = Expand-InstallProfilePath -Template $profile.Windows.DefaultInstallRoot
}

Remove-HubWindowsShortcuts -Profile $profile -RemoveDesktopShortcuts:$RemoveDesktopShortcuts

if ($UnregisterTasks) {
    $taskNames = @($profile.Windows.ScheduledTasks) + @('NVMe-WriteOffload-PostBootVerify')
    foreach ($task in $taskNames) {
        try {
            Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction Stop
            Write-Host "[UNINSTALL] Removed task: $task"
        } catch {
            Write-Host "[UNINSTALL] Task not removed ($task): $($_.Exception.Message)"
        }
    }
}

if ($RemoveApp) {
    $appRoot = Get-HubAppRoot -InstallRoot $InstallRoot -AppSubdir $profile.Windows.AppSubdir
    if (Test-Path -LiteralPath $appRoot) {
        if (Test-HubDevSyncJunction -AppRoot $appRoot) {
            cmd /c "rmdir `"$appRoot`"" 2>$null | Out-Null
            Write-Host "[UNINSTALL] Removed dev-sync junction: $appRoot"
        }
        else {
            Remove-Item -LiteralPath $appRoot -Recurse -Force
            Write-Host "[UNINSTALL] Removed app copy: $appRoot"
        }
    }
    $manifest = Join-Path $InstallRoot 'install-manifest.json'
    if (Test-Path -LiteralPath $manifest) { Remove-Item -LiteralPath $manifest -Force }
    if ((Get-ChildItem -LiteralPath $InstallRoot -Force -ErrorAction SilentlyContinue | Measure-Object).Count -eq 0) {
        Remove-Item -LiteralPath $InstallRoot -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "[UNINSTALL] Complete for $InstallRoot"
