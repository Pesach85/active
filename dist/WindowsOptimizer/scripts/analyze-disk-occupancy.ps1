[CmdletBinding()]
param(
    [string]$Drive = '',
    [ValidateSet('Quick', 'Standard', 'Deep')]
    [string]$Depth = 'Standard',
    [ValidateSet('FileLevel', 'BitLevel')]
    [string]$AuditLevel = 'BitLevel',
    [int]$Top = 40,
    [switch]$ExecuteSafeDelete,
    [switch]$ListDrives,
    [string]$OutputJson = '',
    [string]$OutputCsv = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'lib\disk-occupancy.ps1')
. (Join-Path $scriptDir 'hub-common.ps1')
$hub = Get-HubPaths

if ([string]::IsNullOrWhiteSpace($OutputJson)) {
    $OutputJson = Join-Path $hub.Logs 'disk-occupancy-latest.json'
}
if ([string]::IsNullOrWhiteSpace($OutputCsv)) {
    $OutputCsv = Join-Path $hub.Logs 'garbage-hotspots-live.csv'
}

function Get-OccupancyDrives {
    Get-PSDrive -PSProvider FileSystem | Where-Object {
        $_.Name -match '^[A-Z]$' -and $_.Used -ne $null
    } | ForEach-Object {
        $total = [int64]$_.Used + [int64]$_.Free
        [pscustomobject]@{
            Drive = $_.Name
            FreeGB = [math]::Round($_.Free / 1GB, 2)
            UsedGB = [math]::Round($_.Used / 1GB, 2)
            TotalGB = [math]::Round($total / 1GB, 2)
            UsedPercent = if ($total -gt 0) { [int](($_.Used / $total) * 100) } else { 0 }
        }
    }
}

$drives = @(Get-OccupancyDrives)
if ($ListDrives -or [string]::IsNullOrWhiteSpace($Drive)) {
    $drives | Format-Table -AutoSize | Out-String | Write-Host
    if ($ListDrives -and [string]::IsNullOrWhiteSpace($Drive)) {
        return $drives
    }
}

if ([string]::IsNullOrWhiteSpace($Drive)) {
    $Drive = 'C'
}

$report = Invoke-OccupancyScan -Drive $Drive -Depth $Depth -AuditLevel $AuditLevel -Top $Top -ExecuteSafeDelete:$ExecuteSafeDelete

$outDir = Split-Path -Parent $OutputJson
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}
$report | ConvertTo-Json -Depth 8 | Out-File -LiteralPath $OutputJson -Encoding utf8 -Force

$csvDir = Split-Path -Parent $OutputCsv
if ($csvDir -and -not (Test-Path -LiteralPath $csvDir)) {
    New-Item -ItemType Directory -Path $csvDir -Force | Out-Null
}

$explorerRows = @($report.Explorer)
if ($explorerRows.Count -eq 0) {
    # Always emit CSV so GUI Wait-ForOutputFile succeeds (empty ranked list).
    [pscustomobject]@{
        Score = 0
        Recommendation = 'Info'
        Drive = $report.Drive
        Path = '(no ranked items in sample)'
        Category = 'EmptySample'
        Provenance = 'T0'
        DominantType = '-'
        StalePct = 0
        EstimatedReclaimGB = 0
        FilesScanned = [int]$report.FilesScanned
    } | Export-Csv -LiteralPath $OutputCsv -NoTypeInformation -Encoding UTF8
} else {
    $explorerRows | Export-Csv -LiteralPath $OutputCsv -NoTypeInformation -Encoding UTF8
}

if (Get-Command Write-TransparencyEvent -ErrorAction SilentlyContinue) {
    # optional
} else {
    $evtLib = Join-Path $scriptDir 'lib\transparency-events.ps1'
    if (Test-Path -LiteralPath $evtLib) { . $evtLib }
}
if (Get-Command Write-TransparencyEvent -ErrorAction SilentlyContinue) {
    Write-TransparencyEvent -EventsPath (Join-Path $hub.Logs 'transparency-events.jsonl') `
        -Action 'disk-occupancy-scan' `
        -Detail ("Drive={0} Files={1} Deleted={2}" -f $report.Drive, $report.FilesScanned, $report.DeletedFiles) `
        -AgentId 'storage-cleanup' `
        -ControlLevel $(if ($ExecuteSafeDelete) { 'T1_Delegated' } else { 'T0_Observed' }) `
        -Extra @{ Drive = $report.Drive; DeletedFiles = $report.DeletedFiles }
}

# Emit only compact summary to stdout (full report is in OutputJson/CSV).
[pscustomobject]@{
    SchemaVersion = $report.SchemaVersion
    Drive = $report.Drive
    FilesScanned = $report.FilesScanned
    DeletedFiles = $report.DeletedFiles
    DeletedAllocatedGB = $report.DeletedAllocatedGB
    OutputJson = $OutputJson
    OutputCsv = $OutputCsv
}
