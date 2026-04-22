<#
.SYNOPSIS
    Deterministic audit/remediation for legacy recovery partition cleanup.

.DESCRIPTION
    Audits a candidate recovery partition (default partition 4 on disk 1) and
    deterministically classifies it as:
      - LegacyUnusedWinREStore
      - NotLegacyOrNotDeterministic

    When -ApplyIfLegacy is supplied, the script removes the candidate partition
    and extends the target OS partition only if all deterministic checks pass.

.PARAMETER OutputJson
    Output path for the JSON report.

.PARAMETER DiskNumber
    Disk hosting OS and candidate recovery partition.

.PARAMETER CandidatePartitionNumber
    Recovery partition to evaluate (default 4).

.PARAMETER TargetPartitionNumber
    Main OS partition to extend (default 3).

.PARAMETER ApplyIfLegacy
    Apply cleanup only when deterministic legacy classification is true.
#>
param(
    [Parameter(Mandatory)][string]$OutputJson,
    [int]$DiskNumber = 1,
    [int]$CandidatePartitionNumber = 4,
    [int]$TargetPartitionNumber = 3,
    [switch]$ApplyIfLegacy
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Progress2 {
    param([string]$Message)
    Write-Host "[PARTITION-LEGACY] $Message"
}

function New-Result {
    return [ordered]@{
        AuditVersion = '1.0.0'
        Timestamp = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
        Parameters = [ordered]@{
            DiskNumber = $DiskNumber
            CandidatePartitionNumber = $CandidatePartitionNumber
            TargetPartitionNumber = $TargetPartitionNumber
            ApplyIfLegacy = [bool]$ApplyIfLegacy
        }
        Assessment = [ordered]@{
            DeterministicLegacy = $false
            Classification = 'NotLegacyOrNotDeterministic'
            BestNextDecision = ''
            TechnicalRationale = @()
            Evidence = @()
            CandidatePartition = $null
            TargetPartition = $null
            ActiveWinRE = $null
            BootPartition = $null
        }
        Remediation = [ordered]@{
            Attempted = [bool]$ApplyIfLegacy
            Applied = $false
            Actions = @()
            Rollback = 'Restore from full-disk backup/image if partition operations fail.'
            Error = $null
        }
    }
}

function Convert-ReagentInfo {
    $raw = (reagentc /info 2>&1 | Out-String)
    $enabled = ($raw -match 'Enabled|Abilitato')
    $partitionNumber = $null
    $diskNumber = $null

    $rx = [regex]'harddisk(?<disk>\d+)\\partition(?<part>\d+)'
    $m = $rx.Match($raw)
    if ($m.Success) {
        $diskNumber = [int]$m.Groups['disk'].Value
        $partitionNumber = [int]$m.Groups['part'].Value
    }

    return [ordered]@{
        Enabled = $enabled
        DiskNumber = $diskNumber
        PartitionNumber = $partitionNumber
        Raw = $raw.Trim()
    }
}

function Get-BootPartitionFromWmi {
    $boot = Get-CimInstance Win32_BootConfiguration -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $boot) { return $null }

    $caption = [string]$boot.Caption
    $disk = $null
    $part = $null

    $m = [regex]::Match($caption, 'Harddisk(?<disk>\d+)\\Partition(?<part>\d+)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
        $disk = [int]$m.Groups['disk'].Value
        $part = [int]$m.Groups['part'].Value
    }

    return [ordered]@{
        Caption = $caption
        DiskNumber = $disk
        PartitionNumber = $part
    }
}

function Get-VolumePathForPartition {
    param(
        [int]$Disk,
        [int]$Partition
    )

    $p = Get-Partition -DiskNumber $Disk -PartitionNumber $Partition -ErrorAction Stop
    $v = $p | Get-Volume -ErrorAction Stop

    return [ordered]@{
        Partition = $p
        Volume = $v
        VolumePath = [string]$v.Path
        Label = [string]$v.FileSystemLabel
    }
}

function Get-PathChildrenNames {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop | ForEach-Object { $_.Name })
}

