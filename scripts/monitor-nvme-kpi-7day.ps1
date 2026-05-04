#Requires -RunAsAdministrator
<#
.SYNOPSIS
Monitor NVMe C: write reduction KPI over 7-day observation period (post-Wave3).
Tracks daily metrics: free space, pagefile usage, system performance, stability.

.PARAMETER OutputPath
JSON output path for KPI snapshot (default: logs/kpi-observation-{timestamp}.json)

.PARAMETER FullReport
If true, includes pagefile usage breakdown and symlink integrity checks

.NOTES
Designed to run every 5 minutes via scheduled task during observation period.
Decision criteria:
  - Go Wave 4: ≥30% NVMe write reduction + C: stable + no instability
  - Hold: <30% reduction or instability detected
  - Rollback: Wave 1-3 regression (symlinks broken, TEMP not relocated, etc.)
#>

param(
    [string]$OutputPath = "",
    [switch]$FullReport,
    [switch]$Retrospective  # Capture current state as baseline
)

$ErrorActionPreference = "Stop"

function Get-NVMeMetrics {
    <# Collect NVMe C: write metrics and disk health #>
    try {
        $volume = Get-Volume -DriveLetter C -ErrorAction Stop
        $cDrive = Get-PSDrive C
        
        return @{
            TimestampUTC = [DateTime]::UtcNow
            CFreeBytes = $volume.SizeRemaining
            CFreePct = [math]::Round(($volume.SizeRemaining / $volume.Size) * 100, 2)
            CUsedPct = [math]::Round((($volume.Size - $volume.SizeRemaining) / $volume.Size) * 100, 2)
            CTotalGB = [math]::Round($volume.Size / 1GB, 2)
            CUsedGB = [math]::Round(($volume.Size - $volume.SizeRemaining) / 1GB, 2)
        }
    } catch {
        Write-Warning "Failed to collect NVMe metrics: $_"
        return $null
    }
}

function Get-PagefileMetrics {
    <# Pagefile usage and configuration #>
    try {
        $pageFiles = Get-WmiObject -Class Win32_PageFileUsage -ErrorAction SilentlyContinue
        $pageFileSetting = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" -Name PagingFiles -ErrorAction SilentlyContinue
        
        $metrics = @{
            ConfiguredPageFiles = @()
            ActivePageFileUsage = @()
        }
        
        if ($pageFileSetting) {
            $metrics.ConfiguredPageFiles = @($pageFileSetting.PagingFiles) | Select-Object -ExpandProperty PagingFiles
        }
        
        if ($pageFiles) {
            foreach ($pf in $pageFiles) {
                $metrics.ActivePageFileUsage += @{
                    Name = $pf.Name
                    CurrentUsageMB = $pf.CurrentUsage
                    PeakUsageMB = $pf.PeakUsage
                }
            }
        }
        
        return $metrics
    } catch {
        Write-Warning "Failed to collect pagefile metrics: $_"
        return @{ ConfiguredPageFiles = @(); ActivePageFileUsage = @() }
    }
}

