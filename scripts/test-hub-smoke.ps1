<#
.SYNOPSIS
  Deterministic smoke gate for hub engines (no GUI). Exit 0 only if all pass.
.DESCRIPTION
  Validates health-audit, garbage-hotspots, and privacy-scan produce parseable output.
  Does not apply fixes or delete files.
#>
[CmdletBinding()]
param(
    [string]$HubRoot,
    [switch]$SkipPrivacy
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $HubRoot) {
    $HubRoot = Split-Path -Parent $scriptDir
}

$logs = Join-Path $HubRoot 'logs'
if (-not (Test-Path -LiteralPath $logs)) {
    New-Item -Path $logs -ItemType Directory -Force | Out-Null
}

$pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
$pwsh = if ($pwshCmd) { $pwshCmd.Path } else { (Get-Command powershell).Path }

$failures = [System.Collections.Generic.List[string]]::new()

function Invoke-SmokeStep {
    param(
        [string]$Name,
        [string]$ScriptPath,
        [string[]]$Arguments,
        [string]$OutputPath,
        [scriptblock]$Validate
    )

    Write-Host ("[SMOKE] {0}..." -f $Name)
    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        $failures.Add("$Name missing script: $ScriptPath")
        return
    }

    if (Test-Path -LiteralPath $OutputPath) {
        Remove-Item -LiteralPath $OutputPath -Force -ErrorAction SilentlyContinue
    }

    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + $Arguments
    $p = Start-Process -FilePath $pwsh -ArgumentList $argList -Wait -PassThru -WindowStyle Hidden
    if ($p.ExitCode -ne 0) {
        $failures.Add("$Name exit $($p.ExitCode)")
        return
    }

    if (-not (Test-Path -LiteralPath $OutputPath)) {
        $failures.Add("$Name missing output: $OutputPath")
        return
    }

    try {
        & $Validate $OutputPath
        Write-Host ("[SMOKE] {0} OK" -f $Name)
    } catch {
        $failures.Add("$Name validate failed: $($_.Exception.Message)")
    }
}

$healthOut = Join-Path $logs 'smoke-health.json'
Invoke-SmokeStep -Name 'health-audit' `
    -ScriptPath (Join-Path $scriptDir 'system-health-audit.ps1') `
    -Arguments @('-OutputJson', $healthOut) `
    -OutputPath $healthOut `
    -Validate {
        param($path)
        $j = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ($null -eq $j.Findings) { throw 'Findings missing' }
        if ($null -eq $j.AlreadyOptimized) { throw 'AlreadyOptimized missing' }
        if ($null -eq $j.Summary) { throw 'Summary missing' }
        # AlreadyOptimized must be strings (not objects with .Id) — GUI contract
        $sample = @($j.AlreadyOptimized) | Select-Object -First 1
        if ($null -ne $sample -and $sample -isnot [string] -and $sample.PSObject.Properties['Id']) {
            throw 'AlreadyOptimized entries look like objects with Id (unexpected schema)'
        }
    }

$garbageCsv = Join-Path $logs 'smoke-garbage.csv'
Invoke-SmokeStep -Name 'garbage-hotspots' `
    -ScriptPath (Join-Path $scriptDir 'analyze-garbage-hotspots.ps1') `
    -Arguments @('-Depth', 'Quick', '-Top', '5', '-OutputCsv', $garbageCsv, '-Drives', 'C') `
    -OutputPath $garbageCsv `
    -Validate {
        param($path)
        $rows = Import-Csv -LiteralPath $path
        if (@($rows).Count -lt 1) { throw 'CSV empty' }
        $cols = $rows[0].PSObject.Properties.Name
        foreach ($need in @('Score', 'Path', 'EstimatedReclaimGB')) {
            if ($cols -notcontains $need) { throw "Missing column $need" }
        }
    }

if (-not $SkipPrivacy) {
    $privacyOut = Join-Path $logs 'smoke-privacy.json'
    Invoke-SmokeStep -Name 'privacy-scan' `
        -ScriptPath (Join-Path $scriptDir 'privacy-scan-secrets.ps1') `
        -Arguments @('-OutputJson', $privacyOut) `
        -OutputPath $privacyOut `
        -Validate {
            param($path)
            $j = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $schema = [string]$j.SchemaVersion
            if ($schema -notmatch 'PrivacyScanReport') { throw "Unexpected schema: $schema" }
            if ($null -eq $j.Findings) { throw 'Findings missing' }
        }
}

