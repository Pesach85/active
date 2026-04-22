<#
.SYNOPSIS
    System Health Audit - scans hardware, OS config, and services to find
    optimization opportunities.  Outputs a structured JSON report that the
    GUI parses and displays as actionable findings.

.DESCRIPTION
    Each finding carries:
      Severity   : Critical | Important | Moderate | Info
      Category   : Disk | Memory | Driver | Service | OS | Power | Network
      Invasiveness levels with concrete fix commands (Safe / Moderate / Aggressive)
    The JSON schema is hardware-agnostic: the audit engine populates it from
    whatever it detects.  A companion script (apply-safe-fixes.ps1) can consume
    the same JSON and execute selected fixes.

.PARAMETER OutputJson
    Path where the JSON report is written.

.PARAMETER KnowledgeBase
    Optional path to a JSON knowledge-base file with learned solutions for
    hardware variants.  If absent the engine uses built-in heuristics only.
#>
param(
    [Parameter(Mandatory)][string]$OutputJson,
    [string]$KnowledgeBase
)

$ErrorActionPreference = 'Continue'

# â”€â”€ helpers â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
function Write-Progress2 { param([string]$Msg) Write-Host "[AUDIT] $Msg" }

function New-Finding {
    param(
        [string]$Id,
        [string]$Severity,      # Critical | Important | Moderate | Info
        [string]$Category,      # Disk | Memory | Driver | Service | OS | Power | Network
        [string]$Title,
        [string]$Description,
        [string]$CurrentValue,
        [string]$RecommendedValue,
        [string]$Impact,
        [hashtable[]]$Solutions  # each: { Level, Label, Command, Rollback, RiskNote }
    )
    return [ordered]@{
        Id               = $Id
        Severity         = $Severity
        Category         = $Category
        Title            = $Title
        Description      = $Description
        CurrentValue     = $CurrentValue
        RecommendedValue = $RecommendedValue
        Impact           = $Impact
        Solutions        = $Solutions
        Applied          = $false
        AppliedLevel     = $null
        AppliedAt        = $null
    }
}

function New-Solution {
    param(
        [string]$Level,    # Safe | Moderate | Aggressive
        [string]$Label,
        [string]$Command,
        [string]$Rollback,
        [string]$RiskNote
    )
    return @{
        Level    = $Level
        Label    = $Label
        Command  = $Command
        Rollback = $Rollback
        RiskNote = $RiskNote
    }
}

