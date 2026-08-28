# Shared deterministic process pressure scoring and classification (Windows).
# Dot-source from analyze-process-pressure.ps1 and apply-process-pressure-safe.ps1

function Get-ProcessPressureDefaults {
    return @{
        ExcludedProcesses = @('Idle', 'System Idle Process', 'Registry', 'Memory Compression')
        CpuWeight         = 0.50
        MemoryWeight      = 0.30
        IoWeight          = 0.20
        MemoryCapMb       = 8192.0
        IoCapMbPerSec     = 400.0
    }
}

function Get-ProcessIntelligenceCatalog {
    param([string]$CatalogPath)

    if (-not (Test-Path -LiteralPath $CatalogPath)) {
        return @{
            SchemaVersion = 'ProcessIntelligence.v1'
            vitalExact = @('System', 'csrss', 'wininit', 'services', 'lsass', 'svchost', 'winlogon', 'dwm')
            vitalPatterns = @()
            securityExact = @('MsMpEng', 'NisSrv', 'Sense')
            platformServicePatterns = @('SearchIndexer', 'WSearch')
            knownApplications = @{}
            optionalBackgroundPatterns = @()
            safeActionDefinitions = @{}
        }
    }

    $raw = Get-Content -LiteralPath $CatalogPath -Raw -ErrorAction Stop | ConvertFrom-Json
    return $raw
}

function Test-ProcessNameMatch {
    param([string]$ProcessName, [string[]]$Exact, [string[]]$Patterns)

    if ($Exact -contains $ProcessName) { return $true }
    foreach ($p in $Patterns) {
        if ($ProcessName -match $p) { return $true }
    }
    return $false
}

function Resolve-ProcessNecessity {
    param(
        [string]$ProcessName,
        $Catalog
    )

    $name = [string]$ProcessName
    $lower = $name.ToLowerInvariant()

    if (Test-ProcessNameMatch -ProcessName $name -Exact @($Catalog.vitalExact) -Patterns @($Catalog.vitalPatterns)) {
        return @{
            Level = 'CriticalSystem'; Priority = 'Keep'; Category = 'OSCore'
            Notes = 'Windows core / session process — never terminate or throttle aggressively.'
        }
    }

    if (Test-ProcessNameMatch -ProcessName $name -Exact @($Catalog.securityExact) -Patterns @()) {
        return @{
            Level = 'Security'; Priority = 'Keep'; Category = 'Security'
            Notes = 'Security component — tune schedule/scope only; never disable without HITL security review.'
        }
    }

    foreach ($pat in @($Catalog.platformServicePatterns)) {
        if ($name -match $pat) {
            return @{
                Level = 'PlatformService'; Priority = 'Tune'; Category = 'Platform'
                Notes = 'Platform service — scope or schedule tuning preferred over kill.'
            }
        }
    }

    $known = $null
    if ($Catalog.knownApplications) {
        $props = $Catalog.knownApplications.PSObject.Properties
        foreach ($prop in $props) {
            if ($lower -eq $prop.Name.ToLowerInvariant() -or $lower -like ($prop.Name.ToLowerInvariant() + '*')) {
                $known = $prop.Value
                break
            }
        }
    }

    if ($known) {
        return @{
            Level = 'KnownApplication'; Priority = [string]$known.priority; Category = [string]$known.category
            Notes = "Catalog match — review mitigations for dominant pressure."
        }
    }

    foreach ($pat in @($Catalog.optionalBackgroundPatterns)) {
        if ($name -like "*$pat*") {
            return @{
                Level = 'OptionalBackground'; Priority = 'Review'; Category = 'Background'
                Notes = 'Optional background/updater/remote — candidate for manual-start after review.'
            }
        }
    }

    return @{
        Level = 'Unknown'; Priority = 'Review'; Category = 'Unknown'
        Notes = 'Not in catalog — classify owner and business need before any action.'
    }
}

