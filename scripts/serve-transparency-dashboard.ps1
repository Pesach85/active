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
    $existingHealthy = $false
    try {
        $healthCheck = Invoke-WebRequest -Uri "${prefix}api/health" -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
        $existingHealthy = ($healthCheck.StatusCode -eq 200)
    } catch { }
    if ($existingHealthy) {
        Write-WebLog "Port $Port already serving hub dashboard — reusing."
        if ($OpenBrowser) { Start-Process $prefix | Out-Null }
        exit 0
    }
    Write-WebLog "Port $Port occupied but not hub health — attempting bind anyway."
}

$pidFile = Join-Path $hub.Logs 'transparency-web.pid'

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

function Read-RequestBodyJson {
    param([System.Net.HttpListenerContext]$Context)

    $encoding = $Context.Request.ContentEncoding
    if (-not $encoding) {
        $encoding = [System.Text.UTF8Encoding]::new($false)
    }
    $reader = New-Object System.IO.StreamReader($Context.Request.InputStream, $encoding)
    try {
        $raw = $reader.ReadToEnd()
    } finally {
        $reader.Dispose()
    }
    if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
    return ($raw | ConvertFrom-Json)
}

function Get-BodyProperty {
    param(
        $Body,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($null -eq $Body) { return $null }
    if ($Body.PSObject.Properties[$Name]) { return $Body.$Name }
    return $null
}

function Send-JsonResponse {
    param(
        [System.Net.HttpListenerContext]$Context,
        [object]$Payload,
        [int]$StatusCode = 200
    )
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($Payload | ConvertTo-Json -Depth 14 -Compress))
    Send-Response -Context $Context -StatusCode $StatusCode -ContentType 'application/json; charset=utf-8' -BodyBytes $bytes `
        -ExtraHeaders @{ 'Cache-Control' = 'no-store' }
}

$resolveScript = Join-Path $scriptDir 'resolve-unknown-process.ps1'
$identifyScript = Join-Path $scriptDir 'identify-unknown-process.ps1'
$pwshExe = Get-HubPwshExecutable

function Invoke-HubProcessScript {
    param(
        [string]$ScriptPath,
        [string[]]$ArgumentList
    )
    $tmpOut = Join-Path $hub.Logs ("web-api-{0}.json" -f ([guid]::NewGuid().ToString('N')))
    $errLog = Join-Path $hub.Logs ("web-api-{0}.err" -f ([guid]::NewGuid().ToString('N')))
    . (Join-Path $scriptDir 'lib\operator-auth.ps1')
    $resolved = Resolve-HubProcessScriptArguments -ArgumentList $ArgumentList -LogsDir $hub.Logs
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + $resolved.ArgumentList + @('-OutputJson', $tmpOut, '-Quiet')
    try {
        $proc = Start-Process -FilePath $pwshExe -ArgumentList $args -Wait -PassThru -WindowStyle Hidden `
            -RedirectStandardError $errLog -WorkingDirectory $hubRoot
        $payload = $null
        if (Test-Path -LiteralPath $tmpOut) {
            try { $payload = Get-Content -LiteralPath $tmpOut -Raw | ConvertFrom-Json } catch { }
            Remove-Item -LiteralPath $tmpOut -Force -ErrorAction SilentlyContinue
        }
        $stderr = ''
        if (Test-Path -LiteralPath $errLog) {
            $rawErr = Get-Content -LiteralPath $errLog -Raw -ErrorAction SilentlyContinue
            if ($null -ne $rawErr) { $stderr = $rawErr.Trim() }
            Remove-Item -LiteralPath $errLog -Force -ErrorAction SilentlyContinue
        }
        return @{ ExitCode = $proc.ExitCode; Payload = $payload; Stderr = $stderr }
    } finally {
        Clear-OperatorPasswordFile -PasswordFile $resolved.PasswordFile
    }
}

try {
    $listener.Start()
} catch {
    Write-WebLog ("FAILED to bind {0}: {1}" -f $prefix, $_.Exception.Message)
    throw
}

