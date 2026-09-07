# Startup / scheduled-task / Run-key integrity for hub relocation leftovers.
# Dot-source from audit-startup-integrity.ps1 and system-health-audit.ps1.
# Fast: named task lookup + XML fingerprint scan. Does not enumerate every COM task via CIM.
# Do not Set-StrictMode here â€” this file is dot-sourced into health-audit (Continue, non-strict).

function Get-StartupIntegrityLegacyRoots {
    return @(
        'C:\SystemOptimizerHub',
        'C:\SystemOptimizer'
    )
}

function Get-StartupIntegrityPersistentTaskMap {
    return @{
        'SystemResourceMonitor'            = 'install-monitor-task.ps1'
        'StorageCleanupSafe'               = 'install-cleanup-task.ps1'
        'SystemOptimizerHub-Orchestrator'  = 'install-orchestrator-task.ps1'
    }
}

function Get-StartupIntegrityOneShotTaskNames {
    return @(
        'NVMe-WriteOffload-PostBootVerify'
    )
}

function Test-StartupIntegrityHubFingerprint {
    param(
        [string]$Name,
        [string]$TargetPath,
        [string]$Blob
    )
    $hay = ('{0} {1} {2}' -f $Name, $TargetPath, $Blob)
    if ($hay -match '(?i)SystemOptimizerHub|WindowsOptimizer\\scripts|verify-nvme-writeoffload|StorageCleanupSafe|SystemResourceMonitor') {
        return $true
    }
    foreach ($root in (Get-StartupIntegrityLegacyRoots)) {
        if ($hay -like ('*{0}*' -f $root)) { return $true }
    }
    return $false
}

function Test-StartupIntegrityLegacyRootPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $full = $Path
    try { $full = [System.IO.Path]::GetFullPath($Path) } catch { }
    foreach ($root in (Get-StartupIntegrityLegacyRoots)) {
        $prefix = $root.TrimEnd('\')
        if ($full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Resolve-StartupIntegrityTargetPath {
    param(
        [string]$Command,
        [string]$Arguments
    )
    $cmd = [string]$Command
    $arg = [string]$Arguments
    $file = $null
    if ($arg -match '(?i)-File\s+"([^"]+\.ps1)"') { $file = $Matches[1] }
    elseif ($arg -match "(?i)-File\s+'([^']+\.ps1)'") { $file = $Matches[1] }
    elseif ($arg -match '(?i)-File\s+(\S+\.ps1)') { $file = $Matches[1] }

    if (-not $file -and $cmd) {
        $leaf = ''
        try { $leaf = Split-Path -Leaf $cmd.Trim('"') } catch { $leaf = $cmd }
        if ($leaf -notmatch '^(?i)(powershell|pwsh)(\.exe)?$') {
            if ($cmd -match '^"([^"]+)"') { $file = $Matches[1] }
            elseif ($cmd -match '\.(exe|bat|cmd|ps1)(\s|$)') { $file = $cmd.Trim().Trim('"') }
        }
    }

    if ([string]::IsNullOrWhiteSpace($file)) { return $null }
    $file = [Environment]::ExpandEnvironmentVariables($file)
    try { return [System.IO.Path]::GetFullPath($file) } catch { return $file }
}

function Find-StartupIntegrityRelocatedScript {
    param(
        [string]$TargetPath,
        [string]$HubScripts
    )
    if ([string]::IsNullOrWhiteSpace($TargetPath) -or [string]::IsNullOrWhiteSpace($HubScripts)) { return $null }
    $leaf = Split-Path -Leaf $TargetPath
    if ([string]::IsNullOrWhiteSpace($leaf)) { return $null }
    $candidate = Join-Path $HubScripts $leaf
    if (Test-Path -LiteralPath $candidate) { return $candidate }
    $nested = Get-ChildItem -LiteralPath $HubScripts -Filter $leaf -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($nested) { return $nested.FullName }
    return $null
}

function New-StartupIntegrityItem {
    param(
        [string]$Kind,
        [string]$Name,
        [string]$SourcePath,
        [string]$Command,
        [string]$Arguments,
        [string]$TargetPath,
        [string]$HubRoot,
        [string]$HubScripts,
        [string]$TaskPath = '\'
    )

    $exists = $false
    if (-not [string]::IsNullOrWhiteSpace($TargetPath)) {
        $exists = Test-Path -LiteralPath $TargetPath
    }
    $blob = ('{0} {1}' -f $Command, $Arguments)
    $hubFp = Test-StartupIntegrityHubFingerprint -Name $Name -TargetPath $TargetPath -Blob $blob
    $legacy = Test-StartupIntegrityLegacyRootPath -Path $TargetPath
    $relocated = $null
    if ($hubFp -and (-not $exists -or $legacy)) {
        $relocated = Find-StartupIntegrityRelocatedScript -TargetPath $TargetPath -HubScripts $HubScripts
    }

    $oneShot = @((Get-StartupIntegrityOneShotTaskNames)) -contains $Name
    $persistentMap = Get-StartupIntegrityPersistentTaskMap
    $persistent = $persistentMap.ContainsKey($Name)

    $classification = 'Ok'
    $action = 'None'
    if ($hubFp -and $exists -and -not $legacy) {
        $classification = 'HubHealthy'
        $action = 'None'
    }
    elseif ($oneShot -and $Kind -eq 'ScheduledTask' -and ($legacy -or -not $exists)) {
        $classification = 'HubOneShotStale'
        $action = 'Unregister'
    }
    elseif ($hubFp -and $persistent -and $relocated -and ($legacy -or -not $exists)) {
        $classification = 'HubRelocatable'
        $action = 'Retarget'
    }
    elseif ($hubFp -and $relocated -and ($legacy -or -not $exists) -and $Kind -eq 'ScheduledTask' -and -not $oneShot) {
        $classification = 'HubRelocatable'
        $action = 'Retarget'
    }
    elseif ($hubFp -and $relocated -and $Kind -eq 'RunKey') {
        $classification = 'HubRelocatable'
        $action = 'Retarget'
    }
    elseif ($hubFp -and -not $exists) {
        $classification = 'HubBroken'
        $action = if ($Kind -eq 'ScheduledTask') { 'Unregister' } elseif ($Kind -eq 'RunKey') { 'RemoveValue' } else { 'RemoveShortcut' }
    }
    elseif (-not $exists -and -not [string]::IsNullOrWhiteSpace($TargetPath)) {
        $classification = 'BrokenMissing'
        $action = 'ReportOnly'
    }

    return [ordered]@{
        Kind             = $Kind
        Name             = $Name
        SourcePath       = $SourcePath
        TaskPath         = $TaskPath
        Command          = $Command
        Arguments        = $Arguments
        TargetPath       = $TargetPath
        TargetExists     = $exists
        LegacyRoot       = $legacy
        HubFingerprint   = $hubFp
        RelocatedPath    = $relocated
        Classification   = $classification
        SuggestedAction  = $action
        PersistentSuite  = $persistent
        OneShot          = $oneShot
    }
}

function Get-StartupIntegrityScheduledTaskItems {
    param(
        [string]$HubRoot,
        [string]$HubScripts
    )
    $items = [System.Collections.Generic.List[object]]::new()
    $seen = @{}

    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($n in @((Get-StartupIntegrityPersistentTaskMap).Keys)) { [void]$names.Add($n) }
    foreach ($n in (Get-StartupIntegrityOneShotTaskNames)) { [void]$names.Add($n) }

    $tasksRoot = Join-Path $env:SystemRoot 'System32\Tasks'
    if (Test-Path -LiteralPath $tasksRoot) {
        $hits = Get-ChildItem -LiteralPath $tasksRoot -Recurse -File -ErrorAction SilentlyContinue |
            Select-String -Pattern 'SystemOptimizerHub|WindowsOptimizer\\scripts|verify-nvme-writeoffload' -List -ErrorAction SilentlyContinue
        foreach ($h in @($hits)) {
            $rel = $h.Path.Substring($tasksRoot.Length).TrimStart('\')
            if (-not [string]::IsNullOrWhiteSpace($rel)) { [void]$names.Add($rel) }
        }
    }

    foreach ($name in @($names | Select-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $leaf = Split-Path -Leaf $name
        if ($seen.ContainsKey($leaf)) { continue }
        $task = $null
        try { $task = Get-ScheduledTask -TaskName $leaf -ErrorAction Stop } catch { continue }
        if (-not $task) { continue }
        $seen[$leaf] = $true
        $action = @($task.Actions) | Select-Object -First 1
        $cmd = ''
        $arg = ''
        if ($action) {
            $cmd = [string]$action.Execute
            $arg = [string]$action.Arguments
        }
        $target = Resolve-StartupIntegrityTargetPath -Command $cmd -Arguments $arg
        $item = New-StartupIntegrityItem -Kind 'ScheduledTask' -Name $leaf `
            -SourcePath ('{0}{1}' -f $task.TaskPath, $task.TaskName) `
            -Command $cmd -Arguments $arg -TargetPath $target `
            -HubRoot $HubRoot -HubScripts $HubScripts -TaskPath $task.TaskPath
        [void]$items.Add($item)
    }
    return $items
}

function Get-StartupIntegrityRunKeyItems {
    param(
        [string]$HubRoot,
        [string]$HubScripts
    )
    $items = [System.Collections.Generic.List[object]]::new()
    $keys = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce'
    )
    foreach ($k in $keys) {
        if (-not (Test-Path -LiteralPath $k)) { continue }
        $props = Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue
        if (-not $props) { continue }
        foreach ($p in $props.PSObject.Properties) {
            if ($p.Name -match '^PS' -or $p.Name -eq '(default)') { continue }
            $val = [string]$p.Value
            $target = Resolve-StartupIntegrityTargetPath -Command $val -Arguments ''
            if (-not $target) {
                if ($val -match '^"([^"]+)"') { $target = $Matches[1] }
                elseif ($val -match '^(\S+\.(?:exe|bat|cmd|ps1))') { $target = $Matches[1] }
                if ($target) {
                    $target = [Environment]::ExpandEnvironmentVariables($target)
                    try { $target = [System.IO.Path]::GetFullPath($target) } catch { }
                }
            }
            $hubFp = Test-StartupIntegrityHubFingerprint -Name $p.Name -TargetPath $target -Blob $val
            $missing = -not [string]::IsNullOrWhiteSpace($target) -and -not (Test-Path -LiteralPath $target)
            if (-not $hubFp -and -not $missing) { continue }
            if (-not $hubFp -and $missing) {
                # Vendor missing Run keys: report only, never auto-remove.
            }
            $item = New-StartupIntegrityItem -Kind 'RunKey' -Name $p.Name -SourcePath $k `
                -Command $val -Arguments '' -TargetPath $target -HubRoot $HubRoot -HubScripts $HubScripts
            [void]$items.Add($item)
        }
    }
    return $items
}

function Get-StartupIntegrityFolderItems {
    param(
        [string]$HubRoot,
        [string]$HubScripts
    )
    $items = [System.Collections.Generic.List[object]]::new()
    $dirs = @(
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup')
    )
    foreach ($d in $dirs) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        $files = @(Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue)
        foreach ($file in $files) {
            $target = $file.FullName
            if ($file.Extension -match '\.(lnk)$') {
                try {
                    $sh = New-Object -ComObject WScript.Shell
                    $target = $sh.CreateShortcut($file.FullName).TargetPath
                } catch { }
            }
            $hubFp = Test-StartupIntegrityHubFingerprint -Name $file.Name -TargetPath $target -Blob $file.FullName
            $missing = -not [string]::IsNullOrWhiteSpace($target) -and -not (Test-Path -LiteralPath $target)
            if (-not $hubFp -and -not $missing) { continue }
            $item = New-StartupIntegrityItem -Kind 'StartupFolder' -Name $file.Name -SourcePath $file.FullName `
                -Command $target -Arguments '' -TargetPath $target -HubRoot $HubRoot -HubScripts $HubScripts
            [void]$items.Add($item)
        }
    }
    return $items
}

function Add-StartupIntegrityItems {
    param($Target, $Chunk)
    if ($null -eq $Chunk) { return }
    if ($Chunk -is [System.Collections.IDictionary]) {
        [void]$Target.Add($Chunk)
        return
    }
    foreach ($i in @($Chunk)) {
        if ($i -is [System.Collections.IDictionary]) {
            [void]$Target.Add($i)
        }
    }
}

function Get-StartupIntegrityReport {
    param(
        [string]$HubRoot
    )
    if ([string]::IsNullOrWhiteSpace($HubRoot)) {
        if (Get-Command Get-HubRoot -ErrorAction SilentlyContinue) {
            $HubRoot = Get-HubRoot
        } else {
            $here = $PSScriptRoot
            if ((Split-Path -Leaf $here) -eq 'lib') {
                $HubRoot = Split-Path (Split-Path $here -Parent) -Parent
            } else {
                $HubRoot = Split-Path $here -Parent
            }
        }
    }
    $hubScripts = Join-Path $HubRoot 'scripts'
    $all = [System.Collections.Generic.List[object]]::new()
    Add-StartupIntegrityItems -Target $all -Chunk (Get-StartupIntegrityScheduledTaskItems -HubRoot $HubRoot -HubScripts $hubScripts)
    Add-StartupIntegrityItems -Target $all -Chunk (Get-StartupIntegrityRunKeyItems -HubRoot $HubRoot -HubScripts $hubScripts)
    Add-StartupIntegrityItems -Target $all -Chunk (Get-StartupIntegrityFolderItems -HubRoot $HubRoot -HubScripts $hubScripts)

    $broken = @($all | Where-Object { $_.Classification -in @('HubOneShotStale', 'HubRelocatable', 'HubBroken') })
    $missingVendor = @($all | Where-Object { $_.Classification -eq 'BrokenMissing' })
    $healthy = @($all | Where-Object { $_.Classification -eq 'HubHealthy' })

    $best = 'No hub startup leftovers.'
    if ($broken.Count -gt 0) {
        $best = 'Apply Safe: unregister stale one-shot/broken hub tasks and retarget persistent suite tasks to the current hub root.'
    }

    return [ordered]@{
        SchemaVersion = 'StartupIntegrityReport.v1'
        Timestamp     = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
        HubRoot       = $HubRoot
        CurrentHubExists = (Test-Path -LiteralPath $HubRoot)
        LegacyRoots   = @(Get-StartupIntegrityLegacyRoots)
        Items         = @($all)
        Summary       = [ordered]@{
            Total              = $all.Count
            HubHealthy         = $healthy.Count
            HubOneShotStale    = @($all | Where-Object { $_.Classification -eq 'HubOneShotStale' }).Count
            HubRelocatable     = @($all | Where-Object { $_.Classification -eq 'HubRelocatable' }).Count
            HubBroken          = @($all | Where-Object { $_.Classification -eq 'HubBroken' }).Count
            BrokenMissingOther = $missingVendor.Count
            NeedsRepair        = $broken.Count
            BestNextDecision   = $best
        }
    }
}

function Export-StartupIntegrityTaskXml {
    param([string]$TaskName)
    try {
        return (Export-ScheduledTask -TaskName $TaskName -ErrorAction Stop)
    } catch {
        return $null
    }
}

function Invoke-StartupIntegrityApply {
    param(
        $Report,
        [string]$BackupDirectory,
        [ValidateSet('Safe', 'Moderate')][string]$MaxLevel = 'Safe'
    )
    if (-not $Report) { throw 'Report is required.' }
    $hubRoot = [string]$Report.HubRoot
    $scripts = Join-Path $hubRoot 'scripts'
    if (-not (Test-Path -LiteralPath $BackupDirectory)) {
        New-Item -ItemType Directory -Path $BackupDirectory -Force | Out-Null
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupPath = Join-Path $BackupDirectory ("startup-integrity-backup-{0}.json" -f $stamp)
    $latestPath = Join-Path $BackupDirectory 'startup-integrity-backup-latest.json'

    $backupItems = [System.Collections.Generic.List[object]]::new()
    $applied = [System.Collections.Generic.List[object]]::new()
    $skipped = [System.Collections.Generic.List[object]]::new()

    foreach ($item in @($Report.Items)) {
        $cls = [string]$item.Classification
        $act = [string]$item.SuggestedAction
        if ($cls -in @('HubHealthy', 'Ok')) { continue }
        if ($act -eq 'ReportOnly' -or $cls -eq 'BrokenMissing') {
            [void]$skipped.Add([ordered]@{ Name = $item.Name; Reason = 'Vendor/non-hub missing target â€” not auto-removed' })
            continue
        }

        $do = $false
        if ($MaxLevel -eq 'Safe' -and $act -in @('Unregister', 'Retarget', 'RemoveValue', 'RemoveShortcut')) { $do = $true }
        if (-not $do) {
            [void]$skipped.Add([ordered]@{ Name = $item.Name; Reason = 'Below apply policy' })
            continue
        }

        $kind = [string]$item.Kind
        $name = [string]$item.Name
        if ($kind -eq 'ScheduledTask') {
            $xml = Export-StartupIntegrityTaskXml -TaskName $name
            [void]$backupItems.Add([ordered]@{
                    Kind = $kind; Name = $name; TaskPath = [string]$item.TaskPath
                    Xml = $xml; Command = [string]$item.Command; Arguments = [string]$item.Arguments
                })
            if ($act -eq 'Unregister') {
                Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop
                [void]$applied.Add([ordered]@{ Name = $name; Action = 'Unregister' })
            }
            elseif ($act -eq 'Retarget') {
                $map = Get-StartupIntegrityPersistentTaskMap
                $installer = $null
                if ($map.ContainsKey($name)) { $installer = Join-Path $scripts $map[$name] }
                if ($installer -and (Test-Path -LiteralPath $installer)) {
                    Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
                    $pwsh = if (Get-Command Get-HubPwshExecutable -ErrorAction SilentlyContinue) { Get-HubPwshExecutable } else { 'powershell.exe' }
                    $p = Start-Process -FilePath $pwsh -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $installer) -Wait -PassThru -WindowStyle Hidden
                    if ($p.ExitCode -ne 0) { throw ("Retarget installer failed for {0} exit={1}" -f $name, $p.ExitCode) }
                    [void]$applied.Add([ordered]@{ Name = $name; Action = 'RetargetInstaller'; Installer = $installer })
                }
                elseif ($item.RelocatedPath) {
                    $newArgs = ([string]$item.Arguments).Replace([string]$item.TargetPath, [string]$item.RelocatedPath)
                    $exe = [string]$item.Command
                    if ([string]::IsNullOrWhiteSpace($exe)) { $exe = 'powershell.exe' }
                    Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
                    $action = New-ScheduledTaskAction -Execute $exe -Argument $newArgs
                    $trigger = New-ScheduledTaskTrigger -AtStartup
                    Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -RunLevel Highest -Force | Out-Null
                    [void]$applied.Add([ordered]@{ Name = $name; Action = 'RetargetArgs'; NewPath = [string]$item.RelocatedPath })
                }
                else {
                    Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop
                    [void]$applied.Add([ordered]@{ Name = $name; Action = 'UnregisterFallback' })
                }
            }
        }
        elseif ($kind -eq 'RunKey') {
            $val = [string]$item.Command
            [void]$backupItems.Add([ordered]@{ Kind = $kind; Name = $name; SourcePath = [string]$item.SourcePath; Value = $val })
            if ($act -eq 'Retarget' -and $item.RelocatedPath) {
                Set-ItemProperty -LiteralPath $item.SourcePath -Name $name -Value $item.RelocatedPath
                [void]$applied.Add([ordered]@{ Name = $name; Action = 'RetargetRunKey' })
            }
            else {
                Remove-ItemProperty -LiteralPath $item.SourcePath -Name $name -ErrorAction Stop
                [void]$applied.Add([ordered]@{ Name = $name; Action = 'RemoveRunKey' })
            }
        }
        elseif ($kind -eq 'StartupFolder') {
            [void]$backupItems.Add([ordered]@{ Kind = $kind; Name = $name; SourcePath = [string]$item.SourcePath })
            if (Test-Path -LiteralPath $item.SourcePath) {
                Remove-Item -LiteralPath $item.SourcePath -Force -ErrorAction Stop
                [void]$applied.Add([ordered]@{ Name = $name; Action = 'RemoveShortcut' })
            }
        }
    }

    $backup = [ordered]@{
        Timestamp = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
        HubRoot   = $hubRoot
        Items     = @($backupItems)
    }
    $json = $backup | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($backupPath, $json, [System.Text.Encoding]::UTF8)
    Copy-Item -LiteralPath $backupPath -Destination $latestPath -Force

    return [ordered]@{
        BackupPath = $backupPath
        LatestPath = $latestPath
        Applied    = @($applied)
        Skipped    = @($skipped)
        AppliedCount = $applied.Count
    }
}

function Restore-StartupIntegrityLatest {
    param([string]$BackupDirectory)
    $latest = Join-Path $BackupDirectory 'startup-integrity-backup-latest.json'
    if (-not (Test-Path -LiteralPath $latest)) {
        throw "No startup-integrity backup found: $latest"
    }
    $raw = Get-Content -LiteralPath $latest -Raw | ConvertFrom-Json
    $restored = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @($raw.Items)) {
        $kind = [string]$item.Kind
        if ($kind -eq 'ScheduledTask' -and $item.Xml) {
            Register-ScheduledTask -TaskName ([string]$item.Name) -Xml ([string]$item.Xml) -Force | Out-Null
            [void]$restored.Add($item.Name)
        }
        elseif ($kind -eq 'RunKey') {
            Set-ItemProperty -LiteralPath ([string]$item.SourcePath) -Name ([string]$item.Name) -Value ([string]$item.Value)
            [void]$restored.Add($item.Name)
        }
    }
    return [ordered]@{ Restored = @($restored); Backup = $latest }
}
