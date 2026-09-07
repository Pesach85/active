# Parity gate: C# Core vs PowerShell (catalog + resolution advisory).
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$hubRoot = Split-Path -Parent $scriptDir
$catalogPath = Join-Path $hubRoot 'config\process-intelligence.json'
$cliProject = Join-Path $hubRoot 'src\SystemOptimizerHub.Cli\SystemOptimizerHub.Cli.csproj'

. (Join-Path $scriptDir 'lib\process-pressure-core.ps1')
. (Join-Path $scriptDir 'lib\process-resolution-policy.ps1')
. (Join-Path $scriptDir 'lib\transparency-policy.ps1')
. (Join-Path $scriptDir 'lib\process-knowledge.ps1')
. (Join-Path $scriptDir 'lib\process-catalog-merge.ps1')

$failures = [System.Collections.Generic.List[string]]::new()
$catalog = Get-ProcessIntelligenceCatalog -CatalogPath $catalogPath
$resCfg = Get-ProcessResolutionConfig -HubRoot $hubRoot

function Invoke-HubCli {
    param([string[]]$CliArgs, [string]$OutFile)
    $errFile = Join-Path $hubRoot 'logs\parity-cli.err'
    $allArgs = @('run', '--project', $cliProject, '--no-build', '-v', 'q', '--') + $CliArgs
    $p = Start-Process -FilePath 'dotnet' -ArgumentList $allArgs -Wait -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $OutFile -RedirectStandardError $errFile
    return $p.ExitCode
}

Write-Host '[PARITY] dotnet test (Core unit)...'
dotnet test (Join-Path $hubRoot 'src\SystemOptimizerHub.sln') -v q --nologo
if ($LASTEXITCODE -ne 0) { $failures.Add('dotnet test failed') }

Write-Host '[PARITY] dotnet build hub CLI (once)...'
dotnet build $cliProject -v q --nologo
if ($LASTEXITCODE -ne 0) { $failures.Add('dotnet build CLI failed') }

Write-Host '[PARITY] catalog classify PS vs hub CLI...'
$cases = @('MsMpEng', 'mysqld', 'chrome', 'TotallyUnknownProcessXYZ', 'System', 'SearchIndexer')
foreach ($name in $cases) {
    $psNec = Resolve-ProcessNecessity -ProcessName $name -Catalog $catalog
    $tmpOut = Join-Path $hubRoot 'logs\parity-classify.json'
    $ec = Invoke-HubCli -CliArgs @('catalog', 'classify', '--name', $name, '--catalog', $catalogPath) -OutFile $tmpOut
    if ($ec -ne 0) { $failures.Add("CLI classify failed for $name"); continue }
    $cs = Get-Content -LiteralPath $tmpOut -Raw | ConvertFrom-Json
    if ([string]$cs.Priority -ne [string]$psNec.Priority) { $failures.Add("$name Priority mismatch") }
    if ([string]$cs.Category -ne [string]$psNec.Category) { $failures.Add("$name Category mismatch") }
    if ([string]$cs.Level -ne [string]$psNec.Level) { $failures.Add("$name Level mismatch") }
}

Write-Host '[PARITY] resolution advisory PS vs hub CLI...'
$advCases = @(
    @{
        Name = 'MsMpEng-Keep'
        Snap = @{ PID = 5808; ProcessName = 'MsMpEng'; RamMb = 446.2 }
        Hint = @{ Confidence = 0.98; TrustLevel = 'T1_Delegated'; WhatItIs = 'MicrosoftDefender'; SuggestedCategory = 'Security' }
        CliExtra = @('--confidence', '0.98', '--category', 'Security', '--trust-level', 'T1_Delegated', '--what-it-is', 'MicrosoftDefender')
    },
    @{
        Name = 'Unknown-HighRam'
        Snap = @{ PID = 1234; ProcessName = 'TotallyUnknownProcessXYZ'; RamMb = 512.0 }
        Hint = @{ Confidence = 0.55; TrustLevel = 'T3_Unknown'; WhatItIs = 'Unknown process'; SuggestedCategory = 'Unknown' }
        CliExtra = @()
    },
    @{
        Name = 'Unknown-LowRam'
        Snap = @{ PID = 1235; ProcessName = 'TotallyUnknownProcessXYZ'; RamMb = 50.0 }
        Hint = @{ Confidence = 0.55; TrustLevel = 'T3_Unknown'; WhatItIs = 'Unknown process'; SuggestedCategory = 'Unknown' }
        CliExtra = @()
    }
)

