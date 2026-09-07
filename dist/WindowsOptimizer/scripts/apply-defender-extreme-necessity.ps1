# Live apply requires elevation; dry-run parity gate runs without admin.
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$EvaluationJson,
    [Parameter(Mandatory)][string]$OutputJson,
    [ValidateSet('TuneExclusions','TemporaryRealtimeOff','ExtremeServiceDisable')]
    [string]$Tier,
    [ValidateSet('DevBuild','EmergencyPerf','ForensicCapture','VendorSupport')]
    [string]$ReasonCode = 'DevBuild',
    [string[]]$ExclusionPaths = @(),
    [int]$AutoReenableMinutes = 0,
    [string]$RollbackJson = '',
    [switch]$DryRun,
    [switch]$IUnderstandRisk,
    [switch]$ConfirmExtremeDisable
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $DryRun) {
    $scriptDirEarly = Split-Path -Parent $MyInvocation.MyCommand.Path
    . (Join-Path $scriptDirEarly 'hub-common.ps1')
    if (-not (Test-HubAdmin)) {
        throw 'Administrator elevation required for live Defender apply (dry-run does not require admin).'
    }
}

if (-not $IUnderstandRisk) {
    throw 'HITL gate: pass -IUnderstandRisk after reading evaluation blockers and prerequisites.'
}
if ($Tier -eq 'ExtremeServiceDisable' -and -not $ConfirmExtremeDisable) {
    throw 'ExtremeServiceDisable requires -ConfirmExtremeDisable (second explicit gate).'
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$hubRoot = Split-Path -Parent $scriptDir
. (Join-Path $scriptDir 'lib\hub-decision-log.ps1')
$logsDir = Join-Path $hubRoot 'logs'
if (-not (Test-Path -LiteralPath $logsDir)) { New-Item -Path $logsDir -ItemType Directory -Force | Out-Null }

if (-not $RollbackJson) {
    $RollbackJson = Join-Path $logsDir ('defender-extreme-rollback-{0}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}

if (-not (Test-Path -LiteralPath $EvaluationJson)) { throw "Evaluation JSON not found: $EvaluationJson" }
$eval = Get-Content -LiteralPath $EvaluationJson -Raw | ConvertFrom-Json
if ([string]$eval.RecommendedTier -ne $Tier) {
    throw ("Tier mismatch: evaluation recommends '{0}' but you requested '{1}'." -f $eval.RecommendedTier, $Tier)
}
if (-not [bool]$eval.AllowedToProceed) {
    throw ("Evaluation blocked proceed. Blockers: {0}" -f (@($eval.Blockers) -join '; '))
}

$corePath = Join-Path $scriptDir 'lib\process-pressure-core.ps1'
. $corePath
$before = Get-DefenderPlatformStatus

$rollback = [ordered]@{
    SchemaVersion = 'DefenderExtremeRollback.v1'
    GeneratedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    ReasonCode = $ReasonCode
    Tier = $Tier
    DryRun = [bool]$DryRun
    Before = $before
    ExclusionPathsAdded = @()
    ServiceStates = @()
    ScheduledReenableMinutes = $AutoReenableMinutes
}

$applied = New-Object System.Collections.Generic.List[object]

function Add-Applied {
    param([string]$Action, [string]$Detail)
    [void]$applied.Add([ordered]@{ Action = $Action; Detail = $Detail; Applied = (-not $DryRun) })
}

switch ($Tier) {
    'TuneExclusions' {
        if (@($ExclusionPaths).Count -lt 1) {
            throw 'TuneExclusions requires -ExclusionPaths for at least one trusted folder.'
        }
        foreach ($path in @($ExclusionPaths)) {
            if (-not (Test-Path -LiteralPath $path)) {
                Write-Warning "Path not found (still recording): $path"
            }
            if (-not $DryRun) {
                Add-MpPreference -ExclusionPath $path -ErrorAction Stop
            }
            $rollback.ExclusionPathsAdded += [string]$path
            Add-Applied -Action 'Add-MpPreference ExclusionPath' -Detail $path
        }
        Add-Applied -Action 'Guidance' -Detail 'Schedule full scan outside work hours via Windows Security or Set-MpPreference scan schedule.'
    }
    'TemporaryRealtimeOff' {
        $maxMin = 60
        if ($AutoReenableMinutes -lt 1) { $AutoReenableMinutes = 30 }
        if ($AutoReenableMinutes -gt $maxMin) {
            throw "TemporaryRealtimeOff max duration is $maxMin minutes."
        }
        if (-not $DryRun) {
            Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction Stop
        }
        Add-Applied -Action 'Set-MpPreference -DisableRealtimeMonitoring' -Detail 'true'
        $rollback.ScheduledReenableMinutes = $AutoReenableMinutes
    }
    'ExtremeServiceDisable' {
        $maxMin = 120
        if ($AutoReenableMinutes -lt 1) { $AutoReenableMinutes = 60 }
        if ($AutoReenableMinutes -gt $maxMin) {
            throw "ExtremeServiceDisable max duration is $maxMin minutes."
        }
        $svc = Get-Service -Name WinDefend -ErrorAction SilentlyContinue
        if ($svc) {
            $rollback.ServiceStates += [ordered]@{
                Name = 'WinDefend'; StartType = [string]$svc.StartType; Status = [string]$svc.Status
            }
        }
        if (-not $DryRun) {
            Stop-Service -Name WinDefend -Force -ErrorAction Stop
            Set-Service -Name WinDefend -StartupType Manual -ErrorAction Stop
        }
        Add-Applied -Action 'Stop-Service WinDefend + Manual start' -Detail "Re-enable within $AutoReenableMinutes min"
        $rollback.ScheduledReenableMinutes = $AutoReenableMinutes
    }
}

if ($AutoReenableMinutes -gt 0 -and -not $DryRun) {
    $restoreScript = Join-Path $scriptDir 'restore-defender-from-rollback.ps1'
    $taskName = 'HubDefenderReenable-{0}' -f (Get-Date -Format 'yyyyMMddHHmmss')
    $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$restoreScript`" -RollbackJson `"$RollbackJson`""
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
    $trigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes($AutoReenableMinutes))
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -RunLevel Highest -Force | Out-Null
    $rollback.ScheduledTaskName = $taskName
    Add-Applied -Action 'Register-ScheduledTask re-enable' -Detail $taskName
}

($rollback | ConvertTo-Json -Depth 10) | Out-File -LiteralPath $RollbackJson -Encoding utf8 -Force

$out = [ordered]@{
    SchemaVersion = 'DefenderExtremeApplyResult.v1'
    GeneratedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Tier = $Tier
    ReasonCode = $ReasonCode
    DryRun = [bool]$DryRun
    Applied = $applied.ToArray()
    RollbackPath = $RollbackJson
    After = if (-not $DryRun) { Get-DefenderPlatformStatus } else { $null }
}
($out | ConvertTo-Json -Depth 10) | Out-File -LiteralPath $OutputJson -Encoding utf8 -Force
$decisionContext = @{
    Tier         = [string]$Tier
    DryRun       = [bool]$DryRun
    AppliedCount = [int]$applied.Count
}
Write-HubDecisionLog -HubRoot $hubRoot `
    -Domain 'defender-apply' `
    -Path $(if ($env:HUB_DECISION_PATH) { [string]$env:HUB_DECISION_PATH } else { 'ps' }) `
    -Action 'ApplyTier' `
    -Outcome $(if ($DryRun) { 'DryRunApplied' } else { 'Applied' }) `
    -Success:$true `
    -Context $decisionContext
Write-Host ("Defender apply tier={0} rollback={1}" -f $Tier, $RollbackJson)
$out
