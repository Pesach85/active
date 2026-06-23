$ErrorActionPreference = 'SilentlyContinue'

function Get-DriveStat($letter) {
    $v = Get-Volume -DriveLetter $letter
    if (-not $v) { return $null }
    $freeGB = [math]::Round($v.SizeRemaining / 1GB, 2)
    $sizeGB = [math]::Round($v.Size / 1GB, 2)
    $freePct = if ($v.Size -gt 0) { [math]::Round(($v.SizeRemaining / $v.Size) * 100, 2) } else { 0 }
    [ordered]@{ Drive = "${letter}:"; FreeGB = $freeGB; SizeGB = $sizeGB; FreePct = $freePct }
}

$report = [ordered]@{}
$report.Timestamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
$report.Drives = @(
    Get-DriveStat -letter 'C'
    Get-DriveStat -letter 'D'
)

$page = Get-CimInstance Win32_PageFileSetting | Select-Object Name, InitialSize, MaximumSize
$report.PageFile = @($page)

$hib = & powercfg /a 2>&1
$report.HibernationDisabled = [bool]($hib -match 'Ibernazione disattivata|Hibernation has not been enabled|The following sleep states are not available')
$report.PowerCfgA = ($hib -join "`n")

$services = @('MySQL80','AnyDesk','CODESYS Gateway V3','CODESYS ServiceControl','W3SVC','IISADMIN','AppHostSvc','FlexNet Licensing Service 64','Autocad2010','AdobeARMservice','SRManagementToolFtpServer','SRManagementToolFileMonitorService','Spooler')
$svcRows = foreach ($name in $services) {
    $svc = Get-CimInstance Win32_Service -Filter "Name='$name'"
    if ($svc) {
        [ordered]@{ Name = $name; StartMode = $svc.StartMode; State = $svc.State }
    }
}
$report.Services = @($svcRows)
$report.ServicesManualCount = @($svcRows | Where-Object { $_.StartMode -eq 'Manual' }).Count

$ntfsMem = (& fsutil behavior query memoryusage) -join ' '
$ntfsMft = (& fsutil behavior query mftzone) -join ' '
$report.Ntfs = [ordered]@{
    MemoryUsage = $ntfsMem
    MftZone = $ntfsMft
}

$sysResp = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' -Name 'SystemResponsiveness'
$report.SystemResponsiveness = $sysResp.SystemResponsiveness

$vfx = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' -Name 'VisualFXSetting'
$report.VisualFXSetting = $vfx.VisualFXSetting

$winget = & winget list --id CrystalDewWorld.CrystalDiskInfo 2>&1
$report.CrystalDiskInfoInstalled = [bool]($winget -match 'CrystalDiskInfo')
$report.CrystalDiskInfoRaw = ($winget -join "`n")

$repairWslScript = 'C:\SystemOptimizerHub\active\scripts\repair-wsl-config.ps1'
if (Test-Path -LiteralPath $repairWslScript) {
    try {
        $wslRaw = & pwsh -NoProfile -ExecutionPolicy Bypass -File $repairWslScript 2>$null
        if ($wslRaw) {
            $wsl = $wslRaw | ConvertFrom-Json
            $report.Wsl = [ordered]@{
                Status = [string]$wsl.Status
                DistributionName = [string]$wsl.DistributionName
                ZombieWslCount = [int]$wsl.ZombieWslCount
                WslService = [string]$wsl.WslService.Status
            }
        }
    } catch {
        $report.Wsl = [ordered]@{ Status = 'AssessmentFailed' }
    }
}

$auditPath = 'C:\SystemOptimizerHub\active\logs\health-audit-postreboot.json'
if (Test-Path $auditPath) {
    $audit = Get-Content -Raw $auditPath | ConvertFrom-Json
    $report.AuditSummary = [ordered]@{
        Total = $audit.Summary.TotalFindings
        Critical = $audit.Summary.Critical
        Important = $audit.Summary.Important
        Moderate = $audit.Summary.Moderate
        Info = $audit.Summary.Info
        AlreadyOptimized = @($audit.AlreadyOptimized).Count
    }
    $report.AuditFindingIds = @($audit.Findings | ForEach-Object { $_.Id })
}

$out = 'C:\SystemOptimizerHub\active\logs\post-reboot-verification.json'
$report | ConvertTo-Json -Depth 8 | Set-Content -Path $out -Encoding UTF8
Write-Host "Verification report written: $out"
Write-Host ("C: free {0} GB ({1}%)" -f $report.Drives[0].FreeGB, $report.Drives[0].FreePct)
Write-Host ("D: free {0} GB ({1}%)" -f $report.Drives[1].FreeGB, $report.Drives[1].FreePct)
Write-Host ("Services manual count: {0}/13" -f $report.ServicesManualCount)
Write-Host ("Audit findings: {0} (Critical={1}, Important={2}, Moderate={3}, Info={4})" -f $report.AuditSummary.Total, $report.AuditSummary.Critical, $report.AuditSummary.Important, $report.AuditSummary.Moderate, $report.AuditSummary.Info)
