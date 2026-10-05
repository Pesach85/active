# Proves TuneExclusions post-state without calling Add-MpPreference or Get-MpPreference.
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$hubRoot = Split-Path -Parent $scriptDir
$apply = Join-Path $scriptDir 'apply-defender-extreme-necessity.ps1'
$wizard = Join-Path $scriptDir 'gui\keep-service-wizard.ps1'
$fixture = Join-Path $hubRoot 'config\fixtures\defender-eval-apply-dryrun.json'
if (-not (Test-Path -LiteralPath $fixture)) { throw "Missing fixture: $fixture" }

$work = Join-Path $hubRoot 'logs\defender-exclusion-verify'
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
New-Item -ItemType Directory -Path $work -Force | Out-Null

$failures = New-Object System.Collections.Generic.List[string]

function Reset-ExclusionEnv {
    Remove-Item Env:HUB_DEFENDER_EXCLUSION_READBACK -ErrorAction SilentlyContinue
    Remove-Item Env:HUB_DEFENDER_MUTATION_FAIL -ErrorAction SilentlyContinue
    Remove-Item Env:HUB_DEFENDER_MUTATION_SINK -ErrorAction SilentlyContinue
    Remove-Item Env:HUB_DEFENDER_ROLLBACK_CORRUPT -ErrorAction SilentlyContinue
}

function Write-Reads {
    param([string]$Name, [object[]]$Reads)
    $path = Join-Path $work $Name
    @{ reads = @($Reads) } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding utf8
    return $path
}

