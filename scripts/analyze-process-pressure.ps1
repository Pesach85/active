[CmdletBinding()]
param(
    [int]$DurationSec = 6,
    [int]$Top = 8,
    [string]$OutputJson = "",
    [string]$CatalogPath = "",
    [switch]$IncludeResearch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($DurationSec -lt 2) { $DurationSec = 2 }
if ($DurationSec -gt 30) { $DurationSec = 30 }
if ($Top -lt 3) { $Top = 3 }
if ($Top -gt 30) { $Top = 30 }

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$hubRoot = Split-Path -Parent $scriptDir
$corePath = Join-Path $scriptDir 'lib\process-pressure-core.ps1'
if (-not (Test-Path -LiteralPath $corePath)) {
    throw "Missing core library: $corePath"
}
. $corePath

if (-not $CatalogPath -or $CatalogPath.Trim() -eq '') {
    $CatalogPath = Join-Path $hubRoot 'config\process-intelligence.json'
}

$defaults = Get-ProcessPressureDefaults
$catalog = Get-ProcessIntelligenceCatalog -CatalogPath $CatalogPath
$weights = @{
    Cpu = $defaults.CpuWeight
    Memory = $defaults.MemoryWeight
    Io = $defaults.IoWeight
    MemoryCapMb = $defaults.MemoryCapMb
    IoCapMbPerSec = $defaults.IoCapMbPerSec
}

$logicalProcessors = [Environment]::ProcessorCount
$first = Get-WindowsProcessSnapshot -Excluded @($defaults.ExcludedProcesses)
Start-Sleep -Seconds $DurationSec
$second = Get-WindowsProcessSnapshot -Excluded @($defaults.ExcludedProcesses)

$list = Measure-ProcessPressureRows -First $first -Second $second -DurationSec $DurationSec `
    -LogicalProcessors $logicalProcessors -Catalog $catalog -Weights $weights

$topRows = @($list | Sort-Object { [double]$_.Score } -Descending | Select-Object -First $Top)

function Get-LegacyRecommendation {
    param([double]$Score, [string]$DominantPressure, [array]$Actions)
    if ($Score -ge 75) {
        $auto = @($Actions | Where-Object { $_.Action -eq 'LowerProcessPriority' -and -not $_.RequiresHitl })
        if ($auto.Count -gt 0) { return 'ThrottlePriority' }
        switch ($DominantPressure) {
            'CPUBound' { return 'ThrottlePriority' }
            'MemoryHeavy' { return 'InvestigateMemory' }
            'IOHeavy' { return 'CheckDiskContention' }
            default { return 'InvestigateImmediately' }
        }
    }
    if ($Score -ge 45) { return 'Observe' }
    return 'Normal'
}

$compatTop = foreach ($row in $topRows) {
    $rec = Get-LegacyRecommendation -Score ([double]$row.Score) -DominantPressure ([string]$row.DominantPressure) -Actions @($row.RecommendedActions)
    [ordered]@{
        Score = $row.Score
        ProcessName = $row.ProcessName
        PID = $row.PID
        ImagePath = $row.ImagePath
        CpuPercent = $row.CpuPercent
        WorkingSetMB = $row.WorkingSetMB
        PrivateMB = $row.PrivateMB
        IoMBps = $row.IoMBps
        DominantPressure = $row.DominantPressure
        Necessity = $row.Necessity
        Priority = $row.Priority
        Category = $row.Category
        Notes = $row.Notes
        Responding = $row.Responding
        Recommendation = $rec
        RecommendedActions = @($row.RecommendedActions)
        AutoEligibleActions = @($row.AutoEligibleActions)
        HitlRequiredActions = @($row.HitlRequiredActions)
    }
}

$highPressure = @($topRows | Where-Object { [double]$_.Score -ge 45 }).Count
$autoEligible = @($topRows | Where-Object { @($_.AutoEligibleActions).Count -gt 0 -and [string]$_.Priority -ne 'Keep' }).Count
$hitlRequired = @($topRows | Where-Object { @($_.HitlRequiredActions).Count -gt 0 }).Count
$vitalPreserved = @($topRows | Where-Object { [string]$_.Priority -eq 'Keep' }).Count

$research = @()
if ($IncludeResearch) {
    $seen = @{}
    foreach ($row in $topRows) {
        $name = ([string]$row.ProcessName).ToLowerInvariant()
        if ($catalog.knownApplications) {
            foreach ($prop in $catalog.knownApplications.PSObject.Properties) {
                if ($name -eq $prop.Name.ToLowerInvariant() -or $name -like ($prop.Name.ToLowerInvariant() + '*')) {
                    foreach ($ref in @($prop.Value.references)) {
                        if (-not $seen.ContainsKey($ref)) {
                            $seen[$ref] = $true
                            $research += [ordered]@{
                                ProcessName = $row.ProcessName
                                Reference = [string]$ref
                                DominantPressure = $row.DominantPressure
                            }
                        }
                    }
                    foreach ($act in @($row.RecommendedActions)) {
                        if ([string]$act.Action -eq 'ReferenceLinks') {
                            foreach ($link in ([string]$act.Rationale -split ';')) {
                                $link = $link.Trim()
                                if ($link -and -not $seen.ContainsKey($link)) {
                                    $seen[$link] = $true
                                    $research += [ordered]@{
                                        ProcessName = $row.ProcessName
                                        Reference = $link
                                        DominantPressure = $row.DominantPressure
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

$result = [ordered]@{
    SchemaVersion = 'ProcessPressureReport.v1'
    GeneratedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Platform = 'Windows'
    DurationSec = $DurationSec
    LogicalProcessors = $logicalProcessors
    TotalProcessesObserved = [int]$list.Count
    CatalogPath = $CatalogPath
    Summary = [ordered]@{
        HighPressureCount = $highPressure
        VitalPreserved = $vitalPreserved
        AutoEligibleCount = $autoEligible
        HitlRequiredCount = $hitlRequired
    }
    TopProcesses = @($compatTop)
    ResearchNotes = @($research)
}

if ($OutputJson) {
    $outDir = Split-Path -Parent $OutputJson
    if ($outDir -and (-not (Test-Path -LiteralPath $outDir))) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }
    ($result | ConvertTo-Json -Depth 12) | Out-File -LiteralPath $OutputJson -Encoding utf8 -Force
}

$result
