# Windows password confirmation for HITL operator actions (local user).

function Get-OperatorWindowsIdentity {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $name = $id.Name
    $user = [Environment]::UserName
    $domain = $env:USERDOMAIN
    if ($name -match '^(.+)\\(.+)$') {
        $domain = $Matches[1]
        $user = $Matches[2]
    }
    return [ordered]@{
        FullName = [string]$name
        UserName = [string]$user
        Domain = [string]$domain
        IsAdmin = if (Get-Command Test-HubAdmin -ErrorAction SilentlyContinue) { (Test-HubAdmin) } else { $false }
    }
}

function Initialize-OperatorLogonValidator {
    if ('HubOperatorLogonValidator' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class HubOperatorLogonValidator
{
    const int LOGON32_LOGON_INTERACTIVE = 2;
    const int LOGON32_PROVIDER_DEFAULT = 0;

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool LogonUser(string lpszUsername, string lpszDomain, string lpszPassword,
        int dwLogonType, int dwLogonProvider, out IntPtr phToken);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr hObject);

    public static bool Validate(string domain, string user, string password)
    {
        IntPtr token = IntPtr.Zero;
        try
        {
            if (string.IsNullOrWhiteSpace(user) || string.IsNullOrEmpty(password)) return false;
            string d = string.IsNullOrWhiteSpace(domain) ? "." : domain;
            if (!LogonUser(user, d, password, LOGON32_LOGON_INTERACTIVE, LOGON32_PROVIDER_DEFAULT, out token))
                return false;
            return token != IntPtr.Zero;
        }
        finally
        {
            if (token != IntPtr.Zero) CloseHandle(token);
        }
    }
}
'@ -ErrorAction Stop
}

function Get-OperatorPasswordFromParam {
    param(
        [string]$Password = '',
        [string]$PasswordFile = ''
    )

    if ($PasswordFile -and (Test-Path -LiteralPath $PasswordFile)) {
        try {
            return (Get-Content -LiteralPath $PasswordFile -Raw -ErrorAction Stop).Trim()
        } catch { }
    }
    return [string]$Password
}

function Clear-OperatorPasswordFile {
    param([string]$PasswordFile)
    if ($PasswordFile -and (Test-Path -LiteralPath $PasswordFile)) {
        Remove-Item -LiteralPath $PasswordFile -Force -ErrorAction SilentlyContinue
    }
}

function Test-OperatorWindowsPassword {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Password,
        [string]$UserName = '',
        [string]$Domain = ''
    )

    if ([string]::IsNullOrWhiteSpace($Password)) { return $false }

    $identity = Get-OperatorWindowsIdentity
    if (-not $UserName) { $UserName = [string]$identity.UserName }
    if (-not $Domain) { $Domain = [string]$identity.Domain }

    try {
        Add-Type -AssemblyName System.DirectoryServices.AccountManagement -ErrorAction Stop
        $contexts = @(
            @{ Type = [System.DirectoryServices.AccountManagement.ContextType]::Machine; Name = $null },
            @{ Type = [System.DirectoryServices.AccountManagement.ContextType]::Domain; Name = $Domain }
        )
        foreach ($ctxInfo in $contexts) {
            try {
                $ctx = if ($ctxInfo.Name) {
                    New-Object System.DirectoryServices.AccountManagement.PrincipalContext($ctxInfo.Type, $ctxInfo.Name)
                } else {
                    New-Object System.DirectoryServices.AccountManagement.PrincipalContext($ctxInfo.Type)
                }
                if ($ctx.ValidateCredentials($UserName, $Password)) {
                    return $true
                }
            } catch { }
        }
    } catch { }

    try {
        Initialize-OperatorLogonValidator
        $domainsToTry = @($Domain, $env:COMPUTERNAME, '.')
        foreach ($d in @($domainsToTry | Select-Object -Unique)) {
            if ([HubOperatorLogonValidator]::Validate([string]$d, $UserName, $Password)) {
                return $true
            }
        }
    } catch { }

    return $false
}

