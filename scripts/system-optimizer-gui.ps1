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
$script:quickCleanupScript = Join-Path $script:scriptRoot "quick-cleanup-safe.ps1"
$script:analyzerScript = Join-Path $script:scriptRoot "analyze-garbage-hotspots.ps1"
$script:computeAnalyzerScript = Join-Path $script:scriptRoot "analyze-compute-resources.ps1"
$script:coreScript = Join-Path $script:scriptRoot "ensure-powershell-core.ps1"
$script:monitorInstaller = Join-Path $script:scriptRoot "install-monitor-task.ps1"
$script:cleanupInstaller = Join-Path $script:scriptRoot "install-cleanup-task.ps1"
$script:configPath = Join-Path $script:hubRoot "config\\sys-maintenance.json"
$script:defaultLog = Join-Path $script:hubRoot "logs\\storage-cleanup.log"
$script:analysisProcess = $null
$script:analysisCsv = Join-Path $script:hubRoot "logs\\garbage-hotspots-live.csv"
$script:analysisStdOut = Join-Path $script:hubRoot "logs\garbage-hotspots-live.out.log"
$script:analysisStdErr = Join-Path $script:hubRoot "logs\garbage-hotspots-live.err.log"
$script:analysisStartedAt = $null
$script:analysisTimeoutSec = 0
$script:analysisSoftTimeoutWarned = $false
$script:cleanupProcess = $null
$script:cleanupJson = Join-Path $script:hubRoot "logs\\cleanup-live.json"
$script:cleanupStdOut = Join-Path $script:hubRoot "logs\cleanup-live.out.log"
$script:cleanupStdErr = Join-Path $script:hubRoot "logs\cleanup-live.err.log"
$script:cleanupStartedAt = $null
$script:cleanupTimeoutSec = 0
$script:cleanupSoftTimeoutWarned = $false
$script:cleanupRunAnalyzeAfter = $false
$script:computeProcess = $null
$script:computeJson = Join-Path $script:hubRoot "logs\compute-analysis-live.json"
$script:computeStdOut = Join-Path $script:hubRoot "logs\compute-analysis-live.out.log"
$script:computeStdErr = Join-Path $script:hubRoot "logs\compute-analysis-live.err.log"
$script:computeStartedAt = $null
$script:computeTimeoutSec = 45
$script:computeSoftTimeoutWarned = $false
$script:quickCleanupProcess = $null
$script:quickCleanupJson = Join-Path $script:hubRoot "logs\quick-cleanup-live.json"
$script:quickCleanupStdOut = Join-Path $script:hubRoot "logs\quick-cleanup-live.out.log"
$script:quickCleanupStdErr = Join-Path $script:hubRoot "logs\quick-cleanup-live.err.log"
$script:quickCleanupStartedAt = $null
$script:quickCleanupTimeoutSec = 120
$script:quickCleanupSoftTimeoutWarned = $false
$script:autoAnalyzeOnStartup = $true
$script:startupAnalyzeDepth = "Quick"
$script:startupAnalyzeTop = 15
$script:computeAnalyzeDurationSec = 8
$script:computeAnalyzeTop = 8
$script:quickCleanupRetentionDays = 2
$script:quickCleanupMaxFilesPerTarget = 2000
$script:diagnosticRetentionDays = 7
$script:diagnosticsDir = Join-Path $script:hubRoot "logs\diagnostics"

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

$btnDiagnostics = New-Object System.Windows.Forms.Button
$btnDiagnostics.Text = "Open Diagnostics"
$btnDiagnostics.Width = 130
$btnDiagnostics.Location = New-Object System.Drawing.Point(182, 46)

$btnCancelAnalyze = New-Object System.Windows.Forms.Button
$btnCancelAnalyze.Text = "Cancel Operation"
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

$btnCompute = New-Object System.Windows.Forms.Button
$btnCompute.Text = "Analyze Compute"
$btnCompute.Width = 125
$btnCompute.Location = New-Object System.Drawing.Point(322, 46)

$btnQuickClean = New-Object System.Windows.Forms.Button
$btnQuickClean.Text = "Quick Clean"
$btnQuickClean.Width = 125
$btnQuickClean.Location = New-Object System.Drawing.Point(452, 46)

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
$lblExplorerHint.Location = New-Object System.Drawing.Point(588, 50)

$progressAnalysis = New-Object System.Windows.Forms.ProgressBar
$progressAnalysis.Minimum = 0
$progressAnalysis.Maximum = 100
$progressAnalysis.Value = 0
$progressAnalysis.Width = 320
$progressAnalysis.Height = 16
$progressAnalysis.Location = New-Object System.Drawing.Point(820, 70)

