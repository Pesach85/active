# Resolve Android SDK/JDK from config/android-build.json (I_Tuoi_Versetti toolchain paths).
Set-StrictMode -Version Latest

function Get-AndroidBuildConfig {
    param([string]$HubRoot)

    $path = Join-Path $HubRoot 'config\android-build.json'
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Android build config not found: $path"
    }
    return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
}

function Expand-AndroidBuildPath {
    param([string]$Template)
    if (-not $Template) { return '' }
    return [Environment]::ExpandEnvironmentVariables($Template)
}

function Resolve-AndroidSdkDir {
    param([object]$Config)

    $candidates = @(
        $env:ANDROID_HOME,
        $env:ANDROID_SDK_ROOT,
        [string]$Config.SdkDir
    )
    foreach ($alt in @($Config.SdkDirAlternates)) {
        $candidates += (Expand-AndroidBuildPath -Template ([string]$alt))
    }
    $candidates += @(
        (Join-Path $env:LOCALAPPDATA 'Android\Sdk'),
        (Join-Path $env:USERPROFILE 'AppData\Local\Android\Sdk')
    )

    foreach ($raw in $candidates) {
        if (-not $raw) { continue }
        $expanded = Expand-AndroidBuildPath -Template $raw
        if (Test-Path -LiteralPath $expanded) { return $expanded }
    }
    return $null
}

function Resolve-AndroidJavaHome {
    param([object]$Config)

    if ($env:JAVA_HOME -and (Test-Path -LiteralPath (Join-Path $env:JAVA_HOME 'bin\java.exe'))) {
        return $env:JAVA_HOME
    }

    $candidates = @([string]$Config.JavaHome)
    foreach ($alt in @($Config.JavaHomeCandidates)) {
        $candidates += (Expand-AndroidBuildPath -Template ([string]$alt))
    }
    $candidates += @(
        'C:\Program Files\Android\Android Studio\jbr',
        'C:\Program Files\Java\jdk-17'
    )

    foreach ($raw in $candidates) {
        if (-not $raw) { continue }
        $expanded = Expand-AndroidBuildPath -Template $raw
        if (Test-Path -LiteralPath (Join-Path $expanded 'bin\java.exe')) {
            return $expanded
        }
    }
    return $null
}

function Set-AndroidBuildEnvironment {
    param(
        [string]$HubRoot,
        [string]$AndroidRoot
    )

    $config = Get-AndroidBuildConfig -HubRoot $HubRoot
    $sdkDir = Resolve-AndroidSdkDir -Config $config
    if (-not $sdkDir) {
        throw 'Android SDK not found. Configure config/android-build.json (see I_Tuoi_Versetti: D:\Android\Sdk).'
    }

    $javaHome = Resolve-AndroidJavaHome -Config $config
    if (-not $javaHome) {
        throw 'JDK 17 not found. Configure config/android-build.json (see I_Tuoi_Versetti: D:\JDK_17).'
    }

    $env:ANDROID_HOME = $sdkDir
    $env:ANDROID_SDK_ROOT = $sdkDir
    $env:JAVA_HOME = $javaHome
    $env:Path = (Join-Path $javaHome 'bin') + ';' + $env:Path

    $localProps = Join-Path $AndroidRoot 'local.properties'
    $escaped = $sdkDir -replace '\\', '\\\\'
    "sdk.dir=$escaped" | Out-File -LiteralPath $localProps -Encoding ascii -Force

    return [ordered]@{
        Config   = $config
        SdkDir   = $sdkDir
        JavaHome = $javaHome
    }
}
