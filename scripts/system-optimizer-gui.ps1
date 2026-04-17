Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Resolve-BaseDirectory {
    if ($PSScriptRoot) {
        return $PSScriptRoot
    }

    if ($MyInvocation.MyCommand.Path) {
        return (Split-Path -Parent $MyInvocation.MyCommand.Path)
    }

    $exeBase = [System.AppDomain]::CurrentDomain.BaseDirectory
    if ($exeBase) {
        return $exeBase.TrimEnd("\\")
    }

    return (Get-Location).Path
}

$baseDir = Resolve-BaseDirectory
$scriptsUnderBase = Join-Path $baseDir "scripts"

if (Test-Path -LiteralPath $scriptsUnderBase) {
    $script:hubRoot = $baseDir
    $script:scriptRoot = $scriptsUnderBase
} elseif ((Split-Path -Leaf $baseDir).ToLowerInvariant() -eq "scripts") {
    $script:scriptRoot = $baseDir
    $script:hubRoot = Split-Path -Parent $baseDir
} else {
    $script:scriptRoot = $baseDir
    $script:hubRoot = Split-Path -Parent $baseDir
}

$pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
if ($pwshCmd) {
    $script:psHost = $pwshCmd.Path
} else {
    $winPsCmd = Get-Command powershell -ErrorAction SilentlyContinue
    if ($winPsCmd) {
        $script:psHost = $winPsCmd.Path
    } else {
        $script:psHost = $null
    }
}

function Invoke-ChildPowerShell {
    param([string[]]$Args)

    if (-not $script:psHost) {
        throw "No PowerShell runtime available in PATH."
    }

    & $script:psHost @Args
}

$script:cleanupScript = Join-Path $script:scriptRoot "cleanup-storage-safe.ps1"
$script:analyzerScript = Join-Path $script:scriptRoot "analyze-garbage-hotspots.ps1"
$script:coreScript = Join-Path $script:scriptRoot "ensure-powershell-core.ps1"
$script:monitorInstaller = Join-Path $script:scriptRoot "install-monitor-task.ps1"
$script:cleanupInstaller = Join-Path $script:scriptRoot "install-cleanup-task.ps1"
$script:configPath = Join-Path $script:hubRoot "config\\sys-maintenance.json"
$script:defaultLog = Join-Path $script:hubRoot "logs\\storage-cleanup.log"
$script:analysisProcess = $null
$script:analysisCsv = Join-Path $script:hubRoot "logs\\garbage-hotspots-live.csv"
$script:analysisStartedAt = $null
$script:analysisTimeoutSec = 0
$script:analysisSoftTimeoutWarned = $false
$script:autoAnalyzeOnStartup = $true
$script:startupAnalyzeDepth = "Quick"
$script:startupAnalyzeTop = 15

$form = New-Object System.Windows.Forms.Form
$form.Text = "Windows Optimizer Console"
$form.Size = New-Object System.Drawing.Size(1280, 780)
$form.StartPosition = "CenterScreen"
$form.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = "Fill"

$tabDashboard = New-Object System.Windows.Forms.TabPage
$tabDashboard.Text = "Dashboard"
$tabTasks = New-Object System.Windows.Forms.TabPage
$tabTasks.Text = "Taskbar"
$tabLogs = New-Object System.Windows.Forms.TabPage
$tabLogs.Text = "Logs"
$tabConfig = New-Object System.Windows.Forms.TabPage
$tabConfig.Text = "Config"

$txtStatus = New-Object System.Windows.Forms.TextBox
$txtStatus.Multiline = $true
$txtStatus.ScrollBars = "Vertical"
$txtStatus.Dock = "Fill"
$txtStatus.ReadOnly = $true

