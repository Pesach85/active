[CmdletBinding()]
param(
    [switch]$InstallIfMissing,
    [switch]$UpdateMachinePath,
    [switch]$ApplyTasksCoreOnly,
    [switch]$AllowWingetFallback,
    [ValidateSet("Auto", "ExternalFirst", "WingetFirst")]
    [string]$InstallerStrategy = "Auto",
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

function Get-LatestPwshMsiUrl {
    $apiUrl = "https://api.github.com/repos/PowerShell/PowerShell/releases/latest"
    try {
        $release = Invoke-RestMethod -Uri $apiUrl -Headers @{ "User-Agent" = "WindowsOptimizer" } -Method Get -ErrorAction Stop
        if ($release -and $release.assets) {
            $x64 = $release.assets | Where-Object { $_.name -match "win-x64\.msi$" } | Select-Object -First 1
            if ($x64 -and $x64.browser_download_url) {
                return [string]$x64.browser_download_url
            }
            $anyMsi = $release.assets | Where-Object { $_.name -match "\.msi$" } | Select-Object -First 1
            if ($anyMsi -and $anyMsi.browser_download_url) {
                return [string]$anyMsi.browser_download_url
            }
        }
    } catch {
        Write-Host ("INSTALL_EXTERNAL_DISCOVERY_FAILED: {0}" -f $_.Exception.Message)
    }

    # Stable fallback page when API discovery is unavailable
    return "https://aka.ms/powershell-release?tag=stable"
}

function Install-PwshExternal {
    $downloadUrl = Get-LatestPwshMsiUrl
    Write-Host ("INSTALL_EXTERNAL_URL: {0}" -f $downloadUrl)

    if ($downloadUrl -notmatch "\.msi($|\?)") {
        # Fallback to browser page if we do not have a direct MSI URL
        Write-Host "INSTALL_EXTERNAL_PAGE: Opening PowerShell release page in browser..."
        Start-Process $downloadUrl | Out-Null
        throw "INSTALL_FAILED: External MSI URL not available. Complete manual install from opened page and rerun Install Core."
    }

    $msiPath = Join-Path $env:TEMP "powershell-latest-x64.msi"
    Write-Host ("INSTALL_EXTERNAL_DOWNLOAD: {0}" -f $msiPath)
    Invoke-WebRequest -Uri $downloadUrl -OutFile $msiPath -UseBasicParsing -ErrorAction Stop

    Write-Host "INSTALL_EXTERNAL_ATTEMPT: Launching MSI installer..."
    $msiArgs = @("/i", ('"{0}"' -f $msiPath), "/passive", "/norestart", "ADD_PATH=1")
    $p = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
        throw ("INSTALL_FAILED: MSI installer failed with code {0} (0x{1:X8})" -f $p.ExitCode, $p.ExitCode)
    }

    Write-Host "INSTALL_EXTERNAL_OK: MSI installer completed."
}

function Test-WingetUsable {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) { return $false }

    try {
        $proc = Start-Process -FilePath $winget.Path -ArgumentList "source", "list" -Wait -PassThru -NoNewWindow
        return ($proc.ExitCode -eq 0)
    } catch {
        return $false
    }
}

function Install-PwshWinget {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw "INSTALL_FAILED: winget not available."
    }

    Write-Host "INSTALL_WINGET_ATTEMPT: winget install Microsoft.PowerShell"
    $p = Start-Process -FilePath $winget.Path `
        -ArgumentList "install","--id","Microsoft.PowerShell","--source","winget","--accept-source-agreements","--accept-package-agreements" `
        -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -ne 0) {
        throw ("INSTALL_FAILED: winget failed with code 0x{0:X8}" -f $p.ExitCode)
    }

    Write-Host "INSTALL_WINGET_OK: winget installation completed."
}

$pwshPath = Find-PwshPath

if (-not $pwshPath -and $InstallIfMissing) {
    $effectiveStrategy = $InstallerStrategy
    if ($effectiveStrategy -eq "Auto") {
        if (Test-WingetUsable) {
            $effectiveStrategy = "WingetFirst"
        } else {
            $effectiveStrategy = "ExternalFirst"
        }
    }

    Write-Host ("INSTALL_MODE: {0}" -f $effectiveStrategy)

    if ($effectiveStrategy -eq "WingetFirst") {
        try {
            Install-PwshWinget
        } catch {
            $wingetError = $_.Exception.Message
            Write-Host ("INSTALL_WINGET_FAILED: {0}" -f $wingetError)
            Write-Host "INSTALL_FALLBACK: trying external installer path..."
            Install-PwshExternal
        }
    } else {
        try {
            Install-PwshExternal
        } catch {
            $externalError = $_.Exception.Message
            Write-Host ("INSTALL_EXTERNAL_FAILED: {0}" -f $externalError)

            if ($AllowWingetFallback) {
                Write-Host "INSTALL_FALLBACK: trying winget fallback..."
                Install-PwshWinget
            } else {
                throw ("INSTALL_FAILED: {0}" -f $externalError)
            }
        }
    }

    $pwshPath = Find-PwshPath
}

if (-not $pwshPath) {
    throw "INSTALL_FAILED: PowerShell Core non trovato dopo installazione. Scarica manualmente da https://aka.ms/powershell-release?tag=stable e riavvia il terminale."
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