function Assert-OperatorWindowsPassword {
    param(
        [string]$Password,
        [switch]$SkipAuth
    )

    if ($SkipAuth) {
        return @{ Ok = $true; Skipped = $true; Identity = (Get-OperatorWindowsIdentity); Via = 'skip' }
    }
    if (-not (Test-OperatorWindowsPassword -Password $Password)) {
        throw 'Windows password verification failed - action blocked.'
    }
    return @{ Ok = $true; Skipped = $false; Identity = (Get-OperatorWindowsIdentity); Via = 'password' }
}

# --- HITL session: one human + risk acknowledgment at panel unlock; no password per action. ---

function Get-OperatorHitlSessionFilePath {
    param([string]$HubRoot = '')
    if (-not $HubRoot) { $HubRoot = $env:HUB_ROOT }
    if (-not $HubRoot) {
        $libDir = $PSScriptRoot
        $HubRoot = Split-Path (Split-Path -Parent $libDir) -Parent
    }
    $logsDir = Join-Path $HubRoot 'logs'
    if (-not (Test-Path -LiteralPath $logsDir)) {
        New-Item -Path $logsDir -ItemType Directory -Force | Out-Null
    }
    return Join-Path $logsDir '.hub-hitl-session.json'
}

function Read-OperatorHitlSessionFromFile {
    param(
        [string]$SessionToken = '',
        [string]$HubRoot = ''
    )
    $path = Get-OperatorHitlSessionFilePath -HubRoot $HubRoot
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json
    } catch {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        return $null
    }
    $expires = [datetime]$raw.ExpiresAt
    if ($expires -lt (Get-Date)) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        return $null
    }
    if ($SessionToken -and [string]$raw.Token -ne [string]$SessionToken) { return $null }
    return [pscustomobject]@{
        Token = [string]$raw.Token
        Identity = $raw.Identity
        StartedAt = [string]$raw.StartedAt
        ExpiresAt = $expires
        RiskAcknowledged = [bool]$raw.RiskAcknowledged
        HumanPresent = [bool]$raw.HumanPresent
        Skipped = [bool]$raw.Skipped
    }
}

function Write-OperatorHitlSessionToFile {
    param(
        $Session,
        [string]$HubRoot = ''
    )
    $path = Get-OperatorHitlSessionFilePath -HubRoot $HubRoot
    $expires = if ($Session.ExpiresAt -is [datetime]) {
        $Session.ExpiresAt.ToString('o')
    } else {
        [string]$Session.ExpiresAt
    }
    $toWrite = [ordered]@{
        Token = [string]$Session.Token
        Identity = $Session.Identity
        StartedAt = [string]$Session.StartedAt
        ExpiresAt = $expires
        RiskAcknowledged = [bool]$Session.RiskAcknowledged
        HumanPresent = [bool]$Session.HumanPresent
        Skipped = [bool]$Session.Skipped
    }
    ($toWrite | ConvertTo-Json -Depth 6) | Out-File -LiteralPath $path -Encoding utf8 -Force
}

