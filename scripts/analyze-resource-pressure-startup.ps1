[CmdletBinding()]
param(
    [int]$DurationSec = 12,
    [int]$Top = 15,
    [int]$StartupLookbackDays = 14,
    [string]$OutputJson = "",
    [string[]]$ExcludedProcesses = @("Idle", "System Idle Process", "Registry", "Memory Compression")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($DurationSec -lt 4) { $DurationSec = 4 }
if ($DurationSec -gt 45) { $DurationSec = 45 }
if ($Top -lt 5) { $Top = 5 }
if ($Top -gt 40) { $Top = 40 }
if ($StartupLookbackDays -lt 1) { $StartupLookbackDays = 1 }
if ($StartupLookbackDays -gt 30) { $StartupLookbackDays = 30 }

function Get-ProcessSnapshot {
    param([string[]]$Excluded)

    $rows = @{}
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
        try {
            if ($Excluded -contains $p.ProcessName) { continue }

            $startTicks = 0L
            try { $startTicks = $p.StartTime.Ticks } catch { $startTicks = 0L }

            $key = "{0}:{1}" -f $p.Id, $startTicks
            $cpu = 0.0
            if ($null -ne $p.CPU) {
                $cpu = [double]$p.CPU
            }

            $ioRead = 0L
            $ioWrite = 0L
            try {
                $ioRead = [int64]$p.IOReadBytes
                $ioWrite = [int64]$p.IOWriteBytes
            } catch {
                $ioRead = 0L
                $ioWrite = 0L
            }

            $rows[$key] = [PSCustomObject]@{
                Key = $key
                ProcessName = [string]$p.ProcessName
                PID = [int]$p.Id
                CpuTime = $cpu
                WorkingSet64 = [int64]$p.WorkingSet64
                PrivateMemorySize64 = [int64]$p.PrivateMemorySize64
                IoReadBytes = $ioRead
                IoWriteBytes = $ioWrite
                IoBytes = $ioRead + $ioWrite
            }
        } catch {
            # Skip process that cannot be read safely.
        }
    }

    return $rows
}

function Get-DominantPressure {
    param(
        [double]$CpuPercent,
        [double]$WorkingSetMb,
        [double]$IoMbPerSec
    )

    $cpuN = [math]::Min(100.0, [math]::Max(0.0, $CpuPercent)) / 100.0
    $memN = [math]::Min(8192.0, [math]::Max(0.0, $WorkingSetMb)) / 8192.0
    $ioN = [math]::Min(400.0, [math]::Max(0.0, $IoMbPerSec)) / 400.0

    if (($cpuN -ge $memN) -and ($cpuN -ge $ioN)) { return "CPUBound" }
    if (($memN -ge $cpuN) -and ($memN -ge $ioN)) { return "MemoryHeavy" }
    if (($ioN -ge $cpuN) -and ($ioN -ge $memN)) { return "IOHeavy" }
    return "Mixed"
}

function Resolve-Necessity {
    param([string]$Name)

    $n = $Name.ToLowerInvariant()

    if ($n -match '^(system|smss|csrss|wininit|services|lsass|svchost|winlogon|dwm)$') {
        return @{ Level = "CriticalSystem"; Priority = "Keep"; Notes = "Windows core process; do not throttle/disable." }
    }

    if ($n -match '^(msmpeng|nissrv|sense|securityhealthservice)$') {
        return @{ Level = "Security"; Priority = "Keep"; Notes = "Security process; tune schedule/scope only." }
    }

    if ($n -match '^(searchindexer|wsearch)$') {
        return @{ Level = "PlatformService"; Priority = "Tune"; Notes = "Indexing can be scoped safely; avoid disabling blindly." }
    }

    if ($n -match '^(code|code - insiders|msedge|chrome|opera|firefox|jwlibrary|teams|discord|onedrive)$') {
        return @{ Level = "UserApp"; Priority = "Tune"; Notes = "User-space app; safe to reduce startup/background behavior." }
    }

    if ($n -match '^(anydesk|teamviewer|zoom|adobearmservice|edgeupdate|googleupdate)$') {
        return @{ Level = "OptionalBackground"; Priority = "Review"; Notes = "Background updater/remote tool; evaluate real need at startup." }
    }

    return @{ Level = "Unknown"; Priority = "Review"; Notes = "Classify by owner and business criticality before action." }
}

