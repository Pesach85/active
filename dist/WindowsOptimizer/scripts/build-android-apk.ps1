[CmdletBinding()]
param(
    [string]$HubRoot = '',
    [ValidateSet('debug', 'release')]
    [string]$Variant = 'debug',
    [string]$OutputApk = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $HubRoot) { $HubRoot = Split-Path -Parent $scriptDir }
$androidRoot = Join-Path $HubRoot 'mobile\android'

if (-not (Test-Path -LiteralPath $androidRoot)) {
    throw "Android project not found: $androidRoot"
}

. (Join-Path $scriptDir 'lib\android-build-config.ps1')
$envInfo = Set-AndroidBuildEnvironment -HubRoot $HubRoot -AndroidRoot $androidRoot
Write-Host "[ANDROID] SDK=$($envInfo.SdkDir)"
Write-Host "[ANDROID] JAVA_HOME=$($envInfo.JavaHome)"

$gradlew = Join-Path $androidRoot 'gradlew.bat'
if (-not (Test-Path -LiteralPath $gradlew)) {
    throw 'gradlew.bat missing under mobile/android'
}

Push-Location $androidRoot
try {
    $task = if ($Variant -eq 'release') { 'assembleRelease' } else { 'assembleDebug' }
    & $gradlew $task --no-daemon --stacktrace
    if ($LASTEXITCODE -ne 0) { throw "Gradle $task failed exit=$LASTEXITCODE" }

    $apkDir = Join-Path $androidRoot "app\build\outputs\apk\$Variant"
    $apk = Get-ChildItem -LiteralPath $apkDir -Filter '*.apk' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $apk) { throw "APK not found under $apkDir" }

    if (-not $OutputApk) {
        $outDir = Join-Path $HubRoot 'dist\android'
        New-Item -Path $outDir -ItemType Directory -Force | Out-Null
        $OutputApk = Join-Path $outDir "SystemOptimizerHub-transparency-$Variant.apk"
    }
    Copy-Item -LiteralPath $apk.FullName -Destination $OutputApk -Force
    Write-Host "[ANDROID] APK: $OutputApk"
}
finally {
    Pop-Location
}
