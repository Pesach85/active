[CmdletBinding()]
param(
    [string]$HubRoot = ''
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
    $gradle = Join-Path $HubRoot 'mobile\android\app\build.gradle.kts'
    if (-not (Test-Path -LiteralPath $gradle)) { throw 'build.gradle.kts missing' }
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

if ($failures.Count -gt 0) {
    Write-Host '[INSTALL-SMOKE] FAILED'
    $failures | ForEach-Object { Write-Host "  - $_" }
    exit 1
}

Write-Host '[INSTALL-SMOKE] ALL PASSED'
exit 0
