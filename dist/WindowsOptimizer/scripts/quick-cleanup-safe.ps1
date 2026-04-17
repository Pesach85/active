[CmdletBinding()]
param(
    [switch]$Execute,
    [int]$RetentionDays = 2,
    [int]$MaxFilesPerTarget = 3000,
    [string]$LogFile = "C:\\SystemOptimizerHub\\active\\logs\\quick-cleanup.log",
    [string]$OutputJson = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($RetentionDays -lt 1) { $RetentionDays = 1 }
if ($RetentionDays -gt 14) { $RetentionDays = 14 }
if ($MaxFilesPerTarget -lt 200) { $MaxFilesPerTarget = 200 }
if ($MaxFilesPerTarget -gt 10000) { $MaxFilesPerTarget = 10000 }

$logDir = Split-Path -Parent $LogFile
if ($logDir -and (-not (Test-Path -LiteralPath $logDir))) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

function Write-Log {
    param([string]$Level, [string]$Message)
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    "$ts [$Level] $Message" | Out-File -LiteralPath $LogFile -Encoding utf8 -Append
}

function Get-FilesForTarget {
    param(
        [string]$Path,
        [datetime]$Cutoff,
        [int]$MaxFiles
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    return Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $Cutoff } |
        Sort-Object LastWriteTime |
        Select-Object -First $MaxFiles
}

$mode = if ($Execute) { "EXECUTE" } else { "AUDIT" }
$cutoff = (Get-Date).AddDays(-$RetentionDays)

$targets = New-Object System.Collections.Generic.List[string]
$targets.Add("C:\\Windows\\Temp")
$targets.Add("C:\\logs")
if ($env:TEMP) { $targets.Add($env:TEMP) }
if ($env:LOCALAPPDATA) {
    $targets.Add((Join-Path $env:LOCALAPPDATA "Microsoft\\Windows\\INetCache"))
    $targets.Add((Join-Path $env:LOCALAPPDATA "Microsoft\\Windows\\WER"))
}

$wuService = Get-Service -Name wuauserv -ErrorAction SilentlyContinue
if (-not ($wuService -and $wuService.Status -eq "Running")) {
    $targets.Add("C:\\Windows\\SoftwareDistribution\\Download")
} else {
    Write-Log -Level "WARN" -Message "Skipped SoftwareDistribution target because wuauserv is running."
}

Write-Log -Level "INFO" -Message ("Quick cleanup started mode={0} retentionDays={1} maxFiles={2}" -f $mode, $RetentionDays, $MaxFilesPerTarget)

$totalCandidates = 0
$totalCandidateBytes = 0L
$totalDeleted = 0
$totalDeletedBytes = 0L
$targetSummary = New-Object System.Collections.Generic.List[object]

foreach ($target in ($targets | Select-Object -Unique)) {
    $files = Get-FilesForTarget -Path $target -Cutoff $cutoff -MaxFiles $MaxFilesPerTarget
    $count = @($files).Count
    $bytes = 0L
    foreach ($f in $files) {
        $bytes += [int64]$f.Length
    }

    $totalCandidates += $count
    $totalCandidateBytes += $bytes

    if ($Execute) {
        foreach ($f in $files) {
            try {
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                $totalDeleted++
                $totalDeletedBytes += [int64]$f.Length
            } catch {
                Write-Log -Level "WARN" -Message ("Skip file={0} Reason={1}" -f $f.FullName, $_.Exception.Message)
            }
        }
    }

    $targetSummary.Add([PSCustomObject]@{
        Path = $target
        CandidateFiles = $count
        CandidateGB = [math]::Round($bytes / 1GB, 3)
    })

    Write-Log -Level "INFO" -Message ("Target={0} candidates={1} sizeGB={2}" -f $target, $count, [math]::Round($bytes / 1GB, 3))
}

$result = [PSCustomObject]@{
    Mode = $mode
    RetentionDays = $RetentionDays
    MaxFilesPerTarget = $MaxFilesPerTarget
    CandidateFiles = $totalCandidates
    CandidateGB = [math]::Round($totalCandidateBytes / 1GB, 3)
    DeletedFiles = $totalDeleted
    DeletedGB = [math]::Round($totalDeletedBytes / 1GB, 3)
    Targets = @(foreach ($entry in $targetSummary) { $entry })
}

if ($OutputJson) {
    try {
        $outDir = Split-Path -Parent $OutputJson
        if ($outDir -and (-not (Test-Path -LiteralPath $outDir))) {
            New-Item -ItemType Directory -Path $outDir -Force | Out-Null
        }
        $result | ConvertTo-Json -Depth 8 | Out-File -LiteralPath $OutputJson -Encoding utf8 -Force
    } catch {
        Write-Log -Level "WARN" -Message ("Cannot write OutputJson={0} Reason={1}" -f $OutputJson, $_.Exception.Message)
    }
}

Write-Log -Level "INFO" -Message ("Quick cleanup completed mode={0} candidateFiles={1} deletedFiles={2}" -f $mode, $totalCandidates, $totalDeleted)
$result
