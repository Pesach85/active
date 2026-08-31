[CmdletBinding()]
param(
    [int]$ProcessId = 0,
    [string]$ProcessName = '',
    [Parameter(Mandatory = $true)]
    [string]$WhatItIs,
    [Parameter(Mandatory = $true)]
    [string]$WhatItDoes,
    [string]$SuggestedCategory = 'Unknown',
    [ValidateSet('Keep', 'Tune', 'Review', 'Unknown')]
    [string]$SuggestedPriority = 'Review',
    [string]$BusinessHint = '',
    [string]$OperatorNote = '',
    [string]$WindowsPassword = '',
    [string]$OutputJson = '',
    [string]$HubRoot = '',
    [switch]$SkipAuth,
    [switch]$Offline,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $HubRoot) { $HubRoot = Split-Path -Parent $scriptDir }

. (Join-Path $scriptDir 'hub-common.ps1')
. (Join-Path $scriptDir 'lib\process-knowledge.ps1')
. (Join-Path $scriptDir 'lib\process-resolution-policy.ps1')
. (Join-Path $scriptDir 'lib\operator-auth.ps1')
. (Join-Path $scriptDir 'lib\transparency-events.ps1')

$hub = Get-HubPaths -HubRoot $HubRoot
$knowCfg = Get-ProcessKnowledgeConfig -HubRoot $HubRoot
$resCfg = Get-ProcessResolutionConfig -HubRoot $HubRoot

[void](Assert-OperatorWindowsPassword -Password $WindowsPassword -SkipAuth:$SkipAuth)

$snap = Get-ProcessLiveSnapshot -ProcessId $ProcessId -ProcessName $ProcessName
if (-not $snap) {
    if (-not $ProcessName) {
        throw 'Process not found â€” provide -ProcessName or a running -ProcessId'
    }
    $snap = [ordered]@{
        PID = 0
        ProcessName = ($ProcessName -replace '\.exe$','')
        RamMb = 0.0
        CpuSec = 0.0
        Responding = $true
        PriorityClass = 'Unknown'
        Path = ''
    }
}

$cachePath = Join-Path $HubRoot (($knowCfg.CachePath -replace '/', '\'))
$key = Get-CacheEntryKey -ProcessName ([string]$snap.ProcessName)

$entry = [ordered]@{
    ProcessName = [string]$snap.ProcessName
    WhatItIs = $WhatItIs.Trim()
    WhatItDoes = $WhatItDoes.Trim()
    SuggestedCategory = $SuggestedCategory
    SuggestedPriority = $SuggestedPriority
    ResourceProfile = 'Mixed'
    BusinessHint = $BusinessHint.Trim()
    SuggestedActions = @('Operator manual identification â€” review catalog merge separately')
    Confidence = 0.98
    Sources = @('operator-manual', "PID=$($snap.PID)")
    LearnedAt = (Get-Date).ToString('o')
    OperatorNote = $OperatorNote.Trim()
    ImagePath = [string]$snap.Path
}

Save-ProcessKnowledgeCacheEntry -CachePath $cachePath -ProcessName ([string]$snap.ProcessName) -Entry $entry

$opDec = Get-OperatorProcessDecisions -HubRoot $HubRoot -RelPath ([string]$resCfg.OperatorDecisionsPath)
Save-OperatorProcessDecision -Path $opDec.Path -ProcessName ([string]$snap.ProcessName) `
    -Decision 'Identified' -Note ("Manual: $WhatItIs | $OperatorNote")

$eventsPath = Join-Path $hub.Logs 'transparency-events.jsonl'
Write-TransparencyEvent -EventsPath $eventsPath -Action 'IdentifyProcessManual' `
    -Detail ("Name={0} Category={1} Priority={2}" -f $snap.ProcessName, $SuggestedCategory, $SuggestedPriority) `
    -AgentId 'process-identify' -ControlLevel 'T0_Observed'

$result = [ordered]@{
    SchemaVersion = 'ProcessIdentifyResult.v1'
    GeneratedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Process = $snap
    CacheKey = $key
    CachePath = $cachePath
    Entry = $entry
    Outcome = 'Identified'
    Message = 'Manual identification saved to KB cache (not auto-merged to catalog).'
}

if (-not $OutputJson) {
    $OutputJson = Join-Path $hub.Logs 'process-identify-latest.json'
}
$dir = Split-Path -Parent $OutputJson
if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
($result | ConvertTo-Json -Depth 10) | Out-File -LiteralPath $OutputJson -Encoding utf8 -Force

if (-not $Quiet) {
    Write-Host ("Identified {0} -> cache key {1}" -f $snap.ProcessName, $key)
}

$result