$listExplorer = New-Object System.Windows.Forms.ListView
$listExplorer.View = "Details"
$listExplorer.FullRowSelect = $true
$listExplorer.GridLines = $true
$listExplorer.Dock = "Fill"
$listExplorer.HideSelection = $false
$listExplorer.Columns.Add("Score", 70) | Out-Null
$listExplorer.Columns.Add("Risk", 70) | Out-Null
$listExplorer.Columns.Add("Drive", 55) | Out-Null
$listExplorer.Columns.Add("Path", 390) | Out-Null
$listExplorer.Columns.Add("Category", 100) | Out-Null
$listExplorer.Columns.Add("Provenance", 120) | Out-Null
$listExplorer.Columns.Add("DominantType", 110) | Out-Null
$listExplorer.Columns.Add("StalePct", 80) | Out-Null
$listExplorer.Columns.Add("ReclaimGB", 95) | Out-Null
$listExplorer.Columns.Add("Files", 70) | Out-Null

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = "Refresh Drive Status"
$btnRefresh.Width = 155
$btnRefresh.Location = New-Object System.Drawing.Point(16, 14)

$btnAnalyze = New-Object System.Windows.Forms.Button
$btnAnalyze.Text = "Analyze Garbage"
$btnAnalyze.Width = 130
$btnAnalyze.Location = New-Object System.Drawing.Point(182, 14)

$btnCancelAnalyze = New-Object System.Windows.Forms.Button
$btnCancelAnalyze.Text = "Cancel Analysis"
$btnCancelAnalyze.Width = 120
$btnCancelAnalyze.Location = New-Object System.Drawing.Point(16, 46)
$btnCancelAnalyze.Enabled = $false

$btnAudit = New-Object System.Windows.Forms.Button
$btnAudit.Text = "Audit Cleanup"
$btnAudit.Width = 120
$btnAudit.Location = New-Object System.Drawing.Point(322, 14)

$btnExecute = New-Object System.Windows.Forms.Button
$btnExecute.Text = "Execute Cleanup"
$btnExecute.Width = 125
$btnExecute.Location = New-Object System.Drawing.Point(452, 14)

$lblDepth = New-Object System.Windows.Forms.Label
$lblDepth.Text = "Depth"
$lblDepth.AutoSize = $true
$lblDepth.Location = New-Object System.Drawing.Point(598, 18)

$cmbDepth = New-Object System.Windows.Forms.ComboBox
$cmbDepth.DropDownStyle = "DropDownList"
$cmbDepth.Items.AddRange(@("Quick", "Standard", "Deep"))
$cmbDepth.SelectedItem = "Standard"
$cmbDepth.Width = 100
$cmbDepth.Location = New-Object System.Drawing.Point(645, 14)

$lblAuditLevel = New-Object System.Windows.Forms.Label
$lblAuditLevel.Text = "Audit"
$lblAuditLevel.AutoSize = $true
$lblAuditLevel.Location = New-Object System.Drawing.Point(754, 18)

$cmbAuditLevel = New-Object System.Windows.Forms.ComboBox
$cmbAuditLevel.DropDownStyle = "DropDownList"
$cmbAuditLevel.Items.AddRange(@("FileLevel", "BitLevel"))
$cmbAuditLevel.SelectedItem = "FileLevel"
$cmbAuditLevel.Width = 110
$cmbAuditLevel.Location = New-Object System.Drawing.Point(800, 14)

$lblCleanupMode = New-Object System.Windows.Forms.Label
$lblCleanupMode.Text = "Mode"
$lblCleanupMode.AutoSize = $true
$lblCleanupMode.Location = New-Object System.Drawing.Point(918, 18)

$cmbCleanupMode = New-Object System.Windows.Forms.ComboBox
$cmbCleanupMode.DropDownStyle = "DropDownList"
$cmbCleanupMode.Items.AddRange(@("Safe", "Radical"))
$cmbCleanupMode.SelectedItem = "Safe"
$cmbCleanupMode.Width = 90
$cmbCleanupMode.Location = New-Object System.Drawing.Point(963, 14)

$lblTop = New-Object System.Windows.Forms.Label
$lblTop.Text = "Top"
$lblTop.AutoSize = $true
$lblTop.Location = New-Object System.Drawing.Point(1064, 18)

$numTop = New-Object System.Windows.Forms.NumericUpDown
$numTop.Minimum = 5
$numTop.Maximum = 100
$numTop.Value = 25
$numTop.Width = 60
$numTop.Location = New-Object System.Drawing.Point(1095, 14)