foreach ($ac in $advCases) {
    $snap = [ordered]@{
        PID = [int]$ac.Snap.PID
        ProcessName = [string]$ac.Snap.ProcessName
        RamMb = [double]$ac.Snap.RamMb
        NotRunning = $false
    }
    $hint = [ordered]@{
        Confidence = [double]$ac.Hint.Confidence
        TrustLevel = [string]$ac.Hint.TrustLevel
        WhatItIs = [string]$ac.Hint.WhatItIs
        SuggestedCategory = [string]$ac.Hint.SuggestedCategory
    }
    $nec = Resolve-ProcessNecessity -ProcessName ([string]$ac.Snap.ProcessName) -Catalog $catalog
    $psAdv = Get-ProcessResolutionAdvisory -ProcessSnapshot $snap -KnowledgeHint $hint `
        -ResolutionConfig $resCfg -CatalogNecessity $nec

    $tmpOut = Join-Path $hubRoot "logs\parity-adv-$($ac.Name).json"
    $cliArgs = @(
        'resolve', 'advisory', '--name', ([string]$ac.Snap.ProcessName),
        '--pid', ([string]$ac.Snap.PID),
        '--ram-mb', ([string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:R}', [double]$ac.Snap.RamMb)),
        '--catalog', $catalogPath
    ) + @($ac.CliExtra)
    $ec = Invoke-HubCli -CliArgs $cliArgs -OutFile $tmpOut
    if ($ec -ne 0) { $failures.Add("CLI advisory failed $($ac.Name)"); continue }

    $csAdv = Get-Content -LiteralPath $tmpOut -Raw | ConvertFrom-Json
    if ([string]$csAdv.RecommendedActionId -ne [string]$psAdv.RecommendedActionId) {
        $failures.Add("$($ac.Name) RecommendedActionId mismatch PS=$($psAdv.RecommendedActionId) CS=$($csAdv.RecommendedActionId)")
    }
    $psBlocked = @($psAdv.BlockedActionIds | Sort-Object)
    $csBlocked = @($csAdv.BlockedActionIds | Sort-Object)
    if (($psBlocked -join ',') -ne ($csBlocked -join ',')) {
        $failures.Add("$($ac.Name) BlockedActionIds mismatch")
    }
    if ([bool]$csAdv.Identifiable -ne [bool]$psAdv.Identifiable) {
        $failures.Add("$($ac.Name) Identifiable mismatch")
    }
}

Write-Host '[PARITY] PPI measure PS vs hub CLI (synthetic snapshots)...'
$firstSnap = @(
    [ordered]@{
        Key = '9001:100'; ProcessName = 'chrome'; PID = 9001
        CpuTime = 2.0; WorkingSet64 = 500MB; PrivateMemorySize64 = 480MB; IoBytes = 0L
        ImagePath = 'C:\Program Files\Google\Chrome\chrome.exe'; Responding = $true
    },
    [ordered]@{
        Key = '9002:100'; ProcessName = 'MsMpEng'; PID = 9002
        CpuTime = 5.0; WorkingSet64 = 400MB; PrivateMemorySize64 = 380MB; IoBytes = 0L
        ImagePath = ''; Responding = $true
    }
)
$secondSnap = @(
    [ordered]@{
        Key = '9001:100'; ProcessName = 'chrome'; PID = 9001
        CpuTime = 8.0; WorkingSet64 = 600MB; PrivateMemorySize64 = 580MB; IoBytes = 40MB
        ImagePath = 'C:\Program Files\Google\Chrome\chrome.exe'; Responding = $true
    },
    [ordered]@{
        Key = '9002:100'; ProcessName = 'MsMpEng'; PID = 9002
        CpuTime = 10.0; WorkingSet64 = 420MB; PrivateMemorySize64 = 400MB; IoBytes = 5MB
        ImagePath = ''; Responding = $true
    }
)
$firstFile = Join-Path $hubRoot 'logs\parity-ppi-first.json'
$secondFile = Join-Path $hubRoot 'logs\parity-ppi-second.json'
($firstSnap | ConvertTo-Json -Depth 6) | Out-File -LiteralPath $firstFile -Encoding utf8 -Force
($secondSnap | ConvertTo-Json -Depth 6) | Out-File -LiteralPath $secondFile -Encoding utf8 -Force

$psRows = Measure-ProcessPressureRows -First @{
    '9001:100' = [PSCustomObject]$firstSnap[0]
    '9002:100' = [PSCustomObject]$firstSnap[1]
} -Second @{
    '9001:100' = [PSCustomObject]$secondSnap[0]
    '9002:100' = [PSCustomObject]$secondSnap[1]
} -DurationSec 6 -LogicalProcessors 8 -Catalog $catalog -Weights @{
    Cpu = 0.50; Memory = 0.30; Io = 0.20; MemoryCapMb = 8192.0; IoCapMbPerSec = 400.0
}

$ppiOut = Join-Path $hubRoot 'logs\parity-ppi-measure.json'
$ec = Invoke-HubCli -CliArgs @(
    'analyze', 'measure', '--first', $firstFile, '--second', $secondFile,
    '--duration', '6', '--top', '8', '--catalog', $catalogPath
) -OutFile $ppiOut
if ($ec -ne 0) { $failures.Add('CLI analyze measure failed') }
else {
    $csPpi = Get-Content -LiteralPath $ppiOut -Raw | ConvertFrom-Json
    $psChrome = @($psRows | Where-Object { $_.ProcessName -eq 'chrome' } | Select-Object -First 1)
    $csChrome = @($csPpi.TopProcesses | Where-Object { $_.ProcessName -eq 'chrome' } | Select-Object -First 1)
    if ($psChrome -and $csChrome) {
        if ([double]$csChrome.Score -ne [double]$psChrome.Score) {
            $failures.Add("PPI chrome Score mismatch PS=$($psChrome.Score) CS=$($csChrome.Score)")
        }
        if ([string]$csChrome.Priority -ne [string]$psChrome.Priority) {
            $failures.Add('PPI chrome Priority mismatch')
        }
        if ([string]$csChrome.DominantPressure -ne [string]$psChrome.DominantPressure) {
            $failures.Add('PPI chrome DominantPressure mismatch')
        }
    } else {
        $failures.Add('PPI chrome row missing in PS or CS output')
    }
}

Write-Host '[PARITY] transparency build PS vs hub CLI (fixture)...'
$transInput = [ordered]@{
    HostSnapshot = [ordered]@{
        TotalRamMb = 16384; FreeRamMb = 3000; TotalRamGb = 16.0
        LogicalProcessors = 8; DriveCFreePercent = 8.5
    }
    Profile = [ordered]@{ Name = 'feather'; Tier = 'C'; LlmAllowed = $false }
    RamConsumers = @(
        [ordered]@{ PID = 101; Name = 'explorer'; RamMb = 350.0; CpuSec = 12.0; ImagePath = ''; Responding = $true },
        [ordered]@{ PID = 102; Name = 'mysteryapp'; RamMb = 512.0; CpuSec = 4.0; ImagePath = ''; Responding = $true }
    )
    Agents = @(
        [ordered]@{ AgentId = 'resource-monitor'; DisplayName = 'Resource Monitor'; TaskState = 'Missing'; ControlLevel = 'T1_Delegated' }
    )
    UnknownRamThresholdMb = 400
    AutoTerminate = $false
    LlmEnabled = $false
    NetworkUnknownTrustCount = 0
    NetworkHiddenProcessCount = 0
    NetworkAvailable = $false
    CatalogNames = @('explorer')
    RunningHubScriptNames = @()
}
$transInFile = Join-Path $hubRoot 'logs\parity-transparency-input.json'
($transInput | ConvertTo-Json -Depth 8) | Out-File -LiteralPath $transInFile -Encoding utf8 -Force

$posture = 100
$postureNotes = [System.Collections.Generic.List[string]]::new()
if ([int]$transInput.HostSnapshot.FreeRamMb -lt 4096) {
    $posture -= 10
    [void]$postureNotes.Add('Low free RAM below 4 GB')
}
if ([double]$transInput.HostSnapshot.DriveCFreePercent -lt 10) {
    $posture -= 15
    [void]$postureNotes.Add('System drive C: below 10% free')
}
foreach ($agent in @($transInput.Agents)) {
    if ($agent.TaskState -eq 'Missing' -and $agent.AgentId -in @('resource-monitor', 'hub-orchestrator')) {
        $posture -= 5
        [void]$postureNotes.Add("Expected agent missing: $($agent.DisplayName)")
    }
}
$unknownHigh = @($transInput.RamConsumers | Where-Object {
    $trust = Resolve-ProcessTrustLevel -Process ([pscustomobject]@{ ProcessName = $_.Name; Path = $_.ImagePath }) `
        -CatalogNames @($transInput.CatalogNames) -RunningHubScripts @{}
    $trust.Level -eq 'T3_Unknown' -and [double]$_.RamMb -ge [int]$transInput.UnknownRamThresholdMb
})
$posture -= [math]::Min(30, @($unknownHigh).Count * 8)
if (@($unknownHigh).Count -gt 0) {
    [void]$postureNotes.Add(("{0} unknown high-RAM process(es) >= {1} MB" -f @($unknownHigh).Count, $transInput.UnknownRamThresholdMb))
}
if ($posture -lt 0) { $posture = 0 }