function Resolve-SafeAction {
    param(
        [string]$Priority,
        [string]$DominantPressure,
        [double]$Score
    )

    if ($Priority -eq "Keep") {
        return "ObserveOnly"
    }

    if ($Priority -eq "Tune") {
        if ($DominantPressure -eq "IOHeavy") { return "StartupAndCacheTuning" }
        if ($DominantPressure -eq "MemoryHeavy") { return "ReduceBackgroundTabsOrInstances" }
        if ($DominantPressure -eq "CPUBound") { return "LowerProcessPriorityIfPersistent" }
        return "ObserveAndTune"
    }

    if ($Priority -eq "Review") {
        if ($Score -ge 60.0) { return "CandidateStartupDisable" }
        return "ReviewNeedThenObserve"
    }

    return "ObserveOnly"
}

function Get-StartupInventory {
    $entries = New-Object System.Collections.Generic.List[object]

    try {
        foreach ($row in (Get-CimInstance Win32_StartupCommand -ErrorAction Stop)) {
            $entries.Add([PSCustomObject]@{
                Source = "StartupCommand"
                Name = [string]$row.Name
                Command = [string]$row.Command
                Location = [string]$row.Location
                User = [string]$row.User
            })
        }
    } catch {
        $entries.Add([PSCustomObject]@{
            Source = "StartupCommand"
            Name = "<AccessError>"
            Command = $_.Exception.Message
            Location = ""
            User = ""
        })
    }

    try {
        $tasks = New-Object System.Collections.Generic.List[object]
        foreach ($task in (Get-ScheduledTask -ErrorAction Stop)) {
            $isStartupTask = $false
            foreach ($trigger in @($task.Triggers)) {
                if ($null -eq $trigger) { continue }
                if ($trigger.CimClass.CimClassName -in @("MSFT_TaskBootTrigger", "MSFT_TaskLogonTrigger")) {
                    $isStartupTask = $true
                    break
                }
            }

            if ($isStartupTask) {
                [void]$tasks.Add($task)
            }
        }

        foreach ($task in $tasks) {
            $entries.Add([PSCustomObject]@{
                Source = "ScheduledTask"
                Name = [string]$task.TaskName
                Command = "TaskPath=" + [string]$task.TaskPath
                Location = [string]$task.State
                User = [string]$task.Principal.UserId
            })
        }
    } catch {
        $entries.Add([PSCustomObject]@{
            Source = "ScheduledTask"
            Name = "<AccessError>"
            Command = $_.Exception.Message
            Location = ""
            User = ""
        })
    }

    return $entries.ToArray()
}

