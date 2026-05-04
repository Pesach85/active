#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [ValidateSet('EnableUsbCapture','DisableUsbCapture','Status')]
    [string]$Mode = 'Status',

    [string]$OutputJson = 'logs/usbpcap-toggle-live.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Sc {
    param([string[]]$ScArgs)

    $text = & sc.exe @ScArgs 2>&1
    return @($text)
}

function Get-UsbPcapState {
    $query = Invoke-Sc -ScArgs @('query', 'USBPcap')

    $exists = -not (($query -join "`n") -match '1060')
    if (-not $exists) {
        return [pscustomobject]@{
            Exists = $false
            Running = $false
            StartValue = $null
            StartMode = 'NotInstalled'
            QueryText = $query
        }
    }

    $running = ($query -join "`n") -match 'STATO\s*:\s*4\s+RUNNING|STATE\s*:\s*4\s+RUNNING'

    $startRaw = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\USBPcap' -Name Start -ErrorAction SilentlyContinue).Start
    $startValue = if ($null -ne $startRaw) { [int]$startRaw } else { -1 }
    $startMode = switch ($startValue) {
        2 { 'Auto' }
        3 { 'Demand' }
        4 { 'Disabled' }
        default { 'Unknown' }
    }

    return [pscustomobject]@{
        Exists = $true
        Running = [bool]$running
        StartValue = $startValue
        StartMode = $startMode
        QueryText = $query
    }
}

function Ensure-OutputFolder {
    param([string]$Path)

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

$before = Get-UsbPcapState
$actions = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]

if (-not $before.Exists) {
    $warnings.Add('USBPcap driver not found. Nothing to change.') | Out-Null
}
else {
    switch ($Mode) {
        'EnableUsbCapture' {
            $actions.Add('Set USBPcap start mode to Demand.') | Out-Null
            $cfg = Invoke-Sc -ScArgs @('config', 'USBPcap', 'start=', 'demand')
            if (($cfg -join "`n") -notmatch 'SUCCESS|RIUSCITE') {
                $warnings.Add('sc config did not report explicit success. Verify state manually.') | Out-Null
            }

            if (-not $before.Running) {
                $actions.Add('Start USBPcap for immediate USB capture availability.') | Out-Null
                $startOut = Invoke-Sc -ScArgs @('start', 'USBPcap')
                if (($startOut -join "`n") -match 'FAILED 1056|NON RIUSCITE 1056') {
                    $warnings.Add('USBPcap already running.') | Out-Null
                }
            }
        }
        'DisableUsbCapture' {
            $actions.Add('Set USBPcap start mode to Disabled to prevent recurring hcmon warnings.') | Out-Null
            $cfg = Invoke-Sc -ScArgs @('config', 'USBPcap', 'start=', 'disabled')
            if (($cfg -join "`n") -notmatch 'SUCCESS|RIUSCITE') {
                $warnings.Add('sc config did not report explicit success. Verify state manually.') | Out-Null
            }

            if ($before.Running) {
                $actions.Add('Try stopping USBPcap now; if stop is rejected, reboot applies full unload.') | Out-Null
                $stopOut = Invoke-Sc -ScArgs @('stop', 'USBPcap')
                if (($stopOut -join "`n") -match '1052') {
                    $warnings.Add('Stop not valid for current USBPcap state. Reboot to unload driver completely.') | Out-Null
                }
            }
        }
        'Status' {
            $actions.Add('Read-only status mode.') | Out-Null
        }
    }
}

$after = Get-UsbPcapState

$result = [pscustomobject]@{
    CapturedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Mode = $Mode
    Before = $before
    After = $after
    Actions = @($actions)
    Warnings = @($warnings)
    Rollback = @(
        'sc.exe config USBPcap start= demand',
        'sc.exe start USBPcap'
    )
    BestNextDecision = if ($Mode -eq 'DisableUsbCapture') {
        'Keep USBPcap disabled by default and enable only during USB troubleshooting sessions.'
    } elseif ($Mode -eq 'EnableUsbCapture') {
        'Run USB capture workload, then return to DisableUsbCapture mode to avoid log noise.'
    } else {
        'Use DisableUsbCapture as default baseline unless USB traffic capture is actively needed.'
    }
}

Ensure-OutputFolder -Path $OutputJson
$result | ConvertTo-Json -Depth 8 | Out-File -LiteralPath $OutputJson -Encoding utf8 -Force

$result