$transOut = Join-Path $hubRoot 'logs\parity-transparency-build.json'
$ec = Invoke-HubCli -CliArgs @('transparency', 'build', '--input', $transInFile) -OutFile $transOut
if ($ec -ne 0) { $failures.Add('CLI transparency build failed') }
else {
    $csTrans = Get-Content -LiteralPath $transOut -Raw | ConvertFrom-Json
    if ([int]$csTrans.Posture.Score -ne [int]$posture) {
        $failures.Add("Transparency posture mismatch PS=$posture CS=$($csTrans.Posture.Score)")
    }
    $csMystery = @($csTrans.RamConsumers | Where-Object { $_.Name -eq 'mysteryapp' } | Select-Object -First 1)
    if (-not $csMystery -or [string]$csMystery.TrustLevel -ne 'T3_Unknown') {
        $failures.Add('Transparency mysteryapp trust mismatch')
    }
    $csExplorer = @($csTrans.RamConsumers | Where-Object { $_.Name -eq 'explorer' } | Select-Object -First 1)
    if (-not $csExplorer -or [string]$csExplorer.TrustLevel -ne 'T1_Delegated') {
        $failures.Add('Transparency explorer trust mismatch (catalog match => T1)')
    }
}

Write-Host '[PARITY] catalog build-entry PS vs hub CLI...'
$parityCatName = 'ParityCatalogMergeXYZ'
$parityCache = [ordered]@{
    ProcessName = $parityCatName
    WhatItIs = 'Parity catalog merge validation'
    WhatItDoes = 'Ensures Core catalog merge matches PS'
    SuggestedCategory = 'Other'
    SuggestedPriority = 'Review'
    ResourceProfile = 'Mixed'
    BusinessHint = 'Parity test'
}
$parityHint = [ordered]@{
    WhatItIs = $parityCache.WhatItIs
    WhatItDoes = $parityCache.WhatItDoes
    SuggestedCategory = 'Other'
    SuggestedPriority = 'Review'
    ResourceProfile = 'Mixed'
    BusinessHint = 'Parity'
    Sources = @('https://example.com/parity-test')
    SuggestedCatalogEntry = [ordered]@{
        category = 'Other'
        priority = 'Review'
        displayName = $parityCatName
        description = $parityCache.WhatItIs
        resourceProfile = 'Mixed'
        pressureMitigations = [ordered]@{
            MemoryHeavy = @("Review parity test $parityCatName")
        }
        references = @()
    }
}
$psCatEntry = Build-CatalogEntryFromSources -ProcessName $parityCatName -Hint $parityHint -CacheEntry $parityCache
$mergeIn = [ordered]@{
    ProcessName = $parityCatName
    CacheEntry = $parityCache
    Hint = $parityHint
    Confidence = 0.98
}
$mergeInFile = Join-Path $hubRoot 'logs\parity-catalog-merge-input.json'
($mergeIn | ConvertTo-Json -Depth 10) | Out-File -LiteralPath $mergeInFile -Encoding utf8 -Force
$buildOut = Join-Path $hubRoot 'logs\parity-catalog-build.json'
$ec = Invoke-HubCli -CliArgs @('catalog', 'build-entry', '--name', $parityCatName, '--input', $mergeInFile) -OutFile $buildOut
if ($ec -ne 0) { $failures.Add('CLI catalog build-entry failed') }
else {
    $csCatEntry = Get-Content -LiteralPath $buildOut -Raw | ConvertFrom-Json
    if ([string]$csCatEntry.priority -ne [string]$psCatEntry.priority) { $failures.Add('Catalog build-entry priority mismatch') }
    if ([string]$csCatEntry.category -ne [string]$psCatEntry.category) { $failures.Add('Catalog build-entry category mismatch') }
    if ([string]$csCatEntry.description -ne [string]$psCatEntry.description) { $failures.Add('Catalog build-entry description mismatch') }
}