$lblExplorerHint = New-Object System.Windows.Forms.Label
$lblExplorerHint.Text = "Double-click a row to open folder. Colors: High=Red, Medium=Amber, Low=Green"
$lblExplorerHint.AutoSize = $true
$lblExplorerHint.Location = New-Object System.Drawing.Point(146, 50)

$progressAnalysis = New-Object System.Windows.Forms.ProgressBar
$progressAnalysis.Minimum = 0
$progressAnalysis.Maximum = 100
$progressAnalysis.Value = 0
$progressAnalysis.Width = 320
$progressAnalysis.Height = 16
$progressAnalysis.Location = New-Object System.Drawing.Point(820, 50)

$lblAnalysisState = New-Object System.Windows.Forms.Label
$lblAnalysisState.Text = "Analyzer idle"
$lblAnalysisState.AutoSize = $true
$lblAnalysisState.Location = New-Object System.Drawing.Point(820, 68)

$panelDash = New-Object System.Windows.Forms.Panel
$panelDash.Dock = "Top"
$panelDash.Height = 94
$panelDash.Controls.AddRange(@(
    $btnRefresh,
    $btnAnalyze,
    $btnCancelAnalyze,
    $btnAudit,
    $btnExecute,
    $lblDepth,
    $cmbDepth,
    $lblAuditLevel,
    $cmbAuditLevel,
    $lblCleanupMode,
    $cmbCleanupMode,
    $lblTop,
    $numTop,
    $lblExplorerHint,
    $progressAnalysis,
    $lblAnalysisState
))

$splitDash = New-Object System.Windows.Forms.SplitContainer
$splitDash.Dock = "Fill"
$splitDash.Orientation = "Horizontal"
$splitDash.SplitterDistance = 190
$splitDash.Panel1.Controls.Add($txtStatus)
$splitDash.Panel2.Controls.Add($listExplorer)

$tabDashboard.Controls.Add($splitDash)
$tabDashboard.Controls.Add($panelDash)

$listTasks = New-Object System.Windows.Forms.ListView
$listTasks.View = "Details"
$listTasks.FullRowSelect = $true
$listTasks.GridLines = $true
$listTasks.Dock = "Fill"
$listTasks.Columns.Add("TaskName", 280) | Out-Null
$listTasks.Columns.Add("State", 120) | Out-Null
$listTasks.Columns.Add("NextRunTime", 220) | Out-Null

$btnReloadTasks = New-Object System.Windows.Forms.Button
$btnReloadTasks.Text = "Reload Tasks"
$btnReloadTasks.Width = 120
$btnReloadTasks.Location = New-Object System.Drawing.Point(20, 20)

$btnInstallTasks = New-Object System.Windows.Forms.Button
$btnInstallTasks.Text = "Install Core Tasks"
$btnInstallTasks.Width = 140
$btnInstallTasks.Location = New-Object System.Drawing.Point(160, 20)

$panelTask = New-Object System.Windows.Forms.Panel
$panelTask.Dock = "Top"
$panelTask.Height = 60
$panelTask.Controls.AddRange(@($btnReloadTasks, $btnInstallTasks))

$tabTasks.Controls.Add($listTasks)
$tabTasks.Controls.Add($panelTask)

$txtLogs = New-Object System.Windows.Forms.TextBox
$txtLogs.Multiline = $true
$txtLogs.ScrollBars = "Vertical"
$txtLogs.Dock = "Fill"
$txtLogs.ReadOnly = $true

$btnLoadLogs = New-Object System.Windows.Forms.Button
$btnLoadLogs.Text = "Load Last 200 Log Lines"
$btnLoadLogs.Width = 190
$btnLoadLogs.Location = New-Object System.Drawing.Point(20, 20)

$panelLog = New-Object System.Windows.Forms.Panel
$panelLog.Dock = "Top"
$panelLog.Height = 60
$panelLog.Controls.Add($btnLoadLogs)

$tabLogs.Controls.Add($txtLogs)
$tabLogs.Controls.Add($panelLog)

$lblConfig = New-Object System.Windows.Forms.Label
$lblConfig.Text = ("Config file: {0}" -f $script:configPath)
$lblConfig.AutoSize = $true
$lblConfig.Location = New-Object System.Drawing.Point(20, 20)

