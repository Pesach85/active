# HITL Paths panel: 3 mutating paths with use-case copy + session unlock (one password per session).

function Get-HitlPathDefinitions {
    param([string]$Language = 'en')
    $it = ($Language -eq 'it')
    return @(
        [ordered]@{
            Id = 'resolve-apply'
            Title = if ($it) { 'Path 1 - Azione processo' } else { 'Path 1 - Process action' }
            UseCase = if ($it) {
                'Processo unknown o ad alta RAM dopo PPI. Throttle reversibile o terminate (HITL + confirm phrase).'
            } else {
                'Unknown or high-RAM process after PPI. Reversible throttle or terminate (HITL + confirm phrase).'
            }
            When = if ($it) { 'RAM/CPU hog non vitali, advisory raccomanda Throttle o Stop.' } else { 'Non-vital RAM/CPU hog; advisory recommends Throttle or Stop.' }
            Risk = if ($it) { 'Medio-alto (terminate irreversibile)' } else { 'Medium-high (terminate irreversible)' }
        },
        [ordered]@{
            Id = 'defender-apply'
            Title = if ($it) { 'Path 2 - Defender extreme' } else { 'Path 2 - Defender extreme' }
            UseCase = if ($it) {
                'MsMpEng satura risorse durante build/dev. Tier da composite >= 85: esclusioni, RT off, stop servizio.'
            } else {
                'MsMpEng saturates resources during build/dev. Tier from composite >= 85: exclusions, RT off, service stop.'
            }
            When = if ($it) { 'Composite Defender >= 85 e evaluation AllowedToProceed.' } else { 'Defender composite >= 85 and evaluation AllowedToProceed.' }
            Risk = if ($it) { 'Critico (disabilita AV)' } else { 'Critical (disables AV)' }
        },
        [ordered]@{
            Id = 'hub-use-core'
            Title = if ($it) { 'Path 3 - Hub Core routing' } else { 'Path 3 - Hub Core routing' }
            UseCase = if ($it) {
                'Instrada domini con parity verificata verso hub CLI (C#). Rollback: disattiva flag sessione.'
            } else {
                'Routes parity-verified domains to hub CLI (C#). Rollback: disable session flag.'
            }
            When = if ($it) { 'Dopo gate ALL PASSED per dominio; read-only gia sicuro senza flag.' } else { 'After ALL PASSED gate per domain; read-only safe without flag.' }
            Risk = if ($it) { 'Basso se solo read-only; alto se apply Core non parity' } else { 'Low if read-only only; high if apply without parity' }
        }
    )
}