Write-Host '[PARITY] catalog merge-direct PS vs hub CLI (temp catalog)...'
$tempCatDir = Join-Path $hubRoot 'logs\parity-catalog-tmp'
if (-not (Test-Path -LiteralPath $tempCatDir)) { New-Item -Path $tempCatDir -ItemType Directory -Force | Out-Null }
$tempCatalog = Join-Path $tempCatDir 'process-intelligence.json'
Copy-Item -LiteralPath $catalogPath -Destination $tempCatalog -Force
$directName = 'ParityMergeDirectXYZ'
$directEntry = Build-CatalogEntryFromSources -ProcessName $directName -Hint $parityHint -CacheEntry $parityCache
$psDirect = Merge-ProcessIntoIntelligenceCatalog -HubRoot $tempCatDir -ProcessName $directName `
    -CatalogEntry $directEntry -CatalogPath $tempCatalog -Confidence 0.98
$directOut = Join-Path $hubRoot 'logs\parity-catalog-merge-direct.json'
$ec = Invoke-HubCli -CliArgs @(
    'catalog', 'merge-direct', '--name', $directName, '--input', $mergeInFile,
    '--catalog', $tempCatalog, '--hub-root', $tempCatDir
) -OutFile $directOut
if ($ec -ne 0) { $failures.Add('CLI catalog merge-direct failed') }
else {
    $csDirect = Get-Content -LiteralPath $directOut -Raw | ConvertFrom-Json
    if (-not $csDirect.Ok) { $failures.Add('CLI merge-direct Ok=false') }
    elseif ([string]$csDirect.ProcessName -ne [string]$psDirect.ProcessName) { $failures.Add('merge-direct ProcessName mismatch') }
}

Write-Host '[PARITY] hub auth verify skip-auth...'
$authOut = Join-Path $hubRoot 'logs\parity-auth-verify.json'
$ec = Invoke-HubCli -CliArgs @('auth', 'verify', '--skip-auth') -OutFile $authOut
if ($ec -ne 0) { $failures.Add('CLI auth verify skip-auth failed') }
else {
    $auth = Get-Content -LiteralPath $authOut -Raw | ConvertFrom-Json
    if (-not $auth.ok -or -not $auth.skipped) { $failures.Add('auth verify skip-auth payload mismatch') }
}

Write-Host '[PARITY] resolve plan PS vs hub CLI...'
$pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
$pwsh = if ($pwshCmd) { $pwshCmd.Path } else { (Get-Command powershell).Path }
$resolveScript = Join-Path $scriptDir 'resolve-unknown-process.ps1'

$planCases = @(
    @{
        Name = 'keep-blocked'
        PsArgs = @('-ProcessName', 'MsMpEng', '-Action', 'ThrottleBelowNormal', '-SkipAuth', '-Offline', '-Quiet')
        CliArgs = @('resolve', 'plan', '--name', 'MsMpEng', '--action', 'ThrottleBelowNormal', '--skip-auth', '--dry-run', '--catalog', $catalogPath)
    },
    @{
        Name = 'dryrun-not-running'
        PsArgs = @('-ProcessId', '1234', '-Action', 'ThrottleBelowNormal', '-DryRun', '-Offline', '-Quiet')
        CliArgs = @('resolve', 'plan', '--name', 'PID1234', '--pid', '1234', '--action', 'ThrottleBelowNormal', '--dry-run', '--not-running', '--catalog', $catalogPath)
    }
)
foreach ($pc in $planCases) {
    $psPlanOut = Join-Path $hubRoot "logs\parity-plan-$($pc.Name)-ps.json"
    $csPlanOut = Join-Path $hubRoot "logs\parity-plan-$($pc.Name)-cs.json"
    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $resolveScript) + $pc.PsArgs + @('-OutputJson', $psPlanOut)
    $pPlan = Start-Process -FilePath $pwsh -ArgumentList $psArgs -Wait -PassThru -WindowStyle Hidden
    if ($pPlan.ExitCode -ne 0) { $failures.Add("PS resolve plan failed $($pc.Name)"); continue }
    $ec = Invoke-HubCli -CliArgs $pc.CliArgs -OutFile $csPlanOut
    if ($ec -ne 0) { $failures.Add("CLI resolve plan failed $($pc.Name)"); continue }
    $psPlan = Get-Content -LiteralPath $psPlanOut -Raw | ConvertFrom-Json
    $csPlan = Get-Content -LiteralPath $csPlanOut -Raw | ConvertFrom-Json
    if ([string]$psPlan.Outcome -ne [string]$csPlan.Outcome) {
        $failures.Add("$($pc.Name) Outcome mismatch PS=$($psPlan.Outcome) CS=$($csPlan.Outcome)")
    }
}

Write-Host '[PARITY] defender evaluate PS vs hub CLI (PPI fixture)...'
if (Test-Path -LiteralPath $ppiOut) {
    $psDefOut = Join-Path $hubRoot 'logs\parity-defender-ps.json'
    $csDefOut = Join-Path $hubRoot 'logs\parity-defender-cs.json'
    $pDef = Start-Process -FilePath $pwsh -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $scriptDir 'evaluate-defender-extreme-necessity.ps1'),
        '-InputJson', $ppiOut, '-OutputJson', $psDefOut
    ) -Wait -PassThru -WindowStyle Hidden
    if ($pDef.ExitCode -ne 0) { $failures.Add('PS defender evaluate failed') }
    else {
        $ec = Invoke-HubCli -CliArgs @('defender', 'evaluate', '--input', $ppiOut, '--catalog', $catalogPath) -OutFile $csDefOut
        if ($ec -ne 0) { $failures.Add('CLI defender evaluate failed') }
        else {
            $psDef = Get-Content -LiteralPath $psDefOut -Raw | ConvertFrom-Json
            $csDef = Get-Content -LiteralPath $csDefOut -Raw | ConvertFrom-Json
            if ([string]$psDef.RecommendedTier -ne [string]$csDef.RecommendedTier) {
                $failures.Add("defender RecommendedTier mismatch PS=$($psDef.RecommendedTier) CS=$($csDef.RecommendedTier)")
            }
            if ([double]$psDef.CompositeScore -ne [double]$csDef.CompositeScore) {
                $failures.Add("defender CompositeScore mismatch PS=$($psDef.CompositeScore) CS=$($csDef.CompositeScore)")
            }
        }
    }
} else {
    $failures.Add('defender parity skipped: PPI fixture missing')
}

Write-Host '[PARITY] defender apply dry-run PS vs hub CLI (fixture)...'
$defFix = Join-Path $hubRoot 'config\fixtures\defender-eval-apply-dryrun.json'
$exclPath = Join-Path $hubRoot 'logs\parity-defender-exclusion-tmp'
if (-not (Test-Path -LiteralPath $exclPath)) { New-Item -Path $exclPath -ItemType Directory -Force | Out-Null }
if (Test-Path -LiteralPath $defFix) {
    $psApplyOut = Join-Path $hubRoot 'logs\parity-defender-apply-ps.json'
    $csApplyOut = Join-Path $hubRoot 'logs\parity-defender-apply-cs.json'
    $applyScript = Join-Path $scriptDir 'apply-defender-extreme-necessity.ps1'
    $psApplyOk = $false
    try {
        & $applyScript -EvaluationJson $defFix -OutputJson $psApplyOut -Tier 'TuneExclusions' `
            -ExclusionPaths @($exclPath) -DryRun -IUnderstandRisk | Out-Null
        if (Test-Path -LiteralPath $psApplyOut) { $psApplyOk = $true }
    } catch {
        $failures.Add("PS defender apply dry-run failed: $($_.Exception.Message)")
    }
    if (-not $psApplyOk) {
        if ($failures -notmatch 'PS defender apply') { $failures.Add('PS defender apply dry-run failed: no output') }
    } else {
        $ec = Invoke-HubCli -CliArgs @(
            'defender', 'apply', '--evaluation', $defFix, '--tier', 'TuneExclusions',
            '--exclusion-path', $exclPath, '--dry-run', '--understand-risk', '--skip-auth'
        ) -OutFile $csApplyOut
        if ($ec -ne 0) { $failures.Add('CLI defender apply dry-run failed') }
        else {
            $psA = Get-Content -LiteralPath $psApplyOut -Raw | ConvertFrom-Json
            $csA = Get-Content -LiteralPath $csApplyOut -Raw | ConvertFrom-Json
            if ([string]$psA.Tier -ne [string]$csA.Tier) { $failures.Add('defender apply Tier mismatch') }
            if ([bool]$psA.DryRun -ne [bool]$csA.DryRun) { $failures.Add('defender apply DryRun mismatch') }
            if (@($psA.Applied).Count -ne @($csA.Applied).Count) { $failures.Add('defender apply Applied count mismatch') }
            if (-not (Test-Path -LiteralPath $psA.RollbackPath)) { $failures.Add('PS defender apply rollback missing') }
            if (-not (Test-Path -LiteralPath $csA.RollbackPath)) { $failures.Add('CS defender apply rollback missing') }
        }
    }
}

if ($failures.Count -gt 0) {
    Write-Host '[PARITY] FAILED'
    foreach ($f in $failures) { Write-Host "  - $f" }
    exit 1
}

Write-Host '[PARITY] ALL PASSED'
exit 0
