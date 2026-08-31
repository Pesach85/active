[CmdletBinding()]
param(
    [string]$OutputJson = '',
    [string]$ConfigPath = '',
    [int]$TopProcesses = 15,
    [switch]$IncludeRawSignals
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$hubRoot = Split-Path -Parent $scriptDir
. (Join-Path $scriptDir 'hub-common.ps1')
. (Join-Path $scriptDir 'lib\resource-budget.ps1')
. (Join-Path $scriptDir 'lib\transparency-policy.ps1')
. (Join-Path $scriptDir 'lib\network-transparency.ps1')
. (Join-Path $scriptDir 'lib\process-knowledge.ps1')
. (Join-Path $scriptDir 'lib\process-pressure-core.ps1')
. (Join-Path $scriptDir 'lib\process-resolution-policy.ps1')

$hub = Get-HubPaths -HubRoot $hubRoot
if (-not $ConfigPath) { $ConfigPath = $hub.ConfigFile }
$config = Get-MaintenanceConfig -ConfigPath $ConfigPath

function Read-JsonIfExists {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { return $null }
}

function Get-JsonProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function Read-TransparencyEvents {
    param([string]$Path, [int]$MaxLines = 40)

    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    try {
        $lines = Get-Content -LiteralPath $Path -Tail $MaxLines -ErrorAction Stop
        $events = [System.Collections.Generic.List[object]]::new()
        foreach ($line in $lines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { [void]$events.Add(($line | ConvertFrom-Json)) } catch { }
        }
        return @($events)
    } catch {
        return @()
    }
}

function Get-ScheduledAgentStatus {
    param($Registry)

    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($agent in $Registry) {
        $taskName = [string]$agent.TaskName
        if ([string]::IsNullOrWhiteSpace($taskName)) {
            [void]$rows.Add([ordered]@{
                AgentId = $agent.Id
                DisplayName = $agent.DisplayName
                TaskState = 'OnDemand'
                ControlLevel = $agent.ControlLevel
                LastRun = $null
                NextRun = $null
            })
            continue
        }

        try {
            $t = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
            $info = Get-ScheduledTaskInfo -TaskName $taskName
            [void]$rows.Add([ordered]@{
                AgentId = $agent.Id
                DisplayName = $agent.DisplayName
                TaskState = [string]$t.State
                ControlLevel = $agent.ControlLevel
                LastRun = if ($info.LastRunTime) { $info.LastRunTime.ToString('o') } else { $null }
                NextRun = if ($info.NextRunTime) { $info.NextRunTime.ToString('o') } else { $null }
            })
        } catch {
            [void]$rows.Add([ordered]@{
                AgentId = $agent.Id
                DisplayName = $agent.DisplayName
                TaskState = 'Missing'
                ControlLevel = $agent.ControlLevel
                LastRun = $null
                NextRun = $null
            })
        }
    }
    return @($rows)
}

function Get-RunningHubProcesses {
    $hubProcList = [System.Collections.Generic.List[object]]::new()
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $cmd = [string]$_.CommandLine
            $cmd -match 'SystemOptimizerHub|monitor-resources|hub-orchestrator|build-transparency|build-optimization|analyze-process-pressure|privacy-scan|system-health-audit'
        } |
        ForEach-Object {
            [void]$hubProcList.Add([ordered]@{
                PID = [int]$_.ProcessId
                Name = [string]$_.Name
                CommandLine = if ($_.CommandLine.Length -gt 200) { $_.CommandLine.Substring(0, 200) + '…' } else { [string]$_.CommandLine }
            })
        }
    return @($hubProcList)
}

function Get-CatalogProcessNames {
    $catalogPath = Join-Path $hubRoot 'config\process-intelligence.json'
    if (-not (Test-Path -LiteralPath $catalogPath)) { return @() }
    try {
        $cat = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
        $names = [System.Collections.Generic.List[string]]::new()
        foreach ($n in @($cat.vitalExact)) { if ($n) { [void]$names.Add([string]$n) } }
        foreach ($n in @($cat.securityExact)) { if ($n) { [void]$names.Add([string]$n) } }
        if ($cat.knownApplications) {
            foreach ($prop in $cat.knownApplications.PSObject.Properties) {
                [void]$names.Add([string]$prop.Name)
            }
        }
        return @($names | Select-Object -Unique)
    } catch {
        return @()
    }
}

$transparency = $null
if ($config -is [hashtable]) { $transparency = $config['Transparency'] }
elseif ($config.Transparency) { $transparency = $config.Transparency }

