[CmdletBinding()]
param(
    [switch]$Execute,
    [string]$ConfigPath = '',
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'hub-common.ps1')
$hub = Get-HubPaths
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = $hub.ConfigFile
}
$config = Get-MaintenanceConfig -ConfigPath $ConfigPath
$fsCfg = Get-ConfigSection -Config $config -SectionName 'FsIntegrity'

if (-not $fsCfg.ContainsKey('Enabled') -or -not [bool]$fsCfg.Enabled) {
    Write-Host '[FS-INTEGRITY] Scan disabled in config (FsIntegrity.Enabled=false).' -ForegroundColor Yellow
    exit 0
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $rel = if ($fsCfg.OutputPath) { [string]$fsCfg.OutputPath } else { 'logs/fs-integrity-latest.json' }
    $OutputPath = Resolve-HubPath -HubRoot $hub.HubRoot -Path $rel
}

$lookbackHours = if ($fsCfg.EventLookbackHours) { [int]$fsCfg.EventLookbackHours } else { 24 }
$scanDrives = @($fsCfg.ScanDrives)
if (-not $scanDrives -or $scanDrives.Count -eq 0) {
    $scanDrives = @('C', 'D')
}

$outDir = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $outDir)) {
    New-Item -Path $outDir -ItemType Directory -Force | Out-Null
}

$findings = [System.Collections.Generic.List[object]]::new()
$checkedPaths = [System.Collections.Generic.List[object]]::new()

function Add-Finding {
    param(
        [string]$Severity,
        [string]$Category,
        [string]$Title,
        [string]$Detail
    )
    [void]$findings.Add([ordered]@{
        Severity  = $Severity
        Category  = $Category
        Title     = $Title
        Detail    = $Detail
        Timestamp = (Get-Date).ToString('o')
    })
}

Write-Host '[FS-INTEGRITY] Starting scan-only filesystem integrity assessment...' -ForegroundColor Cyan

foreach ($driveLetter in $scanDrives) {
    $root = '{0}:\' -f $driveLetter.ToUpperInvariant()
    if (-not (Test-Path -LiteralPath $root)) {
        Add-Finding -Severity 'Important' -Category 'Drive' -Title "Drive $driveLetter missing" -Detail "Path not accessible: $root"
        continue
    }

    try {
        $vol = Get-Volume -DriveLetter $driveLetter -ErrorAction Stop
        [void]$checkedPaths.Add([ordered]@{
            Drive       = $driveLetter
            Health      = [string]$vol.HealthStatus
            FileSystem  = [string]$vol.FileSystem
            FreeGB      = [math]::Round($vol.SizeRemaining / 1GB, 2)
        })

        if ($vol.HealthStatus -and $vol.HealthStatus -ne 'Healthy') {
            Add-Finding -Severity 'Critical' -Category 'Drive' -Title "Volume $driveLetter unhealthy" -Detail "HealthStatus=$($vol.HealthStatus)"
        }
    } catch {
        Add-Finding -Severity 'Important' -Category 'Drive' -Title "Volume query failed on $driveLetter" -Detail $_.Exception.Message
    }

    try {
        $dirty = (& fsutil dirty query $root 2>&1 | Out-String).Trim()
        if ($dirty -match 'dirty') {
            Add-Finding -Severity 'Critical' -Category 'CHKDSK' -Title "Dirty bit set on $driveLetter" -Detail $dirty
        }
    } catch {
        # Non-blocking on permission errors.
    }
}

$dataHub = 'C:\DataHub'
if (Test-Path -LiteralPath $dataHub) {
    Get-ChildItem -LiteralPath $dataHub -Force -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            try {
                $target = $_.Target
                if ($target) {
                    $resolved = $target
                    if ($target -is [string[]]) { $resolved = $target[0] }
                    if (-not (Test-Path -LiteralPath $resolved)) {
                        Add-Finding -Severity 'Critical' -Category 'Symlink' -Title 'Broken DataHub symlink' -Detail ("{0} -> {1}" -f $_.FullName, $resolved)
                    }
                }
            } catch {
                Add-Finding -Severity 'Important' -Category 'Symlink' -Title 'Symlink check failed' -Detail $_.FullName
            }
        }
    }
}

$cutoff = (Get-Date).AddHours(-$lookbackHours)
try {
    $fsEvents = @(Get-WinEvent -FilterHashtable @{
        LogName   = 'System'
        StartTime = $cutoff
        Id        = 7, 9, 11, 15, 50, 55, 57, 153
    } -ErrorAction SilentlyContinue)
    if ($fsEvents.Count -gt 0) {
        Add-Finding -Severity 'Important' -Category 'EventLog' -Title 'Recent filesystem-related System events' -Detail ("Count={0} in last {1}h" -f $fsEvents.Count, $lookbackHours)
    }
} catch {
    Add-Finding -Severity 'Important' -Category 'EventLog' -Title 'Filesystem event query failed' -Detail $_.Exception.Message
}

if ($Execute) {
    Write-Host '[FS-INTEGRITY] WARNING: -Execute is scan-only â€” no automated repair is implemented. Use vendor/chkdsk tools for remediation.' -ForegroundColor Yellow
}

$report = [ordered]@{
    Mode           = if ($Execute) { 'scan-only-requested-execute-not-implemented' } else { 'scan-only' }
    TimestampUTC   = [DateTime]::UtcNow.ToString('o')
    HubRoot        = $hub.HubRoot
    DrivesChecked  = @($checkedPaths)
    FindingCount   = $findings.Count
    Findings       = @($findings)
    Recommendation = if ($findings.Count -eq 0) { 'No filesystem integrity issues detected.' } else { 'Review findings before cleanup or hardware changes.' }
}

$report | ConvertTo-Json -Depth 8 | Out-File -LiteralPath $OutputPath -Encoding utf8 -Force
Write-Host ("[FS-INTEGRITY] Report written: {0} (findings={1})" -f $OutputPath, $findings.Count) -ForegroundColor Green

if ($findings.Count -gt 0) { exit 2 }
exit 0
