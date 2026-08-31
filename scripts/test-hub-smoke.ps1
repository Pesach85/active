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
foreach ($mod in @('gui\theme.ps1', 'gui\worker-helpers.ps1', 'gui\async-worker.ps1', 'gui\i18n.ps1', 'gui\command-help.ps1', 'gui\keep-service-wizard.ps1')) {
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

$optCtx = Join-Path $logs 'smoke-optimization-context.json'
Invoke-SmokeStep -Name 'optimization-context' `
    -ScriptPath (Join-Path $scriptDir 'build-optimization-context.ps1') `
    -Arguments @('-OutputJson', $optCtx) `
    -OutputPath $optCtx `
    -Validate {
        param($path)
        $j = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ([string]$j.SchemaVersion -notmatch 'OptimizationContext') { throw 'Unexpected schema' }
        if ($null -eq $j.Host.Tier) { throw 'Host.Tier missing' }
        if ($null -eq $j.RecommendedCadence) { throw 'RecommendedCadence missing' }
    }

$transparencyOut = Join-Path $logs 'smoke-transparency.json'
Invoke-SmokeStep -Name 'transparency-report' `
    -ScriptPath (Join-Path $scriptDir 'build-transparency-report.ps1') `
    -Arguments @('-OutputJson', $transparencyOut) `
    -OutputPath $transparencyOut `
    -Validate {
        param($path)
        $j = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ([string]$j.SchemaVersion -notmatch 'TransparencyReport') { throw 'Unexpected schema' }
        if ($null -eq $j.Posture.Score) { throw 'Posture.Score missing' }
        if ($null -eq $j.DelegationManifest) { throw 'DelegationManifest missing' }
        if ($null -eq $j.Network) { throw 'Network section missing' }
    }

$pkOut = Join-Path $logs 'smoke-process-knowledge.json'
Invoke-SmokeStep -Name 'process-knowledge' `
    -ScriptPath (Join-Path $scriptDir 'enrich-process-classification.ps1') `
    -Arguments @('-ProcessNames', 'mysqld,vmware-vmx,chrome', '-Offline', '-OutputJson', $pkOut, '-Quiet') `
    -OutputPath $pkOut `
    -Validate {
        param($path)
        $j = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ([string]$j.SchemaVersion -ne 'ProcessClassificationEnrichment.v1') { throw 'Unexpected schema' }
        if (@($j.ClassificationHints).Count -lt 3) { throw 'Expected 3 hints' }
        $mysql = @($j.ClassificationHints | Where-Object { $_.ProcessName -match 'mysqld' } | Select-Object -First 1)
        if (-not $mysql) { throw 'mysqld hint missing' }
        if ([double]$mysql.Confidence -lt 0.9) { throw 'mysqld cache confidence too low' }
        if ([string]$mysql.SuggestedCategory -notmatch 'Database') { throw 'mysqld category wrong' }
        $chrome = @($j.ClassificationHints | Where-Object { $_.ProcessName -match 'chrome' } | Select-Object -First 1)
        if ([double]$chrome.Confidence -lt 0.95) { throw 'chrome catalog hint expected' }
    }

$ppiHintsOut = Join-Path $logs 'smoke-ppi-hints.json'
Invoke-SmokeStep -Name 'process-pressure-hints' `
    -ScriptPath (Join-Path $scriptDir 'analyze-process-pressure.ps1') `
    -Arguments @('-DurationSec', '2', '-Top', '5', '-IncludeClassificationHints', '-OfflineHints', '-OutputJson', $ppiHintsOut) `
    -OutputPath $ppiHintsOut `
    -Validate {
        param($path)
        $j = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ([string]$j.SchemaVersion -notmatch 'ProcessPressureReport') { throw 'Unexpected PPI schema' }
        if ($null -eq $j.ClassificationHints) { throw 'ClassificationHints missing on PPI report' }
    }

$resAdvOut = Join-Path $logs 'smoke-process-resolution.json'
Invoke-SmokeStep -Name 'process-resolution-advisory' `
    -ScriptPath (Join-Path $scriptDir 'resolve-unknown-process.ps1') `
    -Arguments @('-ProcessName', 'TotallyUnknownProcessXYZ', '-Action', 'Advisory', '-Offline', '-OutputJson', $resAdvOut, '-Quiet') `
    -OutputPath $resAdvOut `
    -Validate {
        param($path)
        $j = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ([string]$j.SchemaVersion -notmatch 'ProcessResolutionResult') { throw 'Unexpected schema' }
        if ([string]$j.Advisory.RecommendedActionId -notin @('Observe', 'ThrottleBelowNormal')) { throw 'Unexpected recommendation for unknown' }
        if (-not $j.Advisory.RequiresOperatorApproval) { throw 'RequiresOperatorApproval must be true' }
    }

$failTerminate = Join-Path $logs 'smoke-res-fail.json'
if (Test-Path $failTerminate) { Remove-Item $failTerminate -Force }
Write-Host '[SMOKE] process-resolution-block-terminate...'
$pFail = Start-Process -FilePath $pwsh -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $scriptDir 'resolve-unknown-process.ps1'),
    '-ProcessName', 'TotallyUnknownProcessXYZ', '-Action', 'Terminate', '-ConfirmPhrase', 'WRONG', '-Offline', '-Quiet'
) -Wait -PassThru -WindowStyle Hidden
if ($pFail.ExitCode -eq 0) { $failures.Add('process-resolution-block-terminate should fail with wrong phrase') }
else { Write-Host '[SMOKE] process-resolution-block-terminate OK' }

