<#
.SYNOPSIS
    Audit, auto-check and safe repair for broken WSL configuration on Windows.

.DESCRIPTION
    Deterministic root cause addressed:
      HKCU\...\Lxss\DefaultDistribution points to a distro GUID that is missing
      from HKLM\...\Lxss. WslService enumerates distros from HKLM, so every
      wsl.exe client blocks on IPC and accumulates zombie processes.

    Safe apply sequence (no distro unregister, no hypervisor changes):
      1. Backup HKLM Lxss state
      2. Terminate zombie wsl/wslrelay/vmwp clients
      3. Recover WslService when STOP_PENDING (kill wslservice.exe + sc start)
      4. Mirror HKCU distro metadata into HKLM when absent or incomplete
      5. Set HKLM DefaultDistribution to the HKCU default GUID
      6. Validate wsl -l -v with a bounded timeout

.PARAMETER Apply
    Apply the safe repair sequence after assessment.

.PARAMETER RestoreLatest
    Restore HKLM Lxss state from the latest JSON backup.

.PARAMETER ValidateLaunch
    Optional post-repair probe: wsl -d <default> -- echo WSL_OK (bounded timeout).
    Skipped by default to avoid leaving hung clients during service recovery.

.PARAMETER BackupDirectory
    Directory for rollback JSON backups.

.PARAMETER ZombieThreshold
    Number of wsl.exe processes above which registry-only assessment is used.

.PARAMETER CommandTimeoutSec
    Timeout for bounded wsl.exe probes.
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$RestoreLatest,
    [switch]$ValidateLaunch,
    [string]$BackupDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'logs\diagnostics'),
    [ValidateRange(1, 500)][int]$ZombieThreshold = 5,
    [ValidateRange(3, 120)][int]$CommandTimeoutSec = 12
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$hkcuRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
$hklmRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Lxss'
$distroPropertyNames = @(
    'State', 'DistributionName', 'Version', 'BasePath', 'Flags',
    'DefaultUid', 'PackageFamilyName', 'Flavor', 'OsVersion'
)

function Get-RegistryKeySnapshot {
    param([string]$Path)

    $snapshot = [ordered]@{
        Path       = $Path
        Exists     = Test-Path -LiteralPath $Path
        Properties = [ordered]@{}
    }

    if (-not $snapshot.Exists) {
        return $snapshot
    }

    $item = Get-ItemProperty -LiteralPath $Path -ErrorAction Stop
    foreach ($name in $distroPropertyNames) {
        if ($item.PSObject.Properties.Name -contains $name) {
            $snapshot.Properties[$name] = $item.$name
        }
    }

    if ($Path -ieq $hklmRoot) {
        $rootItem = Get-ItemProperty -LiteralPath $Path -ErrorAction Stop
        if ($rootItem.PSObject.Properties.Name -contains 'DefaultDistribution') {
            $snapshot.Properties['DefaultDistribution'] = [string]$rootItem.DefaultDistribution
        }
    }

    return $snapshot
}

function Get-WslZombieCount {
    return @((Get-Process -Name 'wsl' -ErrorAction SilentlyContinue)).Count
}

function Get-HypervisorLaunchType {
    # Reads the BCD hypervisorlaunchtype for the current boot entry.
    # WSL2 needs the hypervisor launched at boot (Auto). Off => distro VM cannot boot.
    $raw = & cmd /c 'bcdedit /enum {current}' 2>$null
    $line = @($raw | Where-Object { $_ -match '(?i)hypervisorlaunchtype' }) | Select-Object -First 1
    if (-not $line) {
        # Absent line means default/Off on most systems.
        return 'Off'
    }
    if ($line -match '(?i)hypervisorlaunchtype\s+(\w+)') {
        return $Matches[1]
    }
    return 'Unknown'
}