function Get-BootDiagnostics {
    param([int]$LookbackDays)

    $logName = "Microsoft-Windows-Diagnostics-Performance/Operational"
    $cutoff = (Get-Date).AddDays(-$LookbackDays)

    $payload = [ordered]@{
        LogName = $logName
        Access = "Unavailable"
        Note = ""
        TopOffenders = @()
    }

    try {
        $events = Get-WinEvent -FilterHashtable @{
            LogName = $logName
            StartTime = $cutoff
            Id = 101, 102, 103, 110
        } -ErrorAction Stop

        $rows = New-Object System.Collections.Generic.List[object]

        foreach ($event in $events) {
            try {
                $xml = [xml]$event.ToXml()
                $eventData = @{}
                foreach ($node in $xml.Event.EventData.Data) {
                    $eventData[[string]$node.Name] = [string]$node.'#text'
                }

                $friendly = ""
                if ($eventData.ContainsKey("FriendlyName")) { $friendly = [string]$eventData["FriendlyName"] }
                $fileName = ""
                if ($eventData.ContainsKey("FileName")) { $fileName = [string]$eventData["FileName"] }

                $duration = 0
                if ($eventData.ContainsKey("DegradationTime")) {
                    [int]::TryParse([string]$eventData["DegradationTime"], [ref]$duration) | Out-Null
                }
                if (($duration -le 0) -and $eventData.ContainsKey("TotalTime")) {
                    [int]::TryParse([string]$eventData["TotalTime"], [ref]$duration) | Out-Null
                }

                $rows.Add([PSCustomObject]@{
                    TimeCreated = $event.TimeCreated.ToString("yyyy-MM-dd HH:mm:ss")
                    EventId = [int]$event.Id
                    FriendlyName = $friendly
                    FileName = $fileName
                    DurationMs = [int]$duration
                })
            } catch {
                # Skip malformed event payloads.
            }
        }

        $top = $rows | Sort-Object DurationMs -Descending | Select-Object -First 20
        $payload.Access = "Available"
        $payload.Note = "Diagnostics-Performance events collected successfully."
        $payload.TopOffenders = @($top)
    } catch {
        $payload.Access = "DeniedOrMissing"
        $payload.Note = $_.Exception.Message
        $payload.TopOffenders = @()
    }

    return [PSCustomObject]$payload
}

$logicalProcessors = [Environment]::ProcessorCount
$first = Get-ProcessSnapshot -Excluded $ExcludedProcesses
Start-Sleep -Seconds $DurationSec
$second = Get-ProcessSnapshot -Excluded $ExcludedProcesses

$rows = New-Object System.Collections.Generic.List[object]
foreach ($key in $second.Keys) {
    if (-not $first.ContainsKey($key)) {
        continue
    }

    $a = $first[$key]
    $b = $second[$key]

    $cpuDelta = [math]::Max(0.0, ([double]$b.CpuTime - [double]$a.CpuTime))
    $cpuPercent = ($cpuDelta / ($DurationSec * $logicalProcessors)) * 100.0

    $ioDelta = [math]::Max(0L, ([int64]$b.IoBytes - [int64]$a.IoBytes))
    $ioMbPerSec = ($ioDelta / 1MB) / $DurationSec

    $workingSetMb = [math]::Round([double]$b.WorkingSet64 / 1MB, 2)
    $privateMb = [math]::Round([double]$b.PrivateMemorySize64 / 1MB, 2)

    $score = [math]::Min(100.0,
        ([math]::Min(100.0, $cpuPercent) * 0.50) +
        (([math]::Min(8192.0, $workingSetMb) / 8192.0) * 100.0 * 0.30) +
        (([math]::Min(400.0, $ioMbPerSec) / 400.0) * 100.0 * 0.20)
    )

    $dominant = Get-DominantPressure -CpuPercent $cpuPercent -WorkingSetMb $workingSetMb -IoMbPerSec $ioMbPerSec
    $need = Resolve-Necessity -Name ([string]$b.ProcessName)
    $safeAction = Resolve-SafeAction -Priority ([string]$need.Priority) -DominantPressure $dominant -Score $score

    $rows.Add([PSCustomObject]@{
        Score = [math]::Round($score, 2)
        ProcessName = [string]$b.ProcessName
        PID = [int]$b.PID
        CpuPercent = [math]::Round($cpuPercent, 2)
        WorkingSetMB = $workingSetMb
        PrivateMB = $privateMb
        IoMBps = [math]::Round($ioMbPerSec, 3)
        DominantPressure = $dominant
        Necessity = [string]$need.Level
        Priority = [string]$need.Priority
        SafeAction = $safeAction
        Notes = [string]$need.Notes
    })
}

$topRows = @($rows | Sort-Object Score -Descending | Select-Object -First $Top)

$startup = Get-StartupInventory
$bootDiagnostics = Get-BootDiagnostics -LookbackDays $StartupLookbackDays