function Remove-OperatorHitlSessionFile {
    param([string]$HubRoot = '')
    $path = Get-OperatorHitlSessionFilePath -HubRoot $HubRoot
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

function Get-OperatorHitlSessionConfig {
    return @{
        DurationMinutes = 45
    }
}

function Get-OperatorHitlSession {
    if (Get-Variable -Name HubOperatorHitlSession -Scope Global -ErrorAction SilentlyContinue) {
        $sess = $global:HubOperatorHitlSession
        if ($null -ne $sess) {
            if ($sess.ExpiresAt -lt (Get-Date)) {
                Clear-OperatorHitlSession | Out-Null
                return $null
            }
            return $sess
        }
    }
    $fileSess = Read-OperatorHitlSessionFromFile
    if ($fileSess) {
        Set-Variable -Name HubOperatorHitlSession -Scope Global -Value $fileSess -Force
        return $fileSess
    }
    return $null
}

function Test-OperatorHitlSession {
    param([string]$SessionToken = '')
    if ($SessionToken) {
        $fileSess = Read-OperatorHitlSessionFromFile -SessionToken $SessionToken
        if ($fileSess) { return $true }
    }
    $sess = Get-OperatorHitlSession
    if ($null -eq $sess) { return $false }
    if ($SessionToken -and [string]$sess.Token -ne [string]$SessionToken) { return $false }
    return $true
}

function Start-OperatorHitlSession {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Password,
        [switch]$RiskAcknowledged,
        [switch]$HumanPresent,
        [switch]$SkipAuth
    )

    if (-not $SkipAuth) {
        if (-not $RiskAcknowledged -or -not $HumanPresent) {
            throw 'HITL session requires human presence and risk acknowledgment.'
        }
        [void](Assert-OperatorWindowsPassword -Password $Password)
    }

    $cfg = Get-OperatorHitlSessionConfig
    $identity = Get-OperatorWindowsIdentity
    $token = [guid]::NewGuid().ToString('N')
    $sess = [ordered]@{
        Token = $token
        Identity = $identity
        StartedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        ExpiresAt = (Get-Date).AddMinutes([int]$cfg.DurationMinutes)
        RiskAcknowledged = [bool]$RiskAcknowledged
        HumanPresent = [bool]$HumanPresent
        Skipped = [bool]$SkipAuth
    }
    Set-Variable -Name HubOperatorHitlSession -Scope Global -Value ([pscustomobject]$sess) -Force
    Write-OperatorHitlSessionToFile -Session ([pscustomobject]$sess)
    if (Get-Command Write-HubDecisionLog -ErrorAction SilentlyContinue) {
        Write-HubDecisionLog -HubRoot $env:HUB_ROOT -Domain 'hitl-session' `
            -Path $(if ($env:HUB_DECISION_PATH) { $env:HUB_DECISION_PATH } else { 'ps' }) `
            -Action 'SessionStart' -Outcome 'Active' -Success $true `
            -Context @{ ExpiresAt = $sess.ExpiresAt.ToString('o'); Skipped = [bool]$SkipAuth }
    }
    return $sess
}

function Clear-OperatorHitlSession {
    Set-Variable -Name HubOperatorHitlSession -Scope Global -Value $null -Force
    Remove-OperatorHitlSessionFile
    if (Get-Command Write-HubDecisionLog -ErrorAction SilentlyContinue) {
        Write-HubDecisionLog -HubRoot $env:HUB_ROOT -Domain 'hitl-session' `
            -Path $(if ($env:HUB_DECISION_PATH) { $env:HUB_DECISION_PATH } else { 'ps' }) `
            -Action 'SessionEnd' -Outcome 'Cleared' -Success $true
    }
    return @{ Cleared = $true }
}

function Assert-OperatorAuth {
    param(
        [string]$Password = '',
        [string]$SessionToken = '',
        [switch]$SkipAuth
    )

    if ($SkipAuth) {
        return @{ Ok = $true; Skipped = $true; Identity = (Get-OperatorWindowsIdentity); Via = 'skip' }
    }
    if (Test-OperatorHitlSession -SessionToken $SessionToken) {
        $sess = Get-OperatorHitlSession
        return @{ Ok = $true; Skipped = $false; Identity = $sess.Identity; Via = 'session'; SessionToken = [string]$sess.Token }
    }
    if (-not [string]::IsNullOrWhiteSpace($Password)) {
        $r = Assert-OperatorWindowsPassword -Password $Password
        $r.Via = 'password'
        return $r
    }
    throw 'HITL session expired or missing. Unlock from HITL Paths panel first.'
}

$hubDecisionLogLib = Join-Path $PSScriptRoot 'hub-decision-log.ps1'
if (Test-Path -LiteralPath $hubDecisionLogLib) { . $hubDecisionLogLib }

function Resolve-HubProcessScriptArguments {
    param(
        [string[]]$ArgumentList,
        [string]$LogsDir
    )

    $out = [System.Collections.Generic.List[string]]::new()
    $passwordFile = $null
    $i = 0
    while ($i -lt $ArgumentList.Count) {
        $arg = [string]$ArgumentList[$i]
        if ($arg -in @('-WindowsPassword', '-Password') -and ($i + 1) -lt $ArgumentList.Count) {
            if (-not (Test-Path -LiteralPath $LogsDir)) {
                New-Item -Path $LogsDir -ItemType Directory -Force | Out-Null
            }
            $passwordFile = Join-Path $LogsDir (".hub-pwd-{0}.tmp" -f ([guid]::NewGuid().ToString('N')))
            [System.IO.File]::WriteAllText($passwordFile, [string]$ArgumentList[$i + 1])
            [void]$out.Add('-WindowsPasswordFile')
            [void]$out.Add($passwordFile)
            $i += 2
            continue
        }
        [void]$out.Add($arg)
        $i++
    }
    return @{ ArgumentList = @($out); PasswordFile = $passwordFile }
}

function Invoke-HubProcessScriptViaRequest {
    param(
        [string]$ScriptPath,
        [object]$RequestBody,
        [string]$LogsDir,
        [string]$PwshExe,
        [string]$HubRoot
    )

    if (-not (Test-Path -LiteralPath $LogsDir)) {
        New-Item -Path $LogsDir -ItemType Directory -Force | Out-Null
    }

    $reqPath = Join-Path $LogsDir (".hub-req-{0}.json" -f ([guid]::NewGuid().ToString('N')))
    $outPath = Join-Path $LogsDir (".hub-out-{0}.json" -f ([guid]::NewGuid().ToString('N')))
    $errPath = Join-Path $LogsDir (".hub-err-{0}.log" -f ([guid]::NewGuid().ToString('N')))

    try {
        ($RequestBody | ConvertTo-Json -Depth 8 -Compress) | Out-File -LiteralPath $reqPath -Encoding utf8 -Force
        $prevHubRoot = $env:HUB_ROOT
        $prevDecisionPath = $env:HUB_DECISION_PATH
        $env:HUB_ROOT = $HubRoot
        $env:HUB_DECISION_PATH = 'gui-subprocess'
        $args = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath,
            '-RequestJsonPath', $reqPath,
            '-OutputJson', $outPath,
            '-Quiet',
            '-HubRoot', $HubRoot
        )
        $proc = Start-Process -FilePath $PwshExe -ArgumentList $args -Wait -PassThru -WindowStyle Hidden `
            -RedirectStandardError $errPath -WorkingDirectory $HubRoot

        $payload = $null
        if (Test-Path -LiteralPath $outPath) {
            try { $payload = Get-Content -LiteralPath $outPath -Raw | ConvertFrom-Json } catch { }
            Remove-Item -LiteralPath $outPath -Force -ErrorAction SilentlyContinue
        }
        $stderr = ''
        if (Test-Path -LiteralPath $errPath) {
            $rawErr = Get-Content -LiteralPath $errPath -Raw -ErrorAction SilentlyContinue
            if ($null -ne $rawErr) { $stderr = $rawErr.Trim() }
            Remove-Item -LiteralPath $errPath -Force -ErrorAction SilentlyContinue
        }
        return @{ ExitCode = $proc.ExitCode; Payload = $payload; Stderr = $stderr }
    } finally {
        if ($null -ne $prevHubRoot) { $env:HUB_ROOT = $prevHubRoot } else { Remove-Item Env:HUB_ROOT -ErrorAction SilentlyContinue }
        if ($null -ne $prevDecisionPath) { $env:HUB_DECISION_PATH = $prevDecisionPath } else { Remove-Item Env:HUB_DECISION_PATH -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $reqPath -Force -ErrorAction SilentlyContinue
    }
}