$btnOpenConfig = New-Object System.Windows.Forms.Button
$btnOpenConfig.Text = "Open Config"
$btnOpenConfig.Width = 120
$btnOpenConfig.Location = New-Object System.Drawing.Point(20, 50)

$tabConfig.Controls.Add($lblConfig)
$tabConfig.Controls.Add($btnOpenConfig)

$tabs.TabPages.AddRange(@($tabDashboard, $tabTasks, $tabLogs, $tabConfig))
$form.Controls.Add($tabs)

function Append-Status {
    param([string]$Message)

    $stamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $txtStatus.AppendText("$stamp - $Message`r`n")
}

function Load-GuiPreferences {
    if (-not (Test-Path -LiteralPath $script:configPath)) {
        return
    }

    try {
        $cfg = Get-Content -LiteralPath $script:configPath -Raw -ErrorAction Stop | ConvertFrom-Json
    } catch {
        Append-Status ("Config read warning: {0}" -f $_.Exception.Message)
        return
    }

    if (-not $cfg) {
        return
    }

    if ($cfg.PSObject.Properties.Name -contains "Gui") {
        $gui = $cfg.Gui
        if ($null -ne $gui.AutoAnalyzeOnStartup) {
            $script:autoAnalyzeOnStartup = [bool]$gui.AutoAnalyzeOnStartup
        }

        if ($gui.DefaultAnalyzeDepth -and @("Quick", "Standard", "Deep") -contains [string]$gui.DefaultAnalyzeDepth) {
            $script:startupAnalyzeDepth = [string]$gui.DefaultAnalyzeDepth
        }

        if ($null -ne $gui.DefaultAnalyzeTop) {
            $requestedTop = [int]$gui.DefaultAnalyzeTop
            if ($requestedTop -lt 5) { $requestedTop = 5 }
            if ($requestedTop -gt 100) { $requestedTop = 100 }
            $script:startupAnalyzeTop = $requestedTop
        }
    }
}

function Refresh-Drives {
    $drives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Name -in @("C", "D") }
    $summary = $drives | ForEach-Object {
        "{0}: Free {1} GB / Used {2} GB" -f $_.Name, [math]::Round($_.Free / 1GB, 2), [math]::Round($_.Used / 1GB, 2)
    }
    Append-Status ($summary -join " | ")
}

function Reload-Tasks {
    $listTasks.Items.Clear()
    $names = @("SystemResourceMonitor", "StorageCleanupSafe")

    foreach ($name in $names) {
        try {
            $t = Get-ScheduledTask -TaskName $name -ErrorAction Stop
            $info = Get-ScheduledTaskInfo -TaskName $name
            $item = New-Object System.Windows.Forms.ListViewItem($t.TaskName)
            $item.SubItems.Add([string]$t.State) | Out-Null
            $item.SubItems.Add([string]$info.NextRunTime) | Out-Null
            $listTasks.Items.Add($item) | Out-Null
        } catch {
            $item = New-Object System.Windows.Forms.ListViewItem($name)
            $item.SubItems.Add("Missing") | Out-Null
            $item.SubItems.Add("-") | Out-Null
            $listTasks.Items.Add($item) | Out-Null
        }
    }
}

function Populate-Explorer {
    param([object[]]$Rows)

    $listExplorer.Items.Clear()
    foreach ($row in $Rows) {
        $item = New-Object System.Windows.Forms.ListViewItem([string]$row.Score)
        [void]$item.SubItems.Add([string]$row.Recommendation)
        [void]$item.SubItems.Add([string]$row.Drive)
        [void]$item.SubItems.Add([string]$row.Path)
        [void]$item.SubItems.Add([string]$row.Category)
        [void]$item.SubItems.Add([string]$row.Provenance)
        [void]$item.SubItems.Add([string]$row.DominantType)
        [void]$item.SubItems.Add([string]$row.StalePct)
        [void]$item.SubItems.Add([string]$row.EstimatedReclaimGB)
        [void]$item.SubItems.Add([string]$row.FilesScanned)

        switch ([string]$row.Recommendation) {
            "High" { $item.BackColor = [System.Drawing.Color]::MistyRose }
            "Medium" { $item.BackColor = [System.Drawing.Color]::LemonChiffon }
            default { $item.BackColor = [System.Drawing.Color]::Honeydew }
        }

        [void]$listExplorer.Items.Add($item)
    }
}

