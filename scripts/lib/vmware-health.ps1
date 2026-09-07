# VMware Workstation health helpers (inventory, diagnose, safe repair).
# Dot-source from scripts/. Audit-first; mutating actions require explicit Apply.

Set-StrictMode -Version Latest

$script:VmwareHealthSchema = 'VmwareHealthReport.v1'

$script:VmwareDefaultInventoryRoots = @(
    'D:\Macchine_Virtuali',
    'C:\Users\*\Documents\Virtual Machines',
    'C:\Virtual Machines',
    "$env:USERPROFILE\Documents\Virtual Machines"
)

$script:VmwareMksCrashPatterns = @(
    'ISBRendererComm:\s*Lost connection to mksSandbox',
    'Lost connection to mksSandbox',
    'unrecoverable error:\s*\(mks\)',
    'msg\.log\.error\.unrecoverable.*\(mks\)',
    'mksSandbox might be unresponsive'
)

$script:VmwareProcessNames = @(
    'vmware', 'vmware-vmx', 'vmware-tray', 'vmware-authd',
    'vmware-usbarbitrator64', 'vmware-unity-helper', 'mksSandbox'
)

function Get-VmwareHealthConfig {
    param(
        [hashtable]$HubPaths,
        [string[]]$InventoryRoots = @()
    )

    $roots = [System.Collections.Generic.List[string]]::new()
    foreach ($r in @($InventoryRoots)) {
        if (-not [string]::IsNullOrWhiteSpace($r)) { [void]$roots.Add($r.Trim()) }
    }

    $cfgPath = $null
    if ($HubPaths -and $HubPaths.ConfigFile) { $cfgPath = [string]$HubPaths.ConfigFile }
    if ($cfgPath -and (Test-Path -LiteralPath $cfgPath)) {
        try {
            $cfg = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($cfg.Vmware -and $cfg.Vmware.InventoryRoots) {
                foreach ($r in @($cfg.Vmware.InventoryRoots)) {
                    if (-not [string]::IsNullOrWhiteSpace($r)) { [void]$roots.Add([string]$r) }
                }
            }
        } catch { }
    }

    if ($roots.Count -eq 0) {
        foreach ($r in $script:VmwareDefaultInventoryRoots) { [void]$roots.Add($r) }
    }

    $expanded = [System.Collections.Generic.List[string]]::new()
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($pattern in $roots) {
        if ($pattern -match '[\*\?]') {
            $parent = Split-Path -Parent $pattern
            $leaf = Split-Path -Leaf $pattern
            if ($parent -and (Test-Path -LiteralPath $parent)) {
                Get-ChildItem -LiteralPath $parent -Directory -Filter $leaf -ErrorAction SilentlyContinue | ForEach-Object {
                    if ($seen.Add($_.FullName)) { [void]$expanded.Add($_.FullName) }
                }
            }
        } else {
            if ($seen.Add($pattern)) { [void]$expanded.Add($pattern) }
        }
    }

    return [pscustomobject]@{
        InventoryRoots = @($expanded)
        SchemaVersion  = $script:VmwareHealthSchema
    }
}