function Test-IsAdministrator {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Add-Evidence {
    param(
        [System.Collections.ArrayList]$EvidenceList,
        [string]$Name,
        [bool]$Passed,
        [string]$Detail
    )

    [void]$EvidenceList.Add([pscustomobject]@{
        Name = $Name
        Passed = $Passed
        Detail = $Detail
    })
}

$result = New-Result
$evidence = [System.Collections.ArrayList]::new()

try {
    Write-Progress2 'Collecting partition data...'

    $candidate = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $CandidatePartitionNumber -ErrorAction Stop
    $target = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $TargetPartitionNumber -ErrorAction Stop

    $result.Assessment.CandidatePartition = [ordered]@{
        DiskNumber = $candidate.DiskNumber
        PartitionNumber = $candidate.PartitionNumber
        DriveLetter = [string]$candidate.DriveLetter
        GptType = [string]$candidate.GptType
        Type = [string]$candidate.Type
        Size = [int64]$candidate.Size
        Offset = [int64]$candidate.Offset
    }

    $result.Assessment.TargetPartition = [ordered]@{
        DiskNumber = $target.DiskNumber
        PartitionNumber = $target.PartitionNumber
        DriveLetter = [string]$target.DriveLetter
        GptType = [string]$target.GptType
        Type = [string]$target.Type
        Size = [int64]$target.Size
        Offset = [int64]$target.Offset
    }

    $winre = Convert-ReagentInfo
    $result.Assessment.ActiveWinRE = $winre

    $bootInfo = Get-BootPartitionFromWmi
    $result.Assessment.BootPartition = $bootInfo

    $candidateV = Get-VolumePathForPartition -Disk $DiskNumber -Partition $CandidatePartitionNumber
    $activeV = $null
    if ($null -ne $winre.DiskNumber -and $null -ne $winre.PartitionNumber) {
        $activeV = Get-VolumePathForPartition -Disk $winre.DiskNumber -Partition $winre.PartitionNumber
    }

    $isRecoveryType = ([string]$candidate.GptType -eq '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}')
    Add-Evidence -EvidenceList $evidence -Name 'CandidateIsRecoveryPartition' -Passed $isRecoveryType -Detail ("GPT={0}" -f [string]$candidate.GptType)

    $winreEnabled = [bool]$winre.Enabled
    Add-Evidence -EvidenceList $evidence -Name 'WinREEnabled' -Passed $winreEnabled -Detail ("Disk={0} Partition={1}" -f $winre.DiskNumber, $winre.PartitionNumber)

    $activeWinreDifferent = ($winre.DiskNumber -ne $DiskNumber -or $winre.PartitionNumber -ne $CandidatePartitionNumber)
    Add-Evidence -EvidenceList $evidence -Name 'CandidateNotCurrentWinRE' -Passed $activeWinreDifferent -Detail ("CurrentWinRE=Disk{0}/Part{1}" -f $winre.DiskNumber, $winre.PartitionNumber)

    $bootIsNotCandidate = $true
    if ($bootInfo) {
        $bootIsNotCandidate = -not ($bootInfo.DiskNumber -eq $DiskNumber -and $bootInfo.PartitionNumber -eq $CandidatePartitionNumber)
    }
    Add-Evidence -EvidenceList $evidence -Name 'CandidateNotBootPartition' -Passed $bootIsNotCandidate -Detail ("Boot={0}" -f $(if ($bootInfo) { "Disk$($bootInfo.DiskNumber)/Part$($bootInfo.PartitionNumber)" } else { 'Unknown' }))

    $candidateRootChildren = Get-PathChildrenNames -Path $candidateV.VolumePath
    $allowedRoot = @('Recovery', 'System Volume Information')
    $candidateRootOnlyAllowed = @($candidateRootChildren | Where-Object { $allowedRoot -notcontains $_ }).Count -eq 0
    Add-Evidence -EvidenceList $evidence -Name 'CandidateRootContainsOnlyRecoveryArtifacts' -Passed $candidateRootOnlyAllowed -Detail ("RootChildren={0}" -f ($candidateRootChildren -join ', '))

    $candidateWinreDir = Join-Path $candidateV.VolumePath 'Recovery\WindowsRE'
    $candidateWinreWim = Join-Path $candidateWinreDir 'winre.wim'
    $candidateHasWinreWim = Test-Path -LiteralPath $candidateWinreWim
    Add-Evidence -EvidenceList $evidence -Name 'CandidateHasWinreWim' -Passed $candidateHasWinreWim -Detail $candidateWinreWim

    $activeWinreWimExists = $false
    if ($activeV) {
        $activeWinreWim = Join-Path $activeV.VolumePath 'Recovery\WindowsRE\winre.wim'
        $activeWinreWimExists = Test-Path -LiteralPath $activeWinreWim
        Add-Evidence -EvidenceList $evidence -Name 'ActiveWinreWimExists' -Passed $activeWinreWimExists -Detail $activeWinreWim
    } else {
        Add-Evidence -EvidenceList $evidence -Name 'ActiveWinreWimExists' -Passed $false -Detail 'Unable to resolve active WinRE volume path.'
    }

    $contiguousToTarget = (($target.Offset + $target.Size) -eq $candidate.Offset)
    Add-Evidence -EvidenceList $evidence -Name 'CandidateAdjacentToTarget' -Passed $contiguousToTarget -Detail ("TargetEnd={0}; CandidateOffset={1}" -f ($target.Offset + $target.Size), $candidate.Offset)

    $deterministicLegacy = @($evidence | Where-Object { -not $_.Passed }).Count -eq 0

    $result.Assessment.DeterministicLegacy = $deterministicLegacy
    if ($deterministicLegacy) {
        $result.Assessment.Classification = 'LegacyUnusedWinREStore'
        $result.Assessment.BestNextDecision = 'Candidate recovery partition is deterministically unused by current WinRE/boot and can be reclaimed.'
        $result.Assessment.TechnicalRationale = @(
            'WinRE currently points to a different partition than the candidate.',
            'Candidate is recovery-typed, contains only recovery artifacts, and is not boot partition.',
            'Candidate is adjacent to target OS partition, so deterministic extend path exists.'
        )
    } else {
        $result.Assessment.Classification = 'NotLegacyOrNotDeterministic'
        $result.Assessment.BestNextDecision = 'Do not remove candidate partition automatically; at least one deterministic safety check failed.'
        $result.Assessment.TechnicalRationale = @(
            'One or more required deterministic checks failed.',
            'Automatic cleanup is blocked to avoid regression or data-loss risk.'
        )
    }

    $result.Assessment.Evidence = @($evidence)

    if ($ApplyIfLegacy) {
        if (-not $deterministicLegacy) {
            throw 'ApplyIfLegacy requested but deterministic legacy criteria are not satisfied.'
        }
        if (-not (Test-IsAdministrator)) {
            throw 'ApplyIfLegacy requires elevated Administrator privileges.'
        }

        Write-Progress2 'Deterministic legacy confirmed. Applying cleanup...'

        Remove-Partition -DiskNumber $DiskNumber -PartitionNumber $CandidatePartitionNumber -Confirm:$false -ErrorAction Stop
        $result.Remediation.Actions += ("Removed partition Disk{0}/Part{1}" -f $DiskNumber, $CandidatePartitionNumber)

        $supported = Get-PartitionSupportedSize -DiskNumber $DiskNumber -PartitionNumber $TargetPartitionNumber -ErrorAction Stop
        $requestedSize = [int64]($target.Size + $candidate.Size)
        $newSize = if ($requestedSize -gt $supported.SizeMax) { [int64]$supported.SizeMax } else { $requestedSize }

        if ($newSize -le $target.Size) {
            throw ("Partition removed but extension is not available. Current={0} Requested={1} SizeMax={2}" -f $target.Size, $requestedSize, $supported.SizeMax)
        }

        Resize-Partition -DiskNumber $DiskNumber -PartitionNumber $TargetPartitionNumber -Size $newSize -ErrorAction Stop
        $result.Remediation.Actions += ("Extended partition Disk{0}/Part{1} to {2} bytes" -f $DiskNumber, $TargetPartitionNumber, $newSize)

        $result.Remediation.Applied = $true
        Write-Progress2 'Cleanup applied successfully.'
    }
}
catch {
    $result.Remediation.Error = $_.Exception.Message
    if ($result.Remediation.Attempted -and -not $result.Remediation.Applied) {
        Write-Progress2 ("Apply failed: {0}" -f $_.Exception.Message)
    } else {
        Write-Progress2 ("Audit warning: {0}" -f $_.Exception.Message)
    }
}
finally {
    $json = $result | ConvertTo-Json -Depth 12 -Compress:$false
    [System.IO.File]::WriteAllText($OutputJson, $json, [System.Text.Encoding]::UTF8)
    Write-Progress2 ("Report saved to {0}" -f $OutputJson)
}