$lblAnalysisState = New-Object System.Windows.Forms.Label
$lblAnalysisState.Text = "Analyzer idle"
$lblAnalysisState.AutoSize = $true
$lblAnalysisState.Location = New-Object System.Drawing.Point(820, 88)

$panelDash = New-Object System.Windows.Forms.Panel
$panelDash.Dock = "Top"
$panelDash.Height = 112
$panelDash.Controls.AddRange(@(
    $btnRefresh,
    $btnAnalyze,
    $btnDiagnostics,
    $btnCancelAnalyze,
    $btnAudit,
    $btnExecute,
    $btnCompute,
    $btnQuickClean,
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

        if ($null -ne $gui.ComputeAnalyzeDurationSec) {
            $v = [int]$gui.ComputeAnalyzeDurationSec
            if ($v -lt 2) { $v = 2 }
            if ($v -gt 30) { $v = 30 }
            $script:computeAnalyzeDurationSec = $v
        }

        if ($null -ne $gui.ComputeAnalyzeTop) {
            $v = [int]$gui.ComputeAnalyzeTop
            if ($v -lt 3) { $v = 3 }
            if ($v -gt 30) { $v = 30 }
            $script:computeAnalyzeTop = $v
        }

        if ($null -ne $gui.QuickCleanupRetentionDays) {
            $v = [int]$gui.QuickCleanupRetentionDays
            if ($v -lt 1) { $v = 1 }
            if ($v -gt 14) { $v = 14 }
            $script:quickCleanupRetentionDays = $v
        }

        if ($null -ne $gui.QuickCleanupMaxFilesPerTarget) {
            $v = [int]$gui.QuickCleanupMaxFilesPerTarget
            if ($v -lt 200) { $v = 200 }
            if ($v -gt 10000) { $v = 10000 }
            $script:quickCleanupMaxFilesPerTarget = $v
        }

        if ($null -ne $gui.DiagnosticRetentionDays) {
            $v = [int]$gui.DiagnosticRetentionDays
            if ($v -lt 1) { $v = 1 }
            if ($v -gt 30) { $v = 30 }
            $script:diagnosticRetentionDays = $v
        }
    }
}

function Get-DiagnosticLogFiles {
    return @(
        $script:analysisStdOut,
        $script:analysisStdErr,
        $script:cleanupStdOut,
        $script:cleanupStdErr,
        $script:computeStdOut,
        $script:computeStdErr,
        $script:quickCleanupStdOut,
        $script:quickCleanupStdErr,
        $script:defaultLog
    )
}

function Cleanup-DiagnosticLogs {
    param([int]$RetentionDays)

    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    $logsRoot = Join-Path $script:hubRoot "logs"

    if (-not (Test-Path -LiteralPath $logsRoot)) {
        return
    }

    # Keep JSON state files; rotate only textual logs and diagnostic snapshots.
    $targets = Get-ChildItem -LiteralPath $logsRoot -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            $_.LastWriteTime -lt $cutoff -and
            ($_.Extension -in @(".log", ".txt"))
        }

    foreach ($f in $targets) {
        try {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
        } catch {
            # Non-blocking retention cleanup.
        }
    }
}