function Get-VmwareWorkstationInstall {
    $candidates = @(
        'HKLM:\SOFTWARE\VMware, Inc.\VMware Workstation',
        'HKLM:\SOFTWARE\WOW6432Node\VMware, Inc.\VMware Workstation'
    )
    foreach ($key in $candidates) {
        if (-not (Test-Path -LiteralPath $key)) { continue }
        try {
            $item = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
            $installPath = [string]$item.InstallPath
            if ([string]::IsNullOrWhiteSpace($installPath)) { continue }
            $installPath = $installPath.TrimEnd('\')
            $vmrun = Join-Path $installPath 'vmrun.exe'
            $vmSupport = Join-Path $installPath 'vm-support.bat'
            if (-not (Test-Path -LiteralPath $vmSupport)) {
                $vmSupport = Join-Path $installPath 'vm-support.ps1'
            }
            if (-not (Test-Path -LiteralPath $vmSupport)) {
                $vmSupport = Join-Path $installPath 'vm-support.exe'
            }
            $productVersion = $null
            foreach ($prop in @('ProductVersion', 'Version')) {
                if ($item.PSObject.Properties.Name -contains $prop -and $item.$prop) {
                    $productVersion = [string]$item.$prop
                    break
                }
            }
            if (-not $productVersion) {
                $exe = Join-Path $installPath 'vmware.exe'
                if (Test-Path -LiteralPath $exe) {
                    try { $productVersion = [string](Get-Item -LiteralPath $exe).VersionInfo.ProductVersion } catch { }
                }
            }
            return [pscustomobject]@{
                Found           = $true
                InstallPath     = $installPath
                ProductVersion  = $productVersion
                VmrunPath       = $(if (Test-Path -LiteralPath $vmrun) { $vmrun } else { $null })
                VmSupportPath   = $(if (Test-Path -LiteralPath $vmSupport) { $vmSupport } else { $null })
                RegistryKey     = $key
            }
        } catch { }
    }

    $fallbackDirs = @(
        'C:\Program Files (x86)\VMware\VMware Workstation',
        'C:\Program Files\VMware\VMware Workstation'
    )
    foreach ($dir in $fallbackDirs) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $exe = Join-Path $dir 'vmware.exe'
        $ver = $null
        if (Test-Path -LiteralPath $exe) {
            try { $ver = [string](Get-Item -LiteralPath $exe).VersionInfo.ProductVersion } catch { }
        }
        $vmrun = Join-Path $dir 'vmrun.exe'
        $vmSupport = Join-Path $dir 'vm-support.bat'
        return [pscustomobject]@{
            Found           = $true
            InstallPath     = $dir
            ProductVersion  = $ver
            VmrunPath       = $(if (Test-Path -LiteralPath $vmrun) { $vmrun } else { $null })
            VmSupportPath   = $(if (Test-Path -LiteralPath $vmSupport) { $vmSupport } else { $null })
            RegistryKey     = $null
        }
    }

    return [pscustomobject]@{
        Found           = $false
        InstallPath     = $null
        ProductVersion  = $null
        VmrunPath       = $null
        VmSupportPath   = $null
        RegistryKey     = $null
    }
}

function Get-VmwareHostPressure {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $totalMb = 0
    $freeMb = 0
    $usedPct = 0
    if ($os) {
        $totalMb = [int]([math]::Round($os.TotalVisibleMemorySize / 1024.0, 0))
        $freeMb = [int]([math]::Round($os.FreePhysicalMemory / 1024.0, 0))
        if ($totalMb -gt 0) {
            $usedPct = [int]([math]::Round((($totalMb - $freeMb) / [double]$totalMb) * 100.0, 0))
        }
    }

    $cpuLoad = $null
    try {
        $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cpu -and $null -ne $cpu.LoadPercentage) { $cpuLoad = [int]$cpu.LoadPercentage }
    } catch { }

    $gpu = @()
    try {
        Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | ForEach-Object {
            $gpu += [pscustomobject]@{
                Name           = [string]$_.Name
                DriverVersion  = [string]$_.DriverVersion
                AdapterRAM_MB  = if ($_.AdapterRAM -and $_.AdapterRAM -gt 0) { [int]([math]::Round($_.AdapterRAM / 1MB, 0)) } else { $null }
                Status         = [string]$_.Status
            }
        }
    } catch { }

    return [pscustomobject]@{
        TotalRamMB     = $totalMb
        FreeRamMB      = $freeMb
        RamUsedPercent = $usedPct
        CpuLoadPercent = $cpuLoad
        GpuAdapters     = $gpu
        HighRamPressure = ($usedPct -ge 85 -or $freeMb -lt 2048)
        HighCpuPressure = ($null -ne $cpuLoad -and $cpuLoad -ge 90)
    }
}