$unknownThreshold = 400
if ($transparency) {
    $ut = if ($transparency -is [hashtable]) { $transparency['UnknownRamThresholdMb'] } else { $transparency.UnknownRamThresholdMb }
    if ($null -ne $ut) { $unknownThreshold = [int]$ut }
}

$snap = Get-HostResourceSnapshot
$profile = Resolve-OptimizationProfile -Config $config -Snapshot $snap
$registry = Get-HubAgentRegistry
$catalogNames = Get-CatalogProcessNames
$hubProcs = Get-RunningHubProcesses
$hubNameMap = @{}
foreach ($hp in $hubProcs) { $hubNameMap[[string]$hp.Name] = $true }

$processRows = [System.Collections.Generic.List[object]]::new()
$unknownHighRam = [System.Collections.Generic.List[object]]::new()
$totalRamUsedMb = 0

Get-Process -ErrorAction SilentlyContinue |
    Sort-Object WorkingSet64 -Descending |
    Select-Object -First $TopProcesses |
    ForEach-Object {
        $ramMb = [math]::Round($_.WorkingSet64 / 1MB, 1)
        $totalRamUsedMb += $ramMb
        $trust = Resolve-ProcessTrustLevel -Process $_ -CatalogNames $catalogNames -RunningHubScripts $hubNameMap
        $row = [ordered]@{
            PID = $_.Id
            Name = $_.ProcessName
            RamMb = $ramMb
            CpuSec = [math]::Round($_.CPU, 1)
            TrustLevel = $trust.Level
            TrustReason = $trust.Reason
            Responding = $_.Responding
        }
        [void]$processRows.Add($row)
        if ($trust.Level -eq 'T3_Unknown' -and $ramMb -ge $unknownThreshold) {
            [void]$unknownHighRam.Add($row)
        }
    }

$logs = $hub.Logs
$eventsPath = Join-Path $logs 'transparency-events.jsonl'
if ($transparency) {
    $ep = if ($transparency -is [hashtable]) { $transparency['EventsPath'] } else { $transparency.EventsPath }
    if ($ep) { $eventsPath = Resolve-HubPath -HubRoot $hubRoot -Path $ep }
}

$events = Read-TransparencyEvents -Path $eventsPath -MaxLines 50
$heartbeat = Read-JsonIfExists (Join-Path $logs 'hub-orchestrator-heartbeat.json')
$optCtx = Read-JsonIfExists (Join-Path $logs 'optimization-context-latest.json')
$agents = Get-ScheduledAgentStatus -Registry $registry

$posture = 100
$postureNotes = [System.Collections.Generic.List[string]]::new()

if ([int]$snap.FreeRamMb -lt 2048) {
    $posture -= 25
    [void]$postureNotes.Add('Critical free RAM below 2 GB')
} elseif ([int]$snap.FreeRamMb -lt 4096) {
    $posture -= 10
    [void]$postureNotes.Add('Low free RAM below 4 GB')
}

if ([double]$snap.DriveCFreePercent -lt 10) {
    $posture -= 15
    [void]$postureNotes.Add('System drive C: below 10% free')
}

foreach ($agent in $agents) {
    if ($agent.TaskState -eq 'Missing' -and $agent.AgentId -in @('resource-monitor', 'hub-orchestrator')) {
        $posture -= 5
        [void]$postureNotes.Add("Expected agent missing: $($agent.DisplayName)")
    }
}

$posture -= [math]::Min(30, @($unknownHighRam).Count * 8)
if (@($unknownHighRam).Count -gt 0) {
    [void]$postureNotes.Add(("{0} unknown high-RAM process(es) >= {1} MB" -f @($unknownHighRam).Count, $unknownThreshold))
}

$autoTerminate = $false
if ($config -is [hashtable]) { $autoTerminate = [bool]$config['AutoTerminate'] }
elseif ($config.AutoTerminate) { $autoTerminate = [bool]$config.AutoTerminate }
if ($autoTerminate) {
    $posture -= 10
    [void]$postureNotes.Add('Monitor AutoTerminate is enabled — review policy')
}

$llmEnabled = $false
$llm = $null
if ($config -is [hashtable]) { $llm = $config['LlmAdvisory'] }
elseif ($config.LlmAdvisory) { $llm = $config.LlmAdvisory }
if ($llm) {
    $llmEnabled = if ($llm -is [hashtable]) { [bool]$llm['Enabled'] } else { [bool]$llm.Enabled }
}
if ($llmEnabled -and -not $profile.LlmAllowed) {
    $posture -= 15
    [void]$postureNotes.Add('LLM enabled on Tier C host — misaligned with feather policy')
}

