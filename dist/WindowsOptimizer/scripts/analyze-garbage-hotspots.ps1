[CmdletBinding()]
param(
    [string[]]$Drives = @("C", "D"),
    [int]$Top = 25,
    [ValidateSet("Quick", "Standard", "Deep")]
    [string]$Depth = "Standard",
    [ValidateSet("FileLevel", "BitLevel")]
    [string]$AuditLevel = "FileLevel",
    [ValidateSet("Safe", "Radical")]
    [string]$CleanupMode = "Safe",
    [string]$OutputCsv = "C:\\SystemOptimizerHub\\active\\logs\\garbage-hotspots.csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$outputDir = Split-Path -Path $OutputCsv -Parent
if (-not (Test-Path -LiteralPath $outputDir)) {
    New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
}

function Get-DepthProfile {
    param([string]$Mode)

    switch ($Mode) {
        "Quick" { return @{ MaxFiles = 6000; RootChildren = 12 } }
        "Deep" { return @{ MaxFiles = 120000; RootChildren = 60 } }
        default { return @{ MaxFiles = 25000; RootChildren = 30 } }
    }
}

function Get-StaleDays {
    param([string]$Mode)

    if ($Mode -eq "Radical") {
        return 2
    }
    return 7
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

function Resolve-PathCategory {
    param([string]$Path)

    $p = $Path.ToLowerInvariant()
    if ($p -match "\\temp\\|\\tmp\\") { return "Temp" }
    if ($p -match "\\cache\\|softwaredistribution\\download|\\npm-cache\\|\\pip\\cache") { return "Cache" }
    if ($p -match "\\logs\\|\\logfiles\\") { return "Log" }
    if ($p -match '\\\$recycle\.bin\\|\\\$recycle\.bin$') { return "Recycle" }
    if ($p -match "\\appdata\\local\\microsoft\\windows\\inetcache\\|\\mozilla\\|\\chrome\\|\\edge\\|\\opera\\|\\brave") { return "Browser" }
    if ($p -match "softwaredistribution|winsxs|windows\\prefetch") { return "SystemUpdate" }
    if ($p -match "virtual|vm|vhd|vmdk|macchine_virtuali") { return "Virtualization" }
    if ($p -match "\\downloads\\|\\incoming\\") { return "Downloads" }
    return "Other"
}

function Resolve-Provenance {
    param([string]$Path)

    $p = $Path.ToLowerInvariant()
    if ($p -match "^c:\\windows\\") { return "Windows" }
    if ($p -match "^c:\\users\\") { return "UserProfile" }
    if ($p -match "inetpub") { return "IIS" }
    if ($p -match "chrome|edge|mozilla|brave|opera") { return "Browser" }
    if ($p -match "virtual|vm|vhd|vmdk|macchine_virtuali") { return "Virtualization" }
    return "Application"
}

function Resolve-DominantType {
    param([System.Collections.Generic.Dictionary[string,int]]$ExtMap)

    if ($ExtMap.Count -eq 0) {
        return "Unknown"
    }

    $top = $ExtMap.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1
    $ext = $top.Key.ToLowerInvariant()

    if ($ext -in @('.tmp','.temp','.log','.etl','.dmp')) { return "Transient" }
    if ($ext -in @('.zip','.7z','.rar','.iso','.cab')) { return "Archive" }
    if ($ext -in @('.msi','.msp','.exe','.dll')) { return "InstallerBinary" }
    if ($ext -in @('.vhd','.vhdx','.vmdk','.qcow2')) { return "VirtualDisk" }
    if ($ext -in @('.jpg','.jpeg','.png','.mp4','.mkv','.mp3','.wav')) { return "Media" }
    return "Mixed"
}

function Get-CategoryWeight {
    param([string]$Category)

    switch ($Category) {
        "Temp" { return 35 }
        "Cache" { return 30 }
        "Recycle" { return 28 }
        "Log" { return 20 }
        "Browser" { return 24 }
        "SystemUpdate" { return 18 }
        "Downloads" { return 12 }
        "Virtualization" { return 4 }
        default { return 8 }
    }
}

function Add-CandidatePath {
    param(
        [System.Collections.Generic.HashSet[string]]$Set,
        [string]$Path
    )

    if ($Path -and (Test-Path -LiteralPath $Path)) {
        [void]$Set.Add($Path)
    }
}

$depthTuning = Get-DepthProfile -Mode $Depth
$maxFiles = [int]$depthTuning.MaxFiles
$rootChildren = [int]$depthTuning.RootChildren
$staleDays = Get-StaleDays -Mode $CleanupMode
$staleCutoff = (Get-Date).AddDays(-$staleDays)

$candidatePaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

foreach ($drive in $Drives) {
    $root = "{0}:\\" -f $drive
    if (-not (Test-Path -LiteralPath $root)) {
        continue
    }

    Add-CandidatePath -Set $candidatePaths -Path (Join-Path $root '$Recycle.Bin')
    Add-CandidatePath -Set $candidatePaths -Path (Join-Path $root '$RECYCLE.BIN')

    Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue |
        Sort-Object Name |
        Select-Object -First $rootChildren |
        ForEach-Object {
            Add-CandidatePath -Set $candidatePaths -Path $_.FullName
        }
}

$knownTargets = @(
    "C:\\Windows\\Temp",
    "C:\\Windows\\SoftwareDistribution\\Download",
    "C:\\inetpub\\logs\\LogFiles",
    "C:\\Windows\\Prefetch"
)

foreach ($path in $knownTargets) {
    Add-CandidatePath -Set $candidatePaths -Path $path
}

Get-ChildItem -LiteralPath "C:\\Users" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    Add-CandidatePath -Set $candidatePaths -Path (Join-Path $_.FullName "AppData\\Local\\Temp")
    Add-CandidatePath -Set $candidatePaths -Path (Join-Path $_.FullName "AppData\\Local\\Microsoft\\Windows\\INetCache")
    Add-CandidatePath -Set $candidatePaths -Path (Join-Path $_.FullName "AppData\\Local\\Google\\Chrome\\User Data\\Default\\Cache")
    Add-CandidatePath -Set $candidatePaths -Path (Join-Path $_.FullName "AppData\\Local\\Microsoft\\Edge\\User Data\\Default\\Cache")
    Add-CandidatePath -Set $candidatePaths -Path (Join-Path $_.FullName "AppData\\Local\\Mozilla\\Firefox\\Profiles")
}

$clusterByDrive = @{}
foreach ($drive in $Drives) {
    $clusterByDrive[$drive] = Get-ClusterSizeBytes -Drive $drive
}

$rows = New-Object System.Collections.Generic.List[object]

foreach ($path in $candidatePaths) {
    $drive = $path.Substring(0,1).ToUpperInvariant()
    $cluster = 4096
    if ($clusterByDrive.ContainsKey($drive)) {
        $cluster = [int64]$clusterByDrive[$drive]
    }

    $files = @(Get-ChildItem -LiteralPath $path -File -Recurse -Force -ErrorAction SilentlyContinue | Select-Object -First $maxFiles)
    if ($files.Count -eq 0) {
        continue
    }

    $totalBytes = 0L
    $staleBytesLogical = 0L
    $staleBytesAllocated = 0L
    $staleCount = 0
    $transientCount = 0
    $extMap = New-Object 'System.Collections.Generic.Dictionary[string,int]' ([StringComparer]::OrdinalIgnoreCase)

    foreach ($f in $files) {
        $len = [int64]$f.Length
        $totalBytes += $len

        $ext = $f.Extension
        if (-not $ext) {
            $ext = "(none)"
        }

        if ($extMap.ContainsKey($ext)) {
            $extMap[$ext]++
        } else {
            $extMap[$ext] = 1
        }

        if ($ext -in @('.tmp','.temp','.log','.etl','.dmp','.cache','.old','.bak')) {
            $transientCount++
        }

        if ($f.LastWriteTime -lt $staleCutoff) {
            $staleCount++
            $staleBytesLogical += $len
            $allocated = [int64]([math]::Ceiling($len / [double]$cluster) * $cluster)
            $staleBytesAllocated += $allocated
        }
    }

    $stalePct = 0.0
    if ($files.Count -gt 0) {
        $stalePct = ($staleCount / [double]$files.Count) * 100.0
    }

    $transientPct = 0.0
    if ($files.Count -gt 0) {
        $transientPct = ($transientCount / [double]$files.Count) * 100.0
    }

    $reclaimBytes = if ($AuditLevel -eq "BitLevel") { $staleBytesAllocated } else { $staleBytesLogical }
    $reclaimGb = [math]::Round($reclaimBytes / 1GB, 3)

    $category = Resolve-PathCategory -Path $path
    $provenance = Resolve-Provenance -Path $path
    $dominantType = Resolve-DominantType -ExtMap $extMap

    $score = 0.0
    $score += Get-CategoryWeight -Category $category
    $score += [math]::Min(40.0, ($stalePct * 0.45))
    $score += [math]::Min(18.0, ($transientPct * 0.3))
    $score += [math]::Min(20.0, ($reclaimGb * 1.8))
    if ($CleanupMode -eq "Radical") {
        $score += 4
    }
    $score = [math]::Round($score, 1)

    $recommendation = "Low"
    if ($score -ge 70) {
        $recommendation = "High"
    } elseif ($score -ge 40) {
        $recommendation = "Medium"
    }

    $rows.Add([PSCustomObject]@{
        Score = $score
        Recommendation = $recommendation
        Drive = $drive
        Path = $path
        Category = $category
        Provenance = $provenance
        DominantType = $dominantType
        FilesScanned = $files.Count
        StaleFiles = $staleCount
        StalePct = [math]::Round($stalePct, 1)
        EstimatedReclaimGB = $reclaimGb
        TotalScannedGB = [math]::Round($totalBytes / 1GB, 3)
        Depth = $Depth
        AuditLevel = $AuditLevel
        CleanupMode = $CleanupMode
    })
}

$result = $rows |
    Sort-Object EstimatedReclaimGB -Descending |
    Sort-Object Score -Descending |
    Select-Object -First $Top
$result | Export-Csv -LiteralPath $OutputCsv -NoTypeInformation -Encoding UTF8
$result