function Get-VmwareServiceHealth {
    $wanted = @(
        'VMAuthdService',
        'VMwareHostOpen',
        'VMUSBArbService',
        'VMnetDHCP',
        'VMware NAT Service'
    )
    $services = @()
    foreach ($name in $wanted) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($svc) {
            $services += [pscustomobject]@{
                Name        = $svc.Name
                DisplayName = $svc.DisplayName
                Status      = [string]$svc.Status
                StartType   = [string]$svc.StartType
            }
        } else {
            $services += [pscustomobject]@{
                Name        = $name
                DisplayName = $null
                Status      = 'NotInstalled'
                StartType   = $null
            }
        }
    }

    $procs = @()
    foreach ($pn in $script:VmwareProcessNames) {
        Get-Process -Name $pn -ErrorAction SilentlyContinue | ForEach-Object {
            $path = $null
            try { $path = $_.Path } catch { }
            $procs += [pscustomobject]@{
                Name      = $_.ProcessName
                Id        = $_.Id
                Path      = $path
                WorkingSetMB = [int]([math]::Round($_.WorkingSet64 / 1MB, 0))
            }
        }
    }

    return [pscustomobject]@{
        Services  = $services
        Processes = $procs
    }
}

function Get-VmwareLiveVmxPaths {
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    try {
        Get-CimInstance Win32_Process -Filter "Name='vmware-vmx.exe'" -ErrorAction SilentlyContinue | ForEach-Object {
            $cmd = [string]$_.CommandLine
            if ([string]::IsNullOrWhiteSpace($cmd)) { return }
            if ($cmd -match '"([^"]+\.vmx)"') {
                [void]$set.Add($Matches[1])
            } elseif ($cmd -match '([A-Za-z]:\\[^\s"]+\.vmx)') {
                [void]$set.Add($Matches[1])
            }
        }
    } catch { }
    return $set
}

function Find-VmwareVmxInventory {
    param(
        [string[]]$Roots,
        [int]$MaxDepth = 4
    )

    $found = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($root in @($Roots)) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        if (-not (Test-Path -LiteralPath $root)) { continue }
        try {
            # Prefer shallow recursive search; VMware keeps .vmx at VM folder root.
            Get-ChildItem -LiteralPath $root -Filter '*.vmx' -File -Recurse -Depth $MaxDepth -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notmatch '\.vmx~$' } |
                ForEach-Object { [void]$found.Add($_.FullName) }
        } catch { }
    }
    return @($found)
}

function Get-VmwareVmxSetting {
    param(
        [string[]]$Lines,
        [string]$Key
    )
    $pattern = '^\s*' + [regex]::Escape($Key) + '\s*='
    foreach ($line in $Lines) {
        if ($line -match $pattern) {
            if ($line -match '=\s*"([^"]*)"') { return $Matches[1] }
            if ($line -match '=\s*(\S+)') { return $Matches[1].Trim('"') }
        }
    }
    return $null
}

function Get-VmwareLockItems {
    param([string]$VmDir)

    $locks = @()
    if (-not (Test-Path -LiteralPath $VmDir)) { return $locks }

    Get-ChildItem -LiteralPath $VmDir -Force -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match '\.lck$|\.lck~$' -or ($_.PSIsContainer -and $_.Name -match '\.lck')
    } | ForEach-Object {
        $locks += [pscustomobject]@{
            Name         = $_.Name
            FullName     = $_.FullName
            IsDirectory  = [bool]$_.PSIsContainer
            LastWriteTime = $_.LastWriteTime.ToString('o')
        }
    }
    return $locks
}

