[CmdletBinding()]
param(
    [string]$HubRoot = '',
    [string]$ApkPath = '',
    [string]$DeviceSerial = '',
    [switch]$Launch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $HubRoot) { $HubRoot = Split-Path -Parent $scriptDir }

. (Join-Path $scriptDir 'lib\android-build-config.ps1')

$cfg = Get-AndroidBuildConfig -HubRoot $HubRoot
$adb = Join-Path (Resolve-AndroidSdkDir -Config $cfg) 'platform-tools\adb.exe'
if (-not $ApkPath) {
    $ApkPath = Join-Path $HubRoot 'dist\android\SystemOptimizerHub-android-debug.apk'
}

if (-not (Test-Path -LiteralPath $ApkPath)) {
    & (Join-Path $scriptDir 'build-android-apk.ps1') -HubRoot $HubRoot -Variant debug | Out-Host
}

$serialArg = @()
if ($DeviceSerial) { $serialArg = @('-s', $DeviceSerial) }

$installArgs = @('install', '-r', $ApkPath)
& $adb @serialArg @installArgs
if ($LASTEXITCODE -ne 0) { throw "adb install failed exit=$LASTEXITCODE" }

Write-Host "[ANDROID-INSTALL] APK installed: $ApkPath"

if ($Launch) {
    & $adb @serialArg shell am start -n com.systemoptimizerhub.transparency/.MainActivity | Out-Host
}