function Get-DominantPressure {
    param(
        [double]$CpuPercent,
        [double]$WorkingSetMb,
        [double]$IoMbPerSec,
        [double]$MemoryCapMb = 8192.0,
        [double]$IoCapMbPerSec = 400.0
    )

    $cpuN = [math]::Min(100.0, [math]::Max(0.0, $CpuPercent)) / 100.0
    $memN = [math]::Min($MemoryCapMb, [math]::Max(0.0, $WorkingSetMb)) / $MemoryCapMb
    $ioN = [math]::Min($IoCapMbPerSec, [math]::Max(0.0, $IoMbPerSec)) / $IoCapMbPerSec

    if (($cpuN -ge $memN) -and ($cpuN -ge $ioN)) { return 'CPUBound' }
    if (($memN -ge $cpuN) -and ($memN -ge $ioN)) { return 'MemoryHeavy' }
    if (($ioN -ge $cpuN) -and ($ioN -ge $memN)) { return 'IOHeavy' }
    return 'Mixed'
}

function Get-PressureScore {
    param(
        [double]$CpuPercent,
        [double]$WorkingSetMb,
        [double]$IoMbPerSec,
        [hashtable]$Weights
    )

    $w = if ($Weights) { $Weights } else { @{ Cpu = 0.50; Memory = 0.30; Io = 0.20; MemoryCapMb = 8192.0; IoCapMbPerSec = 400.0 } }
    $memCap = [double]$w.MemoryCapMb
    $ioCap = [double]$w.IoCapMbPerSec

    return [math]::Min(100.0,
        ([math]::Min(100.0, $CpuPercent) * [double]$w.Cpu) +
        (([math]::Min($memCap, $WorkingSetMb) / $memCap) * 100.0 * [double]$w.Memory) +
        (([math]::Min($ioCap, $IoMbPerSec) / $ioCap) * 100.0 * [double]$w.Io))
}

function Resolve-PressureActions {
    param(
        [string]$Priority,
        [string]$DominantPressure,
        [double]$Score,
        [string]$ProcessName,
        $Catalog
    )

    $actions = New-Object System.Collections.Generic.List[object]

    if ($Priority -eq 'Keep') {
        [void]$actions.Add([ordered]@{
            Action = 'ObserveOnly'; Level = 'Safe'; RequiresHitl = $false
            Rationale = 'Vital/security process preserved.'
        })
        $known = $null
        if ($Catalog.knownApplications) {
            $lower = $ProcessName.ToLowerInvariant()
            foreach ($prop in $Catalog.knownApplications.PSObject.Properties) {
                if ($lower -eq $prop.Name.ToLowerInvariant() -or $lower -like ($prop.Name.ToLowerInvariant() + '*')) {
                    $known = $prop.Value; break
                }
            }
        }
        if ($known -and $known.pressureMitigations) {
            $mitProp = $known.pressureMitigations.PSObject.Properties[$DominantPressure]
            if ($null -ne $mitProp) {
                foreach ($tip in @($mitProp.Value)) {
                    [void]$actions.Add([ordered]@{
                        Action = 'GuidanceOnly'; Level = 'Safe'; RequiresHitl = $true
                        Rationale = [string]$tip
                    })
                }
            }
        }
        if ($known -and $known.references) {
            [void]$actions.Add([ordered]@{
                Action = 'ReferenceLinks'; Level = 'Safe'; RequiresHitl = $false
                Rationale = (@($known.references) -join '; ')
            })
        }
        if ($ProcessName -eq 'MsMpEng' -and $Score -ge 55) {
            [void]$actions.Add([ordered]@{
                Action = 'DefenderExtremeNecessityReview'; Level = 'Aggressive'; RequiresHitl = $true
                Rationale = 'Run evaluate-defender-extreme-necessity.ps1 — escalation ladder before any disable.'
            })
        }
        return $actions.ToArray()
    }

    if ($Priority -eq 'Tune') {
        if ($DominantPressure -eq 'CPUBound' -and $Score -ge 40) {
            [void]$actions.Add([ordered]@{
                Action = 'LowerProcessPriority'; Level = 'Safe'; RequiresHitl = $false
                Rationale = 'Reversible priority throttle (BelowNormal).'
            })
        }
        if ($DominantPressure -eq 'IOHeavy') {
            [void]$actions.Add([ordered]@{
                Action = 'StartupAndCacheTuning'; Level = 'Moderate'; RequiresHitl = $true
                Rationale = 'Reduce autostart / cache / sync scope.'
            })
        }
        if ($DominantPressure -eq 'MemoryHeavy') {
            [void]$actions.Add([ordered]@{
                Action = 'ReduceInstancesOrTabs'; Level = 'Moderate'; RequiresHitl = $true
                Rationale = 'Close redundant instances or background tabs.'
            })
        }
        [void]$actions.Add([ordered]@{
            Action = 'ObserveOnly'; Level = 'Safe'; RequiresHitl = $false
            Rationale = 'Monitor after optional tune.'
        })
        return $actions.ToArray()
    }

    if ($Score -ge 55) {
        [void]$actions.Add([ordered]@{
            Action = 'DisableStartupEntry'; Level = 'Moderate'; RequiresHitl = $true
            Rationale = 'High score optional background — review then disable autostart.'
        })
    }
    if ($Score -ge 75 -and $Priority -eq 'Review') {
        [void]$actions.Add([ordered]@{
            Action = 'LowerProcessPriority'; Level = 'Safe'; RequiresHitl = $false
            Rationale = 'Temporary throttle while investigating.'
        })
    }
    [void]$actions.Add([ordered]@{
        Action = 'ObserveOnly'; Level = 'Safe'; RequiresHitl = $false
        Rationale = 'Default safe path when classification uncertain.'
    })
    return $actions.ToArray()
}