function Get-AnalysisTimeoutSec {
    param([string]$Depth)

    switch ($Depth) {
        "Quick" { return 90 }
        "Deep" { return 420 }
        default { return 210 }
    }
}

function Set-AnalysisUiState {
    param(
        [bool]$IsBusy,
        [string]$StateText
    )

    $btnAnalyze.Enabled = -not $IsBusy
    $btnAudit.Enabled = -not $IsBusy
    $btnExecute.Enabled = -not $IsBusy
    $cmbDepth.Enabled = -not $IsBusy
    $cmbAuditLevel.Enabled = -not $IsBusy
    $cmbCleanupMode.Enabled = -not $IsBusy
    $numTop.Enabled = -not $IsBusy
    $btnCancelAnalyze.Enabled = $IsBusy

    if ($IsBusy) {
        $progressAnalysis.Style = "Continuous"
    } else {
        $progressAnalysis.Style = "Continuous"
        $progressAnalysis.Value = 0
    }

    if ($StateText) {
        $lblAnalysisState.Text = $StateText
    }
}

function Update-AnalysisProgress {
    if (-not $script:analysisStartedAt) {
        return
    }

    $elapsedSec = [math]::Round(((Get-Date) - $script:analysisStartedAt).TotalSeconds, 0)
    $timeoutSec = [math]::Max(1, $script:analysisTimeoutSec)
    $pct = [math]::Min(95, [int](($elapsedSec / $timeoutSec) * 100))

    if ($pct -lt $progressAnalysis.Minimum) {
        $pct = $progressAnalysis.Minimum
    }
    if ($pct -gt $progressAnalysis.Maximum) {
        $pct = $progressAnalysis.Maximum
    }

    $progressAnalysis.Value = $pct
    $lblAnalysisState.Text = ("Analyzer running: {0}s elapsed (target {1}s)" -f $elapsedSec, $timeoutSec)

    if (($elapsedSec -gt $timeoutSec) -and (-not $script:analysisSoftTimeoutWarned)) {
        $script:analysisSoftTimeoutWarned = $true
        Append-Status ("Analyzer exceeded expected time ({0}s). No forced stop applied; you can cancel manually." -f $timeoutSec)
        $lblAnalysisState.Text = ("Analyzer slower than expected ({0}s > {1}s)." -f $elapsedSec, $timeoutSec)
    }
}

function Stop-GarbageAnalysis {
    param([string]$Reason)

    if ($script:analysisProcess -and (-not $script:analysisProcess.HasExited)) {
        try {
            Stop-Process -Id $script:analysisProcess.Id -Force -ErrorAction Stop
            Append-Status ("Analyzer stopped. Reason: {0}" -f $Reason)
        } catch {
            Append-Status ("Unable to stop analyzer cleanly: {0}" -f $_.Exception.Message)
        }
    }

    $analysisTimer.Stop()
    $script:analysisProcess = $null
    $script:analysisStartedAt = $null
    $script:analysisTimeoutSec = 0
    $script:analysisSoftTimeoutWarned = $false
    Set-AnalysisUiState -IsBusy:$false -StateText "Analyzer idle"
}

