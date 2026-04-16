Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:hubRoot = Split-Path -Parent $script:scriptRoot
$script:cleanupScript = Join-Path $script:scriptRoot "cleanup-storage-safe.ps1"
$script:analyzerScript = Join-Path $script:scriptRoot "analyze-garbage-hotspots.ps1"
$script:coreScript = Join-Path $script:scriptRoot "ensure-powershell-core.ps1"
$script:monitorInstaller = Join-Path $script:scriptRoot "install-monitor-task.ps1"
$script:cleanupInstaller = Join-Path $script:scriptRoot "install-cleanup-task.ps1"
$script:configPath = Join-Path $script:hubRoot "config\\sys-maintenance.json"
$script:defaultLog = Join-Path $script:hubRoot "logs\\storage-cleanup.log"

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
$lblExplorerHint.Location = New-Object System.Drawing.Point(16, 50)

$panelDash = New-Object System.Windows.Forms.Panel
$panelDash.Dock = "Top"
$panelDash.Height = 78
$panelDash.Controls.AddRange(@(
    $btnRefresh,
    $btnAnalyze,
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
    $lblExplorerHint
))

$splitDash = New-Object System.Windows.Forms.SplitContainer
$splitDash.Dock = "Fill"
$splitDash.Orientation = "Horizontal"
$splitDash.SplitterDistance = 170
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

function Run-GarbageAnalysis {
    if (-not (Test-Path -LiteralPath $script:analyzerScript)) {
        Append-Status "Analyzer script not found: $script:analyzerScript"
        return
    }

    $depth = [string]$cmbDepth.SelectedItem
    $auditLevel = [string]$cmbAuditLevel.SelectedItem
    $cleanupMode = [string]$cmbCleanupMode.SelectedItem
    $top = [int]$numTop.Value

    Append-Status ("Analyzing garbage hotspots Depth={0} Audit={1} Mode={2} Top={3}" -f $depth, $auditLevel, $cleanupMode, $top)
    $rows = & powershell -NoProfile -ExecutionPolicy Bypass -File $script:analyzerScript -Drives C,D -Top $top -Depth $depth -AuditLevel $auditLevel -CleanupMode $cleanupMode
    if ($rows) {
        Populate-Explorer -Rows @($rows)
        Append-Status ("Explorer updated with {0} ranked paths." -f @($rows).Count)
    } else {
        Populate-Explorer -Rows @()
        Append-Status "Analyzer returned no rows."
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
    $result = & powershell @args
    Append-Status ($result | Out-String)
    Refresh-Drives
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
    & powershell @args
    Reload-Tasks
    Append-Status "Core tasks installation completed."
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

Refresh-Drives
Reload-Tasks
Run-GarbageAnalysis
[void]$form.ShowDialog()
