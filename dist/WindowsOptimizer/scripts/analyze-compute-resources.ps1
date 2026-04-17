[CmdletBinding()]
param(
    [int]$DurationSec = 6,
    [int]$Top = 8,
    [string]$OutputJson = "",
    [string[]]$ExcludedProcesses = @("Idle", "System", "Registry", "Memory Compression")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($DurationSec -lt 2) { $DurationSec = 2 }
if ($DurationSec -gt 30) { $DurationSec = 30 }
if ($Top -lt 3) { $Top = 3 }
if ($Top -gt 30) { $Top = 30 }

function Get-ProcessSnapshot {
    $rows = @{}
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
        if ($ExcludedProcesses -contains $p.ProcessName) {
            continue
        }

        try {
            $startTicks = 0L
            try { $startTicks = $p.StartTime.Ticks } catch { $startTicks = 0L }

            $key = "{0}:{1}" -f $p.Id, $startTicks
            $cpu = 0.0
            if ($null -ne $p.CPU) {
                $cpu = [double]$p.CPU
            }

            $ioBytes = 0L
            try {
                $ioBytes = [int64]$p.IOReadBytes + [int64]$p.IOWriteBytes
            } catch {
                $ioBytes = 0L
            }

            $rows[$key] = [PSCustomObject]@{
                Key = $key
                ProcessName = [string]$p.ProcessName
                Id = [int]$p.Id
                CPU = $cpu
                WorkingSet64 = [int64]$p.WorkingSet64
                PrivateMemorySize64 = [int64]$p.PrivateMemorySize64
                IoBytes = $ioBytes
            }
        } catch {
            # Skip processes that cannot be read safely.
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

function Get-Recommendation {
    param(
        [double]$Score,
        [string]$DominantPressure
    )

    if ($Score -ge 75) {
        switch ($DominantPressure) {
            "CPUBound" { return "ThrottlePriority" }
            "MemoryHeavy" { return "InvestigateMemory" }
            "IOHeavy" { return "CheckDiskContention" }
            default { return "InvestigateImmediately" }
        }
    }

    if ($Score -ge 45) {
        return "Observe"
    }

    return "Normal"
}

$logicalProcessors = [Environment]::ProcessorCount
$start = Get-Date
$first = Get-ProcessSnapshot
Start-Sleep -Seconds $DurationSec
$second = Get-ProcessSnapshot

$rows = New-Object System.Collections.Generic.List[object]
foreach ($key in $second.Keys) {
    if (-not $first.ContainsKey($key)) {
        continue
    }

    $a = $first[$key]
    $b = $second[$key]

    $cpuDelta = [math]::Max(0.0, ([double]$b.CPU - [double]$a.CPU))
    $cpuPercent = ($cpuDelta / ($DurationSec * $logicalProcessors)) * 100.0

    $ioDelta = [math]::Max(0L, ([int64]$b.IoBytes - [int64]$a.IoBytes))
    $ioMbPerSec = ($ioDelta / 1MB) / $DurationSec

    $workingSetMb = [math]::Round([double]$b.WorkingSet64 / 1MB, 2)
    $privateMb = [math]::Round([double]$b.PrivateMemorySize64 / 1MB, 2)

    $score = [math]::Min(100.0,
        ([math]::Min(100.0, $cpuPercent) * 0.55) +
        (([math]::Min(8192.0, $workingSetMb) / 8192.0) * 100.0 * 0.25) +
        (([math]::Min(400.0, $ioMbPerSec) / 400.0) * 100.0 * 0.20)
    )

    $dominant = Get-DominantPressure -CpuPercent $cpuPercent -WorkingSetMb $workingSetMb -IoMbPerSec $ioMbPerSec
    $recommendation = Get-Recommendation -Score $score -DominantPressure $dominant

    $rows.Add([PSCustomObject]@{
        Score = [math]::Round($score, 2)
        ProcessName = [string]$b.ProcessName
        PID = [int]$b.Id
        CpuPercent = [math]::Round($cpuPercent, 2)
        WorkingSetMB = $workingSetMb
        PrivateMB = $privateMb
        IoMBps = [math]::Round($ioMbPerSec, 3)
        DominantPressure = $dominant
        Recommendation = $recommendation
    })
}

$topRows = $rows | Sort-Object Score -Descending | Select-Object -First $Top
$topOut = foreach ($row in $topRows) { $row }
$result = [PSCustomObject]@{
    GeneratedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    DurationSec = $DurationSec
    LogicalProcessors = $logicalProcessors
    TotalProcessesObserved = [int]$rows.Count
    TopProcesses = @($topOut)
}

if ($OutputJson) {
    $outDir = Split-Path -Parent $OutputJson
    if ($outDir -and (-not (Test-Path -LiteralPath $outDir))) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }
    $result | ConvertTo-Json -Depth 8 | Out-File -LiteralPath $OutputJson -Encoding utf8 -Force
}

$result
