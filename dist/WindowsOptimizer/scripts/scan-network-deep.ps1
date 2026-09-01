[CmdletBinding()]
param(
    [string]$OutputJson = '',
    [string]$HubRoot = '',
    [switch]$IncludeMemoryScan,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $HubRoot) { $HubRoot = Split-Path -Parent $scriptDir }

. (Join-Path $scriptDir 'hub-common.ps1')
. (Join-Path $scriptDir 'lib\process-pressure-core.ps1')
. (Join-Path $scriptDir 'lib\network-deep-scan.ps1')
. (Join-Path $scriptDir 'lib\hub-decision-log.ps1')
. (Join-Path $scriptDir 'lib\hub-core-routing.ps1')

if (-not $OutputJson) {
    $OutputJson = Join-Path $HubRoot 'logs\network-deep-scan-latest.json'
}
$dir = Split-Path -Parent $OutputJson
if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }

$decisionPath = 'ps'
$result = $null

if (Test-HubUseCore) {
    $catalogPath = Join-Path $HubRoot 'config\process-intelligence.json'
    $coreArgs = @{
        HubRoot     = $HubRoot
        OutputJson  = $OutputJson
        CatalogPath = $catalogPath
    }
    if ($IncludeMemoryScan) { $coreArgs['IncludeMemoryScan'] = $true }
    $coreOk = Invoke-HubCoreNetworkDeepScan @coreArgs
    if ($coreOk) {
        $result = Get-Content -LiteralPath $OutputJson -Raw | ConvertFrom-Json
        $decisionPath = 'core'
        if (-not $Quiet) { Write-Host ("[HUB_USE_CORE] Network deep scan -> {0}" -f $OutputJson) }
    }
    else {
        Write-Warning 'HUB_USE_CORE network deep-scan failed â€” falling back to PS.'
    }
}

if (-not $result) {
    $isAdmin = Test-HubAdmin
    $catalog = Get-ProcessIntelligenceCatalog -CatalogPath (Join-Path $HubRoot 'config\process-intelligence.json')
    $catalogNames = [System.Collections.Generic.List[string]]::new()
    foreach ($n in @($catalog.vitalExact) + @($catalog.securityExact)) {
        if ($n) { [void]$catalogNames.Add([string]$n) }
    }
    if ($catalog.knownApplications) {
        foreach ($p in $catalog.knownApplications.PSObject.Properties) {
            [void]$catalogNames.Add([string]$p.Name)
        }
    }
    $scanParams = @{
        HubRoot      = $HubRoot
        CatalogNames = @($catalogNames)
        IsAdmin      = $isAdmin
    }
    if ($IncludeMemoryScan) { $scanParams['IncludeMemoryScan'] = $true }
    $result = Invoke-NetworkDeepScan @scanParams
    ($result | ConvertTo-Json -Depth 12) | Out-File -LiteralPath $OutputJson -Encoding utf8 -Force
}

$scanContext = @{
    Findings = [int]$result.Summary.FindingCount
    Critical = [int]$result.Summary.CriticalCount
    High     = [int]$result.Summary.HighCount
}
Write-HubDecisionLog -HubRoot $HubRoot -Domain 'network-deep-scan' -Path $decisionPath `
    -Action 'DeepScan' -Outcome ([string]$result.Summary.RecommendedAction) `
    -Success ($result.Summary.CriticalCount -eq 0) `
    -DurationMs ([int]$result.DurationMs) `
    -Context $scanContext

if (-not $Quiet) {
    Write-Host ("Network deep scan: findings={0} critical={1} high={2} -> {3}" -f `
        $result.Summary.FindingCount, $result.Summary.CriticalCount, $result.Summary.HighCount, $OutputJson)
}

$result
