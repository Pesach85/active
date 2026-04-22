<#
.SYNOPSIS
    NVMe risk advisor with read-only transition plan.

.DESCRIPTION
    Produces a JSON advisory report with:
      - Best next decision
      - Technical rationale
      - Immediate operational steps
      - Anti-regression checks
      - Write-offload plan to preserve a worn NVMe

    The script is observation-first and applies no system changes.

.PARAMETER OutputJson
    Destination path for the advisory JSON.

.PARAMETER TargetDriveLetter
    Drive letter to protect (default: C).

.PARAMETER CriticalWarning
    Optional manual override from CrystalDiskInfo (decimal or hex string like 0x04).

.PARAMETER PercentageUsed
    Optional manual override from CrystalDiskInfo (% used).

.PARAMETER CompositeTemperatureC
    Optional manual override from CrystalDiskInfo (Celsius).
#>
param(
    [Parameter(Mandatory)][string]$OutputJson,
    [ValidatePattern('^[A-Za-z]$')][string]$TargetDriveLetter = 'C',
    [string]$CriticalWarning,
    [int]$PercentageUsed = -1,
    [int]$CompositeTemperatureC = -1
)

$ErrorActionPreference = 'Continue'

function Write-Progress2 {
    param([string]$Message)
    Write-Host "[NVME-ADVISOR] $Message"
}

function Convert-ToNullableInt {
    param([object]$Value)

    if ($null -eq $Value) { return $null }
    $txt = [string]$Value
    if ([string]::IsNullOrWhiteSpace($txt)) { return $null }

    $trimmed = $txt.Trim()
    if ($trimmed -match '^0x[0-9A-Fa-f]+$') {
        try { return [Convert]::ToInt32($trimmed, 16) } catch { return $null }
    }

    $num = 0
    if ([int]::TryParse($trimmed, [ref]$num)) {
        return $num
    }

    return $null
}

function Get-PropertyInt {
    param(
        [object]$Object,
        [string[]]$CandidateNames
    )

    if ($null -eq $Object) { return $null }

    foreach ($name in $CandidateNames) {
        if ($Object.PSObject.Properties.Name -contains $name) {
            $val = Convert-ToNullableInt -Value $Object.$name
            if ($null -ne $val) {
                return $val
            }
        }
    }

    return $null
}

function Get-TargetDiskNumbers {
    param([char]$DriveLetter)

    $numbers = [System.Collections.Generic.List[int]]::new()

    try {
        $parts = @(Get-Partition -DriveLetter $DriveLetter -ErrorAction Stop)
        foreach ($p in $parts) {
            if ($null -ne $p.DiskNumber -and -not $numbers.Contains([int]$p.DiskNumber)) {
                [void]$numbers.Add([int]$p.DiskNumber)
            }
        }
    } catch {
        # Keep empty and let caller fallback.
    }

    return $numbers.ToArray()
}

function Get-AlternativeWriteVolume {
    param([string]$ProtectedDrive)

    $candidates = @(Get-Volume -ErrorAction SilentlyContinue |
        Where-Object {
            $_.DriveLetter -and
            ("$($_.DriveLetter):" -ne $ProtectedDrive) -and
            $_.FileSystemType -and
            $_.SizeRemaining -gt 40GB
        } |
        Sort-Object SizeRemaining -Descending)

    if ($candidates.Count -gt 0) {
        return ("{0}:" -f $candidates[0].DriveLetter)
    }

    return 'D:'
}

function Get-RiskLevel {
    param(
        [string]$HealthStatus,
        [object]$CriticalWarningValue,
        [object]$PctUsed,
        [object]$TempC,
        [object]$AvailableSparePct
    )

    $cw = Convert-ToNullableInt -Value $CriticalWarningValue
    $pu = Convert-ToNullableInt -Value $PctUsed
    $tc = Convert-ToNullableInt -Value $TempC
    $as = Convert-ToNullableInt -Value $AvailableSparePct

    if ($HealthStatus -and $HealthStatus -ne 'Healthy') { return 'Critical' }
    if ($null -ne $cw -and $cw -ge 1) { return 'Critical' }
    if ($null -ne $pu -and $pu -ge 100) { return 'Critical' }

    if ($null -ne $pu -and $pu -ge 90) { return 'Important' }
    if ($null -ne $as -and $as -le 10) { return 'Important' }
    if ($null -ne $tc -and $tc -ge 70) { return 'Important' }

    if ($null -ne $pu -and $pu -ge 75) { return 'Moderate' }
    if ($null -ne $tc -and $tc -ge 60) { return 'Moderate' }

    return 'Info'
}