function Test-VmwareLogMksCrash {
    param(
        [string]$VmDir,
        [int]$TailLines = 400
    )

    $hits = @()
    $logNames = @(
        'vmware.log', 'vmware-0.log', 'vmware-1.log', 'vmware-2.log',
        'mksSandbox.log', 'mksSandbox-0.log', 'mksSandbox-1.log',
        'vmware-mks.log', 'vmware-mks-0.log'
    )
    $files = @()
    foreach ($n in $logNames) {
        $p = Join-Path $VmDir $n
        if (Test-Path -LiteralPath $p) { $files += Get-Item -LiteralPath $p }
    }
    Get-ChildItem -LiteralPath $VmDir -Filter 'mksSandbox*.log' -File -ErrorAction SilentlyContinue | ForEach-Object {
        if ($files.FullName -notcontains $_.FullName) { $files += $_ }
    }

    foreach ($f in $files) {
        try {
            $tail = Get-Content -LiteralPath $f.FullName -Tail $TailLines -ErrorAction SilentlyContinue
            if (-not $tail) { continue }
            $joined = $tail -join "`n"
            foreach ($pat in $script:VmwareMksCrashPatterns) {
                if ($joined -match $pat) {
                    $sample = ($tail | Where-Object { $_ -match $pat } | Select-Object -Last 1)
                    $hits += [pscustomobject]@{
                        LogFile   = $f.FullName
                        Pattern   = $pat
                        Sample    = [string]$sample
                        LogMtime  = $f.LastWriteTime.ToString('o')
                    }
                    break
                }
            }
        } catch { }
    }

    return $hits
}

function Get-VmwareGuestFamilyHint {
    param([string]$GuestOs)
    if ([string]::IsNullOrWhiteSpace($GuestOs)) { return 'Unknown' }
    $g = $GuestOs.ToLowerInvariant()
    if ($g -match 'winxp|windowsxp') { return 'WindowsXP' }
    if ($g -match 'winnet|windows7|win7|windows2008') { return 'Windows7Era' }
    if ($g -match 'windows8|windows9|windows10|windows11|winvista') { return 'WindowsModern' }
    if ($g -match 'linux|ubuntu|debian|kali|rhel|centos') { return 'Linux' }
    return 'Other'
}

