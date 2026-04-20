[CmdletBinding()]
param(
    [ValidateSet('MonthlyEnterprise','Current','SemiAnnualEnterprise')]
    [string]$PreferredChannel = 'MonthlyEnterprise',

    [switch]$Apply,
    [switch]$RestoreLatest,
    [string]$BackupDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'logs\diagnostics')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$policyPaths = @(
    'HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate',
    'HKCU:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate'
)
$clickToRunPath = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
$managedPolicyValues = @('UpdateBranch', 'UpdateChannel', 'CDNBaseUrl', 'AudienceId')
$allowedChannels = @('Current', 'MonthlyEnterprise', 'SemiAnnualEnterprise')
$channelLabels = [ordered]@{
    Current              = 'Current Channel'
    MonthlyEnterprise    = 'Monthly Enterprise Channel'
    SemiAnnualEnterprise = 'Semi-Annual Enterprise Channel'
}

function Get-RegistryValueMap {
    param(
        [string]$Path,
        [string[]]$Names
    )

    $state = [ordered]@{
        Path   = $Path
        Exists = Test-Path -LiteralPath $Path
        Values = [ordered]@{}
    }

    if (-not $state.Exists) {
        return $state
    }

    $props = Get-ItemProperty -LiteralPath $Path -ErrorAction Stop
    foreach ($name in $Names) {
        if ($props.PSObject.Properties.Name -contains $name) {
            $state.Values[$name] = [string]$props.$name
        }
    }

    return $state
}

function Set-RegistryValueMap {
    param(
        [string]$Path,
        [hashtable]$Values,
        [string[]]$ManagedNames
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }

    foreach ($name in $ManagedNames) {
        if ($Values.Contains($name) -and -not [string]::IsNullOrWhiteSpace([string]$Values[$name])) {
            Set-ItemProperty -LiteralPath $Path -Name $name -Value ([string]$Values[$name]) -Force
        } elseif (Test-Path -LiteralPath $Path) {
            Remove-ItemProperty -LiteralPath $Path -Name $name -ErrorAction SilentlyContinue
        }
    }
}

function Get-ClickToRunState {
    $result = [ordered]@{
        Exists            = $false
        ProductReleaseIds = ''
        UpdateChannel     = ''
        CDNBaseUrl        = ''
        AudienceId        = ''
        VersionToReport   = ''
        Platform          = ''
        ClientCulture     = ''
    }

    if (-not (Test-Path -LiteralPath $clickToRunPath)) {
        return $result
    }

    $props = Get-ItemProperty -LiteralPath $clickToRunPath -ErrorAction Stop
    $result.Exists = $true
    foreach ($name in @('ProductReleaseIds', 'UpdateChannel', 'CDNBaseUrl', 'AudienceId', 'VersionToReport', 'Platform', 'ClientCulture')) {
        if ($props.PSObject.Properties.Name -contains $name) {
            $result[$name] = [string]$props.$name
        }
    }

    return $result
}

function Test-M365ChannelMismatch {
    param(
        [object[]]$PolicyStates,
        [hashtable]$ClickToRunState
    )

    foreach ($policy in $PolicyStates) {
        $branch = [string]$policy.Values['UpdateBranch']
        $channel = [string]$policy.Values['UpdateChannel']
        $cdn = [string]$policy.Values['CDNBaseUrl']

        if ($branch -match 'Perpetual|LTSC') {
            return $true
        }

        if (-not [string]::IsNullOrWhiteSpace($branch) -and ($branch -notin $allowedChannels)) {
            return $true
        }

        if ($channel -match 'Perpetual|LTSC') {
            return $true
        }

        if ($cdn -match 'Perpetual|LTSC') {
            return $true
        }
    }

    if ($ClickToRunState.Exists) {
        if ($ClickToRunState.ProductReleaseIds -match 'Perpetual|LTSC|2021Volume|2024Volume') {
            return $true
        }

        if ($ClickToRunState.UpdateChannel -match 'Perpetual|LTSC') {
            return $true
        }

        if ($ClickToRunState.CDNBaseUrl -match 'Perpetual|LTSC') {
            return $true
        }
    }

    return $false
}

