#requires -RunAsAdministrator
<#
.SYNOPSIS
  PROPOSED (HITL): clear Kernel-WHEA/Errors with .evtx backup, then set circular retention.

.DESCRIPTION
  DESTRUCTIVE to the live channel contents (after backup). Requires -IConfirmBlindChannelRestore.
  Syntax from local help 2026-10-07:
    wevtutil cl <LOG> /bu:<backup.evtx>
    wevtutil sl <LOG> /rt:false /ms:<bytes>
  Current measured state (FASE1): retention=true, maxSize=8388608 → STRUMENTO CIECO.

.NOTES
  Do NOT run without explicit user confirmation. Run Export-* first.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$IConfirmBlindChannelRestore,
    [string]$ArtifactRoot = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'artifacts\whea-dualchannel-20261007\raw\events\channel-restore'),
    [string]$LogName = 'Microsoft-Windows-Kernel-WHEA/Errors',
    # 64 MiB — above current 8 MiB storm fill; min per help = 1048576
    [long]$MaxSizeBytes = 67108864,
    [ValidateSet('false')]
    [string]$RetentionCircular = 'false'
)

$ErrorActionPreference = 'Stop'
if (-not $IConfirmBlindChannelRestore) {
    throw @'
REFUSED: missing -IConfirmBlindChannelRestore.
This script clears the live Kernel-WHEA/Errors channel after backup and changes retention.
Obtain explicit user confirmation, run Export-KernelWheaErrorsChannel.ps1 first, then re-run with the switch.
'@
}

if ($MaxSizeBytes -lt 1048576) { throw "MaxSizeBytes must be >= 1048576 (wevtutil sl /?)" }

$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
New-Item -ItemType Directory -Force -Path $ArtifactRoot | Out-Null
$stateDir = Join-Path $ArtifactRoot "state_$ts"
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

$glBeforePath = Join-Path $stateDir 'gl_before.txt'
$glBefore = cmd /c "wevtutil gl `"$LogName`"" 2>&1 | Out-String
$glBefore | Set-Content -Encoding UTF8 $glBeforePath

$buClear = Join-Path $stateDir ("Kernel-WHEA-Errors_cl_backup_{0}.evtx" -f $ts)
$rollbackManifest = Join-Path $stateDir 'rollback_manifest.json'

Write-Host "WARNING: about to CLEAR $LogName after /bu backup"
Write-Host "Backup=$buClear MaxSize=$MaxSizeBytes Retention=/rt:$RetentionCircular"

if (-not $PSCmdlet.ShouldProcess($LogName, "cl /bu + sl /rt:$RetentionCircular /ms:$MaxSizeBytes")) {
    Write-Host 'ShouldProcess blocked — no changes.'
    return
}

# 1) Clear with backup (help: wevtutil cl <LOG> /bu:file.evtx)
cmd /c "wevtutil cl `"$LogName`" /bu:`"$buClear`""
if ($LASTEXITCODE -ne 0) { throw "wevtutil cl failed exit=$LASTEXITCODE" }
if (-not (Test-Path $buClear) -or (Get-Item $buClear).Length -le 0) {
    throw "Clear backup missing or empty: $buClear — STOP before sl"
}

# 2) Circular retention + larger max size
# help: /rt:false => incoming overwrite oldest; /ms:<n> bytes
cmd /c "wevtutil sl `"$LogName`" /rt:$RetentionCircular /ms:$MaxSizeBytes"
if ($LASTEXITCODE -ne 0) { throw "wevtutil sl failed exit=$LASTEXITCODE" }

$glAfter = cmd /c "wevtutil gl `"$LogName`"" 2>&1 | Out-String
$glAfter | Set-Content -Encoding UTF8 (Join-Path $stateDir 'gl_after.txt')

# Parse retention/maxSize from gl_after for manifest
$rtMatch = [regex]::Match($glAfter, 'retention:\s*(true|false)')
$msMatch = [regex]::Match($glAfter, 'maxSize:\s*(\d+)')

[ordered]@{
    Timestamp = (Get-Date).ToString('o')
    LogName = $LogName
    ClearBackupEvtx = $buClear
    GlBeforeFile = $glBeforePath
    GlAfterFile = (Join-Path $stateDir 'gl_after.txt')
    Applied = @{
        retention = $rtMatch.Groups[1].Value
        maxSize = $msMatch.Groups[1].Value
        commanded_rt = $RetentionCircular
        commanded_ms = $MaxSizeBytes
    }
    RollbackHint = 'Run Rollback-KernelWheaErrorsChannel.ps1 -ManifestPath <this file>'
    # Prior measured values for rollback of config (not event content)
    PriorConfig = @{
        retention = 'true'
        maxSize = 8388608
        source = 'FASE1 wevtutil gl 2026-10-07'
    }
} | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 $rollbackManifest

Write-Host "OK restore applied. Manifest=$rollbackManifest"
Write-Host "NEXT: run Validate-KernelWheaErrorsWritable.ps1 before any soak."
