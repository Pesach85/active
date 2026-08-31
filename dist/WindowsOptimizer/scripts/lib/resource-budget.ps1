# Host resource tier + optimization profile resolver (ultra-light).
# Dot-source from build-optimization-context.ps1, hub-orchestrator, llm-advise (future).

function Get-HostResourceSnapshot {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $totalMb = 16384.0
    $freeMb = 4096.0
    if ($os) {
        $totalMb = [math]::Round($os.TotalVisibleMemorySize / 1024.0, 0)
        $freeMb = [math]::Round($os.FreePhysicalMemory / 1024.0, 0)
    }
    $totalGb = [math]::Round($totalMb / 1024.0, 2)
    $threads = [Environment]::ProcessorCount
    if ($cs -and $cs.NumberOfLogicalProcessors) {
        $threads = [int]$cs.NumberOfLogicalProcessors
    }

    $cFreePct = 100.0
    try {
        $c = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
        if ($c.Size -gt 0) {
            $cFreePct = [math]::Round(($c.FreeSpace / [double]$c.Size) * 100.0, 1)
        }
    } catch {}

    return [ordered]@{
        TotalRamMb = [int]$totalMb
        FreeRamMb = [int]$freeMb
        TotalRamGb = $totalGb
        LogicalProcessors = $threads
        DriveCFreePercent = $cFreePct
    }
}

function Get-HostResourceTier {
    param($Snapshot)

    $s = if ($Snapshot) { $Snapshot } else { Get-HostResourceSnapshot }
    $totalGb = [double]$s.TotalRamGb
    $freeMb = [int]$s.FreeRamMb
    $cFree = [double]$s.DriveCFreePercent

    if ($totalGb -le 16.5 -or $freeMb -lt 4096 -or $cFree -lt 10.0) {
        return 'C'
    }
    if ($totalGb -le 24.5 -or $freeMb -lt 6144) {
        return 'B'
    }
    return 'A'
}

function Get-OptimizationProfileDefaults {
    param([ValidateSet('feather', 'light', 'standard')][string]$Name)

    switch ($Name) {
        'light' {
            return @{
                Name = 'light'
                MonitorLoopIntervalSec = 45
                OrchestratorIntervalSec = 300
                PpiEveryOrchestratorCycles = 6
                PpiDurationSec = 4
                PpiTop = 6
                RunFsIntegrityEveryNCycles = 4
                RunWheaEveryNCycles = 1
                AutoApplySafeThrottle = $false
                LlmAllowed = $true
                LlmModel = 'qwen2.5:0.5b-instruct'
            }
        }
        'standard' {
            return @{
                Name = 'standard'
                MonitorLoopIntervalSec = 30
                OrchestratorIntervalSec = 300
                PpiEveryOrchestratorCycles = 3
                PpiDurationSec = 6
                PpiTop = 8
                RunFsIntegrityEveryNCycles = 2
                RunWheaEveryNCycles = 1
                AutoApplySafeThrottle = $false
                LlmAllowed = $true
                LlmModel = 'qwen2.5:1.5b-instruct'
            }
        }
        default {
            return @{
                Name = 'feather'
                MonitorLoopIntervalSec = 60
                OrchestratorIntervalSec = 600
                PpiEveryOrchestratorCycles = 12
                PpiDurationSec = 3
                PpiTop = 5
                RunFsIntegrityEveryNCycles = 6
                RunWheaEveryNCycles = 2
                AutoApplySafeThrottle = $false
                LlmAllowed = $false
                LlmModel = ''
            }
        }
    }
}

function Resolve-OptimizationProfile {
    param(
        $Config,
        $Snapshot
    )

    $snap = if ($Snapshot) { $Snapshot } else { Get-HostResourceSnapshot }
    $tier = Get-HostResourceTier -Snapshot $snap

    $co = $null
    if ($Config -is [hashtable]) { $co = $Config['ContinuousOptimization'] }
    elseif ($Config.ContinuousOptimization) { $co = $Config.ContinuousOptimization }

    $requested = 'auto'
    if ($co) {
        $requested = if ($co -is [hashtable]) { [string]$co['Profile'] } else { [string]$co.Profile }
        if (-not $requested) { $requested = 'auto' }
    }

    $profileName = switch ($requested.ToLowerInvariant()) {
        'feather' { 'feather' }
        'light' { 'light' }
        'standard' { 'standard' }
        default {
            switch ($tier) {
                'A' { 'standard' }
                'B' { 'light' }
                default { 'feather' }
            }
        }
    }

    if ($tier -eq 'C' -and $profileName -eq 'standard') { $profileName = 'feather' }

    $defaults = Get-OptimizationProfileDefaults -Name $profileName
    $defaults['Tier'] = $tier
    $defaults['Snapshot'] = $snap
    return $defaults
}

function Test-LlmAdvisoryAllowed {
    param(
        $Config,
        $Snapshot,
        $Profile
    )

    $snap = if ($Snapshot) { $Snapshot } else { Get-HostResourceSnapshot }
    $prof = if ($Profile) { $Profile } else { Resolve-OptimizationProfile -Config $Config -Snapshot $snap }

    if (-not $prof.LlmAllowed) { return @{ Allowed = $false; Reason = 'Profile disables LLM (feather/Tier C)' } }

    $llm = $null
    if ($Config -is [hashtable]) { $llm = $Config['LlmAdvisory'] }
    elseif ($Config.LlmAdvisory) { $llm = $Config.LlmAdvisory }

    $enabled = $false
    $minFree = 6144
    if ($llm) {
        $enabled = if ($llm -is [hashtable]) { [bool]$llm['Enabled'] } else { [bool]$llm.Enabled }
        $mf = if ($llm -is [hashtable]) { $llm['MinFreeRamMbForLlm'] } else { $llm.MinFreeRamMbForLlm }
        if ($null -ne $mf) { $minFree = [int]$mf }
    }
    if (-not $enabled) { return @{ Allowed = $false; Reason = 'LlmAdvisory.Enabled=false' } }
    if ([int]$snap.FreeRamMb -lt $minFree) {
        return @{ Allowed = $false; Reason = "Free RAM $($snap.FreeRamMb)MB < $minFree MB" }
    }
    return @{ Allowed = $true; Reason = 'OK'; Model = [string]$prof.LlmModel }
}
