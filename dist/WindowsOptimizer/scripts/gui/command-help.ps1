# Command help panel + tooltips for GUI controls (dot-source after i18n.ps1).
Set-StrictMode -Version Latest

$script:CommandHelpMap = @{}
$script:GuiToolTip = $null
$script:TxtCommandHelp = $null

function Initialize-CommandHelp {
    param(
        [System.Windows.Forms.Form]$Form,
        [hashtable]$ControlToCommandId
    )

    $script:CommandHelpMap = @{}
    foreach ($key in $ControlToCommandId.Keys) {
        $script:CommandHelpMap[$key] = $ControlToCommandId[$key]
    }

    if (-not $script:GuiToolTip) {
        $script:GuiToolTip = New-Object System.Windows.Forms.ToolTip
        $script:GuiToolTip.AutoPopDelay = 12000
        $script:GuiToolTip.InitialDelay = 400
        $script:GuiToolTip.ReshowDelay = 200
        $script:GuiToolTip.ShowAlways = $true
    }

    foreach ($ctrl in $ControlToCommandId.Keys) {
        $cmdId = $ControlToCommandId[$ctrl]
        $tip = Get-CommandTooltip -CommandId $cmdId
        if ($tip) {
            [void]$script:GuiToolTip.SetToolTip($ctrl, $tip)
        }
        $handler = {
            param($sender, $e)
            Show-CommandHelpForControl -Control $sender
        }
        $ctrl.Add_MouseEnter($handler)
        # WinForms Button has no Add_Focus; use Click for buttons and GotFocus elsewhere.
        if ($ctrl -is [System.Windows.Forms.Button]) {
            $ctrl.Add_Click($handler)
        } else {
            $ctrl.Add_GotFocus($handler)
        }
    }
}

function Register-CommandHelpTextBox {
    param([System.Windows.Forms.TextBox]$TextBox)
    $script:TxtCommandHelp = $TextBox
}

function Show-CommandHelpForControl {
    param([System.Windows.Forms.Control]$Control)

    if (-not $script:TxtCommandHelp) { return }
    if (-not $Control) { return }

    $cmdId = $null
    if ($script:CommandHelpMap.ContainsKey($Control)) {
        $cmdId = $script:CommandHelpMap[$Control]
    }
    if (-not $cmdId) {
        $script:TxtCommandHelp.Text = ''
        return
    }

    $script:TxtCommandHelp.Text = Format-CommandHelpText -CommandId $cmdId
}

function Update-GuiLanguage {
    param(
        [string]$HubRoot,
        [string]$Language
    )

    Initialize-I18n -HubRoot $HubRoot -Language $Language

    # Caller updates control texts via Get-I18n keys after this returns.
}
