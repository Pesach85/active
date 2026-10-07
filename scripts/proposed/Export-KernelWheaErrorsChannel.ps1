#requires -RunAsAdministrator
<#
.SYNOPSIS
  PROPOSED (HITL): export Microsoft-Windows-Kernel-WHEA/Errors to timestamped .evtx.

.DESCRIPTION
  Read-ish operation on the log (export only). Does NOT clear or reconfigure the channel.
  Syntax verified via `wevtutil epl /?` on HOST-REDACTED 2026-10-07.

.NOTES
  Do not run until the user explicitly confirms FASE 1b apply.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ArtifactRoot = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'artifacts\whea-dualchannel-20261007\raw\events\channel-restore'),
    [string]$LogName = 'Microsoft-Windows-Kernel-WHEA/Errors'
)

$ErrorActionPreference = 'Stop'
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
New-Item -ItemType Directory -Force -Path $ArtifactRoot | Out-Null
$dest = Join-Path $ArtifactRoot ("Kernel-WHEA-Errors_export_{0}.evtx" -f $ts)
$meta = Join-Path $ArtifactRoot ("Kernel-WHEA-Errors_export_{0}.json" -f $ts)

Write-Host "PROPOSED EXPORT — LogName=$LogName"
Write-Host "Destination=$dest"

# Capture pre-state (read-only)
$glOut = cmd /c "wevtutil gl `"$LogName`"" 2>&1 | Out-String
$glOut | Set-Content -Encoding UTF8 (Join-Path $ArtifactRoot ("gl_before_export_{0}.txt" -f $ts))

if (-not $PSCmdlet.ShouldProcess($LogName, "wevtutil epl export to $dest")) {
    Write-Host 'WhatIf/ShouldProcess blocked — no export performed.'
    return
}

cmd /c "wevtutil epl `"$LogName`" `"$dest`" /ow:true"
if ($LASTEXITCODE -ne 0) { throw "wevtutil epl failed exit=$LASTEXITCODE" }

$item = Get-Item $dest
if ($item.Length -le 0) { throw "Export file empty: $dest" }

[ordered]@{
    Timestamp = (Get-Date).ToString('o')
    LogName = $LogName
    ExportEvtx = $dest
    Bytes = $item.Length
    Command = "wevtutil epl `"$LogName`" `"$dest`" /ow:true"
    GlBefore = $glOut
} | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 $meta

Write-Host "OK export bytes=$($item.Length) meta=$meta"