$networkSnapshot = $null
$networkEnabled = $true
$smallRamMb = 120
if ($transparency) {
    $netCfg = if ($transparency -is [hashtable]) { $transparency['NetworkMonitor'] } else { $transparency.NetworkMonitor }
    if ($netCfg) {
        $networkEnabled = if ($netCfg -is [hashtable]) {
            -not $netCfg.ContainsKey('Enabled') -or [bool]$netCfg['Enabled']
        } else {
            [bool]$netCfg.Enabled
        }
        $sr = if ($netCfg -is [hashtable]) { $netCfg['SmallProcessRamMb'] } else { $netCfg.SmallProcessRamMb }
        if ($null -ne $sr) { $smallRamMb = [int]$sr }
    }
}

if ($networkEnabled) {
    $networkSnapshot = Get-NetworkTransparencySnapshot -Config $config -CatalogNames $catalogNames -SmallProcessRamMb $smallRamMb
    if ($networkSnapshot.Available) {
        $unkNet = [int]$networkSnapshot.Summary.UnknownTrustCount
        $hiddenNet = [int]$networkSnapshot.Summary.HiddenNetworkProcessCount
        if ($unkNet -gt 0) {
            $posture -= [math]::Min(20, $unkNet * 3)
            [void]$postureNotes.Add("{0} network connection(s) with T3 trust" -f $unkNet)
        }
        if ($hiddenNet -gt 0) {
            $posture -= [math]::Min(15, $hiddenNet * 5)
            [void]$postureNotes.Add("{0} small/hidden process(es) with outbound traffic" -f $hiddenNet)
        }
    } else {
        [void]$postureNotes.Add('Network snapshot unavailable — run as admin or check Get-NetTCPConnection')
    }
}

if ($posture -lt  0) { $posture = 0 }

$recentActions = [System.Collections.Generic.List[object]]::new()
foreach ($ev in $events) {
    [void]$recentActions.Add([ordered]@{
        Source = 'transparency-events'
        Timestamp = [string]$ev.Timestamp
        Action = [string]$ev.Action
        Detail = [string]$ev.Detail
        AgentId = [string]$ev.AgentId
        ControlLevel = [string]$ev.ControlLevel
    })
}

if ($heartbeat -and $heartbeat.Actions) {
    foreach ($act in @($heartbeat.Actions)) {
        $status = Get-JsonProperty $act 'Status'
        $actionName = Get-JsonProperty $act 'Action'
        [void]$recentActions.Add([ordered]@{
            Source = 'orchestrator-heartbeat'
            Timestamp = [string]$heartbeat.TimestampUTC
            Action = [string]$actionName
            Detail = if ($status) { [string]$status } else { '' }
            AgentId = 'hub-orchestrator'
            ControlLevel = 'T1_Delegated'
        })
    }
}

$monitorLog = Join-Path $logs 'resource-monitor.log'
if (Test-Path -LiteralPath $monitorLog) {
    Get-Content -LiteralPath $monitorLog -Tail 8 -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_ -match '\[(WARN|CRITICAL|ERROR)\]') {
            [void]$recentActions.Add([ordered]@{
                Source = 'resource-monitor'
                Timestamp = $_.Substring(0, [math]::Min(19, $_.Length))
                Action = 'MonitorLog'
                Detail = $_.Substring([math]::Min(20, $_.Length))
                AgentId = 'resource-monitor'
                ControlLevel = 'T1_Delegated'
            })
        }
    }
}

$result = [ordered]@{
    SchemaVersion = 'TransparencyReport.v1'
    GeneratedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    PolicyVersion = $script:TransparencyPolicyVersion
    Posture = [ordered]@{
        Score = $posture
        Grade = if ($posture -ge 85) { 'Good' } elseif ($posture -ge 65) { 'Review' } else { 'Alert' }
        Notes = @($postureNotes)
    }
    Host = [ordered]@{
        Tier = [string]$profile.Tier
        Profile = [string]$profile.Name
        TotalRamGb = $snap.TotalRamGb
        FreeRamMb = $snap.FreeRamMb
        UsedRamMbTopN = [math]::Round($totalRamUsedMb, 0)
        DriveCFreePercent = $snap.DriveCFreePercent
        LogicalProcessors = $snap.LogicalProcessors
    }
    RamConsumers = @($processRows)
    UnknownHighRam = @($unknownHighRam)
    Network = if ($networkSnapshot) { $networkSnapshot } else { $null }
    RegisteredAgents = @($agents)
    RunningHubProcesses = @($hubProcs)
    RecentAutomatedActions = @($recentActions | Select-Object -Last 40)
    DelegationManifest = Get-DelegationManifest -Config $config
    ControlLevels = [ordered]@{
        T0_Observed = Get-ControlLevelLabel 'T0_Observed'
        T1_Delegated = Get-ControlLevelLabel 'T1_Delegated'
        T2_Review = Get-ControlLevelLabel 'T2_Review'
        T3_Unknown = Get-ControlLevelLabel 'T3_Unknown'
    }
}

