[CmdletBinding()]
param(
    [string]$OutputDir,
    [ValidateSet('linux-x64', 'linux-arm64')]
    [string]$Runtime = 'linux-x64'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$hubRoot = Split-Path -Parent $scriptDir
$configDir = Join-Path $hubRoot 'config'
$linuxDir = Join-Path $scriptDir 'linux'
$cliProject = Join-Path $hubRoot 'src\SystemOptimizerHub.Cli\SystemOptimizerHub.Cli.csproj'

if (-not $OutputDir -or $OutputDir.Trim() -eq '') {
    $OutputDir = Join-Path $hubRoot 'dist\LinuxOptimizer'
}

$targetScripts = Join-Path $OutputDir 'scripts\linux'
$targetConfig = Join-Path $OutputDir 'config'
$targetBin = Join-Path $OutputDir 'bin'
New-Item -Path $targetScripts -ItemType Directory -Force | Out-Null
New-Item -Path $targetConfig -ItemType Directory -Force | Out-Null
New-Item -Path $targetBin -ItemType Directory -Force | Out-Null

Get-ChildItem -LiteralPath $linuxDir -File | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $targetScripts -Force
}

$configs = @('process-intelligence.json', 'install-profile.json', 'sys-maintenance.json')
foreach ($cfg in $configs) {
    $src = Join-Path $configDir $cfg
    if (Test-Path -LiteralPath $src) {
        Copy-Item -LiteralPath $src -Destination $targetConfig -Force
    }
}

if (Test-Path -LiteralPath $cliProject) {
    Write-Host "Publishing hub CLI ($Runtime)..."
    dotnet publish $cliProject -c Release -r $Runtime --self-contained true `
        -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true `
        -o $targetBin -v q --nologo
    if ($LASTEXITCODE -ne 0) { throw 'dotnet publish linux hub failed' }
    $published = Join-Path $targetBin 'SystemOptimizerHub.Cli'
    if (Test-Path -LiteralPath $published) {
        Move-Item -LiteralPath $published -Destination (Join-Path $targetBin 'hub') -Force
    }
}

$version = Get-Content -LiteralPath (Join-Path $linuxDir 'VERSION') -Raw
$readme = @"
Linux Optimizer Hub ($($version.Trim()))

Install (user scope, no root):
  chmod +x scripts/linux/install-linux-suite.sh
  ./scripts/linux/install-linux-suite.sh

Uninstall:
  ./scripts/linux/uninstall-linux-suite.sh

CLI (after install):
  hub version
  hub analyze pressure --duration 6 --top 8
  hub network deep-scan --catalog config/process-intelligence.json

PPI bash (offline):
  ./scripts/linux/analyze-process-pressure.sh 6 8 /tmp/process-pressure.json
  ./scripts/linux/apply-process-pressure-safe.sh /tmp/process-pressure.json /tmp/apply.json

Systemd user timer: systemoptimizerhub-orchestrator.timer (optional, install script enables)
"@

Set-Content -LiteralPath (Join-Path $OutputDir 'README.txt') -Value $readme -Encoding UTF8
Write-Host "Linux package ready at: $OutputDir"
