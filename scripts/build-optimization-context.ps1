[CmdletBinding()]
param(
    [string]$OutputJson = '',
    [string]$ConfigPath = '',
    [switch]$IncludeProfile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$hubRoot = Split-Path -Parent $scriptDir
. (Join-Path $scriptDir 'lib\resource-budget.ps1')

if (-not $ConfigPath) { $ConfigPath = Join-Path $hubRoot 'config\sys-maintenance.json' }
$config = $null
if (Test-Path -LiteralPath $ConfigPath) {
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
}

$snap = Get-HostResourceSnapshot
$profile = Resolve-OptimizationProfile -Config $config -Snapshot $snap
$llmGate = Test-LlmAdvisoryAllowed -Config $config -Snapshot $snap -Profile $profile

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

$logs = Join-Path $hubRoot 'logs'
$signals = [ordered]@{}

$p = Join-Path $logs 'compute-analysis-live.json'
if (-not (Test-Path $p)) { $p = Join-Path $logs 'process-pressure-latest.json' }
$pp = Read-JsonIfExists $p
if ($pp) {
    $ppSummary = Get-JsonProperty $pp 'Summary'
    $signals.ProcessPressure = [ordered]@{
        Path = $p
        TopCount = @($pp.TopProcesses).Count
        Summary = $ppSummary
    }
}

$hb = Read-JsonIfExists (Join-Path $logs 'hub-orchestrator-heartbeat.json')
if ($hb) { $signals.OrchestratorHeartbeat = [ordered]@{ TimestampUTC = $hb.TimestampUTC; Actions = @($hb.Actions).Count } }

$health = Read-JsonIfExists (Join-Path $logs 'health-audit-live.json')
if (-not $health) { $health = Read-JsonIfExists (Join-Path $logs 'smoke-health.json') }
$healthSummary = Get-JsonProperty $health 'Summary'
if ($healthSummary) {
    $signals.HealthSummary = [ordered]@{
        Critical = [int](Get-JsonProperty $healthSummary 'Critical')
        Important = [int](Get-JsonProperty $healthSummary 'Important')
        Moderate = [int](Get-JsonProperty $healthSummary 'Moderate')
    }
}

$signals.HostSnapshot = $snap
$signals.LlmGate = $llmGate

$result = [ordered]@{
    SchemaVersion = 'OptimizationContext.v1'
    GeneratedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Host = [ordered]@{
        Tier = [string]$profile.Tier
        Profile = [string]$profile.Name
        TotalRamGb = $snap.TotalRamGb
        FreeRamMb = $snap.FreeRamMb
        LogicalProcessors = $snap.LogicalProcessors
        DriveCFreePercent = $snap.DriveCFreePercent
    }
    Signals = $signals
    RecommendedCadence = [ordered]@{
        MonitorLoopIntervalSec = $profile.MonitorLoopIntervalSec
        OrchestratorIntervalSec = $profile.OrchestratorIntervalSec
        PpiEveryOrchestratorCycles = $profile.PpiEveryOrchestratorCycles
    }
}

if ($IncludeProfile) {
    $result.Profile = $profile
}

if (-not $OutputJson) {
    $co = $null
    if ($config -and $config.ContinuousOptimization) { $co = $config.ContinuousOptimization }
    $rel = 'logs/optimization-context-latest.json'
    if ($co -and $co.ContextOutputPath) { $rel = [string]$co.ContextOutputPath }
    $OutputJson = Join-Path $hubRoot ($rel -replace '/', '\')
}

$dir = Split-Path -Parent $OutputJson
if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
($result | ConvertTo-Json -Depth 10) | Out-File -LiteralPath $OutputJson -Encoding utf8 -Force

Write-Host ("Context tier={0} profile={1} freeRam={2}MB llm={3}" -f $profile.Tier, $profile.Name, $snap.FreeRamMb, $llmGate.Allowed)
$result
