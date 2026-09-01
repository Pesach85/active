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

$cliProject = Join-Path $HubRoot 'src\SystemOptimizerHub.Cli\SystemOptimizerHub.Cli.csproj'

Write-Host '[SMOKE] dotnet build hub CLI (once)...'
dotnet build $cliProject -v q --nologo
if ($LASTEXITCODE -ne 0) { throw 'dotnet build hub CLI failed' }

$pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
$pwsh = if ($pwshCmd) { $pwshCmd.Path } else { (Get-Command powershell).Path }

function Invoke-HubCliSmoke {
    param([string[]]$CliArgs, [string]$OutFile)
    $errFile = Join-Path $HubRoot 'logs\smoke-hub-cli.err'
    $allArgs = @('run', '--project', $cliProject, '--no-build', '-v', 'q', '--') + $CliArgs
    $p = Start-Process -FilePath 'dotnet' -ArgumentList $allArgs -Wait -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $OutFile -RedirectStandardError $errFile
    return $p.ExitCode
}

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
foreach ($mod in @('gui\theme.ps1', 'gui\worker-helpers.ps1', 'gui\async-worker.ps1', 'gui\i18n.ps1', 'gui\command-help.ps1', 'gui\keep-service-wizard.ps1', 'gui\transparency-panel.ps1', 'gui\unknown-process-wizard.ps1')) {
    $p = Join-Path $scriptDir $mod
    if (-not (Test-Path -LiteralPath $p)) {
        $failures.Add("Missing module: $mod")
    }
}

Write-Host '[SMOKE] gui-parse-ps51...'
$guiParseScript = Join-Path $scriptDir 'test-gui-parse-ps51.ps1'
$ps51 = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Path
if (-not $ps51) { $ps51 = 'powershell.exe' }
$pGuiParse = Start-Process -FilePath $ps51 -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $guiParseScript
) -Wait -PassThru -WindowStyle Hidden
if ($pGuiParse.ExitCode -ne 0) { $failures.Add('gui-parse-ps51 failed') }
else { Write-Host '[SMOKE] gui-parse-ps51 OK' }

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

# Transparency tab StrictMode / unset $tab regression (Bug 31 / EXE Refresh on Shown)
Write-Host '[SMOKE] transparency-panel-registry...'
try {
    $hubCommonTp = Join-Path $scriptDir 'hub-common.ps1'
    $themeTp = Join-Path $scriptDir 'gui\theme.ps1'
    $panelTp = Join-Path $scriptDir 'gui\transparency-panel.ps1'
    $probeTp = Join-Path $logs 'smoke-transparency-panel-probe.ps1'
    @'
param([string]$HubCommon, [string]$Theme, [string]$Panel)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. $HubCommon
. $Theme
. $Panel
if (-not (Get-Command Get-HubTransparencyPanel -ErrorAction SilentlyContinue)) {
    throw "Get-HubTransparencyPanel missing"
}
$tmp = Join-Path $env:TEMP ("hub-tp-smoke-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $tmp "logs") -Force | Out-Null
$cfg = Join-Path $tmp "config.json"
"{}" | Set-Content -LiteralPath $cfg -Encoding utf8
$ui = New-TransparencyTab -HubRoot $tmp -ScriptRoot $tmp -ConfigPath $cfg -OnStatus { param($m) } -TestBusy { $false }
if ($null -eq $ui -or $null -eq $ui.Tab -or $null -eq $ui.Refresh) { throw "New-TransparencyTab returned incomplete UI" }
Remove-Variable -Name tab -ErrorAction SilentlyContinue
Set-StrictMode -Version Latest
& $ui.Refresh
$st = Get-HubTransparencyPanel
if ($null -eq $st) { throw "global HubTransparencyPanel missing after New-TransparencyTab" }
if ($null -eq $st.Tab) { throw "panel Tab missing" }
$c = & $st.GetTrustColor "T0_Observed"
if ($null -eq $c) { throw "GetTrustColor returned null" }
$fake = [pscustomobject]@{
    Posture = [pscustomobject]@{ Score = 80; Grade = 'Good' }
    RegisteredAgents = @()
    RamConsumers = @()
    DelegationManifest = [pscustomobject]@{
        Principles = @('p')
        HumanOnly = @('h')
        AiDelegatedWhenEnabled = @('d')
    }
    RecentAutomatedActions = @()
    UnknownHighRam = @()
}
& $st.ShowReport $fake
if ($st.LblPosture.Text -notmatch '80') { throw "ShowReport did not update posture" }
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Output "OK"
'@ | Set-Content -LiteralPath $probeTp -Encoding utf8
    $pTp = Start-Process -FilePath $ps51 -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $probeTp,
        '-HubCommon', $hubCommonTp,
        '-Theme', $themeTp,
        '-Panel', $panelTp
    ) -Wait -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $logs 'smoke-transparency-panel.out.log') -RedirectStandardError (Join-Path $logs 'smoke-transparency-panel.err.log')
    $outTp = ''
    if (Test-Path (Join-Path $logs 'smoke-transparency-panel.out.log')) {
        $outTp = Get-Content (Join-Path $logs 'smoke-transparency-panel.out.log') -Raw
    }
    $errTp = ''
    if (Test-Path (Join-Path $logs 'smoke-transparency-panel.err.log')) {
        $errTp = Get-Content (Join-Path $logs 'smoke-transparency-panel.err.log') -Raw
    }
    if ($pTp.ExitCode -ne 0 -or $outTp -notmatch 'OK') {
        $failures.Add(("transparency-panel-registry failed exit={0} out={1} err={2}" -f $pTp.ExitCode, $outTp.Trim(), $errTp.Trim()))
    } else {
        Write-Host '[SMOKE] transparency-panel-registry OK'
    }
} catch {
    $failures.Add(("transparency-panel-registry exception: {0}" -f $_.Exception.Message))
}