function New-OfficeM365ChannelFinding {
    param(
        [string]$CurrentBranch,
        [string]$CurrentProduct,
        [string]$RecommendedChannels,
        [string]$RepairScriptPath
    )

    $inspectCommand = "& '$RepairScriptPath'"
    $repairCommand = "& '$RepairScriptPath' -Apply -PreferredChannel MonthlyEnterprise"
    $rollbackCommand = "& '$RepairScriptPath' -RestoreLatest"
    $currentValue = if ([string]::IsNullOrWhiteSpace($CurrentProduct)) {
        "Policy branch=$CurrentBranch; ClickToRun=NotInstalled"
    } else {
        "Policy branch=$CurrentBranch; Product=$CurrentProduct"
    }

    $solutions = @(
        (New-Solution -Level 'Safe' -Label 'Inspect current Office channel compatibility' `
            -Command $inspectCommand `
            -Rollback 'N/A (read-only)' `
            -RiskNote 'Read-only assessment of policy and Click-to-Run state.'),
        (New-Solution -Level 'Safe' -Label 'Align Office policy to Monthly Enterprise Channel for Microsoft 365 Apps' `
            -Command $repairCommand `
            -Rollback $rollbackCommand `
            -RiskNote 'Creates a JSON backup before changing the Office update policy.')
    )

    return New-Finding `
        -Id 'OFFICE-CHANNEL-001' `
        -Severity 'Important' `
        -Category 'OS' `
        -Title 'Office update channel policy incompatible with Microsoft 365 Apps' `
        -Description "A perpetual/LTSC Office channel is configured on this PC. That blocks Microsoft 365 Apps installations and updates with the error 'Questo prodotto non puo essere installato con il canale di aggiornamento selezionato'." `
        -CurrentValue $currentValue `
        -RecommendedValue "Microsoft 365 Business Standard supports: $RecommendedChannels. Recommended default: Monthly Enterprise Channel." `
        -Impact 'Office install/update remains blocked until the policy is moved away from Perpetual/LTSC.' `
        -Solutions $solutions
}

function Test-CommandAvailable {
    param([string]$Name)

    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Test-WingetPackageInstalled {
    param([string]$PackageId)

    if (-not (Test-CommandAvailable -Name 'winget')) {
        return $false
    }

    $stdoutPath = [System.IO.Path]::Combine($env:TEMP, ("winget-list-{0}.out.log" -f ([guid]::NewGuid().ToString("N"))))
    $stderrPath = [System.IO.Path]::Combine($env:TEMP, ("winget-list-{0}.err.log" -f ([guid]::NewGuid().ToString("N"))))

    try {
        $args = @(
            'list',
            '--id', $PackageId,
            '--exact',
            '--accept-source-agreements'
        )

        $proc = Start-Process -FilePath 'winget' -ArgumentList $args -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
        $finished = $proc.WaitForExit(12000)
        if (-not $finished) {
            try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
            return $false
        }

        if (-not (Test-Path -LiteralPath $stdoutPath)) {
            return $false
        }

        $out = Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue
        if (-not $out) { return $false }
        return ($out -match [regex]::Escape($PackageId))
    } catch {
        return $false
    } finally {
        Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

# â”€â”€ collector arrays â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
$findings = [System.Collections.ArrayList]::new()
$hardwareProfile = [ordered]@{}

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#  PHASE 1 - Hardware Inventory
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
Write-Progress2 "Collecting hardware inventory..."

# --- CPU ---
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$hardwareProfile.CPU = [ordered]@{
    Model       = $cpu.Name.Trim()
    Cores       = [int]$cpu.NumberOfCores
    Threads     = [int]$cpu.NumberOfLogicalProcessors
    MaxClockMHz = [int]$cpu.MaxClockSpeed
    CacheL3KB   = [int]($cpu.L3CacheSize)
}

# --- RAM ---
$dimms = @(Get-CimInstance Win32_PhysicalMemory)
$totalRAM = ($dimms | Measure-Object -Property Capacity -Sum).Sum
$slotsUsed = $dimms.Count
$slotsTotal = (Get-CimInstance Win32_PhysicalMemoryArray | Select-Object -First 1).MemoryDevices
$isDualChannel = $slotsUsed -ge 2
$hardwareProfile.RAM = [ordered]@{
    TotalGB      = [math]::Round($totalRAM / 1GB, 1)
    SlotsUsed    = $slotsUsed
    SlotsTotal   = [int]$slotsTotal
    DualChannel  = $isDualChannel
    Modules      = @($dimms | ForEach-Object {
        [ordered]@{
            SizeGB    = [math]::Round($_.Capacity / 1GB, 1)
            Speed     = [int]$_.Speed
            PartNum   = ($_.PartNumber -replace '\s+$','')
            Slot      = $_.DeviceLocator
        }
    })
}

# --- Disks ---
$physDisks = @(Get-PhysicalDisk)
$volumes = @(Get-Volume | Where-Object { $_.DriveLetter })
$hardwareProfile.Disks = @($physDisks | ForEach-Object {
    [ordered]@{
        DeviceId     = [string]$_.DeviceId
        Model        = $_.FriendlyName
        MediaType    = [string]$_.MediaType
        BusType      = [string]$_.BusType
        SizeGB       = [math]::Round($_.Size / 1GB, 1)
        Health       = [string]$_.HealthStatus
        OpStatus     = [string]$_.OperationalStatus
        FirmwareRev  = $_.FirmwareRevision
    }
})
$hardwareProfile.Volumes = @($volumes | ForEach-Object {
    $sizeGB = [math]::Round($_.Size / 1GB, 1)
    $freeGB = [math]::Round($_.SizeRemaining / 1GB, 1)
    $freePct = if ($_.Size -gt 0) { [math]::Round(($_.SizeRemaining / $_.Size) * 100, 1) } else { 0 }
    [ordered]@{
        Drive    = "$($_.DriveLetter):"
        Label    = $_.FileSystemLabel
        SizeGB   = $sizeGB
        FreeGB   = $freeGB
        FreePct  = $freePct
        FileSystem = [string]$_.FileSystemType
    }
})

# --- OS ---
$ntVer = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -EA SilentlyContinue
$bios  = Get-CimInstance Win32_BIOS | Select-Object -First 1
$cs    = Get-CimInstance Win32_ComputerSystem | Select-Object -First 1
$hardwareProfile.System = [ordered]@{
    Manufacturer = $cs.Manufacturer
    Model        = $cs.Model
    OSVersion    = "$($ntVer.ProductName) $($ntVer.DisplayVersion)"
    OSBuild      = "$($ntVer.CurrentBuild).$($ntVer.UBR)"
    BIOS         = $bios.SMBIOSBIOSVersion
    BIOSDate     = if ($bios.ReleaseDate) { $bios.ReleaseDate.ToString('yyyy-MM-dd') } else { 'Unknown' }
}

# --- Storage Controller ---
$rstDrv = Get-CimInstance Win32_PnPSignedDriver -EA SilentlyContinue |
    Where-Object { $_.DeviceName -match 'Intel.*Chipset.*SATA.*RST|iaStore' } | Select-Object -First 1
if ($rstDrv) {
    $hardwareProfile.StorageController = [ordered]@{
        Name     = $rstDrv.DeviceName
        Driver   = $rstDrv.DriverVersion
        Date     = if ($rstDrv.DriverDate) { $rstDrv.DriverDate.ToString('yyyy-MM-dd') } else { 'Unknown' }
    }
}

# --- Network adapters ---
$netAdapters = @(Get-NetAdapter -EA SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'VMware|Tailscale|Loopback' })
$hardwareProfile.Network = @($netAdapters | ForEach-Object {
    [ordered]@{
        Name    = $_.Name
        Desc    = $_.InterfaceDescription
        Driver  = $_.DriverVersion
        LinkSpeed = $_.LinkSpeed
    }
})

# --- GPU ---
$gpus = @(Get-CimInstance Win32_VideoController)
$hardwareProfile.GPU = @($gpus | ForEach-Object {
    [ordered]@{
        Name    = $_.Name
        Driver  = $_.DriverVersion
        VRAM_MB = [math]::Round($_.AdapterRAM / 1MB, 0)
    }
})

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#  PHASE 2 - Finding Detection
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
Write-Progress2 "Analyzing disk health..."

# â”€â”€ DISK HEALTH â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
foreach ($pd in $physDisks) {
    if ($pd.HealthStatus -ne 'Healthy') {
        [void]$findings.Add((New-Finding `
            -Id 'DISK-HEALTH-001' `
            -Severity 'Critical' `
            -Category 'Disk' `
            -Title "$($pd.FriendlyName): $($pd.OperationalStatus)" `
            -Description "Physical disk reports non-healthy status. This may indicate imminent failure. SMART data blocked by Intel RST RAID layer." `
            -CurrentValue "$($pd.HealthStatus) / $($pd.OperationalStatus)" `
            -RecommendedValue 'Healthy / OK' `
            -Impact 'Risk of data loss. All optimizations are secondary to this.' `
            -Solutions @(
                (New-Solution -Level 'Safe' -Label 'Install CrystalDiskInfo for SMART bypass' `
                    -Command 'winget install --id CrystalDewWorld.CrystalDiskInfo --accept-package-agreements --accept-source-agreements' `
                    -Rollback 'winget uninstall CrystalDewWorld.CrystalDiskInfo' `
                    -RiskNote 'Read-only diagnostic. No system changes.'),
                (New-Solution -Level 'Moderate' -Label 'Create full system backup now' `
                    -Command 'wbadmin start backup -backupTarget:D: -include:C: -quiet 2>&1' `
                    -Rollback 'N/A (backup only)' `
                    -RiskNote 'Requires D: has free space. Long running.'),
                (New-Solution -Level 'Aggressive' -Label 'Plan disk replacement (manual)' `
                    -Command 'Write-Host "ACTION REQUIRED: Purchase replacement NVMe SSD and clone with Clonezilla or Macrium Reflect."' `
                    -Rollback 'N/A' `
                    -RiskNote 'Hardware purchase required.')
            )))
    }
}

# â”€â”€ DISK SPACE â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
Write-Progress2 "Analyzing disk space..."
foreach ($vol in $volumes) {
    $sizeGB = [math]::Round($vol.Size / 1GB, 1)
    $freeGB = [math]::Round($vol.SizeRemaining / 1GB, 1)
    $freePct = if ($vol.Size -gt 0) { [math]::Round(($vol.SizeRemaining / $vol.Size) * 100, 1) } else { 100 }
    $letter = $vol.DriveLetter

    if ($freePct -lt 5) {
        $severity = 'Critical'
    } elseif ($freePct -lt 15) {
        $severity = 'Important'
    } elseif ($freePct -lt 25) {
        $severity = 'Moderate'
    } else {
        continue
    }

    $solutions = [System.Collections.ArrayList]::new()

    # Check hibernation
    $hiberPath = "${letter}:\hiberfil.sys"
    $hiberSizeGB = 0
    if (Test-Path $hiberPath -EA SilentlyContinue) {
        try {
            $hiberSizeGB = [math]::Round((Get-Item $hiberPath -Force -EA Stop).Length / 1GB, 1)
        } catch { $hiberSizeGB = 0 }
    }
    if ($hiberSizeGB -gt 0 -and $letter -eq 'C') {
        [void]$solutions.Add((New-Solution -Level 'Safe' -Label "Disable hibernation (free ~${hiberSizeGB} GB)" `
            -Command 'powercfg /hibernate off' `
            -Rollback 'powercfg /hibernate on' `
            -RiskNote 'Disables hibernate and Fast Startup. Sleep (S3) still works.'))
    }

    # Check pagefile
    if ($letter -eq 'C') {
        $pfUsage = Get-CimInstance Win32_PageFileUsage -EA SilentlyContinue | Select-Object -First 1
        if ($pfUsage) {
            $pfSizeGB = [math]::Round($pfUsage.AllocatedBaseSize / 1024, 1)
            $ramGB = [math]::Round($totalRAM / 1GB, 0)
            $recommendedPF = [math]::Max(4, [math]::Floor($ramGB / 2))
            if ($pfSizeGB -gt ($recommendedPF + 2)) {
                [void]$solutions.Add((New-Solution -Level 'Safe' -Label "Reduce pagefile from ${pfSizeGB} GB to ${recommendedPF} GB (free ~$([math]::Round($pfSizeGB - $recommendedPF, 0)) GB after reboot)" `
                    -Command "
`$pf = Get-CimInstance Win32_PageFileSetting -Filter `"Name='c:\\\\pagefile.sys'`" -EA SilentlyContinue
if (`$pf) { `$pf | Set-CimInstance -Property @{InitialSize=$($recommendedPF * 1024); MaximumSize=$($recommendedPF * 1024)} }
else { New-CimInstance -ClassName Win32_PageFileSetting -Property @{Name='c:\\pagefile.sys'; InitialSize=$($recommendedPF * 1024); MaximumSize=$($recommendedPF * 1024)} }
Write-Host 'Pagefile set to ${recommendedPF} GB. Reboot to apply.'" `
                    -Rollback "
`$pf = Get-CimInstance Win32_PageFileSetting -Filter `"Name='c:\\\\pagefile.sys'`" -EA SilentlyContinue
if (`$pf) { `$pf | Set-CimInstance -Property @{InitialSize=$($pfSizeGB * 1024); MaximumSize=$($pfSizeGB * 1024)} }" `
                    -RiskNote "Effective after reboot. If heavy workloads cause OOM, revert to original size."))
            }
        }
    }

    # DISM cleanup (only on C:)
    if ($letter -eq 'C') {
        [void]$solutions.Add((New-Solution -Level 'Safe' -Label 'DISM Component Store cleanup' `
            -Command 'Dism /Online /Cleanup-Image /StartComponentCleanup /ResetBase 2>&1 | ForEach-Object { Write-Host $_ }' `
            -Rollback 'N/A (removes old update backups only)' `
            -RiskNote 'Cannot uninstall previously installed Windows updates afterwards. Safe for stable systems.'))
    }

    # Temp cleanup
    if ($letter -eq 'C') {
        $tempSizeMB = 0
        $tempPath = [System.IO.Path]::GetTempPath()
        $winTemp = 'C:\Windows\Temp'
        foreach ($tp in @($tempPath, $winTemp)) {
            if (Test-Path $tp) {
                $tempSizeMB += [math]::Round(((Get-ChildItem $tp -Recurse -Force -EA SilentlyContinue |
                    Measure-Object -Property Length -Sum -EA SilentlyContinue).Sum / 1MB), 0)
            }
        }
        if ($tempSizeMB -gt 100) {
            $tempSizeGB = [math]::Round($tempSizeMB / 1024, 1)
            [void]$solutions.Add((New-Solution -Level 'Safe' -Label "Clean TEMP files older than 3 days (~${tempSizeGB} GB)" `
                -Command "
`$cleaned = 0
foreach (`$tp in @([System.IO.Path]::GetTempPath(), 'C:\Windows\Temp')) {
    Get-ChildItem `$tp -Recurse -Force -EA SilentlyContinue |
        Where-Object { -not `$_.PSIsContainer -and `$_.LastWriteTime -lt (Get-Date).AddDays(-3) } |
        ForEach-Object { try { Remove-Item `$_.FullName -Force -EA Stop; `$cleaned++ } catch {} }
}
Write-Host `"Removed `$cleaned temp files.`"" `
                -Rollback 'N/A (temp files only)' `
                -RiskNote 'Only removes files untouched for 3+ days. Running applications unaffected.'))
        }
    }

    [void]$findings.Add((New-Finding `
        -Id "DISK-SPACE-$letter" `
        -Severity $severity `
        -Category 'Disk' `
        -Title "${letter}: drive space critically low" `
        -Description "${letter}: has ${freeGB} GB free of ${sizeGB} GB (${freePct}%). Windows needs at least 10-15% free for optimal I/O performance, temp files, and updates." `
        -CurrentValue "${freeGB} GB free (${freePct}%)" `
        -RecommendedValue 'At least 15% free' `
        -Impact 'Severe I/O degradation, write amplification on SSD, unable to defragment, Windows Update failures.' `
        -Solutions @($solutions.ToArray())))
}

