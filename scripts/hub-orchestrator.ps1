[CmdletBinding()]
param(
    [string]$ConfigPath = '',
    [switch]$Once,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'hub-common.ps1')
$hub = Get-HubPaths
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = $hub.ConfigFile
}
$config = Get-MaintenanceConfig -ConfigPath $ConfigPath
$orch = Get-ConfigSection -Config $config -SectionName 'Orchestrator'

if (-not $orch.ContainsKey('Enabled') -or -not [bool]$orch.Enabled) {
    if (-not $Quiet) { Write-Host '[ORCH] Disabled in config.' -ForegroundColor Yellow }
    exit 0
}

$intervalSec = if ($orch.HeartbeatIntervalSeconds) { [int]$orch.HeartbeatIntervalSeconds } else { 300 }
$rotationDays = if ($orch.LogRotationDays) { [int]$orch.LogRotationDays } else { 7 }
$heartbeatRel = if ($orch.HeartbeatFile) { [string]$orch.HeartbeatFile } else { 'logs/hub-orchestrator-heartbeat.json' }
$heartbeatPath = Resolve-HubPath -HubRoot $hub.HubRoot -Path $heartbeatRel

function Write-Heartbeat {
    param([hashtable]$Payload)
    $dir = Split-Path -Parent $heartbeatPath
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
    $Payload | ConvertTo-Json -Depth 6 | Out-File -LiteralPath $heartbeatPath -Encoding utf8 -Force
}

function Invoke-LogRotation {
    param([int]$Days)
    $cutoff = (Get-Date).AddDays(-$Days)
    $logsRoot = $hub.Logs
    if (-not (Test-Path -LiteralPath $logsRoot)) { return 0 }

    $removed = 0
    Get-ChildItem -LiteralPath $logsRoot -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            $_.LastWriteTime -lt $cutoff -and
            $_.Extension -in @('.log', '.txt') -and
            $_.Name -notlike '*rollback*'
        } |
        ForEach-Object {
            try {
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop
                $removed++
            } catch { }
        }
    return $removed
}

function Invoke-OrchestratorCycle {
    $cycleStarted = Get-Date
    $actions = [System.Collections.Generic.List[object]]::new()

    $rotated = Invoke-LogRotation -Days $rotationDays
    [void]$actions.Add([ordered]@{ Action = 'LogRotation'; Removed = $rotated; Days = $rotationDays })

    if ($orch.RunFsIntegrityScan -and [bool]$orch.RunFsIntegrityScan) {
        try {
            & (Join-Path $hub.Scripts 'fs-integrity.ps1') -ConfigPath $ConfigPath | Out-Null
            [void]$actions.Add([ordered]@{ Action = 'FsIntegrity'; Status = 'ok' })
        } catch {
            [void]$actions.Add([ordered]@{ Action = 'FsIntegrity'; Status = 'failed'; Error = $_.Exception.Message })
        }
    }

    if ($orch.RunWheaMonitor -and [bool]$orch.RunWheaMonitor) {
        try {
            & (Join-Path $hub.Scripts 'monitor-whea-rate.ps1') -ConfigPath $ConfigPath -Quiet | Out-Null
            [void]$actions.Add([ordered]@{ Action = 'WheaMonitor'; Status = 'ok' })
        } catch {
            [void]$actions.Add([ordered]@{ Action = 'WheaMonitor'; Status = 'failed'; Error = $_.Exception.Message })
        }
    }

    $payload = [ordered]@{
        TimestampUTC = [DateTime]::UtcNow.ToString('o')
        HubRoot      = $hub.HubRoot
        CycleSeconds = [math]::Round(((Get-Date) - $cycleStarted).TotalSeconds, 2)
        Actions      = @($actions)
        NextRunUTC   = [DateTime]::UtcNow.AddSeconds($intervalSec).ToString('o')
    }
    Write-Heartbeat -Payload $payload

    if (-not $Quiet) {
        Write-Host ("[ORCH] Cycle complete. Log files removed={0}. Heartbeat={1}" -f $rotated, $heartbeatPath) -ForegroundColor Green
    }
}

if ($Once) {
    Invoke-OrchestratorCycle
    exit 0
}

if (-not $Quiet) {
    Write-Host ("[ORCH] Starting loop. Interval={0}s" -f $intervalSec) -ForegroundColor Cyan
}

while ($true) {
    try {
        Invoke-OrchestratorCycle
    } catch {
        if (-not $Quiet) {
            Write-Warning ("[ORCH] Cycle error: {0}" -f $_.Exception.Message)
        }
    }
    Start-Sleep -Seconds $intervalSec
}
