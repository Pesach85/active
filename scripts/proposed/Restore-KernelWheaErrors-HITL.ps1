#Requires -RunAsAdministrator
<#
.SYNOPSIS
  HITL restore of Microsoft-Windows-Kernel-WHEA/Errors (export-verify gate, then clear + circular).

.DESCRIPTION
  Default is SIMULATION (-Execute omitted). When -Execute:
    1) Disk space check on backup volume (outside channel)
    2) wevtutil epl -> .evtx
    3) BLOCKING gate: file exists, size>0, Get-WinEvent -Path readable, Id=20 count == ExpectedId20
    4) Only then: wevtutil cl + wevtutil sl /rt:false /ms
    5) Verify Circular; print exact restore timestamp = soak window start

  Does NOT start soak. Does NOT touch BCD.
  Syntax aligned with local wevtutil help captured 2026-10-07.
#>
[CmdletBinding()]
param(
    [string]$Channel = 'Microsoft-Windows-Kernel-WHEA/Errors',
    # Default on D: — measured 2026-10-07: C: free ~564 MB < 1 GB gate. Override with -BackupDir if needed.
    [string]$BackupDir = 'D:\whea-backup',
    [int]$ExpectedId20 = 3456,
    [int]$MaxSizeMB = 64,
    [long]$MinFreeBytes = 1GB,
    [switch]$Execute
)

$ErrorActionPreference = 'Stop'

function Invoke-Wevt {
    & wevtutil @args
    if ($LASTEXITCODE -ne 0) {
        throw "wevtutil $($args -join ' ') fallito ($LASTEXITCODE)"
    }
}

$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = Join-Path $BackupDir "Kernel-WHEA-Errors-$ts.evtx"
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null

# 1. Stato attuale
$cfg = Get-WinEvent -ListLog $Channel
"Stato attuale: LogMode=$($cfg.LogMode) Max=$($cfg.MaximumSizeInBytes) Record=$($cfg.RecordCount) Abilitato=$($cfg.IsEnabled)"

# 2. Spazio disco per il backup (fuori dal canale)
$driveLetter = [IO.Path]::GetPathRoot($BackupDir).Substring(0, 1)
$free = (Get-PSDrive -Name $driveLetter).Free
if ($null -eq $free -or $free -lt $MinFreeBytes) {
    throw "Spazio libero insufficiente per il backup su ${driveLetter}: $([math]::Round(($free / 1MB), 0)) MB (min $([math]::Round($MinFreeBytes/1MB)) MB)"
}
"Spazio libero ${driveLetter}: $([math]::Round($free/1GB, 2)) GB — OK"

if (-not $Execute) {
    Write-Host "SIMULAZIONE: farei export in $backup, verifica (${ExpectedId20} eventi ID20 via Get-WinEvent -Path), clear, retention circolare ${MaxSizeMB}MB."
    Write-Host "Rilancia con -Execute solo dopo conferma HITL. cl NON parte se il gate export fallisce."
    return
}

# 3. Export + verifica BLOCCANTE (cl non parte se fallisce)
Invoke-Wevt epl $Channel $backup /ow:true

if (-not (Test-Path -LiteralPath $backup)) {
    throw "Backup assente dopo epl: $backup — clear annullato."
}
$size = (Get-Item -LiteralPath $backup).Length
if ($size -le 0) {
    throw 'Backup vuoto: clear annullato.'
}

# Readable + count Id 20 (must match expected storm snapshot)
try {
    $n = @(Get-WinEvent -FilterHashtable @{ Path = $backup; Id = 20 } -ErrorAction Stop).Count
}
catch {
    throw "Backup non leggibile con Get-WinEvent -Path / FilterHashtable: $($_.Exception.Message) — clear annullato."
}
if ($n -ne $ExpectedId20) {
    throw "Backup contiene $n eventi ID20 invece di ${ExpectedId20}: clear annullato."
}
Write-Host "Backup verificato: $backup ($size byte, $n eventi ID20) — gate PASS, procedo al clear."

# 4. Clear + retention circolare (solo dopo gate)
Invoke-Wevt cl $Channel
Invoke-Wevt sl $Channel /rt:false /ms:$(($MaxSizeMB * 1MB))

# 5. Verifica configurazione e orario di inizio finestra soak
$after = Get-WinEvent -ListLog $Channel
if ($after.LogMode -ne 'Circular') {
    throw "LogMode=$($after.LogMode), atteso Circular"
}
if (-not $after.IsEnabled) {
    throw 'Canale disabilitato dopo sl — unexpected'
}
if ($after.MaximumSizeInBytes -lt ($MaxSizeMB * 1MB - 65536)) {
    # allow 64KB rounding per wevtutil help
    throw "MaxSize=$($after.MaximumSizeInBytes) inferiore a ${MaxSizeMB}MB atteso"
}

$start = Get-Date -Format 'o'
$startFile = Join-Path $BackupDir "restore-time-$ts.txt"
$start | Set-Content -Encoding UTF8 $startFile

$meta = [ordered]@{
    RestoreTimeIso = $start
    BackupEvtx = $backup
    BackupBytes = $size
    Id20Count = $n
    Channel = $Channel
    LogMode = "$($after.LogMode)"
    MaximumSizeInBytes = $after.MaximumSizeInBytes
    RecordCountAfterClear = $after.RecordCount
    SoakWindowStartsAt = $start
    Note = 'Soak still requires Validate gate: Circular + HWiNFO CSV active. No BCD changes in this script.'
}
$meta | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $BackupDir "restore-meta-$ts.json")

Write-Host "OK: Circular, Max=$($after.MaximumSizeInBytes), RecordCount=$($after.RecordCount)."
Write-Host "Inizio finestra soak (orario esatto ripristino): $start"
Write-Host "Salvato: $startFile"
Write-Host "Rollback config: wevtutil sl `"$Channel`" /rt:true /ms:8388608 (il backup resta in $BackupDir)"
Write-Host "NEXT: avvia HWiNFO CSV, poi Validate-SoakGate.ps1 — senza entrambi PASS il soak non parte."
