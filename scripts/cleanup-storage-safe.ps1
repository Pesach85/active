[CmdletBinding()]
param(
    [switch]$Execute,
    [int]$TempRetentionDays = 7,
    [int]$LogRetentionDays = 30,
    [ValidateSet("Quick", "Standard", "Deep")]
    [string]$AuditDepth = "Standard",
    [ValidateSet("FileLevel", "BitLevel")]
    [string]$AuditLevel = "FileLevel",
    [ValidateSet("Safe", "Radical")]
    [string]$CleanupMode = "Safe",
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

function Get-DepthMaxFiles {
    param([string]$Depth)

    switch ($Depth) {
        "Quick" { return 5000 }
        "Deep" { return 100000 }
        default { return 20000 }
    }
}

function Get-ClusterSizeBytes {
    param([string]$Drive)

    $cluster = 4096
    try {
        $line = (& fsutil fsinfo ntfsinfo ("{0}:" -f $Drive) 2>$null | Where-Object { $_ -match "Bytes Per Cluster" } | Select-Object -First 1)
        if ($line) {
            $parts = $line -split ":"
            if ($parts.Count -ge 2) {
                $parsed = ($parts[1] -replace "[^0-9]", "")
                if ($parsed) {
                    $cluster = [int64]$parsed
                }
            }
        }
    } catch {
        $cluster = 4096
    }

    return $cluster
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
        [datetime]$OlderThan,
        [int]$MaxFiles
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $OlderThan } |
        Select-Object -First $MaxFiles
}

if ($CleanupMode -eq "Radical") {
    if (-not $PSBoundParameters.ContainsKey("TempRetentionDays")) {
        $TempRetentionDays = 2
    }
    if (-not $PSBoundParameters.ContainsKey("LogRetentionDays")) {
        $LogRetentionDays = 7
    }
} else {
    if (-not $PSBoundParameters.ContainsKey("TempRetentionDays")) {
        $TempRetentionDays = 7
    }
    if (-not $PSBoundParameters.ContainsKey("LogRetentionDays")) {
        $LogRetentionDays = 30
    }
}

$maxFilesPerTarget = Get-DepthMaxFiles -Depth $AuditDepth
$clusterByDrive = @{}
foreach ($drive in $Drives) {
    $clusterByDrive[$drive] = Get-ClusterSizeBytes -Drive $drive
}

$mode = if ($Execute) { "EXECUTE" } else { "AUDIT" }
Write-Log -Level "INFO" -Message "Starting cleanup mode=$mode CleanupMode=$CleanupMode AuditDepth=$AuditDepth AuditLevel=$AuditLevel TempRetentionDays=$TempRetentionDays LogRetentionDays=$LogRetentionDays"

$pre = Get-DriveSnapshot -DriveLetters $Drives
$pre | ForEach-Object { Write-Log -Level "INFO" -Message ("Pre {0}: Free={1}GB Used={2}GB" -f $_.Name, $_.FreeGB, $_.UsedGB) }

$targets = New-Object System.Collections.Generic.List[object]
$tempCutoff = (Get-Date).AddDays(-$TempRetentionDays)
$logCutoff = (Get-Date).AddDays(-$LogRetentionDays)

$targets.Add([PSCustomObject]@{ Path = "C:\\Windows\\Temp"; Cutoff = $tempCutoff; Kind = "temp" })
$targets.Add([PSCustomObject]@{ Path = "C:\\Windows\\SoftwareDistribution\\Download"; Cutoff = $tempCutoff; Kind = "cache" })
$targets.Add([PSCustomObject]@{ Path = "C:\\inetpub\\logs\\LogFiles"; Cutoff = $logCutoff; Kind = "log" })
$targets.Add([PSCustomObject]@{ Path = "C:\\logs"; Cutoff = $logCutoff; Kind = "log" })

if ($CleanupMode -eq "Radical") {
    $targets.Add([PSCustomObject]@{ Path = "C:\\Windows\\Prefetch"; Cutoff = $tempCutoff; Kind = "cache" })
    $targets.Add([PSCustomObject]@{ Path = "C:\\Users\\Public\\Downloads"; Cutoff = $tempCutoff; Kind = "downloads" })
}

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
    $files = Get-FileCandidates -Path $t.Path -OlderThan $t.Cutoff -MaxFiles $maxFilesPerTarget
    $count = ($files | Measure-Object).Count
    $bytes = 0L
    $bytesAllocated = 0L
    foreach ($f in $files) {
        $len = [int64]$f.Length
        $bytes += $len
        $drive = $f.FullName.Substring(0,1).ToUpperInvariant()
        $cluster = 4096
        if ($clusterByDrive.ContainsKey($drive)) {
            $cluster = [int64]$clusterByDrive[$drive]
        }
        $bytesAllocated += [int64]([math]::Ceiling($len / [double]$cluster) * $cluster)
    }

    $effectiveBytes = if ($AuditLevel -eq "BitLevel") { $bytesAllocated } else { $bytes }

    $totalCandidates += $count
    $totalCandidateBytes += [int64]$effectiveBytes

    Write-Log -Level "INFO" -Message ("Target={0} Kind={1} Candidates={2} SizeGB={3} LogicalGB={4} MaxFiles={5}" -f $t.Path, $t.Kind, $count, [math]::Round($effectiveBytes / 1GB, 3), [math]::Round($bytes / 1GB, 3), $maxFilesPerTarget)

    if ($Execute) {
        foreach ($f in $files) {
            try {
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                $totalDeleted++
                if ($AuditLevel -eq "BitLevel") {
                    $drive = $f.FullName.Substring(0,1).ToUpperInvariant()
                    $cluster = 4096
                    if ($clusterByDrive.ContainsKey($drive)) {
                        $cluster = [int64]$clusterByDrive[$drive]
                    }
                    $totalDeletedBytes += [int64]([math]::Ceiling(([int64]$f.Length) / [double]$cluster) * $cluster)
                } else {
                    $totalDeletedBytes += [int64]$f.Length
                }
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
    CleanupMode = $CleanupMode
    AuditDepth = $AuditDepth
    AuditLevel = $AuditLevel
    CandidateFiles = $totalCandidates
    CandidateGB = [math]::Round($totalCandidateBytes / 1GB, 3)
    DeletedFiles = $totalDeleted
    DeletedGB = [math]::Round($totalDeletedBytes / 1GB, 3)
    Pre = $pre
    Post = $post
}