function Get-WindowsProcessSnapshot {
    param([string[]]$Excluded)

    $rows = @{}
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
        try {
            if ($Excluded -contains $p.ProcessName) { continue }
            $startTicks = 0L
            try { $startTicks = $p.StartTime.Ticks } catch {}
            $key = '{0}:{1}' -f $p.Id, $startTicks
            $cpu = 0.0
            if ($null -ne $p.CPU) { $cpu = [double]$p.CPU }
            $ioRead = 0L; $ioWrite = 0L
            try {
                $ioRead = [int64]$p.IOReadBytes
                $ioWrite = [int64]$p.IOWriteBytes
            } catch {}
            $path = ''
            try { $path = [string]$p.Path } catch {}
            $rows[$key] = [PSCustomObject]@{
                Key = $key
                ProcessName = [string]$p.ProcessName
                PID = [int]$p.Id
                CpuTime = $cpu
                WorkingSet64 = [int64]$p.WorkingSet64
                PrivateMemorySize64 = [int64]$p.PrivateMemorySize64
                IoBytes = $ioRead + $ioWrite
                ImagePath = $path
                Responding = try { [bool]$p.Responding } catch { $true }
            }
        } catch {}
    }
    return $rows
}

function Measure-ProcessPressureRows {
    param(
        [hashtable]$First,
        [hashtable]$Second,
        [int]$DurationSec,
        [int]$LogicalProcessors,
        $Catalog,
        [hashtable]$Weights
    )

    $list = New-Object System.Collections.Generic.List[object]
    foreach ($key in $Second.Keys) {
        if (-not $First.ContainsKey($key)) { continue }
        $a = $First[$key]
        $b = $Second[$key]

        $cpuDelta = [math]::Max(0.0, ([double]$b.CpuTime - [double]$a.CpuTime))
        $cpuPercent = ($cpuDelta / ($DurationSec * [math]::Max(1, $LogicalProcessors))) * 100.0
        $ioDelta = [math]::Max(0L, ([int64]$b.IoBytes - [int64]$a.IoBytes))
        $ioMbPerSec = ($ioDelta / 1MB) / $DurationSec
        $workingSetMb = [math]::Round([double]$b.WorkingSet64 / 1MB, 2)
        $privateMb = [math]::Round([double]$b.PrivateMemorySize64 / 1MB, 2)

        $score = Get-PressureScore -CpuPercent $cpuPercent -WorkingSetMb $workingSetMb -IoMbPerSec $ioMbPerSec -Weights $Weights
        $dominant = Get-DominantPressure -CpuPercent $cpuPercent -WorkingSetMb $workingSetMb -IoMbPerSec $ioMbPerSec
        $need = Resolve-ProcessNecessity -ProcessName ([string]$b.ProcessName) -Catalog $Catalog
        $actions = Resolve-PressureActions -Priority ([string]$need.Priority) -DominantPressure $dominant -Score $score -ProcessName ([string]$b.ProcessName) -Catalog $Catalog

        $autoEligible = @($actions | Where-Object { -not $_.RequiresHitl -and $_.Action -in @('LowerProcessPriority', 'ObserveOnly') })
        $hitlRequired = @($actions | Where-Object { $_.RequiresHitl })

        $list.Add([ordered]@{
            Score = [math]::Round($score, 2)
            ProcessName = [string]$b.ProcessName
            PID = [int]$b.PID
            ImagePath = [string]$b.ImagePath
            CpuPercent = [math]::Round($cpuPercent, 2)
            WorkingSetMB = $workingSetMb
            PrivateMB = $privateMb
            IoMBps = [math]::Round($ioMbPerSec, 3)
            DominantPressure = $dominant
            Necessity = [string]$need.Level
            Priority = [string]$need.Priority
            Category = [string]$need.Category
            Notes = [string]$need.Notes
            Responding = [bool]$b.Responding
            RecommendedActions = @($actions)
            AutoEligibleActions = @($autoEligible)
            HitlRequiredActions = @($hitlRequired)
        })
    }
    return $list
}

