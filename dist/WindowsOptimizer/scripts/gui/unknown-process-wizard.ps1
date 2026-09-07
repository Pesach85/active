# HITL wizard: resolve + manually identify unknown processes - no terminal required.

function Show-UnknownProcessResolutionWizard {
    param(
        [System.Windows.Forms.Form]$Owner,
        [string]$HubRoot,
        [string]$ScriptRoot,
        [string]$PsHost,
        [string]$Language = 'en',
        [scriptblock]$OnStatus,
        [int]$ProcessId = 0,
        [string]$ProcessName = '',
        [double]$RamMb = 0,
        [object]$ClassificationHint = $null,
        [switch]$IdentifyOnly
    )

    $it = ($Language -eq 'it')
    $resolveScript = Join-Path $ScriptRoot 'resolve-unknown-process.ps1'
    $identifyScript = Join-Path $ScriptRoot 'identify-unknown-process.ps1'
    $outJson = Join-Path $HubRoot 'logs\process-resolution-wizard.json'

    if ($ProcessId -le 0 -and -not $ProcessName) {
        $pick = Show-ProcessPickerDialog -Owner $Owner -Language $Language
        if (-not $pick) {
            return @{ Ok = $false; Reason = 'NoTarget' }
        }
        $ProcessId = [int]$pick.ProcessId
        $ProcessName = [string]$pick.ProcessName
    }

    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $resolveScript, '-Action', 'Advisory', '-OutputJson', $outJson, '-Offline')
    if ($ProcessId -gt 0) { $args += @('-ProcessId', "$ProcessId") }
    if ($ProcessName) { $args += @('-ProcessName', $ProcessName) }

    if ($Owner) { $Owner.Cursor = [System.Windows.Forms.Cursors]::WaitCursor }
    try {
        $p = Start-HubPowerShellProcess -FilePath $PsHost -ArgumentList $args -Wait -PassThru
    } finally {
        if ($Owner) { $Owner.Cursor = [System.Windows.Forms.Cursors]::Default }
    }
    if ($p.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $outJson)) {
        [void][System.Windows.Forms.MessageBox]::Show(
            $(if ($it) { "Impossibile costruire l'advisory. Seleziona un processo attivo dalla lista." } else { 'Failed to build advisory. Pick a running process from the list.' }),
            'Resolve', 'OK', 'Error')
        return @{ Ok = $false; Reason = 'AdvisoryFailed' }
    }

    $data = Get-Content -LiteralPath $outJson -Raw | ConvertFrom-Json
    $adv = $data.Advisory
    $hint = $data.KnowledgeHint
    if ($ProcessId -le 0 -and $data.Process.PID) { $ProcessId = [int]$data.Process.PID }
    if (-not $ProcessName) { $ProcessName = [string]$data.Process.ProcessName }

    $title = if ($IdentifyOnly) {
        if ($it) { 'Identifica processo' } else { 'Identify process' }
    } else {
        if ($it) { 'Risolvi processo (AI-aided)' } else { 'Resolve process (AI-aided)' }
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $title
    $form.Size = New-Object System.Drawing.Size(680, 580)
    $form.StartPosition = 'CenterParent'
    $form.BackColor = $clrBg
    $form.ForeColor = $clrText
    $form.Font = $fntUI

    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Dock = 'Fill'

    $tabAdv = New-Object System.Windows.Forms.TabPage
    $tabAdv.Text = if ($it) { 'Advisory & azioni' } else { 'Advisory & actions' }
    $tabAdv.BackColor = $clrBg

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Multiline = $true
    $txt.ReadOnly = $true
    $txt.ScrollBars = 'Vertical'
    $txt.Dock = 'Fill'
    $txt.BackColor = $clrSurface
    $txt.ForeColor = $clrText
    $txt.Font = $fntUI

    $lines = [System.Collections.Generic.List[string]]::new()
    [void]$lines.Add("=== $(if ($it) { 'PROCESSO' } else { 'PROCESS' }) ===")
    [void]$lines.Add(("{0} PID={1} RAM={2}MB" -f $data.Process.ProcessName, $data.Process.PID, $data.Process.RamMb))
    if ($data.Process.PSObject.Properties['NotRunning'] -and $data.Process.NotRunning) {
        [void]$lines.Add($(if ($it) { '! Processo non in esecuzione - azioni mutanti non disponibili.' } else { '! Process not running - mutating actions unavailable.' }))
    }
    [void]$lines.Add('')
    [void]$lines.Add('=== AI / KB (Cursor aided) ===')
    [void]$lines.Add([string]$adv.AiAidedSummary)
    if ($hint.WhatItIs) { [void]$lines.Add("WhatItIs: $($hint.WhatItIs)") }
    if ($hint.WhatItDoes) { [void]$lines.Add("WhatItDoes: $($hint.WhatItDoes)") }
    if ($hint.BusinessHint) { [void]$lines.Add("Hint: $($hint.BusinessHint)") }
    [void]$lines.Add('')
    [void]$lines.Add('=== WARNINGS ===')
    foreach ($w in @($adv.Warnings)) { [void]$lines.Add("* $w") }
    [void]$lines.Add('')
    [void]$lines.Add(">>> RECOMMENDED: $($adv.RecommendedActionId)")
    [void]$lines.Add('')
    foreach ($o in @($adv.Options)) {
        [void]$lines.Add(("[{0}] {1} - cost={2}" -f $o.ActionId, $o.Label, $o.EfficiencyCost))
    }
    $txt.Text = ($lines -join [Environment]::NewLine)

    $pnlAdvBtns = New-Object System.Windows.Forms.Panel
    $pnlAdvBtns.Dock = 'Bottom'
    $pnlAdvBtns.Height = 52
    $pnlAdvBtns.BackColor = $clrSurface

    $btnObserve = New-Btn $(if ($it) { 'Osserva' } else { 'Observe' }) $clrAccent 100 36
    $btnObserve.Location = New-Object System.Drawing.Point(12, 8)
    $btnThrottle = New-Btn 'Throttle' $clrGreen 100 36
    $btnThrottle.Location = New-Object System.Drawing.Point(118, 8)
    $btnKeep = New-Btn $(if ($it) { 'Necessario' } else { 'Work OK' }) $clrCyan 100 36
    $btnKeep.Location = New-Object System.Drawing.Point(224, 8)
    $btnStop = New-Btn 'Stop...' $clrRed 90 36
    $btnStop.Location = New-Object System.Drawing.Point(330, 8)

    $notRunning = $false
    if ($data.Process.PSObject.Properties['NotRunning'] -and $data.Process.NotRunning) { $notRunning = $true }
    $blocked = @()
    if ($data.Advisory -and $data.Advisory.BlockedActionIds) { $blocked = @($data.Advisory.BlockedActionIds) }
    if ($notRunning -or ($blocked -contains 'ThrottleBelowNormal')) { $btnThrottle.Enabled = $false }
    if ($notRunning -or ($blocked -contains 'Terminate')) { $btnStop.Enabled = $false }
    if ($data.CatalogNecessity -and [string]$data.CatalogNecessity.Priority -eq 'Keep' -and $OnStatus) {
        & $OnStatus $(if ($it) {
            'Priority=Keep: Throttle/Stop bloccati. Usa Osserva o tuning schedule/scope.'
        } else {
            'Priority=Keep: Throttle/Stop blocked. Use Observe or tune schedule/scope.'
        })
    }

    $pnlAdvBtns.Controls.AddRange(@($btnObserve, $btnThrottle, $btnKeep, $btnStop))
    $tabAdv.Controls.Add($txt)
    $tabAdv.Controls.Add($pnlAdvBtns)

    $tabId = New-Object System.Windows.Forms.TabPage
    $tabId.Text = if ($it) { 'Identifica manualmente' } else { 'Identify manually' }
    $tabId.BackColor = $clrBg
    $tabId.Padding = New-Object System.Windows.Forms.Padding(8)

    function New-FieldLabel([string]$Text, [int]$Y) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $Text
        $l.AutoSize = $true
        $l.Location = New-Object System.Drawing.Point(8, $Y)
        return $l
    }
    function New-FieldBox([int]$Y, [int]$H = 24) {
        $t = New-Object System.Windows.Forms.TextBox
        $t.Width = 620
        $t.Location = New-Object System.Drawing.Point(8, $Y)
        if ($H -gt 30) { $t.Multiline = $true; $t.Height = $H; $t.ScrollBars = 'Vertical' }
        return $t
    }

    $lblIdIntro = New-Object System.Windows.Forms.Label
    $lblIdIntro.Text = if ($it) {
        "Descrivi cos'e questo processo. Dopo il salvataggio: KB cache + merge catalogo (T1) + report."
    } else {
        'Describe what this process is. On save: KB cache + catalog merge (T1) + report refresh.'
    }
    $lblIdIntro.AutoSize = $true
    $lblIdIntro.MaximumSize = New-Object System.Drawing.Size(620, 0)
    $lblIdIntro.Location = New-Object System.Drawing.Point(8, 8)

    $tbWhatIs = New-FieldBox 48
    $tbWhatDoes = New-FieldBox 100 48
    $tbBusiness = New-FieldBox 180 40
    $tbNote = New-FieldBox 248 36

    $lblCat = New-FieldLabel $(if ($it) { 'Categoria:' } else { 'Category:' }) 292
    $cmbCat = New-Object System.Windows.Forms.ComboBox
    $cmbCat.DropDownStyle = 'DropDownList'
    $cmbCat.Width = 200
    $cmbCat.Location = New-Object System.Drawing.Point(8, 312)
    [void]$cmbCat.Items.AddRange(@('Unknown', 'Browser', 'Database', 'Virtualization', 'VPN', 'Security', 'IDE', 'Sync', 'Platform', 'DevTool', 'Game', 'Other'))

    $lblPri = New-FieldLabel $(if ($it) { 'Priorità:' } else { 'Priority:' }) 292
    $lblPri.Location = New-Object System.Drawing.Point(240, 292)
    $cmbPri = New-Object System.Windows.Forms.ComboBox
    $cmbPri.DropDownStyle = 'DropDownList'
    $cmbPri.Width = 120
    $cmbPri.Location = New-Object System.Drawing.Point(240, 312)
    [void]$cmbPri.Items.AddRange(@('Review', 'Tune', 'Keep'))
    $cmbPri.SelectedIndex = 0

    if ($hint.WhatItIs) { $tbWhatIs.Text = [string]$hint.WhatItIs }
    if ($hint.WhatItDoes) { $tbWhatDoes.Text = [string]$hint.WhatItDoes }
    if ($hint.BusinessHint) { $tbBusiness.Text = [string]$hint.BusinessHint }
    if ($hint.SuggestedCategory) {
        $idx = $cmbCat.Items.IndexOf([string]$hint.SuggestedCategory)
        if ($idx -ge 0) { $cmbCat.SelectedIndex = $idx } else { $cmbCat.SelectedIndex = 0 }
    } else { $cmbCat.SelectedIndex = 0 }

    $btnSaveId = New-Btn $(if ($it) { 'Salva identificazione' } else { 'Save identification' }) $clrAccent 160 36
    $btnSaveId.Location = New-Object System.Drawing.Point(8, 350)

    $tabId.Controls.AddRange(@(
        $lblIdIntro,
        (New-FieldLabel $(if ($it) { "Cos'e:" } else { 'What it is:' }) 28),
        $tbWhatIs,
        (New-FieldLabel $(if ($it) { 'Cosa fa:' } else { 'What it does:' }) 76),
        $tbWhatDoes,
        (New-FieldLabel $(if ($it) { 'Suggerimento lavoro:' } else { 'Work hint:' }) 156),
        $tbBusiness,
        (New-FieldLabel $(if ($it) { 'Nota operatore:' } else { 'Operator note:' }) 224),
        $tbNote,
        $lblCat, $cmbCat, $lblPri, $cmbPri,
        $btnSaveId
    ))

    $tabs.TabPages.AddRange(@($tabAdv, $tabId))
    if ($IdentifyOnly) { $tabs.SelectedTab = $tabId }

    $pnlFooter = New-Object System.Windows.Forms.Panel
    $pnlFooter.Dock = 'Bottom'
    $pnlFooter.Height = 44
    $pnlFooter.BackColor = $clrSurface
    $btnCancel = New-Btn $(if ($it) { 'Chiudi' } else { 'Close' }) $clrRaised 90 32
    $btnCancel.Location = New-Object System.Drawing.Point(12, 8)
    $pnlFooter.Controls.Add($btnCancel)

    $form.Controls.Add($tabs)
    $form.Controls.Add($pnlFooter)

    function Get-SessionTokenOrUnlock {
        $sess = if (Get-Command Get-OperatorHitlSession -ErrorAction SilentlyContinue) { Get-OperatorHitlSession } else { $null }
        if ($sess -and $sess.Token) { return [string]$sess.Token }
        $unlock = Show-OperatorHitlSessionDialog -Owner $form -Language $Language
        if (-not $unlock.Ok) { return $null }
        return [string]$unlock.SessionToken
    }

    function Invoke-ResolutionAction {
        param([string]$ActionName, [string]$Confirm = '')

        $sessionToken = Get-SessionTokenOrUnlock
        if (-not $sessionToken) { return $false }

        $authLib = Join-Path $ScriptRoot 'lib\operator-auth.ps1'
        if (Test-Path -LiteralPath $authLib) { . $authLib }

        $body = @{
            action = $ActionName
            sessionToken = $sessionToken
        }
        if ($ProcessId -gt 0) { $body.processId = $ProcessId }
        if ($ProcessName) { $body.processName = $ProcessName }
        if ($Confirm) { $body.confirmPhrase = $Confirm }

        try {
            $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
            $pnlAdvBtns.Enabled = $false
            $btnSaveId.Enabled = $false
            if (Get-Command Invoke-HubProcessScriptViaRequest -ErrorAction SilentlyContinue) {
                $run = Invoke-HubProcessScriptViaRequest -ScriptPath $resolveScript -RequestBody $body `
                    -LogsDir (Join-Path $HubRoot 'logs') -PwshExe $PsHost -HubRoot $HubRoot
                if ($run.ExitCode -ne 0) {
                    $msg = if ($run.Payload -and $run.Payload.Message) { [string]$run.Payload.Message }
                           elseif ($run.Stderr) { [string]$run.Stderr }
                           else { $(if ($it) { 'Azione fallita' } else { 'Action failed' }) }
                    [void][System.Windows.Forms.MessageBox]::Show($msg, 'Resolve', 'OK', 'Error')
                    return $false
                }
            } else {
                throw 'Invoke-HubProcessScriptViaRequest not available'
            }
            if ($OnStatus) { & $OnStatus ("Process resolution: $ActionName") }
            return $true
        } catch {
            [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Resolve', 'OK', 'Error')
            return $false
        } finally {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
            $pnlAdvBtns.Enabled = $true
            $btnSaveId.Enabled = $true
        }
    }

    function Show-PhrasePrompt {
        param([string]$Prompt, [string]$Title)
        $d = New-Object System.Windows.Forms.Form
        $d.Text = $Title
        $d.Size = New-Object System.Drawing.Size(420, 140)
        $d.StartPosition = 'CenterParent'
        $d.BackColor = $clrBg
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $Prompt
        $lbl.AutoSize = $true
        $lbl.Location = New-Object System.Drawing.Point(12, 12)
        $tb = New-Object System.Windows.Forms.TextBox
        $tb.Width = 380
        $tb.Location = New-Object System.Drawing.Point(12, 36)
        $ok = New-Btn 'OK' $clrAccent 80 30
        $ok.Location = New-Object System.Drawing.Point(12, 68)
        $d.Controls.AddRange(@($lbl, $tb, $ok))
        $script:phraseResult = $null
        $ok.Add_Click({ $script:phraseResult = $tb.Text; $d.Close() })
        [void]$d.ShowDialog($form)
        return $script:phraseResult
    }

    $btnObserve.Add_Click({
        if (Invoke-ResolutionAction -ActionName 'Observe') { $form.DialogResult = 'OK'; $form.Close() }
    })
    $btnThrottle.Add_Click({
        $msg = if ($it) { "Throttle BelowNormal su $($data.Process.ProcessName)? (reversibile)" } else { "Throttle BelowNormal on $($data.Process.ProcessName)? (reversible)" }
        if ([System.Windows.Forms.MessageBox]::Show($msg, 'Throttle', 'YesNo', 'Question') -eq 'Yes' -and (Invoke-ResolutionAction -ActionName 'ThrottleBelowNormal')) {
            $form.DialogResult = 'OK'; $form.Close()
        }
    })
    $btnKeep.Add_Click({
        $phrase = 'KEEP FOR WORK'
        $input = Show-PhrasePrompt -Prompt $(if ($it) { "Digita: $phrase" } else { "Type: $phrase" }) -Title 'Mark work necessary'
        if ($input -eq $phrase -and (Invoke-ResolutionAction -ActionName 'MarkWorkNecessary' -Confirm $phrase)) {
            $form.DialogResult = 'OK'; $form.Close()
        }
    })
    $btnStop.Add_Click({
        if ([System.Windows.Forms.MessageBox]::Show(
            $(if ($it) { 'ATTENZIONE: chiudere il processo può causare perdita dati.' } else { 'WARNING: stopping may cause data loss.' }),
            'Stop', 'YesNo', 'Warning') -ne 'Yes') { return }
        $phrase = 'STOP UNKNOWN'
        $input = Show-PhrasePrompt -Prompt $(if ($it) { "Digita: $phrase" } else { "Type: $phrase" }) -Title 'Confirm terminate'
        if ($input -eq $phrase -and (Invoke-ResolutionAction -ActionName 'Terminate' -Confirm $phrase)) {
            $form.DialogResult = 'OK'; $form.Close()
        }
    })

    $btnSaveId.Add_Click({
        if ([string]::IsNullOrWhiteSpace($tbWhatIs.Text) -or [string]::IsNullOrWhiteSpace($tbWhatDoes.Text)) {
            [void][System.Windows.Forms.MessageBox]::Show(
                $(if ($it) { "Compila almeno Cos'e e Cosa fa." } else { 'Fill at least What it is and What it does.' }),
                'Identify', 'OK', 'Warning')
            return
        }
        $sessionToken = Get-SessionTokenOrUnlock
        if (-not $sessionToken) { return }

        $authLib = Join-Path $ScriptRoot 'lib\operator-auth.ps1'
        if (Test-Path -LiteralPath $authLib) { . $authLib }

        $body = @{
            whatItIs = $tbWhatIs.Text.Trim()
            whatItDoes = $tbWhatDoes.Text.Trim()
            category = [string]$cmbCat.SelectedItem
            priority = [string]$cmbPri.SelectedItem
            businessHint = $tbBusiness.Text.Trim()
            note = $tbNote.Text.Trim()
            sessionToken = $sessionToken
        }
        if ($ProcessId -gt 0) { $body.processId = $ProcessId }
        if ($ProcessName) { $body.processName = $ProcessName }

        try {
            $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
            $btnSaveId.Enabled = $false
            $pnlAdvBtns.Enabled = $false
            if (-not (Get-Command Invoke-HubProcessScriptViaRequest -ErrorAction SilentlyContinue)) {
                throw 'Invoke-HubProcessScriptViaRequest not available'
            }
            $run = Invoke-HubProcessScriptViaRequest -ScriptPath $identifyScript -RequestBody $body `
                -LogsDir (Join-Path $HubRoot 'logs') -PwshExe $PsHost -HubRoot $HubRoot
            if ($run.ExitCode -ne 0) {
                $msg = if ($run.Payload -and $run.Payload.Message) { [string]$run.Payload.Message }
                       elseif ($run.Stderr) { [string]$run.Stderr }
                       else { 'Identify failed.' }
                [void][System.Windows.Forms.MessageBox]::Show($msg, 'Identify', 'OK', 'Error')
                return
            }
        } catch {
            [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Identify', 'OK', 'Error')
            return
        } finally {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
            $btnSaveId.Enabled = $true
            $pnlAdvBtns.Enabled = $true
        }
        if ($OnStatus) { & $OnStatus ("Identified: $ProcessName") }
        [void][System.Windows.Forms.MessageBox]::Show(
            $(if ($it) { 'Identificazione salvata in KB cache.' } else { 'Identification saved to KB cache.' }),
            'Identify', 'OK', 'Information')
        $form.DialogResult = 'OK'
        $form.Close()
    })

    $btnCancel.Add_Click({ $form.DialogResult = 'Cancel'; $form.Close() })

    if ($Owner) { [void]$form.ShowDialog($Owner) } else { [void]$form.ShowDialog() }
    return @{ Ok = ($form.DialogResult -eq 'OK') }
}

function Show-IdentifyProcessWizard {
    param(
        [System.Windows.Forms.Form]$Owner,
        [string]$HubRoot,
        [string]$ScriptRoot,
        [string]$PsHost,
        [string]$Language = 'en',
        [scriptblock]$OnStatus,
        [int]$ProcessId = 0,
        [string]$ProcessName = ''
    )
    return Show-UnknownProcessResolutionWizard -Owner $Owner -HubRoot $HubRoot -ScriptRoot $ScriptRoot `
        -PsHost $PsHost -Language $Language -OnStatus $OnStatus `
        -ProcessId $ProcessId -ProcessName $ProcessName -IdentifyOnly
}