function Invoke-VmwareVmDiagnose {
    param(
        [string]$VmxPath,
        [System.Collections.Generic.HashSet[string]]$LiveVmxPaths
    )

    $vmDir = Split-Path -Parent $VmxPath
    $displayName = [IO.Path]::GetFileNameWithoutExtension($VmxPath)
    $lines = @()
    try { $lines = Get-Content -LiteralPath $VmxPath -ErrorAction Stop } catch { }

    $dn = Get-VmwareVmxSetting -Lines $lines -Key 'displayName'
    if ($dn) { $displayName = $dn }
    $guestOs = Get-VmwareVmxSetting -Lines $lines -Key 'guestOS'
    $memsize = Get-VmwareVmxSetting -Lines $lines -Key 'memsize'
    $numvcpus = Get-VmwareVmxSetting -Lines $lines -Key 'numvcpus'
    $enable3d = Get-VmwareVmxSetting -Lines $lines -Key 'mks.enable3d'
    $svgaGfx = Get-VmwareVmxSetting -Lines $lines -Key 'svga.graphicsMemoryKB'
    $svgaVram = Get-VmwareVmxSetting -Lines $lines -Key 'svga.vramSize'

    $isPoweredOn = $false
    if ($LiveVmxPaths -and $LiveVmxPaths.Contains($VmxPath)) { $isPoweredOn = $true }

    $locks = @(Get-VmwareLockItems -VmDir $vmDir)
    $hasLocks = $locks.Count -gt 0
    $staleLocks = $false
    if ($hasLocks -and -not $isPoweredOn) { $staleLocks = $true }

    $vmdkCount = @(Get-ChildItem -LiteralPath $vmDir -Filter '*.vmdk' -File -ErrorAction SilentlyContinue).Count
    $snapshotCount = @(Get-ChildItem -LiteralPath $vmDir -Filter '*.vmsn' -File -ErrorAction SilentlyContinue).Count
    $dumpCount = @(Get-ChildItem -LiteralPath $vmDir -Filter 'vmware-vmx*.dmp' -File -ErrorAction SilentlyContinue).Count

    $mksHits = @(Test-VmwareLogMksCrash -VmDir $vmDir)
    $mksCrash = $mksHits.Count -gt 0

    $findings = [System.Collections.Generic.List[object]]::new()
    $repairs = [System.Collections.Generic.List[object]]::new()

    if ($mksCrash) {
        $findings.Add([pscustomobject]@{
            Id       = 'VMWARE-MKS-001'
            Severity = 'Critical'
            Title    = 'MKS / mksSandbox crash signature'
            Detail   = ("Found {0} log hit(s); typical: ISBRendererComm Lost connection to mksSandbox." -f $mksHits.Count)
            Evidence = @($mksHits | Select-Object -First 3)
        }) | Out-Null
        $enable3dOn = ($enable3d -match '^(TRUE|1|yes)$')
        if ($enable3dOn -or [string]::IsNullOrWhiteSpace($enable3d)) {
            $repairs.Add([pscustomobject]@{
                Id          = 'REPAIR-DISABLE-3D'
                Safe        = $true
                RequiresHitl = $false
                RequiresPoweredOff = $true
                Title       = 'Disable 3D acceleration in .vmx (mks.enable3d = FALSE)'
                Detail      = 'Common mitigation for mksSandbox / ISBRendererComm host GPU renderer crashes. Backs up .vmx under logs/ first.'
            }) | Out-Null
        }
    }

    if ($staleLocks) {
        $findings.Add([pscustomobject]@{
            Id       = 'VMWARE-LOCK-001'
            Severity = 'Important'
            Title    = 'Stale lock files while VM appears powered off'
            Detail   = ("{0} lock item(s) present with no live vmware-vmx for this .vmx." -f $locks.Count)
            Evidence = @($locks | Select-Object -First 8)
        }) | Out-Null
        $repairs.Add([pscustomobject]@{
            Id          = 'REPAIR-CLEAR-STALE-LOCKS'
            Safe        = $true
            RequiresHitl = $false
            RequiresPoweredOff = $true
            Title       = 'Clear stale .lck folders/files'
            Detail      = 'Only when no live vmware-vmx holds this .vmx. Never deletes .vmdk or snapshots.'
        }) | Out-Null
    } elseif ($hasLocks -and $isPoweredOn) {
        $findings.Add([pscustomobject]@{
            Id       = 'VMWARE-LOCK-002'
            Severity = 'Info'
            Title    = 'Lock files present (VM powered on - expected)'
            Detail   = 'Locks are normal while vmware-vmx is running this .vmx.'
            Evidence = @($locks | Select-Object -First 4)
        }) | Out-Null
    }

    if ($vmdkCount -eq 0) {
        $findings.Add([pscustomobject]@{
            Id       = 'VMWARE-DISK-001'
            Severity = 'Critical'
            Title    = 'No .vmdk files in VM folder'
            Detail   = 'Disk descriptors/extents missing - do not auto-repair; HITL required.'
            Evidence = @()
        }) | Out-Null
        $repairs.Add([pscustomobject]@{
            Id          = 'REPAIR-DISK-HITL'
            Safe        = $false
            RequiresHitl = $true
            RequiresPoweredOff = $true
            Title       = 'Investigate missing VMDK (HITL)'
            Detail      = 'Never auto-delete or recreate disks.'
        }) | Out-Null
    }

    if ($dumpCount -gt 0 -and $mksCrash) {
        $findings.Add([pscustomobject]@{
            Id       = 'VMWARE-DUMP-001'
            Severity = 'Important'
            Title    = 'vmware-vmx dump present with MKS crash'
            Detail   = ("{0} dump file(s) in VM folder - useful for vendor support, not auto-deleted." -f $dumpCount)
            Evidence = @()
        }) | Out-Null
    }

    $guestFamily = Get-VmwareGuestFamilyHint -GuestOs $guestOs
    $guestNote = $null
    switch ($guestFamily) {
        'WindowsXP' { $guestNote = 'XP guests: keep VMware Tools matching Workstation major; avoid aggressive 3D.' }
        'Windows7Era' { $guestNote = 'Win7 guests: Tools + 3D often fragile on modern host GPUs; prefer 3D off for industrial software.' }
        'WindowsModern' { $guestNote = 'Win10/11 guests: mksSandbox crashes often tied to host iGPU/dGPU drivers + mks.enable3d.' }
        default { $guestNote = $null }
    }
    if ($guestNote) {
        $findings.Add([pscustomobject]@{
            Id       = 'VMWARE-GUEST-001'
            Severity = 'Info'
            Title    = ("Guest family note ({0})" -f $guestFamily)
            Detail   = $guestNote
            Evidence = @()
        }) | Out-Null
    }

    $severity = 'Ok'
    if ($findings | Where-Object { $_.Severity -eq 'Critical' }) { $severity = 'Critical' }
    elseif ($findings | Where-Object { $_.Severity -eq 'Important' }) { $severity = 'Important' }
    elseif ($findings.Count -gt 0) { $severity = 'Info' }

    return [pscustomobject]@{
        DisplayName       = $displayName
        VmxPath           = $VmxPath
        VmDirectory       = $vmDir
        GuestOs           = $guestOs
        GuestFamily       = $guestFamily
        MemSizeMB         = $(if ($memsize) { [int]$memsize } else { $null })
        NumVcpus          = $(if ($numvcpus) { [int]$numvcpus } else { $null })
        PoweredOn         = $isPoweredOn
        MksEnable3d       = $enable3d
        SvgaGraphicsMemoryKB = $svgaGfx
        SvgaVramSize      = $svgaVram
        LockCount         = $locks.Count
        StaleLocks        = $staleLocks
        Locks             = $locks
        VmdkCount         = $vmdkCount
        SnapshotCount     = $snapshotCount
        DumpCount         = $dumpCount
        MksCrashDetected  = $mksCrash
        MksCrashHits      = $mksHits
        Severity          = $severity
        Findings          = @($findings)
        RecommendedRepairs = @($repairs)
    }
}

