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
$catalogNames = @($catalogNames)

$result = Invoke-NetworkDeepScan -HubRoot $HubRoot -CatalogNames $catalogNames `
    -IncludeMemoryScan:$IncludeMemoryScan -IsAdmin:$isAdmin

if (-not $OutputJson) {
    $OutputJson = Join-Path $HubRoot 'logs\network-deep-scan-latest.json'
}
$dir = Split-Path -Parent $OutputJson
if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
($result | ConvertTo-Json -Depth 12) | Out-File -LiteralPath $OutputJson -Encoding utf8 -Force

Write-HubDecisionLog -HubRoot $HubRoot -Domain 'network-deep-scan' -Path 'ps' `
    -Action 'DeepScan' -Outcome ([string]$result.Summary.RecommendedAction) `
    -Success ($result.Summary.CriticalCount -eq 0) `
    -DurationMs ([int]$result.DurationMs) `
    -Context @{
        Findings = [int]$result.Summary.FindingCount
        Critical = [int]$result.Summary.CriticalCount
        High = [int]$result.Summary.HighCount
    }

if (-not $Quiet) {
    Write-Host ("Network deep scan: findings={0} critical={1} high={2} -> {3}" -f `
        $result.Summary.FindingCount, $result.Summary.CriticalCount, $result.Summary.HighCount, $OutputJson)
}

$result
