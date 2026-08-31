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
        return @{ Ok = $true; Skipped = $true; Identity = (Get-OperatorWindowsIdentity) }
    }
    if (-not (Test-OperatorWindowsPassword -Password $Password)) {
        throw 'Windows password verification failed - action blocked.'
    }
    return @{ Ok = $true; Skipped = $false; Identity = (Get-OperatorWindowsIdentity) }
}

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
