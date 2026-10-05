# Live apply requires elevation; dry-run parity gate runs without admin.
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$EvaluationJson,
    [Parameter(Mandatory)][string]$OutputJson,
    [ValidateSet('TuneExclusions','TemporaryRealtimeOff','ExtremeServiceDisable')]
    [string]$Tier,
    [ValidateSet('DevBuild','EmergencyPerf','ForensicCapture','VendorSupport')]
    [string]$ReasonCode = 'DevBuild',
    [string[]]$ExclusionPaths = @(),
    [int]$AutoReenableMinutes = 0,
    [string]$RollbackJson = '',
    [switch]$DryRun,
    [switch]$IUnderstandRisk,
    [switch]$ConfirmExtremeDisable
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-HubCrashSafeJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Json
    )

    $dir = Split-Path -Parent $Path
    if ([string]::IsNullOrWhiteSpace($dir)) {
        throw "Rollback path has no directory: $Path"
    }
    if (Test-Path -LiteralPath $dir -PathType Leaf) {
        throw "Rollback directory is not a folder: $dir. No Defender mutation was performed."
    }
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $encoding = New-Object System.Text.UTF8Encoding $true
    $bytes = $encoding.GetBytes($Json)
    $stream = New-Object System.IO.FileStream(
        $Path,
        [System.IO.FileMode]::Create,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::Read)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
    }
}

function Assert-HubRollbackReadable {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedTier,
        [int]$ExpectedExclusions = 0,
        [int]$ExpectedServiceStates = 0
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Rollback not found: $Path. No Defender mutation was performed."
    }

    $parsed = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json
    if ([string]$parsed.SchemaVersion -ne 'DefenderExtremeRollback.v1') {
        throw "Rollback schema invalid: $Path. No Defender mutation was performed."
    }
    if ([string]$parsed.Tier -ne $ExpectedTier) {
        throw "Rollback tier mismatch: $Path. No Defender mutation was performed."
    }
    if ($ExpectedTier -eq 'TuneExclusions' -and @($parsed.ExclusionPathsAdded).Count -lt $ExpectedExclusions) {
        throw "Rollback is missing exclusion paths: $Path. No Defender mutation was performed."
    }
    if ($ExpectedTier -eq 'ExtremeServiceDisable' -and @($parsed.ServiceStates).Count -lt $ExpectedServiceStates) {
        throw "Rollback is missing WinDefend pre-state: $Path. No Defender mutation was performed."
    }
}

