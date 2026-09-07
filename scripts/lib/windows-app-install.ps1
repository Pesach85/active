# Windows app install helpers: shortcuts, Start Menu, Desktop, dev-sync junction, manifest.
Set-StrictMode -Version Latest

function Expand-InstallProfilePath {
    param([string]$Template)
    if (-not $Template) { return '' }
    $expanded = [Environment]::ExpandEnvironmentVariables($Template)
    return $expanded -replace '\$\{HOME\}', $env:USERPROFILE
}

function Get-InstallProfile {
    param([string]$HubRoot)
    $path = Join-Path $HubRoot 'config\install-profile.json'
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Install profile not found: $path"
    }
    return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
}

function Get-HubAppRoot {
    param([string]$InstallRoot, [string]$AppSubdir = 'app')
    return Join-Path $InstallRoot $AppSubdir
}

function Test-HubDevSyncJunction {
    param([string]$AppRoot)
    try {
        $item = Get-Item -LiteralPath $AppRoot -Force
        return $item.Attributes -band [IO.FileAttributes]::ReparsePoint
    } catch { return $false }
}

function Set-HubDevSyncJunction {
    param(
        [string]$AppRoot,
        [string]$SourceDistPath
    )

    if (-not (Test-Path -LiteralPath $SourceDistPath)) {
        throw "Dev-sync source dist missing. Run: scripts\package-suite.ps1 - $SourceDistPath"
    }

    $parent = Split-Path -Parent $AppRoot
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }

    if (Test-Path -LiteralPath $AppRoot) {
        if (Test-HubDevSyncJunction -AppRoot $AppRoot) {
            cmd /c "rmdir `"$AppRoot`"" 2>$null | Out-Null
        }
        elseif ((Get-ChildItem -LiteralPath $AppRoot -Force -ErrorAction SilentlyContinue | Measure-Object).Count -eq 0) {
            Remove-Item -LiteralPath $AppRoot -Force -ErrorAction SilentlyContinue
        }
        else {
            throw "App path exists and is not a dev-sync junction: $AppRoot (use -Force or uninstall first)"
        }
    }

    New-Item -ItemType Junction -Path $AppRoot -Target $SourceDistPath | Out-Null
}

function Copy-HubAppMirror {
    param(
        [string]$AppRoot,
        [string]$SourceDistPath
    )

    if (-not (Test-Path -LiteralPath $SourceDistPath)) {
        throw "Source dist missing: $SourceDistPath"
    }

    if (Test-Path -LiteralPath $AppRoot) {
        if (Test-HubDevSyncJunction -AppRoot $AppRoot) {
            throw "Cannot mirror-copy over dev-sync junction. Uninstall or use -DevSync."
        }
    }
    else {
        New-Item -Path $AppRoot -ItemType Directory -Force | Out-Null
    }

    & robocopy $SourceDistPath $AppRoot /MIR /NFL /NDL /NJH /NJS /NP /XD logs | Out-Null
    if ($LASTEXITCODE -ge 8) {
        throw "robocopy failed with exit code $LASTEXITCODE"
    }
}

function New-HubShellShortcut {
    param(
        [string]$ShortcutPath,
        [string]$TargetPath,
        [string]$Arguments = '',
        [string]$WorkingDirectory = '',
        [string]$Description = '',
        [string]$IconLocation = ''
    )

    $dir = Split-Path -Parent $ShortcutPath
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }

    $wsh = New-Object -ComObject WScript.Shell
    $sc = $wsh.CreateShortcut($ShortcutPath)
    $sc.TargetPath = $TargetPath
    if ($Arguments) { $sc.Arguments = $Arguments }
    if ($WorkingDirectory) { $sc.WorkingDirectory = $WorkingDirectory }
    if ($Description) { $sc.Description = $Description }
    if ($IconLocation) { $sc.IconLocation = $IconLocation }
    $sc.Save()
}

function Install-HubWindowsShortcuts {
    param(
        [string]$AppRoot,
        [object]$Profile,
        [switch]$CreateDesktopShortcuts,
        [switch]$PinToTaskbar
    )

    $startRoot = [Environment]::GetFolderPath('Programs')
    $menuDir = Join-Path $startRoot $Profile.Windows.StartMenuFolder
    New-Item -Path $menuDir -ItemType Directory -Force | Out-Null

    $iconExe = Join-Path $AppRoot 'WindowsOptimizer.exe'
    $iconLoc = if (Test-Path -LiteralPath $iconExe) { "$iconExe,0" } else { "$env:SystemRoot\System32\imageres.dll,109" }

    foreach ($prop in $Profile.Windows.Shortcuts.PSObject.Properties) {
        $def = $prop.Value
        $targetRel = [string]$def.Target
        $targetFull = Join-Path $AppRoot $targetRel
        if (-not (Test-Path -LiteralPath $targetFull)) { continue }

        $lnkName = [string]$def.Name
        $desc = [string]$def.Description
        $args = ''
        $launch = $targetFull
        if ($targetRel -match '\.bat$') {
            $launch = $env:ComSpec
            $args = "/c `"$targetFull`""
        }

        New-HubShellShortcut -ShortcutPath (Join-Path $menuDir "$lnkName.lnk") `
            -TargetPath $launch -Arguments $args -WorkingDirectory $AppRoot `
            -Description $desc -IconLocation $iconLoc

        if ($CreateDesktopShortcuts) {
            $desktopFolder = [Environment]::GetFolderPath('Desktop')
            New-HubShellShortcut -ShortcutPath (Join-Path $desktopFolder "$lnkName.lnk") `
                -TargetPath $launch -Arguments $args -WorkingDirectory $AppRoot `
                -Description $desc -IconLocation $iconLoc
        }

        if ($PinToTaskbar -and $prop.Name -eq 'Gui') {
            try {
                $shell = New-Object -ComObject Shell.Application
                $folder = $shell.NameSpace($menuDir)
                $item = $folder.ParseName("$lnkName.lnk")
                if ($item) { $item.InvokeVerb('taskbarpin') }
            } catch {
                Write-Warning "Taskbar pin may require manual action (right-click shortcut → Pin to taskbar)."
            }
        }
    }
}

