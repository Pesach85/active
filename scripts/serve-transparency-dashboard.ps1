[CmdletBinding()]
param(
    [string]$ConfigPath = '',
    [int]$Port = 0,
    [string]$BindAddress = '',
    [switch]$BuildReportFirst,
    [switch]$OpenBrowser,
    [string]$LogPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$hubRoot = Split-Path -Parent $scriptDir
. (Join-Path $scriptDir 'hub-common.ps1')

$hub = Get-HubPaths -HubRoot $hubRoot
if (-not $ConfigPath) { $ConfigPath = $hub.ConfigFile }
$config = Get-MaintenanceConfig -ConfigPath $ConfigPath

$transparency = $null
if ($config -is [hashtable]) { $transparency = $config['Transparency'] }
elseif ($config.Transparency) { $transparency = $config.Transparency }

$webCfg = $null
if ($transparency) {
    $webCfg = if ($transparency -is [hashtable]) { $transparency['WebDashboard'] } else { $transparency.WebDashboard }
}

if (-not $BindAddress) {
    $BindAddress = '127.0.0.1'
    if ($webCfg) {
        $ba = if ($webCfg -is [hashtable]) { $webCfg['BindAddress'] } else { $webCfg.BindAddress }
        if ($ba) { $BindAddress = [string]$ba }
    }
}

if ($Port -le 0) {
    $Port = 8765
    if ($webCfg) {
        $p = if ($webCfg -is [hashtable]) { $webCfg['Port'] } else { $webCfg.Port }
        if ($p) { $Port = [int]$p }
    }
}

$webRoot = Join-Path $hub.HubRoot 'web\transparency'
if (-not (Test-Path -LiteralPath $webRoot)) {
    $webRoot = Join-Path $hubRoot 'web\transparency'
}

$reportRel = 'logs/transparency-report-latest.json'
if ($transparency) {
    $rp = if ($transparency -is [hashtable]) { $transparency['ReportOutputPath'] } else { $transparency.ReportOutputPath }
    if ($rp) { $reportRel = [string]$rp }
}
$reportPath = Resolve-HubPath -HubRoot $hub.HubRoot -Path $reportRel

if (-not $LogPath) {
    $LogPath = Join-Path $hub.Logs 'transparency-web.log'
}

function Write-WebLog {
    param([string]$Message)
    $line = ('{0} {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Message)
    try {
        $dir = Split-Path -Parent $LogPath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
        $line | Out-File -LiteralPath $LogPath -Encoding utf8 -Append
    } catch { }
    Write-Host $line
}

if (-not (Test-Path -LiteralPath $webRoot)) {
    throw "Web root not found: $webRoot"
}

$prefix = "http://${BindAddress}:${Port}/"

function Test-PortInUse {
    param([string]$Address, [int]$ListenPort)
    try {
        $existing = Get-NetTCPConnection -LocalAddress $Address -LocalPort $ListenPort -State Listen -ErrorAction Stop
        return ($null -ne $existing)
    } catch {
        return $false
    }
}

if (Test-PortInUse -Address $BindAddress -ListenPort $Port) {
    Write-WebLog "Port $Port already listening — reusing existing dashboard."
    if ($OpenBrowser) { Start-Process $prefix | Out-Null }
    exit 0
}

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($prefix)

function Send-Response {
    param(
        [System.Net.HttpListenerContext]$Context,
        [int]$StatusCode = 200,
        [string]$ContentType = 'text/plain; charset=utf-8',
        [byte[]]$BodyBytes,
        [hashtable]$ExtraHeaders = @{}
    )

    $response = $Context.Response
    $response.StatusCode = $StatusCode
    $response.ContentType = $ContentType
    foreach ($key in $ExtraHeaders.Keys) {
        $response.Headers[$key] = [string]$ExtraHeaders[$key]
    }
    if ($BodyBytes) {
        $response.ContentLength64 = $BodyBytes.Length
        $response.OutputStream.Write($BodyBytes, 0, $BodyBytes.Length)
    }
    $response.OutputStream.Close()
}

function Get-ContentType {
    param([string]$Path)
    switch ([IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '.html' { return 'text/html; charset=utf-8' }
        '.css' { return 'text/css; charset=utf-8' }
        '.js' { return 'application/javascript; charset=utf-8' }
        '.json' { return 'application/json; charset=utf-8' }
        '.svg' { return 'image/svg+xml' }
        default { return 'application/octet-stream' }
    }
}

try {
    $listener.Start()
} catch {
    Write-WebLog ("FAILED to bind {0}: {1}" -f $prefix, $_.Exception.Message)
    throw
}

Write-WebLog "Listening on $prefix (localhost only). Press Ctrl+C to stop."

if ($OpenBrowser) {
    Start-Process $prefix | Out-Null
}

if ($BuildReportFirst) {
    $buildScript = Join-Path $scriptDir 'build-transparency-report.ps1'
    Start-Job -Name 'TransparencyReportWarmup' -ScriptBlock {
        param($Script, $Cfg, $Out)
        & $Script -ConfigPath $Cfg -OutputJson $Out | Out-Null
    } -ArgumentList $buildScript, $ConfigPath, $reportPath | Out-Null
    Write-WebLog 'Background report warmup started.'
}

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $path = $context.Request.Url.LocalPath
        if ($path -eq '/') { $path = '/index.html' }

        if ($path -eq '/api/report.json') {
            if (-not (Test-Path -LiteralPath $reportPath)) {
                & (Join-Path $scriptDir 'build-transparency-report.ps1') -ConfigPath $ConfigPath -OutputJson $reportPath | Out-Null
            }
            if (Test-Path -LiteralPath $reportPath) {
                $json = [System.Text.Encoding]::UTF8.GetBytes((Get-Content -LiteralPath $reportPath -Raw))
                Send-Response -Context $context -ContentType 'application/json; charset=utf-8' -BodyBytes $json `
                    -ExtraHeaders @{ 'Cache-Control' = 'no-store' }
            } else {
                $err = [System.Text.Encoding]::UTF8.GetBytes('{"error":"report not available"}')
                Send-Response -Context $context -StatusCode 503 -ContentType 'application/json' -BodyBytes $err
            }
            continue
        }

        if ($path -eq '/api/refresh') {
            & (Join-Path $scriptDir 'build-transparency-report.ps1') -ConfigPath $ConfigPath -OutputJson $reportPath | Out-Null
            $ok = [System.Text.Encoding]::UTF8.GetBytes('{"status":"ok"}')
            Send-Response -Context $context -ContentType 'application/json' -BodyBytes $ok
            continue
        }

        if ($path -eq '/api/health') {
            $ok = [System.Text.Encoding]::UTF8.GetBytes('{"status":"ok","listening":true}')
            Send-Response -Context $context -ContentType 'application/json' -BodyBytes $ok
            continue
        }

        $safePath = $path.TrimStart('/').Replace('/', [IO.Path]::DirectorySeparatorChar)
        $filePath = Join-Path $webRoot $safePath
        $fullWeb = [IO.Path]::GetFullPath($webRoot)
        $fullFile = [IO.Path]::GetFullPath($filePath)
        if (-not $fullFile.StartsWith($fullWeb, [StringComparison]::OrdinalIgnoreCase)) {
            Send-Response -Context $context -StatusCode 403 -BodyBytes ([System.Text.Encoding]::UTF8.GetBytes('Forbidden'))
            continue
        }

        if (Test-Path -LiteralPath $fullFile -PathType Leaf) {
            $bytes = [IO.File]::ReadAllBytes($fullFile)
            Send-Response -Context $context -ContentType (Get-ContentType $fullFile) -BodyBytes $bytes
        } else {
            Send-Response -Context $context -StatusCode 404 -BodyBytes ([System.Text.Encoding]::UTF8.GetBytes('Not found'))
        }
    }
} catch {
    Write-WebLog ("Server loop error: {0}" -f $_.Exception.Message)
    throw
} finally {
    if ($listener.IsListening) { $listener.Stop() }
    $listener.Close()
}
