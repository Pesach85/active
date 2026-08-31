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
