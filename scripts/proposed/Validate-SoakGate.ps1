#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Soak gate: Circular Kernel-WHEA/Errors + HWiNFO CSV active. Both required.

.DESCRIPTION
  If either check fails, SoakAllowed=$false (exit 2). Does not touch BCD.
  Restore time file (optional) is reported as soak window start reference.
#>
[CmdletBinding()]
param(
    [string]$Channel = 'Microsoft-Windows-Kernel-WHEA/Errors',
    [long]$MinMaxSizeBytes = 67108864,
    [string]$HwinfoCsvPath = '',
    [string]$HwinfoCsvDir = '',
    [int]$HwinfoMaxAgeMinutes = 15,
    [string]$RestoreTimeFile = '',
    [string]$OutJson = ''
)

$ErrorActionPreference = 'Stop'

$log = Get-WinEvent -ListLog $Channel
$circularOk = ($log.LogMode -eq 'Circular') -and $log.IsEnabled -and ($log.MaximumSizeInBytes -ge ($MinMaxSizeBytes - 65536))

# Resolve newest HWiNFO CSV
$csv = $null
if ($HwinfoCsvPath) {
    if (Test-Path -LiteralPath $HwinfoCsvPath) { $csv = Get-Item -LiteralPath $HwinfoCsvPath }
}
elseif ($HwinfoCsvDir) {
    $csv = Get-ChildItem -LiteralPath $HwinfoCsvDir -Filter '*.csv' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

$hwinfoOk = $false
$hwinfoReason = 'NO_CSV'
if ($csv) {
    $ageMin = ((Get-Date) - $csv.LastWriteTime).TotalMinutes
    if ($csv.Length -le 0) {
        $hwinfoReason = 'CSV_EMPTY'
    }
    elseif ($ageMin -gt $HwinfoMaxAgeMinutes) {
        $hwinfoReason = "CSV_STALE ageMin=$([math]::Round($ageMin,1)) > $HwinfoMaxAgeMinutes (logging non attivo)"
    }
    else {
        $hwinfoOk = $true
        $hwinfoReason = "CSV_ACTIVE path=$($csv.FullName) ageMin=$([math]::Round($ageMin,1))"
    }
}

$restoreTime = $null
if ($RestoreTimeFile -and (Test-Path -LiteralPath $RestoreTimeFile)) {
    $restoreTime = (Get-Content -LiteralPath $RestoreTimeFile -Raw).Trim()
}

$soakAllowed = $circularOk -and $hwinfoOk
$result = [ordered]@{
    Timestamp = (Get-Date).ToString('o')
    Channel = $Channel
    CircularOk = $circularOk
    LogMode = "$($log.LogMode)"
    MaximumSizeInBytes = $log.MaximumSizeInBytes
    IsEnabled = $log.IsEnabled
    RecordCount = $log.RecordCount
    HwinfoOk = $hwinfoOk
    HwinfoReason = $hwinfoReason
    HwinfoCsv = if ($csv) { $csv.FullName } else { $null }
    RestoreTimeIso = $restoreTime
    SoakAllowed = $soakAllowed
    Gate = if ($soakAllowed) { 'PASS' } else { 'FAIL' }
    GateReason = if ($soakAllowed) {
        'Circular verified + HWiNFO CSV active'
    } elseif (-not $circularOk) {
        'CHANNEL_NOT_CIRCULAR_OR_TOO_SMALL — soak non parte (STRUMENTO CIECO risk)'
    } else {
        "HWiNFO_CSV_NOT_ACTIVE — $hwinfoReason — soak non parte"
    }
}

if (-not $OutJson) {
    $dir = if ($RestoreTimeFile) { Split-Path $RestoreTimeFile -Parent } else { $env:TEMP }
    $OutJson = Join-Path $dir ("soak-gate-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
$result | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 $OutJson
$result | ConvertTo-Json -Depth 5
if (-not $soakAllowed) { exit 2 }
exit 0
