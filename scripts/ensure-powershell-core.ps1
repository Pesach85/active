[CmdletBinding()]
param(
    [switch]$InstallIfMissing,
    [switch]$UpdateMachinePath,
    [switch]$ApplyTasksCoreOnly,
    [string]$MonitorInstallerPath = "C:\\scripts\\install-monitor-task.ps1",
    [string]$CleanupInstallerPath = "C:\\scripts\\install-cleanup-task.ps1"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Find-PwshPath {
    $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Path
    }

    $candidates = @(
        "C:\\Program Files\\PowerShell\\7\\pwsh.exe",
        "C:\\Program Files\\PowerShell\\7-preview\\pwsh.exe"
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return $null
}

function Ensure-PathContainsPwshFolder {
    param(
        [string]$PwshPath,
        [ValidateSet("User", "Machine")]
        [string]$Target
    )

    $folder = Split-Path -Path $PwshPath -Parent
    $current = [Environment]::GetEnvironmentVariable("Path", $Target)
    if (-not $current) {
        $current = ""
    }

    $parts = @($current -split ";" | Where-Object { $_ -and $_.Trim() -ne "" })
    if ($parts -contains $folder) {
        return $false
    }

    $newPath = (($parts + $folder) -join ";").Trim(';')
    [Environment]::SetEnvironmentVariable("Path", $newPath, $Target)
    return $true
}

$pwshPath = Find-PwshPath

if (-not $pwshPath -and $InstallIfMissing) {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw "winget not found. Install PowerShell 7 manually, then rerun this script."
    }

    Write-Host "Installing PowerShell 7 with winget..."
    & $winget.Path install --id Microsoft.PowerShell --source winget --accept-source-agreements --accept-package-agreements --silent
    $pwshPath = Find-PwshPath
}

if (-not $pwshPath) {
    throw "PowerShell Core not found. Run with -InstallIfMissing or install PowerShell 7 manually."
}

$userUpdated = Ensure-PathContainsPwshFolder -PwshPath $pwshPath -Target User
$machineUpdated = $false
if ($UpdateMachinePath) {
    $machineUpdated = Ensure-PathContainsPwshFolder -PwshPath $pwshPath -Target Machine
}

$pwshVersion = & $pwshPath -NoProfile -NoLogo -Command '$PSVersionTable.PSVersion.ToString()'

Write-Host "pwsh path: $pwshPath"
Write-Host "pwsh version: $pwshVersion"
Write-Host "User PATH updated: $userUpdated"
Write-Host "Machine PATH updated: $machineUpdated"

if ($ApplyTasksCoreOnly) {
    if (Test-Path -LiteralPath $MonitorInstallerPath) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $MonitorInstallerPath -RequireCore
    }
    if (Test-Path -LiteralPath $CleanupInstallerPath) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $CleanupInstallerPath -RequireCore
    }
}

[PSCustomObject]@{
    PwshPath = $pwshPath
    PwshVersion = $pwshVersion
    UserPathUpdated = $userUpdated
    MachinePathUpdated = $machineUpdated
    TasksCoreOnlyApplied = [bool]$ApplyTasksCoreOnly
}