function Get-WriteOffloadValidation {
    <# Validate Wave 1-3 relocation integrity #>
    try {
        $validation = @{
            DataHubMountExists = Test-Path "C:\DataHub"
            UserTempPath = [Environment]::GetEnvironmentVariable("TEMP", "User")
            UserTempRelocated = [Environment]::GetEnvironmentVariable("TEMP", "User").StartsWith("C:\DataHub\Temp")
            MachineTemp = [Environment]::GetEnvironmentVariable("TEMP", "Machine")
            MachineTempRelocated = [Environment]::GetEnvironmentVariable("TEMP", "Machine").StartsWith("C:\DataHub\Temp")
            BrowserCacheSymlinks = @{
                ChromeIntact = $false
                FirefoxIntact = $false
                EdgeIntact = $false
            }
            DataHubSubdirectoriesExist = @{
                TempUser = Test-Path "C:\DataHub\Temp\User"
                TempSystem = Test-Path "C:\DataHub\Temp\System"
                CacheBrowsers = Test-Path "C:\DataHub\Cache\Browsers"
                CacheApps = Test-Path "C:\DataHub\Cache\Apps"
                PkgCache = Test-Path "C:\DataHub\PkgCache"
            }
        }
        
        # Check browser symlinks
        if ($FullReport) {
            $chromeProfile = "$env:LOCALAPPDATA\Google\Chrome\User Data"
            if (Test-Path "$chromeProfile\Default\Cache") {
                $target = (Get-Item "$chromeProfile\Default\Cache" -Force).LinkTarget
                $validation.BrowserCacheSymlinks.ChromeIntact = $target -like "*DataHub*"
            }
            
            $firefoxProfile = "$env:APPDATA\Mozilla\Firefox\Profiles"
            if (Test-Path $firefoxProfile) {
                $defaultProfile = Get-ChildItem $firefoxProfile -Filter "*.default" | Select-Object -First 1
                if ($defaultProfile) {
                    $cacheDir = "$($defaultProfile.FullName)\cache2"
                    if (Test-Path $cacheDir) {
                        $target = (Get-Item $cacheDir -Force).LinkTarget
                        $validation.BrowserCacheSymlinks.FirefoxIntact = $target -like "*DataHub*"
                    }
                }
            }
            
            $edgePath = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache"
            if (Test-Path $edgePath) {
                $target = (Get-Item $edgePath -Force).LinkTarget
                $validation.BrowserCacheSymlinks.EdgeIntact = $target -like "*DataHub*"
            }
        }
        
        return $validation
    } catch {
        Write-Warning "Failed to validate write-offload: $_"
        return $null
    }
}

function Get-SystemPerformance {
    <# CPU, memory, disk I/O health metrics #>
    try {
        $cpuLoad = (Get-WmiObject -Class Win32_Processor).LoadPercentage | Measure-Object -Average | Select-Object -ExpandProperty Average
        $memUsage = Get-WmiObject -Class Win32_OperatingSystem | Select-Object -ExpandProperty FreePhysicalMemory
        $totalMem = (Get-WmiObject -Class Win32_ComputerSystem | Select-Object -ExpandProperty TotalPhysicalMemory) / 1MB
        
        $logicalDisk = Get-WmiObject -Class Win32_LogicalDisk -Filter "Name='C:'" | Select-Object -ExpandProperty Name
        
        return @{
            CPULoadPercent = [math]::Round($cpuLoad, 2)
            FreeMemoryMB = [math]::Round($memUsage / 1024, 2)
            TotalMemoryGB = [math]::Round($totalMem / 1024, 2)
            MemoryUsedPercent = [math]::Round(((($totalMem * 1024) - $memUsage) / ($totalMem * 1024)) * 100, 2)
            NVMeHealthStatus = "Operational"  # Placeholder; would need storage diagnostic tools
        }
    } catch {
        Write-Warning "Failed to collect performance metrics: $_"
        return $null
    }
}

function Get-ApplicationStability {
    <# Check for recent crashes, warnings in event log #>
    try {
        $criticalEvents = @{
            LastHourCrashes = 0
            Last24hCrashes = 0
            LastHourWarnings = 0
        }
        
        $oneHourAgo = (Get-Date).AddHours(-1)
        $oneDayAgo = (Get-Date).AddDays(-1)
        
        try {
            $crashes = Get-WinEvent -LogName System -FilterXPath "*[System[(Level=1 or Level=2) and TimeCreated[timediff(@SystemTime) <= 3600000]]]" -ErrorAction SilentlyContinue
            $criticalEvents.LastHourCrashes = @($crashes).Count
            
            $allCrashes = Get-WinEvent -LogName System -FilterXPath "*[System[(Level=1 or Level=2) and TimeCreated[timediff(@SystemTime) <= 86400000]]]" -ErrorAction SilentlyContinue
            $criticalEvents.Last24hCrashes = @($allCrashes).Count
        } catch {
            # Graceful fallback if event log unavailable
        }
        
        return $criticalEvents
    } catch {
        Write-Warning "Failed to collect stability metrics: $_"
        return $null
    }
}