# Module presence (GUI modularization gate)
foreach ($mod in @('gui\theme.ps1', 'gui\worker-helpers.ps1', 'gui\async-worker.ps1', 'gui\i18n.ps1', 'gui\command-help.ps1')) {
    $p = Join-Path $scriptDir $mod
    if (-not (Test-Path -LiteralPath $p)) {
        $failures.Add("Missing module: $mod")
    }
}

# Async-worker StrictMode / unset-variable regression (Bug 28 / EXE HubWorkers)
Write-Host '[SMOKE] async-worker-registry...'
try {
    $hubCommon = Join-Path $scriptDir 'hub-common.ps1'
    $workerHelpers = Join-Path $scriptDir 'gui\worker-helpers.ps1'
    $asyncWorker = Join-Path $scriptDir 'gui\async-worker.ps1'
    $probeScript = Join-Path $logs 'smoke-async-worker-probe.ps1'
    @'
param([string]$HubCommon, [string]$WorkerHelpers, [string]$AsyncWorker)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. $HubCommon
. $WorkerHelpers
. $AsyncWorker
Initialize-HubWorkerRegistry
if (-not (Test-Path variable:global:HubWorkers)) { throw "global HubWorkers missing after init" }
if ((Test-AnyHubAsyncWorkerRunning) -ne $false) { throw "expected no running workers" }
if ($null -ne (Get-HubAsyncWorker -Name "does-not-exist")) { throw "expected null for missing worker" }
# Re-read under StrictMode without prior assignment in THIS scope (global must exist)
$null = $global:HubWorkers.Count
Write-Output "OK"
'@ | Set-Content -LiteralPath $probeScript -Encoding utf8
    $p = Start-Process -FilePath $pwsh -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $probeScript,
        '-HubCommon', $hubCommon,
        '-WorkerHelpers', $workerHelpers,
        '-AsyncWorker', $asyncWorker
    ) -Wait -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $logs 'smoke-async-worker.out.log') -RedirectStandardError (Join-Path $logs 'smoke-async-worker.err.log')
    $outText = ''
    if (Test-Path (Join-Path $logs 'smoke-async-worker.out.log')) {
        $outText = Get-Content (Join-Path $logs 'smoke-async-worker.out.log') -Raw
    }
    $errText = ''
    if (Test-Path (Join-Path $logs 'smoke-async-worker.err.log')) {
        $errText = Get-Content (Join-Path $logs 'smoke-async-worker.err.log') -Raw
    }
    if ($p.ExitCode -ne 0 -or $outText -notmatch 'OK') {
        $failures.Add(("async-worker-registry failed exit={0} out={1} err={2}" -f $p.ExitCode, $outText.Trim(), $errText.Trim()))
    } else {
        Write-Host '[SMOKE] async-worker-registry OK'
    }
} catch {
    $failures.Add(("async-worker-registry exception: {0}" -f $_.Exception.Message))
}

$pressureOut = Join-Path $logs 'smoke-process-pressure.json'
Invoke-SmokeStep -Name 'process-pressure' `
    -ScriptPath (Join-Path $scriptDir 'analyze-process-pressure.ps1') `
    -Arguments @('-DurationSec', '2', '-Top', '5', '-OutputJson', $pressureOut) `
    -OutputPath $pressureOut `
    -Validate {
        param($path)
        $j = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $schema = [string]$j.SchemaVersion
        if ($schema -notmatch 'ProcessPressureReport') { throw "Unexpected schema: $schema" }
        if ($null -eq $j.TopProcesses) { throw 'TopProcesses missing' }
        if ($null -eq $j.Summary) { throw 'Summary missing' }
        $sample = @($j.TopProcesses) | Select-Object -First 1
        if ($null -ne $sample -and -not $sample.PSObject.Properties['DominantPressure']) {
            throw 'TopProcesses missing DominantPressure'
        }
    }

if ($failures.Count -gt 0) {
    Write-Host '[SMOKE] FAILED'
    $failures | ForEach-Object { Write-Host ("  - {0}" -f $_) }
    exit 1
}

Write-Host '[SMOKE] ALL PASSED'
exit 0
