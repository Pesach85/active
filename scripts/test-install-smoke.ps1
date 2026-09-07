[CmdletBinding()]
param(
    [string]$HubRoot = '',
    [switch]$BuildApk,
    [switch]$DeviceSmoke
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $HubRoot) { $HubRoot = Split-Path -Parent $scriptDir }

$failures = [System.Collections.Generic.List[string]]::new()

function Assert-Test {
    param([string]$Name, [scriptblock]$Block)
    try {
        & $Block
        Write-Host "[INSTALL-SMOKE] $Name OK"
    } catch {
        $failures.Add("${Name}: $($_.Exception.Message)")
        Write-Host "[INSTALL-SMOKE] $Name FAIL: $($_.Exception.Message)"
    }
}

Assert-Test 'install-profile.json' {
    $p = Join-Path $HubRoot 'config\install-profile.json'
    if (-not (Test-Path -LiteralPath $p)) { throw 'missing' }
    $j = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
    if ([string]$j.SchemaVersion -notmatch 'InstallProfile') { throw 'schema' }
}

Assert-Test 'windows-app-install lib' {
    . (Join-Path $scriptDir 'lib\windows-app-install.ps1')
    $prof = Get-InstallProfile -HubRoot $HubRoot
    if (-not $prof.Windows.StartMenuFolder) { throw 'StartMenuFolder missing' }
}

Assert-Test 'launch bats in scripts' {
    foreach ($b in @('Launch-Hub.bat', 'Launch-Transparency-Web.bat')) {
        if (-not (Test-Path -LiteralPath (Join-Path $scriptDir $b))) { throw "$b missing" }
    }
}

Assert-Test 'linux install scripts' {
    $linux = Join-Path $scriptDir 'linux'
    foreach ($f in @('install-linux-suite.sh', 'uninstall-linux-suite.sh', 'hub-linux-common.sh')) {
        if (-not (Test-Path -LiteralPath (Join-Path $linux $f))) { throw "$f missing" }
    }
}

Assert-Test 'android project skeleton' {
    $manifest = Join-Path $HubRoot 'mobile\android\app\src\main\AndroidManifest.xml'
    if (-not (Test-Path -LiteralPath $manifest)) { throw 'AndroidManifest missing' }
    $engine = Join-Path $HubRoot 'mobile\android\app\src\main\java\com\systemoptimizerhub\transparency\DeviceMaintenanceEngine.kt'
    if (-not (Test-Path -LiteralPath $engine)) { throw 'DeviceMaintenanceEngine.kt missing' }
}

Assert-Test 'android-build config (I_Tuoi_Versetti paths)' {
    $cfgPath = Join-Path $HubRoot 'config\android-build.json'
    if (-not (Test-Path -LiteralPath $cfgPath)) { throw 'android-build.json missing' }
    . (Join-Path $scriptDir 'lib\android-build-config.ps1')
    $cfg = Get-AndroidBuildConfig -HubRoot $HubRoot
    $sdk = Resolve-AndroidSdkDir -Config $cfg
    if (-not $sdk) { throw "SDK not found (expected $($cfg.SdkDir))" }
    $jdk = Resolve-AndroidJavaHome -Config $cfg
    if (-not $jdk) { throw "JDK not found (expected $($cfg.JavaHome))" }
}

Assert-Test 'package-suite includes install-profile' {
    $content = Get-Content -LiteralPath (Join-Path $scriptDir 'package-suite.ps1') -Raw
    if ($content -notmatch 'install-profile.json') { throw 'package-suite missing install-profile' }
    if ($content -notmatch 'install-windows-app.ps1') { throw 'package-suite missing install-windows-app' }
}

Assert-Test 'dev-sync dry package' {
    & (Join-Path $scriptDir 'package-suite.ps1') -OutputDir (Join-Path $HubRoot 'dist\WindowsOptimizer') | Out-Null
    $launch = Join-Path $HubRoot 'dist\WindowsOptimizer\Launch-Hub.bat'
    if (-not (Test-Path -LiteralPath $launch)) { throw 'Launch-Hub.bat not in dist' }
}

if ($BuildApk) {
    Assert-Test 'android apk build' {
        & (Join-Path $scriptDir 'build-android-apk.ps1') -HubRoot $HubRoot -Variant debug | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "build-android-apk exit=$LASTEXITCODE" }
        $apk = Join-Path $HubRoot 'dist\android\SystemOptimizerHub-android-debug.apk'
        if (-not (Test-Path -LiteralPath $apk)) { throw 'APK output missing' }
    }
}

if ($DeviceSmoke) {
    Assert-Test 'android device smoke' {
        & (Join-Path $scriptDir 'test-android-device-smoke.ps1') -HubRoot $HubRoot | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "test-android-device-smoke exit=$LASTEXITCODE" }
    }
}

if ($failures.Count -gt 0) {
    Write-Host '[INSTALL-SMOKE] FAILED'
    $failures | ForEach-Object { Write-Host "  - $_" }
    exit 1
}

Write-Host '[INSTALL-SMOKE] ALL PASSED'
exit 0
