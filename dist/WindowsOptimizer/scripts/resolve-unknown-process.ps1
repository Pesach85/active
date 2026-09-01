[CmdletBinding()]
param(
    [int]$ProcessId = 0,
    [string]$ProcessName = '',
    [ValidateSet('Advisory', 'Observe', 'ThrottleBelowNormal', 'Terminate', 'MarkWorkNecessary', 'MarkUnneeded')]
    [string]$Action = 'Advisory',
    [string]$ConfirmPhrase = '',
    [string]$OperatorNote = '',
    [string]$WindowsPassword = '',
    [string]$WindowsPasswordFile = '',
    [string]$SessionToken = '',
    [string]$RequestJsonPath = '',
    [string]$OutputJson = '',
    [string]$HubRoot = '',
    [switch]$DryRun,
    [switch]$Offline,
    [switch]$SkipAuth,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $HubRoot) { $HubRoot = Split-Path -Parent $scriptDir }

. (Join-Path $scriptDir 'hub-common.ps1')
. (Join-Path $scriptDir 'lib\process-pressure-core.ps1')
. (Join-Path $scriptDir 'lib\process-knowledge.ps1')
. (Join-Path $scriptDir 'lib\process-resolution-policy.ps1')
. (Join-Path $scriptDir 'lib\transparency-events.ps1')
. (Join-Path $scriptDir 'lib\operator-auth.ps1')
. (Join-Path $scriptDir 'lib\hub-decision-log.ps1')

$hub = Get-HubPaths -HubRoot $HubRoot
$resCfg = Get-ProcessResolutionConfig -HubRoot $HubRoot
$knowCfg = Get-ProcessKnowledgeConfig -HubRoot $HubRoot

if ($RequestJsonPath -and (Test-Path -LiteralPath $RequestJsonPath)) {
    $req = Get-Content -LiteralPath $RequestJsonPath -Raw | ConvertFrom-Json
    $reqNames = @($req.PSObject.Properties.Name)
    if ($reqNames -contains 'processId' -and $req.processId) { $ProcessId = [int]$req.processId }
    if ($reqNames -contains 'processName' -and $req.processName) { $ProcessName = [string]$req.processName }
    if ($reqNames -contains 'action' -and $req.action) { $Action = [string]$req.action }
    if ($reqNames -contains 'confirmPhrase' -and $req.confirmPhrase) { $ConfirmPhrase = [string]$req.confirmPhrase }
    if ($reqNames -contains 'operatorNote' -and $req.operatorNote) { $OperatorNote = [string]$req.operatorNote }
    if ($reqNames -contains 'password' -and $req.password) { $WindowsPassword = [string]$req.password }
    if ($reqNames -contains 'sessionToken' -and $req.sessionToken) { $SessionToken = [string]$req.sessionToken }
    if ($reqNames -contains 'dryRun' -and $req.dryRun) { $DryRun = $true }
    if ($reqNames -contains 'offline' -and $req.offline) { $Offline = $true }
}

$WindowsPassword = Get-OperatorPasswordFromParam -Password $WindowsPassword -PasswordFile $WindowsPasswordFile
$catalog = Get-ProcessIntelligenceCatalog -CatalogPath (Join-Path $HubRoot 'config\process-intelligence.json')
$maintenanceConfig = $null
if (Test-Path -LiteralPath $hub.ConfigFile) {
    $maintenanceConfig = Get-MaintenanceConfig -ConfigPath $hub.ConfigFile
}

$snap = Get-ProcessLiveSnapshot -ProcessId $ProcessId -ProcessName $ProcessName
if (-not $snap) {
    $syntheticName = if ($ProcessName) { ($ProcessName -replace '\.exe$','') } else { "PID$ProcessId" }
    if ($Action -eq 'Advisory' -or ($DryRun -and $Action -ne 'Observe')) {
        $snap = [ordered]@{
            PID = if ($ProcessId -gt 0) { $ProcessId } else { 0 }
            ProcessName = $syntheticName
            RamMb = 0.0
            CpuSec = 0.0
            Responding = $false
            PriorityClass = 'Unknown'
            Path = ''
            NotRunning = $true
        }
    } else {
        $result = [ordered]@{
            SchemaVersion = 'ProcessResolutionResult.v1'
            GeneratedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            Action = $Action
            DryRun = [bool]$DryRun
            Process = [ordered]@{ PID = $ProcessId; ProcessName = $syntheticName }
            Outcome = 'ProcessNotFound'
            Message = "Process not running (PID=$ProcessId Name=$ProcessName). Select a live process from the Control tab or web dashboard."
        }
        if (-not $OutputJson) { $OutputJson = Join-Path $hub.Logs 'process-resolution-latest.json' }
        $dir = Split-Path -Parent $OutputJson
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
        ($result | ConvertTo-Json -Depth 8) | Out-File -LiteralPath $OutputJson -Encoding utf8 -Force
        if (-not $Quiet) { Write-Host $result.Message }
        $result
        exit 1
    }
}