function Backup-VmwareVmx {
    param(
        [string]$VmxPath,
        [string]$BackupDirectory
    )
    if (-not (Test-Path -LiteralPath $BackupDirectory)) {
        New-Item -ItemType Directory -Path $BackupDirectory -Force | Out-Null
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $base = [IO.Path]::GetFileNameWithoutExtension($VmxPath)
    $dest = Join-Path $BackupDirectory ("{0}.vmx.rollback-{1}.vmx" -f $base, $stamp)
    Copy-Item -LiteralPath $VmxPath -Destination $dest -Force
    return $dest
}

function Set-VmwareVmxKey {
    param(
        [string]$VmxPath,
        [string]$Key,
        [string]$Value
    )
    $lines = @(Get-Content -LiteralPath $VmxPath -ErrorAction Stop)
    $pattern = '^\s*' + [regex]::Escape($Key) + '\s*='
    $replaced = $false
    $newLines = foreach ($line in $lines) {
        if ($line -match $pattern) {
            $replaced = $true
            '{0} = "{1}"' -f $Key, $Value
        } else {
            $line
        }
    }
    if (-not $replaced) {
        $newLines = @($newLines) + ('{0} = "{1}"' -f $Key, $Value)
    }
    Set-Content -LiteralPath $VmxPath -Value $newLines -Encoding UTF8
}

function Clear-VmwareStaleLocks {
    param(
        [string]$VmDir,
        [switch]$WhatIf
    )
    $removed = @()
    $locks = @(Get-VmwareLockItems -VmDir $VmDir)
    foreach ($lock in $locks) {
        if ($WhatIf) {
            $removed += [pscustomobject]@{ Path = $lock.FullName; Action = 'WouldRemove' }
            continue
        }
        try {
            if ($lock.IsDirectory) {
                Remove-Item -LiteralPath $lock.FullName -Recurse -Force -ErrorAction Stop
            } else {
                Remove-Item -LiteralPath $lock.FullName -Force -ErrorAction Stop
            }
            $removed += [pscustomobject]@{ Path = $lock.FullName; Action = 'Removed' }
        } catch {
            $removed += [pscustomobject]@{ Path = $lock.FullName; Action = 'Failed'; Error = $_.Exception.Message }
        }
    }
    return $removed
}

function Invoke-VmwareSafeRepairs {
    param(
        [object]$VmReport,
        [string]$BackupDirectory,
        [switch]$Apply
    )

    $actions = [System.Collections.Generic.List[object]]::new()
    if (-not $VmReport -or -not $VmReport.RecommendedRepairs) { return @($actions) }

    foreach ($repair in @($VmReport.RecommendedRepairs)) {
        if ($repair.RequiresHitl) {
            $actions.Add([pscustomobject]@{
                RepairId = $repair.Id
                Status   = 'HitlRequired'
                Detail   = $repair.Detail
            }) | Out-Null
            continue
        }
        if ($repair.RequiresPoweredOff -and $VmReport.PoweredOn) {
            $actions.Add([pscustomobject]@{
                RepairId = $repair.Id
                Status   = 'SkippedPoweredOn'
                Detail   = 'VM is powered on; refuse mutating repair without power-off + HITL.'
            }) | Out-Null
            continue
        }

        if ($repair.Id -eq 'REPAIR-CLEAR-STALE-LOCKS') {
            if (-not $Apply) {
                $actions.Add([pscustomobject]@{
                    RepairId = $repair.Id
                    Status   = 'DryRun'
                    Detail   = ("Would clear {0} lock item(s)." -f $VmReport.LockCount)
                }) | Out-Null
            } else {
                $result = Clear-VmwareStaleLocks -VmDir $VmReport.VmDirectory
                $actions.Add([pscustomobject]@{
                    RepairId = $repair.Id
                    Status   = 'Applied'
                    Detail   = 'Cleared stale locks.'
                    Result   = $result
                }) | Out-Null
            }
            continue
        }

        if ($repair.Id -eq 'REPAIR-DISABLE-3D') {
            if (-not $Apply) {
                $actions.Add([pscustomobject]@{
                    RepairId = $repair.Id
                    Status   = 'DryRun'
                    Detail   = 'Would set mks.enable3d = FALSE after .vmx backup.'
                }) | Out-Null
            } else {
                $backup = Backup-VmwareVmx -VmxPath $VmReport.VmxPath -BackupDirectory $BackupDirectory
                Set-VmwareVmxKey -VmxPath $VmReport.VmxPath -Key 'mks.enable3d' -Value 'FALSE'
                $actions.Add([pscustomobject]@{
                    RepairId = $repair.Id
                    Status   = 'Applied'
                    Detail   = 'Set mks.enable3d = FALSE.'
                    Backup   = $backup
                }) | Out-Null
            }
            continue
        }

        $actions.Add([pscustomobject]@{
            RepairId = $repair.Id
            Status   = 'Unsupported'
            Detail   = 'No automated handler.'
        }) | Out-Null
    }

    return @($actions)
}

function New-VmwareHealthReport {
    param(
        [string[]]$InventoryRoots = @(),
        [hashtable]$HubPaths,
        [string]$VmxFilter = '',
        [switch]$Apply,
        [string]$BackupDirectory = ''
    )

    $cfg = Get-VmwareHealthConfig -HubPaths $HubPaths -InventoryRoots $InventoryRoots
    $install = Get-VmwareWorkstationInstall
    $hostPressure = Get-VmwareHostPressure
    $svcHealth = Get-VmwareServiceHealth
    $live = Get-VmwareLiveVmxPaths
    $vmxList = @(Find-VmwareVmxInventory -Roots $cfg.InventoryRoots)

    if (-not [string]::IsNullOrWhiteSpace($VmxFilter)) {
        $filter = $VmxFilter.Trim()
        $vmxList = @($vmxList | Where-Object {
            $_ -like "*$filter*" -or (Split-Path -Parent $_) -like "*$filter*"
        })
        if ($vmxList.Count -eq 0 -and (Test-Path -LiteralPath $filter)) {
            if ($filter -like '*.vmx') { $vmxList = @($filter) }
            else {
                $nested = @(Get-ChildItem -LiteralPath $filter -Filter '*.vmx' -File -Recurse -Depth 3 -ErrorAction SilentlyContinue)
                $vmxList = @($nested | ForEach-Object { $_.FullName })
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($BackupDirectory)) {
        if ($HubPaths -and $HubPaths.Logs) {
            $BackupDirectory = Join-Path $HubPaths.Logs 'vmware-vmx-rollback'
        } else {
            $BackupDirectory = Join-Path $env:TEMP 'vmware-vmx-rollback'
        }
    }

    $vms = @()
    $applied = @()
    foreach ($vmx in ($vmxList | Sort-Object)) {
        $diag = Invoke-VmwareVmDiagnose -VmxPath $vmx -LiveVmxPaths $live
        $repairResult = Invoke-VmwareSafeRepairs -VmReport $diag -BackupDirectory $BackupDirectory -Apply:$Apply
        $diag | Add-Member -NotePropertyName AppliedRepairs -NotePropertyValue $repairResult -Force
        $vms += $diag
        foreach ($a in $repairResult) { $applied += $a }
    }

    $crit = @($vms | Where-Object { $_.Severity -eq 'Critical' }).Count
    $imp = @($vms | Where-Object { $_.Severity -eq 'Important' }).Count
    $mksCount = @($vms | Where-Object { $_.MksCrashDetected }).Count
    $staleCount = @($vms | Where-Object { $_.StaleLocks }).Count
    $poweredOn = @($vms | Where-Object { $_.PoweredOn }).Count

    $bestNext = 'No VMs inventoried - configure Vmware.InventoryRoots or place VMs under D:\Macchine_Virtuali.'
    if ($vms.Count -gt 0) {
        if ($mksCount -gt 0) {
            $bestNext = 'MKS/mksSandbox crash detected: power off affected VM(s), re-run with -Apply to disable 3D (backed-up .vmx) and clear only verified stale locks. Do not force-power-off without HITL.'
        } elseif ($staleCount -gt 0) {
            $bestNext = 'Stale locks found on powered-off VMs: re-run with -Apply to clear locks safely.'
        } elseif ($hostPressure.HighRamPressure) {
            $bestNext = 'Host RAM pressure high - suspend unused VMs before starting another heavy guest.'
        } else {
            $bestNext = 'Inventory healthy enough for normal use; review Info findings if any guest Tools/3D notes apply.'
        }
    }

    if (-not $install.Found) {
        $bestNext = 'VMware Workstation install not found - install/repair Workstation before VM repairs.'
    }

    return [pscustomobject]@{
        SchemaVersion     = $script:VmwareHealthSchema
        GeneratedAt       = (Get-Date).ToString('o')
        Mode              = $(if ($Apply) { 'Apply' } else { 'Audit' })
        InventoryRoots    = @($cfg.InventoryRoots)
        Install           = $install
        Host              = $hostPressure
        Services          = $svcHealth.Services
        Processes         = $svcHealth.Processes
        Summary           = [pscustomobject]@{
            VmCount              = $vms.Count
            PoweredOnCount       = $poweredOn
            CriticalCount        = $crit
            ImportantCount       = $imp
            MksCrashVmCount      = $mksCount
            StaleLockVmCount     = $staleCount
            AppliedActionCount   = @($applied | Where-Object { $_.Status -eq 'Applied' }).Count
            DryRunActionCount    = @($applied | Where-Object { $_.Status -eq 'DryRun' }).Count
            HitlRequiredCount    = @($applied | Where-Object { $_.Status -eq 'HitlRequired' -or $_.Status -eq 'SkippedPoweredOn' }).Count
        }
        BestNextDecision  = $bestNext
        VirtualMachines   = $vms
        Notes             = @(
            'Safe repairs: clear stale locks (powered off only), disable mks.enable3d after .vmx backup.',
            'HITL required: delete .vmdk/snapshots, force power-off, restart VMware services, run vm-support bundle.',
            'Guest OS XP, 7, 10: host-side checks apply to all; 3D and Tools notes are advisory per guest family.'
        )
    }
}