function Set-HypervisorLaunchType {
    param([ValidateSet('Auto', 'Off', 'OptIn', 'OptOut')][string]$Value)

    $out = & cmd /c "bcdedit /set hypervisorlaunchtype $Value" 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw ("bcdedit /set hypervisorlaunchtype $Value failed: {0}" -f $out.Trim())
    }
    return (Get-HypervisorLaunchType)
}

function Get-BootTimeApprox {
    # Instant, WMI-free boot time. Stable within a boot session; changes after reboot.
    # Win32_ComputerSystem CIM can stall on degraded systems, so we avoid it here.
    return (Get-Date).AddMilliseconds(-[Environment]::TickCount64)
}

function Get-RebootMarkerPath {
    return (Join-Path $BackupDirectory 'wsl-hypervisor-reboot-pending.json')
}

function Set-RebootPendingMarker {
    if (-not (Test-Path -LiteralPath $BackupDirectory)) {
        New-Item -Path $BackupDirectory -ItemType Directory -Force | Out-Null
    }
    # Store boot time as Int64 ticks: unambiguous across cultures and immune to
    # ConvertFrom-Json's automatic ISO-date coercion that breaks string round-trips.
    $marker = [ordered]@{
        BootTimeTicks = (Get-BootTimeApprox).Ticks
        BootTime      = (Get-BootTimeApprox).ToString('yyyy-MM-dd HH:mm:ss')
        Reason        = 'hypervisorlaunchtype changed to Auto; reboot required for WSL2 utility VM'
        CreatedAt     = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    $json = $marker | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText((Get-RebootMarkerPath), $json, [System.Text.Encoding]::UTF8)
}

function Clear-RebootPendingMarker {
    $path = Get-RebootMarkerPath
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

function Test-HypervisorRebootPending {
    # Reboot is still pending if the marker exists and we have NOT rebooted since it
    # was written (boot time within ~2 min of the recorded value). After a reboot the
    # boot time advances, so we clear the stale marker and report no pending reboot.
    $path = Get-RebootMarkerPath
    if (-not (Test-Path -LiteralPath $path)) {
        return $false
    }
    try {
        $marker = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json
        if (-not ($marker.PSObject.Properties.Name -contains 'BootTimeTicks')) {
            # Legacy/invalid marker without ticks: treat as still-pending to stay safe.
            return $true
        }
        $markerBoot = [datetime]::new([long]$marker.BootTimeTicks)
        $currentBoot = Get-BootTimeApprox
        if ([math]::Abs(($currentBoot - $markerBoot).TotalSeconds) -le 120) {
            return $true
        }
        Clear-RebootPendingMarker
        return $false
    } catch {
        return $false
    }
}

function Get-WslServiceState {
    $svc = Get-Service -Name 'WslService' -ErrorAction SilentlyContinue
    if ($null -eq $svc) {
        return [ordered]@{
            Exists = $false
            Status = 'Missing'
            StartType = 'Unknown'
        }
    }

    return [ordered]@{
        Exists    = $true
        Status    = $svc.Status.ToString()
        StartType = $svc.StartType.ToString()
    }
}

function Stop-WslClientProcesses {
    param([switch]$IncludeServiceHost)

    $names = @('wsl', 'wslrelay', 'vmwp')
    if ($IncludeServiceHost) {
        $names += 'wslservice'
    }

    foreach ($name in $names) {
        Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object {
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

function Restart-WslServiceSafe {
    $svc = Get-Service -Name 'WslService' -ErrorAction SilentlyContinue
    if ($null -eq $svc) {
        throw 'WslService is not installed on this system.'
    }

    if ($svc.Status.ToString() -eq 'Running') {
        return [ordered]@{
            Action = 'NoOp'
            Status = 'Running'
        }
    }

    if ($svc.Status.ToString() -eq 'StopPending') {
        Stop-WslClientProcesses -IncludeServiceHost
        Start-Sleep -Seconds 2
    }

    $null = & sc.exe start WslService 2>&1
    Start-Sleep -Seconds 3

    $svcAfter = Get-Service -Name 'WslService' -ErrorAction Stop
    return [ordered]@{
        Action = 'Started'
        Status = $svcAfter.Status.ToString()
    }
}

function Copy-DistroRegistryToHklm {
    param(
        [string]$Guid,
        [object]$SourceProperties
    )

    $targetPath = Join-Path $hklmRoot "{$Guid}"
    if (-not (Test-Path -LiteralPath $hklmRoot)) {
        New-Item -Path $hklmRoot -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $targetPath)) {
        New-Item -Path $targetPath -Force | Out-Null
    }

    foreach ($name in $distroPropertyNames) {
        if (-not $SourceProperties.Contains($name)) {
            continue
        }

        $value = $SourceProperties[$name]
        if ($null -eq $value) {
            continue
        }

        if ($value -is [int] -or $value -is [long]) {
            New-ItemProperty -Path $targetPath -Name $name -Value ([int]$value) -PropertyType DWord -Force | Out-Null
        } else {
            New-ItemProperty -Path $targetPath -Name $name -Value ([string]$value) -PropertyType String -Force | Out-Null
        }
    }

    return $targetPath
}

function Invoke-WslProbe {
    param(
        [string[]]$Arguments,
        [int]$TimeoutSec
    )

    $stdoutPath = [System.IO.Path]::Combine($env:TEMP, ("wsl-probe-{0}.out" -f ([guid]::NewGuid().ToString('N'))))
    $stderrPath = [System.IO.Path]::Combine($env:TEMP, ("wsl-probe-{0}.err" -f ([guid]::NewGuid().ToString('N'))))

    try {
        $proc = Start-Process -FilePath 'wsl.exe' -ArgumentList $Arguments -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        $finished = $proc.WaitForExit($TimeoutSec * 1000)
        if (-not $finished) {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            Get-Process -Name 'wsl' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            return [ordered]@{
                TimedOut = $true
                ExitCode = -1
                Output   = ''
                Error    = "Timed out after ${TimeoutSec}s: wsl.exe $($Arguments -join ' ')"
            }
        }

        $stdout = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue } else { '' }
        $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue } else { '' }
        return [ordered]@{
            TimedOut = $false
            ExitCode = $proc.ExitCode
            Output   = [string]$stdout
            Error    = [string]$stderr
        }
    } finally {
        Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Test-HklmDistroMatchesHkcu {
    param(
        [string]$Guid,
        [hashtable]$HkcuProperties
    )

    $hklmPath = Join-Path $hklmRoot "{$Guid}"
    if (-not (Test-Path -LiteralPath $hklmPath)) {
        return $false
    }

    $hklmItem = Get-ItemProperty -LiteralPath $hklmPath -ErrorAction Stop
    foreach ($name in @('DistributionName', 'BasePath', 'Version')) {
        if (-not $HkcuProperties.Contains($name)) {
            continue
        }
        $expected = [string]$HkcuProperties[$name]
        if ($name -eq 'Version') {
            if ([int]$hklmItem.$name -ne [int]$expected) {
                return $false
            }
            continue
        }
        if ([string]$hklmItem.$name -ne $expected) {
            return $false
        }
    }

    return $true
}

function Get-WslConfigAssessment {
    $zombies = Get-WslZombieCount
    $service = Get-WslServiceState
    $issues = [System.Collections.Generic.List[string]]::new()

    $defaultGuid = ''
    $hkcuDefault = Get-ItemProperty -LiteralPath $hkcuRoot -ErrorAction SilentlyContinue
    if ($hkcuDefault -and ($hkcuDefault.PSObject.Properties.Name -contains 'DefaultDistribution')) {
        $defaultGuid = ([string]$hkcuDefault.DefaultDistribution).Trim('{}')
    }

    $hkcuDistro = $null
    $hkcuProperties = [ordered]@{}
    if (-not [string]::IsNullOrWhiteSpace($defaultGuid)) {
        $hkcuDistroPath = Join-Path $hkcuRoot "{$defaultGuid}"
        if (Test-Path -LiteralPath $hkcuDistroPath) {
            $hkcuDistro = Get-RegistryKeySnapshot -Path $hkcuDistroPath
            foreach ($entry in $hkcuDistro.Properties.GetEnumerator()) {
                $hkcuProperties[$entry.Key] = $entry.Value
            }
        } else {
            [void]$issues.Add('HKCU default distro key missing')
        }
    } else {
        [void]$issues.Add('HKCU DefaultDistribution not configured')
    }

    $hklmDistroExists = $false
    $hklmMatches = $false
    if (-not [string]::IsNullOrWhiteSpace($defaultGuid)) {
        $hklmDistroExists = Test-Path -LiteralPath (Join-Path $hklmRoot "{$defaultGuid}")
        if (-not $hklmDistroExists) {
            [void]$issues.Add('HKLM distro registration missing for default GUID')
        } elseif ($hkcuProperties.Count -gt 0) {
            $hklmMatches = Test-HklmDistroMatchesHkcu -Guid $defaultGuid -HkcuProperties $hkcuProperties
            if (-not $hklmMatches) {
                [void]$issues.Add('HKLM distro metadata does not match HKCU')
            }
        }
    }

    $hklmDefault = ''
    if (Test-Path -LiteralPath $hklmRoot) {
        $hklmRootItem = Get-ItemProperty -LiteralPath $hklmRoot -ErrorAction SilentlyContinue
        if ($hklmRootItem -and ($hklmRootItem.PSObject.Properties.Name -contains 'DefaultDistribution')) {
            $hklmDefault = ([string]$hklmRootItem.DefaultDistribution).Trim('{}')
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($defaultGuid) -and $hklmDefault -ne $defaultGuid) {
        [void]$issues.Add('HKLM DefaultDistribution does not match HKCU')
    }

    if ($zombies -gt $ZombieThreshold) {
        [void]$issues.Add("Zombie wsl.exe processes above threshold ($zombies > $ZombieThreshold)")
    }

    if ($service.Exists -and $service.Status -ne 'Running') {
        [void]$issues.Add("WslService status is $($service.Status)")
    }

    $hypervisorLaunchType = Get-HypervisorLaunchType
    $hypervisorConfiguredOk = $hypervisorLaunchType -in @('Auto', 'On')
    $rebootPendingForHypervisor = $false
    if (-not $hypervisorConfiguredOk) {
        [void]$issues.Add("Hyper-V hypervisor not auto-launched (hypervisorlaunchtype=$hypervisorLaunchType): WSL2 utility VM cannot boot, so distro launch hangs even when listing works")
    } elseif (Test-HypervisorRebootPending) {
        $rebootPendingForHypervisor = $true
        [void]$issues.Add("hypervisorlaunchtype=$hypervisorLaunchType is configured but the system has not rebooted yet: reboot required before WSL2 distro launch will work")
    }

    $basePath = [string]$hkcuProperties['BasePath']
    $vhdxPath = ''
    $basePathExists = $false
    $vhdxExists = $false
    if (-not [string]::IsNullOrWhiteSpace($basePath)) {
        $basePathExists = Test-Path -LiteralPath $basePath
        $vhdxPath = Join-Path $basePath 'ext4.vhdx'
        $vhdxExists = Test-Path -LiteralPath $vhdxPath
        if (-not $basePathExists) {
            [void]$issues.Add('Distro BasePath directory missing')
        } elseif (-not $vhdxExists) {
            [void]$issues.Add('Distro ext4.vhdx missing')
        }
    }

    $listProbe = $null
    $launchProbe = $null
    $canProbe = $service.Exists -and $service.Status -eq 'Running' -and $zombies -le $ZombieThreshold -and $issues.Count -eq 0
    if ($canProbe) {
        $listProbe = Invoke-WslProbe -Arguments @('-l', '-v') -TimeoutSec $CommandTimeoutSec
        if ($listProbe.TimedOut -or $listProbe.ExitCode -ne 0) {
            [void]$issues.Add('wsl -l -v probe failed or timed out')
        }
    } elseif ($issues.Count -eq 0) {
        [void]$issues.Add('Skipped live wsl probe because service/zombie preconditions were not met')
    }

    if ($ValidateLaunch -and $canProbe -and $null -ne $listProbe -and -not $listProbe.TimedOut -and $listProbe.ExitCode -eq 0) {
        $distroName = [string]$hkcuProperties['DistributionName']
        if (-not [string]::IsNullOrWhiteSpace($distroName)) {
            $launchProbe = Invoke-WslProbe -Arguments @('-d', $distroName, '--', 'echo', 'WSL_OK') -TimeoutSec ([Math]::Max($CommandTimeoutSec, 30))
            if ($launchProbe.TimedOut -or $launchProbe.ExitCode -ne 0 -or ($launchProbe.Output -notmatch 'WSL_OK')) {
                [void]$issues.Add('Default distro launch probe failed; reboot once after repair if listing works')
            }
        }
    }

    $status = if ($issues.Count -eq 0) {
        'Ready'
    } elseif ($rebootPendingForHypervisor -and @($issues | Where-Object { $_ -notmatch 'reboot required' }).Count -eq 0) {
        'PendingReboot'
    } elseif ($issues -match 'HKLM distro registration missing|HKLM DefaultDistribution|HKLM distro metadata|Zombie wsl|WslService status|probe failed|hypervisor not auto-launched') {
        'Broken'
    } else {
        'Warning'
    }

    return [ordered]@{
        Timestamp           = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
        Status              = $status
        DefaultGuid         = $defaultGuid
        DistributionName    = [string]$hkcuProperties['DistributionName']
        BasePath            = $basePath
        VhdxPath            = $vhdxPath
        BasePathExists      = $basePathExists
        VhdxExists          = $vhdxExists
        HklmDistroExists    = $hklmDistroExists
        HklmDistroMatches   = $hklmMatches
        HklmDefaultGuid     = $hklmDefault
        ZombieWslCount      = $zombies
        WslService          = $service
        HypervisorLaunchType = $hypervisorLaunchType
        HypervisorRebootPending = $rebootPendingForHypervisor
        Issues              = @($issues)
        ListProbe           = $listProbe
        LaunchProbe         = $launchProbe
        HkcuDistro          = $hkcuDistro
        RecommendedAction   = if ($status -eq 'Ready') {
            'No action required.'
        } else {
            "pwsh -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Apply"
        }
        RebootRecommended   = [bool]($rebootPendingForHypervisor -or ($launchProbe -and ($launchProbe.TimedOut -or $launchProbe.ExitCode -ne 0)))
    }
}

function Save-Backup {
    param([hashtable]$Assessment)

    if (-not (Test-Path -LiteralPath $BackupDirectory)) {
        New-Item -Path $BackupDirectory -ItemType Directory -Force | Out-Null
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $timestampedPath = Join-Path $BackupDirectory ("wsl-config-backup-{0}.json" -f $stamp)
    $latestPath = Join-Path $BackupDirectory 'wsl-config-backup-latest.json'

    $backup = [ordered]@{
        Timestamp            = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
        HklmRoot             = Get-RegistryKeySnapshot -Path $hklmRoot
        HypervisorLaunchType = Get-HypervisorLaunchType
        Distros              = @()
    }

    if (Test-Path -LiteralPath $hklmRoot) {
        Get-ChildItem -LiteralPath $hklmRoot -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' } |
            ForEach-Object {
                $backup.Distros += Get-RegistryKeySnapshot -Path $_.PSPath
            }
    }

    $json = ($backup | ConvertTo-Json -Depth 8 -Compress:$false)
    [System.IO.File]::WriteAllText($timestampedPath, $json, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText($latestPath, $json, [System.Text.Encoding]::UTF8)

    return [ordered]@{
        Timestamped = $timestampedPath
        Latest      = $latestPath
    }
}

function Restore-FromLatestBackup {
    $latestPath = Join-Path $BackupDirectory 'wsl-config-backup-latest.json'
    if (-not (Test-Path -LiteralPath $latestPath)) {
        throw "Backup file not found: $latestPath"
    }

    $backup = Get-Content -LiteralPath $latestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop

    Get-ChildItem -LiteralPath $hklmRoot -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' } |
        ForEach-Object {
            Remove-Item -LiteralPath $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
        }

    foreach ($distro in @($backup.Distros)) {
        $guid = ([string]$distro.Path).Split('\')[-1].Trim('{}')
        $props = [ordered]@{}
        foreach ($prop in $distro.Properties.PSObject.Properties) {
            $props[$prop.Name] = $prop.Value
        }
        Copy-DistroRegistryToHklm -Guid $guid -SourceProperties $props
    }

    if ($null -ne $backup.HklmRoot.Properties -and $backup.HklmRoot.Properties.PSObject.Properties.Name -contains 'DefaultDistribution') {
        if (-not (Test-Path -LiteralPath $hklmRoot)) {
            New-Item -Path $hklmRoot -Force | Out-Null
        }
        Set-ItemProperty -LiteralPath $hklmRoot -Name 'DefaultDistribution' -Value ([string]$backup.HklmRoot.Properties.DefaultDistribution) -Type String -Force
    }

    $restoredHypervisor = $null
    if ($backup.PSObject.Properties.Name -contains 'HypervisorLaunchType' -and -not [string]::IsNullOrWhiteSpace([string]$backup.HypervisorLaunchType)) {
        $prior = [string]$backup.HypervisorLaunchType
        if ($prior -in @('Auto', 'Off', 'OptIn', 'OptOut')) {
            $restoredHypervisor = Set-HypervisorLaunchType -Value $prior
        }
    }

    return [ordered]@{
        Action               = 'RestoreLatest'
        BackupPath           = $latestPath
        Status               = 'Restored'
        RestoredHypervisor   = $restoredHypervisor
        RebootRecommended    = [bool]$restoredHypervisor
        Assessment           = Get-WslConfigAssessment
    }
}

function Invoke-ApplyRepair {
    param([hashtable]$PreAssessment)

    $actions = [System.Collections.Generic.List[string]]::new()
    $guid = [string]$PreAssessment.DefaultGuid
    if ([string]::IsNullOrWhiteSpace($guid)) {
        throw 'Cannot apply repair without HKCU DefaultDistribution.'
    }

    $hkcuDistroPath = Join-Path $hkcuRoot "{$guid}"
    if (-not (Test-Path -LiteralPath $hkcuDistroPath)) {
        throw "HKCU distro key not found: $hkcuDistroPath"
    }

    $hkcuSnapshot = Get-RegistryKeySnapshot -Path $hkcuDistroPath
    $hkcuProperties = [ordered]@{}
    foreach ($entry in $hkcuSnapshot.Properties.GetEnumerator()) {
        $hkcuProperties[$entry.Key] = $entry.Value
    }

    if ((Get-WslZombieCount) -gt 0) {
        Stop-WslClientProcesses
        Start-Sleep -Seconds 2
        [void]$actions.Add('Terminated zombie wsl/wslrelay/vmwp client processes.')
    }

    $serviceState = Get-WslServiceState
    if ($serviceState.Exists -and $serviceState.Status -ne 'Running') {
        $restart = Restart-WslServiceSafe
        [void]$actions.Add(("Recovered WslService: {0} -> {1}" -f $restart.Action, $restart.Status))
    }

    if (-not (Test-HklmDistroMatchesHkcu -Guid $guid -HkcuProperties $hkcuProperties) -or -not (Test-Path -LiteralPath (Join-Path $hklmRoot "{$guid}"))) {
        $target = Copy-DistroRegistryToHklm -Guid $guid -SourceProperties $hkcuProperties
        [void]$actions.Add("Mirrored HKCU distro metadata to HKLM: $target")
    }

    if (-not (Test-Path -LiteralPath $hklmRoot)) {
        New-Item -Path $hklmRoot -Force | Out-Null
    }
    Set-ItemProperty -LiteralPath $hklmRoot -Name 'DefaultDistribution' -Value "{$guid}" -Type String -Force
    [void]$actions.Add("Set HKLM DefaultDistribution to {$guid}")

    $currentHypervisor = Get-HypervisorLaunchType
    if ($currentHypervisor -notin @('Auto', 'On')) {
        $newHypervisor = Set-HypervisorLaunchType -Value 'Auto'
        Set-RebootPendingMarker
        [void]$actions.Add("Set bcdedit hypervisorlaunchtype $currentHypervisor -> $newHypervisor (WSL2 utility VM boot enablement; reboot required)")
    }

    $post = Get-WslConfigAssessment
    if ($post.Status -ne 'Ready' -and (Get-WslServiceState).Status -ne 'Running') {
        $restart = Restart-WslServiceSafe
        [void]$actions.Add(("Post-repair WslService recovery: {0} -> {1}" -f $restart.Action, $restart.Status))
        $post = Get-WslConfigAssessment
    }

    return [ordered]@{
        Actions        = @($actions)
        PostAssessment = $post
    }
}

function Assert-Administrator {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Administrator rights are required for -Apply and -RestoreLatest.'
    }
}

if ($Apply -and $RestoreLatest) {
    throw 'Use either -Apply or -RestoreLatest, not both.'
}

if ($RestoreLatest) {
    Assert-Administrator
    $restoreResult = Restore-FromLatestBackup
    $restoreResult | ConvertTo-Json -Depth 10 -Compress:$false
    return
}

$preAssessment = Get-WslConfigAssessment

if (-not $Apply) {
    $preAssessment | ConvertTo-Json -Depth 10 -Compress:$false
    return
}

Assert-Administrator
$backupInfo = Save-Backup -Assessment $preAssessment
$applyResult = Invoke-ApplyRepair -PreAssessment $preAssessment
$postAssessment = [hashtable]$applyResult.PostAssessment

if ($ValidateLaunch -and $postAssessment.Status -eq 'Ready') {
    $postAssessment = Get-WslConfigAssessment
}

[ordered]@{
    Action           = 'Apply'
    BackupPaths      = $backupInfo
    PreAssessment    = $preAssessment
    ApplyActions     = $applyResult.Actions
    PostAssessment   = $postAssessment
    Status           = [string]$postAssessment.Status
    RebootRecommended = [bool]$postAssessment.RebootRecommended
    Message          = if ($postAssessment.Status -eq 'Ready') {
        'WSL registry and service state repaired. Listing probe succeeded.'
    } elseif ($postAssessment.Status -eq 'PendingReboot') {
        'Deterministic fix applied: hypervisorlaunchtype set to Auto. REBOOT NOW to launch the Hyper-V hypervisor; WSL2 distro boot will work after reboot. Re-run this script with -ValidateLaunch after rebooting to confirm.'
    } elseif ($postAssessment.Issues -contains 'Default distro launch probe failed; reboot once after repair if listing works') {
        'Registry/service repair applied. Reboot once, then rerun with -ValidateLaunch if distro start is still slow.'
    } else {
        'Repair applied, but one or more checks are still failing. Review PostAssessment.Issues.'
    }
} | ConvertTo-Json -Depth 12 -Compress:$false