function Get-RecordedAdditions {
    param([string]$RollbackPath)
    if (-not (Test-Path -LiteralPath $RollbackPath)) {
        return [pscustomobject]@{ Exists = $false; Paths = @() }
    }
    $rb = Get-Content -LiteralPath $RollbackPath -Raw | ConvertFrom-Json
    $paths = @($rb.ExclusionPathsAdded | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    return [pscustomobject]@{ Exists = $true; Paths = $paths }
}

function Invoke-ExclusionCase {
    param([string]$Name, [string[]]$Requested, [string]$ReadFile)
    $out = Join-Path $work "$Name-result.json"
    $rollback = Join-Path $work "$Name-rollback.json"
    $threw = $false
    $errorText = ''
    try {
        & $apply -EvaluationJson $fixture -OutputJson $out -Tier TuneExclusions `
            -ExclusionPaths @($Requested) -RollbackJson $rollback -IUnderstandRisk | Out-Null
    } catch {
        $threw = $true
        $errorText = $_.Exception.Message
    }
    if (-not (Test-Path -LiteralPath $out)) {
        return @{ Threw = $threw; Error = $errorText; Outcome = ''; Rollback = $rollback; Message = '' }
    }
    $doc = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json
    return @{
        Threw = $threw
        Error = $errorText
        Outcome = [string]$doc.Outcome
        Message = [string]$doc.Message
        Rollback = $rollback
    }
}

function Assert-Outcome {
    param([string]$Name, [string]$Expected, $Result)
    if ([string]$Result.Outcome -ne $Expected) {
        $failures.Add("$Name expected $Expected but was '$($Result.Outcome)' ($($Result.Error))")
    }
    if ($Expected -eq 'Applied' -and $Result.Threw) {
        $failures.Add("$Name Applied threw: $($Result.Error)")
    }
    if ($Expected -ne 'Applied' -and -not $Result.Threw) {
        $failures.Add("$Name $Expected was reported as success")
    }
}

try {
    $env:HUB_DEFENDER_EXCLUSION_READBACK = Write-Reads 'case1.json' @(
        @{ ok = $true; paths = @() },
        @{ ok = $true; paths = @('C:\Example') }
    )
    $case1 = Invoke-ExclusionCase -Name 'case1' -Requested @('C:\Example') -ReadFile $env:HUB_DEFENDER_EXCLUSION_READBACK
    Assert-Outcome -Name 'case1 absent-then-present' -Expected 'Applied' -Result $case1
    $case1Added = Get-RecordedAdditions -RollbackPath $case1.Rollback
    if (-not $case1Added.Exists -or @($case1Added.Paths).Count -ne 1 -or [string]$case1Added.Paths[0] -ne 'C:\Example') {
        $failures.Add("case1 rollback set was '$($case1Added.Paths -join ',')'")
    }

    Reset-ExclusionEnv
    $env:HUB_DEFENDER_EXCLUSION_READBACK = Write-Reads 'case2.json' @(
        @{ ok = $true; paths = @('C:\Example') },
        @{ ok = $true; paths = @('C:\Example') }
    )
    $case2 = Invoke-ExclusionCase -Name 'case2' -Requested @('C:\Example') -ReadFile $env:HUB_DEFENDER_EXCLUSION_READBACK
    Assert-Outcome -Name 'case2 already-present' -Expected 'Applied' -Result $case2
    $case2Added = Get-RecordedAdditions -RollbackPath $case2.Rollback
    if (-not $case2Added.Exists -or @($case2Added.Paths).Count -ne 0) {
        $failures.Add('case2 recorded an exclusion that already existed')
    }

    Reset-ExclusionEnv
    $env:HUB_DEFENDER_EXCLUSION_READBACK = Write-Reads 'case3.json' @(
        @{ ok = $true; paths = @() }
    )
    $env:HUB_DEFENDER_MUTATION_FAIL = '1'
    $case3 = Invoke-ExclusionCase -Name 'case3' -Requested @('C:\Example') -ReadFile $env:HUB_DEFENDER_EXCLUSION_READBACK
    Assert-Outcome -Name 'case3 mutation-failed' -Expected 'Failed' -Result $case3
    $case3Added = Get-RecordedAdditions -RollbackPath $case3.Rollback
    if (-not $case3Added.Exists -or @($case3Added.Paths).Count -ne 1 -or [string]$case3Added.Paths[0] -ne 'C:\Example') {
        $failures.Add("case3 rollback set was '$($case3Added.Paths -join ',')'")
    }

    Reset-ExclusionEnv
    $sink4 = Join-Path $work 'case4-sink.txt'
    Set-Content -LiteralPath $sink4 -Value '' -Encoding utf8
    $env:HUB_DEFENDER_MUTATION_SINK = $sink4
    $env:HUB_DEFENDER_EXCLUSION_READBACK = Write-Reads 'case4.json' @(
        @{ ok = $false; paths = @() }
    )
    $case4 = Invoke-ExclusionCase -Name 'case4' -Requested @('C:\Example') -ReadFile $env:HUB_DEFENDER_EXCLUSION_READBACK
    Assert-Outcome -Name 'case4 before-read-failed' -Expected 'PreStateUnavailable' -Result $case4
    if (Test-Path -LiteralPath $case4.Rollback) { $failures.Add('case4 wrote a rollback for unknown pre-state') }
    $sink4Body = Get-Content -LiteralPath $sink4 -Raw -ErrorAction SilentlyContinue
    if (-not [string]::IsNullOrWhiteSpace($sink4Body)) { $failures.Add('case4 mutated after a failed before-read') }

    Reset-ExclusionEnv
    $sink5 = Join-Path $work 'case5-sink.txt'
    Set-Content -LiteralPath $sink5 -Value '' -Encoding utf8
    $env:HUB_DEFENDER_MUTATION_SINK = $sink5
    $env:HUB_DEFENDER_EXCLUSION_READBACK = Write-Reads 'case5.json' @(
        @{ ok = $false; paths = @() }
    )
    $case5 = Invoke-ExclusionCase -Name 'case5' -Requested @('C:\One', 'C:\Two') -ReadFile $env:HUB_DEFENDER_EXCLUSION_READBACK
    Assert-Outcome -Name 'case5 before-read-failed-multi' -Expected 'PreStateUnavailable' -Result $case5
    if (Test-Path -LiteralPath $case5.Rollback) { $failures.Add('case5 wrote a rollback for unknown pre-state') }
    $sink5Body = Get-Content -LiteralPath $sink5 -Raw -ErrorAction SilentlyContinue
    if (-not [string]::IsNullOrWhiteSpace($sink5Body)) { $failures.Add('case5 mutated a requested path after a failed before-read') }

    Reset-ExclusionEnv
    $sink6 = Join-Path $work 'case6-sink.txt'
    Set-Content -LiteralPath $sink6 -Value '' -Encoding utf8
    $env:HUB_DEFENDER_MUTATION_SINK = $sink6
    $env:HUB_DEFENDER_EXCLUSION_READBACK = Write-Reads 'case6.json' @(
        @{ ok = $true; paths = @() },
        @{ ok = $false; paths = @() }
    )
    $case6 = Invoke-ExclusionCase -Name 'case6' -Requested @('C:\Example') -ReadFile $env:HUB_DEFENDER_EXCLUSION_READBACK
    Assert-Outcome -Name 'case6 after-read-failed' -Expected 'StateUnverified' -Result $case6
    $case6Added = Get-RecordedAdditions -RollbackPath $case6.Rollback
    if (-not $case6Added.Exists -or @($case6Added.Paths).Count -ne 1 -or [string]$case6Added.Paths[0] -ne 'C:\Example') {
        $failures.Add("case6 rollback set was '$($case6Added.Paths -join ',')'")
    }
    $sink6Body = Get-Content -LiteralPath $sink6 -Raw -ErrorAction SilentlyContinue
    if ([string]$sink6Body -notmatch 'Add-MpPreference') { $failures.Add('case6 did not attempt the exclusion after a known pre-state') }

    Reset-ExclusionEnv
    $env:HUB_DEFENDER_EXCLUSION_READBACK = Write-Reads 'case7.json' @(
        @{ ok = $true; paths = @() },
        @{ ok = $true; paths = @('C:\Other') }
    )
    $case7 = Invoke-ExclusionCase -Name 'case7' -Requested @('C:\Example') -ReadFile $env:HUB_DEFENDER_EXCLUSION_READBACK
    Assert-Outcome -Name 'case7 post-mismatch' -Expected 'StateMismatch' -Result $case7

    Reset-ExclusionEnv
    $sink8 = Join-Path $work 'case8-sink.txt'
    Set-Content -LiteralPath $sink8 -Value '' -Encoding utf8
    $env:HUB_DEFENDER_MUTATION_SINK = $sink8
    $env:HUB_DEFENDER_EXCLUSION_READBACK = Write-Reads 'case8.json' @(
        @{ ok = $true; paths = @('C:\Example') },
        @{ ok = $true; paths = @('C:\Example') }
    )
    $case8 = Invoke-ExclusionCase -Name 'case8' -Requested @('C:\Example\') -ReadFile $env:HUB_DEFENDER_EXCLUSION_READBACK
    Assert-Outcome -Name 'case8 equivalent-already-present' -Expected 'Applied' -Result $case8
    $case8Added = Get-RecordedAdditions -RollbackPath $case8.Rollback
    if (-not $case8Added.Exists -or @($case8Added.Paths).Count -ne 0) {
        $failures.Add('case8 recorded a normalization-equivalent path as newly added')
    }
    $sink8Body = Get-Content -LiteralPath $sink8 -Raw -ErrorAction SilentlyContinue
    if (-not [string]::IsNullOrWhiteSpace($sink8Body)) { $failures.Add('case8 mutated an equivalent existing path') }

    Reset-ExclusionEnv
    $env:HUB_DEFENDER_EXCLUSION_READBACK = Write-Reads 'case-near.json' @(
        @{ ok = $true; paths = @() },
        @{ ok = $true; paths = @('C:\Example2') }
    )
    $near = Invoke-ExclusionCase -Name 'near' -Requested @('C:\Example') -ReadFile $env:HUB_DEFENDER_EXCLUSION_READBACK
    Assert-Outcome -Name 'near-match' -Expected 'StateMismatch' -Result $near

    . $wizard
    $appliedMsg = Get-KeepApplyOperatorMessage -Outcome 'Applied' -Tier 'TuneExclusions' -DryRun $false -Italian $false -ExitCode 0 -HasResult $true
    $unverifiedMsg = Get-KeepApplyOperatorMessage -Outcome 'StateUnverified' -Tier 'TuneExclusions' -DryRun $false -Italian $false -ExitCode 1 -HasResult $true
    $failedMsg = Get-KeepApplyOperatorMessage -Outcome 'Failed' -Tier 'TuneExclusions' -DryRun $false -Italian $false -ExitCode 1 -HasResult $true
    $mismatchMsg = Get-KeepApplyOperatorMessage -Outcome 'StateMismatch' -Tier 'TuneExclusions' -DryRun $false -Italian $false -ExitCode 1 -HasResult $true
    $preStateMsg = Get-KeepApplyOperatorMessage -Outcome 'PreStateUnavailable' -Tier 'TuneExclusions' -DryRun $false -Italian $false -ExitCode 1 -HasResult $true
    if ($appliedMsg.Text -ne 'The exclusion is active.' -or -not $appliedMsg.Success) {
        $failures.Add("GUI Applied text was '$($appliedMsg.Text)'")
    }
    if ($unverifiedMsg.Text -match 'failed' -or $unverifiedMsg.Icon -ne 'Warning' -or $unverifiedMsg.Success) {
        $failures.Add("GUI StateUnverified was not a non-success warning: $($unverifiedMsg.Text)")
    }
    if ($failedMsg.Text -ne 'The exclusion could not be applied.' -or $failedMsg.Icon -ne 'Error') {
        $failures.Add("GUI Failed text was '$($failedMsg.Text)'")
    }
    if ($mismatchMsg.Text -eq 'The exclusion is active.' -or $mismatchMsg.Success) {
        $failures.Add('GUI StateMismatch was presented as applied')
    }
    if ($preStateMsg.Text -match 'failed' -or $preStateMsg.Text -match 'verified' -or $preStateMsg.Success -or $preStateMsg.Text -notmatch 'no exclusion was changed') {
        $failures.Add("GUI PreStateUnavailable text was '$($preStateMsg.Text)'")
    }
} finally {
    Reset-ExclusionEnv
}

if ($failures.Count -gt 0) {
    Write-Host '[DEFENDER-EXCLUSION] FAILED'
    foreach ($f in $failures) { Write-Host "  - $f" }
    exit 1
}

Write-Host '[DEFENDER-EXCLUSION] ALL PASSED'
exit 0
