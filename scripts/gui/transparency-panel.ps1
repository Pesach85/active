# WinForms "Controllo & Trasparenza" tab - dot-source from system-optimizer-gui.ps1
#
# Delayed scriptblocks (Refresh, clicks, ShowReport) MUST NOT close over function-local
# variables such as $tab. Under ps2exe + Set-StrictMode those closures are lost and the
# EXE shows: "Impossibile recuperare la variabile $tab perché non è stata impostata."
# Same pattern as Bug 28 ($global:HubWorkers): keep panel state on $global:.

function Initialize-HubTransparencyPanel {
    $var = Get-Variable -Name HubTransparencyPanel -Scope Global -ErrorAction SilentlyContinue
    if ($null -eq $var) {
        Set-Variable -Name HubTransparencyPanel -Scope Global -Value $null -Force
    }
}

function Get-HubTransparencyPanel {
    Initialize-HubTransparencyPanel
    $var = Get-Variable -Name HubTransparencyPanel -Scope Global -ErrorAction SilentlyContinue
    if ($null -eq $var) { return $null }
    return $var.Value
}

function Set-HubTransparencyPanel {
    param($State)
    Set-Variable -Name HubTransparencyPanel -Scope Global -Value $State -Force
}

Initialize-HubTransparencyPanel

