[CmdletBinding()]
param(
    [string[]]$ProcessNames = @(),
    [string]$InputJson = '',
    [string]$OutputJson = '',
    [string]$HubRoot = '',
    [switch]$Offline,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $HubRoot) { $HubRoot = Split-Path -Parent $scriptDir }

. (Join-Path $scriptDir 'lib\process-pressure-core.ps1')
. (Join-Path $scriptDir 'lib\process-knowledge.ps1')
. (Join-Path $scriptDir 'hub-common.ps1')

$hub = Get-HubPaths -HubRoot $HubRoot
$knowledgeConfig = Get-ProcessKnowledgeConfig -HubRoot $HubRoot
if (-not $knowledgeConfig.Enabled) {
    Write-Warning 'ProcessKnowledge disabled in config.'
    exit 0
}

$catalogPath = Join-Path $hub.HubRoot 'config\process-intelligence.json'
$catalog = Get-ProcessIntelligenceCatalog -CatalogPath $catalogPath
$maintenanceConfig = $null
if (Test-Path -LiteralPath $hub.ConfigFile) {
    $maintenanceConfig = Get-MaintenanceConfig -ConfigPath $hub.ConfigFile
}

$targets = [System.Collections.Generic.List[object]]::new()

if ($InputJson -and (Test-Path -LiteralPath $InputJson)) {
    $report = Get-Content -LiteralPath $InputJson -Raw | ConvertFrom-Json
    if ($report.TopProcesses) {
        foreach ($p in @($report.TopProcesses)) {
            if ([string]$p.Priority -eq 'Review' -or [string]$p.Category -eq 'Unknown') {
                [void]$targets.Add([ordered]@{
                    ProcessName = [string]$p.ProcessName
                    PID = [int]$p.PID
                    ImagePath = [string]$p.ImagePath
                    RamMb = [double]$p.WorkingSetMB
                    DominantPressure = [string]$p.DominantPressure
                })
            }
        }
    }
    if ($report.UnknownHighRam) {
        foreach ($p in @($report.UnknownHighRam)) {
            [void]$targets.Add([ordered]@{
                ProcessName = [string]$p.Name
                PID = [int]$p.PID
                RamMb = [double]$p.RamMb
            })
        }
    }
}

foreach ($n in $ProcessNames) {
    foreach ($part in ([string]$n -split ',')) {
        $t = $part.Trim()
        if ($t) {
            [void]$targets.Add([ordered]@{ ProcessName = $t })
        }
    }
}

if (@($targets).Count -eq 0) {
    throw 'No targets â€” pass -ProcessNames or -InputJson with unknown processes.'
}

$hints = Get-ProcessKnowledgeHintsForTargets `
    -Targets @($targets) `
    -HubRoot $HubRoot `
    -Catalog $catalog `
    -KnowledgeConfig $knowledgeConfig `
    -MaintenanceConfig $maintenanceConfig `
    -Offline:$Offline

$result = [ordered]@{
    SchemaVersion = 'ProcessClassificationEnrichment.v1'
    GeneratedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Offline = [bool]$Offline.IsPresent
    HintCount = @($hints).Count
    ClassificationHints = @($hints)
}

if (-not $OutputJson) {
    $OutputJson = Join-Path $hub.Logs 'process-classification-hints.json'
}

$dir = Split-Path -Parent $OutputJson
if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
($result | ConvertTo-Json -Depth 12) | Out-File -LiteralPath $OutputJson -Encoding utf8 -Force

if (-not $Quiet) {
    Write-Host ("Enriched {0} process(es) -> {1}" -f @($hints).Count, $OutputJson)
    foreach ($h in $hints) {
        Write-Host ("  {0}: {1} ({2}, conf={3})" -f $h.ProcessName, $h.SuggestedCategory, $h.SuggestedPriority, $h.Confidence)
    }
}

$result