function Show-HitlPathsPanel {
    param(
        [System.Windows.Forms.Form]$Owner,
        [string]$HubRoot,
        [string]$ScriptRoot,
        [string]$PsHost,
        [string]$Language = 'en',
        [scriptblock]$OnStatus,
        [scriptblock]$OnDefenderReview = $null
    )

    $it = ($Language -eq 'it')
    $paths = Get-HitlPathDefinitions -Language $Language

    $form = New-Object System.Windows.Forms.Form
    $form.Text = if ($it) { 'Path HITL - Controllo umano' } else { 'HITL Paths - Human control' }
    $form.Size = New-Object System.Drawing.Size(720, 520)
    $form.StartPosition = 'CenterParent'
    $form.BackColor = $clrBg
    $form.ForeColor = $clrText
    $form.Font = $fntUI

    $pnlTop = New-Object System.Windows.Forms.Panel
    $pnlTop.Dock = 'Top'
    $pnlTop.Height = 72
    $pnlTop.BackColor = $clrSurface

    $lblSession = New-Object System.Windows.Forms.Label
    $lblSession.AutoSize = $true
    $lblSession.Location = New-Object System.Drawing.Point(12, 12)
    $lblSession.Font = $fntH2
    $lblSession.ForeColor = $clrAccent

    $btnUnlock = New-Btn $(if ($it) { 'Sblocca sessione' } else { 'Unlock session' }) $clrGreen 130 34
    $btnUnlock.Location = New-Object System.Drawing.Point(12, 38)
    $btnEnd = New-Btn $(if ($it) { 'Termina sessione' } else { 'End session' }) $clrRed 120 34
    $btnEnd.Location = New-Object System.Drawing.Point(148, 38)
    $btnEnd.Enabled = $false

    $chkCore = New-Object System.Windows.Forms.CheckBox
    $chkCore.Text = if ($it) { 'Path 3: usa HUB_USE_CORE=1 per questa sessione GUI (domini parity)' } else { 'Path 3: use HUB_USE_CORE=1 for this GUI session (parity domains)' }
    $chkCore.AutoSize = $true
    $chkCore.MaximumSize = New-Object System.Drawing.Size(540, 0)
    $chkCore.Location = New-Object System.Drawing.Point(280, 42)

    $pnlTop.Controls.AddRange(@($lblSession, $btnUnlock, $btnEnd, $chkCore))

    $scroll = New-Object System.Windows.Forms.Panel
    $scroll.Dock = 'Fill'
    $scroll.AutoScroll = $true
    $scroll.BackColor = $clrBg

    function Update-SessionLabel {
        $sess = if (Get-Command Get-OperatorHitlSession -ErrorAction SilentlyContinue) { Get-OperatorHitlSession } else { $null }
        if ($sess) {
            $lblSession.Text = if ($it) {
                "Sessione attiva fino a $($sess.ExpiresAt.ToString('HH:mm'))"
            } else {
                "Session active until $($sess.ExpiresAt.ToString('HH:mm'))"
            }
            $lblSession.ForeColor = $clrGreen
            $btnUnlock.Visible = $false
            $btnEnd.Enabled = $true
            $pnlTop.Height = 44
        } else {
            $lblSession.Text = if ($it) { 'Sessione HITL: bloccata - sblocca una volta per tutte le azioni' } else { 'HITL session: locked - unlock once for all actions' }
            $lblSession.ForeColor = $clrRed
            $btnUnlock.Visible = $true
            $btnEnd.Enabled = $false
            $pnlTop.Height = 72
        }
    }

    $y = 8
    foreach ($p in $paths) {
        $gb = New-Object System.Windows.Forms.GroupBox
        $gb.Text = [string]$p.Title
        $gb.Width = 660
        $gb.Height = 118
        $gb.Location = New-Object System.Drawing.Point(8, $y)
        $gb.ForeColor = $clrText
        $gb.BackColor = $clrSurface

        $lblU = New-Object System.Windows.Forms.Label
        $lblU.Text = "Use case: $($p.UseCase)"
        $lblU.AutoSize = $true
        $lblU.MaximumSize = New-Object System.Drawing.Size(640, 0)
        $lblU.Location = New-Object System.Drawing.Point(10, 22)

        $lblW = New-Object System.Windows.Forms.Label
        $lblW.Text = $(if ($it) { "Quando: $($p.When)  |  Rischio: $($p.Risk)" } else { "When: $($p.When)  |  Risk: $($p.Risk)" })
        $lblW.AutoSize = $true
        $lblW.MaximumSize = New-Object System.Drawing.Size(640, 0)
        $lblW.Location = New-Object System.Drawing.Point(10, 58)
        $lblW.ForeColor = $clrMuted
        $lblW.Font = $fntSmall

        $gb.Controls.AddRange(@($lblU, $lblW))
        $scroll.Controls.Add($gb)
        $y += 126
    }

    $pnlActions = New-Object System.Windows.Forms.Panel
    $pnlActions.Dock = 'Bottom'
    $pnlActions.Height = 48
    $pnlActions.BackColor = $clrSurface

    $btnResolve = New-Btn $(if ($it) { 'Apri Resolve...' } else { 'Open Resolve...' }) $clrRed 120 34
    $btnResolve.Location = New-Object System.Drawing.Point(12, 8)
    $btnDef = New-Btn $(if ($it) { 'Defender Review...' } else { 'Defender Review...' }) $clrPurple 140 34
    $btnDef.Location = New-Object System.Drawing.Point(138, 8)
    $btnClose = New-Btn $(if ($it) { 'Chiudi' } else { 'Close' }) $clrRaised 90 34
    $btnClose.Location = New-Object System.Drawing.Point(284, 8)
    $pnlActions.Controls.AddRange(@($btnResolve, $btnDef, $btnClose))

    $form.Controls.Add($scroll)
    $form.Controls.Add($pnlActions)
    $form.Controls.Add($pnlTop)

    $btnUnlock.Add_Click({
        $r = Show-OperatorHitlSessionDialog -Owner $form -Language $Language
        if ($r.Ok -and $OnStatus) { & $OnStatus $(if ($it) { 'Sessione HITL sbloccata' } else { 'HITL session unlocked' }) }
        Update-SessionLabel
    })
    $btnEnd.Add_Click({
        if (Get-Command Clear-OperatorHitlSession -ErrorAction SilentlyContinue) { Clear-OperatorHitlSession | Out-Null }
        if ($OnStatus) { & $OnStatus $(if ($it) { 'Sessione HITL terminata' } else { 'HITL session ended' }) }
        Update-SessionLabel
    })
    $chkCore.Add_CheckedChanged({
        if ($chkCore.Checked) { $env:HUB_USE_CORE = '1' }
        else { Remove-Item Env:HUB_USE_CORE -ErrorAction SilentlyContinue }
    })

    $btnResolve.Add_Click({
        $sess = if (Get-Command Get-OperatorHitlSession -ErrorAction SilentlyContinue) { Get-OperatorHitlSession } else { $null }
        if (-not $sess) {
            [void][System.Windows.Forms.MessageBox]::Show(
                $(if ($it) { 'Sblocca la sessione HITL prima di Resolve.' } else { 'Unlock HITL session before Resolve.' }),
                'HITL', 'OK', 'Warning')
            return
        }
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $pnlActions.Enabled = $false
        try {
            $form.Hide()
            Show-UnknownProcessResolutionWizard -Owner $Owner -HubRoot $HubRoot -ScriptRoot $ScriptRoot `
                -PsHost $PsHost -Language $Language -OnStatus $OnStatus | Out-Null
            $form.Show()
        } finally {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
            $pnlActions.Enabled = $true
        }
    })

    $btnDef.Add_Click({
        $sess = if (Get-Command Get-OperatorHitlSession -ErrorAction SilentlyContinue) { Get-OperatorHitlSession } else { $null }
        if (-not $sess) {
            [void][System.Windows.Forms.MessageBox]::Show(
                $(if ($it) { 'Sblocca la sessione HITL prima di Defender Review.' } else { 'Unlock HITL session before Defender Review.' }),
                'HITL', 'OK', 'Warning')
            return
        }
        if ($OnDefenderReview) {
            $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
            $pnlActions.Enabled = $false
            if ($OnStatus) { & $OnStatus $(if ($it) { 'Defender review in corso...' } else { 'Defender review running...' }) }
            try {
                $form.Hide()
                & $OnDefenderReview
                $form.Show()
            } finally {
                $form.Cursor = [System.Windows.Forms.Cursors]::Default
                $pnlActions.Enabled = $true
            }
        } elseif ($OnStatus) {
            & $OnStatus $(if ($it) { 'Usa pulsante Defender nella toolbar principale' } else { 'Use Defender button on main toolbar' })
        }
    })

    $btnClose.Add_Click({ $form.Close() })

    Update-SessionLabel
    if ($Owner) { [void]$form.ShowDialog($Owner) } else { [void]$form.ShowDialog() }
}
