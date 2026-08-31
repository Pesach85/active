# Parity gate: C# Core vs PowerShell Resolve-ProcessNecessity (deterministic).
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$hubRoot = Split-Path -Parent $scriptDir
$catalogPath = Join-Path $hubRoot 'config\process-intelligence.json'
$cliProject = Join-Path $hubRoot 'src\SystemOptimizerHub.Cli\SystemOptimizerHub.Cli.csproj'

. (Join-Path $scriptDir 'lib\process-pressure-core.ps1')

$failures = [System.Collections.Generic.List[string]]::new()
$catalog = Get-ProcessIntelligenceCatalog -CatalogPath $catalogPath

$cases = @('MsMpEng', 'mysqld', 'chrome', 'TotallyUnknownProcessXYZ', 'System', 'SearchIndexer')

Write-Host '[PARITY] dotnet test (Core unit)...'
$pTest = Start-Process -FilePath 'dotnet' -ArgumentList @(
    'test', (Join-Path $hubRoot 'src\SystemOptimizerHub.sln'), '-v', 'q'
) -Wait -PassThru -WindowStyle Hidden
if ($pTest.ExitCode -ne 0) { $failures.Add('dotnet test failed') }

Write-Host '[PARITY] catalog classify PS vs hub CLI...'
foreach ($name in $cases) {
    $psNec = Resolve-ProcessNecessity -ProcessName $name -Catalog $catalog
    $tmpOut = Join-Path $hubRoot 'logs\parity-classify.json'
    $p = Start-Process -FilePath 'dotnet' -ArgumentList @(
        'run', '--project', $cliProject, '-v', 'q', '--',
        'catalog', 'classify', '--name', $name, '--catalog', $catalogPath
    ) -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $tmpOut -RedirectStandardError (Join-Path $hubRoot 'logs\parity-classify.err')
    if ($p.ExitCode -ne 0) {
        $failures.Add("CLI classify failed for $name")
        continue
    }
    $cs = Get-Content -LiteralPath $tmpOut -Raw | ConvertFrom-Json
    if ([string]$cs.Priority -ne [string]$psNec.Priority) {
        $failures.Add("$name Priority mismatch PS=$($psNec.Priority) CS=$($cs.Priority)")
    }
    if ([string]$cs.Category -ne [string]$psNec.Category) {
        $failures.Add("$name Category mismatch PS=$($psNec.Category) CS=$($cs.Category)")
    }
    if ([string]$cs.Level -ne [string]$psNec.Level) {
        $failures.Add("$name Level mismatch PS=$($psNec.Level) CS=$($cs.Level)")
    }
}

if ($failures.Count -gt 0) {
    Write-Host '[PARITY] FAILED'
    foreach ($f in $failures) { Write-Host "  - $f" }
    exit 1
}

Write-Host '[PARITY] ALL PASSED'
exit 0
