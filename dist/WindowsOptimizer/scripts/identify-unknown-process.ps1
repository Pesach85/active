[CmdletBinding()]
param(
    [int]$ProcessId = 0,
    [string]$ProcessName = '',
    [Parameter(Mandatory = $false)]
    [string]$WhatItIs,
    [Parameter(Mandatory = $false)]
    [string]$WhatItDoes,
    [string]$SuggestedCategory = 'Unknown',
    [ValidateSet('Keep', 'Tune', 'Review', 'Unknown')]
    [string]$SuggestedPriority = 'Review',
    [string]$BusinessHint = '',
    [string]$OperatorNote = '',
    [string]$WindowsPassword = '',
    [string]$WindowsPasswordFile = '',
    [string]$SessionToken = '',
    [string]$RequestJsonPath = '',
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
. (Join-Path $scriptDir 'lib\hub-decision-log.ps1')
. (Join-Path $scriptDir 'lib\transparency-events.ps1')
. (Join-Path $scriptDir 'lib\process-catalog-merge.ps1')

$hub = Get-HubPaths -HubRoot $HubRoot
$knowCfg = Get-ProcessKnowledgeConfig -HubRoot $HubRoot
$resCfg = Get-ProcessResolutionConfig -HubRoot $HubRoot

if ($RequestJsonPath -and (Test-Path -LiteralPath $RequestJsonPath)) {
    $req = Get-Content -LiteralPath $RequestJsonPath -Raw | ConvertFrom-Json
    $reqNames = @($req.PSObject.Properties.Name)
    if ($reqNames -contains 'processId' -and $req.processId) { $ProcessId = [int]$req.processId }
    if ($reqNames -contains 'processName' -and $req.processName) { $ProcessName = [string]$req.processName }
    if ($reqNames -contains 'whatItIs' -and $req.whatItIs) { $WhatItIs = [string]$req.whatItIs }
    if ($reqNames -contains 'whatItDoes' -and $req.whatItDoes) { $WhatItDoes = [string]$req.whatItDoes }
    if ($reqNames -contains 'category' -and $req.category) { $SuggestedCategory = [string]$req.category }
    if ($reqNames -contains 'priority' -and $req.priority) { $SuggestedPriority = [string]$req.priority }
    if ($reqNames -contains 'businessHint' -and $req.businessHint) { $BusinessHint = [string]$req.businessHint }
    if ($reqNames -contains 'note' -and $req.note) { $OperatorNote = [string]$req.note }
    if ($reqNames -contains 'password' -and $req.password) { $WindowsPassword = [string]$req.password }
    if ($reqNames -contains 'sessionToken' -and $req.sessionToken) { $SessionToken = [string]$req.sessionToken }
}

if ([string]::IsNullOrWhiteSpace($WhatItIs) -or [string]::IsNullOrWhiteSpace($WhatItDoes)) {
    throw 'WhatItIs and WhatItDoes are required.'
}

$WindowsPassword = Get-OperatorPasswordFromParam -Password $WindowsPassword -PasswordFile $WindowsPasswordFile

try {
[void](Assert-OperatorAuth -Password $WindowsPassword -SessionToken $SessionToken -SkipAuth:$SkipAuth)

$snap = Get-ProcessLiveSnapshot -ProcessId $ProcessId -ProcessName $ProcessName
if (-not $snap) {
    if (-not $ProcessName) {
        throw 'Process not found - provide -ProcessName or a running -ProcessId'
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

$cacheObj = Get-ProcessKnowledgeCache -HubRoot $HubRoot -CacheRelPath ([string]$knowCfg.CachePath)
$existing = Get-ProcessKnowledgeFromCache -Cache $cacheObj -ProcessName ([string]$snap.ProcessName) -TtlDays 99999
$seedBaseline = Get-ProcessKnowledgeSeedEntry -HubRoot $HubRoot -ProcessName ([string]$snap.ProcessName)

$entry = [ordered]@{
    ProcessName = [string]$snap.ProcessName
    WhatItIs = $WhatItIs.Trim()
    WhatItDoes = $WhatItDoes.Trim()
    SuggestedCategory = $SuggestedCategory
    SuggestedPriority = $SuggestedPriority
    ResourceProfile = 'Mixed'
    BusinessHint = $BusinessHint.Trim()
    SuggestedActions = @('Operator manual identification - catalog auto-merge on auth')
    Confidence = 0.98
    Sources = @('operator-manual', "PID=$($snap.PID)")
    LearnedAt = (Get-Date).ToString('o')
    OperatorNote = $OperatorNote.Trim()
    ImagePath = [string]$snap.Path
}

$mergeBaseline = $seedBaseline
if ($existing) {
    $existingDoes = [string](Get-JsonPropertySafe $existing 'WhatItDoes')
    $seedDoes = if ($seedBaseline) { [string](Get-JsonPropertySafe $seedBaseline 'WhatItDoes') } else { '' }
    if ($existingDoes.Length -gt $seedDoes.Length) {
        $mergeBaseline = $existing
    } elseif (-not $mergeBaseline) {
        $mergeBaseline = $existing
    }
}
if ($mergeBaseline) {
    $entry = Merge-OperatorManualCacheEntry -Existing $mergeBaseline -New $entry
}

Save-ProcessKnowledgeCacheEntry -CachePath $cachePath -ProcessName ([string]$snap.ProcessName) -Entry $entry

$catalogPipeline = Invoke-PostIdentifyCatalogPipeline `
    -HubRoot $HubRoot `
    -ProcessName ([string]$snap.ProcessName) `
    -CacheEntry $entry `
    -ProcessSnapshot $snap `
    -Confidence ([double]$entry.Confidence) `
    -Offline:$Offline `
    -SkipAuth:$SkipAuth

$opDec = Get-OperatorProcessDecisions -HubRoot $HubRoot -RelPath ([string]$resCfg.OperatorDecisionsPath)
Save-OperatorProcessDecision -Path $opDec.Path -ProcessName ([string]$snap.ProcessName) `
    -Decision 'Identified' -Note ("Manual: $WhatItIs | $OperatorNote")

$eventsPath = Join-Path $hub.Logs 'transparency-events.jsonl'
Write-TransparencyEvent -EventsPath $eventsPath -Action 'IdentifyProcessManual' `
    -Detail ("Name={0} Category={1} Priority={2}" -f $snap.ProcessName, $SuggestedCategory, $SuggestedPriority) `
    -AgentId 'process-identify' -ControlLevel 'T0_Observed'

$msg = 'Manual identification saved to KB cache.'
$pipelineSkipped = [bool](Get-JsonPropertySafe $catalogPipeline 'Skipped')
$pipelineMerge = Get-JsonPropertySafe $catalogPipeline 'CatalogMerge'
if ($catalogPipeline -is [System.Collections.IDictionary]) {
    if ($catalogPipeline.Contains('Skipped')) { $pipelineSkipped = [bool]$catalogPipeline['Skipped'] }
    if ($catalogPipeline.Contains('CatalogMerge')) { $pipelineMerge = $catalogPipeline['CatalogMerge'] }
}

if ($pipelineSkipped) {
    $skipReason = [string](Get-JsonPropertySafe $catalogPipeline 'Reason')
    $msg += " Catalog merge skipped ($skipReason)."
} elseif ($pipelineMerge -and [bool]$pipelineMerge.Ok) {
    $msg += ' Catalog updated (T1 trust) and transparency report refreshed.'
    $catPath = [string](Get-JsonPropertySafe $pipelineMerge 'CatalogPath')
    Write-TransparencyEvent -EventsPath $eventsPath -Action 'CatalogMergeFromIdentify' `
        -Detail ("Name={0} Catalog={1}" -f $snap.ProcessName, $catPath) `
        -AgentId 'process-identify' -ControlLevel 'T1_Delegated'
} elseif ($pipelineMerge) {
    $mergeReason = [string](Get-JsonPropertySafe $pipelineMerge 'Reason')
    $msg += " Catalog merge failed ($mergeReason)."
} else {
    $msg += ' Catalog merge state unknown.'
}

$result = [ordered]@{
    SchemaVersion = 'ProcessIdentifyResult.v1'
    GeneratedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Process = $snap
    CacheKey = $key
    CachePath = $cachePath
    Entry = $entry
    CatalogMerge = $catalogPipeline
    Outcome = 'Identified'
    Message = $msg
}

if (-not $OutputJson) {
    $OutputJson = Join-Path $hub.Logs 'process-identify-latest.json'
}
$dir = Split-Path -Parent $OutputJson
if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
($result | ConvertTo-Json -Depth 10) | Out-File -LiteralPath $OutputJson -Encoding utf8 -Force

$catalogMerged = ($null -ne $pipelineMerge -and [bool]$pipelineMerge.Ok)
$idSuccess = [string]$result.Outcome -eq 'Identified' -and ($pipelineSkipped -or $catalogMerged)
$idContext = @{
    ProcessName   = [string]$snap.ProcessName
    Category      = $SuggestedCategory
    CatalogMerged = $catalogMerged
}
Write-HubDecisionLog -HubRoot $HubRoot `
    -Domain 'identify' `
    -Path $(if ($env:HUB_DECISION_PATH) { [string]$env:HUB_DECISION_PATH } else { 'ps' }) `
    -Action 'ManualIdentify' `
    -Outcome ([string]$result.Outcome) `
    -Success:$idSuccess `
    -Context $idContext

if (-not $Quiet) {
    Write-Host ("Identified {0} -> cache key {1}" -f $snap.ProcessName, $key)
}

$result
} catch {
    $fail = [ordered]@{
        SchemaVersion = 'ProcessIdentifyResult.v1'
        GeneratedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Outcome = 'Failed'
        Message = $_.Exception.Message
    }
    if (-not $OutputJson) {
        $OutputJson = Join-Path $hub.Logs 'process-identify-latest.json'
    }
    $dir = Split-Path -Parent $OutputJson
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    ($fail | ConvertTo-Json -Depth 6) | Out-File -LiteralPath $OutputJson -Encoding utf8 -Force
    Write-HubDecisionLog -HubRoot $HubRoot -Domain 'identify' `
        -Path $(if ($env:HUB_DECISION_PATH) { $env:HUB_DECISION_PATH } else { 'ps' }) `
        -Action 'ManualIdentify' -Outcome 'Failed' -Success $false `
        -Context @{ Message = $_.Exception.Message }
    if (-not $Quiet) { Write-Error $_.Exception.Message }
    exit 1
} finally {
    Clear-OperatorPasswordFile -PasswordFile $WindowsPasswordFile
}
