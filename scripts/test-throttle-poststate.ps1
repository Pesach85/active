# Proves throttle post-state without changing a real process priority.
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$hubRoot = Split-Path -Parent $scriptDir
$resolve = Join-Path $scriptDir 'resolve-unknown-process.ps1'
$wizard = Join-Path $scriptDir 'gui\unknown-process-wizard.ps1'
$work = Join-Path $hubRoot 'logs\throttle-poststate'
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
New-Item -ItemType Directory -Path $work -Force | Out-Null

$failures = New-Object System.Collections.Generic.List[string]

function Reset-ThrottleEnv {
    Remove-Item Env:HUB_THROTTLE_SIMULATION -ErrorAction SilentlyContinue
}

function Write-Sim {
    param([string]$Name, [hashtable]$Body)
    $path = Join-Path $work $Name
    $Body | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $path -Encoding utf8
    return $path
}

function Invoke-ThrottleCase {
    param([string]$Name, [string]$SimFile, [switch]$DryRun)
    $out = Join-Path $work "$Name-result.json"
    $args = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $resolve,
        '-ProcessId', '4242', '-ProcessName', 'ok', '-Action', 'ThrottleBelowNormal',
        '-SkipAuth', '-Offline', '-Quiet', '-OutputJson', $out, '-HubRoot', $hubRoot
    )
    if ($DryRun) { $args += '-DryRun' }
    $env:HUB_THROTTLE_SIMULATION = $SimFile
    & powershell.exe @args | Out-Null
    $code = $LASTEXITCODE
    $doc = $null
    if (Test-Path -LiteralPath $out) {
        $doc = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json
    }
    return @{ ExitCode = $code; Outcome = $(if ($doc) { [string]$doc.Outcome } else { '' }); Message = $(if ($doc) { [string]$doc.Message } else { '' }) }
}

function Assert-Case {
    param([string]$Name, [string]$Expected, [int]$ExitCode, $Result)
    if ([string]$Result.Outcome -ne $Expected) {
        $failures.Add("$Name expected $Expected but was '$($Result.Outcome)'")
    }
    if ($Expected -eq 'Throttled' -or $Expected -eq 'DryRunThrottle') {
        if ([int]$Result.ExitCode -ne 0) { $failures.Add("$Name exit was $($Result.ExitCode)") }
    } elseif ([int]$Result.ExitCode -eq 0) {
        $failures.Add("$Name non-success exited 0")
    }
    if ($Expected -ne 'Throttled' -and [string]$Result.Message -match 'Priority set BelowNormal') {
        $failures.Add("$Name claimed an unproven priority set")
    }
}

$base = @{
    pid = 4242
    name = 'ok'
    beforePriority = 'Normal'
    path = 'C:\ok.exe'
    mutateFails = $false
    postOk = $true
    identityMatch = $true
    priority = 'BelowNormal'
}

try {
    $case1 = Invoke-ThrottleCase -Name 'case1' -SimFile (Write-Sim 'case1.json' $base)
    Assert-Case -Name 'case1 proven' -Expected 'Throttled' -Result $case1
    if ($case1.Message -notmatch 'Below Normal') { $failures.Add("case1 message was '$($case1.Message)'") }

    Reset-ThrottleEnv
    $mismatch = $base.Clone()
    $mismatch.priority = 'Normal'
    $case2 = Invoke-ThrottleCase -Name 'case2' -SimFile (Write-Sim 'case2.json' $mismatch)
    Assert-Case -Name 'case2 still-normal' -Expected 'StateMismatch' -Result $case2

    Reset-ThrottleEnv
    $unread = $base.Clone()
    $unread.postOk = $false
    $case3 = Invoke-ThrottleCase -Name 'case3' -SimFile (Write-Sim 'case3.json' $unread)
    Assert-Case -Name 'case3 read-failed' -Expected 'StateUnverified' -Result $case3

    Reset-ThrottleEnv
    $gone = $base.Clone()
    $gone.postOk = $false
    $case4 = Invoke-ThrottleCase -Name 'case4' -SimFile (Write-Sim 'case4.json' $gone)
    Assert-Case -Name 'case4 process-gone' -Expected 'StateUnverified' -Result $case4

    Reset-ThrottleEnv
    $reuse = $base.Clone()
    $reuse.identityMatch = $false
    $case5 = Invoke-ThrottleCase -Name 'case5' -SimFile (Write-Sim 'case5.json' $reuse)
    Assert-Case -Name 'case5 pid-reuse' -Expected 'PidIdentityMismatch' -Result $case5

    Reset-ThrottleEnv
    $failed = $base.Clone()
    $failed.mutateFails = $true
    $case6 = Invoke-ThrottleCase -Name 'case6' -SimFile (Write-Sim 'case6.json' $failed)
    Assert-Case -Name 'case6 mutation-failed' -Expected 'PidIdentityMismatch' -Result $case6

    Reset-ThrottleEnv
    $case7 = Invoke-ThrottleCase -Name 'case7' -SimFile (Write-Sim 'case7.json' $base) -DryRun
    Assert-Case -Name 'case7 dry-run' -Expected 'DryRunThrottle' -Result $case7

    Reset-ThrottleEnv
    $already = $base.Clone()
    $already.beforePriority = 'BelowNormal'
    $case8 = Invoke-ThrottleCase -Name 'case8' -SimFile (Write-Sim 'case8.json' $already)
    Assert-Case -Name 'case8 already-below' -Expected 'Throttled' -Result $case8

    . $wizard
    $ok = Get-ThrottleApplyOperatorMessage -Outcome 'Throttled' -Italian $false
    $unverified = Get-ThrottleApplyOperatorMessage -Outcome 'StateUnverified' -Italian $false
    $mismatchMsg = Get-ThrottleApplyOperatorMessage -Outcome 'StateMismatch' -Italian $false
    if (-not $ok.Success -or $ok.Text -ne 'Process priority was changed to Below Normal.') {
        $failures.Add("GUI success text was '$($ok.Text)'")
    }
    if ($unverified.Success -or $unverified.Icon -ne 'Warning' -or $unverified.Text -match 'failed' -or $unverified.Text -match 'Below Normal') {
        $failures.Add("GUI unverified text was '$($unverified.Text)'")
    }
    if ($mismatchMsg.Success -or $mismatchMsg.Text -ne 'The process priority did not reach the requested state.') {
        $failures.Add("GUI mismatch text was '$($mismatchMsg.Text)'")
    }
} finally {
    Reset-ThrottleEnv
}

if ($failures.Count -gt 0) {
    Write-Host '[THROTTLE-POSTSTATE] FAILED'
    foreach ($f in $failures) { Write-Host "  - $f" }
    exit 1
}

Write-Host '[THROTTLE-POSTSTATE] ALL PASSED'
exit 0