# â”€â”€ RAM SINGLE-CHANNEL â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
Write-Progress2 "Analyzing memory configuration..."
if (-not $isDualChannel -and $slotsTotal -ge 2) {
    $currentModule = $dimms[0]
    $speedMT = [int]$currentModule.Speed
    $partNum = ($currentModule.PartNumber -replace '\s+$','')
    [void]$findings.Add((New-Finding `
        -Id 'RAM-CHANNEL-001' `
        -Severity 'Critical' `
        -Category 'Memory' `
        -Title "RAM running in single-channel ($slotsUsed of $slotsTotal slots)" `
        -Description "Only $slotsUsed DIMM slot is populated. Dual-channel mode doubles memory bandwidth. Current: ~$([math]::Round($speedMT * 8 / 1000, 1)) GB/s single. Potential: ~$([math]::Round($speedMT * 8 * 2 / 1000, 1)) GB/s dual." `
        -CurrentValue "Single-channel, $slotsUsed of $slotsTotal slots, $partNum @ ${speedMT} MT/s" `
        -RecommendedValue "Dual-channel (2 matching DIMMs)" `
        -Impact "~40% memory bandwidth penalty affecting all workloads, especially VMs, compilation, and multi-threaded IO." `
        -Solutions @(
            (New-Solution -Level 'Info' -Label "Add matching DIMM: DDR4-${speedMT} SODIMM ($([math]::Round($currentModule.Capacity / 1GB, 0)) GB)" `
                -Command "Write-Host 'HARDWARE: Add a matching DDR4-${speedMT} SODIMM to the empty slot. Compatible part: ${partNum} or equivalent.'" `
                -Rollback 'Remove added DIMM' `
                -RiskNote 'Hardware purchase required. ~25-40 EUR.')
        )))
}

