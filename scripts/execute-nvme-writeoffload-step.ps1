<#
.SYNOPSIS
    Execute deterministic NVMe write-offload steps (audit/apply) with validation.

.DESCRIPTION
    Runs one operational step at a time and writes a structured JSON report with
    checks, actions, rollback hints, and outcome.

.PARAMETER StepId
    Step selector: S00-S80 (Waves 1-3), S90-S120 (Wave 4)
    - S00: Baseline KPI
    - S10: DataHub mount + scaffold
    - S20: User TEMP/TMP relocation
    - S30: Machine TEMP/TMP relocation
    - S40: Browser cache audit
    - S50: App cache audit
    - S60: Cache relocation (symlinks)
    - S70: Package manager cache audit
    - S80: Pagefile relocation config
    - S90: npm/yarn cache relocation
    - S100: pip cache relocation
    - S110: NuGet/Maven/Gradle relocation
    - S120: Apply all package manager redirects

.PARAMETER OutputJson
    Path to JSON report for the executed step.

.PARAMETER Apply
    Apply changes for the selected step. Without this switch, runs audit-only.

.PARAMETER DataDriveLetter
    Data drive letter used as write-offload target (default E).

.PARAMETER DataRoot
    Stable logical data root path (default C:\DataHub).
#>
param(
    [Parameter(Mandatory)][ValidateSet('S00','S10','S20','S30','S40','S50','S60','S70','S80','S90','S100','S110','S120')][string]$StepId,
    [Parameter(Mandatory)][string]$OutputJson,
    [switch]$Apply,
    [ValidatePattern('^[A-Za-z]$')][string]$DataDriveLetter = 'E',
    [string]$DataRoot = 'C:\DataHub'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Progress2 {
    param([string]$Message)
    Write-Host "[WRITEOFFLOAD] $Message"
}

function Test-IsAdmin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

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

function New-Report {
    param([string]$Step)

    return [ordered]@{
        AuditVersion = '1.0.0'
        Timestamp = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
        StepId = $Step
        ApplyRequested = [bool]$Apply
        Applied = $false
        Admin = [bool](Test-IsAdmin)
        DataDriveLetter = $DataDriveLetter.ToUpperInvariant()
        DataRoot = $DataRoot
        Summary = [ordered]@{
            Status = 'NotStarted'
            BestNextDecision = ''
            DeterministicPass = $false
        }
        Checks = @()
        Actions = @()
        RollbackHints = @()
        Metrics = [ordered]@{}
        Error = $null
    }
}

function Resolve-DataVolume {
    param([char]$Letter)

    $vol = Get-Volume -DriveLetter $Letter -ErrorAction SilentlyContinue
    if (-not $vol) { return $null }

    $part = Get-Partition -DriveLetter $Letter -ErrorAction SilentlyContinue
    if (-not $part) { return $null }

    return [ordered]@{
        Volume = $vol
        Partition = $part
    }
}

function Ensure-Dir {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

$report = New-Report -Step $StepId
$checks = [System.Collections.ArrayList]::new()
$actions = [System.Collections.ArrayList]::new()
$rollback = [System.Collections.ArrayList]::new()

try {
    $data = Resolve-DataVolume -Letter ([char]$DataDriveLetter)
    $dataPresent = $null -ne $data
    if ($dataPresent) {
        $freeGb = [math]::Round($data.Volume.SizeRemaining / 1GB, 2)
        $sizeGb = [math]::Round($data.Volume.Size / 1GB, 2)
        $report.Metrics.DataVolume = [ordered]@{
            Letter = ("{0}:" -f $DataDriveLetter.ToUpperInvariant())
            Label = [string]$data.Volume.FileSystemLabel
            SizeGB = $sizeGb
            FreeGB = $freeGb
            Path = [string]$data.Volume.Path
        }
        Add-Check -Checks $checks -Name 'DataVolumePresent' -Passed $true -Current ("{0}:" -f $DataDriveLetter.ToUpperInvariant()) -Expected 'Volume exists'
        Add-Check -Checks $checks -Name 'DataVolumeFreeGB' -Passed ($freeGb -ge 100) -Current ([string]$freeGb) -Expected '>=100GB'
    } else {
        Add-Check -Checks $checks -Name 'DataVolumePresent' -Passed $false -Current 'Missing' -Expected ("{0}: exists" -f $DataDriveLetter.ToUpperInvariant())
    }

    switch ($StepId) {
        'S00' {
            Write-Progress2 'Running baseline metrics audit...'

            $cVol = Get-Volume -DriveLetter C -ErrorAction Stop
            $cFreeGb = [math]::Round($cVol.SizeRemaining / 1GB, 2)
            $cSizeGb = [math]::Round($cVol.Size / 1GB, 2)
            $cUsedPct = if ($cVol.Size -gt 0) { [math]::Round((($cVol.Size - $cVol.SizeRemaining) / $cVol.Size) * 100, 2) } else { 0 }

            $topWriters = Get-Process -ErrorAction SilentlyContinue |
                Sort-Object -Property IOWriteBytes -Descending |
                Select-Object -First 10 Name,Id,IOWriteBytes

            $report.Metrics.Baseline = [ordered]@{
                CSizeGB = $cSizeGb
                CFreeGB = $cFreeGb
                CUsedPct = $cUsedPct
                UserTEMP = [Environment]::GetEnvironmentVariable('TEMP','User')
                UserTMP = [Environment]::GetEnvironmentVariable('TMP','User')
                MachineTEMP = [Environment]::GetEnvironmentVariable('TEMP','Machine')
                MachineTMP = [Environment]::GetEnvironmentVariable('TMP','Machine')
                TopWriters = @($topWriters)
            }

            Add-Check -Checks $checks -Name 'CFreeGB' -Passed ($cFreeGb -ge 15) -Current ([string]$cFreeGb) -Expected '>=15GB'
            Add-Check -Checks $checks -Name 'BaselineCollected' -Passed $true -Current 'Yes' -Expected 'Yes'

            $report.Summary.Status = 'Completed'
            $report.Summary.DeterministicPass = $true
            $report.Summary.BestNextDecision = 'Proceed to S10 (DataHub mount + scaffold) in apply mode.'
            [void]$actions.Add('Collected baseline KPIs and write-heavy process list.')
            [void]$rollback.Add('No changes applied in S00.')
        }

        'S10' {
            Write-Progress2 'Preparing stable DataHub target...'
            Add-Check -Checks $checks -Name 'AdminRequired' -Passed ([bool]$report.Admin) -Current ([string]$report.Admin) -Expected 'True'

            if (-not $dataPresent) {
                throw ("Data drive {0}: not found." -f $DataDriveLetter.ToUpperInvariant())
            }
            if (-not $report.Admin) {
                throw 'S10 apply requires Administrator rights.'
            }

            $dataPhysicalRoot = ("{0}:\DataHub" -f $DataDriveLetter.ToUpperInvariant())
            $mountPath = ($DataRoot.TrimEnd('\') + '\')

            if ($Apply) {
                Ensure-Dir -Path $dataPhysicalRoot
                Ensure-Dir -Path $DataRoot

                $part = $data.Partition
                $accessPaths = @($part.AccessPaths | ForEach-Object { [string]$_ })
                $hasMount = @($accessPaths | ForEach-Object { $_.ToLowerInvariant() }) -contains $mountPath.ToLowerInvariant()
                if (-not $hasMount) {
                    Add-PartitionAccessPath -DiskNumber $part.DiskNumber -PartitionNumber $part.PartitionNumber -AccessPath $mountPath -ErrorAction Stop
                    [void]$actions.Add(("Added mount path {0} for {1}:" -f $mountPath, $DataDriveLetter.ToUpperInvariant()))
                }

                $dirs = @(
                    (Join-Path $DataRoot 'Temp\User'),
                    (Join-Path $DataRoot 'Temp\System'),
                    (Join-Path $DataRoot 'Cache\Browsers'),
                    (Join-Path $DataRoot 'PkgCache\Node'),
                    (Join-Path $DataRoot 'PkgCache\Python'),
                    (Join-Path $DataRoot 'PkgCache\NuGet'),
                    (Join-Path $DataRoot 'PkgCache\Maven'),
                    (Join-Path $DataRoot 'PkgCache\Gradle'),
                    (Join-Path $DataRoot 'Work'),
                    (Join-Path $DataRoot 'VM'),
                    (Join-Path $DataRoot 'Cloud\OneDrive'),
                    (Join-Path $DataRoot 'Containers\Docker'),
                    (Join-Path $DataRoot 'WSL')
                )
                foreach ($d in $dirs) { Ensure-Dir -Path $d }
                [void]$actions.Add('Created DataHub directory scaffold.')
            }

            $partAfter = Get-Partition -DriveLetter $DataDriveLetter -ErrorAction Stop
            $mountSetAfter = @($partAfter.AccessPaths | ForEach-Object { ([string]$_).ToLowerInvariant() })
            $hasMountAfter = $mountSetAfter -contains $mountPath.ToLowerInvariant()
            Add-Check -Checks $checks -Name 'DataRootMountPath' -Passed $hasMountAfter -Current ([string]$hasMountAfter) -Expected 'True'

            $criticalDirs = @(
                (Join-Path $DataRoot 'Temp\User'),
                (Join-Path $DataRoot 'Temp\System'),
                (Join-Path $DataRoot 'Cache\Browsers')
            )
            $dirsOk = @($criticalDirs | Where-Object { Test-Path -LiteralPath $_ }).Count -eq $criticalDirs.Count
            Add-Check -Checks $checks -Name 'CriticalDataHubDirsExist' -Passed $dirsOk -Current ([string]$dirsOk) -Expected 'True'

            $allPass = @($checks | Where-Object { -not $_.Passed }).Count -eq 0
            $report.Summary.Status = if ($allPass) { 'Completed' } else { 'Blocked' }
            $report.Summary.DeterministicPass = $allPass
            $report.Summary.BestNextDecision = if ($allPass) { 'Proceed to S20 (user TEMP/TMP relocation).' } else { 'Fix blocking checks before next step.' }
            [void]$rollback.Add('Remove mount path with Remove-PartitionAccessPath if you need to revert DataHub mount.')
        }

        'S20' {
            Write-Progress2 'Relocating USER TEMP/TMP...'

            $userTempTarget = Join-Path $DataRoot 'Temp\User'
            Ensure-Dir -Path $userTempTarget

            $oldUserTemp = [Environment]::GetEnvironmentVariable('TEMP','User')
            $oldUserTmp = [Environment]::GetEnvironmentVariable('TMP','User')
            $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
            $backupPath = Join-Path (Join-Path $PSScriptRoot '..\logs\diagnostics') ("user-env-backup-{0}.json" -f $stamp)
            Ensure-Dir -Path (Split-Path -Parent $backupPath)

            $backup = [ordered]@{
                Timestamp = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
                OldUserTEMP = $oldUserTemp
                OldUserTMP = $oldUserTmp
                NewTarget = $userTempTarget
            }
            [System.IO.File]::WriteAllText($backupPath, ($backup | ConvertTo-Json -Depth 6), [System.Text.Encoding]::UTF8)
            [void]$actions.Add(("Saved user env backup: {0}" -f $backupPath))

            if ($Apply) {
                [Environment]::SetEnvironmentVariable('TEMP', $userTempTarget, 'User')
                [Environment]::SetEnvironmentVariable('TMP', $userTempTarget, 'User')
                $env:TEMP = $userTempTarget
                $env:TMP = $userTempTarget
                [void]$actions.Add('Updated User TEMP and TMP to DataHub target.')
            }

            $newUserTemp = [Environment]::GetEnvironmentVariable('TEMP','User')
            $newUserTmp = [Environment]::GetEnvironmentVariable('TMP','User')
            Add-Check -Checks $checks -Name 'UserTEMPRelocated' -Passed ($newUserTemp -eq $userTempTarget) -Current $newUserTemp -Expected $userTempTarget
            Add-Check -Checks $checks -Name 'UserTMPRelocated' -Passed ($newUserTmp -eq $userTempTarget) -Current $newUserTmp -Expected $userTempTarget
            Add-Check -Checks $checks -Name 'UserTempPathExists' -Passed (Test-Path -LiteralPath $userTempTarget) -Current ([string](Test-Path -LiteralPath $userTempTarget)) -Expected 'True'

            $allPass = @($checks | Where-Object { -not $_.Passed }).Count -eq 0
            $report.Summary.Status = if ($allPass) { 'Completed' } else { 'Blocked' }
            $report.Summary.DeterministicPass = $allPass
            $report.Summary.BestNextDecision = if ($allPass) { 'Proceed to S30 (machine TEMP/TMP relocation).' } else { 'Fix blocking checks before next step.' }
            [void]$rollback.Add(("Restore user TEMP/TMP from backup file: {0}" -f $backupPath))
            $report.Metrics.UserEnvBackup = $backupPath
        }

        'S30' {
            Write-Progress2 'Relocating MACHINE TEMP/TMP...'
            Add-Check -Checks $checks -Name 'AdminRequired' -Passed ([bool]$report.Admin) -Current ([string]$report.Admin) -Expected 'True'

            if (-not $report.Admin) {
                throw 'S30 requires Administrator rights.'
            }

            $machineTempTarget = Join-Path $DataRoot 'Temp\System'
            Ensure-Dir -Path $machineTempTarget

            $oldMachineTemp = [Environment]::GetEnvironmentVariable('TEMP','Machine')
            $oldMachineTmp = [Environment]::GetEnvironmentVariable('TMP','Machine')
            $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
            $backupPath = Join-Path (Join-Path $PSScriptRoot '..\logs\diagnostics') ("machine-env-backup-{0}.json" -f $stamp)
            Ensure-Dir -Path (Split-Path -Parent $backupPath)

            $backup = [ordered]@{
                Timestamp = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
                OldMachineTEMP = $oldMachineTemp
                OldMachineTMP = $oldMachineTmp
                NewTarget = $machineTempTarget
            }
            [System.IO.File]::WriteAllText($backupPath, ($backup | ConvertTo-Json -Depth 6), [System.Text.Encoding]::UTF8)
            [void]$actions.Add(("Saved machine env backup: {0}" -f $backupPath))

            if ($Apply) {
                [Environment]::SetEnvironmentVariable('TEMP', $machineTempTarget, 'Machine')
                [Environment]::SetEnvironmentVariable('TMP', $machineTempTarget, 'Machine')
                [void]$actions.Add('Updated Machine TEMP and TMP to DataHub target.')
            }

            $newMachineTemp = [Environment]::GetEnvironmentVariable('TEMP','Machine')
            $newMachineTmp = [Environment]::GetEnvironmentVariable('TMP','Machine')
            Add-Check -Checks $checks -Name 'MachineTEMPRelocated' -Passed ($newMachineTemp -eq $machineTempTarget) -Current $newMachineTemp -Expected $machineTempTarget
            Add-Check -Checks $checks -Name 'MachineTMPRelocated' -Passed ($newMachineTmp -eq $machineTempTarget) -Current $newMachineTmp -Expected $machineTempTarget
            Add-Check -Checks $checks -Name 'MachineTempPathExists' -Passed (Test-Path -LiteralPath $machineTempTarget) -Current ([string](Test-Path -LiteralPath $machineTempTarget)) -Expected 'True'

            $allPass = @($checks | Where-Object { -not $_.Passed }).Count -eq 0
            $report.Summary.Status = if ($allPass) { 'Completed' } else { 'Blocked' }
            $report.Summary.DeterministicPass = $allPass
            $report.Summary.BestNextDecision = if ($allPass) { 'Proceed to next wave (browser/tool cache relocation).' } else { 'Fix blocking checks before next step.' }
            [void]$rollback.Add(("Restore machine TEMP/TMP from backup file: {0}" -f $backupPath))
            $report.Metrics.MachineEnvBackup = $backupPath
        }

        'S40' {
            Write-Progress2 'Auditing browser cache locations...'

            $browserCacheData = [ordered]@{
                Chrome = $null
                ChromeSize = 0
                Firefox = $null
                FirefoxSize = 0
                Edge = $null
                EdgeSize = 0
            }

            $userProfile = $env:USERPROFILE
            if ($userProfile -and (Test-Path -LiteralPath $userProfile)) {
                $chromeCache = Join-Path $userProfile 'AppData\Local\Google\Chrome\User Data\Default\Cache'
                if (Test-Path -LiteralPath $chromeCache) {
                    $browserCacheData.Chrome = $chromeCache
                    $browserCacheData.ChromeSize = (Get-ChildItem -Path $chromeCache -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1MB
                }

                $firefoxProfile = Join-Path $userProfile 'AppData\Local\Mozilla\Firefox\Profiles'
                if (Test-Path -LiteralPath $firefoxProfile) {
                    $ffCaches = @(Get-ChildItem -Path $firefoxProfile -Filter 'cache2' -Directory -ErrorAction SilentlyContinue)
                    if ($ffCaches.Count -gt 0) {
                        $browserCacheData.Firefox = ($ffCaches.FullName -join '; ')
                        $browserCacheData.FirefoxSize = ($ffCaches | Get-ChildItem -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1MB
                    }
                }

                $edgeCache = Join-Path $userProfile 'AppData\Local\Microsoft\Edge\User Data\Default\Cache'
                if (Test-Path -LiteralPath $edgeCache) {
                    $browserCacheData.Edge = $edgeCache
                    $browserCacheData.EdgeSize = (Get-ChildItem -Path $edgeCache -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1MB
                }
            }

            $totalBrowserMb = $browserCacheData.ChromeSize + $browserCacheData.FirefoxSize + $browserCacheData.EdgeSize
            Add-Check -Checks $checks -Name 'BrowserCacheDetected' -Passed ($totalBrowserMb -gt 0) -Current ([string]$totalBrowserMb) -Expected '>0 MB'
            Add-Check -Checks $checks -Name 'BrowserCachePathsValid' -Passed (($browserCacheData.Chrome -or $browserCacheData.Firefox -or $browserCacheData.Edge) -and ($userProfile)) -Current $(if ($userProfile) { 'UserProfile found' } else { 'No profile' }) -Expected 'UserProfile found'

            $report.Summary.Status = 'Completed'
            $report.Summary.DeterministicPass = $true
            $report.Summary.BestNextDecision = if ($totalBrowserMb -gt 0) { 'Proceed to S50 (app cache audit).' } else { 'Skip cache relocation or verify browser state.' }
            $report.Metrics.BrowserCaches = $browserCacheData
            [void]$actions.Add(("Detected browser caches total: {0:F2} MB" -f $totalBrowserMb))
        }

        'S50' {
            Write-Progress2 'Auditing application cache locations...'

            $appCacheData = [ordered]@{
                Microsoft = $null
                MicrosoftSize = 0
                Adobe = $null
                AdobeSize = 0
                VSCode = $null
                VSCodeSize = 0
            }

            $userProfile = $env:USERPROFILE
            if ($userProfile -and (Test-Path -LiteralPath $userProfile)) {
                $msAppData = Join-Path $userProfile 'AppData\Local\Microsoft'
                if (Test-Path -LiteralPath $msAppData) {
                    $appCacheData.Microsoft = $msAppData
                    $appCacheData.MicrosoftSize = (Get-ChildItem -Path $msAppData -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1MB
                }

                $adobeAppData = Join-Path $userProfile 'AppData\Local\Adobe'
                if (Test-Path -LiteralPath $adobeAppData) {
                    $appCacheData.Adobe = $adobeAppData
                    $appCacheData.AdobeSize = (Get-ChildItem -Path $adobeAppData -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1MB
                }

                $vscodeAppData = Join-Path $userProfile 'AppData\Roaming\Code'
                if (Test-Path -LiteralPath $vscodeAppData) {
                    $appCacheData.VSCode = $vscodeAppData
                    $appCacheData.VSCodeSize = (Get-ChildItem -Path $vscodeAppData -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1MB
                }
            }

            $totalAppMb = $appCacheData.MicrosoftSize + $appCacheData.AdobeSize + $appCacheData.VSCodeSize
            Add-Check -Checks $checks -Name 'AppCacheDetected' -Passed ($totalAppMb -gt 0) -Current ([string]$totalAppMb) -Expected '>0 MB'
            Add-Check -Checks $checks -Name 'DataRootCacheBrowsersExists' -Passed (Test-Path -LiteralPath (Join-Path $DataRoot 'Cache\Browsers')) -Current $(if (Test-Path -LiteralPath (Join-Path $DataRoot 'Cache\Browsers')) { 'Exists' } else { 'Missing' }) -Expected 'Exists'

            $report.Summary.Status = 'Completed'
            $report.Summary.DeterministicPass = $true
            $report.Summary.BestNextDecision = 'Proceed to S60 (apply cache relocation) if browser cache > 100MB.'
            $report.Metrics.AppCaches = $appCacheData
            [void]$actions.Add(("Detected app caches total: {0:F2} MB" -f $totalAppMb))
        }

        'S60' {
            Write-Progress2 'Applying browser and application cache relocation...'
            Add-Check -Checks $checks -Name 'AdminRequired' -Passed ([bool]$report.Admin) -Current ([string]$report.Admin) -Expected 'True'

            if (-not $report.Admin) {
                throw 'S60 apply requires Administrator rights.'
            }

            $userProfile = $env:USERPROFILE
            if (-not ($userProfile -and (Test-Path -LiteralPath $userProfile))) {
                throw 'Unable to resolve user profile path.'
            }

            $browserCacheTarget = Join-Path $DataRoot 'Cache\Browsers'
            $appCacheTarget = Join-Path $DataRoot 'Cache\Apps'
            Ensure-Dir -Path $browserCacheTarget
            Ensure-Dir -Path $appCacheTarget

            $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
            $backupPath = Join-Path (Join-Path $PSScriptRoot '..\logs\diagnostics') ("cache-relocation-backup-{0}.json" -f $stamp)
            Ensure-Dir -Path (Split-Path -Parent $backupPath)

            $backup = [ordered]@{
                Timestamp = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
                Operations = [System.Collections.ArrayList]::new()
            }

            if ($Apply) {
                $chromeCache = Join-Path $userProfile 'AppData\Local\Google\Chrome\User Data\Default\Cache'
                $chromeBkup = Join-Path $browserCacheTarget 'Chrome_old'
                if (Test-Path -LiteralPath $chromeCache) {
                    Copy-Item -Path $chromeCache -Destination $chromeBkup -Recurse -ErrorAction SilentlyContinue
                    Remove-Item -Path $chromeCache -Recurse -Force -ErrorAction SilentlyContinue
                    New-Item -ItemType SymbolicLink -Path $chromeCache -Target (Join-Path $browserCacheTarget 'Chrome') -Force -ErrorAction SilentlyContinue | Out-Null
                    [void]$backup.Operations.Add([ordered]@{ Type = 'ChromeCache'; BackupPath = $chromeBkup; Status = 'Migrated' })
                    [void]$actions.Add("Symlinked Chrome cache to DataHub.")
                }

                $firefoxProfile = Join-Path $userProfile 'AppData\Local\Mozilla\Firefox\Profiles'
                $ffCaches = @(Get-ChildItem -Path $firefoxProfile -Filter 'cache2' -Directory -ErrorAction SilentlyContinue)
                foreach ($ffCache in $ffCaches) {
                    $ffBkup = Join-Path $browserCacheTarget ("Firefox_{0}_old" -f $ffCache.Name)
                    Copy-Item -Path $ffCache.FullName -Destination $ffBkup -Recurse -ErrorAction SilentlyContinue
                    Remove-Item -Path $ffCache.FullName -Recurse -Force -ErrorAction SilentlyContinue
                    New-Item -ItemType SymbolicLink -Path $ffCache.FullName -Target (Join-Path $browserCacheTarget ("Firefox_{0}" -f $ffCache.Name)) -Force -ErrorAction SilentlyContinue | Out-Null
                    [void]$backup.Operations.Add([ordered]@{ Type = 'FirefoxCache'; Profile = $ffCache.Name; BackupPath = $ffBkup; Status = 'Migrated' })
                    [void]$actions.Add("Symlinked Firefox cache ($($ffCache.Name)) to DataHub.")
                }

                $edgeCache = Join-Path $userProfile 'AppData\Local\Microsoft\Edge\User Data\Default\Cache'
                $edgeBkup = Join-Path $browserCacheTarget 'Edge_old'
                if (Test-Path -LiteralPath $edgeCache) {
                    Copy-Item -Path $edgeCache -Destination $edgeBkup -Recurse -ErrorAction SilentlyContinue
                    Remove-Item -Path $edgeCache -Recurse -Force -ErrorAction SilentlyContinue
                    New-Item -ItemType SymbolicLink -Path $edgeCache -Target (Join-Path $browserCacheTarget 'Edge') -Force -ErrorAction SilentlyContinue | Out-Null
                    [void]$backup.Operations.Add([ordered]@{ Type = 'EdgeCache'; BackupPath = $edgeBkup; Status = 'Migrated' })
                    [void]$actions.Add("Symlinked Edge cache to DataHub.")
                }
            }

            [System.IO.File]::WriteAllText($backupPath, ($backup | ConvertTo-Json -Depth 6), [System.Text.Encoding]::UTF8)
            [void]$actions.Add(("Saved cache relocation backup: {0}" -f $backupPath))

            $chromeLinked = $false
            $firefoxLinked = $false
            $edgeLinked = $false

            $chromeCache = Join-Path $userProfile 'AppData\Local\Google\Chrome\User Data\Default\Cache'
            if (Test-Path -LiteralPath $chromeCache) {
                $chromeLinked = (Get-Item -LiteralPath $chromeCache -ErrorAction SilentlyContinue).LinkType -eq 'SymbolicLink'
            }

            $firefoxProfile = Join-Path $userProfile 'AppData\Local\Mozilla\Firefox\Profiles'
            $ffCaches = @(Get-ChildItem -Path $firefoxProfile -Filter 'cache2' -Directory -ErrorAction SilentlyContinue)
            $firefoxLinked = @($ffCaches | Where-Object { (Get-Item -LiteralPath $_.FullName -ErrorAction SilentlyContinue).LinkType -eq 'SymbolicLink' }).Count -eq $ffCaches.Count

            $edgeCache = Join-Path $userProfile 'AppData\Local\Microsoft\Edge\User Data\Default\Cache'
            if (Test-Path -LiteralPath $edgeCache) {
                $edgeLinked = (Get-Item -LiteralPath $edgeCache -ErrorAction SilentlyContinue).LinkType -eq 'SymbolicLink'
            }

            Add-Check -Checks $checks -Name 'ChromeCacheSymlinked' -Passed $chromeLinked -Current ([string]$chromeLinked) -Expected 'True'
            Add-Check -Checks $checks -Name 'FirefoxCacheSymlinked' -Passed $firefoxLinked -Current ([string]$firefoxLinked) -Expected 'True'
            Add-Check -Checks $checks -Name 'EdgeCacheSymlinked' -Passed $edgeLinked -Current ([string]$edgeLinked) -Expected 'True'
            Add-Check -Checks $checks -Name 'CacheTargetsExist' -Passed ((Test-Path -LiteralPath $browserCacheTarget) -and (Test-Path -LiteralPath $appCacheTarget)) -Current $(if ((Test-Path -LiteralPath $browserCacheTarget) -and (Test-Path -LiteralPath $appCacheTarget)) { 'Both exist' } else { 'Missing' }) -Expected 'Both exist'

            $allPass = @($checks | Where-Object { -not $_.Passed }).Count -eq 0
            $report.Summary.Status = if ($allPass) { 'Completed' } else { 'Blocked' }
            $report.Summary.DeterministicPass = $allPass
            $report.Summary.BestNextDecision = if ($allPass) { 'Wave 2 complete. Verify browser/app performance post-relocation. Next: Wave 3 (package manager caches).' } else { 'Fix blocking checks or restore from backup.' }
            [void]$rollback.Add(("Restore caches from backup file: {0}" -f $backupPath))
            $report.Metrics.CacheRelocationBackup = $backupPath
        }

        'S70' {
            Write-Progress2 'Auditing package manager caches...'

            $pkgCacheData = [ordered]@{
                NPM = @{ Path = $null; SizeMB = 0 }
                Pnpm = @{ Path = $null; SizeMB = 0 }
                Yarn = @{ Path = $null; SizeMB = 0 }
                Pip = @{ Path = $null; SizeMB = 0 }
                NuGet = @{ Path = $null; SizeMB = 0 }
                Maven = @{ Path = $null; SizeMB = 0 }
                Gradle = @{ Path = $null; SizeMB = 0 }
            }

            $userProfile = $env:USERPROFILE
            if ($userProfile) {
                # npm cache
                $npmCache = Join-Path $userProfile '.npm'
                if (Test-Path -LiteralPath $npmCache) {
                    $pkgCacheData.NPM.Path = $npmCache
                    $pkgCacheData.NPM.SizeMB = (Get-ChildItem -Path $npmCache -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1MB
                }

                # pnpm store
                $pnpmHome = $env:PNPM_HOME; if (-not $pnpmHome) { $pnpmHome = Join-Path $userProfile '.pnpm-store' }
                if (Test-Path -LiteralPath $pnpmHome) {
                    $pkgCacheData.Pnpm.Path = $pnpmHome
                    $pkgCacheData.Pnpm.SizeMB = (Get-ChildItem -Path $pnpmHome -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1MB
                }

                # yarn cache
                $yarnCache = Join-Path $userProfile '.yarn\cache'
                if (Test-Path -LiteralPath $yarnCache) {
                    $pkgCacheData.Yarn.Path = $yarnCache
                    $pkgCacheData.Yarn.SizeMB = (Get-ChildItem -Path $yarnCache -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1MB
                }

                # pip cache
                $pipCache = Join-Path $userProfile 'AppData\Local\pip\Cache'
                if (Test-Path -LiteralPath $pipCache) {
                    $pkgCacheData.Pip.Path = $pipCache
                    $pkgCacheData.Pip.SizeMB = (Get-ChildItem -Path $pipCache -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1MB
                }

                # NuGet cache
                $nugetCache = Join-Path $userProfile '.nuget\packages'
                if (Test-Path -LiteralPath $nugetCache) {
                    $pkgCacheData.NuGet.Path = $nugetCache
                    $pkgCacheData.NuGet.SizeMB = (Get-ChildItem -Path $nugetCache -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1MB
                }

                # Maven cache
                $mavenHome = $env:M2_HOME; if (-not $mavenHome) { $mavenHome = Join-Path $userProfile '.m2' }
                if (Test-Path -LiteralPath $mavenHome) {
                    $pkgCacheData.Maven.Path = $mavenHome
                    $pkgCacheData.Maven.SizeMB = (Get-ChildItem -Path $mavenHome -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1MB
                }

                # Gradle cache
                $gradleHome = $env:GRADLE_USER_HOME; if (-not $gradleHome) { $gradleHome = Join-Path $userProfile '.gradle' }
                if (Test-Path -LiteralPath $gradleHome) {
                    $pkgCacheData.Gradle.Path = $gradleHome
                    $pkgCacheData.Gradle.SizeMB = (Get-ChildItem -Path $gradleHome -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1MB
                }
            }

            $totalPkgMb = @($pkgCacheData.Values | ForEach-Object { $_.SizeMB }) | Measure-Object -Sum | Select-Object -ExpandProperty Sum
            Add-Check -Checks $checks -Name 'PkgCacheDetected' -Passed ($totalPkgMb -gt 0) -Current ([string]$totalPkgMb) -Expected '>0 MB'
            Add-Check -Checks $checks -Name 'DataRootPkgCacheExists' -Passed (Test-Path -LiteralPath (Join-Path $DataRoot 'PkgCache')) -Current $(if (Test-Path -LiteralPath (Join-Path $DataRoot 'PkgCache')) { 'Exists' } else { 'Missing' }) -Expected 'Exists'

            $report.Summary.Status = 'Completed'
            $report.Summary.DeterministicPass = $true
            $report.Summary.BestNextDecision = if ($totalPkgMb -gt 100) { 'Proceed to S80 (pagefile relocation) which requires reboot.' } else { 'Skip to S80 or reschedule later.' }
            $report.Metrics.PackageManagerCaches = $pkgCacheData
            [void]$actions.Add(("Detected package manager caches total: {0:F2} MB" -f $totalPkgMb))
        }

        'S80' {
            Write-Progress2 'Setting up pagefile relocation...'
            Add-Check -Checks $checks -Name 'AdminRequired' -Passed ([bool]$report.Admin) -Current ([string]$report.Admin) -Expected 'True'

            if (-not $report.Admin) {
                throw 'S80 apply requires Administrator rights.'
            }

            if (-not $dataPresent) {
                throw ("Data drive {0}: not found." -f $DataDriveLetter.ToUpperInvariant())
            }

            $pagefileRoot = Join-Path $DataRoot 'Pagefile'
            $pagefilePrimary = Join-Path $pagefileRoot 'pagefile.sys'
            Ensure-Dir -Path $pagefileRoot

            $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
            $backupPath = Join-Path (Join-Path $PSScriptRoot '..\logs\diagnostics') ("pagefile-config-backup-{0}.json" -f $stamp)
            Ensure-Dir -Path (Split-Path -Parent $backupPath)

            $backup = [ordered]@{
                Timestamp = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
                PagefilePrimary = $pagefilePrimary
                PagefileFallback = 'C:\pagefile.sys'
                RequiresReboot = $true
                ConfigCommand = "fsutil behavior set disable-lastaccess 1"
            }

            if ($Apply) {
                try {
                    # Disable last-access timestamp for performance
                    fsutil behavior set disable-lastaccess 1 -ErrorAction SilentlyContinue | Out-Null

                    # Configure pagefile registry entry (will take effect after reboot)
                    # HKLM\System\CurrentControlSet\Control\Session Manager\Memory Management
                    $regPath = 'HKLM:\System\CurrentControlSet\Control\Session Manager\Memory Management'
                    if (-not (Test-Path -LiteralPath $regPath)) {
                        New-Item -Path $regPath -Force | Out-Null
                    }

                    # Create pagefile registry entries for multi-boot safety
                    # PagingFiles format: "C:\pagefile.sys 1024 2048" (min/max in MB)
                    $pagefileSpec = @(
                        ("{0} 2048 4096" -f $pagefilePrimary),
                        "C:\pagefile.sys 512 1024"
                    ) -join "`0"

                    New-ItemProperty -Path $regPath -Name 'PagingFiles' -Value $pagefileSpec -Force | Out-Null
                    [void]$actions.Add(("Configured pagefile registry: {0} (primary) + C:\ (fallback)" -f $pagefilePrimary))
                    [void]$backup.Add('AppliedDate', (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'))
                }
                catch {
                    throw ("Pagefile configuration failed: {0}" -f $_.Exception.Message)
                }
            }

            [System.IO.File]::WriteAllText($backupPath, ($backup | ConvertTo-Json -Depth 6), [System.Text.Encoding]::UTF8)
            [void]$actions.Add(("Saved pagefile config backup: {0}" -f $backupPath))

            # Validation: check registry entry was written
            $pagingFilesValue = $null
            $regPath = 'HKLM:\System\CurrentControlSet\Control\Session Manager\Memory Management'
            if (Test-Path -LiteralPath $regPath) {
                $pagingFilesValue = Get-ItemProperty -Path $regPath -Name 'PagingFiles' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty PagingFiles
            }

            $pagefileConfigured = $null -ne $pagingFilesValue -and ($pagingFilesValue -like "*$pagefilePrimary*")
            $pagefileFallbackPresent = $null -ne $pagingFilesValue -and ($pagingFilesValue -like "*C:\pagefile.sys*")

            Add-Check -Checks $checks -Name 'PagefileTargetDirExists' -Passed (Test-Path -LiteralPath $pagefileRoot) -Current ([string](Test-Path -LiteralPath $pagefileRoot)) -Expected 'True'
            Add-Check -Checks $checks -Name 'PagefilePrimaryConfigured' -Passed $pagefileConfigured -Current ([string]$pagefileConfigured) -Expected 'True'
            Add-Check -Checks $checks -Name 'PagefileFallbackConfigured' -Passed $pagefileFallbackPresent -Current ([string]$pagefileFallbackPresent) -Expected 'True'
            Add-Check -Checks $checks -Name 'RebootRequired' -Passed $true -Current 'Reboot required' -Expected 'Pending'

            $allPass = @($checks | Where-Object { -not $_.Passed }).Count -eq 0
            $report.Summary.Status = if ($allPass) { 'Completed' } else { 'Blocked' }
            $report.Summary.DeterministicPass = $allPass
            $report.Summary.BestNextDecision = if ($allPass) { 'REBOOT REQUIRED to activate pagefile relocation. After reboot, verify C:\DataHub\Pagefile\pagefile.sys is in use.' } else { 'Fix blocking checks or verify registry write permissions.' }
            [void]$rollback.Add(("Restore pagefile config from backup: {0}" -f $backupPath))
            [void]$rollback.Add("Delete HKLM:\System\CurrentControlSet\Control\Session Manager\Memory Management\PagingFiles and reboot to revert.")
            $report.Metrics.PagefileConfig = $backup
            $report.Applied = [bool]$Apply -and $pagefileConfigured
        }

        'S90' {
            Write-Progress2 'Auditing npm/yarn package manager caches...'
            Add-Check -Checks $checks -Name 'DataRootExists' -Passed (Test-Path -LiteralPath $DataRoot) -Current $(if (Test-Path -LiteralPath $DataRoot) { 'Exists' } else { 'Missing' }) -Expected 'Exists'

            $npmCacheDir = Join-Path $env:APPDATA 'npm-cache'
            $yarnCacheDir = Join-Path $env:LOCALAPPDATA 'yarn-cache'
            
            $npmExists = Test-Path -LiteralPath $npmCacheDir
            $yarnExists = Test-Path -LiteralPath $yarnCacheDir
            
            $npmSize = if ($npmExists) { (Get-ChildItem -Path $npmCacheDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1MB } else { 0 }
            $yarnSize = if ($yarnExists) { (Get-ChildItem -Path $yarnCacheDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1MB } else { 0 }

            Add-Check -Checks $checks -Name 'NpmCacheDetected' -Passed $npmExists -Current $(if ($npmExists) { "Found: {0:F2}MB" -f $npmSize } else { 'Not found' }) -Expected 'Found'
            Add-Check -Checks $checks -Name 'YarnCacheDetected' -Passed $yarnExists -Current $(if ($yarnExists) { "Found: {0:F2}MB" -f $yarnSize } else { 'Not found' }) -Expected 'Found'

            $totalSize = $npmSize + $yarnSize
            Add-Check -Checks $checks -Name 'PkgCacheTargetDirExists' -Passed (Test-Path -LiteralPath (Join-Path $DataRoot 'PkgCache')) -Current $(if (Test-Path -LiteralPath (Join-Path $DataRoot 'PkgCache')) { 'Exists' } else { 'Missing' }) -Expected 'Exists'

            $report.Summary.Status = 'Completed'
            $report.Summary.DeterministicPass = @($checks | Where-Object { -not $_.Passed }).Count -eq 0
            $report.Summary.BestNextDecision = if ($totalSize -gt 50) { 'npm/yarn detected. Proceed to S100 (pip audit) then S120 (apply).' } else { 'Minimal npm/yarn cache; continue to next step.' }
            $report.Metrics = @{
                NpmCacheMB = [math]::Round($npmSize, 2)
                YarnCacheMB = [math]::Round($yarnSize, 2)
                TotalNodePkgMB = [math]::Round($totalSize, 2)
            }
            [void]$actions.Add(("npm cache: {0:F2}MB, yarn cache: {1:F2}MB" -f $npmSize, $yarnSize))
        }

        'S100' {
            Write-Progress2 'Auditing pip package manager cache...'
            Add-Check -Checks $checks -Name 'DataRootExists' -Passed (Test-Path -LiteralPath $DataRoot) -Current $(if (Test-Path -LiteralPath $DataRoot) { 'Exists' } else { 'Missing' }) -Expected 'Exists'

            $pipCacheDir = Join-Path $env:LOCALAPPDATA 'pip\cache'
            $pipExists = Test-Path -LiteralPath $pipCacheDir
            $pipSize = if ($pipExists) { (Get-ChildItem -Path $pipCacheDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1MB } else { 0 }

            Add-Check -Checks $checks -Name 'PipCacheDetected' -Passed $pipExists -Current $(if ($pipExists) { "Found: {0:F2}MB" -f $pipSize } else { 'Not found' }) -Expected 'Found or MissingOK'
            Add-Check -Checks $checks -Name 'PkgCacheTargetDirExists' -Passed (Test-Path -LiteralPath (Join-Path $DataRoot 'PkgCache')) -Current $(if (Test-Path -LiteralPath (Join-Path $DataRoot 'PkgCache')) { 'Exists' } else { 'Missing' }) -Expected 'Exists'

            $report.Summary.Status = 'Completed'
            $report.Summary.DeterministicPass = @($checks | Where-Object { -not $_.Passed }).Count -eq 0
            $report.Summary.BestNextDecision = 'Proceed to S110 (NuGet/Maven/Gradle audit) then S120 (apply all).'
            $report.Metrics = @{
                PipCacheMB = [math]::Round($pipSize, 2)
            }
            [void]$actions.Add(("pip cache: {0:F2}MB" -f $pipSize))
        }

        'S110' {
            Write-Progress2 'Auditing NuGet, Maven, Gradle package caches...'
            Add-Check -Checks $checks -Name 'DataRootExists' -Passed (Test-Path -LiteralPath $DataRoot) -Current $(if (Test-Path -LiteralPath $DataRoot) { 'Exists' } else { 'Missing' }) -Expected 'Exists'

            $nugetHome = Join-Path $env:USERPROFILE '.nuget'
            $mavenHome = Join-Path $env:USERPROFILE '.m2'
            $gradleHome = Join-Path $env:USERPROFILE '.gradle'

            $nugetSize = if (Test-Path -LiteralPath $nugetHome) { (Get-ChildItem -Path $nugetHome -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1MB } else { 0 }
            $mavenSize = if (Test-Path -LiteralPath $mavenHome) { (Get-ChildItem -Path $mavenHome -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1MB } else { 0 }
            $gradleSize = if (Test-Path -LiteralPath $gradleHome) { (Get-ChildItem -Path $gradleHome -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1MB } else { 0 }

            Add-Check -Checks $checks -Name 'NugetCacheDetected' -Passed ($nugetSize -gt 0) -Current "$([math]::Round($nugetSize, 2))MB" -Expected '>0 (or OK if absent)'
            Add-Check -Checks $checks -Name 'MavenCacheDetected' -Passed ($mavenSize -gt 0) -Current "$([math]::Round($mavenSize, 2))MB" -Expected '>0 (or OK if absent)'
            Add-Check -Checks $checks -Name 'GradleCacheDetected' -Passed ($gradleSize -gt 0) -Current "$([math]::Round($gradleSize, 2))MB" -Expected '>0 (or OK if absent)'

            $report.Summary.Status = 'Completed'
            $report.Summary.DeterministicPass = @($checks | Where-Object { -not $_.Passed }).Count -eq 0
            $report.Summary.BestNextDecision = 'All package manager audits complete. Proceed to S120 (apply all redirects).'
            $report.Metrics = @{
                NugetCacheMB = [math]::Round($nugetSize, 2)
                MavenCacheMB = [math]::Round($mavenSize, 2)
                GradleCacheMB = [math]::Round($gradleSize, 2)
                TotalBuildToolsMB = [math]::Round($nugetSize + $mavenSize + $gradleSize, 2)
            }
            [void]$actions.Add(("NuGet: {0:F2}MB, Maven: {1:F2}MB, Gradle: {2:F2}MB" -f $nugetSize, $mavenSize, $gradleSize))
        }

        'S120' {
            Write-Progress2 'Applying package manager cache redirects and environment configuration...'
            Add-Check -Checks $checks -Name 'AdminRequired' -Passed ([bool]$report.Admin) -Current ([string]$report.Admin) -Expected 'True'
            Add-Check -Checks $checks -Name 'DataRootExists' -Passed (Test-Path -LiteralPath $DataRoot) -Current $(if (Test-Path -LiteralPath $DataRoot) { 'Exists' } else { 'Missing' }) -Expected 'Exists'

            $pkgCacheRoot = Join-Path $DataRoot 'PkgCache'
            Ensure-Dir -Path $pkgCacheRoot

            $envConfigs = @{
                npm = @{ EnvVar = 'npm_config_cache'; NewPath = (Join-Path $pkgCacheRoot 'npm'); Profile = 'User' }
                yarn = @{ EnvVar = 'YARN_CACHE_FOLDER'; NewPath = (Join-Path $pkgCacheRoot 'yarn'); Profile = 'User' }
                pip = @{ EnvVar = 'PIP_CACHE_DIR'; NewPath = (Join-Path $pkgCacheRoot 'pip'); Profile = 'User' }
            }

            if ($Apply) {
                try {
                    foreach ($pkg in $envConfigs.Keys) {
                        $config = $envConfigs[$pkg]
                        Ensure-Dir -Path $config.NewPath
                        
                        [Environment]::SetEnvironmentVariable($config.EnvVar, $config.NewPath, $config.Profile)
                        [void]$actions.Add(("Set $($config.EnvVar) = $($config.NewPath)"))
                    }

                    # Create .npmrc file for npm redirect
                    $npmrcPath = Join-Path $env:USERPROFILE '.npmrc'
                    if (-not (Test-Path $npmrcPath)) {
                        "cache=$(Join-Path $pkgCacheRoot 'npm')" | Set-Content -Path $npmrcPath -Encoding UTF8
                        [void]$actions.Add(("Created .npmrc with cache redirect"))
                    }
                }
                catch {
                    throw ("Package manager redirect failed: {0}" -f $_.Exception.Message)
                }
            }

            # Validation
            foreach ($pkg in $envConfigs.Keys) {
                $config = $envConfigs[$pkg]
                $envValue = [Environment]::GetEnvironmentVariable($config.EnvVar, $config.Profile)
                Add-Check -Checks $checks -Name ("$pkg`EnvSet") -Passed ($envValue -eq $config.NewPath) -Current ([string]$envValue) -Expected $config.NewPath
            }

            $allPass = @($checks | Where-Object { -not $_.Passed }).Count -eq 0
            $report.Summary.Status = if ($allPass) { 'Completed' } else { 'BlockedOrPartial' }
            $report.Summary.DeterministicPass = $allPass
            $report.Summary.BestNextDecision = if ($allPass) { 'Wave 4 complete. All package manager caches redirected to DataHub. Verify with: npm config get cache, yarn config get cacheFolder, etc.' } else { 'Some redirects failed; verify environment permissions and registry access.' }
            $report.Applied = [bool]$Apply -and $allPass
        }
    }

    $report.Applied = [bool]$Apply -and ($report.Summary.Status -eq 'Completed')
}
catch {
    $report.Error = $_.Exception.Message
    if ($report.Summary.Status -eq 'NotStarted') {
        $report.Summary.Status = 'Failed'
    }
    if ([string]::IsNullOrWhiteSpace([string]$report.Summary.BestNextDecision)) {
        $report.Summary.BestNextDecision = 'Resolve error and re-run the same step in audit mode first.'
    }
}
finally {
    $report.Checks = @($checks)
    $report.Actions = @($actions)
    $report.RollbackHints = @($rollback)

    $json = $report | ConvertTo-Json -Depth 12 -Compress:$false
    [System.IO.File]::WriteAllText($OutputJson, $json, [System.Text.Encoding]::UTF8)
    Write-Progress2 ("Step {0} report saved to {1}" -f $StepId, $OutputJson)
}