$startupIntegrityOut = Join-Path $logs 'smoke-startup-integrity.json'
Invoke-SmokeStep -Name 'startup-integrity' `
    -ScriptPath (Join-Path $scriptDir 'audit-startup-integrity.ps1') `
    -Arguments @('-OutputJson', $startupIntegrityOut, '-HubRoot', $HubRoot) `
    -OutputPath $startupIntegrityOut `
    -Validate {
        param($path)
        $j = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ([string]$j.SchemaVersion -notmatch 'StartupIntegrityReport') { throw "Unexpected schema: $($j.SchemaVersion)" }
        if ($null -eq $j.Summary) { throw 'Summary missing' }
        if ($null -eq $j.Items) { throw 'Items missing' }
        if (-not $j.PSObject.Properties['HubRoot']) { throw 'HubRoot missing' }
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

$liveObserveOut = Join-Path $logs 'smoke-res-live-observe.json'
$liveProc = Get-Process -Id $PID
Invoke-SmokeStep -Name 'process-resolution-live-observe' `
    -ScriptPath (Join-Path $scriptDir 'resolve-unknown-process.ps1') `
    -Arguments @('-ProcessId', ([string]$liveProc.Id), '-ProcessName', $liveProc.ProcessName, '-Action', 'Observe', '-SkipAuth', '-Offline', '-OutputJson', $liveObserveOut, '-Quiet') `
    -OutputPath $liveObserveOut `
    -Validate {
        param($path)
        $j = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ([string]$j.Outcome -ne 'Observed') { throw "Expected Observed on live process, got $($j.Outcome)" }
        if ($j.Process.PSObject.Properties['NotRunning'] -and $j.Process.NotRunning) { throw 'Live snapshot must not be NotRunning' }
    }

$keepAdvOut = Join-Path $logs 'smoke-res-keep-advisory.json'
Invoke-SmokeStep -Name 'process-resolution-keep-advisory' `
    -ScriptPath (Join-Path $scriptDir 'resolve-unknown-process.ps1') `
    -Arguments @('-ProcessName', 'MsMpEng', '-Action', 'Advisory', '-Offline', '-OutputJson', $keepAdvOut, '-Quiet') `
    -OutputPath $keepAdvOut `
    -Validate {
        param($path)
        $j = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ([string]$j.CatalogNecessity.Priority -ne 'Keep') { throw 'MsMpEng must be Priority=Keep' }
        $blocked = @($j.Advisory.BlockedActionIds)
        if ($blocked -notcontains 'ThrottleBelowNormal') { throw 'Throttle must be blocked for Keep' }
        if ($blocked -notcontains 'Terminate') { throw 'Terminate must be blocked for Keep' }
        $ids = @($j.Advisory.Options | ForEach-Object { [string]$_.ActionId })
        if ($ids -contains 'ThrottleBelowNormal') { throw 'Advisory must not offer Throttle for Keep' }
    }

$keepBlockOut = Join-Path $logs 'smoke-res-keep-blocked.json'
Invoke-SmokeStep -Name 'process-resolution-keep-blocked' `
    -ScriptPath (Join-Path $scriptDir 'resolve-unknown-process.ps1') `
    -Arguments @('-ProcessName', 'MsMpEng', '-Action', 'ThrottleBelowNormal', '-SkipAuth', '-Offline', '-OutputJson', $keepBlockOut, '-Quiet') `
    -OutputPath $keepBlockOut `
    -Validate {
        param($path)
        $j = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ([string]$j.Outcome -ne 'ActionBlocked') { throw "Expected ActionBlocked got $($j.Outcome)" }
        if (-not [string]$j.Message) { throw 'ActionBlocked must include Message' }
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

Write-Host '[SMOKE] hub-auth-verify-skip...'
$authOut = Join-Path $logs 'smoke-hub-auth-verify.json'
$authEc = Invoke-HubCliSmoke -CliArgs @('auth', 'verify', '--skip-auth') -OutFile $authOut
if ($authEc -ne 0) { $failures.Add('hub-auth-verify-skip: CLI exit non-zero') }
else {
    $authJ = Get-Content -LiteralPath $authOut -Raw | ConvertFrom-Json
    if (-not $authJ.ok) { $failures.Add('hub-auth-verify-skip: ok=false') }
    else { Write-Host '[SMOKE] hub-auth-verify-skip OK' }
}

Write-Host '[SMOKE] hub-catalog-merge-direct...'
. (Join-Path $scriptDir 'lib\process-catalog-merge.ps1')
$hubCoreCatName = 'HubCatalogMergeCoreXYZ'
$hubCoreCache = [ordered]@{
    ProcessName = $hubCoreCatName
    WhatItIs = 'Hub Core catalog merge smoke process'
    WhatItDoes = 'Validates hub catalog merge-direct CLI'
    SuggestedCategory = 'Other'
    SuggestedPriority = 'Review'
    ResourceProfile = 'Mixed'
    BusinessHint = 'Core smoke'
}
$hubCoreHint = [ordered]@{
    WhatItIs = $hubCoreCache.WhatItIs
    WhatItDoes = $hubCoreCache.WhatItDoes
    SuggestedCategory = 'Other'
    SuggestedPriority = 'Review'
    ResourceProfile = 'Mixed'
    BusinessHint = 'Core smoke'
    Sources = @('smoke-test')
}
$hubMergeIn = [ordered]@{
    ProcessName = $hubCoreCatName
    CacheEntry = $hubCoreCache
    Hint = $hubCoreHint
    Confidence = 0.98
}
$hubMergeInFile = Join-Path $logs 'smoke-hub-catalog-merge-input.json'
($hubMergeIn | ConvertTo-Json -Depth 10) | Out-File -LiteralPath $hubMergeInFile -Encoding utf8 -Force
$smokeCatTmp = Join-Path $logs 'smoke-hub-catalog-tmp'
if (-not (Test-Path -LiteralPath $smokeCatTmp)) { New-Item -Path $smokeCatTmp -ItemType Directory -Force | Out-Null }
$smokeTmpCatalog = Join-Path $smokeCatTmp 'process-intelligence.json'
Copy-Item -LiteralPath $catPath -Destination $smokeTmpCatalog -Force
$hubMergeOut = Join-Path $logs 'smoke-hub-catalog-merge-direct.json'
$hubMergeEc = Invoke-HubCliSmoke -CliArgs @(
    'catalog', 'merge-direct', '--name', $hubCoreCatName, '--input', $hubMergeInFile,
    '--catalog', $smokeTmpCatalog, '--hub-root', $smokeCatTmp
) -OutFile $hubMergeOut
if ($hubMergeEc -ne 0) { $failures.Add('hub-catalog-merge-direct: CLI exit non-zero') }
else {
    $hubMergeJ = Get-Content -LiteralPath $hubMergeOut -Raw | ConvertFrom-Json
    if (-not $hubMergeJ.Ok) { $failures.Add("hub-catalog-merge-direct: $($hubMergeJ.Reason)") }
    else {
        $cat2 = Get-Content -LiteralPath $smokeTmpCatalog -Raw | ConvertFrom-Json
        $hit2 = $cat2.knownApplications.PSObject.Properties[$hubCoreCatName.ToLowerInvariant()]
        if (-not $hit2) { $hit2 = $cat2.knownApplications.PSObject.Properties[$hubCoreCatName] }
        if (-not $hit2) { $failures.Add('hub-catalog-merge-direct: entry missing in temp catalog') }
        elseif ($null -eq $cat2.extremeNecessityDefender) { $failures.Add('hub-catalog-merge-direct: extremeNecessityDefender stripped') }
        else { Write-Host '[SMOKE] hub-catalog-merge-direct OK' }
    }
}

Write-Host '[SMOKE] hub-resolve-plan-keep-blocked...'
$hubKeepBlockOut = Join-Path $logs 'smoke-hub-res-keep-blocked.json'
$hubKeepEc = Invoke-HubCliSmoke -CliArgs @(
    'resolve', 'plan', '--name', 'MsMpEng', '--action', 'ThrottleBelowNormal',
    '--skip-auth', '--dry-run', '--catalog', $catPath
) -OutFile $hubKeepBlockOut
if ($hubKeepEc -ne 0) { $failures.Add('hub-resolve-plan-keep-blocked: CLI exit non-zero') }
else {
    $hubKeepJ = Get-Content -LiteralPath $hubKeepBlockOut -Raw | ConvertFrom-Json
    if ([string]$hubKeepJ.Outcome -ne 'ActionBlocked') { $failures.Add("hub-resolve-plan-keep-blocked: $($hubKeepJ.Outcome)") }
    else { Write-Host '[SMOKE] hub-resolve-plan-keep-blocked OK' }
}

Write-Host '[SMOKE] hub-resolve-plan-dryrun-missing...'
$hubDryOut = Join-Path $logs 'smoke-hub-res-dryrun-missing.json'
$hubDryEc = Invoke-HubCliSmoke -CliArgs @(
    'resolve', 'plan', '--name', 'PID1234', '--pid', '1234', '--action', 'ThrottleBelowNormal',
    '--dry-run', '--not-running', '--catalog', $catPath
) -OutFile $hubDryOut
if ($hubDryEc -ne 0) { $failures.Add('hub-resolve-plan-dryrun-missing: CLI exit non-zero') }
else {
    $hubDryJ = Get-Content -LiteralPath $hubDryOut -Raw | ConvertFrom-Json
    if ([string]$hubDryJ.Outcome -ne 'ProcessNotRunning') { $failures.Add("hub-resolve-plan-dryrun-missing: $($hubDryJ.Outcome)") }
    else { Write-Host '[SMOKE] hub-resolve-plan-dryrun-missing OK' }
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

Write-Host '[SMOKE] hub-defender-evaluate...'
$ppiSmokeOut = Join-Path $logs 'smoke-ppi-for-defender.json'
$ppiSmokeEc = Invoke-HubCliSmoke -CliArgs @(
    'analyze', 'pressure', '--duration', '2', '--top', '5', '--catalog', $catPath
) -OutFile $ppiSmokeOut
if ($ppiSmokeEc -ne 0) { $failures.Add('hub-defender-evaluate: PPI sample failed') }
else {
    $hubDefOut = Join-Path $logs 'smoke-hub-defender-eval.json'
    $hubDefEc = Invoke-HubCliSmoke -CliArgs @(
        'defender', 'evaluate', '--input', $ppiSmokeOut, '--catalog', $catPath
    ) -OutFile $hubDefOut
    if ($hubDefEc -ne 0) { $failures.Add('hub-defender-evaluate: CLI exit non-zero') }
    else {
        $hubDefJ = Get-Content -LiteralPath $hubDefOut -Raw | ConvertFrom-Json
        if ([string]$hubDefJ.SchemaVersion -notmatch 'DefenderExtremeNecessityEvaluation') { $failures.Add('hub-defender-evaluate: schema') }
        elseif ($null -eq $hubDefJ.RecommendedTier) { $failures.Add('hub-defender-evaluate: RecommendedTier missing') }
        else { Write-Host '[SMOKE] hub-defender-evaluate OK' }
    }
}

Write-Host '[SMOKE] hub-defender-apply-dryrun...'
$defFixSmoke = Join-Path $HubRoot 'config\fixtures\defender-eval-apply-dryrun.json'
$exclSmoke = Join-Path $logs 'smoke-defender-exclusion-tmp'
if (-not (Test-Path -LiteralPath $exclSmoke)) { New-Item -Path $exclSmoke -ItemType Directory -Force | Out-Null }
$hubDefApplyOut = Join-Path $logs 'smoke-hub-defender-apply-dryrun.json'
$hubDefApplyEc = Invoke-HubCliSmoke -CliArgs @(
    'defender', 'apply', '--evaluation', $defFixSmoke, '--tier', 'TuneExclusions',
    '--exclusion-path', $exclSmoke, '--dry-run', '--understand-risk', '--skip-auth'
) -OutFile $hubDefApplyOut
if ($hubDefApplyEc -ne 0) { $failures.Add('hub-defender-apply-dryrun: CLI exit non-zero') }
else {
    $hubDefApplyJ = Get-Content -LiteralPath $hubDefApplyOut -Raw | ConvertFrom-Json
    if ([string]$hubDefApplyJ.SchemaVersion -notmatch 'DefenderExtremeApplyResult') { $failures.Add('hub-defender-apply-dryrun: schema') }
    elseif (-not $hubDefApplyJ.DryRun) { $failures.Add('hub-defender-apply-dryrun: expected DryRun') }
    elseif (-not (Test-Path -LiteralPath $hubDefApplyJ.RollbackPath)) { $failures.Add('hub-defender-apply-dryrun: rollback missing') }
    else { Write-Host '[SMOKE] hub-defender-apply-dryrun OK' }
}

Write-Host '[SMOKE] network-deep-scan...'
$netDeepOut = Join-Path $logs 'smoke-network-deep-scan.json'
& (Join-Path $HubRoot 'scripts\scan-network-deep.ps1') -OutputJson $netDeepOut -Quiet -ErrorAction Stop
if (-not (Test-Path -LiteralPath $netDeepOut)) { $failures.Add('network-deep-scan: output missing') }
else {
    $netDeepJ = Get-Content -LiteralPath $netDeepOut -Raw | ConvertFrom-Json
    if ([string]$netDeepJ.SchemaVersion -notmatch 'NetworkDeepScan') { $failures.Add('network-deep-scan: schema') }
    elseif (-not $netDeepJ.Layers) { $failures.Add('network-deep-scan: Layers missing') }
    else { Write-Host '[SMOKE] network-deep-scan OK' }
}

Write-Host '[SMOKE] hub-use-core-defender-evaluate...'
$prevUseCore = $env:HUB_USE_CORE
try {
    $env:HUB_USE_CORE = '1'
    $hubCoreDefOut = Join-Path $logs 'smoke-hub-use-core-defender-eval.json'
    if (-not (Test-Path -LiteralPath $ppiSmokeOut)) {
        $failures.Add('hub-use-core-defender-evaluate: PPI sample missing')
    }
    else {
        & (Join-Path $HubRoot 'scripts\evaluate-defender-extreme-necessity.ps1') `
            -InputJson $ppiSmokeOut -OutputJson $hubCoreDefOut -CatalogPath $catPath | Out-Null
        if (-not (Test-Path -LiteralPath $hubCoreDefOut)) { $failures.Add('hub-use-core-defender-evaluate: output missing') }
        else {
            $hubCoreDefJ = Get-Content -LiteralPath $hubCoreDefOut -Raw | ConvertFrom-Json
            if (-not $hubCoreDefJ.RecommendedTier) { $failures.Add('hub-use-core-defender-evaluate: missing tier') }
            else { Write-Host '[SMOKE] hub-use-core-defender-evaluate OK' }
        }
    }
}
finally {
    if ($null -eq $prevUseCore) { Remove-Item Env:HUB_USE_CORE -ErrorAction SilentlyContinue }
    else { $env:HUB_USE_CORE = $prevUseCore }
}

if ($failures.Count -gt 0) {
    Write-Host '[SMOKE] FAILED'
    $failures | ForEach-Object { Write-Host ("  - {0}" -f $_) }
    exit 1
}

Write-Host '[SMOKE] ALL PASSED'
exit 0