function Get-DefenderProcessRowFromReport {
    param($Report)
    if (-not $Report -or -not $Report.TopProcesses) { return $null }
    foreach ($row in @($Report.TopProcesses)) {
        if ([string]$row.ProcessName -eq 'MsMpEng') { return $row }
    }
    return $null
}

function Get-DefenderPlatformStatus {
    $status = [ordered]@{
        ModuleAvailable = $false
        RealTimeProtectionEnabled = $null
        TamperProtectionEnabled = $null
        AMServiceEnabled = $null
        AntivirusEnabled = $null
        QuickScanAgeHours = $null
        FullScanAgeHours = $null
    }
    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        $status.ModuleAvailable = $true
        $status.RealTimeProtectionEnabled = [bool]$mp.RealTimeProtectionEnabled
        $status.TamperProtectionEnabled = [bool]$mp.IsTamperProtected
        $status.AMServiceEnabled = [bool]$mp.AMServiceEnabled
        $status.AntivirusEnabled = [bool]$mp.AntivirusEnabled
        if ($mp.QuickScanStartTime) {
            $status.QuickScanAgeHours = [math]::Round(((Get-Date) - $mp.QuickScanStartTime).TotalHours, 1)
        }
        if ($mp.FullScanStartTime) {
            $status.FullScanAgeHours = [math]::Round(((Get-Date) - $mp.FullScanStartTime).TotalHours, 1)
        }
    } catch {}
    return [pscustomobject]$status
}