$pkConfig = Get-ProcessKnowledgeConfig -HubRoot $hubRoot
if ($pkConfig.Enabled) {
    $hintTargets = [System.Collections.Generic.List[object]]::new()
    foreach ($u in @($unknownHighRam)) {
        [void]$hintTargets.Add([ordered]@{
            ProcessName = [string]$u.Name; PID = [int]$u.PID; RamMb = [double]$u.RamMb
        })
    }
    if ($networkSnapshot -and $networkSnapshot.HiddenNetworkProcesses) {
        foreach ($h in @($networkSnapshot.HiddenNetworkProcesses)) {
            [void]$hintTargets.Add([ordered]@{
                ProcessName = [string]$h.Name; PID = [int]$h.PID; RamMb = [double]$h.RamMb
            })
        }
    }
    if (@($hintTargets).Count -gt 0) {
        $catalog = Get-ProcessIntelligenceCatalog -CatalogPath (Join-Path $hubRoot 'config\process-intelligence.json')
        $deduped = [System.Collections.Generic.List[object]]::new()
        $seenHint = @{}
        foreach ($t in $hintTargets) {
            $k = ([string]$t.ProcessName).ToLowerInvariant()
            if (-not $k -or $seenHint.ContainsKey($k)) { continue }
            $seenHint[$k] = $true
            [void]$deduped.Add($t)
        }
        $result['ClassificationHints'] = @(Get-ProcessKnowledgeHintsForTargets `
            -Targets @($deduped) `
            -HubRoot $hubRoot `
            -Catalog $catalog `
            -KnowledgeConfig $pkConfig `
            -MaintenanceConfig $config `
            -Offline)

        $resCfg = Get-ProcessResolutionConfig -HubRoot $hubRoot
        $opDec = Get-OperatorProcessDecisions -HubRoot $hubRoot -RelPath ([string]$resCfg.OperatorDecisionsPath)
        $resList = [System.Collections.Generic.List[object]]::new()
        foreach ($t in $deduped) {
            $ps = Get-ProcessLiveSnapshot -ProcessId ([int]$t.PID) -ProcessName ([string]$t.ProcessName)
            if (-not $ps) {
                $ps = [ordered]@{
                    PID = [int]$t.PID
                    ProcessName = [string]$t.ProcessName
                    RamMb = [double]$t.RamMb
                    Responding = $true
                    PriorityClass = 'Unknown'
                    Path = ''
                }
            }
            $matchHint = @($result['ClassificationHints'] | Where-Object { $_.ProcessName -ieq $ps.ProcessName } | Select-Object -First 1)
            $op = Get-OperatorDecisionForProcess -DecisionsObj $opDec -ProcessName ([string]$ps.ProcessName)
            [void]$resList.Add((Get-ProcessResolutionAdvisory -ProcessSnapshot $ps -KnowledgeHint $matchHint `
                -ResolutionConfig $resCfg -OperatorDecision $op))
        }
        $result['ProcessResolutions'] = @($resList)
    }
}

if ($IncludeRawSignals) {
    $result.RawSignals = [ordered]@{
        OptimizationContext = $optCtx
        OrchestratorHeartbeat = $heartbeat
    }
}

if (-not $OutputJson) {
    $rel = 'logs/transparency-report-latest.json'
    if ($transparency) {
        $op = if ($transparency -is [hashtable]) { $transparency['ReportOutputPath'] } else { $transparency.ReportOutputPath }
        if ($op) { $rel = [string]$op }
    }
    $OutputJson = Resolve-HubPath -HubRoot $hubRoot -Path $rel
}

$dir = Split-Path -Parent $OutputJson
if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
($result | ConvertTo-Json -Depth 12) | Out-File -LiteralPath $OutputJson -Encoding utf8 -Force

Write-Host ("Transparency posture={0}/100 tier={1} unknownHighRam={2} -> {3}" -f $posture, $profile.Tier, @($unknownHighRam).Count, $OutputJson)
$result

