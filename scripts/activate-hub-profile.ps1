[CmdletBinding()]
param(
    [string]$HubRoot = "C:\\SystemOptimizerHub\\active",
    [switch]$InstallCoreIfMissing,
    [switch]$UpdateMachinePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptsDir = Join-Path $HubRoot "scripts"
$configDir = Join-Path $HubRoot "config"
$logsDir = Join-Path $HubRoot "logs"

$ensureCoreScript = Join-Path $scriptsDir "ensure-powershell-core.ps1"
$monitorInstaller = Join-Path $scriptsDir "install-monitor-task.ps1"
$cleanupInstaller = Join-Path $scriptsDir "install-cleanup-task.ps1"
$monitorScript = Join-Path $scriptsDir "monitor-resources.ps1"
$cleanupScript = Join-Path $scriptsDir "cleanup-storage-safe.ps1"
$configPath = Join-Path $configDir "sys-maintenance.json"

$required = @($ensureCoreScript, $monitorInstaller, $cleanupInstaller, $monitorScript, $cleanupScript, $configPath)
foreach ($path in $required) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Required file not found: $path"
    }
}

if (-not (Test-Path -LiteralPath $logsDir)) {
    New-Item -Path $logsDir -ItemType Directory -Force | Out-Null
}

$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$config.LogDirectory = $logsDir
$config | ConvertTo-Json -Depth 8 | Out-File -LiteralPath $configPath -Encoding utf8

$ensureArgs = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $ensureCoreScript,
    "-ApplyTasksCoreOnly",
    "-MonitorInstallerPath", $monitorInstaller,
    "-CleanupInstallerPath", $cleanupInstaller
)
if ($InstallCoreIfMissing.IsPresent) {
    $ensureArgs += "-InstallIfMissing"
}
if ($UpdateMachinePath.IsPresent) {
    $ensureArgs += "-UpdateMachinePath"
}

& powershell @ensureArgs

& powershell -NoProfile -ExecutionPolicy Bypass -File $monitorInstaller -TaskName "SystemResourceMonitor" -MonitorScriptPath $monitorScript -ConfigPath $configPath -RequireCore
& powershell -NoProfile -ExecutionPolicy Bypass -File $cleanupInstaller -TaskName "StorageCleanupSafe" -CleanupScriptPath $cleanupScript -RequireCore

Write-Host "Hub profile activated from $HubRoot"
Write-Host "Config: $configPath"
Write-Host "Logs: $logsDir"
