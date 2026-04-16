[CmdletBinding()]
param(
    [string]$SourceScript = "C:\\SystemOptimizerHub\\active\\scripts\\system-optimizer-gui.ps1",
    [string]$OutputExe = "C:\\SystemOptimizerHub\\active\\dist\\WindowsOptimizer\\WindowsOptimizer.exe"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $SourceScript)) {
    throw "Source script not found: $SourceScript"
}

$parent = Split-Path -Path $OutputExe -Parent
if (-not (Test-Path -LiteralPath $parent)) {
    New-Item -Path $parent -ItemType Directory -Force | Out-Null
}

if (-not (Get-Command Invoke-PS2EXE -ErrorAction SilentlyContinue)) {
    $moduleCacheRoot = "C:\\SystemOptimizerHub\\active\\scripts\\modules"
    if (-not (Test-Path -LiteralPath $moduleCacheRoot)) {
        New-Item -Path $moduleCacheRoot -ItemType Directory -Force | Out-Null
    }

    try {
        Save-Module -Name ps2exe -Path $moduleCacheRoot -Force -ErrorAction Stop
        $manifest = Get-ChildItem -LiteralPath $moduleCacheRoot -Filter ps2exe.psd1 -Recurse -ErrorAction Stop | Select-Object -First 1
        Import-Module -Name $manifest.FullName -Force -ErrorAction Stop
    } catch {
        Install-Module -Name ps2exe -Scope AllUsers -Force -AllowClobber -ErrorAction Stop
    }
}

if (-not (Get-Command Invoke-PS2EXE -ErrorAction SilentlyContinue)) {
    throw "Invoke-PS2EXE not available after module installation attempts."
}

Invoke-PS2EXE -InputFile $SourceScript -OutputFile $OutputExe -NoConsole -Title "Windows Optimizer Console" -Description "Windows optimization dashboard"
Write-Host "EXE generated: $OutputExe"
