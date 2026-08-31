# Parity gate: C# Core vs PowerShell (catalog + resolution advisory).
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$hubRoot = Split-Path -Parent $scriptDir
$catalogPath = Join-Path $hubRoot 'config\process-intelligence.json'
$cliProject = Join-Path $hubRoot 'src\SystemOptimizerHub.Cli\SystemOptimizerHub.Cli.csproj'

. (Join-Path $scriptDir 'lib\process-pressure-core.ps1')
. (Join-Path $scriptDir 'lib\process-resolution-policy.ps1')

$failures = [System.Collections.Generic.List[string]]::new()
$catalog = Get-ProcessIntelligenceCatalog -CatalogPath $catalogPath
$resCfg = Get-ProcessResolutionConfig -HubRoot $hubRoot

function Invoke-HubCli {
    param([string[]]$CliArgs, [string]$OutFile)
    $errFile = Join-Path $hubRoot 'logs\parity-cli.err'
    $allArgs = @('run', '--project', $cliProject, '-v', 'q', '--') + $CliArgs
    $p = Start-Process -FilePath 'dotnet' -ArgumentList $allArgs -Wait -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $OutFile -RedirectStandardError $errFile
    return $p.ExitCode
}

Write-Host '[PARITY] dotnet test (Core unit)...'
dotnet test (Join-Path $hubRoot 'src\SystemOptimizerHub.sln') -v q --nologo
if ($LASTEXITCODE -ne 0) { $failures.Add('dotnet test failed') }

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

if ($failures.Count -gt 0) {
    Write-Host '[PARITY] FAILED'
    foreach ($f in $failures) { Write-Host "  - $f" }
    exit 1
}

Write-Host '[PARITY] ALL PASSED'
exit 0