$disks = @()
try {
    $physical = @(Get-PhysicalDisk -ErrorAction Stop)
    foreach ($disk in $physical) {
        $disks += [PSCustomObject]@{
            Model = [string]$disk.FriendlyName
            MediaType = [string]$disk.MediaType
            BusType = [string]$disk.BusType
            SizeGB = [math]::Round([double]$disk.Size / 1GB, 1)
            Health = [string]$disk.HealthStatus
            OperationalStatus = [string]$disk.OperationalStatus
        }
    }
} catch {
    $disks = @([PSCustomObject]@{
        Model = "<AccessError>"
        MediaType = "Unknown"
        BusType = "Unknown"
        SizeGB = 0
        Health = "Unknown"
        OperationalStatus = $_.Exception.Message
    })
}

$hasHdd = $false
foreach ($disk in $disks) {
    if ([string]$disk.MediaType -match 'HDD|Unspecified') {
        $hasHdd = $true
    }
}

$startupNames = @($startup | ForEach-Object { ([string]$_.Name).ToLowerInvariant() })
$browserAutostart = @($startupNames | Where-Object { $_ -match 'edge|chrome|opera|firefox' }).Count
$remoteAutostart = @($startupNames | Where-Object { $_ -match 'anydesk|teamviewer' }).Count
$updateAutostart = @($startupNames | Where-Object { $_ -match 'update|updater' }).Count

$safeActions = New-Object System.Collections.Generic.List[object]
$safeActions.Add([PSCustomObject]@{
    Action = "BaselineOnlyNoAggressiveKill"
    Why = "Avoid regressions; keep AutoTerminate disabled during observation."
    Fallback = "No changes applied; rerun after 24h sample."
})

if ($browserAutostart -gt 0) {
    $safeActions.Add([PSCustomObject]@{
        Action = "DisableBrowserAutoStart"
        Why = "Reduces startup disk chatter and memory spikes on mixed SSD+HDD systems."
        Fallback = "Re-enable single startup item from Task Manager Startup tab."
    })
}

if ($remoteAutostart -gt 0) {
    $safeActions.Add([PSCustomObject]@{
        Action = "SetRemoteToolManualStart"
        Why = "Keeps remote software available on demand while reducing idle boot overhead."
        Fallback = "Set service/app back to Automatic startup."
    })
}

if ($hasHdd) {
    $safeActions.Add([PSCustomObject]@{
        Action = "MoveHighIOWorkloadsToSSD"
        Why = "Mechanical disks amplify seek latency during startup/background scans."
        Fallback = "Keep data on HDD but apply schedule windows for scan/indexing."
    })

    $safeActions.Add([PSCustomObject]@{
        Action = "ScopeSearchIndexing"
        Why = "Limiting indexed folders decreases random HDD reads after logon."
        Fallback = "Restore previous indexing scope from Indexing Options."
    })
}

if (@($topRows | Where-Object { $_.ProcessName -eq "MsMpEng" }).Count -gt 0) {
    $safeActions.Add([PSCustomObject]@{
        Action = "DefenderScheduleAndExclusionsReview"
        Why = "Keep security intact while reducing duplicate scans on trusted build folders."
        Fallback = "Remove exclusions if risk posture changes."
    })
}

$result = [PSCustomObject]@{
    GeneratedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    SampleDurationSec = $DurationSec
    LogicalProcessors = $logicalProcessors
    TotalProcessesObserved = [int]$rows.Count
    TopProcesses = @($topRows)
    StartupEntries = @($startup | Select-Object -First 60)
    DiskInventory = @($disks)
    BootDiagnostics = $bootDiagnostics
    StartupSignals = [PSCustomObject]@{
        BrowserAutoStartCount = $browserAutostart
        RemoteToolAutoStartCount = $remoteAutostart
        UpdaterAutoStartCount = $updateAutostart
        MixedStorageWithHdd = $hasHdd
    }
    SafeActions = $safeActions.ToArray()
}

if ($OutputJson) {
    $outDir = Split-Path -Parent $OutputJson
    if ($outDir -and (-not (Test-Path -LiteralPath $outDir))) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }
    $result | ConvertTo-Json -Depth 8 | Out-File -LiteralPath $OutputJson -Encoding utf8 -Force
}

$result