function Remove-HubWindowsShortcuts {
    param([object]$Profile, [switch]$RemoveDesktopShortcuts)

    $startRoot = [Environment]::GetFolderPath('Programs')
    $menuDir = Join-Path $startRoot $Profile.Windows.StartMenuFolder
    if (Test-Path -LiteralPath $menuDir) {
        Remove-Item -LiteralPath $menuDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($RemoveDesktopShortcuts) {
        $desktopFolder = [Environment]::GetFolderPath('Desktop')
        foreach ($prop in $Profile.Windows.Shortcuts.PSObject.Properties) {
            $lnk = Join-Path $desktopFolder ("{0}.lnk" -f $prop.Value.Name)
            if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue }
        }
    }
}

function Write-HubInstallManifest {
    param(
        [string]$InstallRoot,
        [string]$AppRoot,
        [string]$HubRoot,
        [bool]$DevSync,
        [string]$DevSyncSource = ''
    )

    $manifest = [ordered]@{
        SchemaVersion = 'HubInstallManifest.v1'
        InstalledAt   = (Get-Date).ToString('o')
        InstallRoot   = $InstallRoot
        AppRoot       = $AppRoot
        HubRoot       = $HubRoot
        DevSync       = $DevSync
        DevSyncSource = $DevSyncSource
        ProductName   = 'System Optimizer Hub'
    }
    $path = Join-Path $InstallRoot 'install-manifest.json'
    ($manifest | ConvertTo-Json -Depth 4) | Out-File -LiteralPath $path -Encoding utf8 -Force
    return $path
}

function Read-HubInstallManifest {
    param([string]$InstallRoot)
    $path = Join-Path $InstallRoot 'install-manifest.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
}
