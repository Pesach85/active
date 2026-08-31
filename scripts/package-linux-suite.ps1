[CmdletBinding()]
param(
    [string]$OutputDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$hubRoot = Split-Path -Parent $scriptDir
$configDir = Join-Path $hubRoot 'config'
$linuxDir = Join-Path $scriptDir 'linux'

if (-not $OutputDir -or $OutputDir.Trim() -eq '') {
    $OutputDir = Join-Path $hubRoot 'dist\LinuxOptimizer'
}

$targetScripts = Join-Path $OutputDir 'scripts'
$targetConfig = Join-Path $OutputDir 'config'
New-Item -Path $targetScripts -ItemType Directory -Force | Out-Null
New-Item -Path (Join-Path $targetScripts 'linux') -ItemType Directory -Force | Out-Null
New-Item -Path $targetConfig -ItemType Directory -Force | Out-Null

$items = @(
    (Join-Path $linuxDir 'analyze-process-pressure.sh'),
    (Join-Path $linuxDir 'apply-process-pressure-safe.sh'),
    (Join-Path $linuxDir 'VERSION'),
    (Join-Path $configDir 'process-intelligence.json')
)

foreach ($item in $items) {
    if (-not (Test-Path -LiteralPath $item)) {
        Write-Warning "Missing: $item"
        continue
    }
    if ($item -match '[\\/]config[\\/]') {
        Copy-Item -LiteralPath $item -Destination $targetConfig -Force
    } else {
        Copy-Item -LiteralPath $item -Destination (Join-Path $targetScripts 'linux') -Force
    }
}

$readme = @"
Linux Optimizer — Process Pressure Intelligence (v0.2.0)

Hub Core migration preview: shared catalog with Windows; bash PPI until hub CLI parity (ADR-0007).

Analyze top CPU/RAM/IO processes (deterministic two-snapshot scoring):

  chmod +x scripts/linux/analyze-process-pressure.sh
  ./scripts/linux/analyze-process-pressure.sh 6 8 /tmp/process-pressure.json

Arguments: DURATION_SEC TOP OUTPUT_JSON [CATALOG_PATH]

Catalog: config/process-intelligence.json (shared knowledge base with Windows build).

Safe apply on Linux (renice, reversible):

  chmod +x scripts/linux/apply-process-pressure-safe.sh
  ./scripts/linux/apply-process-pressure-safe.sh /tmp/process-pressure.json /tmp/apply.json

Cross-platform CLI (preview, requires .NET 9):

  dotnet run --project /path/to/active/src/SystemOptimizerHub.Cli -- catalog classify --name chrome
  dotnet publish src/SystemOptimizerHub.Cli -c Release -r linux-x64 --self-contained -p:PublishSingleFile=true
"@

Set-Content -LiteralPath (Join-Path $OutputDir 'README.txt') -Value $readme -Encoding UTF8
Write-Host "Linux package ready at: $OutputDir"
