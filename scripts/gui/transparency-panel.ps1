# WinForms "Controllo & Trasparenza" tab — dot-source from system-optimizer-gui.ps1

function New-TransparencyTab {
    param(
        [string]$HubRoot,
        [string]$ScriptRoot,
        [string]$ConfigPath,
        [scriptblock]$OnStatus,
        [scriptblock]$TestBusy
    )

    $tab = New-Object System.Windows.Forms.TabPage
    $tab.Text = 'Control'
    $tab.BackColor = $clrBg
    $tab.UseVisualStyleBackColor = $false

    $pnlHeader = New-Object System.Windows.Forms.Panel
    $pnlHeader.Dock = 'Top'
    $pnlHeader.Height = 64
    $pnlHeader.BackColor = $clrSurface

    $btnRefresh = New-Btn 'Refresh' $clrAccent 120 38
    $btnRefresh.Location = New-Object System.Drawing.Point(12, 14)

    $btnOpenWeb = New-Btn 'Web Dashboard' $clrCyan 140 38
    $btnOpenWeb.Location = New-Object System.Drawing.Point(140, 14)

    $btnRunReport = New-Btn 'Full Audit' $clrPurple 120 38
    $btnRunReport.Location = New-Object System.Drawing.Point(288, 14)

    $btnResolve = New-Btn 'Resolve…' $clrRed 100 38
    $btnResolve.Location = New-Object System.Drawing.Point(414, 14)

    $lblPosture = New-Object System.Windows.Forms.Label
    $lblPosture.Text = 'Posture: —'
    $lblPosture.Font = $fntH2
    $lblPosture.ForeColor = $clrAccent
    $lblPosture.AutoSize = $true
    $lblPosture.Location = New-Object System.Drawing.Point(530, 18)
    $lblPosture.BackColor = [System.Drawing.Color]::Transparent

    $lblTransDesc = New-Object System.Windows.Forms.Label
    $lblTransDesc.Text = 'Human + AI shared control contract. T3 = unknown — classify before auto-action.'
    $lblTransDesc.Font = $fntSmall
    $lblTransDesc.ForeColor = $clrMuted
    $lblTransDesc.AutoSize = $true
    $lblTransDesc.Location = New-Object System.Drawing.Point(12, 48)
    $lblTransDesc.BackColor = [System.Drawing.Color]::Transparent

    $pnlHeaderBorder = New-Object System.Windows.Forms.Panel
    $pnlHeaderBorder.Dock = 'Bottom'
    $pnlHeaderBorder.Height = 1
    $pnlHeaderBorder.BackColor = $clrBorderC

    $pnlHeader.Controls.AddRange(@($btnRefresh, $btnOpenWeb, $btnRunReport, $btnResolve, $lblPosture, $lblTransDesc, $pnlHeaderBorder))

    $listAgents = New-Object System.Windows.Forms.ListView
    $listAgents.View = 'Details'
    $listAgents.FullRowSelect = $true
    $listAgents.Dock = 'Fill'
    $listAgents.BackColor = $clrSurface
    $listAgents.ForeColor = $clrText
    $listAgents.Font = $fntUI
    $listAgents.BorderStyle = 'None'
    [void]$listAgents.Columns.Add('Agent', 160)
    [void]$listAgents.Columns.Add('State', 90)
    [void]$listAgents.Columns.Add('Control', 110)
    [void]$listAgents.Columns.Add('Last Run', 140)

    $listRam = New-Object System.Windows.Forms.ListView
    $listRam.View = 'Details'
    $listRam.FullRowSelect = $true
    $listRam.Dock = 'Fill'
    $listRam.BackColor = $clrSurface
    $listRam.ForeColor = $clrText
    $listRam.Font = $fntUI
    $listRam.BorderStyle = 'None'
    [void]$listRam.Columns.Add('Process', 120)
    [void]$listRam.Columns.Add('RAM MB', 70)
    [void]$listRam.Columns.Add('Trust', 100)
    [void]$listRam.Columns.Add('Reason', 280)

    $txtDetail = New-Object System.Windows.Forms.TextBox
    $txtDetail.Multiline = $true
    $txtDetail.ScrollBars = 'Vertical'
    $txtDetail.Dock = 'Fill'
    $txtDetail.ReadOnly = $true
    $txtDetail.BackColor = $clrBg
    $txtDetail.ForeColor = $clrText
    $txtDetail.Font = $fntUI
    $txtDetail.BorderStyle = 'None'

    $splitLeft = New-Object System.Windows.Forms.SplitContainer
    $splitLeft.Dock = 'Fill'
    $splitLeft.Orientation = 'Vertical'
    $splitLeft.SplitterDistance = 420
    $splitLeft.BackColor = $clrBorderC
    $splitLeft.Panel1.BackColor = $clrBg
    $splitLeft.Panel2.BackColor = $clrBg
    $splitLeft.Panel1.Controls.Add($listAgents)
    $splitLeft.Panel2.Controls.Add($listRam)

    $splitMain = New-Object System.Windows.Forms.SplitContainer
    $splitMain.Dock = 'Fill'
    $splitMain.Orientation = 'Horizontal'
    $splitMain.SplitterDistance = 260
    $splitMain.BackColor = $clrBorderC
    $splitMain.Panel1.BackColor = $clrBg
    $splitMain.Panel2.BackColor = $clrBg
    $splitMain.Panel1.Controls.Add($splitLeft)
    $splitMain.Panel2.Controls.Add($txtDetail)

    $tab.SuspendLayout()
    $tab.Controls.Add($splitMain)
    $tab.Controls.Add($pnlHeader)
    $tab.ResumeLayout($false)

    $reportPath = Join-Path $HubRoot 'logs\transparency-report-latest.json'
    $serveScript = Join-Path $ScriptRoot 'serve-transparency-dashboard.ps1'
    $buildScript = Join-Path $ScriptRoot 'build-transparency-report.ps1'
    $panelState = @{ WebProcess = $null; RamPidByRow = @{} }
    $webLogPath = Join-Path $HubRoot 'logs\transparency-web.log'

    function Wait-HubTcpPort {
        param(
            [string]$Address = '127.0.0.1',
            [int]$Port = 8765,
            [int]$TimeoutSec = 25
        )
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        while ((Get-Date) -lt $deadline) {
            try {
                $hit = Get-NetTCPConnection -LocalAddress $Address -LocalPort $Port -State Listen -ErrorAction Stop
                if ($hit) { return $true }
            } catch { }
            Start-Sleep -Milliseconds 350
        }
        return $false
    }

    function Start-TransparencyWebServer {
        $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Path
        if (-not $pwsh) { $pwsh = (Get-Command powershell).Path }

        if ($panelState.WebProcess -and -not $panelState.WebProcess.HasExited) {
            if (Wait-HubTcpPort -Port 8765 -TimeoutSec 2) { return $true }
        }

        if (Test-Path -LiteralPath $webLogPath) { Remove-Item -LiteralPath $webLogPath -Force -ErrorAction SilentlyContinue }

        $panelState.WebProcess = Start-Process -FilePath $pwsh -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $serveScript,
            '-ConfigPath', $ConfigPath
        ) -PassThru -WindowStyle Hidden -RedirectStandardOutput $webLogPath -RedirectStandardError $webLogPath

        if (Wait-HubTcpPort -Port 8765 -TimeoutSec 25) { return $true }

        $tail = ''
        if (Test-Path -LiteralPath $webLogPath) {
            $tail = (Get-Content -LiteralPath $webLogPath -Tail 6 -ErrorAction SilentlyContinue) -join [Environment]::NewLine
        }
        throw ("Dashboard did not start on port 8765 within 25s.{0}{1}" -f [Environment]::NewLine, $tail)
    }

    function Get-TrustColor {
        param([string]$Level)
        switch ($Level) {
            'T0_Observed' { return $clrAccent }
            'T1_Delegated' { return $clrCyan }
            'T2_Review' { return $clrAmber }
            default { return $clrRed }
        }
    }

    function Show-TransparencyReport {
        param($Report)

        if (-not $Report) { return }

        $score = [int]$Report.Posture.Score
        $grade = [string]$Report.Posture.Grade
        $lblPosture.Text = "Posture: $score/100 ($grade)"
        $lblPosture.ForeColor = switch ($grade) {
            'Good' { $clrAccent }
            'Review' { $clrAmber }
            default { $clrRed }
        }

        $listAgents.Items.Clear()
        foreach ($a in @($Report.RegisteredAgents)) {
            $item = New-Object System.Windows.Forms.ListViewItem([string]$a.DisplayName)
            [void]$item.SubItems.Add([string]$a.TaskState)
            [void]$item.SubItems.Add([string]$a.ControlLevel)
            [void]$item.SubItems.Add([string]$a.LastRun)
            $item.ForeColor = Get-TrustColor ([string]$a.ControlLevel)
            [void]$listAgents.Items.Add($item)
        }

        $listRam.Items.Clear()
        $panelState.RamPidByRow = @{}
        foreach ($p in @($Report.RamConsumers)) {
            $item = New-Object System.Windows.Forms.ListViewItem([string]$p.Name)
            [void]$item.SubItems.Add([string]$p.RamMb)
            [void]$item.SubItems.Add([string]$p.TrustLevel)
            [void]$item.SubItems.Add([string]$p.TrustReason)
            $item.Tag = [int]$p.PID
            $panelState.RamPidByRow[[string]$p.Name] = [int]$p.PID
            $item.ForeColor = Get-TrustColor ([string]$p.TrustLevel)
            if ([string]$p.TrustLevel -eq 'T3_Unknown') {
                $item.BackColor = $clrRowHigh
            }
            [void]$listRam.Items.Add($item)
        }

        $lines = [System.Collections.Generic.List[string]]::new()
        [void]$lines.Add("=== Delegation contract ===")
        foreach ($pr in @($Report.DelegationManifest.Principles)) { [void]$lines.Add("• $pr") }
        [void]$lines.Add('')
        [void]$lines.Add('=== Human only ===')
        foreach ($h in @($Report.DelegationManifest.HumanOnly)) { [void]$lines.Add("• $h") }
        [void]$lines.Add('')
        [void]$lines.Add('=== AI delegated (when enabled) ===')
        foreach ($d in @($Report.DelegationManifest.AiDelegatedWhenEnabled)) { [void]$lines.Add("• $d") }
        [void]$lines.Add('')
        [void]$lines.Add('=== Recent automated actions ===')
        foreach ($act in @($Report.RecentAutomatedActions | Select-Object -Last 15)) {
            [void]$lines.Add(("{0} [{1}] {2}: {3}" -f $act.Timestamp, $act.Source, $act.Action, $act.Detail))
        }
        if (@($Report.UnknownHighRam).Count -gt 0) {
            [void]$lines.Add('')
            [void]$lines.Add('=== ALERT: Unknown high RAM ===')
            foreach ($u in @($Report.UnknownHighRam)) {
                [void]$lines.Add(("{0} PID={1} {2}MB" -f $u.Name, $u.PID, $u.RamMb))
            }
        }
        if ($Report.Network -and $Report.Network.Summary) {
            [void]$lines.Add('')
            [void]$lines.Add('=== Network transparency ===')
            $ns = $Report.Network.Summary
            [void]$lines.Add(("{0} established | {1} listen | T3: {2} | hidden small: {3}" -f $ns.Established, $ns.Listen, $ns.UnknownTrustCount, $ns.HiddenNetworkProcessCount))
            foreach ($h in @($Report.Network.HiddenNetworkProcesses | Select-Object -First 8)) {
                [void]$lines.Add(("{0} PID={1} {2}MB ext={3} — {4}" -f $h.Name, $h.PID, $h.RamMb, $h.ExternalConnections, $h.TrustReason))
            }
            foreach ($nc in @($Report.Network.Connections | Where-Object { $_.TrustLevel -eq 'T3_Unknown' } | Select-Object -First 8)) {
                [void]$lines.Add(("[T3 NET] {0} {1} -> {2}" -f $nc.ProcessName, $nc.Local, $nc.Remote))
            }
        }
        if ($Report.ClassificationHints) {
            [void]$lines.Add('')
            [void]$lines.Add('=== Classification hints (deterministic + KB + AI-assisted) ===')
            foreach ($h in @($Report.ClassificationHints | Select-Object -First 6)) {
                [void]$lines.Add(("{0} [{1}] conf={2} — {3}" -f $h.ProcessName, $h.SuggestedCategory, $h.Confidence, $h.WhatItIs))
                [void]$lines.Add(("  Does: {0}" -f $h.WhatItDoes))
                if ($h.BusinessHint) { [void]$lines.Add(("  Hint: {0}" -f $h.BusinessHint)) }
            }
        }
        $txtDetail.Text = ($lines -join [Environment]::NewLine)
    }

    function Invoke-BuildReport {
        param([switch]$Quiet)

        if ($TestBusy -and (& $TestBusy)) {
            if (-not $Quiet) { [System.Windows.Forms.MessageBox]::Show('Another operation is running.', 'Busy') | Out-Null }
            return $null
        }

        $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Path
        if (-not $pwsh) { $pwsh = (Get-Command powershell).Path }

        $p = Start-Process -FilePath $pwsh -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $buildScript,
            '-ConfigPath', $ConfigPath, '-OutputJson', $reportPath
        ) -Wait -PassThru -WindowStyle Hidden

        if ($p.ExitCode -ne 0) { return $null }
        if (-not (Test-Path -LiteralPath $reportPath)) { return $null }
        return (Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json)
    }

    $btnRefresh.Add_Click({
        if ($OnStatus) { & $OnStatus 'Refreshing transparency report…' }
        $r = Invoke-BuildReport
        if ($r) { Show-TransparencyReport -Report $r; if ($OnStatus) { & $OnStatus 'Transparency report updated.' } }
        else { if ($OnStatus) { & $OnStatus 'Transparency report failed.' } }
    })

    $btnRunReport.Add_Click({
        if ($OnStatus) { & $OnStatus 'Running full transparency audit…' }
        $r = Invoke-BuildReport
        if ($r) {
            Show-TransparencyReport -Report $r
            if ($OnStatus) { & $OnStatus ("Audit complete. Posture {0}/100." -f $r.Posture.Score) }
        }
    })

    $btnOpenWeb.Add_Click({
        try {
            Invoke-BuildReport -Quiet | Out-Null
            [void](Start-TransparencyWebServer)
            Start-Process 'http://127.0.0.1:8765/' | Out-Null
            if ($OnStatus) { & $OnStatus 'Web dashboard ready at http://127.0.0.1:8765/' }
        } catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Web Dashboard') | Out-Null
            if ($OnStatus) { & $OnStatus 'Web dashboard failed — see logs/transparency-web.log' }
        }
    })

    $btnResolve.Add_Click({
        if (-not (Get-Command Show-UnknownProcessResolutionWizard -ErrorAction SilentlyContinue)) {
            [System.Windows.Forms.MessageBox]::Show('Unknown process wizard not loaded.', 'Resolve') | Out-Null
            return
        }
        $sel = $listRam.SelectedItems
        if (-not $sel -or $sel.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('Select a process in the RAM list first.', 'Resolve') | Out-Null
            return
        }
        $item = $sel[0]
        $pidVal = 0
        if ($item.Tag) { $pidVal = [int]$item.Tag }
        $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Path
        if (-not $pwsh) { $pwsh = (Get-Command powershell).Path }
        $lang = 'en'
        if ($script:guiLanguage) { $lang = $script:guiLanguage }
        [void](Show-UnknownProcessResolutionWizard -Owner $tab.FindForm() -HubRoot $HubRoot -ScriptRoot $ScriptRoot `
            -PsHost $pwsh -Language $lang -OnStatus $OnStatus -ProcessId $pidVal -ProcessName ([string]$item.Text))
        $r = Invoke-BuildReport -Quiet
        if ($r) { Show-TransparencyReport -Report $r }
    })

    return @{
        Tab = $tab
        Refresh = {
            if (Test-Path -LiteralPath $reportPath) {
                try {
                    $r = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
                    Show-TransparencyReport -Report $r
                } catch { }
            }
        }
    }
}

function Set-TransparencyTabLanguage {
    param($Controls)

    if (-not (Get-Command Get-I18n -ErrorAction SilentlyContinue)) { return }
    if (-not $Controls) { return }

    $Controls.Tab.Text = Get-I18n 'tabs.control'
}
