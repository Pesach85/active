# Disk occupancy classification: SafeDelete / SystemBound / AppBound / PersonalHitl
# Bit-level here means: NTFS cluster allocation + magic-byte header + optional LCN sample.
# It is NOT a full-disk bitstream scan (too expensive / not useful for reclaim).

Set-StrictMode -Version Latest

function Get-OccupancyClusterBytes {
    param([string]$Drive)
    $cluster = 4096L
    try {
        $line = (& fsutil fsinfo ntfsinfo ("{0}:" -f $Drive) 2>$null |
            Where-Object { $_ -match 'Bytes Per Cluster' } | Select-Object -First 1)
        if ($line) {
            $parsed = (($line -split ':')[-1] -replace '[^0-9]', '')
            if ($parsed) { $cluster = [int64]$parsed }
        }
    } catch { }
    return $cluster
}

function Get-OccupancyAllocatedBytes {
    param([int64]$LogicalBytes, [int64]$ClusterBytes)
    if ($ClusterBytes -le 0) { $ClusterBytes = 4096 }
    if ($LogicalBytes -le 0) { return 0L }
    return [int64]([math]::Ceiling($LogicalBytes / [double]$ClusterBytes) * $ClusterBytes)
}

function Get-OccupancyMagicKind {
    param([string]$Path, [int]$MaxBytes = 16)
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $buf = New-Object byte[] $MaxBytes
            $n = $fs.Read($buf, 0, $MaxBytes)
            if ($n -lt 2) { return 'Empty' }
            $hex = ([BitConverter]::ToString($buf, 0, [Math]::Min($n, 8))).Replace('-', '')
            if ($buf[0] -eq 0x4D -and $buf[1] -eq 0x5A) { return 'PE' }
            if ($buf[0] -eq 0x50 -and $buf[1] -eq 0x4B) { return 'ZipContainer' }
            if ($n -ge 3 -and $buf[0] -eq 0xFF -and $buf[1] -eq 0xD8 -and $buf[2] -eq 0xFF) { return 'Jpeg' }
            if ($n -ge 8 -and $buf[0] -eq 0x89 -and $buf[1] -eq 0x50 -and $buf[2] -eq 0x4E) { return 'Png' }
            if ($n -ge 4 -and $buf[0] -eq 0x25 -and $buf[1] -eq 0x50 -and $buf[2] -eq 0x44 -and $buf[3] -eq 0x46) { return 'Pdf' }
            if ($n -ge 4 -and $buf[0] -eq 0x52 -and $buf[1] -eq 0x49 -and $buf[2] -eq 0x46 -and $buf[3] -eq 0x46) { return 'Riff' }
            if ($n -ge 4 -and $buf[0] -eq 0x37 -and $buf[1] -eq 0x7A -and $buf[2] -eq 0xBC) { return 'SevenZip' }
            if ($n -ge 8 -and $hex.StartsWith('7F454C46')) { return 'Elf' }
            if ($n -ge 16) {
                $ascii = [System.Text.Encoding]::ASCII.GetString($buf, 0, [Math]::Min($n, 16))
                if ($ascii.StartsWith('SQLite format')) { return 'Sqlite' }
                if ($ascii.Contains('ftyp')) { return 'MediaContainer' }
            }
            return "Unknown:$hex"
        } finally { $fs.Dispose() }
    } catch {
        return 'Unreadable'
    }
}

function Get-OccupancyExtentHint {
    param([string]$Path)
    try {
        $out = & fsutil file queryExtents $Path 2>$null
        if (-not $out) { return $null }
        $first = @($out | Where-Object { $_ -match 'LCN|VCN|Extent' } | Select-Object -First 2) -join '; '
        if ([string]::IsNullOrWhiteSpace($first)) { return ($out | Select-Object -First 1) }
        return $first
    } catch {
        return $null
    }
}

function Get-OccupancyLiveImagePaths {
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    try {
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.ExecutablePath) { [void]$set.Add([string]$_.ExecutablePath) }
        }
    } catch { }
    try {
        Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                if ($_.Path) { [void]$set.Add([string]$_.Path) }
            } catch { }
        }
    } catch { }
    return $set
}

