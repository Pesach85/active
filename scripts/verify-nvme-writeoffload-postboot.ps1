<#
.SYNOPSIS
    Post-reboot validation for NVMe write-offload Wave 3: verify pagefile relocation active.

.DESCRIPTION
    Runs after system reboot following S80 pagefile config.
    Validates that primary pagefile is now on C:\DataHub\Pagefile\pagefile.sys and captures KPI.

.PARAMETER OutputJson
    Path to JSON report for validation results.

.EXAMPLE
    .\verify-nvme-writeoffload-postboot.ps1 -OutputJson logs/writeoffload-verify-postboot.json
#>
param(
    [Parameter(Mandatory)][string]$OutputJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Progress2 {
    param([string]$Message)
    Write-Host "[POSTBOOT-VERIFY] $Message"
}

$report = [ordered]@{
    AuditVersion = '1.0.0'
    Timestamp = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
    Phase = 'PostRebootVerification'
    Summary = [ordered]@{
        Status = 'NotStarted'
        DeterministicPass = $false
        BestNextDecision = ''
    }
    Checks = @()
    Metrics = [ordered]@{}
    Error = $null
}

$checks = [System.Collections.ArrayList]::new()

function Add-Check {
    param(
        [System.Collections.ArrayList]$Checks,
        [string]$Name,
        [bool]$Passed,
        [string]$Current,
        [string]$Expected
    )

    [void]$Checks.Add([pscustomobject]@{
        Name = $Name
        Passed = $Passed
        Current = $Current
        Expected = $Expected
    })
}

try {
    Write-Progress2 'Verifying post-reboot pagefile relocation...'

    # Check 1: Pagefile registry config still in place
    $regPath = 'HKLM:\System\CurrentControlSet\Control\Session Manager\Memory Management'
    $pagingFilesValue = $null
    if (Test-Path -LiteralPath $regPath) {
        $pagingFilesValue = Get-ItemProperty -Path $regPath -Name 'PagingFiles' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty PagingFiles
    }
    $regConfigPresent = $null -ne $pagingFilesValue -and ($pagingFilesValue -like "*C:\DataHub\Pagefile\pagefile.sys*")
    Add-Check -Checks $checks -Name 'PagefileRegistryConfigPresent' -Passed $regConfigPresent -Current ([string]$regConfigPresent) -Expected 'True'

    # Check 2: Verify DataHub mount is still present
    $dataHubPath = 'C:\DataHub'
    $dataHubExists = Test-Path -LiteralPath $dataHubPath
    Add-Check -Checks $checks -Name 'DataHubMountPresent' -Passed $dataHubExists -Current ([string]$dataHubExists) -Expected 'True'

    # Check 3: Verify pagefile directory exists
    $pagefilePath = 'C:\DataHub\Pagefile'
    $pagefileDirExists = Test-Path -LiteralPath $pagefilePath
    Add-Check -Checks $checks -Name 'PagefileDirectoryExists' -Passed $pagefileDirExists -Current ([string]$pagefileDirExists) -Expected 'True'

    # Check 4: Check for active pagefile in DataHub (Windows creates/uses it)
    $pagefileSysPath = Join-Path $pagefilePath 'pagefile.sys'
    $pagefileSysExists = Test-Path -LiteralPath $pagefileSysPath
    Add-Check -Checks $checks -Name 'PagefileSysCreated' -Passed $pagefileSysExists -Current ([string]$pagefileSysExists) -Expected 'True'

    # Check 5: Verify NVMe C: free space (should be higher if pagefile freed space)
    $cVol = Get-Volume -DriveLetter C -ErrorAction Stop
    $cFreeGb = [math]::Round($cVol.SizeRemaining / 1GB, 2)
    $cUsedPct = if ($cVol.Size -gt 0) { [math]::Round((($cVol.Size - $cVol.SizeRemaining) / $cVol.Size) * 100, 2) } else { 0 }
    Add-Check -Checks $checks -Name 'CFreeGBPositive' -Passed ($cFreeGb -gt 5) -Current ([string]$cFreeGb) -Expected '>5GB'

    # Check 6: Verify browser cache symlinks still intact
    $userProfile = $env:USERPROFILE
    $chromeCache = Join-Path $userProfile 'AppData\Local\Google\Chrome\User Data\Default\Cache'
    $chromeLinked = $false
    if (Test-Path -LiteralPath $chromeCache) {
        $chromeLinked = (Get-Item -LiteralPath $chromeCache -ErrorAction SilentlyContinue).LinkType -eq 'SymbolicLink'
    }
    Add-Check -Checks $checks -Name 'ChromeCacheSymlinkIntact' -Passed $chromeLinked -Current ([string]$chromeLinked) -Expected 'True'

    # Check 7: Verify TEMP relocation still active
    $userTemp = [Environment]::GetEnvironmentVariable('TEMP', 'User')
    $userTempCorrect = $userTemp -eq 'C:\DataHub\Temp\User'
    Add-Check -Checks $checks -Name 'UserTempRelocationIntact' -Passed $userTempCorrect -Current $userTemp -Expected 'C:\DataHub\Temp\User'

    # Check 8: Verify machine TEMP still correct
    $machineTemp = [Environment]::GetEnvironmentVariable('TEMP', 'Machine')
    $machineTempCorrect = $machineTemp -eq 'C:\DataHub\Temp\System'
    Add-Check -Checks $checks -Name 'MachineTempRelocationIntact' -Passed $machineTempCorrect -Current $machineTemp -Expected 'C:\DataHub\Temp\System'

    # Metrics collection
    $report.Metrics.PostBootState = [ordered]@{
        CFreeGB = $cFreeGb
        CUsedPct = $cUsedPct
        UserTEMPPath = $userTemp
        MachineTEMPPath = $machineTemp
        PagefileRegistryConfig = $pagingFilesValue
        RebootTime = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
    }

    # Determine overall pass/fail
    $allPass = @($checks | Where-Object { -not $_.Passed }).Count -eq 0
    $report.Summary.Status = if ($allPass) { 'Completed' } else { 'Blocked' }
    $report.Summary.DeterministicPass = $allPass
    $report.Summary.BestNextDecision = if ($allPass) {
        'Wave 3 post-reboot validation passed. Pagefile now relocating to DataHub. Monitor C: free space trend over next 7 days for write-offload KPI.'
    } else {
        'Some checks failed. Review blocking items and verify DataHub mount + registry config.'
    }

    Write-Progress2 "Validation complete: Status=$($report.Summary.Status), Pass=$($report.Summary.DeterministicPass)"
}
catch {
    $report.Error = $_.Exception.Message
    $report.Summary.Status = 'Failed'
    if ([string]::IsNullOrWhiteSpace($report.Summary.BestNextDecision)) {
        $report.Summary.BestNextDecision = 'Resolve error and re-run post-reboot verification.'
    }
}
finally {
    $report.Checks = @($checks)

    $json = $report | ConvertTo-Json -Depth 12 -Compress:$false
    [System.IO.File]::WriteAllText($OutputJson, $json, [System.Text.Encoding]::UTF8)
    Write-Progress2 "Validation report saved to $OutputJson"
}
