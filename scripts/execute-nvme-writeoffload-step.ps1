<#
.SYNOPSIS
    Execute deterministic NVMe write-offload steps (audit/apply) with validation.

.DESCRIPTION
    Runs one operational step at a time and writes a structured JSON report with
    checks, actions, rollback hints, and outcome.

.PARAMETER StepId
    Step selector: S00, S10, S20, S30

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
    [Parameter(Mandatory)][ValidateSet('S00','S10','S20','S30')][string]$StepId,
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
