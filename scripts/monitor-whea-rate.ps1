#Requires -RunAsAdministrator
<#
.SYNOPSIS
Monitor WHEA (Windows Hardware Error Architecture) error rate post-mitigation.
Tracks corrected vs uncorrected errors every 10 minutes during 24h observation window.

.PARAMETER OutputPath
JSON output path for WHEA monitoring snapshots (default: logs/whea-monitoring-continuous.json)

.PARAMETER WindowMinutes
Lookback window size in minutes for error counting (default: 10)

.PARAMETER Quiet
If true, suppresses console output (use for scheduled task runs)

.PARAMETER Retrospective
If true, capture current baseline state and exit

.NOTES
Decision criteria (post-badmemorylist expansion):
  - Go Wave 5: ≤300 WHEA/10min in all 3 checks (freeze config, schedule DIMM replacement)
  - Hold: 300–600 WHEA/10min (continue observation)
  - Escalate: >600 WHEA/10min (truncatememory + Secure Boot disable, or further expansion)

Designed to run every 10 minutes via scheduled task.
#>

param(
    [string]$OutputPath = "",
    [int]$WindowMinutes = 10,
    [switch]$Quiet,
    [switch]$Retrospective
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# ============================================================================
# Configuration
# ============================================================================
if (-not $OutputPath) {
    $OutputPath = "C:\SystemOptimizerHub\active\logs\whea-monitoring-continuous.json"
}

$LogDir = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $LogDir)) {
    New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
}

# WHEA Errors channel
$WheatLogName = "Microsoft-Windows-Kernel-WHEA/Errors"
$SystemLogName = "System"
$WheatProvider = "Microsoft-Windows-WHEA-Logger"

# ============================================================================
# Functions
# ============================================================================
function Get-WHEA-Rate {
    <# Count WHEA errors in the last N minutes by Event ID #>
    param([int]$MinutesBack)
    
    try {
        $cutoffTime = (Get-Date).AddMinutes(-$MinutesBack)
        
        # All corrected WHEA errors (WHEA Errors channel)
        $correctedEvents = @()
        try {
            $correctedEvents = @(Get-WinEvent -LogName $WheatLogName -FilterScript {
                $_.TimeCreated -ge $cutoffTime
            } -ErrorAction SilentlyContinue)
        } catch {
            # Channel may not exist or be empty
        }
        
        # Uncorrected WHEA errors in System log (WHEA-Logger provider)
        $uncorrectedEvents = @()
        try {
            $uncorrectedEvents = @(Get-WinEvent -FilterHashtable @{
                LogName = $SystemLogName
                ProviderName = $WheatProvider
                StartTime = $cutoffTime
            } -ErrorAction SilentlyContinue)
        } catch {
            # May not exist
        }
        
        # Group by Event ID for histogram
        $correctedByID = $correctedEvents | Group-Object -Property Id -AsHashTable -AsString
        $uncorrectedByID = $uncorrectedEvents | Group-Object -Property Id -AsHashTable -AsString
        
        return @{
            CorrectedCount = $correctedEvents.Count
            UncorrectedCount = $uncorrectedEvents.Count
            TotalCount = $correctedEvents.Count + $uncorrectedEvents.Count
            CorrectedByID = $correctedByID
            UncorrectedByID = $uncorrectedByID
            CorrectedEvents = $correctedEvents
            UncorrectedEvents = $uncorrectedEvents
        }
    } catch {
        Write-Warning "Failed to retrieve WHEA events: $_"
        return $null
    }
}

function Get-Historical-Data {
    <# Load existing monitoring data if available #>
    if (Test-Path -LiteralPath $OutputPath) {
        try {
            $raw = Get-Content -LiteralPath $OutputPath -Raw | ConvertFrom-Json -AsHashtable
            return $raw
        } catch {
            return $null
        }
    }
    return $null
}

function Calculate-Rolling-Average {
    <# Calculate 24h rolling average from history #>
    param([array]$History, [int]$WindowCount = 144)  # 144 * 10min = 24h
    
    if (-not $History -or $History.Count -eq 0) { return $null }
    
    $recent = $History | Select-Object -Last $WindowCount
    if ($recent.Count -eq 0) { return $null }
    
    $avg = ($recent | Measure-Object -Property TotalCount -Average).Average
    return [math]::Round($avg, 2)
}

function Get-Trend-Direction {
    <# Simple trend: up/stable/down based on last 3 measurements #>
    param([array]$History)
    
    if (-not $History -or $History.Count -lt 3) { return "unknown" }
    
    $last3 = $History | Select-Object -Last 3 | ForEach-Object { $_.TotalCount }
    $delta1 = $last3[1] - $last3[0]
    $delta2 = $last3[2] - $last3[1]
    
    if ($delta1 -gt 50 -or $delta2 -gt 50) { return "up" }
    if ($delta1 -lt -50 -or $delta2 -lt -50) { return "down" }
    return "stable"
}

