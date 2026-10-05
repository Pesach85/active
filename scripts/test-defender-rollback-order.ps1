# Proves Defender rollback is persisted before any mutation. Does not change Defender.
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$hubRoot = Split-Path -Parent $scriptDir
$apply = Join-Path $scriptDir 'apply-defender-extreme-necessity.ps1'
$fixture = Join-Path $hubRoot 'config\fixtures\defender-eval-apply-dryrun.json'
if (-not (Test-Path -LiteralPath $fixture)) { throw "Missing fixture: $fixture" }

$work = Join-Path $hubRoot 'logs\defender-rollback-order'
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
New-Item -ItemType Directory -Path $work -Force | Out-Null

$excl = Join-Path $work 'exclusion-placeholder'
New-Item -ItemType Directory -Path $excl -Force | Out-Null

function Reset-InterceptEnv {
    Remove-Item Env:HUB_DEFENDER_MUTATION_SINK -ErrorAction SilentlyContinue
    Remove-Item Env:HUB_DEFENDER_ROLLBACK_CORRUPT -ErrorAction SilentlyContinue
}

function Invoke-Apply {
    param([hashtable]$Params)
    & $apply @Params | Out-Null
}

$failures = New-Object System.Collections.Generic.List[string]

try {
    # 1. Unreadable rollback after flush -> zero intercepted mutations.
    $sink1 = Join-Path $work 'sink-corrupt.txt'
    Set-Content -LiteralPath $sink1 -Value '' -Encoding utf8
    $env:HUB_DEFENDER_MUTATION_SINK = $sink1
    $env:HUB_DEFENDER_ROLLBACK_CORRUPT = '1'
    $threw = $false
    try {
        Invoke-Apply @{
            EvaluationJson = $fixture
            OutputJson = (Join-Path $work 'out-corrupt.json')
            Tier = 'TuneExclusions'
            ExclusionPaths = @($excl)
            RollbackJson = (Join-Path $work 'corrupt-rollback.json')
            IUnderstandRisk = $true
        }
    } catch { $threw = $true }
    $sinkBody = Get-Content -LiteralPath $sink1 -Raw -ErrorAction SilentlyContinue
    if (-not $threw) { $failures.Add('corrupt rollback did not fail') }
    if (-not [string]::IsNullOrWhiteSpace($sinkBody)) { $failures.Add('corrupt rollback recorded a mutation') }

    Reset-InterceptEnv

    # 2. Rollback path cannot be written -> zero intercepted mutations.
    $sink2 = Join-Path $work 'sink-unwritable.txt'
    Set-Content -LiteralPath $sink2 -Value '' -Encoding utf8
    $blocker = Join-Path $work 'not-a-directory'
    Set-Content -LiteralPath $blocker -Value 'x' -Encoding utf8
    $env:HUB_DEFENDER_MUTATION_SINK = $sink2
    $threw = $false
    try {
        Invoke-Apply @{
            EvaluationJson = $fixture
            OutputJson = (Join-Path $work 'out-unwritable.json')
            Tier = 'TuneExclusions'
            ExclusionPaths = @($excl)
            RollbackJson = (Join-Path $blocker 'rollback.json')
            IUnderstandRisk = $true
        }
    } catch { $threw = $true }
    $sinkBody = Get-Content -LiteralPath $sink2 -Raw -ErrorAction SilentlyContinue
    if (-not $threw) { $failures.Add('unwritable rollback did not fail') }
    if (-not [string]::IsNullOrWhiteSpace($sinkBody)) { $failures.Add('unwritable rollback recorded a mutation') }

    Reset-InterceptEnv

    # 3. Valid rollback -> first intercepted mutation is allowed, and it is not reported as Applied.
    $sink3 = Join-Path $work 'sink-valid.txt'
    Set-Content -LiteralPath $sink3 -Value '' -Encoding utf8
    $rollback3 = Join-Path $work 'valid-rollback.json'
    $out3 = Join-Path $work 'out-valid.json'
    $env:HUB_DEFENDER_MUTATION_SINK = $sink3
    $threw = $false
    try {
        Invoke-Apply @{
            EvaluationJson = $fixture
            OutputJson = $out3
            Tier = 'TuneExclusions'
            ExclusionPaths = @($excl)
            RollbackJson = $rollback3
            IUnderstandRisk = $true
        }
    } catch { $threw = $true }
    if (-not $threw) { $failures.Add('intercepted apply was reported as success') }
    $lines = @(Get-Content -LiteralPath $sink3 -ErrorAction SilentlyContinue | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -lt 1 -or ($lines[0] -notmatch 'Add-MpPreference')) {
        $failures.Add('valid rollback did not allow Add-MpPreference after verification')
    }
    $parsed = Get-Content -LiteralPath $rollback3 -Raw | ConvertFrom-Json
    if ([string]$parsed.SchemaVersion -ne 'DefenderExtremeRollback.v1') { $failures.Add('rollback schema mismatch') }
    if ([string]$parsed.Tier -ne 'TuneExclusions') { $failures.Add('rollback tier mismatch') }
    if (@($parsed.ExclusionPathsAdded) -notcontains $excl) { $failures.Add('rollback missing planned exclusion') }
    if (Test-Path -LiteralPath $out3) {
        $out = Get-Content -LiteralPath $out3 -Raw | ConvertFrom-Json
        if ([string]$out.Outcome -eq 'Applied') { $failures.Add('intercepted apply outcome was Applied') }
    } else {
        $failures.Add('intercepted apply wrote no result JSON')
    }
} finally {
    Reset-InterceptEnv
}

if ($failures.Count -gt 0) {
    Write-Host '[DEFENDER-ROLLBACK] FAILED'
    foreach ($f in $failures) { Write-Host "  - $f" }
    exit 1
}

Write-Host '[DEFENDER-ROLLBACK] ALL PASSED'
exit 0
