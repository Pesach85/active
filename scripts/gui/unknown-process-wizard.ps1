# HITL wizard for unknown / uncharacterized processes — operator is sole authority.

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
        [object]$ClassificationHint = $null
    )

    $it = ($Language -eq 'it')
    $resolveScript = Join-Path $ScriptRoot 'resolve-unknown-process.ps1'
    $outJson = Join-Path $HubRoot 'logs\process-resolution-wizard.json'

    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $resolveScript, '-Action', 'Advisory', '-OutputJson', $outJson, '-Offline')
    if ($ProcessId -gt 0) { $args += @('-ProcessId', "$ProcessId") }
    elseif ($ProcessName) { $args += @('-ProcessName', $ProcessName) }
    else {
        [void][System.Windows.Forms.MessageBox]::Show(
            $(if ($it) { 'Seleziona un processo dalla lista RAM.' } else { 'Select a process from the RAM list.' }),
            'Resolve', 'OK', 'Warning')
        return @{ Ok = $false; Reason = 'NoTarget' }
    }

    $p = Start-Process -FilePath $PsHost -ArgumentList $args -Wait -PassThru -WindowStyle Hidden
    if ($p.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $outJson)) {
        [void][System.Windows.Forms.MessageBox]::Show('Failed to build resolution advisory.', 'Resolve', 'OK', 'Error')
        return @{ Ok = $false; Reason = 'AdvisoryFailed' }
    }

    $data = Get-Content -LiteralPath $outJson -Raw | ConvertFrom-Json
    $adv = $data.Advisory
    $hint = $data.KnowledgeHint

    $title = if ($it) { 'Risolvi processo sconosciuto' } else { 'Resolve unknown process' }
    $form = New-Object System.Windows.Forms.Form
    $form.Text = $title
    $form.Size = New-Object System.Drawing.Size(620, 520)
    $form.StartPosition = 'CenterParent'
    $form.BackColor = $clrBg
    $form.ForeColor = $clrText
    $form.Font = $fntUI

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
    [void]$lines.Add('')
    [void]$lines.Add('=== AI / KB (Cursor aided) ===')
    [void]$lines.Add([string]$adv.AiAidedSummary)
    if ($hint.WhatItIs) { [void]$lines.Add("WhatItIs: $($hint.WhatItIs)") }
    if ($hint.WhatItDoes) { [void]$lines.Add("WhatItDoes: $($hint.WhatItDoes)") }
    if ($hint.BusinessHint) { [void]$lines.Add("Hint: $($hint.BusinessHint)") }
    [void]$lines.Add('')
    [void]$lines.Add('=== WARNINGS ===')
    foreach ($w in @($adv.Warnings)) { [void]$lines.Add("• $w") }
    [void]$lines.Add('')
    [void]$lines.Add(">>> RECOMMENDED: $($adv.RecommendedActionId) (most efficient reversible path)")
    [void]$lines.Add('')
    [void]$lines.Add('=== OPTIONS (sorted by efficiency cost) ===')
    foreach ($o in @($adv.Options)) {
        [void]$lines.Add(("[{0}] {1} — {2} (cost={3} HITL={4})" -f $o.ActionId, $o.Label, $o.Rationale, $o.EfficiencyCost, $o.RequiresHitl))
    }
    $txt.Text = ($lines -join [Environment]::NewLine)

    $pnlBtns = New-Object System.Windows.Forms.Panel
    $pnlBtns.Dock = 'Bottom'
    $pnlBtns.Height = 52
    $pnlBtns.BackColor = $clrSurface

    $btnObserve = New-Btn $(if ($it) { 'Osserva' } else { 'Observe' }) $clrAccent 100 36
    $btnObserve.Location = New-Object System.Drawing.Point(12, 8)
    $btnThrottle = New-Btn $(if ($it) { 'Throttle' } else { 'Throttle' }) $clrGreen 100 36
    $btnThrottle.Location = New-Object System.Drawing.Point(118, 8)
    $btnKeep = New-Btn $(if ($it) { 'Necessario lavoro' } else { 'Work necessary' }) $clrCyan 130 36
    $btnKeep.Location = New-Object System.Drawing.Point(224, 8)
    $btnStop = New-Btn $(if ($it) { 'Stop…' } else { 'Stop…' }) $clrRed 90 36
    $btnStop.Location = New-Object System.Drawing.Point(360, 8)
    $btnCancel = New-Btn $(if ($it) { 'Annulla' } else { 'Cancel' }) $clrRaised 90 36
    $btnCancel.Location = New-Object System.Drawing.Point(456, 8)

    $pnlBtns.Controls.AddRange(@($btnObserve, $btnThrottle, $btnKeep, $btnStop, $btnCancel))

    $form.Controls.Add($txt)
    $form.Controls.Add($pnlBtns)

    function Invoke-ResolutionAction {
        param([string]$ActionName, [string]$Confirm = '')

        $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $resolveScript,
            '-Action', $ActionName, '-OutputJson', $outJson)
        if ($ProcessId -gt 0) { $a += @('-ProcessId', "$ProcessId") }
        else { $a += @('-ProcessName', $ProcessName) }
        if ($Confirm) { $a += @('-ConfirmPhrase', $Confirm) }

        $proc = Start-Process -FilePath $PsHost -ArgumentList $a -Wait -PassThru -WindowStyle Hidden
        if ($proc.ExitCode -ne 0) {
            [void][System.Windows.Forms.MessageBox]::Show('Action failed — see logs/process-resolution-latest.json', 'Resolve', 'OK', 'Error')
            return $false
        }
        if ($OnStatus) { & $OnStatus ("Process resolution: $ActionName") }
        return $true
    }

    $btnObserve.Add_Click({
        if (Invoke-ResolutionAction -ActionName 'Observe') { $form.DialogResult = 'OK'; $form.Close() }
    })
    $btnThrottle.Add_Click({
        $msg = if ($it) {
            "Impostare priorità BelowNormal su $($data.Process.ProcessName)? (reversibile)"
        } else {
            "Set BelowNormal priority on $($data.Process.ProcessName)? (reversible)"
        }
        $r = [System.Windows.Forms.MessageBox]::Show($msg, 'Throttle', 'YesNo', 'Question')
        if ($r -eq 'Yes' -and (Invoke-ResolutionAction -ActionName 'ThrottleBelowNormal')) {
            $form.DialogResult = 'OK'; $form.Close()
        }
    })
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
        [void]$d.ShowDialog()
        return $script:phraseResult
    }

    $btnKeep.Add_Click({
        $phrase = 'KEEP FOR WORK'
        $input = Show-PhrasePrompt -Prompt $(if ($it) { "Digita: $phrase" } else { "Type: $phrase" }) -Title 'Mark work necessary'
        if ($input -eq $phrase -and (Invoke-ResolutionAction -ActionName 'MarkWorkNecessary' -Confirm $phrase)) {
            $form.DialogResult = 'OK'; $form.Close()
        }
    })
    $btnStop.Add_Click({
        $w1 = [System.Windows.Forms.MessageBox]::Show(
            $(if ($it) { 'ATTENZIONE: chiudere il processo può causare perdita dati. Continuare?' } else { 'WARNING: stopping may cause data loss. Continue?' }),
            'Stop', 'YesNo', 'Warning')
        if ($w1 -ne 'Yes') { return }
        $phrase = 'STOP UNKNOWN'
        $input = Show-PhrasePrompt -Prompt $(if ($it) { "Digita esattamente: $phrase" } else { "Type exactly: $phrase" }) -Title 'Confirm terminate'
        if ($input -ne $phrase) { return }
        if (Invoke-ResolutionAction -ActionName 'Terminate' -Confirm $phrase) {
            $form.DialogResult = 'OK'; $form.Close()
        }
    })
    $btnCancel.Add_Click({ $form.DialogResult = 'Cancel'; $form.Close() })

    if ($Owner) { [void]$form.ShowDialog($Owner) } else { [void]$form.ShowDialog() }
    return @{ Ok = ($form.DialogResult -eq 'OK') }
}