function Get-PsNoteValue {
    param($Obj, [string]$Name)
    if ($null -eq $Obj) { return $null }
    $prop = $Obj.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Get-PsNoteArray {
    param($Obj, [string]$Name)
    $v = Get-PsNoteValue $Obj $Name
    if ($null -eq $v) { return , @() }
    return , @($v)
}

function New-TransparencyTab {
    param(
        [string]$HubRoot,
        [string]$ScriptRoot,
        [string]$ConfigPath,
        [scriptblock]$OnStatus,
        [scriptblock]$TestBusy,
        [scriptblock]$OnDefenderReview = $null
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

    $btnResolve = New-Btn 'Resolve...' $clrRed 100 38
    $btnResolve.Location = New-Object System.Drawing.Point(414, 14)

    $btnIdentify = New-Btn 'Identify...' $clrPurple 100 38
    $btnIdentify.Location = New-Object System.Drawing.Point(520, 14)

    $btnHitlPaths = New-Btn 'HITL Paths...' $clrAmber 110 38
    $btnHitlPaths.Location = New-Object System.Drawing.Point(626, 14)

    $lblPosture = New-Object System.Windows.Forms.Label
    $lblPosture.Text = 'Posture: -'
    $lblPosture.Font = $fntH2
    $lblPosture.ForeColor = $clrAccent
    $lblPosture.AutoSize = $true
    $lblPosture.Location = New-Object System.Drawing.Point(744, 18)
    $lblPosture.BackColor = [System.Drawing.Color]::Transparent

    $lblTransDesc = New-Object System.Windows.Forms.Label
    $lblTransDesc.Text = 'Human + AI shared control contract. T3 = unknown - classify before auto-action.'
    $lblTransDesc.Font = $fntSmall
    $lblTransDesc.ForeColor = $clrMuted
    $lblTransDesc.AutoSize = $true
    $lblTransDesc.Location = New-Object System.Drawing.Point(12, 48)
    $lblTransDesc.BackColor = [System.Drawing.Color]::Transparent

    $pnlHeaderBorder = New-Object System.Windows.Forms.Panel
    $pnlHeaderBorder.Dock = 'Bottom'
    $pnlHeaderBorder.Height = 1
    $pnlHeaderBorder.BackColor = $clrBorderC

    $pnlHeader.Controls.AddRange(@($btnRefresh, $btnOpenWeb, $btnRunReport, $btnResolve, $btnIdentify, $btnHitlPaths, $lblPosture, $lblTransDesc, $pnlHeaderBorder))

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

    $panelState = @{
        WebProcess     = $null
        RamPidByRow    = @{}
        ReportPath     = (Join-Path $HubRoot 'logs\transparency-report-latest.json')
        ConfigPath     = $ConfigPath
        HubRoot        = $HubRoot
        ScriptRoot     = $ScriptRoot
        BuildScript    = (Join-Path $ScriptRoot 'build-transparency-report.ps1')
        ServeScript    = (Join-Path $ScriptRoot 'serve-transparency-dashboard.ps1')
        EnsureWebScript = (Join-Path $ScriptRoot 'ensure-transparency-web.ps1')
        WebLogPath     = (Join-Path $HubRoot 'logs\transparency-web.log')
        WebErrLogPath  = (Join-Path $HubRoot 'logs\transparency-web.err.log')
        OnStatus       = $OnStatus
        OnDefenderReview = $OnDefenderReview
        TestBusy       = $TestBusy
        ListAgents     = $listAgents
        ListRam        = $listRam
        TxtDetail      = $txtDetail
        LblPosture     = $lblPosture
        Tab            = $tab
        BtnResolve     = $btnResolve
        ClrAccent      = $clrAccent
        ClrCyan        = $clrCyan
        ClrAmber       = $clrAmber
        ClrRed         = $clrRed
        ClrRowHigh     = $clrRowHigh
    }
    $tab.Tag = $panelState
    Set-HubTransparencyPanel -State $panelState

    $panelState.WaitTcp = {
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

    $panelState.GetTrustColor = {
        param([string]$Level)
        $st = Get-HubTransparencyPanel
        if ($null -eq $st) { return [System.Drawing.Color]::Gray }
        switch ($Level) {
            'T0_Observed' { return $st.ClrAccent }
            'T1_Delegated' { return $st.ClrCyan }
            'T2_Review' { return $st.ClrAmber }
            default { return $st.ClrRed }
        }
    }

    $panelState.ShowReport = {
        param($Report)
        $st = Get-HubTransparencyPanel
        if ($null -eq $st) { return }
        if (-not $Report) { return }

        $posture = Get-PsNoteValue $Report 'Posture'
        $score = [int](Get-PsNoteValue $posture 'Score')
        $grade = [string](Get-PsNoteValue $posture 'Grade')
        $st.LblPosture.Text = "Posture: $score/100 ($grade)"
        $st.LblPosture.ForeColor = switch ($grade) {
            'Good' { $st.ClrAccent }
            'Review' { $st.ClrAmber }
            default { $st.ClrRed }
        }

        $st.ListAgents.Items.Clear()
        foreach ($a in (Get-PsNoteArray $Report 'RegisteredAgents')) {
            $item = New-Object System.Windows.Forms.ListViewItem([string]$a.DisplayName)
            [void]$item.SubItems.Add([string]$a.TaskState)
            [void]$item.SubItems.Add([string]$a.ControlLevel)
            [void]$item.SubItems.Add([string]$a.LastRun)
            $item.ForeColor = & $st.GetTrustColor ([string]$a.ControlLevel)
            [void]$st.ListAgents.Items.Add($item)
        }

        $st.ListRam.Items.Clear()
        $st.RamPidByRow = @{}
        foreach ($p in (Get-PsNoteArray $Report 'RamConsumers')) {
            $item = New-Object System.Windows.Forms.ListViewItem([string]$p.Name)
            [void]$item.SubItems.Add([string]$p.RamMb)
            [void]$item.SubItems.Add([string]$p.TrustLevel)
            [void]$item.SubItems.Add([string]$p.TrustReason)
            $item.Tag = [int]$p.PID
            $st.RamPidByRow[[string]$p.Name] = [int]$p.PID
            $item.ForeColor = & $st.GetTrustColor ([string]$p.TrustLevel)
            if ([string]$p.TrustLevel -eq 'T3_Unknown') {
                $item.BackColor = $st.ClrRowHigh
            }
            [void]$st.ListRam.Items.Add($item)
        }

        $manifest = Get-PsNoteValue $Report 'DelegationManifest'
        $lines = [System.Collections.Generic.List[string]]::new()
        [void]$lines.Add('=== Delegation contract ===')
        foreach ($pr in (Get-PsNoteArray $manifest 'Principles')) { [void]$lines.Add("* $pr") }
        [void]$lines.Add('')
        [void]$lines.Add('=== Human only ===')
        foreach ($h in (Get-PsNoteArray $manifest 'HumanOnly')) { [void]$lines.Add("* $h") }
        [void]$lines.Add('')
        [void]$lines.Add('=== AI delegated (when enabled) ===')
        foreach ($d in (Get-PsNoteArray $manifest 'AiDelegatedWhenEnabled')) { [void]$lines.Add("* $d") }
        [void]$lines.Add('')
        [void]$lines.Add('=== Recent automated actions ===')
        foreach ($act in ((Get-PsNoteArray $Report 'RecentAutomatedActions') | Select-Object -Last 15)) {
            [void]$lines.Add(("{0} [{1}] {2}: {3}" -f $act.Timestamp, $act.Source, $act.Action, $act.Detail))
        }
        $unknownHigh = Get-PsNoteArray $Report 'UnknownHighRam'
        if ($unknownHigh.Count -gt 0) {
            [void]$lines.Add('')
            [void]$lines.Add('=== ALERT: Unknown high RAM ===')
            foreach ($u in $unknownHigh) {
                [void]$lines.Add(("{0} PID={1} {2}MB" -f $u.Name, $u.PID, $u.RamMb))
            }
        }
        $net = Get-PsNoteValue $Report 'Network'
        $ns = Get-PsNoteValue $net 'Summary'
        if ($ns) {
            [void]$lines.Add('')
            [void]$lines.Add('=== Network transparency ===')
            [void]$lines.Add(("{0} established | {1} listen | T3: {2} | hidden small: {3}" -f $ns.Established, $ns.Listen, $ns.UnknownTrustCount, $ns.HiddenNetworkProcessCount))
            foreach ($h in ((Get-PsNoteArray $net 'HiddenNetworkProcesses') | Select-Object -First 8)) {
                [void]$lines.Add(("{0} PID={1} {2}MB ext={3} - {4}" -f $h.Name, $h.PID, $h.RamMb, $h.ExternalConnections, $h.TrustReason))
            }
            foreach ($nc in ((Get-PsNoteArray $net 'Connections') | Where-Object { (Get-PsNoteValue $_ 'TrustLevel') -eq 'T3_Unknown' } | Select-Object -First 8)) {
                [void]$lines.Add(("[T3 NET] {0} {1} -> {2}" -f $nc.ProcessName, $nc.Local, $nc.Remote))
            }
        }
        $hints = Get-PsNoteValue $Report 'ClassificationHints'
        if ($hints) {
            [void]$lines.Add('')
            [void]$lines.Add('=== Classification hints (deterministic + KB + AI-assisted) ===')
            foreach ($h in @($hints | Select-Object -First 6)) {
                [void]$lines.Add(("{0} [{1}] conf={2} - {3}" -f $h.ProcessName, $h.SuggestedCategory, $h.Confidence, $h.WhatItIs))
                [void]$lines.Add(("  Does: {0}" -f $h.WhatItDoes))
                $hint = Get-PsNoteValue $h 'BusinessHint'
                if ($hint) { [void]$lines.Add(("  Hint: {0}" -f $hint)) }
            }
        }
        $st.TxtDetail.Text = ($lines -join [Environment]::NewLine)
    }

    $panelState.BuildReport = {
        param([switch]$Quiet)
        $st = Get-HubTransparencyPanel
        if ($null -eq $st) { return $null }
        if ($st.TestBusy -and (& $st.TestBusy)) {
            if (-not $Quiet) { [System.Windows.Forms.MessageBox]::Show('Another operation is running.', 'Busy') | Out-Null }
            return $null
        }

        $pwshExe = if (Get-Command Get-HubPwshExecutable -ErrorAction SilentlyContinue) {
            Get-HubPwshExecutable
        } else {
            $p = (Get-Command pwsh -ErrorAction SilentlyContinue).Path
            if (-not $p) { $p = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Path }
            if (-not $p) { $p = 'powershell.exe' }
            $p
        }

        $proc = Start-HubPowerShellProcess -FilePath $pwshExe -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $st.BuildScript,
            '-ConfigPath', $st.ConfigPath, '-OutputJson', $st.ReportPath
        ) -Wait -PassThru

        if ($proc.ExitCode -ne 0) { return $null }
        if (-not (Test-Path -LiteralPath $st.ReportPath)) { return $null }
        return (Get-Content -LiteralPath $st.ReportPath -Raw | ConvertFrom-Json)
    }

    $panelState.StartWeb = {
        $st = Get-HubTransparencyPanel
        if ($null -eq $st) { return $false }
        $pwshExe = if (Get-Command Get-HubPwshExecutable -ErrorAction SilentlyContinue) {
            Get-HubPwshExecutable
        } else {
            $p = (Get-Command pwsh -ErrorAction SilentlyContinue).Path
            if (-not $p) { $p = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Path }
            if (-not $p) { $p = 'powershell.exe' }
            $p
        }

        if (Test-Path -LiteralPath $st.EnsureWebScript) {
            $ensureArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $st.EnsureWebScript, '-ConfigPath', $st.ConfigPath, '-Quiet')
            $ensureProc = Start-HubPowerShellProcess -FilePath $pwshExe -ArgumentList $ensureArgs -Wait -PassThru
            if ($ensureProc.ExitCode -eq 0 -and (& $st.WaitTcp -Port 8765 -TimeoutSec 3)) { return $true }
        }

        if ($st.WebProcess -and -not $st.WebProcess.HasExited) {
            if (& $st.WaitTcp -Port 8765 -TimeoutSec 2) { return $true }
        }

        if (Test-Path -LiteralPath $st.WebLogPath) { Remove-Item -LiteralPath $st.WebLogPath -Force -ErrorAction SilentlyContinue }

        $st.WebProcess = Start-HubPowerShellProcess -FilePath $pwshExe -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $st.ServeScript,
            '-ConfigPath', $st.ConfigPath
        ) -PassThru -RedirectStandardOutput $st.WebLogPath -RedirectStandardError $st.WebErrLogPath

        if (& $st.WaitTcp -Port 8765 -TimeoutSec 25) { return $true }

        $tail = ''
        if (Test-Path -LiteralPath $st.WebErrLogPath) {
            $tail = (Get-Content -LiteralPath $st.WebErrLogPath -Tail 6 -ErrorAction SilentlyContinue) -join [Environment]::NewLine
        }
        if (-not $tail -and (Test-Path -LiteralPath $st.WebLogPath)) {
            $tail = (Get-Content -LiteralPath $st.WebLogPath -Tail 6 -ErrorAction SilentlyContinue) -join [Environment]::NewLine
        }
        throw ("Dashboard did not start on port 8765 within 25s.{0}{1}" -f [Environment]::NewLine, $tail)
    }

    $btnRefresh.Add_Click({
        $st = Get-HubTransparencyPanel
        if ($null -eq $st) { return }
        if ($st.OnStatus) { & $st.OnStatus 'Refreshing transparency report...' }
        $r = & $st.BuildReport
        if ($r) {
            & $st.ShowReport $r
            if ($st.OnStatus) { & $st.OnStatus 'Transparency report updated.' }
        } else {
            if ($st.OnStatus) { & $st.OnStatus 'Transparency report failed.' }
        }
    })

    $btnRunReport.Add_Click({
        $st = Get-HubTransparencyPanel
        if ($null -eq $st) { return }
        if ($st.OnStatus) { & $st.OnStatus 'Running full transparency audit...' }
        $r = & $st.BuildReport
        if ($r) {
            & $st.ShowReport $r
            if ($st.OnStatus) { & $st.OnStatus ("Audit complete. Posture {0}/100." -f $r.Posture.Score) }
        }
    })

    $btnOpenWeb.Add_Click({
        $st = Get-HubTransparencyPanel
        if ($null -eq $st) { return }
        try {
            & $st.BuildReport -Quiet | Out-Null
            [void](& $st.StartWeb)
            Start-Process 'http://127.0.0.1:8765/' | Out-Null
            if ($st.OnStatus) { & $st.OnStatus 'Web dashboard ready at http://127.0.0.1:8765/' }
        } catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Web Dashboard') | Out-Null
            if ($st.OnStatus) { & $st.OnStatus 'Web dashboard failed - see logs/transparency-web.log' }
        }
    })

    $btnResolve.Add_Click({
        $st = Get-HubTransparencyPanel
        if ($null -eq $st) { return }
        if (-not (Get-Command Show-UnknownProcessResolutionWizard -ErrorAction SilentlyContinue)) {
            [System.Windows.Forms.MessageBox]::Show('Unknown process wizard not loaded.', 'Resolve') | Out-Null
            return
        }
        $sel = $st.ListRam.SelectedItems
        $pidVal = 0
        $procName = ''
        if ($sel -and $sel.Count -gt 0) {
            $item = $sel[0]
            if ($item.Tag) { $pidVal = [int]$item.Tag }
            $procName = [string]$item.Text
        }
        $pwshExe = if (Get-Command Get-HubPwshExecutable -ErrorAction SilentlyContinue) {
            Get-HubPwshExecutable
        } else {
            (Get-Command powershell.exe).Path
        }
        $lang = 'en'
        if (Get-Command Get-I18nLang -ErrorAction SilentlyContinue) { $lang = Get-I18nLang }
        [void](Show-UnknownProcessResolutionWizard -Owner $st.Tab.FindForm() -HubRoot $st.HubRoot -ScriptRoot $st.ScriptRoot `
            -PsHost $pwshExe -Language $lang -OnStatus $st.OnStatus -ProcessId $pidVal -ProcessName $procName)
        $r = & $st.BuildReport -Quiet
        if ($r) { & $st.ShowReport $r }
    })

    $btnIdentify.Add_Click({
        $st = Get-HubTransparencyPanel
        if ($null -eq $st) { return }
        if (-not (Get-Command Show-IdentifyProcessWizard -ErrorAction SilentlyContinue)) {
            [System.Windows.Forms.MessageBox]::Show('Identify wizard not loaded.', 'Identify') | Out-Null
            return
        }
        $sel = $st.ListRam.SelectedItems
        $pidVal = 0
        $procName = ''
        if ($sel -and $sel.Count -gt 0) {
            $item = $sel[0]
            if ($item.Tag) { $pidVal = [int]$item.Tag }
            $procName = [string]$item.Text
        }
        $pwshExe = if (Get-Command Get-HubPwshExecutable -ErrorAction SilentlyContinue) {
            Get-HubPwshExecutable
        } else {
            (Get-Command powershell.exe).Path
        }
        $lang = 'en'
        if (Get-Command Get-I18nLang -ErrorAction SilentlyContinue) { $lang = Get-I18nLang }
        [void](Show-IdentifyProcessWizard -Owner $st.Tab.FindForm() -HubRoot $st.HubRoot -ScriptRoot $st.ScriptRoot `
            -PsHost $pwshExe -Language $lang -OnStatus $st.OnStatus -ProcessId $pidVal -ProcessName $procName)
        $r = & $st.BuildReport -Quiet
        if ($r) { & $st.ShowReport $r }
    })

    $btnHitlPaths.Add_Click({
        $st = Get-HubTransparencyPanel
        if ($null -eq $st) { return }
        if (-not (Get-Command Show-HitlPathsPanel -ErrorAction SilentlyContinue)) {
            [System.Windows.Forms.MessageBox]::Show('HITL paths panel not loaded.', 'HITL') | Out-Null
            return
        }
        $pwshExe = if (Get-Command Get-HubPwshExecutable -ErrorAction SilentlyContinue) {
            Get-HubPwshExecutable
        } else {
            (Get-Command powershell.exe).Path
        }
        $lang = 'en'
        if (Get-Command Get-I18nLang -ErrorAction SilentlyContinue) { $lang = Get-I18nLang }
        Show-HitlPathsPanel -Owner $st.Tab.FindForm() -HubRoot $st.HubRoot -ScriptRoot $st.ScriptRoot `
            -PsHost $pwshExe -Language $lang -OnStatus $st.OnStatus -OnDefenderReview $st.OnDefenderReview
    })

    $listRam.Add_DoubleClick({
        $st = Get-HubTransparencyPanel
        if ($null -eq $st) { return }
        if ($st.BtnResolve -and $st.BtnResolve.Enabled) { $st.BtnResolve.PerformClick() }
    })

    return @{
        Tab = $tab
        Refresh = {
            $st = Get-HubTransparencyPanel
            if ($null -eq $st) { return }
            if (Test-Path -LiteralPath $st.ReportPath) {
                try {
                    $r = Get-Content -LiteralPath $st.ReportPath -Raw | ConvertFrom-Json
                    & $st.ShowReport $r
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