function Build-WriteOffloadPlan {
    param(
        [string]$ProtectedDrive,
        [string]$WriteDrive
    )

    return @(
        [ordered]@{
            Step = 1
            Title = 'Observe current write hotspots (24h)'
            Actions = @(
                'Collect baseline: free space, SMART/reliability counters, and top writers by process.',
                "Track high-churn folders under $ProtectedDrive\Users, $ProtectedDrive\Windows\Temp, and package caches."
            )
            Rollback = 'Observation only. No rollback needed.'
        },
        [ordered]@{
            Step = 2
            Title = 'Move volatile temp and caches'
            Actions = @(
                "Create $WriteDrive\WriteCache\Temp and redirect user TEMP/TMP via user environment variables.",
                "Move browser caches and app caches to $WriteDrive where app settings support it.",
                "Move package caches (npm, pip, NuGet, Maven, Docker) to $WriteDrive using tool-native config."
            )
            Rollback = 'Restore previous environment variables/config values; restart user session.'
        },
        [ordered]@{
            Step = 3
            Title = 'Reduce system write amplification'
            Actions = @(
                "Move pagefile primary allocation to $WriteDrive and keep minimal fallback on $ProtectedDrive (for crash dumps).",
                'Keep hibernation disabled if not required.',
                'Reduce diagnostic log verbosity and enforce log retention.'
            )
            Rollback = 'Re-enable original pagefile and hibernation settings if stability drops.'
        },
        [ordered]@{
            Step = 4
            Title = 'Protect the worn NVMe as mostly-read'
            Actions = @(
                "Keep only OS boot and read-mostly binaries on $ProtectedDrive.",
                "Route downloads, working folders, VMs, scratch data, and exports to $WriteDrive.",
                'Stop heavy write jobs on the worn drive (benchmarks, torrents, transcodes, large patch staging).'
            )
            Rollback = 'Per-workload rollback: restore original data paths if performance regressions are unacceptable.'
        }
    )
}

Write-Progress2 'Collecting storage profile...'

$targetDrive = ("{0}:" -f $TargetDriveLetter.ToUpperInvariant())
$targetDiskNumbers = Get-TargetDiskNumbers -DriveLetter $TargetDriveLetter
$physicalDisks = @(Get-PhysicalDisk -ErrorAction SilentlyContinue)
$candidateDisks = [System.Collections.Generic.List[object]]::new()

foreach ($pd in $physicalDisks) {
    $pdNumber = Convert-ToNullableInt -Value $pd.DeviceId
    if (($targetDiskNumbers.Count -eq 0) -or ($null -eq $pdNumber) -or ($targetDiskNumbers -contains $pdNumber)) {
        [void]$candidateDisks.Add($pd)
    }
}

if ($candidateDisks.Count -eq 0 -and $physicalDisks.Count -gt 0) {
    [void]$candidateDisks.Add($physicalDisks[0])
}

$diskAssessments = [System.Collections.ArrayList]::new()
$overallRisk = 'Info'
$riskRank = @{ 'Info' = 0; 'Moderate' = 1; 'Important' = 2; 'Critical' = 3 }

$manualCriticalWarning = Convert-ToNullableInt -Value $CriticalWarning
$manualPctUsed = if ($PercentageUsed -ge 0) { $PercentageUsed } else { $null }
$manualTempC = if ($CompositeTemperatureC -ge 0) { $CompositeTemperatureC } else { $null }

