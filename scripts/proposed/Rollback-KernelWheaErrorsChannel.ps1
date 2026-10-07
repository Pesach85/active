#requires -RunAsAdministrator
<#
.SYNOPSIS
  PROPOSED (HITL): restore prior Kernel-WHEA/Errors logging config from manifest.

.DESCRIPTION
  Restores retention/maxSize recorded in the restore manifest (default: retention=true, maxSize=8388608).
  Does NOT re-import historical events into the live channel (EVTX backups remain on disk for offline analysis).
  To inspect old storms: open the .evtx backup in Event Viewer / wevtutil qe /lf:true.

.NOTES
  Re-importing millions of ID20 into a live circular log is intentionally NOT automated.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$ManifestPath,
    [switch]$IConfirmRollbackChannelConfig
)

$ErrorActionPreference = 'Stop'
if (-not $IConfirmRollbackChannelConfig) {
    throw 'REFUSED: missing -IConfirmRollbackChannelConfig. Explicit HITL required.'
}
if (-not (Test-Path $ManifestPath)) { throw "Manifest not found: $ManifestPath" }

$m = Get-Content $ManifestPath -Raw | ConvertFrom-Json
$LogName = $m.LogName
$rt = $m.PriorConfig.retention
$ms = [long]$m.PriorConfig.maxSize

Write-Host "Rollback config for $LogName -> retention=$rt maxSize=$ms"
Write-Host "Event content rollback = NOT PERFORMED (use ClearBackupEvtx offline): $($m.ClearBackupEvtx)"

if (-not $PSCmdlet.ShouldProcess($LogName, "wevtutil sl /rt:$rt /ms:$ms")) {
    return
}

cmd /c "wevtutil sl `"$LogName`" /rt:$rt /ms:$ms"
if ($LASTEXITCODE -ne 0) { throw "wevtutil sl rollback failed exit=$LASTEXITCODE" }

$gl = cmd /c "wevtutil gl `"$LogName`"" 2>&1 | Out-String
$out = Join-Path (Split-Path $ManifestPath -Parent) ('gl_after_rollback_{0}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$gl | Set-Content -Encoding UTF8 $out
Write-Host "OK config rolled back. gl=$out"
Write-Host "NOTE: channel is again Retain@8MiB if prior values restored — STRUMENTO CIECO risk returns."