function Poll-GarbageAnalysis {
    if (-not $script:analysisProcess) {
        return
    }

    if (-not $script:analysisProcess.HasExited) {
        Update-AnalysisProgress
        return
    }

    $analysisTimer.Stop()
    $durationSec = 0
    if ($script:analysisStartedAt) {
        $durationSec = [math]::Round(((Get-Date) - $script:analysisStartedAt).TotalSeconds, 1)
    }

    if ($script:analysisProcess.ExitCode -ne 0) {
        Append-Status ("Analyzer process ended with exit code {0}." -f $script:analysisProcess.ExitCode)
        $script:analysisProcess = $null
        $script:analysisStartedAt = $null
        $script:analysisTimeoutSec = 0
        $script:analysisSoftTimeoutWarned = $false
        Set-AnalysisUiState -IsBusy:$false -StateText "Analyzer idle"
        return
    }

    if (Test-Path -LiteralPath $script:analysisCsv) {
        $rows = Import-Csv -LiteralPath $script:analysisCsv -ErrorAction SilentlyContinue
        if ($rows) {
            Populate-Explorer -Rows @($rows)
            Append-Status ("Explorer updated with {0} ranked paths in {1}s." -f @($rows).Count, $durationSec)
            $progressAnalysis.Value = 100
            $lblAnalysisState.Text = ("Analyzer completed in {0}s." -f $durationSec)
        } else {
            Populate-Explorer -Rows @()
            Append-Status ("Analyzer completed in {0}s but returned no rows." -f $durationSec)
            $lblAnalysisState.Text = ("Analyzer completed in {0}s with no rows." -f $durationSec)
        }
    } else {
        Populate-Explorer -Rows @()
        Append-Status ("Analyzer completed in {0}s but output CSV was not found." -f $durationSec)
        $lblAnalysisState.Text = ("Analyzer completed in {0}s but output CSV missing." -f $durationSec)
    }

    $script:analysisProcess = $null
    $script:analysisStartedAt = $null
    $script:analysisTimeoutSec = 0
    $script:analysisSoftTimeoutWarned = $false
    Set-AnalysisUiState -IsBusy:$false -StateText $lblAnalysisState.Text
}

function Run-GarbageAnalysis {
    if (-not (Test-Path -LiteralPath $script:analyzerScript)) {
        Append-Status "Analyzer script not found: $script:analyzerScript"
        return
    }

    if ($script:analysisProcess -and (-not $script:analysisProcess.HasExited)) {
        Append-Status "Analyzer already running. Wait for completion."
        return
    }

    $depth = [string]$cmbDepth.SelectedItem
    $auditLevel = [string]$cmbAuditLevel.SelectedItem
    $cleanupMode = [string]$cmbCleanupMode.SelectedItem
    $top = [int]$numTop.Value

    try {
        Append-Status ("Analyzing garbage hotspots Depth={0} Audit={1} Mode={2} Top={3}" -f $depth, $auditLevel, $cleanupMode, $top)
        if (Test-Path -LiteralPath $script:analysisCsv) {
            Remove-Item -LiteralPath $script:analysisCsv -Force -ErrorAction SilentlyContinue
        }

        $args = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $script:analyzerScript,
            "-Drives", "C", "D",
            "-Top", "$top",
            "-Depth", $depth,
            "-AuditLevel", $auditLevel,
            "-CleanupMode", $cleanupMode,
            "-OutputCsv", $script:analysisCsv
        )

        $script:analysisStartedAt = Get-Date
        $script:analysisTimeoutSec = Get-AnalysisTimeoutSec -Depth $depth
        $script:analysisSoftTimeoutWarned = $false
        $script:analysisProcess = Start-Process -FilePath $script:psHost -ArgumentList $args -WindowStyle Hidden -PassThru
        $progressAnalysis.Value = 1
        Set-AnalysisUiState -IsBusy:$true -StateText ("Analyzer starting (target {0}s)..." -f $script:analysisTimeoutSec)
        $analysisTimer.Start()
        Append-Status "Analyzer started in background. UI remains responsive."
    } catch {
        Append-Status ("Analyzer error: {0}" -f $_.Exception.Message)
        $script:analysisProcess = $null
        $script:analysisStartedAt = $null
        $script:analysisTimeoutSec = 0
        $script:analysisSoftTimeoutWarned = $false
        Set-AnalysisUiState -IsBusy:$false -StateText "Analyzer idle"
    }
}

