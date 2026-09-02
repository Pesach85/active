[CmdletBinding()]
param(
    [string]$HubRoot = '',
    [string]$ApkPath = '',
    [string]$DeviceSerial = '',
    [switch]$SkipInstall,
    [switch]$SkipLaunch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $HubRoot) { $HubRoot = Split-Path -Parent $scriptDir }

. (Join-Path $scriptDir 'lib\android-build-config.ps1')

$failures = [System.Collections.Generic.List[string]]::new()

function Assert-DeviceTest {
    param([string]$Name, [scriptblock]$Block)
    try {
        & $Block
        Write-Host "[ANDROID-DEVICE] $Name OK"
    } catch {
        $failures.Add("${Name}: $($_.Exception.Message)")
        Write-Host "[ANDROID-DEVICE] $Name FAIL: $($_.Exception.Message)"
    }
}

function Get-AdbPath {
    $cfg = Get-AndroidBuildConfig -HubRoot $HubRoot
    $sdk = Resolve-AndroidSdkDir -Config $cfg
    if (-not $sdk) { throw 'Android SDK not found' }
    return Join-Path $sdk 'platform-tools\adb.exe'
}

function Invoke-AdbCommand {
    param([string]$Adb, [string[]]$Command, [string]$Serial = '')
    $all = @()
    if ($Serial) { $all += '-s', $Serial }
    $all += $Command
    $out = & $Adb @all 2>&1
    $text = ($out | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        if ($text) { throw $text }
        throw "adb failed exit=$LASTEXITCODE args=$($Command -join ' ')"
    }
    return $text
}

$adb = Get-AdbPath
if (-not $ApkPath) {
    $ApkPath = Join-Path $HubRoot 'dist\android\SystemOptimizerHub-android-debug.apk'
}

Assert-DeviceTest 'adb device connected' {
    $state = Invoke-AdbCommand -Adb $adb -Command @('get-state') -Serial $DeviceSerial
    if ($state -ne 'device') { throw "adb state=$state" }
    $list = Invoke-AdbCommand -Adb $adb -Command @('devices') -Serial $DeviceSerial
    if ($list -notmatch '(?m)^\S+\s+device\s*$') { throw 'No device in state device' }
}

Assert-DeviceTest 'native engine source present' {
    $engine = Join-Path $HubRoot 'mobile\android\app\src\main\java\com\systemoptimizerhub\transparency\DeviceMaintenanceEngine.kt'
    if (-not (Test-Path -LiteralPath $engine)) { throw 'DeviceMaintenanceEngine.kt missing' }
    $content = Get-Content -LiteralPath $engine -Raw
    if ($content -match '127\.0\.0\.1:8765|WebView') { throw 'WebView/PC remote code still present in engine' }
}

if (-not $SkipInstall) {
    Assert-DeviceTest 'apk install' {
        if (-not (Test-Path -LiteralPath $ApkPath)) {
            & (Join-Path $scriptDir 'build-android-apk.ps1') -HubRoot $HubRoot -Variant debug | Out-Host
        }
        $out = Invoke-AdbCommand -Adb $adb -Command @('install', '-r', $ApkPath) -Serial $DeviceSerial
        if ($out -notmatch 'Success') { throw $out }
    }
}

Assert-DeviceTest 'package version 0.9.x' {
    $ver = Invoke-AdbCommand -Adb $adb -Command @(
        'shell', 'dumpsys', 'package', 'com.systemoptimizerhub.transparency'
    ) -Serial $DeviceSerial
    if ($ver -notmatch 'versionName=0\.9') { throw 'Expected native v0.9.x on device' }
}

if (-not $SkipLaunch) {
    Assert-DeviceTest 'launch MainActivity' {
        $out = Invoke-AdbCommand -Adb $adb -Command @(
            'shell', 'am', 'start', '-W', '-n', 'com.systemoptimizerhub.transparency/.MainActivity'
        ) -Serial $DeviceSerial
        if ($out -notmatch 'Complete|Already') { throw $out }
    }

    Assert-DeviceTest 'native dashboard foreground' {
        Start-Sleep -Seconds 5
        $dump = Invoke-AdbCommand -Adb $adb -Command @('shell', 'dumpsys', 'activity', 'activities') -Serial $DeviceSerial
        if ($dump -notmatch 'topResumedActivity=.*com\.systemoptimizerhub\.transparency') {
            throw 'App not top resumed'
        }
    }

    Assert-DeviceTest 'UI shows device maintenance (logcat)' {
        Start-Sleep -Seconds 2
        $log = Invoke-AdbCommand -Adb $adb -Command @('logcat', '-d', '-t', '200') -Serial $DeviceSerial
        if ($log -match 'AndroidRuntime.*FATAL EXCEPTION.*com\.systemoptimizerhub\.transparency') {
            throw 'FATAL crash in app'
        }
    }

    Assert-DeviceTest 'no WebView PC dashboard dependency' {
        $log = Invoke-AdbCommand -Adb $adb -Command @('logcat', '-d', '-t', '300') -Serial $DeviceSerial
        if ($log -match 'ERR_CONNECTION|8765.*refused|net::ERR') {
            throw 'WebView connection errors — app may still depend on PC dashboard'
        }
    }
}

if ($failures.Count -gt 0) {
    Write-Host '[ANDROID-DEVICE] FAILED'
    $failures | ForEach-Object { Write-Host "  - $_" }
    exit 1
}

Write-Host '[ANDROID-DEVICE] ALL PASSED (native on-device maintenance)'
exit 0
