<#
.SYNOPSIS
    Audit (and optionally repair) leftover startup entries from old hub installs.

.DESCRIPTION
    Scans scheduled tasks, Run/RunOnce registry keys, and Startup folders for:
      - paths under known legacy hub roots (C:\SystemOptimizerHub, C:\SystemOptimizer)
      - hub fingerprints whose -File target no longer exists
      - one-shot campaign tasks (NVMe-WriteOffload-PostBootVerify) left enabled at every boot

    Safe apply:
      - Unregister stale one-shot / broken hub tasks
      - Retarget persistent suite tasks (monitor, cleanup, orchestrator) via official installers
      - Remove hub Run keys / shortcuts whose target is gone
    Never auto-removes vendor Run keys (Adobe, VMware, Sophos, Defender, ...).

.PARAMETER OutputJson
    JSON report path (StartupIntegrityReport.v1). Defaults to logs/startup-integrity-latest.json.

.PARAMETER Apply
    Apply Safe repairs after audit. Writes rollback JSON under logs/diagnostics.

.PARAMETER RestoreLatest
    Restore the latest startup-integrity backup (re-register exported task XML / Run values).

.PARAMETER MaxLevel
    Safe (default) or Moderate (same actions today; reserved for future vendor-missing cleanup).
#>
[CmdletBinding()]
param(
    [string]$OutputJson = '',
    [string]$HubRoot = '',
    [switch]$Apply,
    [switch]$RestoreLatest,
    [ValidateSet('Safe', 'Moderate')][string]$MaxLevel = 'Safe',
    [string]$BackupDirectory = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$hubCommon = Join-Path $scriptDir 'hub-common.ps1'
if (Test-Path -LiteralPath $hubCommon) { . $hubCommon }

$lib = Join-Path $scriptDir 'lib\startup-integrity.ps1'
if (-not (Test-Path -LiteralPath $lib)) { throw "Missing library: $lib" }
. $lib

if ([string]::IsNullOrWhiteSpace($HubRoot)) {
    if (Get-Command Get-HubRoot -ErrorAction SilentlyContinue) { $HubRoot = Get-HubRoot }
    else { $HubRoot = Split-Path $scriptDir -Parent }
}

$paths = $null
if (Get-Command Get-HubPaths -ErrorAction SilentlyContinue) {
    $paths = Get-HubPaths -HubRoot $HubRoot
}
$logsDir = if ($paths) { $paths.Logs } else { Join-Path $HubRoot 'logs' }
$diagDir = if ($paths) { $paths.Diagnostics } else { Join-Path $logsDir 'diagnostics' }
if ([string]::IsNullOrWhiteSpace($BackupDirectory)) { $BackupDirectory = $diagDir }
if ([string]::IsNullOrWhiteSpace($OutputJson)) {
    $OutputJson = Join-Path $logsDir 'startup-integrity-latest.json'
}

if ($RestoreLatest) {
    if (Get-Command Assert-HubAdmin -ErrorAction SilentlyContinue) {
        Assert-HubAdmin -ActionName 'startup-integrity restore'
    }
    $restored = Restore-StartupIntegrityLatest -BackupDirectory $BackupDirectory
    $restored | ConvertTo-Json -Depth 6
    return
}

$report = Get-StartupIntegrityReport -HubRoot $HubRoot

if ($Apply) {
    if (Get-Command Assert-HubAdmin -ErrorAction SilentlyContinue) {
        Assert-HubAdmin -ActionName 'startup-integrity apply'
    }
    $result = Invoke-StartupIntegrityApply -Report $report -BackupDirectory $BackupDirectory -MaxLevel $MaxLevel
    $report.Apply = $result
    $report.Summary.BestNextDecision = if ($result.AppliedCount -gt 0) {
        'Repairs applied. Reboot to confirm no leftover PowerShell -File dialogs. Rollback: audit-startup-integrity.ps1 -RestoreLatest'
    } else {
        'Apply ran but no Safe actions were taken.'
    }
}

$outDir = Split-Path -Parent $OutputJson
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}
$json = $report | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($OutputJson, $json, [System.Text.Encoding]::UTF8)
Write-Host ("Startup integrity: needsRepair={0} oneShot={1} relocatable={2} broken={3} report={4}" -f `
    $report.Summary.NeedsRepair, $report.Summary.HubOneShotStale, $report.Summary.HubRelocatable, $report.Summary.HubBroken, $OutputJson)
if ($report.Summary.NeedsRepair -gt 0 -and -not $Apply) {
    Write-Host 'Best next: pwsh -File scripts\audit-startup-integrity.ps1 -Apply'
}
