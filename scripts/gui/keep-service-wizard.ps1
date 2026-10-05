# Multi-step HITL wizard for extreme apply on catalog-allowlisted KEEP services (Defender first).
# Dot-sourced from system-optimizer-gui.ps1 after theme.ps1.

function Get-KeepApplyOperatorMessage {
    param(
        [string]$Outcome,
        [string]$Tier,
        [bool]$DryRun,
        [bool]$Italian,
        [int]$ExitCode,
        [bool]$HasResult
    )

    if ($DryRun -and $ExitCode -eq 0) {
        if ($Italian) { return @{ Text = 'Dry-run completato. Nessuna modifica al sistema.'; Icon = 'Information'; Success = $true; Reason = 'DryRun' } }
        return @{ Text = 'Dry-run completed. No system changes.'; Icon = 'Information'; Success = $true; Reason = 'DryRun' }
    }

    $known = @('Applied', 'StateUnverified', 'StateMismatch', 'Failed', 'DryRunApplied', 'InterceptedNoOsMutation', 'PreStateUnavailable')
    if (-not $HasResult -or [string]::IsNullOrWhiteSpace($Outcome) -or ($known -notcontains $Outcome -and $ExitCode -ne 0)) {
        if ($Italian) { return @{ Text = "Apply fallito (exit $ExitCode). Vedi log."; Icon = 'Error'; Success = $false; Reason = 'Failed' } }
        return @{ Text = "Apply failed (exit $ExitCode). See logs."; Icon = 'Error'; Success = $false; Reason = 'Failed' }
    }

    switch ($Outcome) {
        'Applied' {
            if ($Tier -eq 'TuneExclusions') {
                if ($Italian) { return @{ Text = "L'esclusione è attiva."; Icon = 'Information'; Success = $true; Reason = 'Applied' } }
                return @{ Text = 'The exclusion is active.'; Icon = 'Information'; Success = $true; Reason = 'Applied' }
            }
            if ($Italian) { return @{ Text = 'Apply completato. Verifica Windows Security e conserva il rollback JSON.'; Icon = 'Information'; Success = $true; Reason = 'Applied' } }
            return @{ Text = 'Apply completed. Verify Windows Security and keep the rollback JSON.'; Icon = 'Information'; Success = $true; Reason = 'Applied' }
        }
        'PreStateUnavailable' {
            if ($Italian) { return @{ Text = "Non posso modificare Defender in sicurezza perché non riesco a determinare lo stato attuale. Nessuna esclusione è stata cambiata. Riprova quando Windows può mostrare le esclusioni."; Icon = 'Warning'; Success = $false; Reason = 'PreStateUnavailable' } }
            return @{ Text = 'The current Defender exclusion state could not be read, so no exclusion was changed. Retry when Windows can report Defender exclusions.'; Icon = 'Warning'; Success = $false; Reason = 'PreStateUnavailable' }
        }
        'StateUnverified' {
            if ($Tier -eq 'TuneExclusions') {
                if ($Italian) { return @{ Text = "Il comando di esclusione è terminato, ma Windows non ha fornito uno stato sufficiente per confermarlo."; Icon = 'Warning'; Success = $false; Reason = 'StateUnverified' } }
                return @{ Text = 'The exclusion command completed, but Windows did not provide enough state to confirm it.'; Icon = 'Warning'; Success = $false; Reason = 'StateUnverified' }
            }
            if ($Italian) { return @{ Text = "La modifica è terminata, ma Windows non ha fornito uno stato sufficiente per confermarla."; Icon = 'Warning'; Success = $false; Reason = 'StateUnverified' } }
            return @{ Text = 'The change completed, but Windows did not provide enough state to confirm it.'; Icon = 'Warning'; Success = $false; Reason = 'StateUnverified' }
        }
        default {
            if ($Tier -eq 'TuneExclusions') {
                if ($Italian) { return @{ Text = "L'esclusione non può essere applicata."; Icon = 'Error'; Success = $false; Reason = 'Failed' } }
                return @{ Text = 'The exclusion could not be applied.'; Icon = 'Error'; Success = $false; Reason = 'Failed' }
            }
            if ($Italian) { return @{ Text = "La modifica non può essere applicata."; Icon = 'Error'; Success = $false; Reason = 'Failed' } }
            return @{ Text = 'The change could not be applied.'; Icon = 'Error'; Success = $false; Reason = 'Failed' }
        }
    }
}

