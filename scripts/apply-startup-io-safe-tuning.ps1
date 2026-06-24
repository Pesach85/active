[CmdletBinding()]
param(
    [switch]$Execute,
    [switch]$SetAnyDeskManual,
    [string]$BackupJson = "C:\SystemOptimizerHub\active\logs\startup-safe-tuning-backup.json",
    [string]$OutputJson = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-RunLocations {
    $locations = New-Object System.Collections.Generic.List[string]
    [void]$locations.Add("HKCU:\Software\Microsoft\Windows\CurrentVersion\Run")

    try {
        foreach ($sidKey in (Get-ChildItem -Path Registry::HKEY_USERS -ErrorAction SilentlyContinue)) {
            if ($sidKey.PSChildName -match '^S-1-5-21-') {
                $path = "Registry::HKEY_USERS\{0}\Software\Microsoft\Windows\CurrentVersion\Run" -f $sidKey.PSChildName
                [void]$locations.Add($path)
            }
        }
    } catch {
        # Keep only HKCU if HKU cannot be enumerated.
    }

    return $locations.ToArray()
}

$targets = @(
    @{ NamePattern = '^MicrosoftEdgeAutoLaunch_'; Reason = 'Browser prelaunch at logon can increase startup I/O.' },
    @{ NamePattern = '^Opera Stable$'; Reason = 'Opera autostart can increase startup I/O and memory.' }
)

$mode = if ($Execute) { "EXECUTE" } else { "AUDIT" }
$backupRows = New-Object System.Collections.Generic.List[object]
$actions = New-Object System.Collections.Generic.List[object]
$runLocations = Get-RunLocations

foreach ($location in $runLocations) {
    if (-not (Test-Path -LiteralPath $location)) {
        continue
    }

    $props = Get-ItemProperty -LiteralPath $location -ErrorAction SilentlyContinue
    if ($null -eq $props) {
        continue
    }

    $propNames = @($props.PSObject.Properties | ForEach-Object { $_.Name })
    foreach ($target in $targets) {
        foreach ($prop in $propNames) {
            if ($prop -notmatch $target.NamePattern) {
                continue
            }

            $value = ""
            try { $value = [string]$props.$prop } catch { $value = "" }

            $backupRows.Add([PSCustomObject]@{
                RegistryPath = $location
                Name = $prop
                Value = $value
                Reason = [string]$target.Reason
            })

            if ($Execute) {
                try {
                    Remove-ItemProperty -LiteralPath $location -Name $prop -ErrorAction Stop
                    $actions.Add([PSCustomObject]@{
                        Action = "DisabledStartupEntry"
                        Target = ("{0}::{1}" -f $location, $prop)
                        Status = "Applied"
                        Reason = [string]$target.Reason
                        Rollback = "Restore from backup JSON using New-ItemProperty."
                    })
                } catch {
                    $actions.Add([PSCustomObject]@{
                        Action = "DisabledStartupEntry"
                        Target = ("{0}::{1}" -f $location, $prop)
                        Status = "Skipped"
                        Reason = $_.Exception.Message
                        Rollback = "None"
                    })
                }
            } else {
                $actions.Add([PSCustomObject]@{
                    Action = "DisabledStartupEntry"
                    Target = ("{0}::{1}" -f $location, $prop)
                    Status = "Planned"
                    Reason = [string]$target.Reason
                    Rollback = "No change in audit mode."
                })
            }
        }
    }
}

if ($SetAnyDeskManual) {
    try {
        $svc = Get-Service -Name "AnyDesk" -ErrorAction Stop
        if ($Execute) {
            Set-Service -Name "AnyDesk" -StartupType Manual -ErrorAction Stop
            $actions.Add([PSCustomObject]@{
                Action = "SetServiceStartupType"
                Target = "AnyDesk"
                Status = "Applied"
                Reason = "Optional remote service can be manual to reduce boot overhead."
                Rollback = "Set-Service -Name AnyDesk -StartupType Automatic"
            })
        } else {
            $actions.Add([PSCustomObject]@{
                Action = "SetServiceStartupType"
                Target = "AnyDesk"
                Status = "Planned"
                Reason = "Optional remote service can be manual to reduce boot overhead."
                Rollback = "No change in audit mode."
            })
        }
    } catch {
        $actions.Add([PSCustomObject]@{
            Action = "SetServiceStartupType"
            Target = "AnyDesk"
            Status = "Skipped"
            Reason = $_.Exception.Message
            Rollback = "None"
        })
    }
}

$backupDir = Split-Path -Parent $BackupJson
if ($backupDir -and (-not (Test-Path -LiteralPath $backupDir))) {
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
}

$backupObj = [PSCustomObject]@{
    GeneratedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Mode = $mode
    Entries = $backupRows.ToArray()
}
$backupObj | ConvertTo-Json -Depth 8 | Out-File -LiteralPath $BackupJson -Encoding utf8 -Force

$result = [PSCustomObject]@{
    GeneratedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Mode = $mode
    BackupJson = $BackupJson
    PlannedOrAppliedActions = $actions.ToArray()
}

if ($OutputJson) {
    $outDir = Split-Path -Parent $OutputJson
    if ($outDir -and (-not (Test-Path -LiteralPath $outDir))) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }
    $result | ConvertTo-Json -Depth 8 | Out-File -LiteralPath $OutputJson -Encoding utf8 -Force
}

$result
