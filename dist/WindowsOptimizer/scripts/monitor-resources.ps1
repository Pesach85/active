param(
    [string]$ConfigPath = "C:\\config\\sys-maintenance.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($PSVersionTable.PSEdition -ne "Core") {
    Write-Warning "This script is optimized for PowerShell Core (pwsh)."
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Config file not found: $ConfigPath"
}

$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -AsHashtable

$logDirectory = [string]$config.LogDirectory
$logPath = Join-Path -Path $logDirectory -ChildPath ([string]$config.LogFileName)
if (-not (Test-Path -LiteralPath $logDirectory)) {
    New-Item -Path $logDirectory -ItemType Directory -Force | Out-Null
}

$cpuHistory = @{}
$violationCounter = @{}
$unresponsiveCounter = @{}
$cycle = 0
$logicalProcessors = [Environment]::ProcessorCount
$loopIntervalSeconds = [int]$config.LoopIntervalSeconds

function Write-Log {
    param(
        [string]$Level,
        [string]$Message
    )

    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    "$timestamp [$Level] $Message" | Out-File -LiteralPath $logPath -Encoding utf8 -Append
}

function Resolve-Priority {
    param([string]$Name)

    switch ($Name) {
        "Idle" { return [System.Diagnostics.ProcessPriorityClass]::Idle }
        "BelowNormal" { return [System.Diagnostics.ProcessPriorityClass]::BelowNormal }
        "Normal" { return [System.Diagnostics.ProcessPriorityClass]::Normal }
        "AboveNormal" { return [System.Diagnostics.ProcessPriorityClass]::AboveNormal }
        "High" { return [System.Diagnostics.ProcessPriorityClass]::High }
        default { return [System.Diagnostics.ProcessPriorityClass]::BelowNormal }
    }
}

$throttlePriority = Resolve-Priority -Name ([string]$config.TargetPriorityOnThrottle)
$excluded = @($config.ExcludedProcesses)

Write-Log -Level "INFO" -Message "Resource monitor started. Interval=${loopIntervalSeconds}s, CPUs=$logicalProcessors"

while ($true) {
    try {
        $cycle++
        $processes = Get-Process -ErrorAction SilentlyContinue

        foreach ($proc in $processes) {
            if ($excluded -contains $proc.ProcessName) {
                continue
            }

            $procKey = "{0}-{1}" -f $proc.Id, $proc.StartTime.Ticks
            $cpuNow = [double]$proc.CPU
            $cpuPercent = 0.0

            if ($cpuHistory.ContainsKey($procKey)) {
                $cpuDelta = $cpuNow - $cpuHistory[$procKey]
                if ($cpuDelta -gt 0) {
                    $cpuPercent = ($cpuDelta / ($loopIntervalSeconds * $logicalProcessors)) * 100
                }
            }
            $cpuHistory[$procKey] = $cpuNow

            $memoryMb = [math]::Round($proc.WorkingSet64 / 1MB, 0)
            $cpuViolation = $cpuPercent -ge [double]$config.CpuHighPercentThreshold
            $memoryViolation = $memoryMb -ge [double]$config.MemoryHighMbThreshold
            $isUnresponsive = $false

            if ($config.Zombie.Enabled -and $proc.MainWindowHandle -ne 0) {
                $isUnresponsive = -not $proc.Responding
            }

            if ($cpuViolation -or $memoryViolation -or $isUnresponsive) {
                if (-not $violationCounter.ContainsKey($procKey)) {
                    $violationCounter[$procKey] = 0
                }
                $violationCounter[$procKey]++

                if ($isUnresponsive) {
                    if (-not $unresponsiveCounter.ContainsKey($procKey)) {
                        $unresponsiveCounter[$procKey] = 0
                    }
                    $unresponsiveCounter[$procKey]++
                } else {
                    $unresponsiveCounter[$procKey] = 0
                }

                $shouldThrottle = $violationCounter[$procKey] -ge 2
                if ($shouldThrottle) {
                    try {
                        if ($proc.PriorityClass -ne $throttlePriority) {
                            $proc.PriorityClass = $throttlePriority
                            Write-Log -Level "WARN" -Message ("Throttle PID={0} Name={1} CPU={2:N1}% RAM={3}MB Priority={4}" -f $proc.Id, $proc.ProcessName, $cpuPercent, $memoryMb, $proc.PriorityClass)
                        }
                    } catch {
                        Write-Log -Level "ERROR" -Message ("Cannot change priority PID={0} Name={1}: {2}" -f $proc.Id, $proc.ProcessName, $_.Exception.Message)
                    }
                }

                $zombieHit = $false
                if ($config.Zombie.Enabled -and $isUnresponsive) {
                    $zombieHit = $unresponsiveCounter[$procKey] -ge [int]$config.Zombie.ConsecutiveUnresponsiveChecks
                }

                $maxViolations = [int]$config.MaxConsecutiveViolations
                $terminateNow = [bool]$config.AutoTerminate -and (($violationCounter[$procKey] -ge $maxViolations) -or $zombieHit)
                if ($terminateNow) {
                    try {
                        Stop-Process -Id $proc.Id -Force -ErrorAction Stop
                        Write-Log -Level "CRITICAL" -Message ("Terminated PID={0} Name={1} after violations={2}" -f $proc.Id, $proc.ProcessName, $violationCounter[$procKey])
                    } catch {
                        Write-Log -Level "ERROR" -Message ("Cannot terminate PID={0} Name={1}: {2}" -f $proc.Id, $proc.ProcessName, $_.Exception.Message)
                    }
                }
            } else {
                $violationCounter[$procKey] = 0
                $unresponsiveCounter[$procKey] = 0
            }
        }

        if (($cycle % [int]$config.StorageCheckEveryCycles) -eq 0) {
            foreach ($driveLetter in $config.DrivesToMonitor) {
                $drive = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='{0}:'" -f $driveLetter) -ErrorAction SilentlyContinue
                if ($null -eq $drive -or $drive.Size -eq 0) {
                    continue
                }

                $freePercent = [math]::Round(($drive.FreeSpace / $drive.Size) * 100, 2)
                $freeGb = [math]::Round($drive.FreeSpace / 1GB, 2)

                if ($freePercent -lt [double]$config.MinFreePercentWarning) {
                    Write-Log -Level "WARN" -Message ("Low disk space {0}: Free={1}% ({2} GB)" -f $drive.DeviceID, $freePercent, $freeGb)
                } else {
                    Write-Log -Level "INFO" -Message ("Disk status {0}: Free={1}% ({2} GB)" -f $drive.DeviceID, $freePercent, $freeGb)
                }
            }
        }
    } catch {
        Write-Log -Level "ERROR" -Message ("Loop error: {0}" -f $_.Exception.Message)
    }

    Start-Sleep -Seconds $loopIntervalSeconds
}
