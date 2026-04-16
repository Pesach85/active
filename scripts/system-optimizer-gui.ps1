Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:defaultLog = "C:\\logs\\storage-cleanup.log"

$form = New-Object System.Windows.Forms.Form
$form.Text = "Windows Optimizer Console"
$form.Size = New-Object System.Drawing.Size(1000, 700)
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

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = "Refresh Drive Status"
$btnRefresh.Width = 180
$btnRefresh.Location = New-Object System.Drawing.Point(20, 20)

$btnAudit = New-Object System.Windows.Forms.Button
$btnAudit.Text = "Audit Cleanup"
$btnAudit.Width = 140
$btnAudit.Location = New-Object System.Drawing.Point(220, 20)

$btnExecute = New-Object System.Windows.Forms.Button
$btnExecute.Text = "Execute Cleanup"
$btnExecute.Width = 140
$btnExecute.Location = New-Object System.Drawing.Point(370, 20)

$panelDash = New-Object System.Windows.Forms.Panel
$panelDash.Dock = "Top"
$panelDash.Height = 60
$panelDash.Controls.AddRange(@($btnRefresh, $btnAudit, $btnExecute))

$tabDashboard.Controls.Add($txtStatus)
$tabDashboard.Controls.Add($panelDash)

$listTasks = New-Object System.Windows.Forms.ListView
$listTasks.View = 'Details'
$listTasks.FullRowSelect = $true
$listTasks.GridLines = $true
$listTasks.Dock = 'Fill'
$listTasks.Columns.Add('TaskName', 280) | Out-Null
$listTasks.Columns.Add('State', 120) | Out-Null
$listTasks.Columns.Add('NextRunTime', 220) | Out-Null

$btnReloadTasks = New-Object System.Windows.Forms.Button
$btnReloadTasks.Text = 'Reload Tasks'
$btnReloadTasks.Width = 120
$btnReloadTasks.Location = New-Object System.Drawing.Point(20, 20)

$btnInstallTasks = New-Object System.Windows.Forms.Button
$btnInstallTasks.Text = 'Install Core Tasks'
$btnInstallTasks.Width = 140
$btnInstallTasks.Location = New-Object System.Drawing.Point(160, 20)

$panelTask = New-Object System.Windows.Forms.Panel
$panelTask.Dock = 'Top'
$panelTask.Height = 60
$panelTask.Controls.AddRange(@($btnReloadTasks, $btnInstallTasks))

$tabTasks.Controls.Add($listTasks)
$tabTasks.Controls.Add($panelTask)

$txtLogs = New-Object System.Windows.Forms.TextBox
$txtLogs.Multiline = $true
$txtLogs.ScrollBars = 'Vertical'
$txtLogs.Dock = 'Fill'
$txtLogs.ReadOnly = $true

$btnLoadLogs = New-Object System.Windows.Forms.Button
$btnLoadLogs.Text = 'Load Last 200 Log Lines'
$btnLoadLogs.Width = 180
$btnLoadLogs.Location = New-Object System.Drawing.Point(20, 20)

$panelLog = New-Object System.Windows.Forms.Panel
$panelLog.Dock = 'Top'
$panelLog.Height = 60
$panelLog.Controls.Add($btnLoadLogs)

$tabLogs.Controls.Add($txtLogs)
$tabLogs.Controls.Add($panelLog)

$lblConfig = New-Object System.Windows.Forms.Label
$lblConfig.Text = "Config file: C:\\config\\sys-maintenance.json"
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

function Append-Status([string]$message) {
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $txtStatus.AppendText("$stamp - $message`r`n")
}

function Refresh-Drives {
    $drives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Name -in @('C','D') }
    $summary = $drives | ForEach-Object {
        "{0}: Free {1} GB / Total {2} GB" -f $_.Name, [math]::Round($_.Free/1GB,2), [math]::Round(($_.Free+$_.Used)/1GB,2)
    }
    Append-Status (($summary -join ' | '))
}

function Reload-Tasks {
    $listTasks.Items.Clear()
    $names = @('SystemResourceMonitor','StorageCleanupSafe')
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
            $item.SubItems.Add('Missing') | Out-Null
            $item.SubItems.Add('-') | Out-Null
            $listTasks.Items.Add($item) | Out-Null
        }
    }
}

$btnRefresh.Add_Click({ Refresh-Drives })
$btnAudit.Add_Click({
    Append-Status 'Running cleanup audit...'
    $result = & powershell -NoProfile -ExecutionPolicy Bypass -File "C:\scripts\cleanup-storage-safe.ps1"
    Append-Status ($result | Out-String)
})
$btnExecute.Add_Click({
    $confirm = [System.Windows.Forms.MessageBox]::Show('Execute safe cleanup now?', 'Confirm', 'YesNo', 'Warning')
    if ($confirm -eq 'Yes') {
        Append-Status 'Running cleanup execute...'
        $result = & powershell -NoProfile -ExecutionPolicy Bypass -File "C:\scripts\cleanup-storage-safe.ps1" -Execute
        Append-Status ($result | Out-String)
        Refresh-Drives
    }
})
$btnReloadTasks.Add_Click({ Reload-Tasks })
$btnInstallTasks.Add_Click({
    & powershell -NoProfile -ExecutionPolicy Bypass -File "C:\scripts\ensure-powershell-core.ps1" -InstallIfMissing -ApplyTasksCoreOnly
    Reload-Tasks
    Append-Status 'Core tasks installation completed.'
})
$btnLoadLogs.Add_Click({
    if (Test-Path -LiteralPath $script:defaultLog) {
        $txtLogs.Text = (Get-Content -LiteralPath $script:defaultLog -Tail 200 -ErrorAction SilentlyContinue) -join "`r`n"
    } else {
        $txtLogs.Text = "Log file not found: $script:defaultLog"
    }
})
$btnOpenConfig.Add_Click({
    $path = "C:\config\sys-maintenance.json"
    if (Test-Path -LiteralPath $path) {
        Start-Process notepad.exe -ArgumentList $path
    }
})

Refresh-Drives
Reload-Tasks
[void]$form.ShowDialog()