Write-WebLog "Listening on $prefix (localhost only). Press Ctrl+C to stop."
try { $PID | Out-File -LiteralPath $pidFile -Encoding ascii -Force } catch { }

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
        $context = $null
        $path = ''
        try {
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

        if ($context.Request.HttpMethod -eq 'POST' -and $path -eq '/api/network/deep-scan') {
            $scanScript = Join-Path $scriptDir 'scan-network-deep.ps1'
            $scanOut = Join-Path $hub.Logs 'network-deep-scan-latest.json'
            try {
                & $scanScript -HubRoot $hubRoot -OutputJson $scanOut -IncludeMemoryScan -Quiet | Out-Null
                if (-not (Test-Path -LiteralPath $scanOut)) { throw 'scan_output_missing' }
                $payload = Get-Content -LiteralPath $scanOut -Raw | ConvertFrom-Json
                Send-JsonResponse -Context $context -Payload $payload
            } catch {
                Send-JsonResponse -Context $context -StatusCode 500 -Payload @{
                    error = 'deep_scan_failed'
                    message = $_.Exception.Message
                }
            }
            continue
        }

        if ($context.Request.HttpMethod -eq 'GET' -and $path -eq '/api/network/deep-scan/latest') {
            $scanOut = Join-Path $hub.Logs 'network-deep-scan-latest.json'
            if (-not (Test-Path -LiteralPath $scanOut)) {
                Send-JsonResponse -Context $context -StatusCode 404 -Payload @{ error = 'no_scan_yet' }
            } else {
                $payload = Get-Content -LiteralPath $scanOut -Raw | ConvertFrom-Json
                Send-JsonResponse -Context $context -Payload $payload
            }
            continue
        }

        if ($context.Request.HttpMethod -eq 'POST' -and $path -eq '/api/network/action') {
            $body = Read-RequestBodyJson -Context $context
            $action = [string]$body.action
            if (-not $action) {
                Send-JsonResponse -Context $context -StatusCode 400 -Payload @{ error = 'action_required' }
                continue
            }
            $sessionToken = Get-BodyProperty $body 'sessionToken'
            $password = Get-BodyProperty $body 'password'
            if (-not $sessionToken -and -not $password) {
                Send-JsonResponse -Context $context -StatusCode 401 -Payload @{ error = 'session_required' }
                continue
            }
            . (Join-Path $scriptDir 'lib\operator-auth.ps1')
            $netActionScript = Join-Path $scriptDir 'apply-network-action.ps1'
            $run = Invoke-HubProcessScriptViaRequest -ScriptPath $netActionScript -RequestBody $body `
                -LogsDir $hub.Logs -PwshExe $pwshExe -HubRoot $hubRoot
            if ($run.ExitCode -ne 0) {
                $msg = $null
                if ($run.Payload -and $run.Payload.Message) { $msg = [string]$run.Payload.Message }
                elseif ($run.Stderr) { $msg = [string]$run.Stderr }
                Send-JsonResponse -Context $context -StatusCode 403 -Payload @{
                    error = if ($msg -match 'session expired|password verification failed') { 'auth_failed' } else { 'action_failed' }
                    exitCode = $run.ExitCode
                    message = $msg
                    result = $run.Payload
                }
            } else {
                Send-JsonResponse -Context $context -Payload $run.Payload
            }
            continue
        }

        if ($path -eq '/api/health') {
            $ok = [System.Text.Encoding]::UTF8.GetBytes('{"status":"ok","listening":true}')
            Send-Response -Context $context -ContentType 'application/json' -BodyBytes $ok
            continue
        }

        if ($context.Request.HttpMethod -eq 'POST' -and $path -eq '/api/process/advisory') {
            $body = Read-RequestBodyJson -Context $context
            $reqBody = @{
                action = 'Advisory'
                offline = $true
            }
            if ($body -and $body.PSObject.Properties['processId']) { $reqBody.processId = [int]$body.processId }
            if ($body -and $body.PSObject.Properties['processName']) { $reqBody.processName = [string]$body.processName }
            . (Join-Path $scriptDir 'lib\operator-auth.ps1')
            $run = Invoke-HubProcessScriptViaRequest -ScriptPath $resolveScript -RequestBody $reqBody `
                -LogsDir $hub.Logs -PwshExe $pwshExe -HubRoot $hubRoot
            if ($run.ExitCode -ne 0 -or -not $run.Payload) {
                $msg = if ($run.Stderr) { [string]$run.Stderr } else { 'advisory_failed' }
                Send-JsonResponse -Context $context -StatusCode 400 -Payload @{
                    error = 'advisory_failed'
                    exitCode = $run.ExitCode
                    message = $msg
                }
            } else {
                Send-JsonResponse -Context $context -Payload $run.Payload
            }
            continue
        }

        if ($context.Request.HttpMethod -eq 'POST' -and $path -eq '/api/operator/session/start') {
            $body = Read-RequestBodyJson -Context $context
            . (Join-Path $scriptDir 'lib\operator-auth.ps1')
            try {
                $env:HUB_ROOT = $hubRoot
                $env:HUB_DECISION_PATH = 'web'
                $password = Get-BodyProperty $body 'password'
                if (-not $password) { throw 'password_required' }
                $sess = Start-OperatorHitlSession -Password ([string]$password) -RiskAcknowledged -HumanPresent
                Send-JsonResponse -Context $context -Payload @{
                    ok = $true
                    sessionToken = [string]$sess.Token
                    expiresAt = $sess.ExpiresAt.ToString('o')
                }
            } catch {
                Send-JsonResponse -Context $context -StatusCode 401 -Payload @{ error = 'session_start_failed'; message = $_.Exception.Message }
            }
            continue
        }

        if ($context.Request.HttpMethod -eq 'GET' -and $path -eq '/api/operator/session/status') {
            . (Join-Path $scriptDir 'lib\operator-auth.ps1')
            $token = [string]$context.Request.QueryString['token']
            $active = Test-OperatorHitlSession -SessionToken $token
            $sess = Get-OperatorHitlSession
            Send-JsonResponse -Context $context -Payload @{
                active = $active
                expiresAt = if ($sess) { $sess.ExpiresAt.ToString('o') } else { $null }
            }
            continue
        }

        if ($context.Request.HttpMethod -eq 'POST' -and $path -eq '/api/process/action') {
            $body = Read-RequestBodyJson -Context $context
            $action = [string]$body.action
            if (-not $action) {
                Send-JsonResponse -Context $context -StatusCode 400 -Payload @{ error = 'action_required' }
                continue
            }
            $sessionToken = Get-BodyProperty $body 'sessionToken'
            $password = Get-BodyProperty $body 'password'
            if (-not $sessionToken -and -not $password) {
                Send-JsonResponse -Context $context -StatusCode 401 -Payload @{ error = 'session_required' }
                continue
            }
            . (Join-Path $scriptDir 'lib\operator-auth.ps1')
            $run = Invoke-HubProcessScriptViaRequest -ScriptPath $resolveScript -RequestBody $body `
                -LogsDir $hub.Logs -PwshExe $pwshExe -HubRoot $hubRoot
            if ($run.ExitCode -ne 0) {
                $msg = $null
                if ($run.Payload -and $run.Payload.Message) { $msg = [string]$run.Payload.Message }
                elseif ($run.Stderr) { $msg = [string]$run.Stderr }
                Send-JsonResponse -Context $context -StatusCode 403 -Payload @{
                    error = if ($msg -match 'session expired|password verification failed') { 'auth_failed' } else { 'action_failed' }
                    exitCode = $run.ExitCode
                    message = $msg
                    result = $run.Payload
                }
            } else {
                Send-JsonResponse -Context $context -Payload $run.Payload
            }
            continue
        }

        if ($context.Request.HttpMethod -eq 'POST' -and $path -eq '/api/process/identify') {
            $body = Read-RequestBodyJson -Context $context
            if (-not $body.whatItIs -or -not $body.whatItDoes) {
                Send-JsonResponse -Context $context -StatusCode 400 -Payload @{ error = 'whatItIs_and_whatItDoes_required' }
                continue
            }
            $sessionToken = Get-BodyProperty $body 'sessionToken'
            $password = Get-BodyProperty $body 'password'
            if (-not $sessionToken -and -not $password) {
                Send-JsonResponse -Context $context -StatusCode 401 -Payload @{ error = 'session_required' }
                continue
            }
            . (Join-Path $scriptDir 'lib\operator-auth.ps1')
            $run = Invoke-HubProcessScriptViaRequest -ScriptPath $identifyScript -RequestBody $body `
                -LogsDir $hub.Logs -PwshExe $pwshExe -HubRoot $hubRoot
            if ($run.ExitCode -ne 0) {
                $msg = $null
                if ($run.Payload -and $run.Payload.Message) { $msg = [string]$run.Payload.Message }
                elseif ($run.Stderr) { $msg = [string]$run.Stderr }
                Send-JsonResponse -Context $context -StatusCode 403 -Payload @{
                    error = if ($msg -match 'password verification failed') { 'auth_failed' } else { 'identify_failed' }
                    exitCode = $run.ExitCode
                    message = $msg
                    result = $run.Payload
                }
            } else {
                Send-JsonResponse -Context $context -Payload $run.Payload
            }
            continue
        }

        if ($context.Request.HttpMethod -eq 'POST' -and $path -eq '/api/process/forensics') {
            $body = Read-RequestBodyJson -Context $context
            try {
                . (Join-Path $scriptDir 'lib\process-forensics.ps1')
                $fp = Get-ProcessForensicProfile `
                    -ProcessId ([int]$body.processId) `
                    -ProcessName ([string]$body.processName) `
                    -HubRoot $hubRoot `
                    -Deep `
                    -IncludeMemory:($false)
                Send-JsonResponse -Context $context -Payload $fp
            } catch {
                Write-WebLog ("Forensics error: {0}" -f $_.Exception.Message)
                Send-JsonResponse -Context $context -StatusCode 500 -Payload @{
                    error = 'forensics_failed'
                    message = $_.Exception.Message
                }
            }
            continue
        }

        if ($context.Request.HttpMethod -eq 'GET' -and $path -eq '/api/operator-identity') {
            . (Join-Path $scriptDir 'lib\operator-auth.ps1')
            Send-JsonResponse -Context $context -Payload (Get-OperatorWindowsIdentity)
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
        } catch {
            Write-WebLog ("Request error [{0}]: {1}" -f $path, $_.Exception.Message)
            if ($context) {
                try {
                    Send-JsonResponse -Context $context -StatusCode 500 -Payload @{
                        error = 'request_failed'
                        message = $_.Exception.Message
                    }
                } catch { }
            }
        }
    }
} catch {
    Write-WebLog ("Server loop error: {0}" -f $_.Exception.Message)
    throw
} finally {
    if ($listener.IsListening) { $listener.Stop() }
    $listener.Close()
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
}

