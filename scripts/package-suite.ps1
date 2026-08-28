[CmdletBinding()]
param(
    [string]$OutputDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$hubRoot = Split-Path -Parent $scriptDir
$configDir = Join-Path $hubRoot "config"

if (-not $OutputDir -or $OutputDir.Trim() -eq "") {
    $OutputDir = Join-Path $hubRoot "dist\WindowsOptimizer"
}

$items = @(
    (Join-Path $scriptDir "hub-common.ps1"),
    (Join-Path $scriptDir "hub-orchestrator.ps1"),
    (Join-Path $scriptDir "fs-integrity.ps1"),
    (Join-Path $scriptDir "monitor-resources.ps1"),
    (Join-Path $scriptDir "cleanup-storage-safe.ps1"),
    (Join-Path $scriptDir "quick-cleanup-safe.ps1"),
    (Join-Path $scriptDir "system-health-audit.ps1"),
    (Join-Path $scriptDir "apply-safe-fixes.ps1"),
    (Join-Path $scriptDir "repair-office-m365-channel.ps1"),
    (Join-Path $scriptDir "repair-wsl-config.ps1"),
    (Join-Path $scriptDir "install-monitor-task.ps1"),
    (Join-Path $scriptDir "install-cleanup-task.ps1"),
    (Join-Path $scriptDir "ensure-powershell-core.ps1"),
    (Join-Path $scriptDir "audit-disk-hotspots.ps1"),
    (Join-Path $scriptDir "analyze-garbage-hotspots.ps1"),
    (Join-Path $scriptDir "analyze-compute-resources.ps1"),
    (Join-Path $scriptDir "analyze-process-pressure.ps1"),
    (Join-Path $scriptDir "apply-process-pressure-safe.ps1"),
    (Join-Path $scriptDir "evaluate-defender-extreme-necessity.ps1"),
    (Join-Path $scriptDir "apply-defender-extreme-necessity.ps1"),
    (Join-Path $scriptDir "restore-defender-from-rollback.ps1"),
    (Join-Path $scriptDir "lib\process-pressure-core.ps1"),
    (Join-Path $configDir "process-intelligence.json"),
    (Join-Path $scriptDir "analyze-nvme-readonly-plan.ps1"),
    (Join-Path $scriptDir "analyze-recovery-partition-legacy.ps1"),
    (Join-Path $scriptDir "privacy-scan-secrets.ps1"),
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
$targetLib = Join-Path $targetScripts "lib"
New-Item -Path $targetScripts -ItemType Directory -Force | Out-Null
New-Item -Path $targetLib -ItemType Directory -Force | Out-Null
New-Item -Path $targetConfig -ItemType Directory -Force | Out-Null

foreach ($item in $items) {
    if (Test-Path -LiteralPath $item) {
        if ($item -match '[\\/]config[\\/]') {
            Copy-Item -LiteralPath $item -Destination $targetConfig -Force
        } elseif ($item -match '[\\/]lib[\\/]') {
            Copy-Item -LiteralPath $item -Destination $targetLib -Force
        } else {
            Copy-Item -LiteralPath $item -Destination $targetScripts -Force
        }
    }
}

$guiSource = Join-Path $scriptDir "gui"
$guiTarget = Join-Path $targetScripts "gui"
if (Test-Path -LiteralPath $guiSource) {
    if (Test-Path -LiteralPath $guiTarget) {
        Remove-Item -LiteralPath $guiTarget -Recurse -Force -ErrorAction SilentlyContinue
    }
    Copy-Item -LiteralPath $guiSource -Destination $guiTarget -Recurse -Force
}

$localeSource = Join-Path $configDir "locale"
$localeTarget = Join-Path $targetConfig "locale"
if (Test-Path -LiteralPath $localeSource) {
    if (Test-Path -LiteralPath $localeTarget) {
        Remove-Item -LiteralPath $localeTarget -Recurse -Force -ErrorAction SilentlyContinue
    }
    Copy-Item -LiteralPath $localeSource -Destination $localeTarget -Recurse -Force
}

$catalogSource = Join-Path $configDir "command-catalog.json"
if (Test-Path -LiteralPath $catalogSource) {
    Copy-Item -LiteralPath $catalogSource -Destination $targetConfig -Force
}

# Force UTF-8 BOM on packaged PowerShell scripts for Windows PowerShell parsing compatibility.
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
Get-ChildItem -LiteralPath $targetScripts -Filter "*.ps1" -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        $raw = Get-Content -LiteralPath $_.FullName -Raw
        [System.IO.File]::WriteAllText($_.FullName, $raw, $utf8Bom)
    } catch {
        Write-Warning ("Skipping UTF-8 BOM normalization for locked file: {0}" -f $_.Exception.Message)
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

Analyze Compute Resources (legacy wrapper):
    powershell -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\analyze-compute-resources.ps1 -DurationSec 8 -Top 8

Process Pressure Intelligence (full report):
    powershell -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\analyze-process-pressure.ps1 -DurationSec 8 -Top 8 -IncludeResearch -OutputJson .\\logs\\process-pressure-latest.json

Apply safe auto-actions (audit-first):
    powershell -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\apply-process-pressure-safe.ps1 -InputJson .\\logs\\process-pressure-latest.json -OutputJson .\\logs\\process-pressure-apply.json -MaxLevel Safe

Quick Cleanup (safe targets):
    powershell -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\quick-cleanup-safe.ps1 -Execute -RetentionDays 2 -MaxFilesPerTarget 2000
"@

Set-Content -LiteralPath (Join-Path $OutputDir "README.txt") -Value $readme -Encoding UTF8
Write-Host "Package ready at: $OutputDir"