function Export-Snapshot {
    <# Export current measurement and update continuous log #>
    param(
        [object]$WHEAData,
        [datetime]$Timestamp
    )
    
    # Load or create history
    $data = Get-Historical-Data
    if (-not $data) {
        $data = @{
            RowVersion = 1
            CreatedUTC = [DateTime]::UtcNow.ToString("o")
            MitigationApplied = $true
            MitigationScope = "badmemorylist (721 PFN, NeighborWindow=180)"
            Measurements = @()
        }
    }
    
    # Ensure Measurements is an array
    if ($data.Measurements -isnot [object[]]) {
        $data.Measurements = @()
    }
    
    # Add current measurement
    $snapshot = @{
        TimestampUTC = $Timestamp.ToString("o")
        CorrectedCount = $WHEAData.CorrectedCount
        UncorrectedCount = $WHEAData.UncorrectedCount
        TotalCount = $WHEAData.TotalCount
        CorrectedByID = @{}
        UncorrectedByID = @{}
    }
    
    # Build ID histograms for export
    if ($WHEAData.CorrectedByID) {
        foreach ($id in $WHEAData.CorrectedByID.Keys) {
            $snapshot.CorrectedByID[[string]$id] = @($WHEAData.CorrectedByID[$id]).Count
        }
    }
    if ($WHEAData.UncorrectedByID) {
        foreach ($id in $WHEAData.UncorrectedByID.Keys) {
            $snapshot.UncorrectedByID[[string]$id] = @($WHEAData.UncorrectedByID[$id]).Count
        }
    }
    
    $data.Measurements += $snapshot
    
    # Keep rolling 24h window (+ 1 buffer)
    $maxCount = 145
    if ($data.Measurements.Count -gt $maxCount) {
        $data.Measurements = $data.Measurements | Select-Object -Last $maxCount
    }
    
    # Calculate statistics
    $avg24h = Calculate-Rolling-Average -History $data.Measurements
    $trend = Get-Trend-Direction -History $data.Measurements
    
    $data.LastUpdate = [DateTime]::UtcNow.ToString("o")
    $data.RollingAverage24h = $avg24h
    $data.Trend = $trend
    $data.LatestTotal = $WHEAData.TotalCount
    
    # Export JSON
    $data | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $OutputPath -Encoding utf8 -Force
    
    return @{
        Snapshot = $snapshot
        History = $data
        RollingAvg24h = $avg24h
        Trend = $trend
    }
}

# ============================================================================
# Main
# ============================================================================
$timestamp = Get-Date

if ($Retrospective) {
    # Capture baseline
    $whea = Get-WHEA-Rate -MinutesBack 0
    $result = Export-Snapshot -WHEAData $whea -Timestamp $timestamp
    Write-Host "✓ Baseline captured: WHEA Total=$($result.Snapshot.TotalCount)" -ForegroundColor Green
    exit 0
}

# Normal monitoring run
$whea = Get-WHEA-Rate -MinutesBack $WindowMinutes

if (-not $whea) {
    Write-Error "Failed to retrieve WHEA data"
    exit 1
}

$result = Export-Snapshot -WHEAData $whea -Timestamp $timestamp

# Console output (unless -Quiet)
if (-not $Quiet) {
    Write-Host "`n=== WHEA Rate Monitor (10-min window) ===" -ForegroundColor Cyan
    Write-Host "Timestamp          : $($timestamp.ToString('yyyy-MM-dd HH:mm:ss Z'))"
    Write-Host "Corrected Errors   : $($result.Snapshot.CorrectedCount)"
    Write-Host "Uncorrected Errors : $($result.Snapshot.UncorrectedCount)"
    Write-Host "Total (10-min)     : $($result.Snapshot.TotalCount)" -ForegroundColor $(
        if ($result.Snapshot.TotalCount -le 300) { "Green" }
        elseif ($result.Snapshot.TotalCount -le 600) { "Yellow" }
        else { "Red" }
    )
    
    if ($result.RollingAvg24h) {
        Write-Host "Rolling Avg (24h)  : $($result.RollingAvg24h) events/10min"
    }
    
    if ($result.Trend) {
        Write-Host "Trend              : $($result.Trend)"
    }
    
    # ID breakdown
    if ($result.Snapshot.CorrectedByID.Count -gt 0) {
        Write-Host "`nCorrected by Event ID:" -ForegroundColor Gray
        foreach ($id in ($result.Snapshot.CorrectedByID.Keys | Sort-Object)) {
            Write-Host "  ID $id : $($result.Snapshot.CorrectedByID[$id])"
        }
    }
    
    if ($result.Snapshot.UncorrectedByID.Count -gt 0) {
        Write-Host "`nUncorrected by Event ID:" -ForegroundColor Yellow
        foreach ($id in ($result.Snapshot.UncorrectedByID.Keys | Sort-Object)) {
            Write-Host "  ID $id : $($result.Snapshot.UncorrectedByID[$id])"
        }
    }
    
    Write-Host "`nLog saved: $OutputPath`n"
}

exit 0
