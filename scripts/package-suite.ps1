[CmdletBinding()]
param(
    [string]$OutputDir = "C:\\SystemOptimizerHub\\active\\dist\\WindowsOptimizer"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$hubRoot = Split-Path -Parent $scriptDir
$configDir = Join-Path $hubRoot "config"

$items = @(
    (Join-Path $scriptDir "monitor-resources.ps1"),
    (Join-Path $scriptDir "cleanup-storage-safe.ps1"),
    (Join-Path $scriptDir "quick-cleanup-safe.ps1"),
    (Join-Path $scriptDir "system-health-audit.ps1"),
    (Join-Path $scriptDir "apply-safe-fixes.ps1"),
    (Join-Path $scriptDir "repair-office-m365-channel.ps1"),
    (Join-Path $scriptDir "install-monitor-task.ps1"),
    (Join-Path $scriptDir "install-cleanup-task.ps1"),
    (Join-Path $scriptDir "ensure-powershell-core.ps1"),
    (Join-Path $scriptDir "audit-disk-hotspots.ps1"),
    (Join-Path $scriptDir "analyze-garbage-hotspots.ps1"),
    (Join-Path $scriptDir "analyze-compute-resources.ps1"),
    (Join-Path $scriptDir "system-optimizer-gui.ps1"),
    (Join-Path $scriptDir "build-gui-exe.ps1"),
    (Join-Path $scriptDir "install-suite.ps1"),
    (Join-Path $scriptDir "uninstall-suite.ps1"),
    (Join-Path $scriptDir "run-gui.bat"),
    (Join-Path $scriptDir "run-install-suite.bat"),
    (Join-Path $scriptDir "run-uninstall-suite.bat"),
    (Join-Path $scriptDir "run-core-bootstrap.bat"),
    (Join-Path $scriptDir "run-disk-audit-safe.bat"),
    (Join-Path $configDir "sys-maintenance.json")
)

if (-not (Test-Path -LiteralPath $OutputDir)) {
    New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
}

$targetScripts = Join-Path $OutputDir "scripts"
$targetConfig = Join-Path $OutputDir "config"
New-Item -Path $targetScripts -ItemType Directory -Force | Out-Null
New-Item -Path $targetConfig -ItemType Directory -Force | Out-Null

foreach ($item in $items) {
    if (Test-Path -LiteralPath $item) {
        if ($item -like "*\\config\\*") {
            Copy-Item -LiteralPath $item -Destination $targetConfig -Force
        } else {
            Copy-Item -LiteralPath $item -Destination $targetScripts -Force
        }
    }
}

$exeSource = Join-Path $hubRoot "dist\\WindowsOptimizer\\WindowsOptimizer.exe"
if (Test-Path -LiteralPath $exeSource) {
    $exeDestination = Join-Path $OutputDir "WindowsOptimizer.exe"
    $srcResolved = (Resolve-Path -LiteralPath $exeSource).ProviderPath
    $dstResolved = [System.IO.Path]::GetFullPath($exeDestination)
    if ($srcResolved -ine $dstResolved) {
        Copy-Item -LiteralPath $exeSource -Destination $exeDestination -Force
    }
}

$readme = @"
Windows Optimizer Suite

Install:
  powershell -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\install-suite.ps1

Uninstall:
  powershell -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\uninstall-suite.ps1

Build GUI EXE:
  powershell -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\build-gui-exe.ps1 -SourceScript .\\scripts\\system-optimizer-gui.ps1 -OutputExe .\\WindowsOptimizer.exe

Analyze Compute Resources:
    powershell -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\analyze-compute-resources.ps1 -DurationSec 8 -Top 8

Quick Cleanup (safe targets):
    powershell -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\quick-cleanup-safe.ps1 -Execute -RetentionDays 2 -MaxFilesPerTarget 2000
"@

Set-Content -LiteralPath (Join-Path $OutputDir "README.txt") -Value $readme -Encoding UTF8
Write-Host "Package ready at: $OutputDir"