function Get-Assessment {
    $policyStates = @($policyPaths | ForEach-Object { Get-RegistryValueMap -Path $_ -Names $managedPolicyValues })
    $clickToRunState = Get-ClickToRunState
    $mismatch = Test-M365ChannelMismatch -PolicyStates $policyStates -ClickToRunState $clickToRunState
    $configuredBranches = @($policyStates | ForEach-Object { [string]$_.Values['UpdateBranch'] } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    return [ordered]@{
        Timestamp          = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
        TargetLicense      = 'Microsoft365Apps'
        RecommendedChannel = $PreferredChannel
        AllowedChannels    = @($allowedChannels | ForEach-Object {
            [ordered]@{ Key = $_; Label = $channelLabels[$_] }
        })
        PolicyStates       = $policyStates
        ClickToRun         = $clickToRunState
        ConfiguredBranches = @($configuredBranches)
        Status             = if ($mismatch) { 'Mismatch' } elseif ($configuredBranches.Count -gt 0 -or $clickToRunState.Exists) { 'Ready' } else { 'Unconfigured' }
        Message            = if ($mismatch) {
            'Detected a perpetual/LTSC Office update channel setting that is incompatible with Microsoft 365 Apps licensing.'
        } elseif ($configuredBranches.Count -gt 0 -or $clickToRunState.Exists) {
            'Office channel settings are compatible with Microsoft 365 Apps licensing.'
        } else {
            'No Click-to-Run Office configuration is installed yet. Pre-staging a Microsoft 365 Apps channel is safe.'
        }
    }
}

function Save-Backup {
    param([hashtable]$Assessment)

    if (-not (Test-Path -LiteralPath $BackupDirectory)) {
        New-Item -Path $BackupDirectory -ItemType Directory -Force | Out-Null
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $timestampedPath = Join-Path $BackupDirectory ("office-channel-backup-{0}.json" -f $stamp)
    $latestPath = Join-Path $BackupDirectory 'office-channel-backup-latest.json'
    $json = $Assessment | ConvertTo-Json -Depth 8 -Compress:$false
    [System.IO.File]::WriteAllText($timestampedPath, $json, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText($latestPath, $json, [System.Text.Encoding]::UTF8)

    return [ordered]@{
        Timestamped = $timestampedPath
        Latest      = $latestPath
    }
}

function Restore-FromLatestBackup {
    $latestPath = Join-Path $BackupDirectory 'office-channel-backup-latest.json'
    if (-not (Test-Path -LiteralPath $latestPath)) {
        throw "Backup file not found: $latestPath"
    }

    $backup = Get-Content -LiteralPath $latestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    foreach ($policy in @($backup.PolicyStates)) {
        $values = @{}
        foreach ($name in $managedPolicyValues) {
            if ($policy.Values.PSObject.Properties.Name -contains $name) {
                $values[$name] = [string]$policy.Values.$name
            }
        }
        Set-RegistryValueMap -Path ([string]$policy.Path) -Values $values -ManagedNames $managedPolicyValues
    }

    return [ordered]@{
        Action     = 'RestoreLatest'
        BackupPath = $latestPath
        Status     = 'Restored'
        Message    = 'Office update channel policy restored from latest backup.'
        Assessment = Get-Assessment
    }
}

if ($Apply -and $RestoreLatest) {
    throw 'Use either -Apply or -RestoreLatest, not both.'
}

if ($RestoreLatest) {
    $restoreResult = Restore-FromLatestBackup
    $restoreResult | ConvertTo-Json -Depth 8 -Compress:$false
    return
}

$preAssessment = Get-Assessment

if (-not $Apply) {
    $preAssessment | ConvertTo-Json -Depth 8 -Compress:$false
    return
}

$backupInfo = Save-Backup -Assessment $preAssessment
$desiredValues = @{ UpdateBranch = $PreferredChannel }

foreach ($path in $policyPaths) {
    Set-RegistryValueMap -Path $path -Values $desiredValues -ManagedNames $managedPolicyValues
}

$postAssessment = Get-Assessment

[ordered]@{
    Action           = 'Apply'
    PreferredChannel = $PreferredChannel
    AllowedChannels  = @($allowedChannels)
    BackupPaths      = $backupInfo
    PreAssessment    = $preAssessment
    PostAssessment   = $postAssessment
    Status           = if ($postAssessment.Status -eq 'Mismatch') { 'Warning' } else { 'Applied' }
    Message          = if ($postAssessment.Status -eq 'Mismatch') {
        'Policy was updated, but additional perpetual Office settings still appear to be present. Review the assessment output.'
    } else {
        'Office update channel policy aligned for Microsoft 365 Apps.'
    }
} | ConvertTo-Json -Depth 10 -Compress:$false