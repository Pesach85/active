# Windows password prompt for HITL operator actions in WinForms GUI.

function Show-OperatorPasswordDialog {
    param(
        [System.Windows.Forms.Form]$Owner = $null,
        [string]$Language = 'en',
        [string]$Purpose = ''
    )

    $it = ($Language -eq 'it')
    $identity = $null
    if (Get-Command Get-OperatorWindowsIdentity -ErrorAction SilentlyContinue) {
        $identity = Get-OperatorWindowsIdentity
    } else {
        $identity = @{ UserName = [Environment]::UserName; Domain = $env:USERDOMAIN }
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = if ($it) { 'Conferma identità Windows' } else { 'Confirm Windows identity' }
    $form.Size = New-Object System.Drawing.Size(440, 200)
    $form.StartPosition = 'CenterParent'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.BackColor = $clrBg
    $form.ForeColor = $clrText
    $form.Font = $fntUI

    $lblUser = New-Object System.Windows.Forms.Label
    $lblUser.Text = if ($it) {
        "Utente: $($identity.Domain)\$($identity.UserName)"
    } else {
        "User: $($identity.Domain)\$($identity.UserName)"
    }
    $lblUser.AutoSize = $true
    $lblUser.Location = New-Object System.Drawing.Point(12, 12)

    $lblPurpose = New-Object System.Windows.Forms.Label
    $lblPurpose.Text = if ($Purpose) { $Purpose } elseif ($it) {
        "Inserisci la password Windows per autorizzare l'azione."
    } else {
        'Enter your Windows password to authorize this action.'
    }
    $lblPurpose.AutoSize = $true
    $lblPurpose.MaximumSize = New-Object System.Drawing.Size(400, 0)
    $lblPurpose.Location = New-Object System.Drawing.Point(12, 36)

    $lblPwd = New-Object System.Windows.Forms.Label
    $lblPwd.Text = if ($it) { 'Password:' } else { 'Password:' }
    $lblPwd.AutoSize = $true
    $lblPwd.Location = New-Object System.Drawing.Point(12, 72)

    $tbPwd = New-Object System.Windows.Forms.TextBox
    $tbPwd.UseSystemPasswordChar = $true
    $tbPwd.Width = 380
    $tbPwd.Location = New-Object System.Drawing.Point(12, 92)

    $btnOk = New-Btn $(if ($it) { 'Conferma' } else { 'Confirm' }) $clrAccent 100 32
    $btnOk.Location = New-Object System.Drawing.Point(12, 124)
    $btnCancel = New-Btn $(if ($it) { 'Annulla' } else { 'Cancel' }) $clrRaised 100 32
    $btnCancel.Location = New-Object System.Drawing.Point(118, 124)

    $form.Controls.AddRange(@($lblUser, $lblPurpose, $lblPwd, $tbPwd, $btnOk, $btnCancel))
    $form.AcceptButton = $btnOk
    $form.CancelButton = $btnCancel

    $script:authOk = $false
    $script:authPassword = $null

    $btnOk.Add_Click({
        if ([string]::IsNullOrWhiteSpace($tbPwd.Text)) {
            [void][System.Windows.Forms.MessageBox]::Show(
                $(if ($it) { 'Password obbligatoria.' } else { 'Password is required.' }),
                $form.Text, 'OK', 'Warning')
            return
        }
        $script:authPassword = $tbPwd.Text
        $script:authOk = $true
        $form.DialogResult = 'OK'
        $form.Close()
    })
    $btnCancel.Add_Click({
        $script:authOk = $false
        $form.DialogResult = 'Cancel'
        $form.Close()
    })

    if ($Owner) { [void]$form.ShowDialog($Owner) } else { [void]$form.ShowDialog() }
    $tbPwd.Text = ''
    return @{ Ok = $script:authOk; Password = $script:authPassword }
}

function Show-OperatorHitlSessionDialog {
    param(
        [System.Windows.Forms.Form]$Owner = $null,
        [string]$Language = 'en'
    )

    $it = ($Language -eq 'it')
    $identity = if (Get-Command Get-OperatorWindowsIdentity -ErrorAction SilentlyContinue) {
        Get-OperatorWindowsIdentity
    } else {
        @{ UserName = [Environment]::UserName; Domain = $env:USERDOMAIN }
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = if ($it) { 'Sblocco sessione HITL' } else { 'Unlock HITL session' }
    $form.Size = New-Object System.Drawing.Size(520, 320)
    $form.StartPosition = 'CenterParent'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.BackColor = $clrBg
    $form.ForeColor = $clrText
    $form.Font = $fntUI

    $lblIntro = New-Object System.Windows.Forms.Label
    $lblIntro.Text = if ($it) {
        "Una sola verifica per sessione (~45 min). Password + consapevolezza rischi.`nUtente: $($identity.Domain)\$($identity.UserName)"
    } else {
        "One verification per session (~45 min). Password + risk awareness.`nUser: $($identity.Domain)\$($identity.UserName)"
    }
    $lblIntro.AutoSize = $true
    $lblIntro.MaximumSize = New-Object System.Drawing.Size(480, 0)
    $lblIntro.Location = New-Object System.Drawing.Point(12, 12)

    $chkHuman = New-Object System.Windows.Forms.CheckBox
    $chkHuman.Text = if ($it) { 'Confermo di essere l operatore umano a questa console' } else { 'I confirm I am the human operator at this console' }
    $chkHuman.AutoSize = $true
    $chkHuman.Location = New-Object System.Drawing.Point(12, 72)

    $chkRisk = New-Object System.Windows.Forms.CheckBox
    $chkRisk.Text = if ($it) { 'Comprendo che throttle/terminate/Defender possono danneggiare il sistema' } else { 'I understand throttle/terminate/Defender actions can harm the system' }
    $chkRisk.AutoSize = $true
    $chkRisk.MaximumSize = New-Object System.Drawing.Size(480, 0)
    $chkRisk.Location = New-Object System.Drawing.Point(12, 98)

    $chkResp = New-Object System.Windows.Forms.CheckBox
    $chkResp.Text = if ($it) { 'Accetto responsabilita per le azioni di questa sessione' } else { 'I accept responsibility for actions in this session' }
    $chkResp.AutoSize = $true
    $chkResp.Location = New-Object System.Drawing.Point(12, 138)

    $lblPwd = New-Object System.Windows.Forms.Label
    $lblPwd.Text = if ($it) { 'Password Windows (solo ora):' } else { 'Windows password (once now):' }
    $lblPwd.AutoSize = $true
    $lblPwd.Location = New-Object System.Drawing.Point(12, 172)

    $tbPwd = New-Object System.Windows.Forms.TextBox
    $tbPwd.UseSystemPasswordChar = $true
    $tbPwd.Width = 460
    $tbPwd.Location = New-Object System.Drawing.Point(12, 192)

    $btnOk = New-Btn $(if ($it) { 'Sblocca sessione' } else { 'Unlock session' }) $clrAccent 140 32
    $btnOk.Location = New-Object System.Drawing.Point(12, 232)
    $btnCancel = New-Btn $(if ($it) { 'Annulla' } else { 'Cancel' }) $clrRaised 100 32
    $btnCancel.Location = New-Object System.Drawing.Point(158, 232)

    $form.Controls.AddRange(@($lblIntro, $chkHuman, $chkRisk, $chkResp, $lblPwd, $tbPwd, $btnOk, $btnCancel))
    $form.AcceptButton = $btnOk
    $form.CancelButton = $btnCancel

    $script:sessionOk = $false
    $script:sessionToken = $null

    $btnOk.Add_Click({
        if (-not $chkHuman.Checked -or -not $chkRisk.Checked -or -not $chkResp.Checked) {
            [void][System.Windows.Forms.MessageBox]::Show(
                $(if ($it) { 'Seleziona tutte le caselle di consapevolezza.' } else { 'Check all awareness boxes.' }),
                $form.Text, 'OK', 'Warning')
            return
        }
        if ([string]::IsNullOrWhiteSpace($tbPwd.Text)) {
            [void][System.Windows.Forms.MessageBox]::Show(
                $(if ($it) { 'Password obbligatoria per aprire la sessione.' } else { 'Password required to open session.' }),
                $form.Text, 'OK', 'Warning')
            return
        }
        try {
            $sess = Start-OperatorHitlSession -Password $tbPwd.Text -RiskAcknowledged -HumanPresent
            $script:sessionToken = [string]$sess.Token
            $script:sessionOk = $true
            $form.DialogResult = 'OK'
            $form.Close()
        } catch {
            [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, $form.Text, 'OK', 'Error')
        }
    })
    $btnCancel.Add_Click({ $script:sessionOk = $false; $form.DialogResult = 'Cancel'; $form.Close() })

    if ($Owner) { [void]$form.ShowDialog($Owner) } else { [void]$form.ShowDialog() }
    $tbPwd.Text = ''
    if (-not $script:sessionOk) { return @{ Ok = $false } }
    $sess = Get-OperatorHitlSession
    return @{ Ok = $true; SessionToken = $script:sessionToken; ExpiresAt = $sess.ExpiresAt }
}

function Show-ProcessPickerDialog {
    param(
        [System.Windows.Forms.Form]$Owner = $null,
        [string]$Language = 'en'
    )

    $it = ($Language -eq 'it')
    $procs = Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Id -gt 0 } |
        Sort-Object WorkingSet64 -Descending |
        Select-Object -First 80

    $form = New-Object System.Windows.Forms.Form
    $form.Text = if ($it) { 'Seleziona processo' } else { 'Pick process' }
    $form.Size = New-Object System.Drawing.Size(520, 420)
    $form.StartPosition = 'CenterParent'
    $form.BackColor = $clrBg
    $form.ForeColor = $clrText
    $form.Font = $fntUI

    $list = New-Object System.Windows.Forms.ListView
    $list.View = 'Details'
    $list.FullRowSelect = $true
    $list.Dock = 'Fill'
    $list.BackColor = $clrSurface
    $list.ForeColor = $clrText
    [void]$list.Columns.Add('Process', 140)
    [void]$list.Columns.Add('PID', 60)
    [void]$list.Columns.Add('RAM MB', 70)
    [void]$list.Columns.Add('Responding', 80)

    foreach ($p in $procs) {
        $item = New-Object System.Windows.Forms.ListViewItem([string]$p.ProcessName)
        [void]$item.SubItems.Add([string]$p.Id)
        [void]$item.SubItems.Add([string]([math]::Round($p.WorkingSet64 / 1MB, 1)))
        [void]$item.SubItems.Add([string]$p.Responding)
        $item.Tag = [int]$p.Id
        [void]$list.Items.Add($item)
    }

    $pnl = New-Object System.Windows.Forms.Panel
    $pnl.Dock = 'Bottom'
    $pnl.Height = 44
    $pnl.BackColor = $clrSurface
    $btnOk = New-Btn 'OK' $clrAccent 80 30
    $btnOk.Location = New-Object System.Drawing.Point(12, 8)
    $btnCancel = New-Btn $(if ($it) { 'Annulla' } else { 'Cancel' }) $clrRaised 80 30
    $btnCancel.Location = New-Object System.Drawing.Point(98, 8)
    $pnl.Controls.AddRange(@($btnOk, $btnCancel))

    $form.Controls.Add($list)
    $form.Controls.Add($pnl)

    $script:pickResult = $null
    $btnOk.Add_Click({
        if ($list.SelectedItems.Count -eq 0) { return }
        $sel = $list.SelectedItems[0]
        $script:pickResult = @{ ProcessId = [int]$sel.Tag; ProcessName = [string]$sel.Text }
        $form.DialogResult = 'OK'
        $form.Close()
    })
    $btnCancel.Add_Click({ $form.DialogResult = 'Cancel'; $form.Close() })
    $list.Add_DoubleClick({ if ($list.SelectedItems.Count -gt 0) { $btnOk.PerformClick() } })

    if ($Owner) { [void]$form.ShowDialog($Owner) } else { [void]$form.ShowDialog() }
    return $script:pickResult
}