function Write-KeepWizardStatus {
    param(
        [scriptblock]$OnStatus,
        [string]$Message
    )
    if ($OnStatus) {
        & $OnStatus $Message
    }
}

function Get-KeepExtremeAllowlistEntry {
    param(
        [string]$ProcessName,
        [string]$CatalogPath
    )

    if (-not (Test-Path -LiteralPath $CatalogPath)) { return $null }
    $catalog = Get-Content -LiteralPath $CatalogPath -Raw | ConvertFrom-Json
    if (-not $catalog.keepExtremeDisableAllowlist) { return $null }

    $lower = $ProcessName.ToLowerInvariant()
    foreach ($prop in $catalog.keepExtremeDisableAllowlist.PSObject.Properties) {
        if ($lower -eq $prop.Name.ToLowerInvariant()) {
            return [pscustomobject]@{
                ProcessName = $prop.Name
                Config = $prop.Value
            }
        }
    }
    return $null
}

function Invoke-KeepExtremeApplyElevated {
    param(
        [string]$PsHost,
        [string]$ApplyScript,
        [hashtable]$ApplyParams,
        [string]$BootstrapLog
    )

    $argParts = New-Object System.Collections.Generic.List[string]
    foreach ($key in $ApplyParams.Keys) {
        $val = $ApplyParams[$key]
        if ($val -is [switch]) {
            if ($val.IsPresent) { [void]$argParts.Add("-$key") }
        } elseif ($val -is [array]) {
            foreach ($item in @($val)) {
                [void]$argParts.Add("-$key")
                [void]$argParts.Add([string]$item)
            }
        } else {
            [void]$argParts.Add("-$key")
            [void]$argParts.Add([string]$val)
        }
    }

    $escapedApply = $ApplyScript.Replace("'", "''")
    $argLine = ($argParts | ForEach-Object { if ($_ -match '\s') { "'$_'" } else { $_ } }) -join ' '
    $bootstrap = @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'
& '$escapedApply' $argLine *>&1 | Tee-Object -FilePath '$BootstrapLog'
exit `$LASTEXITCODE
"@

    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("hub-keep-apply-{0}.ps1" -f ([guid]::NewGuid().ToString('N')))
    Set-Content -LiteralPath $tmp -Value $bootstrap -Encoding UTF8

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $PsHost
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$tmp`""
    $psi.Verb = 'runas'
    $psi.UseShellExecute = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    if ($null -eq $proc) {
        return @{ ExitCode = -1; Log = 'Elevation cancelled by user.' }
    }
    $proc.WaitForExit()
    $logText = ''
    if (Test-Path -LiteralPath $BootstrapLog) {
        $logText = Get-Content -LiteralPath $BootstrapLog -Raw -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    return @{ ExitCode = $proc.ExitCode; Log = $logText }
}

function Show-KeepServiceExtremeWizard {
    param(
        [System.Windows.Forms.Form]$Owner,
        [string]$HubRoot,
        [string]$ScriptRoot,
        [string]$PsHost,
        [string]$Language = 'en',
        [scriptblock]$OnStatus,
        [pscustomobject]$Evaluation,
        [string]$EvaluationJsonPath,
        [string]$ProcessName = 'MsMpEng'
    )

    $it = ($Language -eq 'it')
    $allow = Get-KeepExtremeAllowlistEntry -ProcessName $ProcessName -CatalogPath (Join-Path $HubRoot 'config\process-intelligence.json')
    if (-not $allow) {
        [void][System.Windows.Forms.MessageBox]::Show(
            $(if ($it) { "Processo $ProcessName non in allowlist KEEP extreme." } else { "Process $ProcessName is not in KEEP extreme allowlist." }),
            'KEEP Apply', 'OK', 'Error')
        return @{ Ok = $false; Reason = 'NotAllowlisted' }
    }

    $cfg = $allow.Config
    $confirmPhrase = [string]$cfg.confirmPhrase
    if (-not $confirmPhrase) { $confirmPhrase = 'DISABLE KEEP' }

    $tier = [string]$Evaluation.RecommendedTier
    if ($tier -eq 'Observe') {
        [void][System.Windows.Forms.MessageBox]::Show(
            $(if ($it) { 'Tier Observe - nessuna disabilitazione consigliata. Esegui prima Compute con MsMpEng sotto pressione.' } else { 'Observe tier - disable not recommended. Run Compute while MsMpEng is under pressure first.' }),
            'KEEP Apply', 'OK', 'Information')
        return @{ Ok = $false; Reason = 'ObserveTier' }
    }

    if (-not [bool]$Evaluation.AllowedToProceed) {
        $blk = (@($Evaluation.Blockers) -join "`n- ")
        [void][System.Windows.Forms.MessageBox]::Show(
            $(if ($it) { "Apply bloccato:`n- $blk" } else { "Apply blocked:`n- $blk" }),
            'KEEP Apply', 'OK', 'Warning')
        return @{ Ok = $false; Reason = 'Blocked' }
    }

    $applyScript = Join-Path $ScriptRoot ([string]$cfg.applyScript)
    if (-not (Test-Path -LiteralPath $applyScript)) {
        [void][System.Windows.Forms.MessageBox]::Show("Missing apply script: $applyScript", 'KEEP Apply', 'OK', 'Error')
        return @{ Ok = $false; Reason = 'MissingScript' }
    }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = if ($it) { 'KEEP - Apply estremo (HITL)' } else { 'KEEP - Extreme apply (HITL)' }
    $dlg.Size = New-Object System.Drawing.Size(520, 580)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.BackColor = $clrSurface
    $dlg.ForeColor = $clrText
    $dlg.Font = $fntUI

    $y = 12
    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = [string]$cfg.displayName
    $lblTitle.Font = $fntH2
    $lblTitle.ForeColor = $clrAmber
    $lblTitle.AutoSize = $true
    $lblTitle.Location = New-Object System.Drawing.Point(16, $y)
    $dlg.Controls.Add($lblTitle)
    $y += 28

    $lblTier = New-Object System.Windows.Forms.Label
    $lblTier.Text = ("Tier: {0}  |  Composite: {1}" -f $tier, $Evaluation.CompositeScore)
    $lblTier.AutoSize = $true
    $lblTier.ForeColor = $clrMuted
    $lblTier.Location = New-Object System.Drawing.Point(16, $y)
    $dlg.Controls.Add($lblTier)
    $y += 24

    $txtSummary = New-Object System.Windows.Forms.TextBox
    $txtSummary.Multiline = $true
    $txtSummary.ReadOnly = $true
    $txtSummary.ScrollBars = 'Vertical'
    $txtSummary.BorderStyle = 'None'
    $txtSummary.BackColor = $clrRaised
    $txtSummary.ForeColor = $clrText
    $txtSummary.Font = $fntMono
    $txtSummary.Location = New-Object System.Drawing.Point(16, $y)
    $txtSummary.Size = New-Object System.Drawing.Size(472, 88)
    $pre = @($Evaluation.Rationale) + @($Evaluation.Prerequisites) | ForEach-Object { [string]$_ }
    $txtSummary.Text = ($pre -join [Environment]::NewLine)
    $dlg.Controls.Add($txtSummary)
    $y += 96

    $lblReason = New-Object System.Windows.Forms.Label
    $lblReason.Text = if ($it) { 'Motivo (obbligatorio):' } else { 'Reason (required):' }
    $lblReason.AutoSize = $true
    $lblReason.Location = New-Object System.Drawing.Point(16, $y)
    $dlg.Controls.Add($lblReason)
    $y += 22

    $cmbReason = New-Object System.Windows.Forms.ComboBox
    $cmbReason.DropDownStyle = 'DropDownList'
    $cmbReason.Location = New-Object System.Drawing.Point(16, $y)
    $cmbReason.Size = New-Object System.Drawing.Size(472, 28)
    if ($Evaluation.ReasonCodes) {
        foreach ($prop in $Evaluation.ReasonCodes.PSObject.Properties) {
            [void]$cmbReason.Items.Add($prop.Name)
        }
    } else {
        @('DevBuild', 'EmergencyPerf', 'ForensicCapture', 'VendorSupport') | ForEach-Object { [void]$cmbReason.Items.Add($_) }
    }
    if ($cmbReason.Items.Count -gt 0) { $cmbReason.SelectedIndex = 0 }
    $dlg.Controls.Add($cmbReason)
    $y += 34

    $lblMin = New-Object System.Windows.Forms.Label
    $lblMin.Text = if ($it) { 'Riattiva automaticamente (minuti):' } else { 'Auto re-enable (minutes):' }
    $lblMin.AutoSize = $true
    $lblMin.Location = New-Object System.Drawing.Point(16, $y)
    $dlg.Controls.Add($lblMin)
    $y += 22

    $numMin = New-Object System.Windows.Forms.NumericUpDown
    $numMin.Location = New-Object System.Drawing.Point(16, $y)
    $numMin.Width = 80
    $numMin.Minimum = 5
    $maxMin = if ($tier -eq 'ExtremeServiceDisable') { 120 } elseif ($tier -eq 'TemporaryRealtimeOff') { 60 } else { 0 }
    if ($maxMin -gt 0) {
        $numMin.Maximum = $maxMin
        $numMin.Value = [Math]::Min(30, $maxMin)
    } else {
        $numMin.Maximum = 1
        $numMin.Value = 1
        $numMin.Enabled = $false
        $lblMin.Enabled = $false
    }
    $dlg.Controls.Add($numMin)
    $y += 36

    $lblPaths = New-Object System.Windows.Forms.Label
    $lblPaths.Text = if ($it) { 'Path esclusione (solo TuneExclusions, separati da ;):' } else { 'Exclusion paths (TuneExclusions only, ; separated):' }
    $lblPaths.AutoSize = $true
    $lblPaths.Location = New-Object System.Drawing.Point(16, $y)
    $lblPaths.Visible = ($tier -eq 'TuneExclusions')
    $dlg.Controls.Add($lblPaths)
    $y += 22

    $txtPaths = New-Object System.Windows.Forms.TextBox
    $txtPaths.Location = New-Object System.Drawing.Point(16, $y)
    $txtPaths.Width = 472
    $txtPaths.Text = $HubRoot
    $txtPaths.Visible = ($tier -eq 'TuneExclusions')
    $dlg.Controls.Add($txtPaths)
    if ($tier -eq 'TuneExclusions') { $y += 30 }

    $chk1 = New-Object System.Windows.Forms.CheckBox
    $chk1.Text = if ($it) { 'Comprendo che la protezione AV/sicurezza sarà ridotta' } else { 'I understand AV/security protection will be reduced' }
    $chk1.AutoSize = $true
    $chk1.ForeColor = $clrText
    $chk1.Location = New-Object System.Drawing.Point(16, $y)
    $dlg.Controls.Add($chk1)
    $y += 26

    $chk2 = New-Object System.Windows.Forms.CheckBox
    $chk2.Text = if ($it) { 'Ho letto prerequisiti e blocchi nella valutazione' } else { 'I have read prerequisites and blockers in the evaluation' }
    $chk2.AutoSize = $true
    $chk2.ForeColor = $clrText
    $chk2.Location = New-Object System.Drawing.Point(16, $y)
    $dlg.Controls.Add($chk2)
    $y += 26

    $chk3 = New-Object System.Windows.Forms.CheckBox
    $chk3.Text = if ($it) { 'Accetto la responsabilità per il periodo di finestra ridotta' } else { 'I accept responsibility for the reduced-protection window' }
    $chk3.AutoSize = $true
    $chk3.ForeColor = $clrText
    $chk3.Location = New-Object System.Drawing.Point(16, $y)
    $dlg.Controls.Add($chk3)
    $y += 26

    $lblPhrase = New-Object System.Windows.Forms.Label
    $lblPhrase.Text = ("$(if ($it) { 'Digita' } else { 'Type' }) '$confirmPhrase':")
    $lblPhrase.AutoSize = $true
    $lblPhrase.Location = New-Object System.Drawing.Point(16, $y)
    $dlg.Controls.Add($lblPhrase)
    $y += 22

    $txtPhrase = New-Object System.Windows.Forms.TextBox
    $txtPhrase.Location = New-Object System.Drawing.Point(16, $y)
    $txtPhrase.Width = 472
    $dlg.Controls.Add($txtPhrase)
    $y += 36

    $btnCancel = New-Btn $(if ($it) { 'Annulla' } else { 'Cancel' }) $clrRaised 100 36
    $btnCancel.Location = New-Object System.Drawing.Point(16, $y)
    $dlg.Controls.Add($btnCancel)

    $btnDry = New-Btn 'Dry Run' $clrCyan 100 36
    $btnDry.Location = New-Object System.Drawing.Point(124, $y)
    $dlg.Controls.Add($btnDry)

    $btnApply = New-Btn $(if ($it) { 'Applica (Admin)' } else { 'Apply (Admin)' }) $clrRed 140 36
    $btnApply.Location = New-Object System.Drawing.Point(232, $y)
    $dlg.Controls.Add($btnApply)

    $script:keepWizardResult = @{ Ok = $false; Reason = 'Cancelled' }

    function Test-WizardInputs {
        if (-not $chk1.Checked -or -not $chk2.Checked -or -not $chk3.Checked) {
            return $(if ($it) { 'Seleziona tutte le caselle di conferma.' } else { 'Check all confirmation boxes.' })
        }
        if ($txtPhrase.Text.Trim() -cne $confirmPhrase) {
            return $(if ($it) { "Frase di conferma errata. Digita esattamente: $confirmPhrase" } else { "Wrong confirmation phrase. Type exactly: $confirmPhrase" })
        }
        if ($tier -eq 'TuneExclusions') {
            $paths = @($txtPaths.Text -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            if ($paths.Count -lt 1) {
                return $(if ($it) { 'Inserisci almeno un path per TuneExclusions.' } else { 'Enter at least one path for TuneExclusions.' })
            }
        }
        return $null
    }

    function Invoke-WizardApply {
        param([bool]$DryRun)

        $err = Test-WizardInputs
        if ($err) {
            [void][System.Windows.Forms.MessageBox]::Show($err, 'KEEP Apply', 'OK', 'Warning')
            return
        }

        $msg1 = if ($it) {
            "Stai per modificare un servizio KEEP ($($cfg.displayName)).`nTier: $tier`n`nContinuare?"
        } else {
            "You are about to modify a KEEP service ($($cfg.displayName)).`nTier: $tier`n`nContinue?"
        }
        if ([System.Windows.Forms.MessageBox]::Show($msg1, 'KEEP Apply - Confirm 1/3', 'YesNo', 'Warning') -ne 'Yes') { return }

        $msg2 = if ($it) {
            'Seconda conferma: il sistema sarà meno protetto durante la finestra configurata. Procedere?'
        } else {
            'Second confirmation: the system will be less protected during the configured window. Proceed?'
        }
        if ([System.Windows.Forms.MessageBox]::Show($msg2, 'KEEP Apply - Confirm 2/3', 'YesNo', 'Warning') -ne 'Yes') { return }

        if ($tier -eq 'ExtremeServiceDisable') {
            $msg3 = if ($it) {
                'ULTIMA RISORSA: arresto servizio WinDefend. Confermi consapevolmente?'
            } else {
                'LAST RESORT: WinDefend service will be stopped. Confirm knowingly?'
            }
            if ([System.Windows.Forms.MessageBox]::Show($msg3, 'KEEP Apply - Confirm 3/3', 'YesNo', 'Stop') -ne 'Yes') { return }
        } else {
            if ([System.Windows.Forms.MessageBox]::Show(
                $(if ($it) { 'Conferma finale: eseguire ora?' } else { 'Final confirmation: execute now?' }),
                'KEEP Apply - Confirm 3/3', 'YesNo', 'Warning') -ne 'Yes') { return }
        }

        $reason = [string]$cmbReason.SelectedItem
        $applyOut = Join-Path $HubRoot 'logs\keep-extreme-apply-live.json'
        $bootstrapLog = Join-Path $HubRoot 'logs\keep-extreme-apply-elevated.log'

        $params = @{
            EvaluationJson = $EvaluationJsonPath
            OutputJson = $applyOut
            Tier = $tier
            ReasonCode = $reason
            IUnderstandRisk = [switch]::Present
        }
        if ($DryRun) { $params['DryRun'] = [switch]::Present }
        if ($tier -eq 'ExtremeServiceDisable') { $params['ConfirmExtremeDisable'] = [switch]::Present }
        if ($maxMin -gt 0) { $params['AutoReenableMinutes'] = [int]$numMin.Value }
        if ($tier -eq 'TuneExclusions') {
            $params['ExclusionPaths'] = @($txtPaths.Text -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }

        Write-KeepWizardStatus -OnStatus $OnStatus -Message ("KEEP extreme apply starting tier=$tier dryRun=$DryRun")

        $isAdmin = $false
        if (Get-Command Test-HubAdmin -ErrorAction SilentlyContinue) {
            $isAdmin = Test-HubAdmin
        }

        $exitCode = 0
        if ($isAdmin) {
            $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $applyScript)
            foreach ($key in $params.Keys) {
                $val = $params[$key]
                if ($val -is [switch]) {
                    if ($val.IsPresent) { $argList += "-$key" }
                } elseif ($val -is [array]) {
                    foreach ($item in @($val)) { $argList += @("-$key", [string]$item) }
                } else {
                    $argList += @("-$key", [string]$val)
                }
            }
            $p = Start-HubPowerShellProcess -FilePath $PsHost -ArgumentList $argList -Wait -PassThru
            $exitCode = $p.ExitCode
        } else {
            $elev = Invoke-KeepExtremeApplyElevated -PsHost $PsHost -ApplyScript $applyScript -ApplyParams $params -BootstrapLog $bootstrapLog
            $exitCode = [int]$elev.ExitCode
        }

        $res = $null
        if (Test-Path -LiteralPath $applyOut) {
            $res = Get-Content -LiteralPath $applyOut -Raw | ConvertFrom-Json
        }
        $outcome = ''
        if ($res -and $res.PSObject.Properties['Outcome']) { $outcome = [string]$res.Outcome }
        $view = Get-KeepApplyOperatorMessage -Outcome $outcome -Tier $tier -DryRun $DryRun -Italian $it -ExitCode $exitCode -HasResult ($null -ne $res)
        $icon = [System.Windows.Forms.MessageBoxIcon]([string]$view.Icon)
        [void][System.Windows.Forms.MessageBox]::Show([string]$view.Text, 'KEEP Apply', 'OK', $icon)
        Write-KeepWizardStatus -OnStatus $OnStatus -Message ("KEEP extreme apply outcome=$outcome exit=$exitCode")
        if (-not $view.Success) { return }

        $script:keepWizardResult = @{ Ok = $true; Reason = [string]$view.Reason; Tier = $tier }
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dlg.Close()
    }

    $btnCancel.Add_Click({ $dlg.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $dlg.Close() })
    $btnDry.Add_Click({ Invoke-WizardApply -DryRun $true })
    $btnApply.Add_Click({ Invoke-WizardApply -DryRun $false })

    if ($Owner) {
        [void]$dlg.ShowDialog($Owner)
    } else {
        [void]$dlg.ShowDialog()
    }

    return $script:keepWizardResult
}

function Start-KeepExtremeWizardFlow {
    param(
        [System.Windows.Forms.Form]$Owner,
        [string]$HubRoot,
        [string]$ScriptRoot,
        [string]$PsHost,
        [string]$Language,
        [scriptblock]$OnStatus,
        [string]$ComputeJsonPath,
        [string]$EvaluateScript,
        [string]$ProcessName = 'MsMpEng'
    )

    $evalOut = Join-Path $HubRoot 'logs\defender-extreme-necessity-eval.json'
    $inputArg = if ($ComputeJsonPath -and (Test-Path -LiteralPath $ComputeJsonPath)) { $ComputeJsonPath } else { '' }
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $EvaluateScript, '-OutputJson', $evalOut)
    if ($inputArg) { $args += @('-InputJson', $inputArg) }

    $p = Start-HubPowerShellProcess -FilePath $PsHost -ArgumentList $args -Wait -PassThru
    if ($p.ExitCode -ne 0) {
        Write-KeepWizardStatus -OnStatus $OnStatus -Message ("KEEP evaluation failed exit=$($p.ExitCode)")
        return @{ Ok = $false; Reason = 'EvalFailed' }
    }
    if (-not (Test-Path -LiteralPath $evalOut)) {
        Write-KeepWizardStatus -OnStatus $OnStatus -Message 'KEEP evaluation produced no output.'
        return @{ Ok = $false; Reason = 'NoEvalOutput' }
    }

    $ev = Get-Content -LiteralPath $evalOut -Raw | ConvertFrom-Json
    Write-KeepWizardStatus -OnStatus $OnStatus -Message ("KEEP eval tier=$($ev.RecommendedTier) composite=$($ev.CompositeScore) allowed=$($ev.AllowedToProceed)")

    return Show-KeepServiceExtremeWizard -Owner $Owner -HubRoot $HubRoot -ScriptRoot $ScriptRoot -PsHost $PsHost `
        -Language $Language -OnStatus $OnStatus -Evaluation $ev -EvaluationJsonPath $evalOut -ProcessName $ProcessName
}