function Get-DefenderExtremeNecessityEvaluation {
    param(
        $MsMpEngRow,
        $Catalog,
        [switch]$IsAdmin
    )

    $cfg = $null
    if ($Catalog -and $Catalog.extremeNecessityDefender) {
        $cfg = $Catalog.extremeNecessityDefender
    }

    $defStatus = Get-DefenderPlatformStatus
    $pressureScore = if ($MsMpEngRow) { [double]$MsMpEngRow.Score } else { 0.0 }
    $cpu = if ($MsMpEngRow) { [double]$MsMpEngRow.CpuPercent } else { 0.0 }
    $io = if ($MsMpEngRow) { [double]$MsMpEngRow.IoMBps } else { 0.0 }
    $mem = if ($MsMpEngRow) { [double]$MsMpEngRow.WorkingSetMB } else { 0.0 }
    $dominant = if ($MsMpEngRow) { [string]$MsMpEngRow.DominantPressure } else { 'Mixed' }

    $w = @{ pressureScore = 0.35; cpuPercent = 0.25; ioMbPerSec = 0.20; workingSetMb = 0.10; dominantPressureMatch = 0.10 }
    if ($cfg -and $cfg.weights) {
        foreach ($p in $cfg.weights.PSObject.Properties) { $w[$p.Name] = [double]$p.Value }
    }

    $cpuNorm = [math]::Min(100.0, [math]::Max(0.0, $cpu))
    $ioNorm = [math]::Min(100.0, ($io / 400.0) * 100.0)
    $memNorm = [math]::Min(100.0, ($mem / 8192.0) * 100.0)
    $domBonus = if ($dominant -in @('CPUBound', 'IOHeavy')) { 100.0 } else { 40.0 }

    $composite = [math]::Round(
        ($pressureScore * $w['pressureScore']) +
        ($cpuNorm * $w['cpuPercent']) +
        ($ioNorm * $w['ioMbPerSec']) +
        ($memNorm * $w['workingSetMb']) +
        ($domBonus * $w['dominantPressureMatch']),
        2
    )

    $tier = 'Observe'
    if ($cfg -and $cfg.tiers) {
        if ($composite -ge [double]$cfg.tiers.ExtremeServiceDisable.minCompositeScore) {
            $tier = 'ExtremeServiceDisable'
        } elseif ($composite -ge [double]$cfg.tiers.TemporaryRealtimeOff.minCompositeScore) {
            $tier = 'TemporaryRealtimeOff'
        } elseif ($composite -ge [double]$cfg.tiers.TuneExclusions.minCompositeScore) {
            $tier = 'TuneExclusions'
        }
    } else {
        if ($composite -ge 85) { $tier = 'ExtremeServiceDisable' }
        elseif ($composite -ge 70) { $tier = 'TemporaryRealtimeOff' }
        elseif ($composite -ge 55) { $tier = 'TuneExclusions' }
    }

    $blockers = New-Object System.Collections.Generic.List[string]
    $prereqs = New-Object System.Collections.Generic.List[string]

    if (-not $IsAdmin) {
        [void]$blockers.Add('Administrator elevation required for any Defender mutation.')
    }
    if (-not $defStatus.ModuleAvailable) {
        [void]$blockers.Add('Defender PowerShell module unavailable — cannot verify or change state safely.')
    }
    if ($tier -in @('TemporaryRealtimeOff', 'ExtremeServiceDisable')) {
        if ($defStatus.TamperProtectionEnabled -eq $true) {
            [void]$blockers.Add('Tamper Protection is ON — disable manually in Windows Security > Virus & threat protection > Manage settings before Tier 2+.')
        }
        [void]$prereqs.Add('Document reason code and planned re-enable window.')
        [void]$prereqs.Add('Ensure secondary offline AV or isolated network if disabling real-time protection.')
    }
    if ($tier -eq 'ExtremeServiceDisable') {
        [void]$prereqs.Add('Double human confirmation required (ExtremeServiceDisable).')
        [void]$prereqs.Add('Register rollback JSON and scheduled re-enable before apply.')
    }
    if (-not $MsMpEngRow) {
        [void]$blockers.Add('MsMpEng not in current pressure top — run process-pressure analyze first.')
        $tier = 'Observe'
    }

    $allowed = ($tier -ne 'Observe') -and ($blockers.Count -eq 0)
    $neverAuto = $true
    if ($cfg -and $null -ne $cfg.neverAutoApply) { $neverAuto = [bool]$cfg.neverAutoApply }

    $rationale = switch ($tier) {
        'Observe' { 'Defender pressure does not justify disable path — continue monitoring or tune other workloads.' }
        'TuneExclusions' { 'Deterministic gate: composite >= 55 — prefer exclusions and scan schedule (keeps AV active).' }
        'TemporaryRealtimeOff' { 'Deterministic gate: composite >= 70 — time-boxed real-time off allowed ONLY with HITL + Tamper Protection off.' }
        'ExtremeServiceDisable' { 'Deterministic gate: composite >= 85 — last-resort service stop; maximum risk, mandatory rollback timer.' }
        default { 'Unknown tier.' }
    }

    return [ordered]@{
        SchemaVersion = 'DefenderExtremeNecessityEvaluation.v1'
        GeneratedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        CompositeScore = $composite
        RecommendedTier = $tier
        AllowedToProceed = [bool]$allowed
        NeverAutoApply = [bool]$neverAuto
        Rationale = $rationale
        MsMpEngMetrics = if ($MsMpEngRow) {
            [ordered]@{
                Score = $pressureScore; CpuPercent = $cpu; IoMBps = $io
                WorkingSetMB = $mem; DominantPressure = $dominant; PID = [int]$MsMpEngRow.PID
            }
        } else { $null }
        DefenderStatus = $defStatus
        Blockers = @($blockers)
        Prerequisites = @($prereqs)
        EscalationLadder = @(
            '1. Observe and confirm sustained pressure (not a one-shot spike)',
            '2. TuneExclusions: Add-Defender exclusions for trusted build paths + off-hours scan',
            '3. TemporaryRealtimeOff: Set-MpPreference -DisableRealtimeMonitoring (time-boxed)',
            '4. ExtremeServiceDisable: Stop-Service WinDefend (last resort, rollback mandatory)'
        )
        ReasonCodes = if ($cfg -and $cfg.reasonCodes) { $cfg.reasonCodes } else { @{} }
    }
}
