[CmdletBinding()]
param(
    [string]$ConfigPath = '',
    [switch]$Once,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'hub-common.ps1')
. (Join-Path $PSScriptRoot 'lib\resource-budget.ps1')
$hub = Get-HubPaths
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = $hub.ConfigFile
}
$config = Get-MaintenanceConfig -ConfigPath $ConfigPath
$orch = Get-ConfigSection -Config $config -SectionName 'Orchestrator'
$co = Get-ConfigSection -Config $config -SectionName 'ContinuousOptimization'

$profile = Resolve-OptimizationProfile -Config $config
$intervalSec = if ($orch.HeartbeatIntervalSeconds) { [int]$orch.HeartbeatIntervalSeconds } else { $profile.OrchestratorIntervalSec }
$rotationDays = if ($orch.LogRotationDays) { [int]$orch.LogRotationDays } else { 7 }
$heartbeatRel = if ($orch.HeartbeatFile) { [string]$orch.HeartbeatFile } else { 'logs/hub-orchestrator-heartbeat.json' }
$heartbeatPath = Resolve-HubPath -HubRoot $hub.HubRoot -Path $heartbeatRel
$stateRel = if ($orch.StateFile) { [string]$orch.StateFile } else { 'logs/hub-orchestrator-state.json' }
$statePath = Resolve-HubPath -HubRoot $hub.HubRoot -Path $stateRel

function Write-Heartbeat {
    param([hashtable]$Payload)
    $dir = Split-Path -Parent $heartbeatPath
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
    $Payload | ConvertTo-Json -Depth 8 | Out-File -LiteralPath $heartbeatPath -Encoding utf8 -Force
}

function Get-OrchestratorState {
    if (-not (Test-Path -LiteralPath $statePath)) {
        return @{ CycleNumber = 0 }
    }
    try {
        $j = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        return @{ CycleNumber = [int]$j.CycleNumber }
    } catch {
        return @{ CycleNumber = 0 }
    }
}