function Test-OccupancyFileLocked {
    param([string]$Path)
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        $fs.Dispose()
        return $false
    } catch {
        return $true
    }
}

function Get-OccupancyDisposition {
    param(
        [string]$Path,
        [string]$Extension,
        [datetime]$LastWrite,
        [int64]$Length,
        [string]$MagicKind,
        [bool]$IsLocked,
        [bool]$IsLiveImage,
        [bool]$WuRunning
    )

    $p = $Path.ToLowerInvariant()
    $ext = if ($Extension) { $Extension.ToLowerInvariant() } else { '' }

    if ($IsLiveImage -or $IsLocked) {
        return [pscustomobject]@{
            Disposition = 'SystemBound'
            Reason = if ($IsLiveImage) { 'Mapped by running process' } else { 'File locked / in use' }
            Trust = 'T1'
        }
    }

    if ($p -match '\\pagefile\.sys$|\\hiberfil\.sys$|\\swapfile\.sys$') {
        return [pscustomobject]@{ Disposition = 'SystemBound'; Reason = 'Paging/hibernate file'; Trust = 'T0' }
    }
    if ($p -match '\\windows\\(system32|syswow64|winsxs|driverstore|servicing)\\') {
        return [pscustomobject]@{ Disposition = 'SystemBound'; Reason = 'Windows system tree'; Trust = 'T0' }
    }
    if ($p -match '\\windows\\installer\\' -and $ext -in @('.msi', '.msp')) {
        return [pscustomobject]@{ Disposition = 'SystemBound'; Reason = 'Windows Installer cache (uninstall)'; Trust = 'T1' }
    }
    if ($p -match 'softwaredistribution\\download' -and $WuRunning) {
        return [pscustomobject]@{ Disposition = 'SystemBound'; Reason = 'Windows Update running'; Trust = 'T1' }
    }

    $inUserPersonal = $p -match '\\users\\[^\\]+\\(documents|pictures|videos|music|desktop)\\'
    $inDownloads = $p -match '\\users\\[^\\]+\\downloads\\'
    $inProgramFiles = $p -match '\\program files( \(x86\))?\\'
    $inAppData = $p -match '\\appdata\\(local|roaming|locallow)\\'

    $isTempish = $p -match '\\temp\\|\\tmp\\|\\cache\\|\\caches\\|\\inetcache\\|\\code cache\\|\\gpuCache\\|\\shadercache\\'
    $isRecycle = $p -match '\\\$recycle\.bin\\'
    $isInstallerStaging = ($p -match '\\temp\\|\\tmp\\|\\downloads\\') -and ($ext -in @('.tmp', '.temp', '.msi', '.msp', '.cab', '.msu')) -and ($LastWrite -lt (Get-Date).AddHours(-1))
    $isTransientExt = $ext -in @('.tmp', '.temp', '.dmp', '.etl', '.log', '.old', '.bak', '.cache')
    $isPackageCache = $p -match '\\npm-cache\\|\\pip\\cache\\|\\nuget\\packages\\|\\yarn\\cache\\|\\pnpm-store\\|\\gradle\\caches\\|\\cargo\\registry\\'

    if ($isRecycle) {
        return [pscustomobject]@{ Disposition = 'SafeDelete'; Reason = 'Recycle Bin'; Trust = 'T1' }
    }
    if ($p -match 'softwaredistribution\\download' -and -not $WuRunning) {
        return [pscustomobject]@{ Disposition = 'SafeDelete'; Reason = 'WU download cache (service idle)'; Trust = 'T1' }
    }
    if ($isPackageCache) {
        return [pscustomobject]@{ Disposition = 'SafeDelete'; Reason = 'Package manager cache'; Trust = 'T1' }
    }
    if ($isTempish -and -not $inUserPersonal) {
        if ($LastWrite -gt (Get-Date).AddMinutes(-15) -and $Length -gt 0) {
            return [pscustomobject]@{ Disposition = 'AppBound'; Reason = 'Temp/cache recently written'; Trust = 'T2' }
        }
        return [pscustomobject]@{ Disposition = 'SafeDelete'; Reason = 'Temp/cache path'; Trust = 'T1' }
    }
    if ($isInstallerStaging -and -not $inUserPersonal) {
        return [pscustomobject]@{ Disposition = 'SafeDelete'; Reason = 'Installer staging leftover'; Trust = 'T1' }
    }
    if ($p -match '\\windows\\temp\\' -and $isTransientExt) {
        return [pscustomobject]@{ Disposition = 'SafeDelete'; Reason = 'Windows\\Temp transient'; Trust = 'T1' }
    }
    if ($p -match '\\windows\\prefetch\\' -and $ext -eq '.pf') {
        return [pscustomobject]@{ Disposition = 'AppBound'; Reason = 'Prefetch (perf hint, not auto-delete)'; Trust = 'T2' }
    }

    if ($inProgramFiles) {
        return [pscustomobject]@{ Disposition = 'AppBound'; Reason = 'Installed application tree'; Trust = 'T1' }
    }
    if ($inAppData -and -not $isTempish) {
        return [pscustomobject]@{ Disposition = 'AppBound'; Reason = 'Application data (not cache)'; Trust = 'T2' }
    }

    if ($inUserPersonal -or ($inDownloads -and $MagicKind -in @('Jpeg', 'Png', 'Pdf', 'Riff', 'MediaContainer', 'ZipContainer', 'PE'))) {
        return [pscustomobject]@{ Disposition = 'PersonalHitl'; Reason = 'User personal / download content'; Trust = 'T2' }
    }
    if ($inDownloads -and $ext -in @('.tmp', '.part', '.crdownload', '.download')) {
        return [pscustomobject]@{ Disposition = 'SafeDelete'; Reason = 'Incomplete download residue'; Trust = 'T1' }
    }
    if ($MagicKind -in @('Jpeg', 'Png', 'Pdf', 'Riff', 'MediaContainer') -and $Length -gt 5MB) {
        return [pscustomobject]@{ Disposition = 'PersonalHitl'; Reason = "Media/document by magic ($MagicKind)"; Trust = 'T2' }
    }
    if ($Length -ge 80MB -and -not $isTempish) {
        return [pscustomobject]@{ Disposition = 'PersonalHitl'; Reason = 'Large file needs operator review'; Trust = 'T2' }
    }

    return [pscustomobject]@{ Disposition = 'AppBound'; Reason = 'Unclassified application/other'; Trust = 'T3' }
}