$knownAdv = Join-Path $logs 'smoke-res-mysqld.json'
Invoke-SmokeStep -Name 'process-resolution-known' `
    -ScriptPath (Join-Path $scriptDir 'resolve-unknown-process.ps1') `
    -Arguments @('-ProcessName', 'mysqld', '-Action', 'Advisory', '-Offline', '-OutputJson', $knownAdv, '-Quiet') `
    -OutputPath $knownAdv `
    -Validate {
        param($path)
        $j = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ([string]$j.Advisory.RecommendedActionId -eq 'Terminate') { throw 'Should not recommend terminate for known mysqld' }
    }

$idOut = Join-Path $logs 'smoke-process-identify.json'
Invoke-SmokeStep -Name 'process-identify-manual' `
    -ScriptPath (Join-Path $scriptDir 'identify-unknown-process.ps1') `
    -Arguments @('-ProcessName', 'SmokeTestProcXYZ', '-WhatItIs', 'SmokeTestProcess', '-WhatItDoes', 'ValidatesManualIdentify', '-SuggestedCategory', 'Other', '-SuggestedPriority', 'Review', '-SkipAuth', '-OutputJson', $idOut, '-Quiet') `
    -OutputPath $idOut `
    -Validate {
        param($path)
        $j = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ([string]$j.Outcome -ne 'Identified') { throw 'Expected Identified outcome' }
        if (-not $j.CatalogMerge.Skipped) { throw 'Expected catalog merge skipped with SkipAuth' }
    }

Write-Host '[SMOKE] process-catalog-merge...'
. (Join-Path $scriptDir 'lib\process-knowledge.ps1')
. (Join-Path $scriptDir 'lib\process-catalog-merge.ps1')
$smokeCatName = 'SmokeCatalogMergeXYZ'
$smokeEntry = [ordered]@{
    ProcessName = $smokeCatName
    WhatItIs = 'Smoke catalog merge validation process'
    WhatItDoes = 'Ensures identify pipeline can write process-intelligence catalog entries'
    SuggestedCategory = 'Other'
    SuggestedPriority = 'Review'
    ResourceProfile = 'Mixed'
    BusinessHint = 'Smoke test entry - safe to remove'
}
$smokeHint = [ordered]@{
    WhatItIs = $smokeEntry.WhatItIs
    WhatItDoes = $smokeEntry.WhatItDoes
    SuggestedCategory = 'Other'
    SuggestedPriority = 'Review'
    ResourceProfile = 'Mixed'
    BusinessHint = $smokeEntry.BusinessHint
    Sources = @('smoke-test')
    SuggestedCatalogEntry = [ordered]@{
        category = 'Other'
        priority = 'Review'
        displayName = $smokeCatName
        description = $smokeEntry.WhatItIs
        resourceProfile = 'Mixed'
        pressureMitigations = [ordered]@{
            MemoryHeavy = @("Review smoke test process $smokeCatName")
        }
        references = @()
    }
}
$catDraft = Build-CatalogEntryFromSources -ProcessName $smokeCatName -Hint $smokeHint -CacheEntry $smokeEntry
$catPath = Join-Path $HubRoot 'config\process-intelligence.json'
$mergeResult = Merge-ProcessIntoIntelligenceCatalog -HubRoot $HubRoot -ProcessName $smokeCatName -CatalogEntry $catDraft -CatalogPath $catPath -Confidence 0.98
if (-not $mergeResult.Ok) { $failures.Add("process-catalog-merge: $($mergeResult.Reason)") }
else {
    $cat = Get-Content -LiteralPath $catPath -Raw | ConvertFrom-Json
    $hit = $cat.knownApplications.PSObject.Properties[$smokeCatName.ToLowerInvariant()]
    if (-not $hit) { $hit = $cat.knownApplications.PSObject.Properties[$smokeCatName] }
    if (-not $hit) { $failures.Add('process-catalog-merge: entry not found in catalog') }
    else { Write-Host '[SMOKE] process-catalog-merge OK' }
}