foreach ($disk in $candidateDisks) {
    $reliability = $null
    try {
        $reliability = Get-StorageReliabilityCounter -PhysicalDisk $disk -ErrorAction Stop
    } catch {
        $reliability = $null
    }

    $criticalWarningValue = if ($null -ne $manualCriticalWarning) {
        $manualCriticalWarning
    } else {
        Get-PropertyInt -Object $reliability -CandidateNames @('CriticalWarning')
    }

    $pctUsed = if ($null -ne $manualPctUsed) {
        $manualPctUsed
    } else {
        Get-PropertyInt -Object $reliability -CandidateNames @('PercentageUsed', 'Wear')
    }

    $tempC = if ($null -ne $manualTempC) {
        $manualTempC
    } else {
        Get-PropertyInt -Object $reliability -CandidateNames @('Temperature', 'TemperatureCelsius')
    }

    $availableSpare = Get-PropertyInt -Object $reliability -CandidateNames @('AvailableSpare', 'Spare')
    $healthStatus = [string]$disk.HealthStatus

    $riskLevel = Get-RiskLevel -HealthStatus $healthStatus -CriticalWarningValue $criticalWarningValue -PctUsed $pctUsed -TempC $tempC -AvailableSparePct $availableSpare
    if ($riskRank[$riskLevel] -gt $riskRank[$overallRisk]) {
        $overallRisk = $riskLevel
    }

    [void]$diskAssessments.Add([ordered]@{
        Model = [string]$disk.FriendlyName
        DeviceId = [string]$disk.DeviceId
        MediaType = [string]$disk.MediaType
        BusType = [string]$disk.BusType
        SizeGB = [math]::Round(($disk.Size / 1GB), 1)
        HealthStatus = $healthStatus
        OperationalStatus = [string]$disk.OperationalStatus
        Metrics = [ordered]@{
            CriticalWarning = $criticalWarningValue
            PercentageUsed = $pctUsed
            CompositeTemperatureC = $tempC
            AvailableSparePct = $availableSpare
        }
        RiskLevel = $riskLevel
    })
}

$writeDrive = Get-AlternativeWriteVolume -ProtectedDrive $targetDrive

$bestNextDecision = switch ($overallRisk) {
    'Critical' {
        "Freeze write-heavy workloads on $targetDrive immediately, complete a verified backup, and move volatile writes to $writeDrive before replacement."
    }
    'Important' {
        "Start write-offload from $targetDrive to $writeDrive today and monitor wear/temperature daily while planning replacement window."
    }
    'Moderate' {
        "Prepare staged write-offload from $targetDrive to $writeDrive and tighten monitoring cadence to avoid accelerated wear."
    }
    default {
        "Maintain observation mode on $targetDrive with weekly SMART checks and keep a ready write-offload plan to $writeDrive."
    }
}

$technicalRationale = @(
    "Risk level is $overallRisk based on health state plus reliability metrics (CriticalWarning, PercentageUsed/Wear, temperature, spare).",
    'A worn NVMe can degrade abruptly; reducing write amplification lowers near-term failure probability.',
    'Observation-first approach avoids destabilizing changes and preserves rollback options.'
)

$immediateSteps = @(
    'Run and verify backup readability before any migration action.',
    "Set default write destinations to $writeDrive (Downloads, temp work folders, package caches).",
    'Avoid benchmark, torrent, and transcode workloads on the worn drive.',
    'Re-check NVMe metrics after 24h and 7 days to confirm reduced write pressure.'
)

$antiRegressionChecks = @(
    'After each relocation, validate application startup and save/open flows.',
    'Keep rollback mapping of every moved path (old -> new) before applying the next step.',
    'Keep a minimal pagefile on system drive if crash dump capability is required.',
    'If performance or stability drops, roll back only the last relocation block.'
)

$report = [ordered]@{
    AuditVersion = '1.0.0'
    Timestamp = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
    TargetDrive = $targetDrive
    RecommendedWriteDrive = $writeDrive
    Assessment = [ordered]@{
        RiskLevel = $overallRisk
        CandidateDisks = @($diskAssessments)
    }
    BestNextDecision = $bestNextDecision
    TechnicalRationale = @($technicalRationale)
    ImmediateOperationalSteps = @($immediateSteps)
    AntiRegressionChecks = @($antiRegressionChecks)
    WriteOffloadPlan = [ordered]@{
        Objective = "Keep $targetDrive mostly read-oriented and move volatile writes to $writeDrive."
        Steps = @(Build-WriteOffloadPlan -ProtectedDrive $targetDrive -WriteDrive $writeDrive)
    }
}

Write-Progress2 "Risk level: $overallRisk"
Write-Progress2 "Writing report to $OutputJson"

$json = $report | ConvertTo-Json -Depth 12 -Compress:$false
[System.IO.File]::WriteAllText($OutputJson, $json, [System.Text.Encoding]::UTF8)

Write-Progress2 'Done.'