function Run-Cleanup {
    param([bool]$ExecuteNow)

    if (-not (Test-Path -LiteralPath $script:cleanupScript)) {
        Append-Status "Cleanup script not found: $script:cleanupScript"
        return
    }

    $depth = [string]$cmbDepth.SelectedItem
    $auditLevel = [string]$cmbAuditLevel.SelectedItem
    $cleanupMode = [string]$cmbCleanupMode.SelectedItem

    $args = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $script:cleanupScript,
        "-AuditDepth", $depth,
        "-AuditLevel", $auditLevel,
        "-CleanupMode", $cleanupMode
    )
    if ($ExecuteNow) {
        $args += "-Execute"
    }

    $action = if ($ExecuteNow) { "execute" } else { "audit" }
    Append-Status ("Running cleanup {0} with Depth={1}, Audit={2}, Mode={3}" -f $action, $depth, $auditLevel, $cleanupMode)
    try {
        $result = Invoke-ChildPowerShell -Args $args
        Append-Status ($result | Out-String)
        Refresh-Drives
    } catch {
        Append-Status ("Cleanup error: {0}" -f $_.Exception.Message)
    }
}

$listExplorer.Add_DoubleClick({
    if ($listExplorer.SelectedItems.Count -eq 0) {
        return
    }

    $path = $listExplorer.SelectedItems[0].SubItems[3].Text
    if (Test-Path -LiteralPath $path) {
        Start-Process explorer.exe -ArgumentList $path
        Append-Status ("Opened: {0}" -f $path)
    }
})

$btnRefresh.Add_Click({ Refresh-Drives })
$btnAnalyze.Add_Click({ Run-GarbageAnalysis })
$btnCancelAnalyze.Add_Click({
    if ($script:analysisProcess -and (-not $script:analysisProcess.HasExited)) {
        $confirm = [System.Windows.Forms.MessageBox]::Show("Cancel running analysis?", "Confirm", "YesNo", "Question")
        if ($confirm -eq "Yes") {
            Stop-GarbageAnalysis -Reason "Manual cancel requested by user."
        }
    }
})
$btnAudit.Add_Click({ Run-Cleanup -ExecuteNow:$false })
$btnExecute.Add_Click({
    $mode = [string]$cmbCleanupMode.SelectedItem
    $confirm = [System.Windows.Forms.MessageBox]::Show(("Execute {0} cleanup now?" -f $mode), "Confirm", "YesNo", "Warning")
    if ($confirm -eq "Yes") {
        Run-Cleanup -ExecuteNow:$true
        Run-GarbageAnalysis
    }
})
$btnReloadTasks.Add_Click({ Reload-Tasks })
$btnInstallTasks.Add_Click({
    $args = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $script:coreScript,
        "-InstallIfMissing",
        "-ApplyTasksCoreOnly",
        "-MonitorInstallerPath", $script:monitorInstaller,
        "-CleanupInstallerPath", $script:cleanupInstaller
    )
    try {
        Invoke-ChildPowerShell -Args $args | Out-Null
        Reload-Tasks
        Append-Status "Core tasks installation completed."
    } catch {
        Append-Status ("Core install error: {0}" -f $_.Exception.Message)
    }
})
$btnLoadLogs.Add_Click({
    if (Test-Path -LiteralPath $script:defaultLog) {
        $txtLogs.Text = (Get-Content -LiteralPath $script:defaultLog -Tail 200 -ErrorAction SilentlyContinue) -join "`r`n"
    } else {
        $txtLogs.Text = "Log file not found: $script:defaultLog"
    }
})
$btnOpenConfig.Add_Click({
    if (Test-Path -LiteralPath $script:configPath) {
        Start-Process notepad.exe -ArgumentList $script:configPath
    }
})

Load-GuiPreferences
if ($cmbDepth.Items.Contains($script:startupAnalyzeDepth)) {
    $cmbDepth.SelectedItem = $script:startupAnalyzeDepth
}
$numTop.Value = [decimal]$script:startupAnalyzeTop

$analysisTimer = New-Object System.Windows.Forms.Timer
$analysisTimer.Interval = 1000
$analysisTimer.Add_Tick({ Poll-GarbageAnalysis })

$form.Add_Shown({
    Refresh-Drives
    Reload-Tasks
    if ($script:autoAnalyzeOnStartup) {
        Append-Status ("Startup auto-analyze enabled. Depth={0}, Top={1}." -f [string]$cmbDepth.SelectedItem, [int]$numTop.Value)
        Run-GarbageAnalysis
    } else {
        Append-Status "Startup auto-analyze disabled by config. UI ready."
    }
})
[void]$form.ShowDialog()
