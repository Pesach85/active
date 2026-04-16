[CmdletBinding()]
param(
    [switch]$Execute,
    [int]$TempRetentionDays = 7,
    [int]$LogRetentionDays = 30,
    [string[]]$Drives = @("C", "D"),
    [string]$LogFile = "C:\\logs\\storage-cleanup.log"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath (Split-Path -Path $LogFile -Parent))) {
    New-Item -Path (Split-Path -Path $LogFile -Parent) -ItemType Directory -Force | Out-Null
}

function Write-Log {
    param([string]$Level, [string]$Message)
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    "$ts [$Level] $Message" | Out-File -LiteralPath $LogFile -Encoding utf8 -Append
}

function Get-DriveSnapshot {
    param([string[]]$DriveLetters)
    Get-PSDrive -PSProvider FileSystem |
        Where-Object { $DriveLetters -contains $_.Name } |
        Select-Object Name,
            @{N = "FreeGB"; E = { [math]::Round($_.Free / 1GB, 2) } },
            @{N = "UsedGB"; E = { [math]::Round($_.Used / 1GB, 2) } },
            @{N = "TotalGB"; E = { [math]::Round(($_.Used + $_.Free) / 1GB, 2) } }
}

function Get-UserTempPaths {
    $result = @()
    $usersRoot = "C:\\Users"
    if (-not (Test-Path -LiteralPath $usersRoot)) {
        return $result
    }

    Get-ChildItem -LiteralPath $usersRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $tempPath = Join-Path $_.FullName "AppData\\Local\\Temp"
        if (Test-Path -LiteralPath $tempPath) {
            $result += $tempPath
        }
    }

    return $result
}

function Get-FileCandidates {
    param(
        [string]$Path,
        [datetime]$OlderThan
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $OlderThan }
}

$mode = if ($Execute) { "EXECUTE" } else { "AUDIT" }
Write-Log -Level "INFO" -Message "Starting cleanup mode=$mode TempRetentionDays=$TempRetentionDays LogRetentionDays=$LogRetentionDays"

$pre = Get-DriveSnapshot -DriveLetters $Drives
$pre | ForEach-Object { Write-Log -Level "INFO" -Message ("Pre {0}: Free={1}GB Used={2}GB" -f $_.Name, $_.FreeGB, $_.UsedGB) }

$targets = New-Object System.Collections.Generic.List[object]
$tempCutoff = (Get-Date).AddDays(-$TempRetentionDays)
$logCutoff = (Get-Date).AddDays(-$LogRetentionDays)

$targets.Add([PSCustomObject]@{ Path = "C:\\Windows\\Temp"; Cutoff = $tempCutoff; Kind = "temp" })
$targets.Add([PSCustomObject]@{ Path = "C:\\Windows\\SoftwareDistribution\\Download"; Cutoff = $tempCutoff; Kind = "cache" })
$targets.Add([PSCustomObject]@{ Path = "C:\\inetpub\\logs\\LogFiles"; Cutoff = $logCutoff; Kind = "log" })
$targets.Add([PSCustomObject]@{ Path = "C:\\logs"; Cutoff = $logCutoff; Kind = "log" })

Get-UserTempPaths | ForEach-Object {
    $targets.Add([PSCustomObject]@{ Path = $_; Cutoff = $tempCutoff; Kind = "temp" })
}

$wuService = Get-Service -Name wuauserv -ErrorAction SilentlyContinue
if ($wuService -and $wuService.Status -eq "Running") {
    $targets = $targets | Where-Object { $_.Path -ne "C:\\Windows\\SoftwareDistribution\\Download" }
    Write-Log -Level "WARN" -Message "Skipped SoftwareDistribution cleanup because wuauserv is running."
}

$totalCandidates = 0
$totalCandidateBytes = 0L
$totalDeleted = 0
$totalDeletedBytes = 0L

foreach ($t in $targets) {
    $files = Get-FileCandidates -Path $t.Path -OlderThan $t.Cutoff
    $count = ($files | Measure-Object).Count
    $bytes = 0L
    foreach ($f in $files) {
        $bytes += [int64]$f.Length
    }

    $totalCandidates += $count
    $totalCandidateBytes += [int64]$bytes

    Write-Log -Level "INFO" -Message ("Target={0} Kind={1} Candidates={2} SizeGB={3}" -f $t.Path, $t.Kind, $count, [math]::Round($bytes / 1GB, 3))

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
}

if ($Execute) {
    foreach ($drive in $Drives) {
        try {
            Clear-RecycleBin -DriveLetter $drive -Force -ErrorAction Stop
            Write-Log -Level "INFO" -Message "Recycle Bin cleared on drive $drive"
        } catch {
            Write-Log -Level "WARN" -Message ("Recycle Bin not cleared on drive {0}: {1}" -f $drive, $_.Exception.Message)
        }
    }
}

$post = Get-DriveSnapshot -DriveLetters $Drives
$post | ForEach-Object { Write-Log -Level "INFO" -Message ("Post {0}: Free={1}GB Used={2}GB" -f $_.Name, $_.FreeGB, $_.UsedGB) }

[PSCustomObject]@{
    Mode = $mode
    CandidateFiles = $totalCandidates
    CandidateGB = [math]::Round($totalCandidateBytes / 1GB, 3)
    DeletedFiles = $totalDeleted
    DeletedGB = [math]::Round($totalDeletedBytes / 1GB, 3)
    Pre = $pre
    Post = $post
}