$dryRunOut = Join-Path $logs 'smoke-res-dryrun-missing.json'
Invoke-SmokeStep -Name 'process-resolution-dryrun-missing' `
    -ScriptPath (Join-Path $scriptDir 'resolve-unknown-process.ps1') `
    -Arguments @('-ProcessId', '1234', '-Action', 'ThrottleBelowNormal', '-DryRun', '-OutputJson', $dryRunOut, '-Quiet') `
    -OutputPath $dryRunOut `
    -Validate {
        param($path)
        $j = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ([string]$j.Outcome -ne 'ProcessNotRunning') { throw "Expected ProcessNotRunning got $($j.Outcome)" }
    }


$forensicsOut = Join-Path $logs 'smoke-forensics.json'
Write-Host '[SMOKE] process-forensics...'
. (Join-Path $scriptDir 'lib\process-forensics.ps1')
$selfProc = Get-Process -Id $PID
$fp = Get-ProcessForensicProfile -ProcessId $PID -ProcessName $selfProc.ProcessName -ImagePath $selfProc.Path -HubRoot $HubRoot -Deep
($fp | ConvertTo-Json -Depth 8) | Out-File -LiteralPath $forensicsOut -Encoding utf8
if (-not $fp.PeHeader) { $failures.Add('process-forensics: missing PE header') } else { Write-Host '[SMOKE] process-forensics OK' }

Write-Host '[SMOKE] transparency-web-ensure...'
$pWeb = Start-Process -FilePath $pwsh -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $scriptDir 'ensure-transparency-web.ps1'), '-Quiet'
) -Wait -PassThru -WindowStyle Hidden
if ($pWeb.ExitCode -ne 0) { $failures.Add('transparency-web-ensure failed to start') }
else {
    try {
        $h = Invoke-WebRequest -Uri 'http://127.0.0.1:8765/api/health' -TimeoutSec 5 -UseBasicParsing
        if ($h.StatusCode -ne 200) { $failures.Add('transparency-web health not 200') }
        else {
            Write-Host '[SMOKE] transparency-web-ensure OK'
            try {
                $advBody = @{ processId = $PID; processName = (Get-Process -Id $PID).ProcessName; offline = $true } | ConvertTo-Json
                $adv = Invoke-WebRequest -Uri 'http://127.0.0.1:8765/api/process/advisory' -Method POST `
                    -Body $advBody -ContentType 'application/json' -TimeoutSec 30 -UseBasicParsing
                if ($adv.StatusCode -ne 200) { $failures.Add('transparency-web advisory not 200') }
                else {
                    $advJson = $adv.Content | ConvertFrom-Json
                    if (-not $advJson.KnowledgeHint) { $failures.Add('transparency-web advisory missing KnowledgeHint') }
                    else { Write-Host '[SMOKE] transparency-web-advisory OK' }
                }
            } catch { $failures.Add("transparency-web advisory: $($_.Exception.Message)") }
        }
    } catch { $failures.Add("transparency-web health: $($_.Exception.Message)") }
}

$defenderEval = Join-Path $logs 'smoke-defender-eval.json'
Invoke-SmokeStep -Name 'defender-extreme-eval' `
    -ScriptPath (Join-Path $scriptDir 'evaluate-defender-extreme-necessity.ps1') `
    -Arguments @('-OutputJson', $defenderEval) `
    -OutputPath $defenderEval `
    -Validate {
        param($path)
        $j = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ([string]$j.SchemaVersion -notmatch 'DefenderExtremeNecessityEvaluation') { throw 'Unexpected schema' }
        if ($null -eq $j.RecommendedTier) { throw 'RecommendedTier missing' }
        if ($null -eq $j.CompositeScore) { throw 'CompositeScore missing' }
    }

if ($failures.Count -gt 0) {
    Write-Host '[SMOKE] FAILED'
    $failures | ForEach-Object { Write-Host ("  - {0}" -f $_) }
    exit 1
}

Write-Host '[SMOKE] ALL PASSED'
exit 0