$opDec = Get-OperatorProcessDecisions -HubRoot $HubRoot -RelPath ([string]$resCfg.OperatorDecisionsPath)
$operatorDecision = Get-OperatorDecisionForProcess -DecisionsObj $opDec -ProcessName ([string]$snap.ProcessName)
$catalogNecessity = Resolve-ProcessNecessity -ProcessName ([string]$snap.ProcessName) -Catalog $catalog

$hint = Build-ProcessKnowledgeHint `
    -ProcessName ([string]$snap.ProcessName) `
    -ProcessId ([int]$snap.PID) `
    -ImagePath ([string]$snap.Path) `
    -RamMb ([double]$snap.RamMb) `
    -HubRoot $HubRoot `
    -Catalog $catalog `
    -KnowledgeConfig $knowCfg `
    -MaintenanceConfig $maintenanceConfig `
    -Offline:$Offline `
    -AllowWeb:(-not $Offline) `
    -AllowLlm:(-not $Offline)

$advisory = Get-ProcessResolutionAdvisory `
    -ProcessSnapshot $snap `
    -KnowledgeHint $hint `
    -ResolutionConfig $resCfg `
    -OperatorDecision $operatorDecision `
    -CatalogNecessity $catalogNecessity

$eventsPath = Join-Path $hub.Logs 'transparency-events.jsonl'
$rollbackPath = Join-Path $hub.Logs ("process-resolution-rollback-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

$result = [ordered]@{
    SchemaVersion = 'ProcessResolutionResult.v1'
    GeneratedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Action = $Action
    DryRun = [bool]$DryRun
    Process = $snap
    KnowledgeHint = $hint
    Advisory = $advisory
    CatalogNecessity = $catalogNecessity
    Outcome = 'Pending'
    Message = ''
}

if ($Action -eq 'Advisory') {
    $result.Outcome = 'AdvisoryOnly'
    $result.Message = 'No action taken - review Advisory.RecommendedActionId'
}
else {
    if (Test-ProcessSnapshotNotRunning -Snapshot $snap) {
        $result.Outcome = 'ProcessNotRunning'
        $result.Message = 'Process is not running - cannot apply this action. Refresh the list and pick a live process.'
    }
    else {
    [void](Assert-OperatorAuth -Password $WindowsPassword -SessionToken $SessionToken -SkipAuth:$SkipAuth)

    $block = Test-ProcessCatalogActionBlocked -Action $Action -CatalogNecessity $catalogNecessity
    if ($block.Blocked) {
        $result.Outcome = 'ActionBlocked'
        $result.Message = [string]$block.Reason
    }
    else {
    switch ($Action) {
        'Observe' {
            $result.Outcome = if ($DryRun) { 'DryRunObserve' } else { 'Observed' }
            $result.Message = 'Operator chose observe - no system mutation.'
            if (-not $DryRun) {
                Write-TransparencyEvent -EventsPath $eventsPath -Action 'ProcessObserve' `
                    -Detail ("PID={0} Name={1}" -f $snap.PID, $snap.ProcessName) `
                    -AgentId 'process-resolution' -ControlLevel 'T0_Observed'
            }
        }
        'MarkWorkNecessary' {
            $expected = [string]$resCfg.ConfirmPhraseMarkNecessary
            if ($expected -and $ConfirmPhrase -ne $expected) {
                throw "Confirm phrase required: $expected"
            }
            if (-not $DryRun) {
                Save-OperatorProcessDecision -Path $opDec.Path -ProcessName ([string]$snap.ProcessName) `
                    -Decision 'WorkNecessary' -Note $OperatorNote
                Write-TransparencyEvent -EventsPath $eventsPath -Action 'MarkWorkNecessary' `
                    -Detail ("Name={0} Note={1}" -f $snap.ProcessName, $OperatorNote) `
                    -AgentId 'process-resolution' -ControlLevel 'T0_Observed'
            }
            $result.Outcome = if ($DryRun) { 'DryRunMarkWorkNecessary' } else { 'MarkedWorkNecessary' }
            $result.Message = 'Recorded operator decision - process treated as work-necessary.'
        }
        'MarkUnneeded' {
            if (-not $DryRun) {
                Save-OperatorProcessDecision -Path $opDec.Path -ProcessName ([string]$snap.ProcessName) `
                    -Decision 'Unneeded' -Note $OperatorNote
                Write-TransparencyEvent -EventsPath $eventsPath -Action 'MarkUnneeded' `
                    -Detail ("Name={0}" -f $snap.ProcessName) -AgentId 'process-resolution' -ControlLevel 'T2_Review'
            }
            $result.Outcome = if ($DryRun) { 'DryRunMarkUnneeded' } else { 'MarkedUnneeded' }
            $result.Message = 'Recorded as unneeded - terminate still requires HITL.'
        }
        'ThrottleBelowNormal' {
            if ([int]$snap.PID -le 0) { throw 'Throttle requires running process PID' }
            $rollback = [ordered]@{
                SchemaVersion = 'ProcessResolutionRollback.v1'
                PID = [int]$snap.PID
                ProcessName = [string]$snap.ProcessName
                PreviousPriority = [string]$snap.PriorityClass
                Action = 'ThrottleBelowNormal'
            }
            if ($DryRun) {
                $result.Outcome = 'DryRunThrottle'
                $result.Message = 'Would set BelowNormal priority'
            } else {
                $proc = Get-Process -Id ([int]$snap.PID) -ErrorAction Stop
                $rollback.PreviousPriority = [string]$proc.PriorityClass
                $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal
                ($rollback | ConvertTo-Json -Depth 4) | Out-File -LiteralPath $rollbackPath -Encoding utf8 -Force
                Write-TransparencyEvent -EventsPath $eventsPath -Action 'ThrottleBelowNormal' `
                    -Detail ("PID={0} Name={1}" -f $snap.PID, $snap.ProcessName) `
                    -AgentId 'process-resolution' -ControlLevel 'T1_Delegated'
                $result.Outcome = 'Throttled'
                $result.Message = "Priority set BelowNormal. Rollback: $rollbackPath"
                $result.RollbackPath = $rollbackPath
            }
        }
        'Terminate' {
            $gate = Test-ProcessTerminateAllowed -ProcessName ([string]$snap.ProcessName) -ResolutionConfig $resCfg
            if (-not $gate.Allowed) { throw $gate.Reason }
            $expected = [string]$resCfg.ConfirmPhraseTerminate
            if ($ConfirmPhrase -ne $expected) {
                throw "Terminate requires -ConfirmPhrase '$expected'"
            }
            if ([int]$snap.PID -le 0) { throw 'Terminate requires running process PID' }

            if ($DryRun) {
                $result.Outcome = 'DryRunTerminate'
                $result.Message = 'Would stop process after HITL confirmation'
            } else {
                Stop-Process -Id ([int]$snap.PID) -Force -ErrorAction Stop
                Write-TransparencyEvent -EventsPath $eventsPath -Action 'TerminateProcess' `
                    -Detail ("PID={0} Name={1} operator-HITL" -f $snap.PID, $snap.ProcessName) `
                    -AgentId 'process-resolution' -ControlLevel 'T2_Review'
                $result.Outcome = 'Terminated'
                $result.Message = 'Process terminated by operator HITL decision.'
            }
        }
    }
    }
    }
}

if (-not $OutputJson) {
    $OutputJson = Join-Path $hub.Logs 'process-resolution-latest.json'
}
$dir = Split-Path -Parent $OutputJson
if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
($result | ConvertTo-Json -Depth 12) | Out-File -LiteralPath $OutputJson -Encoding utf8 -Force

$resolveSuccess = [string]$result.Outcome -notin @('ActionBlocked', 'ProcessNotRunning', 'AuthRequired', 'ConfirmPhraseRequired', 'TerminateBlocked')
$resolveContext = @{
    ProcessName = [string]$snap.ProcessName
    ProcessId   = [int]$snap.PID
    DryRun      = [bool]$DryRun
    Recommended = [string]$advisory.RecommendedActionId
}
Write-HubDecisionLog -HubRoot $HubRoot `
    -Domain 'resolve-apply' `
    -Path $(if ($env:HUB_DECISION_PATH) { [string]$env:HUB_DECISION_PATH } else { 'ps' }) `
    -Action $Action `
    -Outcome ([string]$result.Outcome) `
    -Success:$resolveSuccess `
    -Context $resolveContext

if (-not $Quiet) {
    Write-Host ("Resolution action={0} outcome={1} recommended={2}" -f $Action, $result.Outcome, $advisory.RecommendedActionId)
    Write-Host ("AI aided: {0}" -f $advisory.AiAidedSummary)
}

$result
Clear-OperatorPasswordFile -PasswordFile $WindowsPasswordFile
