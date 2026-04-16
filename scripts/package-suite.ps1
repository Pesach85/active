[CmdletBinding()]
param(
    [string]$OutputDir = "C:\\dist\\WindowsOptimizer"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$items = @(
    "C:\\scripts\\monitor-resources.ps1",
    "C:\\scripts\\cleanup-storage-safe.ps1",
    "C:\\scripts\\install-monitor-task.ps1",
    "C:\\scripts\\install-cleanup-task.ps1",
    "C:\\scripts\\ensure-powershell-core.ps1",
    "C:\\scripts\\audit-disk-hotspots.ps1",
    "C:\\scripts\\analyze-garbage-hotspots.ps1",
    "C:\\scripts\\system-optimizer-gui.ps1",
    "C:\\scripts\\build-gui-exe.ps1",
    "C:\\scripts\\install-suite.ps1",
    "C:\\scripts\\uninstall-suite.ps1",
    "C:\\scripts\\run-gui.bat",
    "C:\\scripts\\run-install-suite.bat",
    "C:\\scripts\\run-uninstall-suite.bat",
    "C:\\scripts\\run-core-bootstrap.bat",
    "C:\\scripts\\run-disk-audit-safe.bat",
    "C:\\config\\sys-maintenance.json"
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

$exeSource = "C:\\dist\\WindowsOptimizer\\WindowsOptimizer.exe"
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
"@

Set-Content -LiteralPath (Join-Path $OutputDir "README.txt") -Value $readme -Encoding UTF8
Write-Host "Package ready at: $OutputDir"
