# Deterministic migration NBD scorer + mandatory quality gates (ADR-0007).
[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$QuickGates,
    [switch]$Quiet,
    [string]$OutputJson = '',
    [string]$HubRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $HubRoot) { $HubRoot = Split-Path -Parent $scriptDir }

$configPath = Join-Path $HubRoot 'config\migration-nbd.json'
if (-not (Test-Path -LiteralPath $configPath)) {
    throw "Missing config: $configPath"
}

$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$weights = $config.Weights
$passThreshold = [double]$config.PassThreshold
$doneIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

foreach ($c in @($config.Candidates)) {
    if ([string]$c.Status -eq 'done') { [void]$doneIds.Add([string]$c.Id) }
}

function Get-WeightedScore {
    param($Scores)
    $total = 0.0
    $total += [double]$Scores.ParityFeasibility * [double]$weights.ParityFeasibility
    $total += [double]$Scores.RegressionRiskInverse * [double]$weights.RegressionRiskInverse
    $total += [double]$Scores.UserValue * [double]$weights.UserValue
    $total += [double]$Scores.GateReadiness * [double]$weights.GateReadiness
    $total += [double]$Scores.EffortInverse * [double]$weights.EffortInverse
    return [math]::Round($total, 2)
}

function Test-CandidateEligible {
    param($Candidate)
    if ([string]$Candidate.Status -eq 'done') { return $false }
    if ([string]$Candidate.Status -eq 'blocked') {
        $blockers = @($Candidate.BlockedBy)
        if ($blockers.Count -eq 0) { return $false }
        foreach ($b in $blockers) {
            if (-not $doneIds.Contains([string]$b)) { return $false }
        }
        return $true
    }
    return [string]$Candidate.Status -eq 'ready'
}

$gateResults = [System.Collections.Generic.List[object]]::new()
$gatesPassed = $true

function Invoke-MigrationGate {
    param([string]$Id, [string]$Label, [scriptblock]$Run)
    if (-not $Apply) {
        [void]$gateResults.Add([ordered]@{
            Id = $Id; Label = $Label; Status = 'Skipped'; Message = 'Use -Apply to run gates'
        })
        return $true
    }
    if (-not $Quiet) { Write-Host "[NBD-GATE] $Label..." }
    try {
        & $Run
        if ($LASTEXITCODE -ne 0) { throw "exit $LASTEXITCODE" }
        if (-not $Quiet) { Write-Host "[NBD-GATE] $Label OK" }
        [void]$gateResults.Add([ordered]@{ Id = $Id; Label = $Label; Status = 'Passed'; Message = '' })
        return $true
    } catch {
        if (-not $Quiet) { Write-Host "[NBD-GATE] $Label FAILED: $($_.Exception.Message)" }
        [void]$gateResults.Add([ordered]@{
            Id = $Id; Label = $Label; Status = 'Failed'; Message = [string]$_.Exception.Message
        })
        return $false
    }
}

$dotnetOk = Invoke-MigrationGate -Id 'dotnet_test' -Label 'dotnet test' -Run {
    $sln = Join-Path $HubRoot 'src\SystemOptimizerHub.sln'
    if (-not (Test-Path -LiteralPath $sln)) { throw 'Solution not found' }
    dotnet test $sln -v q --nologo
}

$parityOk = Invoke-MigrationGate -Id 'core_parity' -Label 'core parity PS vs C#' -Run {
    $parity = Join-Path $scriptDir 'test-core-parity.ps1'
    & $parity
}

$smokeOk = $true
if (-not $QuickGates) {
    $smokeOk = Invoke-MigrationGate -Id 'hub_smoke' -Label 'hub smoke' -Run {
        $smoke = Join-Path $scriptDir 'test-hub-smoke.ps1'
        & $smoke
    }
} elseif ($Apply) {
    [void]$gateResults.Add([ordered]@{
        Id = 'hub_smoke'; Label = 'hub smoke'; Status = 'Skipped'; Message = 'QuickGates mode'
    })
}

if ($Apply) {
    $gatesPassed = $dotnetOk -and $parityOk -and $smokeOk
}

$ranked = [System.Collections.Generic.List[object]]::new()
foreach ($c in @($config.Candidates)) {
    $eligible = Test-CandidateEligible -Candidate $c
    $score = Get-WeightedScore -Scores $c.Scores
    [void]$ranked.Add([ordered]@{
        Id = [string]$c.Id
        Phase = [int]$c.Phase
        Title = [string]$c.Title
        Status = [string]$c.Status
        Eligible = [bool]$eligible
        TotalScore = $score
        BelowThreshold = ($score -lt $passThreshold)
        Rationale = if ($c.PSObject.Properties['Rationale']) { [string]$c.Rationale } else { '' }
        Deliverable = if ($c.PSObject.Properties['Deliverable']) { [string]$c.Deliverable } else { '' }
    })
}

$eligibleRanked = @($ranked | Where-Object { $_.Eligible } | Sort-Object { [double]$_.TotalScore } -Descending)
$nbd = $null
$decision = 'implement'

if (-not $gatesPassed -and $Apply) {
    $decision = 'stabilize-gates'
    $nbd = [ordered]@{
        Id = 'stabilize-gates'
        Title = 'Fix failed quality gates before migration work'
        TotalScore = 0
        Rationale = 'Mandatory gates must ALL PASS before Phase 1 implementation.'
    }
} elseif ($eligibleRanked.Count -eq 0) {
    $decision = 'plan-next-phase'
    $nbd = [ordered]@{
        Id = 'plan-next-phase'
        Title = 'No eligible candidates — update migration-nbd.json statuses'
        TotalScore = 0
        Rationale = 'All ready items done or blocked.'
    }
} else {
    $winner = $eligibleRanked[0]
    $nbd = [ordered]@{
        Id = [string]$winner.Id
        Title = [string]$winner.Title
        TotalScore = [double]$winner.TotalScore
        BelowThreshold = [bool]$winner.BelowThreshold
        Rationale = [string]$winner.Rationale
        Deliverable = [string]$winner.Deliverable
    }
}

$result = [ordered]@{
    SchemaVersion = 'MigrationNbdReport.v1'
    GeneratedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    HubCoreVersion = '0.3.0'
    Decision = $decision
    PassThreshold = $passThreshold
    GatesApplied = [bool]$Apply
    GatesPassed = [bool]$gatesPassed
    Gates = @($gateResults)
    NextBestDecision = $nbd
    RankedCandidates = @($ranked | Sort-Object { [double]$_.TotalScore } -Descending)
}

if (-not $OutputJson) {
    $logs = Join-Path $HubRoot 'logs'
    if (-not (Test-Path -LiteralPath $logs)) { New-Item -Path $logs -ItemType Directory -Force | Out-Null }
    $OutputJson = Join-Path $logs 'migration-nbd-latest.json'
}

($result | ConvertTo-Json -Depth 8) | Out-File -LiteralPath $OutputJson -Encoding utf8 -Force

if (-not $Quiet) {
    Write-Host ''
    Write-Host "=== Migration NBD (score threshold $passThreshold) ==="
    Write-Host ("Decision: {0}" -f $decision)
    Write-Host ("NBD: {0} (score {1})" -f $nbd.Id, $nbd.TotalScore)
    if ($nbd.Rationale) { Write-Host ("Why: {0}" -f $nbd.Rationale) }
    Write-Host ("Report: {0}" -f $OutputJson)
    if ($Apply -and -not $gatesPassed) { exit 1 }
}

$result
