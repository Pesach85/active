<#
.SYNOPSIS
  Applies safe auto-actions from a ProcessPressureReport.v1 JSON (audit-first, rollback JSON).

.DESCRIPTION
  Only reversible Safe actions without HITL by default (LowerProcessPriority).
  Vital/security (Priority=Keep) processes are never modified.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InputJson,
    [Parameter(Mandatory)][string]$OutputJson,
    [ValidateSet('Safe','Moderate','Aggressive')][string]$MaxLevel = 'Safe',
    [string]$RollbackJson = '',
    [switch]$DryRun,
    [switch]$AllowHitlActions
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$hubRoot = Split-Path -Parent $scriptDir
$logsDir = Join-Path $hubRoot 'logs'
if (-not (Test-Path -LiteralPath $logsDir)) {
    New-Item -Path $logsDir -ItemType Directory -Force | Out-Null
}

if (-not $RollbackJson -or $RollbackJson.Trim() -eq '') {
    $RollbackJson = Join-Path $logsDir ('process-pressure-rollback-{0}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}

function Test-ActionLevelAllowed {
    param([string]$ActionLevel, [string]$Max)
    $order = @{ Safe = 1; Moderate = 2; Aggressive = 3 }
    return ([int]$order[$ActionLevel]) -le ([int]$order[$Max])
}

function Resolve-PriorityClass {
    param([string]$Name)
    switch ($Name) {
        'Idle' { return [System.Diagnostics.ProcessPriorityClass]::Idle }
        'BelowNormal' { return [System.Diagnostics.ProcessPriorityClass]::BelowNormal }
        'Normal' { return [System.Diagnostics.ProcessPriorityClass]::Normal }
        default { return [System.Diagnostics.ProcessPriorityClass]::BelowNormal }
    }
}

if (-not (Test-Path -LiteralPath $InputJson)) {
    throw "Input JSON not found: $InputJson"
}

$report = Get-Content -LiteralPath $InputJson -Raw | ConvertFrom-Json
$schema = [string]$report.SchemaVersion
if ($schema -notmatch 'ProcessPressureReport') {
    throw "Unexpected schema: $schema (expected ProcessPressureReport.v1)"
}

$rollback = [ordered]@{
    SchemaVersion = 'ProcessPressureRollback.v1'
    GeneratedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    SourceReport = $InputJson
    DryRun = [bool]$DryRun
    MaxLevel = $MaxLevel
    Actions = @()
}

$applied = [System.Collections.Generic.List[object]]::new()
$skipped = [System.Collections.Generic.List[object]]::new()

foreach ($proc in @($report.TopProcesses)) {
    $priority = [string]$proc.Priority
    if ($priority -eq 'Keep') {
        [void]$skipped.Add([ordered]@{
            PID = [int]$proc.PID; ProcessName = [string]$proc.ProcessName
            Reason = 'Vital/security preserved'
        })
        continue
    }

    $score = [double]$proc.Score
    if ($score -lt 40) {
        [void]$skipped.Add([ordered]@{
            PID = [int]$proc.PID; ProcessName = [string]$proc.ProcessName
            Reason = 'Score below auto-action threshold (40)'
        })
        continue
    }

    $actions = @($proc.AutoEligibleActions)
    if ($AllowHitlActions) {
        $actions += @($proc.HitlRequiredActions)
    }

    foreach ($act in $actions) {
        $actionName = [string]$act.Action
        $level = [string]$act.Level
        if (-not $level) { $level = 'Safe' }
        if (-not (Test-ActionLevelAllowed -ActionLevel $level -Max $MaxLevel)) {
            [void]$skipped.Add([ordered]@{
                PID = [int]$proc.PID; ProcessName = [string]$proc.ProcessName
                Action = $actionName; Reason = "Level $level exceeds MaxLevel $MaxLevel"
            })
            continue
        }

        if ($act.RequiresHitl -and -not $AllowHitlActions) {
            [void]$skipped.Add([ordered]@{
                PID = [int]$proc.PID; ProcessName = [string]$proc.ProcessName
                Action = $actionName; Reason = 'Requires HITL review'
            })
            continue
        }

        switch ($actionName) {
            'LowerProcessPriority' {
                try {
                    $p = Get-Process -Id ([int]$proc.PID) -ErrorAction Stop
                    $before = [string]$p.PriorityClass
                    $target = Resolve-PriorityClass -Name 'BelowNormal'
                    if ($before -eq 'BelowNormal' -or $before -eq 'Idle') {
                        [void]$skipped.Add([ordered]@{
                            PID = [int]$proc.PID; ProcessName = [string]$proc.ProcessName
                            Action = $actionName; Reason = "Already at $before"
                        })
                        continue
                    }

                    if (-not $DryRun) {
                        $p.PriorityClass = $target
                    }

                    $entry = [ordered]@{
                        PID = [int]$proc.PID
                        ProcessName = [string]$proc.ProcessName
                        Action = $actionName
                        BeforePriority = $before
                        AfterPriority = [string]$target
                        Applied = (-not $DryRun)
                        Rationale = [string]$act.Rationale
                    }
                    [void]$applied.Add($entry)
                    $rollback.Actions += [ordered]@{
                        PID = [int]$proc.PID
                        ProcessName = [string]$proc.ProcessName
                        RestorePriority = $before
                    }
                } catch {
                    [void]$skipped.Add([ordered]@{
                        PID = [int]$proc.PID; ProcessName = [string]$proc.ProcessName
                        Action = $actionName; Reason = $_.Exception.Message
                    })
                }
            }
            'ObserveOnly' {
                [void]$skipped.Add([ordered]@{
                    PID = [int]$proc.PID; ProcessName = [string]$proc.ProcessName
                    Action = $actionName; Reason = 'No system change'
                })
            }
            default {
                [void]$skipped.Add([ordered]@{
                    PID = [int]$proc.PID; ProcessName = [string]$proc.ProcessName
                    Action = $actionName; Reason = 'Not implemented in safe apply (HITL/manual)'
                })
            }
        }
    }
}

$out = [ordered]@{
    SchemaVersion = 'ProcessPressureApplyResult.v1'
    GeneratedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    DryRun = [bool]$DryRun
    MaxLevel = $MaxLevel
    Applied = @($applied)
    Skipped = @($skipped)
    RollbackPath = $RollbackJson
}

($rollback | ConvertTo-Json -Depth 8) | Out-File -LiteralPath $RollbackJson -Encoding utf8 -Force
($out | ConvertTo-Json -Depth 10) | Out-File -LiteralPath $OutputJson -Encoding utf8 -Force

Write-Host ("Applied={0} Skipped={1} Rollback={2}" -f $applied.Count, $skipped.Count, $RollbackJson)
$out