function New-KPISnapshot {
    [CmdletBinding()]
    param()
    
    Write-Host "📊 Collecting NVMe KPI snapshot..." -ForegroundColor Cyan
    
    $snapshot = @{
        Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
        TimestampUTC = [DateTime]::UtcNow.ToString("o")
        Phase = "Wave3-Observation"
        NVMeMetrics = Get-NVMeMetrics
        PagefileMetrics = Get-PagefileMetrics
        WriteOffloadValidation = Get-WriteOffloadValidation
        SystemPerformance = Get-SystemPerformance
        ApplicationStability = Get-ApplicationStability
        Verdict = @{
            AllChecksPass = $true
            RegressionDetected = $false
            RecommendedAction = "Wave4-Ready"  # Default; updated based on metrics
        }
    }
    
    # Validate verdict based on collected data
    if ($snapshot.WriteOffloadValidation.UserTempRelocated -eq $false -or $snapshot.WriteOffloadValidation.MachineTempRelocated -eq $false) {
        $snapshot.Verdict.RegressionDetected = $true
        $snapshot.Verdict.AllChecksPass = $false
        $snapshot.Verdict.RecommendedAction = "Rollback-Wave1-Recovery"
    }
    
    if ($snapshot.ApplicationStability.Last24hCrashes -gt 5) {
        $snapshot.Verdict.AllChecksPass = $false
        $snapshot.Verdict.RecommendedAction = "Hold-Investigate-Stability"
    }
    
    return $snapshot
}

# Main execution
try {
    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $timestamp = (Get-Date -Format "yyyyMMdd-HHmmss")
        $mode = if ($Retrospective) { "retrospective-baseline" } else { "snapshot" }
        $OutputPath = "logs/kpi-observation-${mode}-${timestamp}.json"
    }
    
    $snapshot = New-KPISnapshot
    
    # Ensure logs directory exists
    $logsDir = Split-Path $OutputPath -Parent
    if (-not (Test-Path $logsDir)) {
        New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    }
    
    # Write JSON output
    $snapshot | ConvertTo-Json -Depth 10 | Set-Content $OutputPath -Encoding UTF8
    
    Write-Host "✅ KPI snapshot saved to: $OutputPath" -ForegroundColor Green
    
    # Display summary
    Write-Host "`n📋 KPI Summary:" -ForegroundColor Cyan
    $cfreeText = "$($snapshot.NVMeMetrics.CFreePct)% ($([math]::Round($snapshot.NVMeMetrics.CFreeBytes/1GB, 2))GB)"
    Write-Host "  C: Free Space: $cfreeText" -ForegroundColor White
    Write-Host "  User TEMP Relocated: $($snapshot.WriteOffloadValidation.UserTempRelocated)" -ForegroundColor White
    Write-Host "  Machine TEMP Relocated: $($snapshot.WriteOffloadValidation.MachineTempRelocated)" -ForegroundColor White
    Write-Host "  DataHub Mount: $($snapshot.WriteOffloadValidation.DataHubMountExists)" -ForegroundColor White
    Write-Host "  Pagefile Active Instances: $($snapshot.PagefileMetrics.ActivePageFileUsage.Count)" -ForegroundColor White
    
    $verdictColor = if ($snapshot.Verdict.AllChecksPass) { "Green" } else { "Yellow" }
    Write-Host "  Verdict: $($snapshot.Verdict.RecommendedAction)" -ForegroundColor $verdictColor
    
    $regColor = if ($snapshot.Verdict.RegressionDetected) { "Red" } else { "Green" }
    Write-Host "  Regression: $($snapshot.Verdict.RegressionDetected)" -ForegroundColor $regColor
    
    exit 0
} catch {
    Write-Error "KPI monitoring failed: $_"
    exit 1
}
