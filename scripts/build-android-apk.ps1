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

$javaHome = $env:JAVA_HOME
if (-not $javaHome -or -not (Test-Path -LiteralPath $javaHome)) {
    $candidates = @(
        'C:\Program Files\Android\Android Studio\jbr',
        'C:\Program Files\Java\jdk-17',
        'C:\Program Files\Eclipse Adoptium\jdk-17*'
    )
    foreach ($c in $candidates) {
        $resolved = Get-Item -Path $c -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($resolved) { $env:JAVA_HOME = $resolved.FullName; break }
    }
}

$gradlew = Join-Path $androidRoot 'gradlew.bat'
if (-not (Test-Path -LiteralPath $gradlew)) {
    Write-Host '[ANDROID] gradlew.bat missing - generate with Android Studio or: gradle wrapper'
    Write-Host '[ANDROID] Project validated at mobile/android (build requires Android SDK + JDK 17).'
    exit 2
}

$sdkCandidates = @(
    $env:ANDROID_HOME,
    $env:ANDROID_SDK_ROOT,
    (Join-Path $env:LOCALAPPDATA 'Android\Sdk'),
    (Join-Path $env:USERPROFILE 'AppData\Local\Android\Sdk')
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1

$localProps = Join-Path $androidRoot 'local.properties'
if ($sdkCandidates -and -not (Test-Path -LiteralPath $localProps)) {
    $sdkLine = ($sdkCandidates -replace '\\', '/')
    "sdk.dir=$sdkLine" | Out-File -LiteralPath $localProps -Encoding ascii -Force
    Write-Host "[ANDROID] Wrote local.properties sdk.dir=$sdkCandidates"
}
elseif (-not (Test-Path -LiteralPath $localProps)) {
    Write-Host '[ANDROID] No Android SDK found. Install Android Studio or copy mobile/android/local.properties.example to local.properties'
    exit 2
}

Push-Location $androidRoot
try {
    $task = if ($Variant -eq 'release') { 'assembleRelease' } else { 'assembleDebug' }
    & $gradlew $task --no-daemon
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
