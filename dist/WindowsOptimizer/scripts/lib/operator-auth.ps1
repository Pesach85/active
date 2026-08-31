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
        throw 'Windows password verification failed — action blocked.'
    }
    return @{ Ok = $true; Skipped = $false; Identity = (Get-OperatorWindowsIdentity) }
}