function Open-DiagnosticsBundle {
    if (-not (Test-Path -LiteralPath $script:diagnosticsDir)) {
        New-Item -ItemType Directory -Path $script:diagnosticsDir -Force | Out-Null
    }

    $stamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
    $snapshotPath = Join-Path $script:diagnosticsDir ("diagnostics-{0}.txt" -f $stamp)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(("Timestamp: {0}" -f (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")))
    $lines.Add(("State: {0}" -f $lblAnalysisState.Text))
    $lines.Add(("PSHost: {0}" -f $script:psHost))
    $lines.Add("")
    $lines.Add("=== Recent Status (last 80 lines) ===")
    $statusLines = @($txtStatus.Lines)
    $start = [math]::Max(0, $statusLines.Count - 80)
    for ($i = $start; $i -lt $statusLines.Count; $i++) {
        $lines.Add($statusLines[$i])
    }
    $lines.Add("")
    $lines.Add("=== Worker Logs Tail ===")

    foreach ($path in (Get-DiagnosticLogFiles)) {
        $lines.Add(("--- {0} ---" -f $path))
        if (Test-Path -LiteralPath $path) {
            $tail = Get-Content -LiteralPath $path -Tail 20 -ErrorAction SilentlyContinue
            if ($tail) {
                foreach ($row in $tail) { $lines.Add([string]$row) }
            } else {
                $lines.Add("(empty)")
            }
        } else {
            $lines.Add("(missing)")
        }
        $lines.Add("")
    }

    $lines | Out-File -LiteralPath $snapshotPath -Encoding utf8 -Force
    Append-Status ("Diagnostics snapshot saved: {0}" -f $snapshotPath)
    Start-Process explorer.exe -ArgumentList $script:diagnosticsDir
}

function Wait-ForOutputFile {
    param(
        [string]$Path,
        [int]$TimeoutMs = 3000,
        [int]$PollMs = 150
    )

    $elapsed = 0
    while ($elapsed -lt $TimeoutMs) {
        if (Test-Path -LiteralPath $Path) {
            return $true
        }

        Start-Sleep -Milliseconds $PollMs
        $elapsed += $PollMs
    }

    return (Test-Path -LiteralPath $Path)
}

function Remove-IfExists {
    param([string]$Path)

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }
}

function Get-WorkerErrorTail {
    param([string]$ErrorPath)

    if (-not (Test-Path -LiteralPath $ErrorPath)) {
        return ""
    }

    $tail = (Get-Content -LiteralPath $ErrorPath -Tail 6 -ErrorAction SilentlyContinue) -join " | "
    return [string]$tail
}

function Get-ProcessExitCodeSafe {
    param([System.Diagnostics.Process]$Process)

    if ($null -eq $Process) {
        return -1
    }

    try {
        $Process.Refresh()
        if ($null -eq $Process.ExitCode) {
            return -1
        }
        return [int]$Process.ExitCode
    } catch {
        return -1
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

function Get-CleanupTimeoutSec {
    param(
        [string]$Depth,
        [bool]$ExecuteNow
    )

    $base = switch ($Depth) {
        "Quick" { 120 }
        "Deep" { 720 }
        default { 360 }
    }

    if ($ExecuteNow) {
        $base += 180
    }

    return $base
}

function Test-AnyOperationRunning {
    $busy = $false

    if ($script:analysisProcess -and (-not $script:analysisProcess.HasExited)) { $busy = $true }
    if ($script:cleanupProcess -and (-not $script:cleanupProcess.HasExited)) { $busy = $true }
    if ($script:computeProcess -and (-not $script:computeProcess.HasExited)) { $busy = $true }
    if ($script:quickCleanupProcess -and (-not $script:quickCleanupProcess.HasExited)) { $busy = $true }

    return $busy
}

function Set-AnalysisUiState {
    param(
        [bool]$IsBusy,
        [string]$StateText
    )

    $btnAnalyze.Enabled = -not $IsBusy
    $btnAudit.Enabled = -not $IsBusy
    $btnExecute.Enabled = -not $IsBusy
    $btnCompute.Enabled = -not $IsBusy
    $btnQuickClean.Enabled = -not $IsBusy
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

function Update-CleanupProgress {
    if (-not $script:cleanupStartedAt) {
        return
    }

    $elapsedSec = [math]::Round(((Get-Date) - $script:cleanupStartedAt).TotalSeconds, 0)
    $timeoutSec = [math]::Max(1, $script:cleanupTimeoutSec)
    $pct = [math]::Min(95, [int](($elapsedSec / $timeoutSec) * 100))

    if ($pct -lt $progressAnalysis.Minimum) {
        $pct = $progressAnalysis.Minimum
    }
    if ($pct -gt $progressAnalysis.Maximum) {
        $pct = $progressAnalysis.Maximum
    }

    $progressAnalysis.Value = $pct
    $lblAnalysisState.Text = ("Cleanup running: {0}s elapsed (target {1}s)" -f $elapsedSec, $timeoutSec)

    if (($elapsedSec -gt $timeoutSec) -and (-not $script:cleanupSoftTimeoutWarned)) {
        $script:cleanupSoftTimeoutWarned = $true
        Append-Status ("Cleanup exceeded expected time ({0}s). No forced stop applied; you can cancel manually." -f $timeoutSec)
        $lblAnalysisState.Text = ("Cleanup slower than expected ({0}s > {1}s)." -f $elapsedSec, $timeoutSec)
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

function Update-ComputeProgress {
    if (-not $script:computeStartedAt) {
        return
    }

    $elapsedSec = [math]::Round(((Get-Date) - $script:computeStartedAt).TotalSeconds, 0)
    $timeoutSec = [math]::Max(1, $script:computeTimeoutSec)
    $pct = [math]::Min(95, [int](($elapsedSec / $timeoutSec) * 100))

    if ($pct -lt $progressAnalysis.Minimum) { $pct = $progressAnalysis.Minimum }
    if ($pct -gt $progressAnalysis.Maximum) { $pct = $progressAnalysis.Maximum }

    $progressAnalysis.Value = $pct
    $lblAnalysisState.Text = ("Compute analysis running: {0}s elapsed (target {1}s)" -f $elapsedSec, $timeoutSec)

    if (($elapsedSec -gt $timeoutSec) -and (-not $script:computeSoftTimeoutWarned)) {
        $script:computeSoftTimeoutWarned = $true
        Append-Status ("Compute analysis exceeded expected time ({0}s). No forced stop applied; you can cancel manually." -f $timeoutSec)
        $lblAnalysisState.Text = ("Compute analysis slower than expected ({0}s > {1}s)." -f $elapsedSec, $timeoutSec)
    }
}

function Update-QuickCleanupProgress {
    if (-not $script:quickCleanupStartedAt) {
        return
    }

    $elapsedSec = [math]::Round(((Get-Date) - $script:quickCleanupStartedAt).TotalSeconds, 0)
    $timeoutSec = [math]::Max(1, $script:quickCleanupTimeoutSec)
    $pct = [math]::Min(95, [int](($elapsedSec / $timeoutSec) * 100))

    if ($pct -lt $progressAnalysis.Minimum) { $pct = $progressAnalysis.Minimum }
    if ($pct -gt $progressAnalysis.Maximum) { $pct = $progressAnalysis.Maximum }

    $progressAnalysis.Value = $pct
    $lblAnalysisState.Text = ("Quick cleanup running: {0}s elapsed (target {1}s)" -f $elapsedSec, $timeoutSec)

    if (($elapsedSec -gt $timeoutSec) -and (-not $script:quickCleanupSoftTimeoutWarned)) {
        $script:quickCleanupSoftTimeoutWarned = $true
        Append-Status ("Quick cleanup exceeded expected time ({0}s). No forced stop applied; you can cancel manually." -f $timeoutSec)
        $lblAnalysisState.Text = ("Quick cleanup slower than expected ({0}s > {1}s)." -f $elapsedSec, $timeoutSec)
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

function Stop-CleanupOperation {
    param([string]$Reason)

    if ($script:cleanupProcess -and (-not $script:cleanupProcess.HasExited)) {
        try {
            Stop-Process -Id $script:cleanupProcess.Id -Force -ErrorAction Stop
            Append-Status ("Cleanup stopped. Reason: {0}" -f $Reason)
        } catch {
            Append-Status ("Unable to stop cleanup cleanly: {0}" -f $_.Exception.Message)
        }
    }

    $cleanupTimer.Stop()
    $script:cleanupProcess = $null
    $script:cleanupStartedAt = $null
    $script:cleanupTimeoutSec = 0
    $script:cleanupSoftTimeoutWarned = $false
    $script:cleanupRunAnalyzeAfter = $false
    Set-AnalysisUiState -IsBusy:$false -StateText "Cleanup idle"
}

function Stop-ComputeAnalysis {
    param([string]$Reason)

    if ($script:computeProcess -and (-not $script:computeProcess.HasExited)) {
        try {
            Stop-Process -Id $script:computeProcess.Id -Force -ErrorAction Stop
            Append-Status ("Compute analysis stopped. Reason: {0}" -f $Reason)
        } catch {
            Append-Status ("Unable to stop compute analysis cleanly: {0}" -f $_.Exception.Message)
        }
    }

    $computeTimer.Stop()
    $script:computeProcess = $null
    $script:computeStartedAt = $null
    $script:computeSoftTimeoutWarned = $false
    Set-AnalysisUiState -IsBusy:$false -StateText "Compute analyzer idle"
}

function Stop-QuickCleanupOperation {
    param([string]$Reason)

    if ($script:quickCleanupProcess -and (-not $script:quickCleanupProcess.HasExited)) {
        try {
            Stop-Process -Id $script:quickCleanupProcess.Id -Force -ErrorAction Stop
            Append-Status ("Quick cleanup stopped. Reason: {0}" -f $Reason)
        } catch {
            Append-Status ("Unable to stop quick cleanup cleanly: {0}" -f $_.Exception.Message)
        }
    }

    $quickCleanupTimer.Stop()
    $script:quickCleanupProcess = $null
    $script:quickCleanupStartedAt = $null
    $script:quickCleanupSoftTimeoutWarned = $false
    Set-AnalysisUiState -IsBusy:$false -StateText "Quick cleanup idle"
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

    $analysisExitCode = Get-ProcessExitCodeSafe -Process $script:analysisProcess
    if ($analysisExitCode -ne 0) {
        $errTail = Get-WorkerErrorTail -ErrorPath $script:analysisStdErr
        if ($errTail) {
            Append-Status ("Analyzer process ended with exit code {0}. Error: {1}" -f $analysisExitCode, $errTail)
        } else {
            Append-Status ("Analyzer process ended with exit code {0}." -f $analysisExitCode)
        }
        $script:analysisProcess = $null
        $script:analysisStartedAt = $null
        $script:analysisTimeoutSec = 0
        $script:analysisSoftTimeoutWarned = $false
        Set-AnalysisUiState -IsBusy:$false -StateText "Analyzer idle"
        return
    }

    if (Wait-ForOutputFile -Path $script:analysisCsv -TimeoutMs 4000) {
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

function Poll-CleanupOperation {
    if (-not $script:cleanupProcess) {
        return
    }

    if (-not $script:cleanupProcess.HasExited) {
        Update-CleanupProgress
        return
    }

    $cleanupTimer.Stop()
    $durationSec = 0
    if ($script:cleanupStartedAt) {
        $durationSec = [math]::Round(((Get-Date) - $script:cleanupStartedAt).TotalSeconds, 1)
    }

    $cleanupExitCode = Get-ProcessExitCodeSafe -Process $script:cleanupProcess
    if ($cleanupExitCode -ne 0) {
        $errTail = Get-WorkerErrorTail -ErrorPath $script:cleanupStdErr
        if ($errTail) {
            Append-Status ("Cleanup process ended with exit code {0}. Error: {1}" -f $cleanupExitCode, $errTail)
        } else {
            Append-Status ("Cleanup process ended with exit code {0}." -f $cleanupExitCode)
        }
        $script:cleanupProcess = $null
        $script:cleanupStartedAt = $null
        $script:cleanupTimeoutSec = 0
        $script:cleanupSoftTimeoutWarned = $false
        $script:cleanupRunAnalyzeAfter = $false
        Set-AnalysisUiState -IsBusy:$false -StateText "Cleanup idle"
        return
    }

    if (Wait-ForOutputFile -Path $script:cleanupJson -TimeoutMs 4000) {
        try {
            $cleanupResult = Get-Content -LiteralPath $script:cleanupJson -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $cleanupSummary = "Cleanup completed in {0}s: Mode={1} CandidateFiles={2} CandidateGB={3} DeletedFiles={4} DeletedGB={5}" -f 
                $durationSec,
                [string]$cleanupResult.Mode,
                [int]$cleanupResult.CandidateFiles,
                [decimal]$cleanupResult.CandidateGB,
                [int]$cleanupResult.DeletedFiles,
                [decimal]$cleanupResult.DeletedGB
            Append-Status $cleanupSummary
        } catch {
            Append-Status ("Cleanup completed in {0}s but result parse failed: {1}" -f $durationSec, $_.Exception.Message)
        }
    } else {
        Append-Status ("Cleanup completed in {0}s but output JSON was not found." -f $durationSec)
    }

    Refresh-Drives
    $progressAnalysis.Value = 100
    $lblAnalysisState.Text = ("Cleanup completed in {0}s." -f $durationSec)

    $rerunAnalyze = $script:cleanupRunAnalyzeAfter
    $script:cleanupProcess = $null
    $script:cleanupStartedAt = $null
    $script:cleanupTimeoutSec = 0
    $script:cleanupSoftTimeoutWarned = $false
    $script:cleanupRunAnalyzeAfter = $false
    Set-AnalysisUiState -IsBusy:$false -StateText $lblAnalysisState.Text

    if ($rerunAnalyze) {
        Run-GarbageAnalysis
    }
}

function Poll-ComputeAnalysis {
    if (-not $script:computeProcess) {
        return
    }

    if (-not $script:computeProcess.HasExited) {
        Update-ComputeProgress
        return
    }

    $computeTimer.Stop()
    $durationSec = 0
    if ($script:computeStartedAt) {
        $durationSec = [math]::Round(((Get-Date) - $script:computeStartedAt).TotalSeconds, 1)
    }

    $computeExitCode = Get-ProcessExitCodeSafe -Process $script:computeProcess
    if ($computeExitCode -ne 0) {
        $errTail = Get-WorkerErrorTail -ErrorPath $script:computeStdErr
        if ($errTail) {
            Append-Status ("Compute analysis process ended with exit code {0}. Error: {1}" -f $computeExitCode, $errTail)
        } else {
            Append-Status ("Compute analysis process ended with exit code {0}." -f $computeExitCode)
        }
        $script:computeProcess = $null
        $script:computeStartedAt = $null
        $script:computeSoftTimeoutWarned = $false
        Set-AnalysisUiState -IsBusy:$false -StateText "Compute analyzer idle"
        return
    }

    if (Wait-ForOutputFile -Path $script:computeJson -TimeoutMs 4000) {
        try {
            $computeResult = Get-Content -LiteralPath $script:computeJson -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $topRows = @($computeResult.TopProcesses)
            Append-Status ("Compute analysis completed in {0}s. Observed={1} Top={2}" -f $durationSec, [int]$computeResult.TotalProcessesObserved, $topRows.Count)

            foreach ($proc in ($topRows | Select-Object -First 5)) {
                $computeSummary = "Compute Top PID={0} Name={1} Score={2} CPU={3}% RAM={4}MB IO={5}MB/s Pressure={6} Action={7}" -f 
                    [int]$proc.PID,
                    [string]$proc.ProcessName,
                    [decimal]$proc.Score,
                    [decimal]$proc.CpuPercent,
                    [decimal]$proc.WorkingSetMB,
                    [decimal]$proc.IoMBps,
                    [string]$proc.DominantPressure,
                    [string]$proc.Recommendation
                Append-Status $computeSummary
            }
        } catch {
            Append-Status ("Compute analysis completed in {0}s but result parse failed: {1}" -f $durationSec, $_.Exception.Message)
        }
    } else {
        Append-Status ("Compute analysis completed in {0}s but output JSON was not found." -f $durationSec)
    }

    $progressAnalysis.Value = 100
    $lblAnalysisState.Text = ("Compute analysis completed in {0}s." -f $durationSec)
    $script:computeProcess = $null
    $script:computeStartedAt = $null
    $script:computeSoftTimeoutWarned = $false
    Set-AnalysisUiState -IsBusy:$false -StateText $lblAnalysisState.Text
}

function Poll-QuickCleanup {
    if (-not $script:quickCleanupProcess) {
        return
    }

    if (-not $script:quickCleanupProcess.HasExited) {
        Update-QuickCleanupProgress
        return
    }

    $quickCleanupTimer.Stop()
    $durationSec = 0
    if ($script:quickCleanupStartedAt) {
        $durationSec = [math]::Round(((Get-Date) - $script:quickCleanupStartedAt).TotalSeconds, 1)
    }

    $quickExitCode = Get-ProcessExitCodeSafe -Process $script:quickCleanupProcess
    if ($quickExitCode -ne 0) {
        $errTail = Get-WorkerErrorTail -ErrorPath $script:quickCleanupStdErr
        if ($errTail) {
            Append-Status ("Quick cleanup process ended with exit code {0}. Error: {1}" -f $quickExitCode, $errTail)
        } else {
            Append-Status ("Quick cleanup process ended with exit code {0}." -f $quickExitCode)
        }
        $script:quickCleanupProcess = $null
        $script:quickCleanupStartedAt = $null
        $script:quickCleanupSoftTimeoutWarned = $false
        Set-AnalysisUiState -IsBusy:$false -StateText "Quick cleanup idle"
        return
    }

    if (Wait-ForOutputFile -Path $script:quickCleanupJson -TimeoutMs 4000) {
        try {
            $quickResult = Get-Content -LiteralPath $script:quickCleanupJson -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $quickSummary = "Quick cleanup completed in {0}s: Mode={1} CandidateFiles={2} CandidateGB={3} DeletedFiles={4} DeletedGB={5}" -f 
                $durationSec,
                [string]$quickResult.Mode,
                [int]$quickResult.CandidateFiles,
                [decimal]$quickResult.CandidateGB,
                [int]$quickResult.DeletedFiles,
                [decimal]$quickResult.DeletedGB
            Append-Status $quickSummary
        } catch {
            Append-Status ("Quick cleanup completed in {0}s but result parse failed: {1}" -f $durationSec, $_.Exception.Message)
        }
    } else {
        Append-Status ("Quick cleanup completed in {0}s but output JSON was not found." -f $durationSec)
    }

    Refresh-Drives
    $progressAnalysis.Value = 100
    $lblAnalysisState.Text = ("Quick cleanup completed in {0}s." -f $durationSec)
    $script:quickCleanupProcess = $null
    $script:quickCleanupStartedAt = $null
    $script:quickCleanupSoftTimeoutWarned = $false
    Set-AnalysisUiState -IsBusy:$false -StateText $lblAnalysisState.Text
}

function Run-GarbageAnalysis {
    if (-not (Test-Path -LiteralPath $script:analyzerScript)) {
        Append-Status "Analyzer script not found: $script:analyzerScript"
        return
    }

    if (Test-AnyOperationRunning) {
        Append-Status "Another operation is already running. Wait for completion."
        return
    }

    $depth = [string]$cmbDepth.SelectedItem
    $auditLevel = [string]$cmbAuditLevel.SelectedItem
    $cleanupMode = [string]$cmbCleanupMode.SelectedItem
    $top = [int]$numTop.Value

    try {
        Append-Status ("Analyzing garbage hotspots Depth={0} Audit={1} Mode={2} Top={3}" -f $depth, $auditLevel, $cleanupMode, $top)
        Remove-IfExists -Path $script:analysisCsv
        Remove-IfExists -Path $script:analysisStdOut
        Remove-IfExists -Path $script:analysisStdErr

        $args = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $script:analyzerScript,
            "-Drives", "C,D",
            "-Top", "$top",
            "-Depth", $depth,
            "-AuditLevel", $auditLevel,
            "-CleanupMode", $cleanupMode,
            "-OutputCsv", $script:analysisCsv
        )

        $script:analysisStartedAt = Get-Date
        $script:analysisTimeoutSec = Get-AnalysisTimeoutSec -Depth $depth
        $script:analysisSoftTimeoutWarned = $false
        $script:analysisProcess = Start-Process -FilePath $script:psHost -ArgumentList $args -WindowStyle Hidden -RedirectStandardOutput $script:analysisStdOut -RedirectStandardError $script:analysisStdErr -PassThru
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
    param(
        [bool]$ExecuteNow,
        [bool]$RunAnalyzeAfter
    )

    if (-not (Test-Path -LiteralPath $script:cleanupScript)) {
        Append-Status "Cleanup script not found: $script:cleanupScript"
        return
    }

    if (Test-AnyOperationRunning) {
        Append-Status "Another operation is already running. Wait for completion."
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
        "-CleanupMode", $cleanupMode,
        "-OutputJson", $script:cleanupJson
    )
    if ($ExecuteNow) {
        $args += "-Execute"
    }

    $action = if ($ExecuteNow) { "execute" } else { "audit" }
    Append-Status ("Running cleanup {0} with Depth={1}, Audit={2}, Mode={3}" -f $action, $depth, $auditLevel, $cleanupMode)
    try {
        Remove-IfExists -Path $script:cleanupJson
        Remove-IfExists -Path $script:cleanupStdOut
        Remove-IfExists -Path $script:cleanupStdErr

        $script:cleanupStartedAt = Get-Date
        $script:cleanupTimeoutSec = Get-CleanupTimeoutSec -Depth $depth -ExecuteNow:$ExecuteNow
        $script:cleanupSoftTimeoutWarned = $false
        $script:cleanupRunAnalyzeAfter = $RunAnalyzeAfter
        $script:cleanupProcess = Start-Process -FilePath $script:psHost -ArgumentList $args -WindowStyle Hidden -RedirectStandardOutput $script:cleanupStdOut -RedirectStandardError $script:cleanupStdErr -PassThru
        $progressAnalysis.Value = 1
        Set-AnalysisUiState -IsBusy:$true -StateText ("Cleanup starting (target {0}s)..." -f $script:cleanupTimeoutSec)
        $cleanupTimer.Start()
        Append-Status "Cleanup started in background. UI remains responsive."
    } catch {
        Append-Status ("Cleanup error: {0}" -f $_.Exception.Message)
        $script:cleanupProcess = $null
        $script:cleanupStartedAt = $null
        $script:cleanupTimeoutSec = 0
        $script:cleanupSoftTimeoutWarned = $false
        $script:cleanupRunAnalyzeAfter = $false
        Set-AnalysisUiState -IsBusy:$false -StateText "Cleanup idle"
    }
}

function Run-ComputeAnalysis {
    if (-not (Test-Path -LiteralPath $script:computeAnalyzerScript)) {
        Append-Status "Compute analyzer script not found: $script:computeAnalyzerScript"
        return
    }

    if (Test-AnyOperationRunning) {
        Append-Status "Another operation is already running. Wait for completion."
        return
    }

    try {
        Remove-IfExists -Path $script:computeJson
        Remove-IfExists -Path $script:computeStdOut
        Remove-IfExists -Path $script:computeStdErr

        $args = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $script:computeAnalyzerScript,
            "-DurationSec", "{0}" -f $script:computeAnalyzeDurationSec,
            "-Top", "{0}" -f $script:computeAnalyzeTop,
            "-OutputJson", $script:computeJson
        )

        $script:computeStartedAt = Get-Date
        $script:computeSoftTimeoutWarned = $false
        $script:computeProcess = Start-Process -FilePath $script:psHost -ArgumentList $args -WindowStyle Hidden -RedirectStandardOutput $script:computeStdOut -RedirectStandardError $script:computeStdErr -PassThru
        $progressAnalysis.Value = 1
        Set-AnalysisUiState -IsBusy:$true -StateText "Compute analysis starting (target 45s)..."
        $computeTimer.Start()
        Append-Status "Compute analysis started in background."
    } catch {
        Append-Status ("Compute analysis error: {0}" -f $_.Exception.Message)
        $script:computeProcess = $null
        $script:computeStartedAt = $null
        $script:computeSoftTimeoutWarned = $false
        Set-AnalysisUiState -IsBusy:$false -StateText "Compute analyzer idle"
    }
}

function Run-QuickCleanup {
    if (-not (Test-Path -LiteralPath $script:quickCleanupScript)) {
        Append-Status "Quick cleanup script not found: $script:quickCleanupScript"
        return
    }

    if (Test-AnyOperationRunning) {
        Append-Status "Another operation is already running. Wait for completion."
        return
    }

    try {
        Remove-IfExists -Path $script:quickCleanupJson
        Remove-IfExists -Path $script:quickCleanupStdOut
        Remove-IfExists -Path $script:quickCleanupStdErr

        $args = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $script:quickCleanupScript,
            "-Execute",
            "-RetentionDays", "{0}" -f $script:quickCleanupRetentionDays,
            "-MaxFilesPerTarget", "{0}" -f $script:quickCleanupMaxFilesPerTarget,
            "-OutputJson", $script:quickCleanupJson
        )

        $script:quickCleanupStartedAt = Get-Date
        $script:quickCleanupSoftTimeoutWarned = $false
        $script:quickCleanupProcess = Start-Process -FilePath $script:psHost -ArgumentList $args -WindowStyle Hidden -RedirectStandardOutput $script:quickCleanupStdOut -RedirectStandardError $script:quickCleanupStdErr -PassThru
        $progressAnalysis.Value = 1
        Set-AnalysisUiState -IsBusy:$true -StateText "Quick cleanup starting (target 120s)..."
        $quickCleanupTimer.Start()
        Append-Status "Quick cleanup started in background."
    } catch {
        Append-Status ("Quick cleanup error: {0}" -f $_.Exception.Message)
        $script:quickCleanupProcess = $null
        $script:quickCleanupStartedAt = $null
        $script:quickCleanupSoftTimeoutWarned = $false
        Set-AnalysisUiState -IsBusy:$false -StateText "Quick cleanup idle"
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
$btnDiagnostics.Add_Click({ Open-DiagnosticsBundle })
$btnCancelAnalyze.Add_Click({
    if ($script:analysisProcess -and (-not $script:analysisProcess.HasExited)) {
        $confirm = [System.Windows.Forms.MessageBox]::Show("Cancel running analysis?", "Confirm", "YesNo", "Question")
        if ($confirm -eq "Yes") {
            Stop-GarbageAnalysis -Reason "Manual cancel requested by user."
        }
        return
    }

    if ($script:cleanupProcess -and (-not $script:cleanupProcess.HasExited)) {
        $confirm = [System.Windows.Forms.MessageBox]::Show("Cancel running cleanup?", "Confirm", "YesNo", "Question")
        if ($confirm -eq "Yes") {
            Stop-CleanupOperation -Reason "Manual cancel requested by user."
        }
        return
    }

    if ($script:computeProcess -and (-not $script:computeProcess.HasExited)) {
        $confirm = [System.Windows.Forms.MessageBox]::Show("Cancel running compute analysis?", "Confirm", "YesNo", "Question")
        if ($confirm -eq "Yes") {
            Stop-ComputeAnalysis -Reason "Manual cancel requested by user."
        }
        return
    }

    if ($script:quickCleanupProcess -and (-not $script:quickCleanupProcess.HasExited)) {
        $confirm = [System.Windows.Forms.MessageBox]::Show("Cancel running quick cleanup?", "Confirm", "YesNo", "Question")
        if ($confirm -eq "Yes") {
            Stop-QuickCleanupOperation -Reason "Manual cancel requested by user."
        }
    }
})
$btnAudit.Add_Click({ Run-Cleanup -ExecuteNow:$false -RunAnalyzeAfter:$false })
$btnExecute.Add_Click({
    $mode = [string]$cmbCleanupMode.SelectedItem
    $confirm = [System.Windows.Forms.MessageBox]::Show(("Execute {0} cleanup now?" -f $mode), "Confirm", "YesNo", "Warning")
    if ($confirm -eq "Yes") {
        Run-Cleanup -ExecuteNow:$true -RunAnalyzeAfter:$true
    }
})
$btnCompute.Add_Click({ Run-ComputeAnalysis })
$btnQuickClean.Add_Click({
    $confirm = [System.Windows.Forms.MessageBox]::Show("Run quick safe cleanup now?", "Confirm", "YesNo", "Question")
    if ($confirm -eq "Yes") {
        Run-QuickCleanup
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
Cleanup-DiagnosticLogs -RetentionDays $script:diagnosticRetentionDays
if ($cmbDepth.Items.Contains($script:startupAnalyzeDepth)) {
    $cmbDepth.SelectedItem = $script:startupAnalyzeDepth
}
$numTop.Value = [decimal]$script:startupAnalyzeTop

$analysisTimer = New-Object System.Windows.Forms.Timer
$analysisTimer.Interval = 1000
$analysisTimer.Add_Tick({ Poll-GarbageAnalysis })

$cleanupTimer = New-Object System.Windows.Forms.Timer
$cleanupTimer.Interval = 1000
$cleanupTimer.Add_Tick({ Poll-CleanupOperation })

$computeTimer = New-Object System.Windows.Forms.Timer
$computeTimer.Interval = 1000
$computeTimer.Add_Tick({ Poll-ComputeAnalysis })

$quickCleanupTimer = New-Object System.Windows.Forms.Timer
$quickCleanupTimer.Interval = 1000
$quickCleanupTimer.Add_Tick({ Poll-QuickCleanup })

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
