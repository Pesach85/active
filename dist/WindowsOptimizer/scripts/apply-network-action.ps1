[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)][string]$Action,
    [int]$ProcessId = 0,
    [string]$ProcessName = '',
    [string]$LocalAddress = '',
    [int]$LocalPort = 0,
    [string]$RemoteAddress = '',
    [int]$RemotePort = 0,
    [string]$SessionToken = '',
    [string]$ConfirmPhrase = '',
    [string]$RequestJsonPath = '',
    [string]$OutputJson = '',
    [string]$HubRoot = '',
    [switch]$DryRun,
    [switch]$IUnderstandRisk,
    [switch]$SkipAuth,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $HubRoot) { $HubRoot = Split-Path -Parent $scriptDir }

if ($RequestJsonPath -and (Test-Path -LiteralPath $RequestJsonPath)) {
    $req = Get-Content -LiteralPath $RequestJsonPath -Raw | ConvertFrom-Json
    $reqNames = @($req.PSObject.Properties.Name)
    if ($reqNames -contains 'action' -and $req.action) { $Action = [string]$req.action }
    if ($reqNames -contains 'processId' -and $req.processId) { $ProcessId = [int]$req.processId }
    if ($reqNames -contains 'processName' -and $req.processName) { $ProcessName = [string]$req.processName }
    if ($reqNames -contains 'localAddress' -and $req.localAddress) { $LocalAddress = [string]$req.localAddress }
    if ($reqNames -contains 'localPort' -and $req.localPort) { $LocalPort = [int]$req.localPort }
    if ($reqNames -contains 'remoteAddress' -and $req.remoteAddress) { $RemoteAddress = [string]$req.remoteAddress }
    if ($reqNames -contains 'remotePort' -and $req.remotePort) { $RemotePort = [int]$req.remotePort }
    if ($reqNames -contains 'sessionToken' -and $req.sessionToken) { $SessionToken = [string]$req.sessionToken }
    if ($reqNames -contains 'confirmPhrase' -and $req.confirmPhrase) { $ConfirmPhrase = [string]$req.confirmPhrase }
    if ($reqNames -contains 'dryRun' -and $req.dryRun) { $DryRun = $true }
    if ($reqNames -contains 'understandRisk' -and $req.understandRisk) { $IUnderstandRisk = $true }
}

if (-not $Action) { throw 'Action is required.' }

. (Join-Path $scriptDir 'hub-common.ps1')
. (Join-Path $scriptDir 'lib\operator-auth.ps1')
. (Join-Path $scriptDir 'lib\hub-core-routing.ps1')
. (Join-Path $scriptDir 'lib\hub-decision-log.ps1')

if (-not $IUnderstandRisk) {
    $IUnderstandRisk = $true
}

if (-not $SkipAuth) {
    if (-not (Test-OperatorHitlSession -SessionToken $SessionToken)) {
        throw 'HITL session expired or missing - unlock Control panel first.'
    }
}

if (-not $OutputJson) {
    $OutputJson = Join-Path $HubRoot 'logs\network-action-latest.json'
}
$dir = Split-Path -Parent $OutputJson
if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }

$cliArgs = @(
    'network', 'action',
    '--action', $Action,
    '--pid', [string]$ProcessId,
    '--process-name', $ProcessName,
    '--local-address', $LocalAddress,
    '--local-port', [string]$LocalPort,
    '--remote-address', $RemoteAddress,
    '--remote-port', [string]$RemotePort,
    '--output', $OutputJson
)
if ($DryRun) { $cliArgs += '--dry-run' }
if ($IUnderstandRisk) { $cliArgs += '--understand-risk' }
if ($ConfirmPhrase) { $cliArgs += @('--confirm-phrase', $ConfirmPhrase) }
if ($SkipAuth) { $cliArgs += '--skip-auth' }
elseif ($SessionToken) { $cliArgs += @('--session-token', $SessionToken) }

$ec = Invoke-HubCoreCli -HubRoot $HubRoot -CliArgs $cliArgs -BuildFirst
if ($ec -ne 0 -and -not (Test-Path -LiteralPath $OutputJson)) {
    throw "network action CLI failed exit=$ec"
}

$result = Get-Content -LiteralPath $OutputJson -Raw | ConvertFrom-Json
$success = [string]$result.Outcome -notin @('AuthRequired', 'RiskAckRequired', 'ConfirmPhraseRequired', 'BlockDenied', 'InvalidTarget', 'UnsupportedAction')

$actionContext = @{
    Action   = [string]$Action
    Remote   = [string]$RemoteAddress
    DryRun   = [bool]$DryRun
    Outcome  = [string]$result.Outcome
}
Write-HubDecisionLog -HubRoot $HubRoot -Domain 'network-action' -Path 'core' `
    -Action $Action -Outcome ([string]$result.Outcome) -Success:$success -Context $actionContext

if (-not $Quiet) {
    Write-Host ("Network action={0} outcome={1}" -f $Action, $result.Outcome)
}

if (-not $success) { exit 1 }
$result