function Get-OccupancySkipDirectory {
    param([string]$FullName)
    $p = $FullName.ToLowerInvariant()
    if ($p -match '\\windows\\winsxs$|\\windows\\servicing$|\\system volume information$|\\windows\\system32$|\\windows\\syswow64$') {
        return $true
    }
    return $false
}

function Get-OccupancyDepthBudget {
    param([string]$Depth)
    switch ($Depth) {
        'Quick' { return @{ MaxFiles = 8000; RootChildren = 40; MagicCap = 120; ExtentCap = 8 } }
        'Deep' { return @{ MaxFiles = 80000; RootChildren = 80; MagicCap = 500; ExtentCap = 25 } }
        default { return @{ MaxFiles = 25000; RootChildren = 50; MagicCap = 250; ExtentCap = 15 } }
    }
}

function Invoke-OccupancyScan {
    param(
        [Parameter(Mandatory)][string]$Drive,
        [ValidateSet('Quick', 'Standard', 'Deep')][string]$Depth = 'Standard',
        [ValidateSet('FileLevel', 'BitLevel')][string]$AuditLevel = 'BitLevel',
        [int]$Top = 40,
        [switch]$ExecuteSafeDelete
    )

    $drive = ($Drive.Trim().TrimEnd(':')).ToUpperInvariant()
    $root = "{0}:\" -f $drive
    if (-not (Test-Path -LiteralPath $root)) {
        throw "Drive $drive not available"
    }

    $budget = Get-OccupancyDepthBudget -Depth $Depth
    $cluster = Get-OccupancyClusterBytes -Drive $drive
    $wuRunning = $false
    $wu = Get-Service -Name wuauserv -ErrorAction SilentlyContinue
    if ($wu -and $wu.Status -eq 'Running') { $wuRunning = $true }
    $liveImages = Get-OccupancyLiveImagePaths

    $candidates = New-Object 'System.Collections.Generic.List[string]'
    Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue |
        Select-Object -First ([int]$budget.RootChildren) |
        ForEach-Object { [void]$candidates.Add($_.FullName) }

    $known = @(
        (Join-Path $root 'Windows\Temp'),
        (Join-Path $root 'Windows\SoftwareDistribution\Download'),
        (Join-Path $root '$Recycle.Bin'),
        (Join-Path $env:windir 'Temp'),
        $env:TEMP,
        (Join-Path $env:LOCALAPPDATA 'Temp'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\INetCache'),
        (Join-Path $env:LOCALAPPDATA 'npm-cache'),
        (Join-Path $env:LOCALAPPDATA 'pip\Cache'),
        (Join-Path $env:LOCALAPPDATA 'NuGet\v3-cache')
    )
    foreach ($k in $known) {
        if ($k -and (Test-Path -LiteralPath $k) -and $k.StartsWith("$drive`:\", [StringComparison]::OrdinalIgnoreCase)) {
            if (-not $candidates.Contains($k)) { [void]$candidates.Add($k) }
        }
    }

    $rows = New-Object System.Collections.Generic.List[object]
    $filesSeen = 0
    $magicUsed = 0
    $extentUsed = 0
    $deleted = 0
    $deletedBytes = 0L
    $deleteErrors = 0

    $dirQueue = New-Object System.Collections.Generic.Queue[string]
    $priority = New-Object System.Collections.Generic.List[string]
    $rest = New-Object System.Collections.Generic.List[string]
    foreach ($dir in $candidates) {
        $low = $dir.ToLowerInvariant()
        if ($low -match '\\temp|\\tmp|\\cache|recycle|softwaredistribution\\download|inetcache|npm-cache|nuget') {
            [void]$priority.Add($dir)
        } else {
            [void]$rest.Add($dir)
        }
    }
    foreach ($dir in $priority) { $dirQueue.Enqueue($dir) }
    foreach ($dir in $rest) { $dirQueue.Enqueue($dir) }
    $visited = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    while ($dirQueue.Count -gt 0 -and $filesSeen -lt [int]$budget.MaxFiles) {
        $dir = $dirQueue.Dequeue()
        if (-not $visited.Add($dir)) { continue }
        if (Get-OccupancySkipDirectory -FullName $dir) { continue }

        try {
            foreach ($child in [System.IO.Directory]::EnumerateDirectories($dir)) {
                if ($dirQueue.Count + $visited.Count -gt 8000) { break }
                $dirQueue.Enqueue($child)
            }
        } catch { }

        $fileEnum = $null
        try {
            $fileEnum = [System.IO.Directory]::EnumerateFiles($dir)
        } catch { continue }

        foreach ($filePath in $fileEnum) {
            if ($filesSeen -ge [int]$budget.MaxFiles) { break }
            $filesSeen++
            try {
                $info = [System.IO.FileInfo]$filePath
                if (-not $info.Exists) { continue }
            } catch { continue }

            $magic = $null
            $needMagic = ($AuditLevel -eq 'BitLevel') -and ($magicUsed -lt [int]$budget.MagicCap) -and (
                $info.Length -ge 8KB -or $info.Extension -in @('', '.bin', '.dat', '.tmp', '.temp')
            )
            if ($needMagic) {
                $magic = Get-OccupancyMagicKind -Path $info.FullName
                $magicUsed++
            }

            $locked = $false
            $isLive = $liveImages.Contains($info.FullName)
            $class = Get-OccupancyDisposition -Path $info.FullName -Extension $info.Extension `
                -LastWrite $info.LastWriteTime -Length $info.Length -MagicKind $magic `
                -IsLocked $false -IsLiveImage $isLive -WuRunning $wuRunning
            if ($class.Disposition -eq 'SafeDelete' -and $info.Length -lt 64MB) {
                $locked = Test-OccupancyFileLocked -Path $info.FullName
                if ($locked) {
                    $class = Get-OccupancyDisposition -Path $info.FullName -Extension $info.Extension `
                        -LastWrite $info.LastWriteTime -Length $info.Length -MagicKind $magic `
                        -IsLocked $true -IsLiveImage $isLive -WuRunning $wuRunning
                }
            }

            $logical = [int64]$info.Length
            $allocated = Get-OccupancyAllocatedBytes -LogicalBytes $logical -ClusterBytes $cluster
            $extent = $null
            if ($AuditLevel -eq 'BitLevel' -and $extentUsed -lt [int]$budget.ExtentCap -and $logical -ge 50MB) {
                $extent = Get-OccupancyExtentHint -Path $info.FullName
                $extentUsed++
            }

            $deletedNow = $false
            if ($ExecuteSafeDelete -and $class.Disposition -eq 'SafeDelete' -and -not $locked) {
                try {
                    Remove-Item -LiteralPath $info.FullName -Force -ErrorAction Stop
                    $deletedNow = $true
                    $deleted++
                    $deletedBytes += $allocated
                } catch {
                    $deleteErrors++
                }
            }

            $rows.Add([pscustomobject]@{
                Score = if ($class.Disposition -eq 'SafeDelete') { 90 } elseif ($class.Disposition -eq 'PersonalHitl') { 55 } elseif ($class.Disposition -eq 'SystemBound') { 10 } else { 35 }
                Recommendation = $class.Disposition
                Drive = $drive
                Path = $info.FullName
                Category = $class.Reason
                Provenance = $class.Trust
                DominantType = if ($magic) { $magic } else { $info.Extension }
                StalePct = if ($info.LastWriteTime -lt (Get-Date).AddDays(-7)) { 100 } else { 0 }
                EstimatedReclaimGB = [math]::Round(($(if ($AuditLevel -eq 'BitLevel') { $allocated } else { $logical })) / 1GB, 4)
                FilesScanned = 1
                Disposition = $class.Disposition
                Reason = $class.Reason
                LogicalBytes = $logical
                AllocatedBytes = $allocated
                MagicKind = $magic
                ExtentHint = $extent
                Locked = $locked
                Deleted = $deletedNow
            })
        }
    }

    $agg = $rows | Group-Object Disposition | ForEach-Object {
        [pscustomobject]@{
            Disposition = $_.Name
            Files = $_.Count
            LogicalGB = [math]::Round((($_.Group | Measure-Object LogicalBytes -Sum).Sum) / 1GB, 3)
            AllocatedGB = [math]::Round((($_.Group | Measure-Object AllocatedBytes -Sum).Sum) / 1GB, 3)
        }
    }

    $explorer = $rows |
        Sort-Object -Property @{ Expression = 'Score'; Descending = $true }, @{ Expression = 'EstimatedReclaimGB'; Descending = $true } |
        Select-Object -First $Top

    $hitl = @($rows | Where-Object { $_.Disposition -eq 'PersonalHitl' } |
        Sort-Object EstimatedReclaimGB -Descending |
        Select-Object -First 40)

    return [pscustomobject]@{
        SchemaVersion = 'DiskOccupancyReport.v1'
        Drive = $drive
        Depth = $Depth
        AuditLevel = $AuditLevel
        ClusterBytes = $cluster
        WuRunning = $wuRunning
        FilesScanned = $filesSeen
        MagicSamples = $magicUsed
        ExtentSamples = $extentUsed
        DeletedFiles = $deleted
        DeletedAllocatedGB = [math]::Round($deletedBytes / 1GB, 3)
        DeleteErrors = $deleteErrors
        BitLevelMeans = 'NTFS cluster allocation + magic-byte header + optional LCN (not full bitstream)'
        Summary = @($agg)
        Explorer = @($explorer)
        PersonalHitl = @($hitl)
        GeneratedAt = (Get-Date).ToString('o')
    }
}