# â”€â”€ INTEL RST DRIVER â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
Write-Progress2 "Checking storage controller driver..."
if ($rstDrv) {
    $rstVersionStr = $rstDrv.DriverVersion
    $rstMajor = 0
    if ($rstVersionStr -match '^(\d+)\.') { $rstMajor = [int]$Matches[1] }
    $anyRaid = ($physDisks | Where-Object { $_.BusType -eq 'RAID' }).Count -gt 0

    if ($rstMajor -lt 19) {
        [void]$findings.Add((New-Finding `
            -Id 'DRIVER-RST-001' `
            -Severity 'Important' `
            -Category 'Driver' `
            -Title "Intel RST driver outdated (v$rstVersionStr)" `
            -Description "Current Intel RST driver is v$rstVersionStr. Latest stable branch is v19.x (2024). Outdated driver may cause SMART visibility issues and suboptimal NVMe latency." `
            -CurrentValue "v$rstVersionStr" `
            -RecommendedValue 'v19.5.x or later' `
            -Impact 'Improved NVMe latency, SMART passthrough, and TRIM scheduling.' `
            -Solutions @(
                (New-Solution -Level 'Info' -Label 'Check Intel download page for update' `
                    -Command 'Start-Process "https://www.intel.com/content/www/us/en/download/720755/intel-rapid-storage-technology-driver-installation-software-with-intel-optane-memory.html"' `
                    -Rollback 'Restore previous driver via Device Manager > Roll Back Driver' `
                    -RiskNote 'Manual update from Intel website. Create restore point first.')
            )))
    }

    if ($anyRaid) {
        [void]$findings.Add((New-Finding `
            -Id 'DRIVER-RST-002' `
            -Severity 'Moderate' `
            -Category 'Driver' `
            -Title 'Intel RST RAID mode active (AHCI may be better)' `
            -Description "Disks report BusType=RAID. If no actual RAID arrays exist, AHCI mode provides lower NVMe latency, native SMART access, and better Windows TRIM integration." `
            -CurrentValue 'RAID mode (iaStorAC)' `
            -RecommendedValue 'AHCI (if no RAID arrays)' `
            -Impact 'Lower NVMe latency, native SMART, native TRIM scheduling.' `
            -Solutions @(
                (New-Solution -Level 'Aggressive' -Label 'Switch BIOS to AHCI (requires safe-mode prep)' `
                    -Command "
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\iaStorV' -Name Start -Value 0 -EA SilentlyContinue
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\iaStorAVC\StartOverride' -Name 0 -Value 0 -EA SilentlyContinue
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\storahci' -Name Start -Value 0 -EA SilentlyContinue
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\storahci\StartOverride' -Name 0 -Value 0 -EA SilentlyContinue
Write-Host 'Registry prepared. REBOOT INTO SAFE MODE, then change BIOS from RAID to AHCI, then reboot normally.'" `
                    -Rollback 'Revert BIOS to RAID mode. Windows will auto-detect.' `
                    -RiskNote 'HIGH RISK if procedure not followed exactly. Create full backup first. Must reboot in Safe Mode before BIOS change.')
            )))
    }
}

# â”€â”€ SERVICES â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
Write-Progress2 "Analyzing running services..."
$heavyServices = @(
    @{ Name='MySQL80';                    Desc='MySQL Server';             Note='Database server' },
    @{ Name='AnyDesk';                    Desc='AnyDesk Remote';           Note='Remote desktop' },
    @{ Name='CODESYS Gateway V3';         Desc='CODESYS Gateway';          Note='PLC gateway' },
    @{ Name='CODESYS ServiceControl';     Desc='CODESYS Service';          Note='PLC service' },
    @{ Name='W3SVC';                      Desc='IIS Web Server';           Note='Web server' },
    @{ Name='IISADMIN';                   Desc='IIS Admin';                Note='IIS management' },
    @{ Name='WAS';                        Desc='WAS (Process Activation)'; Note='IIS activation' },
    @{ Name='AppHostSvc';                 Desc='IIS App Host Helper';      Note='IIS helper' },
    @{ Name='FlexNet Licensing Service 64'; Desc='FlexNet Licensing';      Note='License manager' },
    @{ Name='Autocad2010';                Desc='AutoCAD 2010 Service';     Note='Legacy AutoCAD' },
    @{ Name='SharedAccess';               Desc='Internet Conn Sharing';    Note='ICS' },
    @{ Name='AdobeARMservice';            Desc='Adobe Update Service';     Note='Adobe updater' },
    @{ Name='SRManagementToolFtpServer';  Desc='SR FTP Server';            Note='FTP server' },
    @{ Name='SRManagementToolFileMonitorService'; Desc='SR File Monitor';  Note='File monitor' },
    @{ Name='Spooler';                    Desc='Print Spooler';            Note='Printing' }
)

$runningHeavy = [System.Collections.ArrayList]::new()
foreach ($svcDef in $heavyServices) {
    $svc = Get-Service -Name $svcDef.Name -EA SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running' -and $svc.StartType -ne 'Manual') {
        [void]$runningHeavy.Add(@{ Name = $svcDef.Name; Desc = $svcDef.Desc; Note = $svcDef.Note; StartType = [string]$svc.StartType })
    }
}

if ($runningHeavy.Count -gt 0) {
    $svcNames = ($runningHeavy | ForEach-Object { $_.Name })
    $svcList = ($runningHeavy | ForEach-Object { "  - $($_.Desc) ($($_.Name)): $($_.Note)" }) -join "`n"
    $setManualCmd = ($svcNames | ForEach-Object { "Set-Service -Name '$_' -StartupType Manual -EA SilentlyContinue" }) -join "`n"
    [void]$findings.Add((New-Finding `
        -Id 'SERVICE-HEAVY-001' `
        -Severity 'Moderate' `
        -Category 'Service' `
        -Title "$($runningHeavy.Count) non-essential services running at Auto start" `
        -Description "These services start automatically but may not be needed constantly:`n$svcList" `
        -CurrentValue "$($runningHeavy.Count) services at Automatic start" `
        -RecommendedValue 'Set to Manual (start on demand)' `
        -Impact "Reduced boot time, lower background RAM/CPU usage (~50-200 MB)." `
        -Solutions @(
            (New-Solution -Level 'Safe' -Label "Set $($runningHeavy.Count) services to Manual start (no stop)" `
                -Command $setManualCmd `
                -Rollback ($svcNames | ForEach-Object { "Set-Service -Name '$_' -StartupType Automatic -EA SilentlyContinue" }) -join "`n" `
                -RiskNote 'Services will still start when needed. Only changes boot behavior. Running services NOT stopped.'),
            (New-Solution -Level 'Moderate' -Label "Set to Manual AND stop now" `
                -Command (($svcNames | ForEach-Object { "Set-Service -Name '$_' -StartupType Manual -EA SilentlyContinue; Stop-Service -Name '$_' -Force -EA SilentlyContinue" }) -join "`n") `
                -Rollback (($svcNames | ForEach-Object { "Set-Service -Name '$_' -StartupType Automatic -EA SilentlyContinue; Start-Service -Name '$_' -EA SilentlyContinue" }) -join "`n") `
                -RiskNote 'Stops services immediately. Any active connections (DB queries, remote sessions, web requests) will be interrupted.')
        )))
}

# â”€â”€ STARTUP PROGRAMS â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
Write-Progress2 "Checking startup programs..."
$startupEntries = [System.Collections.ArrayList]::new()
foreach ($regPath in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run')) {
    $props = Get-ItemProperty $regPath -EA SilentlyContinue
    if ($props) {
        $props.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS|^\(default\)$|^SecurityHealth' } | ForEach-Object {
            [void]$startupEntries.Add(@{ Name = $_.Name; Value = $_.Value; Path = $regPath })
        }
    }
}

if ($startupEntries.Count -gt 0) {
    $startupList = ($startupEntries | ForEach-Object { "  - $($_.Name)" }) -join "`n"
    $removeCmd = ($startupEntries | ForEach-Object {
        "Remove-ItemProperty -Path '$($_.Path)' -Name '$($_.Name)' -EA SilentlyContinue"
    }) -join "`n"
    $restoreCmd = ($startupEntries | ForEach-Object {
        "Set-ItemProperty -Path '$($_.Path)' -Name '$($_.Name)' -Value '$($_.Value -replace "'","''")' -EA SilentlyContinue"
    }) -join "`n"
    [void]$findings.Add((New-Finding `
        -Id 'STARTUP-001' `
        -Severity 'Moderate' `
        -Category 'OS' `
        -Title "$($startupEntries.Count) non-essential startup programs" `
        -Description "Programs launching at login:`n$startupList" `
        -CurrentValue "$($startupEntries.Count) startup entries" `
        -RecommendedValue 'Remove non-essential entries' `
        -Impact "Faster login, lower background resource usage." `
        -Solutions @(
            (New-Solution -Level 'Safe' -Label 'Review startup entries (no changes)' `
                -Command "Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -EA SilentlyContinue | Format-List *" `
                -Rollback 'N/A' `
                -RiskNote 'Read-only review.'),
            (New-Solution -Level 'Moderate' -Label "Remove all $($startupEntries.Count) startup entries" `
                -Command $removeCmd `
                -Rollback $restoreCmd `
                -RiskNote 'Programs will no longer auto-start. They can still be launched manually.')
        )))
}

# â”€â”€ NTFS TUNING â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
Write-Progress2 "Checking NTFS/filesystem tuning..."

$memUsage = 0
$mftZone = 0
$sysResp = 20
try { $memUsageRaw = (fsutil behavior query memoryusage 2>$null); if ($memUsageRaw -match '=\s*(\d+)') { $memUsage = [int]$Matches[1] } } catch {}
try { $mftZoneRaw = (fsutil behavior query mftzone 2>$null); if ($mftZoneRaw -match '=\s*(\d+)') { $mftZone = [int]$Matches[1] } } catch {}
try { $srKey = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' -EA SilentlyContinue; if ($srKey) { $sysResp = [int]$srKey.SystemResponsiveness } } catch {}

$ntfsSolutions = [System.Collections.ArrayList]::new()
if ($memUsage -lt 2 -and $totalRAM -ge 8GB) {
    [void]$ntfsSolutions.Add((New-Solution -Level 'Safe' -Label 'Increase NTFS memory for metadata caching' `
        -Command 'fsutil behavior set memoryusage 2' `
        -Rollback 'fsutil behavior set memoryusage 0' `
        -RiskNote 'Allocates more kernel pool to NTFS cache. Reversible. Effective immediately.'))
}
if ($mftZone -lt 2) {
    [void]$ntfsSolutions.Add((New-Solution -Level 'Safe' -Label 'Increase MFT zone reservation (after freeing space)' `
        -Command 'fsutil behavior set mftzone 2' `
        -Rollback 'fsutil behavior set mftzone 0' `
        -RiskNote 'Reserves 600 MB for MFT growth. Effective on next volume mount. Best after freeing space.'))
}
if ($sysResp -gt 10) {
    [void]$ntfsSolutions.Add((New-Solution -Level 'Safe' -Label "Reduce SystemResponsiveness from $sysResp to 10" `
        -Command "Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' -Name 'SystemResponsiveness' -Value 10" `
        -Rollback "Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' -Name 'SystemResponsiveness' -Value $sysResp" `
        -RiskNote 'Gives more CPU time to foreground apps. Background tasks get slightly less resources.'))
}

if ($ntfsSolutions.Count -gt 0) {
    [void]$findings.Add((New-Finding `
        -Id 'OS-NTFS-001' `
        -Severity 'Moderate' `
        -Category 'OS' `
        -Title "$($ntfsSolutions.Count) NTFS/system tuning opportunities" `
        -Description "NTFS MemoryUsage=$memUsage (rec: 2), MFT Zone=$mftZone (rec: 2), SystemResponsiveness=$sysResp (rec: 10)" `
        -CurrentValue "MemUsage=$memUsage, MftZone=$mftZone, SysResp=$sysResp" `
        -RecommendedValue 'MemUsage=2, MftZone=2, SysResp=10' `
        -Impact 'Better NTFS cache performance and foreground responsiveness.' `
        -Solutions @($ntfsSolutions.ToArray())))
}

# â”€â”€ VISUAL EFFECTS â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
Write-Progress2 "Checking visual effects..."
$vfx = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' -EA SilentlyContinue
$vfxSetting = if ($vfx) { [int]$vfx.VisualFXSetting } else { 3 }
if ($vfxSetting -ne 2) {
    $vfxLabel = switch ($vfxSetting) { 0 { 'Custom' } 1 { 'Best Appearance' } 3 { 'Let Windows Decide' } default { "Unknown ($vfxSetting)" } }
    [void]$findings.Add((New-Finding `
        -Id 'OS-VFX-001' `
        -Severity 'Info' `
        -Category 'OS' `
        -Title "Visual effects set to '$vfxLabel'" `
        -Description 'Animations and transparency consume GPU/CPU resources. Setting to Best Performance disables all visual effects.' `
        -CurrentValue $vfxLabel `
        -RecommendedValue 'Best Performance (2)' `
        -Impact 'Minor CPU/GPU savings. UI becomes less visually polished.' `
        -Solutions @(
            (New-Solution -Level 'Safe' -Label 'Set visual effects to Best Performance' `
                -Command "Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' -Name 'VisualFXSetting' -Value 2" `
                -Rollback "Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' -Name 'VisualFXSetting' -Value $vfxSetting" `
                -RiskNote 'Purely cosmetic change. Fully reversible.')
        )))
}

# â”€â”€ POWER PLAN CHECK â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
Write-Progress2 "Checking power plan..."
$activePlan = powercfg /getactivescheme 2>$null
$isHighPerf = $activePlan -match '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
if (-not $isHighPerf) {
    [void]$findings.Add((New-Finding `
        -Id 'POWER-001' `
        -Severity 'Important' `
        -Category 'Power' `
        -Title 'Power plan is not High Performance' `
        -Description "Current plan may throttle CPU and disk performance. High Performance prevents power-saving downclock." `
        -CurrentValue ($activePlan -replace '.*:\s*','').Trim() `
        -RecommendedValue 'High Performance' `
        -Impact 'Prevents CPU throttling under load. Higher power consumption on battery.' `
        -Solutions @(
            (New-Solution -Level 'Safe' -Label 'Switch to High Performance' `
                -Command 'powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' `
                -Rollback 'powercfg /setactive 381b4222-f694-41f0-9685-ff5bb260df2e' `
                -RiskNote 'Higher battery drain on battery power.')
        )))
}

# â”€â”€ ALREADY OPTIMIZED (positive findings) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
Write-Progress2 "Collecting positive findings..."
$positives = [System.Collections.ArrayList]::new()
$repairOfficeChannelScript = Join-Path $PSScriptRoot 'repair-office-m365-channel.ps1'
$recommendedM365Channels = 'Current Channel, Monthly Enterprise Channel, Semi-Annual Enterprise Channel'

# â”€â”€ OFFICE UPDATE CHANNEL â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
Write-Progress2 "Checking Office update channel compatibility..."
$officePolicyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate'
$officePolicy = Get-ItemProperty -LiteralPath $officePolicyPath -EA SilentlyContinue
$officeBranch = ''
if ($officePolicy -and ($officePolicy.PSObject.Properties.Name -contains 'UpdateBranch')) {
    $officeBranch = [string]$officePolicy.UpdateBranch
}

$officeClickToRun = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -EA SilentlyContinue
$officeProduct = ''
$officeUpdateChannel = ''
$officeCdnBase = ''
if ($officeClickToRun) {
    if ($officeClickToRun.PSObject.Properties.Name -contains 'ProductReleaseIds') {
        $officeProduct = [string]$officeClickToRun.ProductReleaseIds
    }
    if ($officeClickToRun.PSObject.Properties.Name -contains 'UpdateChannel') {
        $officeUpdateChannel = [string]$officeClickToRun.UpdateChannel
    }
    if ($officeClickToRun.PSObject.Properties.Name -contains 'CDNBaseUrl') {
        $officeCdnBase = [string]$officeClickToRun.CDNBaseUrl
    }
}

$officeMismatch = $false
if ($officeBranch -match 'Perpetual|LTSC') {
    $officeMismatch = $true
}
if ($officeProduct -match 'Perpetual|LTSC|2021Volume|2024Volume') {
    $officeMismatch = $true
}
if ($officeUpdateChannel -match 'Perpetual|LTSC') {
    $officeMismatch = $true
}
if ($officeCdnBase -match 'Perpetual|LTSC') {
    $officeMismatch = $true
}

if ($officeMismatch -and (Test-Path -LiteralPath $repairOfficeChannelScript)) {
    [void]$findings.Add((New-OfficeM365ChannelFinding -CurrentBranch $officeBranch -CurrentProduct $officeProduct -RecommendedChannels $recommendedM365Channels -RepairScriptPath $repairOfficeChannelScript))
} elseif (-not [string]::IsNullOrWhiteSpace($officeBranch) -and ($officeBranch -in @('Current', 'MonthlyEnterprise', 'SemiAnnualEnterprise'))) {
    [void]$positives.Add(("Office channel aligned for Microsoft 365 Apps ({0})" -f $officeBranch))
}

# â”€â”€ REQUIRED SYSTEM PACKAGES â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
Write-Progress2 "Checking required system packages..."

$wingetAvailable = Test-CommandAvailable -Name 'winget'
$pwshInfo = Get-Command pwsh -ErrorAction SilentlyContinue
$pwshMajor = if ($pwshInfo -and $pwshInfo.Version) { [int]$pwshInfo.Version.Major } else { 0 }
$diskHealthWarning = @($physDisks | Where-Object { $_.HealthStatus -ne 'Healthy' }).Count -gt 0

if (-not $wingetAvailable) {
    [void]$findings.Add((New-Finding `
        -Id 'PKG-CORE-001' `
        -Severity 'Info' `
        -Category 'OS' `
        -Title 'Windows Package Manager (winget) not available' `
        -Description 'winget is missing or unusable. The suite can still proceed using external vendor installers.' `
        -CurrentValue 'winget command not found' `
        -RecommendedValue 'External installer path available and validated' `
        -Impact 'Store-based remediation is unavailable; use external installer flow.' `
        -Solutions @(
            (New-Solution -Level 'Safe' -Label 'Open PowerShell release page (external installer path)' `
                -Command 'Start-Process "https://aka.ms/powershell-release?tag=stable"' `
                -Rollback 'N/A (manual install path)' `
                -RiskNote 'Uses external vendor installer flow without Store dependency.')
        )))
}

if ($pwshMajor -lt 7) {
    $psCurrent = if ($pwshInfo -and $pwshInfo.Version) { "pwsh $($pwshInfo.Version)" } else { 'pwsh not found' }
    $pwshSolutions = [System.Collections.ArrayList]::new()
    $ensureCoreScript = Join-Path $PSScriptRoot 'ensure-powershell-core.ps1'
    $ensureCoreCmd = ('powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" -InstallIfMissing' -f $ensureCoreScript)
    [void]$pwshSolutions.Add((New-Solution -Level 'Safe' -Label 'Install PowerShell 7 using external installer flow' `
        -Command $ensureCoreCmd `
        -Rollback 'Uninstall PowerShell 7 from Apps and Features if needed' `
        -RiskNote 'Uses external vendor installer path; no Store/AppInstaller dependency.'))
    [void]$pwshSolutions.Add((New-Solution -Level 'Safe' -Label 'Open PowerShell 7 download page' `
        -Command 'Start-Process "https://aka.ms/powershell-release?tag=stable"' `
        -Rollback 'N/A (manual install path)' `
        -RiskNote 'Manual fallback when automated external install is blocked by policy.'))

    [void]$findings.Add((New-Finding `
        -Id 'PKG-CORE-002' `
        -Severity 'Critical' `
        -Category 'OS' `
        -Title 'PowerShell 7 runtime missing for core automation' `
        -Description 'The optimization suite expects PowerShell 7 (pwsh) for core-only tasks and deterministic background workers.' `
        -CurrentValue $psCurrent `
        -RecommendedValue 'pwsh 7.x installed and resolvable' `
        -Impact 'Some always-on tasks and GUI worker orchestration may be degraded or incompatible.' `
        -Solutions @($pwshSolutions.ToArray())))
} else {
    [void]$positives.Add(("PowerShell Core available ({0})" -f $pwshInfo.Version.ToString()))
}

$crystalInstalled = Test-WingetPackageInstalled -PackageId 'CrystalDewWorld.CrystalDiskInfo'
$crystalInstalled = $crystalInstalled -or (Test-Path -LiteralPath 'C:\Program Files\CrystalDiskInfo\DiskInfo64.exe') -or (Test-Path -LiteralPath 'C:\Program Files (x86)\CrystalDiskInfo\DiskInfo32.exe')
if ($diskHealthWarning -and (-not $crystalInstalled)) {
    [void]$findings.Add((New-Finding `
        -Id 'PKG-DIAG-001' `
        -Severity 'Important' `
        -Category 'Disk' `
        -Title 'CrystalDiskInfo not installed for NVMe SMART diagnostics' `
        -Description 'Disk health warning was detected and SMART passthrough may be limited by Intel RST. CrystalDiskInfo is required for a direct diagnostic check.' `
        -CurrentValue 'CrystalDiskInfo not installed' `
        -RecommendedValue 'CrystalDiskInfo installed' `
        -Impact 'NVMe wear/failure trend cannot be validated quickly from GUI-safe tooling.' `
        -Solutions @(
            (New-Solution -Level 'Safe' -Label 'Open CrystalDiskInfo official download page' `
                -Command 'Start-Process "https://crystalmark.info/en/software/crystaldiskinfo/"' `
                -Rollback 'N/A (manual install path)' `
                -RiskNote 'Uses external installer flow independent from Microsoft Store.')
        )
    ))
} elseif ($diskHealthWarning -and $crystalInstalled) {
    [void]$positives.Add('CrystalDiskInfo installed for NVMe diagnostic validation')
}

# SysMain
$sysMain = Get-Service SysMain -EA SilentlyContinue
if ($sysMain -and $sysMain.Status -ne 'Running') {
    [void]$positives.Add('SysMain (Superfetch) disabled')
}

# WSearch
$wSearch = Get-Service WSearch -EA SilentlyContinue
if ($wSearch -and $wSearch.Status -ne 'Running') {
    [void]$positives.Add('Windows Search disabled')
}

# TRIM
$trimRaw = fsutil behavior query DisableDeleteNotify 2>$null
if ($trimRaw -match 'NTFS DisableDeleteNotify\s*=\s*0') {
    [void]$positives.Add('TRIM enabled (NTFS)')
}

# Last Access
$laRaw = fsutil behavior query disablelastaccess 2>$null
if ($laRaw -match '=\s*1') {
    [void]$positives.Add('Last Access Timestamp disabled')
}

# 8.3 names
$dot3Raw = fsutil behavior query disable8dot3 2>$null
if ($dot3Raw -match 'stato.*1|state.*1|disab.*1') {
    [void]$positives.Add('8.3 filename creation disabled')
}

# Prefetcher
$pfReg = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters' -EA SilentlyContinue
if ($pfReg -and $pfReg.EnablePrefetcher -eq 0) {
    [void]$positives.Add('Prefetcher disabled')
}

if ($isHighPerf) {
    [void]$positives.Add('Power plan: High Performance')
}

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#  PHASE 3 - Load KB overrides (future extensibility)
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
if ($KnowledgeBase -and (Test-Path $KnowledgeBase)) {
    Write-Progress2 "Loading knowledge base overrides..."
    try {
        $kb = Get-Content -Raw $KnowledgeBase -EA Stop | ConvertFrom-Json -EA Stop
        # KB structure: { "HardwareRules": [ { "Match": { "CPU": ".*i7-7700HQ.*" }, "ExtraFindings": [...] } ] }
        if ($kb.HardwareRules) {
            foreach ($rule in $kb.HardwareRules) {
                $matched = $true
                foreach ($prop in $rule.Match.PSObject.Properties) {
                    $hwVal = switch ($prop.Name) {
                        'CPU'   { $hardwareProfile.CPU.Model }
                        'Model' { $hardwareProfile.System.Model }
                        'BIOS'  { $hardwareProfile.System.BIOS }
                        default { '' }
                    }
                    if ($hwVal -notmatch $prop.Value) { $matched = $false; break }
                }
                if ($matched -and $rule.ExtraFindings) {
                    foreach ($ef in $rule.ExtraFindings) {
                        $existing = $findings | Where-Object { $_.Id -eq $ef.Id }
                        if (-not $existing) {
                            [void]$findings.Add($ef)
                            Write-Progress2 "KB added finding: $($ef.Id) - $($ef.Title)"
                        }
                    }
                }
            }
        }
    } catch {
        Write-Progress2 "KB load warning: $_"
    }
}

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#  PHASE 4 - Build & Write JSON report
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
Write-Progress2 "Building report..."

# Sort findings: Critical first, then Important, Moderate, Info
$severityOrder = @{ 'Critical' = 0; 'Important' = 1; 'Moderate' = 2; 'Info' = 3 }
$sortedFindings = $findings | Sort-Object { $severityOrder[$_.Severity] }

$report = [ordered]@{
    AuditVersion = '1.0.0'
    Timestamp    = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
    HardwareProfile = $hardwareProfile
    Findings     = @($sortedFindings)
    AlreadyOptimized = @($positives)
    Summary      = [ordered]@{
        TotalFindings    = $findings.Count
        Critical         = @($findings | Where-Object { $_.Severity -eq 'Critical' }).Count
        Important        = @($findings | Where-Object { $_.Severity -eq 'Important' }).Count
        Moderate         = @($findings | Where-Object { $_.Severity -eq 'Moderate' }).Count
        Info             = @($findings | Where-Object { $_.Severity -eq 'Info' }).Count
        AlreadyOptimized = $positives.Count
    }
}

$json = $report | ConvertTo-Json -Depth 10 -Compress:$false
[System.IO.File]::WriteAllText($OutputJson, $json, [System.Text.Encoding]::UTF8)

Write-Progress2 "Report saved to $OutputJson"
Write-Progress2 ("Summary: {0} findings ({1} Critical, {2} Important, {3} Moderate, {4} Info) - {5} items already optimized" -f `
    $report.Summary.TotalFindings, $report.Summary.Critical, $report.Summary.Important, $report.Summary.Moderate, $report.Summary.Info, $report.Summary.AlreadyOptimized)