function Set-OrchestratorState {
    param([int]$CycleNumber)
    $dir = Split-Path -Parent $statePath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    (@{ CycleNumber = $CycleNumber; UpdatedAt = (Get-Date).ToString('o'); Profile = $profile.Name; Tier = $profile.Tier } | ConvertTo-Json) |
        Out-File -LiteralPath $statePath -Encoding utf8 -Force
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
    $state = Get-OrchestratorState
    $cycleNum = [int]$state.CycleNumber + 1

    $rotated = Invoke-LogRotation -Days $rotationDays
    [void]$actions.Add([ordered]@{ Action = 'LogRotation'; Removed = $rotated; Days = $rotationDays })

    $runFs = ($orch.RunFsIntegrityScan -and [bool]$orch.RunFsIntegrityScan) -and
        ($profile.RunFsIntegrityEveryNCycles -le 1 -or ($cycleNum % [int]$profile.RunFsIntegrityEveryNCycles) -eq 0)
    if ($runFs) {
        try {
            & (Join-Path $hub.Scripts 'fs-integrity.ps1') -ConfigPath $ConfigPath | Out-Null
            [void]$actions.Add([ordered]@{ Action = 'FsIntegrity'; Status = 'ok'; Cycle = $cycleNum })
        } catch {
            [void]$actions.Add([ordered]@{ Action = 'FsIntegrity'; Status = 'failed'; Error = $_.Exception.Message })
        }
    } else {
        [void]$actions.Add([ordered]@{ Action = 'FsIntegrity'; Status = 'skipped'; Cycle = $cycleNum })
    }

    $runWhea = ($orch.RunWheaMonitor -and [bool]$orch.RunWheaMonitor) -and
        ($profile.RunWheaEveryNCycles -le 1 -or ($cycleNum % [int]$profile.RunWheaEveryNCycles) -eq 0)
    if ($runWhea) {
        try {
            & (Join-Path $hub.Scripts 'monitor-whea-rate.ps1') -ConfigPath $ConfigPath -Quiet | Out-Null
            [void]$actions.Add([ordered]@{ Action = 'WheaMonitor'; Status = 'ok'; Cycle = $cycleNum })
        } catch {
            [void]$actions.Add([ordered]@{ Action = 'WheaMonitor'; Status = 'failed'; Error = $_.Exception.Message })
        }
    } else {
        [void]$actions.Add([ordered]@{ Action = 'WheaMonitor'; Status = 'skipped'; Cycle = $cycleNum })
    }

    $coEnabled = $true
    if ($co.ContainsKey('Enabled')) { $coEnabled = [bool]$co.Enabled }
    if ($coEnabled) {
        $buildCtx = -not $co.ContainsKey('BuildContextEachCycle') -or [bool]$co['BuildContextEachCycle']
        if ($buildCtx) {
            try {
                & (Join-Path $hub.Scripts 'build-optimization-context.ps1') -ConfigPath $ConfigPath | Out-Null
                [void]$actions.Add([ordered]@{ Action = 'OptimizationContext'; Status = 'ok' })
            } catch {
                [void]$actions.Add([ordered]@{ Action = 'OptimizationContext'; Status = 'failed'; Error = $_.Exception.Message })
            }
        }

        $transparency = Get-ConfigSection -Config $config -SectionName 'Transparency'
        $buildTransparency = $transparency -and (
            -not $transparency.ContainsKey('Enabled') -or [bool]$transparency.Enabled
        ) -and (
            -not $transparency.ContainsKey('BuildReportEachOrchestratorCycle') -or [bool]$transparency['BuildReportEachOrchestratorCycle']
        )
        if ($buildTransparency) {
            try {
                & (Join-Path $hub.Scripts 'build-transparency-report.ps1') -ConfigPath $ConfigPath | Out-Null
                [void]$actions.Add([ordered]@{ Action = 'TransparencyReport'; Status = 'ok' })
            } catch {
                [void]$actions.Add([ordered]@{ Action = 'TransparencyReport'; Status = 'failed'; Error = $_.Exception.Message })
            }
        }

        $runPpi = ($co.ContainsKey('RunPpiOnCycle') -and [bool]$co['RunPpiOnCycle']) -and
            ($profile.PpiEveryOrchestratorCycles -le 1 -or ($cycleNum % [int]$profile.PpiEveryOrchestratorCycles) -eq 0)
        if ($runPpi) {
            try {
                $ppiScript = Join-Path $hub.Scripts 'analyze-process-pressure.ps1'
                $ppiOut = Resolve-HubPath -HubRoot $hub.HubRoot -Path 'logs/process-pressure-latest.json'
                $dur = [int]$profile.PpiDurationSec
                $top = [int]$profile.PpiTop
                $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Path
                if (-not $pwsh) { $pwsh = (Get-Command powershell).Path }
                $p = Start-Process -FilePath $pwsh -ArgumentList @(
                    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ppiScript,
                    '-DurationSec', "$dur", '-Top', "$top", '-OutputJson', $ppiOut
                ) -Wait -PassThru -WindowStyle Hidden
                [void]$actions.Add([ordered]@{
                    Action = 'ProcessPressure'; Status = if ($p.ExitCode -eq 0) { 'ok' } else { 'failed' }
                    ExitCode = $p.ExitCode; DurationSec = $dur; Top = $top; Cycle = $cycleNum
                })
            } catch {
                [void]$actions.Add([ordered]@{ Action = 'ProcessPressure'; Status = 'failed'; Error = $_.Exception.Message })
            }
        }
    }

    Set-OrchestratorState -CycleNumber $cycleNum

    $payload = [ordered]@{
        TimestampUTC = [DateTime]::UtcNow.ToString('o')
        HubRoot      = $hub.HubRoot
        CycleNumber  = $cycleNum
        Profile      = $profile.Name
        Tier         = $profile.Tier
        CycleSeconds = [math]::Round(((Get-Date) - $cycleStarted).TotalSeconds, 2)
        Actions      = @($actions)
        NextRunUTC   = [DateTime]::UtcNow.AddSeconds($intervalSec).ToString('o')
    }
    Write-Heartbeat -Payload $payload

    if (-not $Quiet) {
        Write-Host ("[ORCH] Cycle {0} ({1}/tier {2}) complete. Heartbeat={3}" -f $cycleNum, $profile.Name, $profile.Tier, $heartbeatPath) -ForegroundColor Green
    }
}

if (-not $orch.ContainsKey('Enabled') -or -not [bool]$orch.Enabled) {
    if (-not $Quiet) { Write-Host '[ORCH] Disabled in config.' -ForegroundColor Yellow }
    exit 0
}

if ($Once) {
    Invoke-OrchestratorCycle
    exit 0
}

if (-not $Quiet) {
    Write-Host ("[ORCH] Starting loop. Interval={0}s Profile={1} Tier={2}" -f $intervalSec, $profile.Name, $profile.Tier) -ForegroundColor Cyan
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
