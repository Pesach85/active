# End-to-end smoke: identify -> catalog merge -> transparency report -> trust T1
# Run after changes to identify-unknown-process, process-catalog-merge, serve-transparency-dashboard, or build-transparency-report.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$hubRoot = Split-Path -Parent $scriptDir
$logs = Join-Path $hubRoot 'logs'
$failures = [System.Collections.Generic.List[string]]::new()

. (Join-Path $scriptDir 'hub-common.ps1')
. (Join-Path $scriptDir 'lib\process-knowledge.ps1')
. (Join-Path $scriptDir 'lib\process-catalog-merge.ps1')
. (Join-Path $scriptDir 'lib\transparency-policy.ps1')
. (Join-Path $scriptDir 'lib\process-pressure-core.ps1')

$pwsh = Get-HubPwshExecutable
$e2eName = 'E2eIdentifyChainXYZ'
$catalogPath = Join-Path $hubRoot 'config\process-intelligence.json'
$reportPath = Join-Path $logs 'e2e-transparency-report.json'

function Add-Fail([string]$Msg) {
    [void]$failures.Add($Msg)
    Write-Host "[E2E FAIL] $Msg" -ForegroundColor Red
}

Write-Host '[E2E] 1/5 identify script (SkipAuth, cache only)...'
$idOut = Join-Path $logs 'e2e-identify-out.json'
& $pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptDir 'identify-unknown-process.ps1') `
    -ProcessName $e2eName `
    -WhatItIs 'E2E chain test process' `
    -WhatItDoes 'Validates identify to catalog to report pipeline' `
    -SuggestedCategory 'Other' `
    -SuggestedPriority 'Review' `
    -SkipAuth -Offline `
    -OutputJson $idOut -Quiet -HubRoot $hubRoot | Out-Null
if (-not (Test-Path $idOut)) { Add-Fail 'identify output missing' }
else {
    $id = Get-Content $idOut -Raw | ConvertFrom-Json
    if ([string]$id.Outcome -ne 'Identified') { Add-Fail "identify outcome $($id.Outcome)" }
    elseif (-not $id.CatalogMerge.Skipped) { Add-Fail 'expected catalog merge skipped with SkipAuth' }
    else { Write-Host '[E2E] 1/5 OK' }
}

Write-Host '[E2E] 2/5 catalog merge pipeline (simulated post-auth)...'
$cacheEntry = [ordered]@{
    ProcessName = $e2eName
    WhatItIs = 'E2E chain test process'
    WhatItDoes = 'Validates identify to catalog to report pipeline'
    SuggestedCategory = 'Other'
    SuggestedPriority = 'Review'
    ResourceProfile = 'Mixed'
    BusinessHint = 'E2E smoke'
    Confidence = 0.98
}
$pipe = Invoke-PostIdentifyCatalogPipeline `
    -HubRoot $hubRoot `
    -ProcessName $e2eName `
    -CacheEntry $cacheEntry `
    -ProcessSnapshot @{ PID = 0; RamMb = 0; Path = '' } `
    -Confidence 0.98 `
    -Offline
if ($pipe.Skipped) { Add-Fail "catalog pipeline skipped: $($pipe.Reason)" }
elseif (-not $pipe.CatalogMerge.Ok) { Add-Fail "catalog merge failed: $($pipe.CatalogMerge.Reason)" }
elseif (-not $pipe.ReportRefresh.Rebuilt) { Add-Fail 'report not rebuilt after catalog merge' }
else { Write-Host '[E2E] 2/5 OK' }

Write-Host '[E2E] 3/5 catalog entry present...'
$cat = Get-Content $catalogPath -Raw | ConvertFrom-Json
$key = $e2eName.ToLowerInvariant()
$prop = $cat.knownApplications.PSObject.Properties[$key]
if (-not $prop) { Add-Fail "catalog missing key $key" }
else { Write-Host '[E2E] 3/5 OK' }

Write-Host '[E2E] 4/5 transparency report trust T1...'
if (-not (Test-Path $reportPath)) {
    & (Join-Path $scriptDir 'build-transparency-report.ps1') -OutputJson $reportPath | Out-Null
}
$report = Get-Content $reportPath -Raw | ConvertFrom-Json
$hit = @($report.RamConsumers | Where-Object { $_.Name -ieq $e2eName }) | Select-Object -First 1
if (-not $hit) {
    Write-Host '[E2E] 4/5 SKIP (process not in top RAM - verify Resolve-ProcessTrustLevel directly)'
    $trust = Resolve-ProcessTrustLevel -Process ([PSCustomObject]@{ ProcessName = $e2eName; Path = '' }) `
        -CatalogNames @($key)
    if ($trust.Level -ne 'T1_Delegated') { Add-Fail "trust level $($trust.Level) expected T1_Delegated" }
    else { Write-Host '[E2E] 4/5 OK (direct trust check)' }
} elseif ($hit.TrustLevel -ne 'T1_Delegated') {
    Add-Fail "report trust $($hit.TrustLevel) expected T1_Delegated"
} else { Write-Host '[E2E] 4/5 OK' }

Write-Host '[E2E] 5/5 web advisory API (if dashboard up)...'
try {
    $body = @{ processId = $PID; processName = (Get-Process -Id $PID).ProcessName; offline = $true } | ConvertTo-Json
    $adv = Invoke-WebRequest -Uri 'http://127.0.0.1:8765/api/process/advisory' -Method POST `
        -Body $body -ContentType 'application/json' -TimeoutSec 20 -UseBasicParsing
    if ($adv.StatusCode -ne 200) { Add-Fail "advisory HTTP $($adv.StatusCode)" }
    else { Write-Host '[E2E] 5/5 OK' }
} catch {
    Write-Host "[E2E] 5/5 SKIP (dashboard not running: $($_.Exception.Message))"
}

if ($failures.Count -gt 0) {
    Write-Host "[E2E] FAILED ($($failures.Count) errors)"
    $failures | ForEach-Object { Write-Host "  - $_" }
    exit 1
}

Write-Host '[E2E] ALL PASSED'
exit 0
