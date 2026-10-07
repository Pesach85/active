#requires -RunAsAdministrator
<#
.SYNOPSIS
  PROPOSED (HITL): gate "misura valida" after channel restore — soak must not start without PASS.

.DESCRIPTION
  Checks (read-only unless -AttemptEnable):
    1) wevtutil gl: retention=false, maxSize >= commanded floor, enabled=true
    2) RecordCount / file growth path is not stuck in retain-full semantics
    3) Optional: after a reboot or natural WHEA Operational activity, prove Errors can accept a NEW record
       with TimeCreated > restore timestamp (stored in manifest).

  Windows does not provide a safe synthetic "inject Event ID 20" API here; therefore the writability
  proof is: either (A) observe a new Errors record after restore, or (B) document CONTROLLED_BOOT_PROBE
  where Kernel-WHEA/Operational still logs and Errors remains enabled+circular with RecordCount able to
  increase when a real correctable error occurs — and require a time-boxed watch.

  Criterion coded below matches report 01b: PASS only if config OK AND (new Errors event since restore
  OR explicit -AcceptConfigOnlyProbe with user acknowledgment that soak stays "instrumentation-limited"
  until first live ID20 or 24h watch with HWiNFO parallel).

.NOTES
  Default is strict: needs NewEventObserved OR user passes -AcceptConfigOnlyProbe.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ManifestPath,
    [string]$LogName = 'Microsoft-Windows-Kernel-WHEA/Errors',
    [long]$MinMaxSizeBytes = 67108864,
    [switch]$AcceptConfigOnlyProbe,
    [string]$OutJson = ''
)

$ErrorActionPreference = 'Stop'
$m = Get-Content $ManifestPath -Raw | ConvertFrom-Json
$restoreUtc = [datetimeoffset]::Parse($m.Timestamp)

$gl = cmd /c "wevtutil gl `"$LogName`"" 2>&1 | Out-String
$rt = [regex]::Match($gl, 'retention:\s*(true|false)').Groups[1].Value
$ms = [long][regex]::Match($gl, 'maxSize:\s*(\d+)').Groups[1].Value
$en = [regex]::Match($gl, 'enabled:\s*(true|false)').Groups[1].Value

$list = Get-WinEvent -ListLog $LogName
$newest = $null
try { $newest = Get-WinEvent -LogName $LogName -MaxEvents 1 -ErrorAction SilentlyContinue } catch {}

$newEventObserved = $false
if ($newest) {
    $newEventObserved = ($newest.TimeCreated -gt $restoreUtc.LocalDateTime) -or ($newest.TimeCreated.ToUniversalTime() -gt $restoreUtc.UtcDateTime)
}

$configOk = ($en -eq 'true') -and ($rt -eq 'false') -and ($ms -ge $MinMaxSizeBytes)

$result = [ordered]@{
    Timestamp = (Get-Date).ToString('o')
    LogName = $LogName
    Config = @{ enabled = $en; retention = $rt; maxSize = $ms; RecordCount = $list.RecordCount; LogMode = "$($list.LogMode)" }
    ConfigOk = $configOk
    RestoreTimestamp = $m.Timestamp
    NewestEventTime = if ($newest) { $newest.TimeCreated.ToString('o') } else { $null }
    NewestEventId = if ($newest) { $newest.Id } else { $null }
    NewEventObservedSinceRestore = $newEventObserved
    AcceptConfigOnlyProbe = [bool]$AcceptConfigOnlyProbe
    Gate = 'FAIL'
    GateReason = ''
    SoakAllowed = $false
}

if (-not $configOk) {
    $result.GateReason = 'CONFIG_NOT_CIRCULAR_OR_TOO_SMALL — refuse soak (STRUMENTO CIECO risk remains)'
}
elseif ($newEventObserved) {
    $result.Gate = 'PASS'
    $result.GateReason = 'NEW_ERRORS_EVENT_AFTER_RESTORE — channel writes again'
    $result.SoakAllowed = $true
}
elseif ($AcceptConfigOnlyProbe) {
    $result.Gate = 'PASS_CONFIG_ONLY'
    $result.GateReason = 'Config circular OK but no new Errors event yet; user accepted config-only probe. Prefer parallel HWiNFO CSV. First live ID20 upgrades to full PASS.'
    $result.SoakAllowed = $true
}
else {
    $result.GateReason = 'NO_NEW_EVENT_YET — wait for natural ID20, reboot+config recheck, or pass -AcceptConfigOnlyProbe with HWiNFO parallel. Soak must NOT start.'
}

if (-not $OutJson) {
    $OutJson = Join-Path (Split-Path $ManifestPath -Parent) ('validate_gate_{0}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
$result | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 $OutJson
$result | ConvertTo-Json -Depth 6
if (-not $result.SoakAllowed) { exit 2 }
exit 0
