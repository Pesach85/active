[CmdletBinding()]
param(
    [int]$DurationSec = 6,
    [int]$Top = 8,
    [string]$OutputJson = "",
    [string[]]$ExcludedProcesses = @("Idle", "System", "Registry", "Memory Compression")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Backward-compatible wrapper — delegates to Process Pressure Intelligence engine.
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$engine = Join-Path $scriptDir "analyze-process-pressure.ps1"
if (-not (Test-Path -LiteralPath $engine)) {
    throw "Process pressure engine not found: $engine"
}

$full = & $engine -DurationSec $DurationSec -Top $Top -IncludeResearch

$legacyTop = foreach ($row in @($full.TopProcesses)) {
    [PSCustomObject]@{
        Score = $row.Score
        ProcessName = $row.ProcessName
        PID = $row.PID
        CpuPercent = $row.CpuPercent
        WorkingSetMB = $row.WorkingSetMB
        PrivateMB = if ($row.PSObject.Properties['PrivateMB']) { $row.PrivateMB } else { 0 }
        IoMBps = $row.IoMBps
        DominantPressure = $row.DominantPressure
        Recommendation = $row.Recommendation
    }
}

$result = [PSCustomObject]@{
    GeneratedAt = $full.GeneratedAt
    DurationSec = $full.DurationSec
    LogicalProcessors = $full.LogicalProcessors
    TotalProcessesObserved = $full.TotalProcessesObserved
    TopProcesses = @($legacyTop)
}

if ($OutputJson) {
    ($result | ConvertTo-Json -Depth 8) | Out-File -LiteralPath $OutputJson -Encoding utf8 -Force
}

$result
