[CmdletBinding()]
param(
    [string]$ConfigPath = '',
    [int]$Port = 8765,
    [string]$BindAddress = '127.0.0.1',
    [int]$WaitSec = 25,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$hubRoot = Split-Path -Parent $scriptDir
. (Join-Path $scriptDir 'hub-common.ps1')

$hub = Get-HubPaths -HubRoot $hubRoot
if (-not $ConfigPath) { $ConfigPath = $hub.ConfigFile }

$healthUrl = "http://${BindAddress}:${Port}/api/health"
$serveScript = Join-Path $scriptDir 'serve-transparency-dashboard.ps1'
$stdoutLog = Join-Path $hub.Logs 'transparency-web.log'
$stderrLog = Join-Path $hub.Logs 'transparency-web.err.log'
$pidFile = Join-Path $hub.Logs 'transparency-web.pid'

function Test-TransparencyWebHealthy {
    try {
        $resp = Invoke-WebRequest -Uri $healthUrl -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
        return ($resp.StatusCode -eq 200)
    } catch {
        return $false
    }
}

function Test-PortListening {
    param([string]$Address, [int]$ListenPort)
    try {
        $hit = Get-NetTCPConnection -LocalAddress $Address -LocalPort $ListenPort -State Listen -ErrorAction Stop
        return ($null -ne $hit)
    } catch {
        return $false
    }
}

function Stop-StaleTransparencyWeb {
    if (-not (Test-Path -LiteralPath $pidFile)) { return }
    try {
        $oldPid = [int](Get-Content -LiteralPath $pidFile -Raw).Trim()
        if ($oldPid -gt 0) {
            $proc = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
            if ($proc -and -not $proc.HasExited) {
                if (Test-TransparencyWebHealthy) { return }
                Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 400
            }
        }
    } catch { }
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
}

$result = [ordered]@{
    SchemaVersion = 'TransparencyWebEnsure.v1'
    GeneratedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Url = "http://${BindAddress}:${Port}/"
    HealthUrl = $healthUrl
    Status = 'Unknown'
    Message = ''
    Pid = 0
}

function Save-TransparencyWebPid {
    param([int]$WebPid)
    if ($WebPid -le 0) { return }
    try {
        $dir = Split-Path -Parent $pidFile
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
        [string]$WebPid | Out-File -LiteralPath $pidFile -Encoding ascii -Force
    } catch { }
}

if (Test-TransparencyWebHealthy) {
    $result.Status = 'AlreadyRunning'
    $result.Message = 'Dashboard already healthy.'
    if (Test-Path -LiteralPath $pidFile) {
        try { $result.Pid = [int](Get-Content -LiteralPath $pidFile -Raw).Trim() } catch { }
    }
    if ($result.Pid -le 0) {
        try {
            $owner = Get-NetTCPConnection -LocalAddress $BindAddress -LocalPort $Port -State Listen -ErrorAction Stop | Select-Object -First 1
            if ($owner) { $result.Pid = [int]$owner.OwningProcess; Save-TransparencyWebPid -WebPid $result.Pid }
        } catch { }
    }
    if (-not $Quiet) { Write-Host $result.Message }
    $result | ConvertTo-Json -Depth 4
    exit 0
}

if (Test-PortListening -Address $BindAddress -ListenPort $Port) {
    Stop-StaleTransparencyWeb
    if (Test-TransparencyWebHealthy) {
        $result.Status = 'AlreadyRunning'
        $result.Message = 'Recovered existing listener.'
        if (-not $Quiet) { Write-Host $result.Message }
        $result | ConvertTo-Json -Depth 4
        exit 0
    }
}

$pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Path
if (-not $pwsh) { $pwsh = (Get-Command powershell).Path }

$logDir = Split-Path -Parent $stdoutLog
if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
    New-Item -Path $logDir -ItemType Directory -Force | Out-Null
}

$args = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $serveScript,
    '-ConfigPath', $ConfigPath,
    '-Port', "$Port",
    '-BindAddress', $BindAddress,
    '-LogPath', $stdoutLog
)

$proc = Start-Process -FilePath $pwsh -ArgumentList $args -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog

$deadline = (Get-Date).AddSeconds($WaitSec)
while ((Get-Date) -lt $deadline) {
    if ($proc.HasExited) { break }
    if (Test-TransparencyWebHealthy) {
        $result.Status = 'Started'
        $result.Pid = $proc.Id
        Save-TransparencyWebPid -WebPid $proc.Id
        $result.Message = "Dashboard ready at $($result.Url)"
        if (-not $Quiet) { Write-Host $result.Message }
        $result | ConvertTo-Json -Depth 4
        exit 0
    }
    Start-Sleep -Milliseconds 350
}

$tail = ''
if (Test-Path -LiteralPath $stderrLog) {
    $tail = (Get-Content -LiteralPath $stderrLog -Tail 8 -ErrorAction SilentlyContinue) -join [Environment]::NewLine
}
if (-not $tail -and (Test-Path -LiteralPath $stdoutLog)) {
    $tail = (Get-Content -LiteralPath $stdoutLog -Tail 8 -ErrorAction SilentlyContinue) -join [Environment]::NewLine
}

$result.Status = 'Failed'
$result.Pid = if ($proc -and -not $proc.HasExited) { $proc.Id } else { 0 }
$result.Message = "Dashboard did not respond on port $Port within ${WaitSec}s."
if ($tail) { $result.Message += " Log: $tail" }

if (-not $Quiet) { Write-Error $result.Message }
$result | ConvertTo-Json -Depth 4
exit 1