function ConvertTo-DefenderExclusionKey {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $value = $Path.Trim().Replace('/', '\')
    while ($value.Length -gt 3 -and $value.EndsWith('\')) {
        $value = $value.Substring(0, $value.Length - 1)
    }
    return $value.ToLowerInvariant()
}

function Test-DefenderExclusionPresent {
    param([string]$Requested, [string[]]$Actual)
    $key = ConvertTo-DefenderExclusionKey -Path $Requested
    if ([string]::IsNullOrWhiteSpace($key)) { return $false }
    foreach ($item in @($Actual)) {
        if ((ConvertTo-DefenderExclusionKey -Path ([string]$item)) -eq $key) { return $true }
    }
    return $false
}

function Read-HubDefenderExclusionState {
    $sim = [string]$env:HUB_DEFENDER_EXCLUSION_READBACK
    if (-not [string]::IsNullOrWhiteSpace($sim)) {
        $doc = Get-Content -LiteralPath $sim -Raw | ConvertFrom-Json
        $index = 0
        if ($script:ExclusionReadIndex) { $index = [int]$script:ExclusionReadIndex }
        $reads = @($doc.reads)
        if ($index -ge $reads.Count) {
            return @{ Ok = $false; Paths = @() }
        }
        $item = $reads[$index]
        $script:ExclusionReadIndex = $index + 1
        if (-not [bool]$item.ok) { return @{ Ok = $false; Paths = @() } }
        return @{ Ok = $true; Paths = @($item.paths) }
    }

    # Sink-only tests have no live exclusion read. Treat that seam as a known empty
    # pre-state so rollback can name the exact paths. A failed read must not land here.
    if (-not [string]::IsNullOrWhiteSpace([string]$env:HUB_DEFENDER_MUTATION_SINK)) {
        return @{ Ok = $true; Paths = @() }
    }

    try {
        $pref = Get-MpPreference -ErrorAction Stop
        $paths = @()
        if ($null -ne $pref.ExclusionPath) { $paths = @($pref.ExclusionPath) }
        return @{ Ok = $true; Paths = $paths }
    } catch {
        return @{ Ok = $false; Paths = @() }
    }
}

$script:RollbackVerified = $false
$script:ExclusionReadIndex = 0

function Invoke-GuardedDefenderMutation {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action
    )

    if (-not $script:RollbackVerified) {
        throw "Refusing Defender mutation '$Name' before a verified rollback."
    }

    $sink = [string]$env:HUB_DEFENDER_MUTATION_SINK
    if (-not [string]::IsNullOrWhiteSpace($sink)) {
        $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Add-Content -LiteralPath $sink -Encoding utf8 -Value ("{0}`t{1}" -f $stamp, $Name)
        return
    }

    & $Action
}

$intercept = -not [string]::IsNullOrWhiteSpace([string]$env:HUB_DEFENDER_MUTATION_SINK)
$simulateExclusions = -not [string]::IsNullOrWhiteSpace([string]$env:HUB_DEFENDER_EXCLUSION_READBACK)
if (-not $DryRun -and -not $intercept -and -not $simulateExclusions) {
    $scriptDirEarly = Split-Path -Parent $MyInvocation.MyCommand.Path
    . (Join-Path $scriptDirEarly 'hub-common.ps1')
    if (-not (Test-HubAdmin)) {
        throw 'Administrator elevation required for live Defender apply (dry-run does not require admin).'
    }
}

if (-not $IUnderstandRisk) {
    throw 'HITL gate: pass -IUnderstandRisk after reading evaluation blockers and prerequisites.'
}
if ($Tier -eq 'ExtremeServiceDisable' -and -not $ConfirmExtremeDisable) {
    throw 'ExtremeServiceDisable requires -ConfirmExtremeDisable (second explicit gate).'
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$hubRoot = Split-Path -Parent $scriptDir
. (Join-Path $scriptDir 'lib\hub-decision-log.ps1')
$logsDir = Join-Path $hubRoot 'logs'
if (-not (Test-Path -LiteralPath $logsDir)) { New-Item -Path $logsDir -ItemType Directory -Force | Out-Null }

if (-not $RollbackJson) {
    $RollbackJson = Join-Path $logsDir ('defender-extreme-rollback-{0}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}

if (-not (Test-Path -LiteralPath $EvaluationJson)) { throw "Evaluation JSON not found: $EvaluationJson" }
$eval = Get-Content -LiteralPath $EvaluationJson -Raw | ConvertFrom-Json
if ([string]$eval.RecommendedTier -ne $Tier) {
    throw ("Tier mismatch: evaluation recommends '{0}' but you requested '{1}'." -f $eval.RecommendedTier, $Tier)
}
if (-not [bool]$eval.AllowedToProceed) {
    throw ("Evaluation blocked proceed. Blockers: {0}" -f (@($eval.Blockers) -join '; '))
}

$corePath = Join-Path $scriptDir 'lib\process-pressure-core.ps1'
. $corePath
$before = Get-DefenderPlatformStatus

$plannedPaths = @()
$requestedPaths = @()
$preStateUnavailable = $false
$serviceStates = @()
$restoreScript = Join-Path $scriptDir 'restore-defender-from-rollback.ps1'
$taskName = $null

switch ($Tier) {
    'TuneExclusions' {
        $requestedPaths = @($ExclusionPaths | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($requestedPaths.Count -lt 1) {
            throw 'TuneExclusions requires -ExclusionPaths for at least one trusted folder.'
        }
        foreach ($path in $requestedPaths) {
            if (-not (Test-Path -LiteralPath $path)) {
                Write-Warning "Path not found (still recording): $path"
            }
        }
        $beforeExclusions = Read-HubDefenderExclusionState
        if (-not $beforeExclusions.Ok) {
            $preStateUnavailable = $true
        } else {
            $plannedPaths = @($requestedPaths | Where-Object { -not (Test-DefenderExclusionPresent -Requested $_ -Actual @($beforeExclusions.Paths)) })
        }
    }
    'TemporaryRealtimeOff' {
        $maxMin = 60
        if ($AutoReenableMinutes -lt 1) { $AutoReenableMinutes = 30 }
        if ($AutoReenableMinutes -gt $maxMin) {
            throw "TemporaryRealtimeOff max duration is $maxMin minutes."
        }
    }
    'ExtremeServiceDisable' {
        $maxMin = 120
        if ($AutoReenableMinutes -lt 1) { $AutoReenableMinutes = 60 }
        if ($AutoReenableMinutes -gt $maxMin) {
            throw "ExtremeServiceDisable max duration is $maxMin minutes."
        }
        $svc = Get-Service -Name WinDefend -ErrorAction SilentlyContinue
        if (-not $svc) {
            throw 'Rollback preparation failed: WinDefend pre-state could not be read. No Defender mutation was performed.'
        }
        $serviceStates = @([ordered]@{
            Name = 'WinDefend'
            StartType = [string]$svc.StartType
            Status = [string]$svc.Status
        })
    }
}

if ($AutoReenableMinutes -gt 0 -and -not $DryRun -and -not $intercept -and -not $simulateExclusions) {
    if (-not (Test-Path -LiteralPath $restoreScript)) {
        throw "Restore script missing: $restoreScript. No Defender mutation was performed."
    }
    $taskName = 'HubDefenderReenable-{0}' -f (Get-Date -Format 'yyyyMMddHHmmss')
}

$applied = New-Object System.Collections.Generic.List[object]
$mutationFailed = $false
$mutationError = ''
$outcome = 'PreStateUnavailable'
$success = $false
$message = 'The current Defender exclusion state could not be read, so no exclusion was changed.'
$reportedRollback = ''

if (-not $preStateUnavailable) {
$rollback = [ordered]@{
    SchemaVersion = 'DefenderExtremeRollback.v1'
    GeneratedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    ReasonCode = $ReasonCode
    Tier = $Tier
    DryRun = [bool]$DryRun
    Before = $before
    ExclusionPathsAdded = @($plannedPaths)
    ServiceStates = @($serviceStates)
    ScheduledReenableMinutes = $AutoReenableMinutes
    ScheduledTaskName = $taskName
}

$json = $rollback | ConvertTo-Json -Depth 10
Write-HubCrashSafeJson -Path $RollbackJson -Json $json
if ($env:HUB_DEFENDER_ROLLBACK_CORRUPT -eq '1') {
    [System.IO.File]::WriteAllText($RollbackJson, 'NOT-JSON')
}
Assert-HubRollbackReadable -Path $RollbackJson -ExpectedTier $Tier `
    -ExpectedExclusions $plannedPaths.Count -ExpectedServiceStates $serviceStates.Count
$script:RollbackVerified = $true

function Add-Applied {
    param([string]$Action, [string]$Detail, [bool]$DidApply)
    [void]$applied.Add([ordered]@{ Action = $Action; Detail = $Detail; Applied = $DidApply })
}

switch ($Tier) {
    'TuneExclusions' {
        foreach ($path in @($requestedPaths)) {
            $alreadyPresent = -not @($plannedPaths | Where-Object { $_ -eq $path })
            if (-not $DryRun -and -not $alreadyPresent) {
                try {
                    if ($env:HUB_DEFENDER_MUTATION_FAIL -eq '1') {
                        throw 'Add-MpPreference failed'
                    }
                    if (-not $simulateExclusions -or $intercept) {
                        Invoke-GuardedDefenderMutation -Name 'Add-MpPreference' -Action {
                            Add-MpPreference -ExclusionPath $path -ErrorAction Stop
                        }.GetNewClosure()
                    }
                } catch {
                    $mutationFailed = $true
                    $mutationError = $_.Exception.Message
                    Add-Applied -Action 'Add-MpPreference ExclusionPath' -Detail $path -DidApply $false
                    break
                }
            }
            $detail = if ($alreadyPresent) { "already present: $path" } else { $path }
            Add-Applied -Action 'Add-MpPreference ExclusionPath' -Detail $detail -DidApply ((-not $DryRun) -and (-not $alreadyPresent) -and (-not $intercept))
        }
        Add-Applied -Action 'Guidance' -Detail 'Schedule full scan outside work hours via Windows Security or Set-MpPreference scan schedule.' -DidApply $false
    }
    'TemporaryRealtimeOff' {
        if (-not $DryRun) {
            Invoke-GuardedDefenderMutation -Name 'Set-MpPreference' -Action {
                Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction Stop
            }
        }
        Add-Applied -Action 'Set-MpPreference -DisableRealtimeMonitoring' -Detail 'true' -DidApply ((-not $DryRun) -and (-not $intercept))
    }
    'ExtremeServiceDisable' {
        if (-not $DryRun) {
            Invoke-GuardedDefenderMutation -Name 'Stop-Service' -Action {
                Stop-Service -Name WinDefend -Force -ErrorAction Stop
            }
            Invoke-GuardedDefenderMutation -Name 'Set-Service' -Action {
                Set-Service -Name WinDefend -StartupType Manual -ErrorAction Stop
            }
        }
        Add-Applied -Action 'Stop-Service WinDefend + Manual start' -Detail "Re-enable within $AutoReenableMinutes min" -DidApply ((-not $DryRun) -and (-not $intercept))
    }
}

$outcome = 'StateUnverified'
$success = $false
$message = "Defender apply tier=$Tier rollback=$RollbackJson"
if ($DryRun) {
    $outcome = 'DryRunApplied'
    $success = $true
    $message = "Defender apply tier=$Tier rollback=$RollbackJson"
} elseif ($intercept -and -not $simulateExclusions) {
    $outcome = 'InterceptedNoOsMutation'
    $success = $false
    $message = "Defender mutations were intercepted after rollback verification. No OS change. Rollback=$RollbackJson"
} else {
    switch ($Tier) {
        'TemporaryRealtimeOff' {
            $afterProbe = Get-DefenderPlatformStatus
            if ($null -eq $afterProbe.RealTimeProtectionEnabled) {
                $outcome = 'StateUnverified'
                $message = "RealTimeProtectionEnabled was not reported after TemporaryRealtimeOff. Applied withheld. Rollback=$RollbackJson"
            } elseif ([bool]$afterProbe.RealTimeProtectionEnabled) {
                $outcome = 'StateMismatch'
                $message = "Real-time protection is still enabled after TemporaryRealtimeOff. Applied withheld. Rollback=$RollbackJson"
            } else {
                $outcome = 'Applied'
                $success = $true
                $message = "Defender apply tier=$Tier verified rollback=$RollbackJson"
            }
        }
        'ExtremeServiceDisable' {
            $afterSvc = Get-Service -Name WinDefend -ErrorAction SilentlyContinue
            $stopped = $false
            $manual = $false
            if ($afterSvc) {
                $stopped = ([string]$afterSvc.Status) -eq 'Stopped'
                $manual = ([string]$afterSvc.StartType) -eq 'Manual'
            }
            if (-not $afterSvc) {
                $outcome = 'StateUnverified'
                $message = "WinDefend post-state could not be read after ExtremeServiceDisable. Applied withheld. Rollback=$RollbackJson"
            } elseif (-not $stopped -or -not $manual) {
                $outcome = 'StateMismatch'
                $message = "WinDefend post-state is StartType=$([string]$afterSvc.StartType) Status=$([string]$afterSvc.Status); expected Manual/Stopped. Applied withheld. Rollback=$RollbackJson"
            } else {
                $outcome = 'Applied'
                $success = $true
                $message = "Defender apply tier=$Tier verified rollback=$RollbackJson"
            }
        }
        default {
            if ($mutationFailed) {
                $outcome = 'Failed'
                $success = $false
                $message = "The exclusion could not be applied. $mutationError Rollback=$RollbackJson"
                break
            }
            $afterExclusions = Read-HubDefenderExclusionState
            if (-not $afterExclusions.Ok) {
                $outcome = 'StateUnverified'
                $message = "The exclusion command completed, but Windows did not provide enough state to confirm it. Rollback=$RollbackJson"
            } else {
                $missing = @($requestedPaths | Where-Object { -not (Test-DefenderExclusionPresent -Requested $_ -Actual @($afterExclusions.Paths)) })
                if ($missing.Count -gt 0) {
                    $outcome = 'StateMismatch'
                    $message = "The exclusion could not be confirmed. Missing: $($missing -join '; '). Rollback=$RollbackJson"
                } else {
                    $outcome = 'Applied'
                    $success = $true
                    $message = 'The exclusion is active.'
                }
            }
        }
    }
}

if ($taskName -and -not $DryRun -and -not $intercept -and -not $simulateExclusions) {
    $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$restoreScript`" -RollbackJson `"$RollbackJson`""
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
    $trigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes($AutoReenableMinutes))
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -RunLevel Highest -Force | Out-Null
    Add-Applied -Action 'Register-ScheduledTask re-enable' -Detail $taskName -DidApply $true
}
$reportedRollback = $RollbackJson
}

$out = [ordered]@{
    SchemaVersion = 'DefenderExtremeApplyResult.v1'
    GeneratedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Tier = $Tier
    ReasonCode = $ReasonCode
    DryRun = [bool]$DryRun
    Applied = $applied.ToArray()
    RollbackPath = $reportedRollback
    After = if ((-not $DryRun) -and (-not $intercept) -and (-not $simulateExclusions)) { Get-DefenderPlatformStatus } else { $null }
    Outcome = $outcome
    Message = $message
}
($out | ConvertTo-Json -Depth 10) | Out-File -LiteralPath $OutputJson -Encoding utf8 -Force
$decisionContext = @{
    Tier         = [string]$Tier
    DryRun       = [bool]$DryRun
    AppliedCount = [int]$applied.Count
    Outcome      = [string]$outcome
}
Write-HubDecisionLog -HubRoot $hubRoot `
    -Domain 'defender-apply' `
    -Path $(if ($env:HUB_DECISION_PATH) { [string]$env:HUB_DECISION_PATH } else { 'ps' }) `
    -Action 'ApplyTier' `
    -Outcome $outcome `
    -Success:$success `
    -Context $decisionContext
Write-Host $message
if (-not $success) {
    throw $message
}
$out
