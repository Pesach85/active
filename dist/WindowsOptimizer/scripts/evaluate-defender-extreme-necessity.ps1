[CmdletBinding()]
param(
    [string]$InputJson = '',
    [string]$OutputJson = '',
    [string]$CatalogPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$hubRoot = Split-Path -Parent $scriptDir
$corePath = Join-Path $scriptDir 'lib\process-pressure-core.ps1'
. $corePath
. (Join-Path $scriptDir 'lib\hub-core-routing.ps1')

if (-not $OutputJson) {
    $OutputJson = Join-Path $hubRoot 'logs\defender-extreme-necessity-eval.json'
}

if (Test-HubUseCore) {
    $dir = Split-Path -Parent $OutputJson
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    if (Invoke-HubCoreDefenderEvaluate -HubRoot $hubRoot -InputJson $InputJson -OutputJson $OutputJson -CatalogPath $CatalogPath) {
        $result = Get-Content -LiteralPath $OutputJson -Raw | ConvertFrom-Json
        Write-Host ("[HUB_USE_CORE] Tier={0} Composite={1}" -f $result.RecommendedTier, $result.CompositeScore)
        $result
        return
    }
    Write-Warning 'HUB_USE_CORE defender evaluate failed â€” falling back to PS.'
}

if (-not $CatalogPath) { $CatalogPath = Join-Path $hubRoot 'config\process-intelligence.json' }
$catalog = Get-ProcessIntelligenceCatalog -CatalogPath $CatalogPath

$isAdmin = $false
try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    $isAdmin = $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch {}

$report = $null
if ($InputJson -and (Test-Path -LiteralPath $InputJson)) {
    $report = Get-Content -LiteralPath $InputJson -Raw | ConvertFrom-Json
} else {
    $live = Join-Path $hubRoot 'logs\compute-analysis-live.json'
    if (Test-Path -LiteralPath $live) {
        $report = Get-Content -LiteralPath $live -Raw | ConvertFrom-Json
    }
}

$msmp = Get-DefenderProcessRowFromReport -Report $report
if (-not $msmp) {
    Write-Host 'MsMpEng not in report â€” running quick 4s pressure sample...'
    $analyzer = Join-Path $scriptDir 'analyze-process-pressure.ps1'
    $tmp = Join-Path $hubRoot 'logs\defender-eval-pressure.json'
    & $analyzer -DurationSec 4 -Top 15 -OutputJson $tmp | Out-Null
    if (Test-Path -LiteralPath $tmp) {
        $report = Get-Content -LiteralPath $tmp -Raw | ConvertFrom-Json
        $msmp = Get-DefenderProcessRowFromReport -Report $report
    }
}

$result = Get-DefenderExtremeNecessityEvaluation -MsMpEngRow $msmp -Catalog $catalog -IsAdmin:$isAdmin
$result.SourceReport = if ($InputJson) { $InputJson } elseif ($report) { 'inline-sample' } else { '' }

$dir = Split-Path -Parent $OutputJson
if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
($result | ConvertTo-Json -Depth 10) | Out-File -LiteralPath $OutputJson -Encoding utf8 -Force

Write-Host ("Tier={0} Composite={1} Allowed={2} Blockers={3}" -f `
    $result.RecommendedTier, $result.CompositeScore, $result.AllowedToProceed, @($result.Blockers).Count)
$result
