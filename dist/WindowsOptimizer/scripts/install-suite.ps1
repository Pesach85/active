[CmdletBinding()]
param(
    [string]$InstallRoot = "C:\\SystemOptimizer",
    [string]$SourceRoot = "C:\\",
    [switch]$CoreInstallIfMissing
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptsSource = Join-Path $SourceRoot "scripts"
$configSource = Join-Path $SourceRoot "config"

if (-not (Test-Path -LiteralPath $scriptsSource)) {
    throw "Source scripts folder not found: $scriptsSource"
}

New-Item -Path $InstallRoot -ItemType Directory -Force | Out-Null
New-Item -Path (Join-Path $InstallRoot "scripts") -ItemType Directory -Force | Out-Null
New-Item -Path (Join-Path $InstallRoot "config") -ItemType Directory -Force | Out-Null
New-Item -Path (Join-Path $InstallRoot "logs") -ItemType Directory -Force | Out-Null

Copy-Item -LiteralPath (Join-Path $scriptsSource "*.ps1") -Destination (Join-Path $InstallRoot "scripts") -Force
if (Test-Path -LiteralPath (Join-Path $configSource "sys-maintenance.json")) {
    Copy-Item -LiteralPath (Join-Path $configSource "sys-maintenance.json") -Destination (Join-Path $InstallRoot "config") -Force
}

$ensureScript = Join-Path $InstallRoot "scripts\\ensure-powershell-core.ps1"
if (Test-Path -LiteralPath $ensureScript) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $ensureScript -InstallIfMissing:$CoreInstallIfMissing -ApplyTasksCoreOnly -MonitorInstallerPath (Join-Path $InstallRoot "scripts\\install-monitor-task.ps1") -CleanupInstallerPath (Join-Path $InstallRoot "scripts\\install-cleanup-task.ps1")
}

Write-Host "Suite installed in $InstallRoot"
