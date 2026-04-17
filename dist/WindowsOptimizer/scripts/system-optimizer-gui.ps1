Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Resolve-BaseDirectory {
    if ($PSScriptRoot) {
        return $PSScriptRoot
    }

    if ($MyInvocation.MyCommand.Path) {
        return (Split-Path -Parent $MyInvocation.MyCommand.Path)
    }

    $exeBase = [System.AppDomain]::CurrentDomain.BaseDirectory
    if ($exeBase) {
        return $exeBase.TrimEnd("\\")
    }

    return (Get-Location).Path
}

$baseDir = Resolve-BaseDirectory
$scriptsUnderBase = Join-Path $baseDir "scripts"

if (Test-Path -LiteralPath $scriptsUnderBase) {
    $script:hubRoot = $baseDir
    $script:scriptRoot = $scriptsUnderBase
} elseif ((Split-Path -Leaf $baseDir).ToLowerInvariant() -eq "scripts") {
    $script:scriptRoot = $baseDir
    $script:hubRoot = Split-Path -Parent $baseDir
} else {
    $script:scriptRoot = $baseDir
    $script:hubRoot = Split-Path -Parent $baseDir
}

function Resolve-PowerShellHost {
    $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($cmd) {
        $candidate = $cmd.Path
        $fi = Get-Item -LiteralPath $candidate -ErrorAction SilentlyContinue
        if ($fi -and $fi.Length -gt 0) {
            return $candidate
        }
        # 0-byte AppExecution alias detected — find real pwsh.exe
        $searchPaths = @(
            "$env:ProgramFiles\PowerShell\*\pwsh.exe",
            "$env:ProgramFiles\WindowsApps\Microsoft.PowerShell_*\pwsh.exe"
        )
        foreach ($pattern in $searchPaths) {
            $real = Get-Item -Path $pattern -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($real) { return $real.FullName }
        }
        return $candidate
    }
    $cmd2 = Get-Command powershell -ErrorAction SilentlyContinue
    if ($cmd2) { return $cmd2.Path }
    return $null
}
$script:psHost = Resolve-PowerShellHost

function Invoke-ChildPowerShell {
    param([string[]]$Args)

    if (-not $script:psHost) {
        throw "No PowerShell runtime available in PATH."
    }

    & $script:psHost @Args
}

$script:cleanupScript = Join-Path $script:scriptRoot "cleanup-storage-safe.ps1"
$script:quickCleanupScript = Join-Path $script:scriptRoot "quick-cleanup-safe.ps1"
$script:analyzerScript = Join-Path $script:scriptRoot "analyze-garbage-hotspots.ps1"
$script:computeAnalyzerScript = Join-Path $script:scriptRoot "analyze-compute-resources.ps1"
$script:coreScript = Join-Path $script:scriptRoot "ensure-powershell-core.ps1"
$script:monitorInstaller = Join-Path $script:scriptRoot "install-monitor-task.ps1"
$script:cleanupInstaller = Join-Path $script:scriptRoot "install-cleanup-task.ps1"
$script:configPath = Join-Path $script:hubRoot "config\\sys-maintenance.json"
$script:defaultLog = Join-Path $script:hubRoot "logs\\storage-cleanup.log"
$script:analysisProcess = $null
$script:analysisCsv = Join-Path $script:hubRoot "logs\\garbage-hotspots-live.csv"
$script:analysisStdOut = Join-Path $script:hubRoot "logs\garbage-hotspots-live.out.log"
$script:analysisStdErr = Join-Path $script:hubRoot "logs\garbage-hotspots-live.err.log"
$script:analysisStartedAt = $null
$script:analysisTimeoutSec = 0
$script:analysisSoftTimeoutWarned = $false
$script:cleanupProcess = $null
$script:cleanupJson = Join-Path $script:hubRoot "logs\\cleanup-live.json"
$script:cleanupStdOut = Join-Path $script:hubRoot "logs\cleanup-live.out.log"
$script:cleanupStdErr = Join-Path $script:hubRoot "logs\cleanup-live.err.log"
$script:cleanupStartedAt = $null
$script:cleanupTimeoutSec = 0
$script:cleanupSoftTimeoutWarned = $false
$script:cleanupRunAnalyzeAfter = $false
$script:computeProcess = $null
$script:computeJson = Join-Path $script:hubRoot "logs\compute-analysis-live.json"
$script:computeStdOut = Join-Path $script:hubRoot "logs\compute-analysis-live.out.log"
$script:computeStdErr = Join-Path $script:hubRoot "logs\compute-analysis-live.err.log"
$script:computeStartedAt = $null
$script:computeTimeoutSec = 45
$script:computeSoftTimeoutWarned = $false
$script:quickCleanupProcess = $null
$script:quickCleanupJson = Join-Path $script:hubRoot "logs\quick-cleanup-live.json"
$script:quickCleanupStdOut = Join-Path $script:hubRoot "logs\quick-cleanup-live.out.log"
$script:quickCleanupStdErr = Join-Path $script:hubRoot "logs\quick-cleanup-live.err.log"
$script:quickCleanupStartedAt = $null
$script:quickCleanupTimeoutSec = 120
$script:quickCleanupSoftTimeoutWarned = $false
$script:autoAnalyzeOnStartup = $true
$script:startupAnalyzeDepth = "Quick"
$script:startupAnalyzeTop = 15
$script:computeAnalyzeDurationSec = 8
$script:computeAnalyzeTop = 8
$script:quickCleanupRetentionDays = 2
$script:quickCleanupMaxFilesPerTarget = 2000
$script:diagnosticRetentionDays = 7
$script:diagnosticsDir = Join-Path $script:hubRoot "logs\diagnostics"
$script:healthAuditScript  = Join-Path $script:scriptRoot "system-health-audit.ps1"
$script:applyFixesScript   = Join-Path $script:scriptRoot "apply-safe-fixes.ps1"
$script:healthAuditProcess = $null
$script:healthAuditJson    = Join-Path $script:hubRoot "logs\health-audit-live.json"
$script:healthApplyJson    = Join-Path $script:hubRoot "logs\health-apply-live.json"
$script:healthAuditStdOut  = Join-Path $script:hubRoot "logs\health-audit-live.out.log"
$script:healthAuditStdErr  = Join-Path $script:hubRoot "logs\health-audit-live.err.log"
$script:healthAuditStartedAt = $null
$script:healthAuditTimeoutSec = 90
$script:healthAuditSoftTimeoutWarned = $false
$script:healthAuditApplyAfter = $false
$script:healthAuditMaxLevel   = 'Safe'

# ─── Deep Scan state ──────────────────────────────────────────────────────────
$script:deepScanProcess          = $null
$script:deepScanJson             = Join-Path $script:hubRoot "logs\deepscan-live.json"
$script:deepScanApplyJson        = Join-Path $script:hubRoot "logs\deepscan-apply-live.json"
$script:deepScanStdOut           = Join-Path $script:hubRoot "logs\deepscan-live.out.log"
$script:deepScanStdErr           = Join-Path $script:hubRoot "logs\deepscan-live.err.log"
$script:deepScanStartedAt        = $null
$script:deepScanTimeoutSec       = 90
$script:deepScanSoftTimeoutWarned = $false
$script:deepScanFindings         = @()
$script:deepScanApplyProcess     = $null
$script:deepScanApplyStartedAt   = $null
$script:deepScanApplyFindingId   = ""
$script:deepScanApplyLevel       = "Safe"
$script:deepScanFilter           = "All"
$script:deepScanLastSummary      = $null

# ═══════════════════════════════════════════════════════════════════════════════
#  Theme palette
# ═══════════════════════════════════════════════════════════════════════════════
$clrBg       = [System.Drawing.Color]::FromArgb(12, 16, 26)
$clrSurface  = [System.Drawing.Color]::FromArgb(19, 27, 44)
$clrRaised   = [System.Drawing.Color]::FromArgb(26, 37, 58)
$clrBorderC  = [System.Drawing.Color]::FromArgb(40, 57, 86)
$clrAccent   = [System.Drawing.Color]::FromArgb(59, 130, 246)
$clrGreen    = [System.Drawing.Color]::FromArgb(16, 185, 129)
$clrRed      = [System.Drawing.Color]::FromArgb(220, 60, 60)
$clrAmber    = [System.Drawing.Color]::FromArgb(217, 140, 10)
$clrPurple   = [System.Drawing.Color]::FromArgb(124, 80, 230)
$clrCyan     = [System.Drawing.Color]::FromArgb(8, 148, 180)
$clrText     = [System.Drawing.Color]::FromArgb(220, 228, 242)
$clrMuted    = [System.Drawing.Color]::FromArgb(95, 112, 140)
$clrRowHigh  = [System.Drawing.Color]::FromArgb(72, 28, 28)
$clrRowAmber = [System.Drawing.Color]::FromArgb(72, 54, 14)
$clrTxtHigh  = [System.Drawing.Color]::FromArgb(252, 160, 160)
$clrTxtAmber = [System.Drawing.Color]::FromArgb(253, 220, 120)

$fntUI    = New-Object System.Drawing.Font("Segoe UI", 9.5)
$fntHead  = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
$fntH2    = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$fntMono  = New-Object System.Drawing.Font("Consolas", 9)
$fntSmall = New-Object System.Drawing.Font("Segoe UI", 8)

$script:spinFrames = @("", ".", "..", "...", "....", ".....", "....", "...", "..", ".")
$script:spinIdx    = 0

# UxTheme for stripping visual styles from old-style controls
try {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class WO_Ux {
    [DllImport("uxtheme.dll")]
    public static extern int SetWindowTheme(IntPtr hwnd, string sub, string idl);
}
"@ -ErrorAction Stop
} catch {}

function Set-NoTheme {
    param([System.Windows.Forms.Control]$Ctrl)
    try { [WO_Ux]::SetWindowTheme($Ctrl.Handle, "", "") | Out-Null } catch {}
}

# Flat button factory
function New-Btn {
    param([string]$Text, [System.Drawing.Color]$Bg, [int]$W = 140, [int]$H = 34)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text; $b.Width = $W; $b.Height = $H
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $b.FlatAppearance.BorderSize = 0
    $b.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(
        [Math]::Min(255, $Bg.R + 38), [Math]::Min(255, $Bg.G + 38), [Math]::Min(255, $Bg.B + 38))
    $b.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(
        [Math]::Max(0, $Bg.R - 22), [Math]::Max(0, $Bg.G - 22), [Math]::Max(0, $Bg.B - 22))
    $b.BackColor = $Bg
    $b.ForeColor = $clrText
    $b.Font = $fntH2
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    return $b
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Main Form
# ═══════════════════════════════════════════════════════════════════════════════
$form = New-Object System.Windows.Forms.Form
$form.Text          = "Windows Optimizer Console"
$form.Size          = New-Object System.Drawing.Size(1400, 880)
$form.MinimumSize   = New-Object System.Drawing.Size(1100, 700)
$form.StartPosition = "CenterScreen"
$form.BackColor     = $clrBg
$form.Font          = $fntUI

# ── Header bar ────────────────────────────────────────────────────────────────
$pnlHeader = New-Object System.Windows.Forms.Panel
$pnlHeader.Dock = "Top"
$pnlHeader.Height = 64
$pnlHeader.BackColor = $clrSurface

$lblAppTitle = New-Object System.Windows.Forms.Label
$lblAppTitle.Text      = "  Windows Optimizer Console"
$lblAppTitle.Font      = $fntHead
$lblAppTitle.ForeColor = $clrText
$lblAppTitle.AutoSize  = $true
$lblAppTitle.Location  = New-Object System.Drawing.Point(10, 16)
$lblAppTitle.BackColor = [System.Drawing.Color]::Transparent

# Drive C card
$pnlDriveC = New-Object System.Windows.Forms.Panel
$pnlDriveC.Size      = New-Object System.Drawing.Size(210, 48)
$pnlDriveC.Location  = New-Object System.Drawing.Point(820, 8)
$pnlDriveC.BackColor = $clrRaised
$pnlDriveC.Anchor    = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right

$lblDriveC = New-Object System.Windows.Forms.Label
$lblDriveC.Text      = "C:  —"
$lblDriveC.Font      = $fntH2
$lblDriveC.ForeColor = $clrText
$lblDriveC.BackColor = [System.Drawing.Color]::Transparent
$lblDriveC.AutoSize  = $true
$lblDriveC.Location  = New-Object System.Drawing.Point(8, 5)

$pbDriveC = New-Object System.Windows.Forms.ProgressBar
$pbDriveC.Size     = New-Object System.Drawing.Size(194, 8)
$pbDriveC.Location = New-Object System.Drawing.Point(8, 32)
$pbDriveC.Minimum  = 0
$pbDriveC.Maximum  = 100
$pbDriveC.Value    = 0

$pnlDriveC.Controls.AddRange(@($lblDriveC, $pbDriveC))

# Drive D card
$pnlDriveD = New-Object System.Windows.Forms.Panel
$pnlDriveD.Size      = New-Object System.Drawing.Size(210, 48)
$pnlDriveD.Location  = New-Object System.Drawing.Point(1044, 8)
$pnlDriveD.BackColor = $clrRaised
$pnlDriveD.Anchor    = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right

$lblDriveD = New-Object System.Windows.Forms.Label
$lblDriveD.Text      = "D:  —"
$lblDriveD.Font      = $fntH2
$lblDriveD.ForeColor = $clrText
$lblDriveD.BackColor = [System.Drawing.Color]::Transparent
$lblDriveD.AutoSize  = $true
$lblDriveD.Location  = New-Object System.Drawing.Point(8, 5)

$pbDriveD = New-Object System.Windows.Forms.ProgressBar
$pbDriveD.Size     = New-Object System.Drawing.Size(194, 8)
$pbDriveD.Location = New-Object System.Drawing.Point(8, 32)
$pbDriveD.Minimum  = 0
$pbDriveD.Maximum  = 100
$pbDriveD.Value    = 0

$pnlDriveD.Controls.AddRange(@($lblDriveD, $pbDriveD))

# Header bottom accent line
$pnlHeaderLine = New-Object System.Windows.Forms.Panel
$pnlHeaderLine.Dock      = "Bottom"
$pnlHeaderLine.Height    = 3
$pnlHeaderLine.BackColor = $clrAccent

$pnlHeader.Controls.AddRange(@($lblAppTitle, $pnlDriveC, $pnlDriveD, $pnlHeaderLine))

# ── Status bar (bottom) ───────────────────────────────────────────────────────
$pnlStatusBar = New-Object System.Windows.Forms.Panel
$pnlStatusBar.Dock      = "Bottom"
$pnlStatusBar.Height    = 28
$pnlStatusBar.BackColor = $clrSurface

$pnlStatusBarLine = New-Object System.Windows.Forms.Panel
$pnlStatusBarLine.Dock      = "Top"
$pnlStatusBarLine.Height    = 1
$pnlStatusBarLine.BackColor = $clrBorderC

$lblStatusLeft = New-Object System.Windows.Forms.Label
$lblStatusLeft.Text      = "Ready"
$lblStatusLeft.Font      = $fntSmall
$lblStatusLeft.ForeColor = $clrMuted
$lblStatusLeft.AutoSize  = $true
$lblStatusLeft.Location  = New-Object System.Drawing.Point(10, 7)
$lblStatusLeft.BackColor = [System.Drawing.Color]::Transparent

$lblStatusRight = New-Object System.Windows.Forms.Label
$lblStatusRight.Text      = "PSHost: —"
$lblStatusRight.Font      = $fntSmall
$lblStatusRight.ForeColor = $clrMuted
$lblStatusRight.Width     = 420
$lblStatusRight.AutoSize  = $false
$lblStatusRight.TextAlign = "MiddleRight"
$lblStatusRight.Location  = New-Object System.Drawing.Point(950, 5)
$lblStatusRight.BackColor = [System.Drawing.Color]::Transparent
$lblStatusRight.Anchor    = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right

$pnlStatusBar.Controls.AddRange(@($pnlStatusBarLine, $lblStatusLeft, $lblStatusRight))

# ── TabControl ────────────────────────────────────────────────────────────────
$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock      = "Fill"
$tabs.DrawMode  = "OwnerDrawFixed"
$tabs.ItemSize  = New-Object System.Drawing.Size(136, 34)
$tabs.SizeMode  = "Fixed"
$tabs.BackColor = $clrBg
$tabs.Font      = $fntH2

$tabs.Add_DrawItem({
    param($s, $e)
    $page      = $s.TabPages[$e.Index]
    $isActive  = ($s.SelectedIndex -eq $e.Index)
    $bg        = if ($isActive) { $clrSurface } else { $clrBg }
    $fg        = if ($isActive) { $clrText } else { $clrMuted }
    $e.Graphics.FillRectangle((New-Object System.Drawing.SolidBrush($bg)), $e.Bounds)
    $sf            = New-Object System.Drawing.StringFormat
    $sf.Alignment  = [System.Drawing.StringAlignment]::Center
    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $e.Graphics.DrawString($page.Text, $fntH2,
        (New-Object System.Drawing.SolidBrush($fg)),
        [System.Drawing.RectangleF]::new($e.Bounds.X, $e.Bounds.Y, $e.Bounds.Width, $e.Bounds.Height), $sf)
    if ($isActive) {
        $e.Graphics.FillRectangle(
            (New-Object System.Drawing.SolidBrush($clrAccent)),
            $e.Bounds.X + 4, $e.Bounds.Bottom - 3, $e.Bounds.Width - 8, 3)
    }
})

$tabDashboard = New-Object System.Windows.Forms.TabPage
$tabDashboard.Text                 = "Dashboard"
$tabDashboard.BackColor            = $clrBg
$tabDashboard.UseVisualStyleBackColor = $false

$tabTasks = New-Object System.Windows.Forms.TabPage
$tabTasks.Text                 = "Tasks"
$tabTasks.BackColor            = $clrBg
$tabTasks.UseVisualStyleBackColor = $false

$tabLogs = New-Object System.Windows.Forms.TabPage
$tabLogs.Text                 = "Logs"
$tabLogs.BackColor            = $clrBg
$tabLogs.UseVisualStyleBackColor = $false

$tabConfig = New-Object System.Windows.Forms.TabPage
$tabConfig.Text                 = "Config"
$tabConfig.BackColor            = $clrBg
$tabConfig.UseVisualStyleBackColor = $false

$tabDeepScan = New-Object System.Windows.Forms.TabPage
$tabDeepScan.Text                 = "Deep Scan"
$tabDeepScan.BackColor            = $clrBg
$tabDeepScan.UseVisualStyleBackColor = $false

# ═══════════════════════════════════════════════════════════════════════════════
#  Dashboard Tab
# ═══════════════════════════════════════════════════════════════════════════════

# Action panel
$pnlActions = New-Object System.Windows.Forms.Panel
$pnlActions.Dock      = "Top"
$pnlActions.Height    = 106
$pnlActions.BackColor = $clrSurface

# Row 1 — operation buttons (y=12)
$clrTeal = [System.Drawing.Color]::FromArgb(13, 148, 136)
$btnAnalyze       = New-Btn "Scan Garbage"    $clrAccent  140 34
$btnCompute       = New-Btn "Compute"          $clrPurple  110 34
$btnAudit         = New-Btn "Audit"            $clrCyan     90 34
$btnExecute       = New-Btn "Execute"          $clrRed      96 34
$btnQuickClean    = New-Btn "Quick Clean"      $clrGreen   118 34
$btnHealthAudit   = New-Btn "Health Audit"     $clrTeal    118 34
$btnDiagnostics   = New-Btn "Diagnostics"      $clrAmber   118 34
$btnCancelAnalyze = New-Btn "Cancel"           $clrRaised   90 34

$btnAnalyze.Location       = New-Object System.Drawing.Point(12,  12)
$btnCompute.Location       = New-Object System.Drawing.Point(158, 12)
$btnAudit.Location         = New-Object System.Drawing.Point(274, 12)
$btnExecute.Location       = New-Object System.Drawing.Point(370, 12)
$btnQuickClean.Location    = New-Object System.Drawing.Point(472, 12)
$btnHealthAudit.Location   = New-Object System.Drawing.Point(596, 12)
$btnDiagnostics.Location   = New-Object System.Drawing.Point(720, 12)
$btnCancelAnalyze.Location = New-Object System.Drawing.Point(844, 12)

$btnCancelAnalyze.Enabled  = $false
$btnCancelAnalyze.ForeColor = $clrMuted

# Row 2 — settings (y=56)
$lblDepth = New-Object System.Windows.Forms.Label
$lblDepth.Text      = "DEPTH"
$lblDepth.Font      = $fntSmall
$lblDepth.ForeColor = $clrMuted
$lblDepth.AutoSize  = $true
$lblDepth.Location  = New-Object System.Drawing.Point(12, 62)
$lblDepth.BackColor = [System.Drawing.Color]::Transparent

$cmbDepth = New-Object System.Windows.Forms.ComboBox
$cmbDepth.DropDownStyle = "DropDownList"
$cmbDepth.Items.AddRange(@("Quick", "Standard", "Deep"))
$cmbDepth.SelectedItem = "Standard"
$cmbDepth.Width = 104
$cmbDepth.Location = New-Object System.Drawing.Point(60, 58)
$cmbDepth.BackColor = $clrRaised
$cmbDepth.ForeColor = $clrText
$cmbDepth.Font = $fntUI
$cmbDepth.FlatStyle = "Flat"

$lblAuditLevel = New-Object System.Windows.Forms.Label
$lblAuditLevel.Text      = "AUDIT"
$lblAuditLevel.Font      = $fntSmall
$lblAuditLevel.ForeColor = $clrMuted
$lblAuditLevel.AutoSize  = $true
$lblAuditLevel.Location  = New-Object System.Drawing.Point(178, 62)
$lblAuditLevel.BackColor = [System.Drawing.Color]::Transparent

$cmbAuditLevel = New-Object System.Windows.Forms.ComboBox
$cmbAuditLevel.DropDownStyle = "DropDownList"
$cmbAuditLevel.Items.AddRange(@("FileLevel", "BitLevel"))
$cmbAuditLevel.SelectedItem = "FileLevel"
$cmbAuditLevel.Width = 110
$cmbAuditLevel.Location = New-Object System.Drawing.Point(226, 58)
$cmbAuditLevel.BackColor = $clrRaised
$cmbAuditLevel.ForeColor = $clrText
$cmbAuditLevel.Font = $fntUI
$cmbAuditLevel.FlatStyle = "Flat"

$lblCleanupMode = New-Object System.Windows.Forms.Label
$lblCleanupMode.Text      = "MODE"
$lblCleanupMode.Font      = $fntSmall
$lblCleanupMode.ForeColor = $clrMuted
$lblCleanupMode.AutoSize  = $true
$lblCleanupMode.Location  = New-Object System.Drawing.Point(350, 62)
$lblCleanupMode.BackColor = [System.Drawing.Color]::Transparent

$cmbCleanupMode = New-Object System.Windows.Forms.ComboBox
$cmbCleanupMode.DropDownStyle = "DropDownList"
$cmbCleanupMode.Items.AddRange(@("Safe", "Radical"))
$cmbCleanupMode.SelectedItem = "Safe"
$cmbCleanupMode.Width = 90
$cmbCleanupMode.Location = New-Object System.Drawing.Point(396, 58)
$cmbCleanupMode.BackColor = $clrRaised
$cmbCleanupMode.ForeColor = $clrText
$cmbCleanupMode.Font = $fntUI
$cmbCleanupMode.FlatStyle = "Flat"

$lblTop = New-Object System.Windows.Forms.Label
$lblTop.Text      = "TOP"
$lblTop.Font      = $fntSmall
$lblTop.ForeColor = $clrMuted
$lblTop.AutoSize  = $true
$lblTop.Location  = New-Object System.Drawing.Point(500, 62)
$lblTop.BackColor = [System.Drawing.Color]::Transparent

$numTop = New-Object System.Windows.Forms.NumericUpDown
$numTop.Minimum  = 5
$numTop.Maximum  = 100
$numTop.Value    = 25
$numTop.Width    = 64
$numTop.Location = New-Object System.Drawing.Point(530, 58)
$numTop.BackColor = $clrRaised
$numTop.ForeColor = $clrText
$numTop.Font = $fntUI

$lblExplorerHint = New-Object System.Windows.Forms.Label
$lblExplorerHint.Text      = "Double-click a row to open in Explorer"
$lblExplorerHint.Font      = $fntSmall
$lblExplorerHint.ForeColor = $clrMuted
$lblExplorerHint.AutoSize  = $true
$lblExplorerHint.Location  = New-Object System.Drawing.Point(740, 62)
$lblExplorerHint.BackColor = [System.Drawing.Color]::Transparent

$lblFixLevel = New-Object System.Windows.Forms.Label
$lblFixLevel.Text      = "FIX"
$lblFixLevel.Font      = $fntSmall
$lblFixLevel.ForeColor = $clrMuted
$lblFixLevel.AutoSize  = $true
$lblFixLevel.Location  = New-Object System.Drawing.Point(610, 62)
$lblFixLevel.BackColor = [System.Drawing.Color]::Transparent

$cmbFixLevel = New-Object System.Windows.Forms.ComboBox
$cmbFixLevel.DropDownStyle = "DropDownList"
$cmbFixLevel.Items.AddRange(@("Safe", "Moderate", "Aggressive"))
$cmbFixLevel.SelectedItem = "Safe"
$cmbFixLevel.Width = 100
$cmbFixLevel.Location = New-Object System.Drawing.Point(638, 58)
$cmbFixLevel.BackColor = $clrRaised
$cmbFixLevel.ForeColor = $clrText
$cmbFixLevel.Font = $fntUI
$cmbFixLevel.FlatStyle = "Flat"

$pnlActionsBorder = New-Object System.Windows.Forms.Panel
$pnlActionsBorder.Dock      = "Bottom"
$pnlActionsBorder.Height    = 1
$pnlActionsBorder.BackColor = $clrBorderC

$pnlActions.Controls.AddRange(@(
    $btnAnalyze, $btnCompute, $btnAudit, $btnExecute,
    $btnQuickClean, $btnHealthAudit, $btnDiagnostics, $btnCancelAnalyze,
    $lblDepth, $cmbDepth, $lblAuditLevel, $cmbAuditLevel,
    $lblCleanupMode, $cmbCleanupMode, $lblTop, $numTop,
    $lblFixLevel, $cmbFixLevel,
    $lblExplorerHint, $pnlActionsBorder
))

# Progress band (animated, shown only when busy)
$pnlProgress = New-Object System.Windows.Forms.Panel
$pnlProgress.Dock      = "Top"
$pnlProgress.Height    = 44
$pnlProgress.BackColor = $clrRaised
$pnlProgress.Visible   = $false

$progressAnalysis = New-Object System.Windows.Forms.ProgressBar
$progressAnalysis.Style                = "Marquee"
$progressAnalysis.MarqueeAnimationSpeed = 28
$progressAnalysis.Dock                 = "Top"
$progressAnalysis.Height               = 5
$progressAnalysis.Minimum              = 0
$progressAnalysis.Maximum              = 100
$progressAnalysis.Value                = 0

$lblAnalysisState = New-Object System.Windows.Forms.Label
$lblAnalysisState.Text      = "Idle"
$lblAnalysisState.Font      = $fntH2
$lblAnalysisState.ForeColor = $clrAccent
$lblAnalysisState.AutoSize  = $true
$lblAnalysisState.Location  = New-Object System.Drawing.Point(14, 12)
$lblAnalysisState.BackColor = [System.Drawing.Color]::Transparent

$pnlProgress.Controls.AddRange(@($progressAnalysis, $lblAnalysisState))

# Hotspot Explorer ListView
$listExplorer = New-Object System.Windows.Forms.ListView
$listExplorer.View          = "Details"
$listExplorer.FullRowSelect = $true
$listExplorer.GridLines     = $false
$listExplorer.Dock          = "Fill"
$listExplorer.HideSelection = $false
$listExplorer.BackColor     = $clrSurface
$listExplorer.ForeColor     = $clrText
$listExplorer.Font          = $fntUI
$listExplorer.BorderStyle   = "None"
$listExplorer.Columns.Add("Score",     68)  | Out-Null
$listExplorer.Columns.Add("Risk",      76)  | Out-Null
$listExplorer.Columns.Add("Drive",     54)  | Out-Null
$listExplorer.Columns.Add("Path",      384) | Out-Null
$listExplorer.Columns.Add("Category",  100) | Out-Null
$listExplorer.Columns.Add("Provenance",120) | Out-Null
$listExplorer.Columns.Add("Type",      110) | Out-Null
$listExplorer.Columns.Add("Stale%",    74)  | Out-Null
$listExplorer.Columns.Add("Reclaim GB",96)  | Out-Null
$listExplorer.Columns.Add("Files",     68)  | Out-Null

# Status feed (dark terminal style)
$txtStatus = New-Object System.Windows.Forms.TextBox
$txtStatus.Multiline    = $true
$txtStatus.ScrollBars   = "Vertical"
$txtStatus.Dock         = "Fill"
$txtStatus.ReadOnly     = $true
$txtStatus.BackColor    = $clrBg
$txtStatus.ForeColor    = $clrText
$txtStatus.Font         = $fntMono
$txtStatus.BorderStyle  = "None"

# SplitContainer: top = explorer, bottom = status feed
$splitDash = New-Object System.Windows.Forms.SplitContainer
$splitDash.Dock              = "Fill"
$splitDash.Orientation       = "Horizontal"
$splitDash.SplitterDistance  = 210
$splitDash.SplitterWidth     = 3
$splitDash.BackColor         = $clrBorderC
$splitDash.Panel1.BackColor  = $clrBg
$splitDash.Panel2.BackColor  = $clrBg
$splitDash.Panel1.Controls.Add($listExplorer)
$splitDash.Panel2.Controls.Add($txtStatus)

$tabDashboard.Controls.Add($splitDash)
$tabDashboard.Controls.Add($pnlProgress)
$tabDashboard.Controls.Add($pnlActions)

# ═══════════════════════════════════════════════════════════════════════════════
#  Tasks Tab
# ═══════════════════════════════════════════════════════════════════════════════
$listTasks = New-Object System.Windows.Forms.ListView
$listTasks.View          = "Details"
$listTasks.FullRowSelect = $true
$listTasks.GridLines     = $false
$listTasks.Dock          = "Fill"
$listTasks.BackColor     = $clrSurface
$listTasks.ForeColor     = $clrText
$listTasks.Font          = $fntUI
$listTasks.BorderStyle   = "None"
$listTasks.Columns.Add("TaskName",    280) | Out-Null
$listTasks.Columns.Add("State",       120) | Out-Null
$listTasks.Columns.Add("NextRunTime", 220) | Out-Null

$pnlTasksHeader = New-Object System.Windows.Forms.Panel
$pnlTasksHeader.Dock      = "Top"
$pnlTasksHeader.Height    = 60
$pnlTasksHeader.BackColor = $clrSurface

$btnReloadTasks  = New-Btn "Reload Tasks"  $clrRaised  128 34
$btnInstallTasks = New-Btn "Install Core"  $clrAccent  128 34
$btnReloadTasks.Location  = New-Object System.Drawing.Point(12, 13)
$btnInstallTasks.Location = New-Object System.Drawing.Point(148, 13)

$pnlTasksBorderB = New-Object System.Windows.Forms.Panel
$pnlTasksBorderB.Dock = "Bottom"; $pnlTasksBorderB.Height = 1; $pnlTasksBorderB.BackColor = $clrBorderC

$pnlTasksHeader.Controls.AddRange(@($btnReloadTasks, $btnInstallTasks, $pnlTasksBorderB))
$tabTasks.Controls.Add($listTasks)
$tabTasks.Controls.Add($pnlTasksHeader)

# ═══════════════════════════════════════════════════════════════════════════════
#  Logs Tab
# ═══════════════════════════════════════════════════════════════════════════════
$txtLogs = New-Object System.Windows.Forms.TextBox
$txtLogs.Multiline   = $true
$txtLogs.ScrollBars  = "Vertical"
$txtLogs.Dock        = "Fill"
$txtLogs.ReadOnly    = $true
$txtLogs.BackColor   = $clrBg
$txtLogs.ForeColor   = $clrText
$txtLogs.Font        = $fntMono
$txtLogs.BorderStyle = "None"

$pnlLogsHeader = New-Object System.Windows.Forms.Panel
$pnlLogsHeader.Dock      = "Top"
$pnlLogsHeader.Height    = 60
$pnlLogsHeader.BackColor = $clrSurface

$cmbLogSource = New-Object System.Windows.Forms.ComboBox
$cmbLogSource.DropDownStyle = "DropDownList"
$cmbLogSource.Width      = 270
$cmbLogSource.Location   = New-Object System.Drawing.Point(12, 16)
$cmbLogSource.BackColor  = $clrRaised
$cmbLogSource.ForeColor  = $clrText
$cmbLogSource.Font       = $fntUI
$cmbLogSource.FlatStyle  = "Flat"
$cmbLogSource.Items.AddRange(@(
    "Garbage Analyzer (stdout)", "Garbage Analyzer (stderr)",
    "Cleanup (stdout)", "Cleanup (stderr)",
    "Compute Analyzer (stdout)", "Compute Analyzer (stderr)",
    "Quick Cleanup (stdout)", "Quick Cleanup (stderr)",
    "Quick Cleanup (log)", "Storage Cleanup (log)",
    "Health Audit (stdout)", "Health Audit (stderr)"
))
$cmbLogSource.SelectedIndex = 0

$btnLoadLogs = New-Btn "Load Last 200"  $clrRaised  130 34
$btnLoadLogs.Location = New-Object System.Drawing.Point(294, 13)

$pnlLogsBorderB = New-Object System.Windows.Forms.Panel
$pnlLogsBorderB.Dock = "Bottom"; $pnlLogsBorderB.Height = 1; $pnlLogsBorderB.BackColor = $clrBorderC

$pnlLogsHeader.Controls.AddRange(@($cmbLogSource, $btnLoadLogs, $pnlLogsBorderB))
$tabLogs.Controls.Add($txtLogs)
$tabLogs.Controls.Add($pnlLogsHeader)

# ═══════════════════════════════════════════════════════════════════════════════
#  Config Tab
# ═══════════════════════════════════════════════════════════════════════════════
$pnlConfigBody = New-Object System.Windows.Forms.Panel
$pnlConfigBody.Dock      = "Fill"
$pnlConfigBody.BackColor = $clrBg

$lblConfigHeading = New-Object System.Windows.Forms.Label
$lblConfigHeading.Text      = "Configuration File"
$lblConfigHeading.Font      = $fntH2
$lblConfigHeading.ForeColor = $clrMuted
$lblConfigHeading.AutoSize  = $true
$lblConfigHeading.Location  = New-Object System.Drawing.Point(24, 28)
$lblConfigHeading.BackColor = [System.Drawing.Color]::Transparent

$lblConfig = New-Object System.Windows.Forms.Label
$lblConfig.Text      = $script:configPath
$lblConfig.Font      = $fntMono
$lblConfig.ForeColor = $clrText
$lblConfig.AutoSize  = $true
$lblConfig.Location  = New-Object System.Drawing.Point(24, 52)
$lblConfig.BackColor = [System.Drawing.Color]::Transparent

$btnOpenConfig = New-Btn "Open in Notepad"  $clrRaised  150 34
$btnOpenConfig.Location = New-Object System.Drawing.Point(24, 88)

$pnlConfigBody.Controls.AddRange(@($lblConfigHeading, $lblConfig, $btnOpenConfig))
$tabConfig.Controls.Add($pnlConfigBody)

# ═══════════════════════════════════════════════════════════════════════════════
#  Deep Scan Tab
# ═══════════════════════════════════════════════════════════════════════════════

# ── Header ────────────────────────────────────────────────────────────────────
$pnlDeepScanHeader = New-Object System.Windows.Forms.Panel
$pnlDeepScanHeader.Dock      = "Top"
$pnlDeepScanHeader.Height    = 72
$pnlDeepScanHeader.BackColor = $clrSurface

$btnDeepScanRun = New-Btn "Run Deep Scan"  $clrCyan   130 34
$btnDeepScanRun.Location = New-Object System.Drawing.Point(12, 19)

$btnDeepScanCancel = New-Btn "Cancel"  $clrRaised  90 34
$btnDeepScanCancel.Location  = New-Object System.Drawing.Point(150, 19)
$btnDeepScanCancel.Enabled   = $false
$btnDeepScanCancel.ForeColor = $clrMuted

$lblDeepFixLabel = New-Object System.Windows.Forms.Label
$lblDeepFixLabel.Text      = "MAX FIX"
$lblDeepFixLabel.Font      = $fntSmall
$lblDeepFixLabel.ForeColor = $clrMuted
$lblDeepFixLabel.AutoSize  = $true
$lblDeepFixLabel.Location  = New-Object System.Drawing.Point(256, 24)
$lblDeepFixLabel.BackColor = [System.Drawing.Color]::Transparent

$cmbDeepFixLevel = New-Object System.Windows.Forms.ComboBox
$cmbDeepFixLevel.DropDownStyle = "DropDownList"
$cmbDeepFixLevel.Items.AddRange(@("Safe", "Moderate", "Aggressive"))
$cmbDeepFixLevel.SelectedItem = "Safe"
$cmbDeepFixLevel.Width     = 104
$cmbDeepFixLevel.Location  = New-Object System.Drawing.Point(312, 19)
$cmbDeepFixLevel.BackColor = $clrRaised
$cmbDeepFixLevel.ForeColor = $clrText
$cmbDeepFixLevel.Font      = $fntUI
$cmbDeepFixLevel.FlatStyle = "Flat"

$lblDeepFilterLabel = New-Object System.Windows.Forms.Label
$lblDeepFilterLabel.Text      = "SHOW"
$lblDeepFilterLabel.Font      = $fntSmall
$lblDeepFilterLabel.ForeColor = $clrMuted
$lblDeepFilterLabel.AutoSize  = $true
$lblDeepFilterLabel.Location  = New-Object System.Drawing.Point(430, 24)
$lblDeepFilterLabel.BackColor = [System.Drawing.Color]::Transparent

$cmbDeepFilter = New-Object System.Windows.Forms.ComboBox
$cmbDeepFilter.DropDownStyle = "DropDownList"
$cmbDeepFilter.Items.AddRange(@("All", "Critical", "Important+", "Critical+Important"))
$cmbDeepFilter.SelectedItem = "All"
$cmbDeepFilter.Width     = 130
$cmbDeepFilter.Location  = New-Object System.Drawing.Point(474, 19)
$cmbDeepFilter.BackColor = $clrRaised
$cmbDeepFilter.ForeColor = $clrText
$cmbDeepFilter.Font      = $fntUI
$cmbDeepFilter.FlatStyle = "Flat"

$btnDeepExport = New-Btn "Export Report"  $clrRaised  118 34
$btnDeepExport.Location = New-Object System.Drawing.Point(612, 19)
$btnDeepExport.Enabled  = $false
$btnDeepExport.ForeColor = $clrMuted

$lblDeepScanDesc = New-Object System.Windows.Forms.Label
$lblDeepScanDesc.Text      = "Full system performance audit — hardware, OS settings, drivers, services.  Select a finding, choose a solution, then click Apply."
$lblDeepScanDesc.Font      = $fntSmall
$lblDeepScanDesc.ForeColor = $clrMuted
$lblDeepScanDesc.AutoSize  = $true
$lblDeepScanDesc.Location  = New-Object System.Drawing.Point(738, 24)
$lblDeepScanDesc.BackColor = [System.Drawing.Color]::Transparent

$pnlDeepScanHeaderBorder = New-Object System.Windows.Forms.Panel
$pnlDeepScanHeaderBorder.Dock      = "Bottom"
$pnlDeepScanHeaderBorder.Height    = 1
$pnlDeepScanHeaderBorder.BackColor = $clrBorderC

$pnlDeepScanHeader.Controls.AddRange(@(
    $btnDeepScanRun, $btnDeepScanCancel,
    $lblDeepFixLabel, $cmbDeepFixLevel,
    $lblDeepFilterLabel, $cmbDeepFilter, $btnDeepExport,
    $lblDeepScanDesc, $pnlDeepScanHeaderBorder
))

# ── Progress band ─────────────────────────────────────────────────────────────
$pnlDeepScanProgress = New-Object System.Windows.Forms.Panel
$pnlDeepScanProgress.Dock      = "Top"
$pnlDeepScanProgress.Height    = 44
$pnlDeepScanProgress.BackColor = $clrRaised
$pnlDeepScanProgress.Visible   = $false

$progressDeepScan = New-Object System.Windows.Forms.ProgressBar
$progressDeepScan.Style                 = "Marquee"
$progressDeepScan.MarqueeAnimationSpeed = 28
$progressDeepScan.Dock                  = "Top"
$progressDeepScan.Height                = 5
$progressDeepScan.Minimum               = 0
$progressDeepScan.Maximum               = 100
$progressDeepScan.Value                 = 0

$lblDeepScanState = New-Object System.Windows.Forms.Label
$lblDeepScanState.Text      = "Idle"
$lblDeepScanState.Font      = $fntH2
$lblDeepScanState.ForeColor = $clrCyan
$lblDeepScanState.AutoSize  = $true
$lblDeepScanState.Location  = New-Object System.Drawing.Point(14, 12)
$lblDeepScanState.BackColor = [System.Drawing.Color]::Transparent

$pnlDeepScanProgress.Controls.AddRange(@($progressDeepScan, $lblDeepScanState))

# ── Findings ListView ─────────────────────────────────────────────────────────
$listDeepFindings = New-Object System.Windows.Forms.ListView
$listDeepFindings.View          = "Details"
$listDeepFindings.FullRowSelect = $true
$listDeepFindings.GridLines     = $false
$listDeepFindings.Dock          = "Fill"
$listDeepFindings.HideSelection = $false
$listDeepFindings.BackColor     = $clrSurface
$listDeepFindings.ForeColor     = $clrText
$listDeepFindings.Font          = $fntUI
$listDeepFindings.BorderStyle   = "None"
$listDeepFindings.Columns.Add("Sev",      70)  | Out-Null
$listDeepFindings.Columns.Add("Category", 90)  | Out-Null
$listDeepFindings.Columns.Add("ID",       120) | Out-Null
$listDeepFindings.Columns.Add("Title",    330) | Out-Null
$listDeepFindings.Columns.Add("Current",  160) | Out-Null
$listDeepFindings.Columns.Add("Target",   160) | Out-Null

# ── Right detail pane ─────────────────────────────────────────────────────────
$txtDeepFindingDetail = New-Object System.Windows.Forms.TextBox
$txtDeepFindingDetail.Multiline   = $true
$txtDeepFindingDetail.ScrollBars  = "Vertical"
$txtDeepFindingDetail.Dock        = "Fill"
$txtDeepFindingDetail.ReadOnly    = $true
$txtDeepFindingDetail.BackColor   = $clrBg
$txtDeepFindingDetail.ForeColor   = $clrText
$txtDeepFindingDetail.Font        = $fntUI
$txtDeepFindingDetail.BorderStyle = "None"

# Solutions ListView
$listDeepSolutions = New-Object System.Windows.Forms.ListView
$listDeepSolutions.View          = "Details"
$listDeepSolutions.FullRowSelect = $true
$listDeepSolutions.GridLines     = $false
$listDeepSolutions.Dock          = "Fill"
$listDeepSolutions.HideSelection = $false
$listDeepSolutions.BackColor     = $clrSurface
$listDeepSolutions.ForeColor     = $clrText
$listDeepSolutions.Font          = $fntUI
$listDeepSolutions.BorderStyle   = "None"
$listDeepSolutions.Columns.Add("Level",    76)  | Out-Null
$listDeepSolutions.Columns.Add("Fix",      240) | Out-Null
$listDeepSolutions.Columns.Add("Risk",     200) | Out-Null
$listDeepSolutions.Columns.Add("Rollback", 200) | Out-Null

# Apply button panel  (Dock=Bottom, wraps solutions list)
$pnlDeepApply = New-Object System.Windows.Forms.Panel
$pnlDeepApply.Dock      = "Bottom"
$pnlDeepApply.Height    = 50
$pnlDeepApply.BackColor = $clrSurface

$btnDeepApply = New-Btn "Apply Selected Fix"  $clrGreen  160 34
$btnDeepApply.Location  = New-Object System.Drawing.Point(12, 8)
$btnDeepApply.Enabled   = $false
$btnDeepApply.ForeColor = $clrMuted

$lblDeepApplyState = New-Object System.Windows.Forms.Label
$lblDeepApplyState.Text      = "Select a finding then a solution"
$lblDeepApplyState.Font      = $fntSmall
$lblDeepApplyState.ForeColor = $clrMuted
$lblDeepApplyState.AutoSize  = $true
$lblDeepApplyState.Location  = New-Object System.Drawing.Point(182, 16)
$lblDeepApplyState.BackColor = [System.Drawing.Color]::Transparent

$pnlDeepApply.Controls.AddRange(@($btnDeepApply, $lblDeepApplyState))

# Panel wrapping solutions list + apply strip (Dock=Fill)
$pnlDeepSolWrapper = New-Object System.Windows.Forms.Panel
$pnlDeepSolWrapper.Dock      = "Fill"
$pnlDeepSolWrapper.BackColor = $clrBg
$pnlDeepSolWrapper.SuspendLayout()
$pnlDeepSolWrapper.Controls.Add($listDeepSolutions)  # index 0 → Fill  → last
$pnlDeepSolWrapper.Controls.Add($pnlDeepApply)        # index 1 → Bottom → first
$pnlDeepSolWrapper.ResumeLayout($false)

# Inner split: finding detail (top) / solutions+apply (bottom)
$splitDeepDetail = New-Object System.Windows.Forms.SplitContainer
$splitDeepDetail.Dock             = "Fill"
$splitDeepDetail.Orientation      = "Horizontal"
$splitDeepDetail.SplitterDistance = 165
$splitDeepDetail.SplitterWidth    = 3
$splitDeepDetail.BackColor        = $clrBorderC
$splitDeepDetail.Panel1.BackColor = $clrBg
$splitDeepDetail.Panel2.BackColor = $clrBg
$splitDeepDetail.Panel1.Controls.Add($txtDeepFindingDetail)
$splitDeepDetail.Panel2.Controls.Add($pnlDeepSolWrapper)

# Outer split: findings list (left) / detail+solutions (right)
$splitDeepMain = New-Object System.Windows.Forms.SplitContainer
$splitDeepMain.Dock             = "Fill"
$splitDeepMain.Orientation      = "Vertical"
$splitDeepMain.SplitterDistance = 830
$splitDeepMain.SplitterWidth    = 4
$splitDeepMain.BackColor        = $clrBorderC
$splitDeepMain.Panel1.BackColor = $clrBg
$splitDeepMain.Panel2.BackColor = $clrBg
$splitDeepMain.Panel1.Controls.Add($listDeepFindings)
$splitDeepMain.Panel2.Controls.Add($splitDeepDetail)

# Dock z-order: Fill first (index 0), then Top panels (higher indices)
$tabDeepScan.SuspendLayout()
$tabDeepScan.Controls.Add($splitDeepMain)           # index 0 → Fill   → docked last
$tabDeepScan.Controls.Add($pnlDeepScanProgress)     # index 1 → Top    → docked second
$tabDeepScan.Controls.Add($pnlDeepScanHeader)       # index 2 → Top    → docked first
$tabDeepScan.ResumeLayout($false)

# ── Assemble ──────────────────────────────────────────────────────────────────
$tabs.TabPages.AddRange(@($tabDashboard, $tabTasks, $tabLogs, $tabConfig, $tabDeepScan))

# Dock layout processes children from highest index first. Edge-docked controls
# (Top/Bottom) must have HIGHER indices so they claim space BEFORE Fill.
$form.SuspendLayout()
$form.Controls.Add($tabs)          # index 0 → Dock=Fill  → docked last  → remaining space
$form.Controls.Add($pnlStatusBar)  # index 1 → Dock=Bottom → docked second
$form.Controls.Add($pnlHeader)     # index 2 → Dock=Top    → docked first → 64px from top
$form.ResumeLayout($false)

function Append-Status {
    param([string]$Message)

    $stamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $txtStatus.AppendText("$stamp  $Message`r`n")
    $preview = if ($Message.Length -gt 92) { $Message.Substring(0, 89) + "..." } else { $Message }
    $lblStatusLeft.Text = $preview
}

function Load-GuiPreferences {
    if (-not (Test-Path -LiteralPath $script:configPath)) {
        return
    }

    try {
        $cfg = Get-Content -LiteralPath $script:configPath -Raw -ErrorAction Stop | ConvertFrom-Json
    } catch {
        Append-Status ("Config read warning: {0}" -f $_.Exception.Message)
        return
    }

    if (-not $cfg) {
        return
    }

    if ($cfg.PSObject.Properties.Name -contains "Gui") {
        $gui = $cfg.Gui
        if ($null -ne $gui.AutoAnalyzeOnStartup) {
            $script:autoAnalyzeOnStartup = [bool]$gui.AutoAnalyzeOnStartup
        }

        if ($gui.DefaultAnalyzeDepth -and @("Quick", "Standard", "Deep") -contains [string]$gui.DefaultAnalyzeDepth) {
            $script:startupAnalyzeDepth = [string]$gui.DefaultAnalyzeDepth
        }

        if ($null -ne $gui.DefaultAnalyzeTop) {
            $requestedTop = [int]$gui.DefaultAnalyzeTop
            if ($requestedTop -lt 5) { $requestedTop = 5 }
            if ($requestedTop -gt 100) { $requestedTop = 100 }
            $script:startupAnalyzeTop = $requestedTop
        }

        if ($null -ne $gui.ComputeAnalyzeDurationSec) {
            $v = [int]$gui.ComputeAnalyzeDurationSec
            if ($v -lt 2) { $v = 2 }
            if ($v -gt 30) { $v = 30 }
            $script:computeAnalyzeDurationSec = $v
        }

        if ($null -ne $gui.ComputeAnalyzeTop) {
            $v = [int]$gui.ComputeAnalyzeTop
            if ($v -lt 3) { $v = 3 }
            if ($v -gt 30) { $v = 30 }
            $script:computeAnalyzeTop = $v
        }

        if ($null -ne $gui.QuickCleanupRetentionDays) {
            $v = [int]$gui.QuickCleanupRetentionDays
            if ($v -lt 1) { $v = 1 }
            if ($v -gt 14) { $v = 14 }
            $script:quickCleanupRetentionDays = $v
        }

        if ($null -ne $gui.QuickCleanupMaxFilesPerTarget) {
            $v = [int]$gui.QuickCleanupMaxFilesPerTarget
            if ($v -lt 200) { $v = 200 }
            if ($v -gt 10000) { $v = 10000 }
            $script:quickCleanupMaxFilesPerTarget = $v
        }

        if ($null -ne $gui.DiagnosticRetentionDays) {
            $v = [int]$gui.DiagnosticRetentionDays
            if ($v -lt 1) { $v = 1 }
            if ($v -gt 30) { $v = 30 }
            $script:diagnosticRetentionDays = $v
        }
    }
}

function Get-DiagnosticLogFiles {
    return @(
        $script:analysisStdOut,
        $script:analysisStdErr,
        $script:cleanupStdOut,
        $script:cleanupStdErr,
        $script:computeStdOut,
        $script:computeStdErr,
        $script:quickCleanupStdOut,
        $script:quickCleanupStdErr,
        $script:defaultLog
    )
}

function Cleanup-DiagnosticLogs {
    param([int]$RetentionDays)

    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    $logsRoot = Join-Path $script:hubRoot "logs"

    if (-not (Test-Path -LiteralPath $logsRoot)) {
        return
    }

    # Keep JSON state files; rotate only textual logs and diagnostic snapshots.
    $targets = Get-ChildItem -LiteralPath $logsRoot -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            $_.LastWriteTime -lt $cutoff -and
            ($_.Extension -in @(".log", ".txt"))
        }

    foreach ($f in $targets) {
        try {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
        } catch {
            # Non-blocking retention cleanup.
        }
    }
}

function Open-DiagnosticsBundle {
    if (-not (Test-Path -LiteralPath $script:diagnosticsDir)) {
        New-Item -ItemType Directory -Path $script:diagnosticsDir -Force | Out-Null
    }

    $stamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
    $snapshotPath = Join-Path $script:diagnosticsDir ("diagnostics-{0}.txt" -f $stamp)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(("Timestamp: {0}" -f (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")))
    $lines.Add(("State: {0}" -f $lblAnalysisState.Text))
    $lines.Add(("PSHost: {0}" -f $script:psHost))
    $lines.Add("")
    $lines.Add("=== Recent Status (last 80 lines) ===")
    $statusLines = @($txtStatus.Lines)
    $start = [math]::Max(0, $statusLines.Count - 80)
    for ($i = $start; $i -lt $statusLines.Count; $i++) {
        $lines.Add($statusLines[$i])
    }
    $lines.Add("")
    $lines.Add("=== Worker Logs Tail ===")

    foreach ($path in (Get-DiagnosticLogFiles)) {
        $lines.Add(("--- {0} ---" -f $path))
        if (Test-Path -LiteralPath $path) {
            $tail = Get-Content -LiteralPath $path -Tail 20 -ErrorAction SilentlyContinue
            if ($tail) {
                foreach ($row in $tail) { $lines.Add([string]$row) }
            } else {
                $lines.Add("(empty)")
            }
        } else {
            $lines.Add("(missing)")
        }
        $lines.Add("")
    }

    $lines | Out-File -LiteralPath $snapshotPath -Encoding utf8 -Force
    Append-Status ("Diagnostics snapshot saved: {0}" -f $snapshotPath)
    Start-Process explorer.exe -ArgumentList $script:diagnosticsDir
}

function Wait-ForOutputFile {
    param(
        [string]$Path,
        [int]$TimeoutMs = 3000,
        [int]$PollMs = 150
    )

    $elapsed = 0
    while ($elapsed -lt $TimeoutMs) {
        if (Test-Path -LiteralPath $Path) {
            return $true
        }

        Start-Sleep -Milliseconds $PollMs
        $elapsed += $PollMs
    }

    return (Test-Path -LiteralPath $Path)
}

function Remove-IfExists {
    param([string]$Path)

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }
}

function Get-WorkerErrorTail {
    param([string]$ErrorPath)

    if (-not (Test-Path -LiteralPath $ErrorPath)) {
        return ""
    }

    $tail = (Get-Content -LiteralPath $ErrorPath -Tail 6 -ErrorAction SilentlyContinue) -join " | "
    return [string]$tail
}

function Get-ProcessExitCodeSafe {
    param([System.Diagnostics.Process]$Process)

    if ($null -eq $Process) {
        return -1
    }

    try {
        if (-not $Process.HasExited) { return -1 }
        $Process.WaitForExit()
        return [int]$Process.ExitCode
    } catch {
        return -1
    }
}

function Refresh-Drives {
    $drives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Name -in @("C", "D") }
    $parts = @()
    foreach ($d in $drives) {
        $total   = $d.Free + $d.Used
        $usedPct = if ($total -gt 0) { [int](($d.Used / $total) * 100) } else { 0 }
        $freeGB  = [math]::Round($d.Free / 1GB, 1)
        if ($d.Name -eq "C") {
            $lblDriveC.Text = "C:  $freeGB GB free"
            $pbDriveC.Value = [Math]::Min(100, $usedPct)
        } elseif ($d.Name -eq "D") {
            $lblDriveD.Text = "D:  $freeGB GB free"
            $pbDriveD.Value = [Math]::Min(100, $usedPct)
        }
        $parts += "$($d.Name): $freeGB GB free ($usedPct%)"
    }
    $lblStatusRight.Text = ("PSHost: {0}  |  {1}" -f (Split-Path -Leaf $script:psHost), (Get-Date -Format "HH:mm:ss"))
    if ($parts) { Append-Status ($parts -join "  |  ") }
}

function Reload-Tasks {
    $listTasks.Items.Clear()
    $names = @("SystemResourceMonitor", "StorageCleanupSafe")

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
            $item.SubItems.Add("Missing") | Out-Null
            $item.SubItems.Add("-") | Out-Null
            $listTasks.Items.Add($item) | Out-Null
        }
    }
}

function Populate-Explorer {
    param([object[]]$Rows)

    $listExplorer.Items.Clear()
    foreach ($row in $Rows) {
        $item = New-Object System.Windows.Forms.ListViewItem([string]$row.Score)
        [void]$item.SubItems.Add([string]$row.Recommendation)
        [void]$item.SubItems.Add([string]$row.Drive)
        [void]$item.SubItems.Add([string]$row.Path)
        [void]$item.SubItems.Add([string]$row.Category)
        [void]$item.SubItems.Add([string]$row.Provenance)
        [void]$item.SubItems.Add([string]$row.DominantType)
        [void]$item.SubItems.Add([string]$row.StalePct)
        [void]$item.SubItems.Add([string]$row.EstimatedReclaimGB)
        [void]$item.SubItems.Add([string]$row.FilesScanned)

        switch ([string]$row.Recommendation) {
            "High" {
                $item.BackColor = $clrRowHigh
                $item.ForeColor = $clrTxtHigh
            }
            "Medium" {
                $item.BackColor = $clrRowAmber
                $item.ForeColor = $clrTxtAmber
            }
            default {
                $item.BackColor = $clrSurface
                $item.ForeColor = $clrText
            }
        }

        [void]$listExplorer.Items.Add($item)
    }
}

function Get-AnalysisTimeoutSec {
    param([string]$Depth)

    switch ($Depth) {
        "Quick" { return 90 }
        "Deep" { return 420 }
        default { return 210 }
    }
}

function Get-CleanupTimeoutSec {
    param(
        [string]$Depth,
        [bool]$ExecuteNow
    )

    $base = switch ($Depth) {
        "Quick" { 120 }
        "Deep" { 720 }
        default { 360 }
    }

    if ($ExecuteNow) {
        $base += 180
    }

    return $base
}

function Test-AnyOperationRunning {
    $busy = $false

    if ($script:analysisProcess -and (-not $script:analysisProcess.HasExited)) { $busy = $true }
    if ($script:cleanupProcess -and (-not $script:cleanupProcess.HasExited)) { $busy = $true }
    if ($script:computeProcess -and (-not $script:computeProcess.HasExited)) { $busy = $true }
    if ($script:quickCleanupProcess -and (-not $script:quickCleanupProcess.HasExited)) { $busy = $true }
    if ($script:healthAuditProcess -and (-not $script:healthAuditProcess.HasExited)) { $busy = $true }
    if ($script:deepScanProcess -and (-not $script:deepScanProcess.HasExited)) { $busy = $true }
    if ($script:deepScanApplyProcess -and (-not $script:deepScanApplyProcess.HasExited)) { $busy = $true }

    return $busy
}

function Set-AnalysisUiState {
    param(
        [bool]$IsBusy,
        [string]$StateText
    )

    $btnAnalyze.Enabled = -not $IsBusy
    $btnAudit.Enabled = -not $IsBusy
    $btnExecute.Enabled = -not $IsBusy
    $btnCompute.Enabled = -not $IsBusy
    $btnQuickClean.Enabled = -not $IsBusy
    $btnHealthAudit.Enabled = -not $IsBusy
    $cmbDepth.Enabled = -not $IsBusy
    $cmbAuditLevel.Enabled = -not $IsBusy
    $cmbCleanupMode.Enabled = -not $IsBusy
    $cmbFixLevel.Enabled = -not $IsBusy
    $numTop.Enabled = -not $IsBusy
    $btnCancelAnalyze.Enabled   = $IsBusy
    $btnCancelAnalyze.ForeColor = if ($IsBusy) { $clrRed } else { $clrMuted }
    $btnDeepScanRun.Enabled  = -not $IsBusy
    $btnDeepExport.Enabled   = ((-not $IsBusy) -and ($script:deepScanFindings.Count -gt 0))
    $btnDeepExport.ForeColor = if ($btnDeepExport.Enabled) { $clrText } else { $clrMuted }
    $cmbDeepFixLevel.Enabled = -not $IsBusy
    $cmbDeepFilter.Enabled   = -not $IsBusy

    $pnlProgress.Visible = $IsBusy
    if ($IsBusy) {
        $progressAnalysis.Style = "Marquee"
        $progressAnalysis.MarqueeAnimationSpeed = 28
    } else {
        $progressAnalysis.Style = "Continuous"
        $progressAnalysis.Value = 0
    }

    if ($StateText) {
        $lblAnalysisState.Text = $StateText
    }
}

function Show-Toast {
    param(
        [string]$Title,
        [string]$Body,
        [string]$Level = "Info"   # Info | Success | Warning | Error
    )
    try {
        $accentCol = switch ($Level) {
            "Success" { $clrGreen }
            "Warning" { $clrAmber }
            "Error"   { $clrRed }
            default    { $clrAccent }
        }

        $toast = New-Object System.Windows.Forms.Form
        $toast.FormBorderStyle = "None"
        $toast.Size            = New-Object System.Drawing.Size(360, 90)
        $toast.StartPosition   = "Manual"
        $toast.BackColor       = $clrSurface
        $toast.Opacity         = 0.95
        $toast.TopMost         = $true

        $workingArea = $null
        try {
            if ($form -and -not $form.IsDisposed) {
                $workingArea = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
            }
        } catch {}
        if (-not $workingArea) {
            $workingArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        }

        $right  = [int](@($workingArea.Right)  | Select-Object -First 1)
        $bottom = [int](@($workingArea.Bottom) | Select-Object -First 1)
        $x = [Math]::Max(0, $right - $toast.Width - 16)
        $y = [Math]::Max(0, $bottom - $toast.Height - 16)
        $toast.Location = New-Object System.Drawing.Point($x, $y)

        $strip = New-Object System.Windows.Forms.Panel
        $strip.Location  = New-Object System.Drawing.Point(0, 0)
        $strip.Size      = New-Object System.Drawing.Size(5, 90)
        $strip.BackColor = $accentCol
        $toast.Controls.Add($strip)

        $lblT = New-Object System.Windows.Forms.Label
        $lblT.Text      = $Title
        $lblT.Font      = $fntH2
        $lblT.ForeColor = $clrText
        $lblT.AutoSize  = $true
        $lblT.Location  = New-Object System.Drawing.Point(16, 12)
        $lblT.BackColor = [System.Drawing.Color]::Transparent
        $toast.Controls.Add($lblT)

        $lblB = New-Object System.Windows.Forms.Label
        $lblB.Text      = $Body
        $lblB.Font      = $fntSmall
        $lblB.ForeColor = $clrMuted
        $lblB.Size      = New-Object System.Drawing.Size(336, 50)
        $lblB.Location  = New-Object System.Drawing.Point(16, 34)
        $lblB.BackColor = [System.Drawing.Color]::Transparent
        $toast.Controls.Add($lblB)

        $toast.Add_Paint({
            param($s, $e)
            $w = [int](@($s.ClientSize.Width)  | Select-Object -First 1)
            $h = [int](@($s.ClientSize.Height) | Select-Object -First 1)
            if ($w -gt 1 -and $h -gt 1) {
                $e.Graphics.DrawRectangle(
                    (New-Object System.Drawing.Pen($clrBorderC, 1)),
                    0, 0, $w - 1, $h - 1)
            }
        })

        # Timer closure fix: .NET event handlers cannot reliably capture
        # PowerShell local variables after the enclosing function returns.
        # Use Tag properties to pass object references via the sender param.
        $ttimer = New-Object System.Windows.Forms.Timer
        $ttimer.Interval = 4500
        $ttimer.Tag  = $toast   # store toast ref in timer's Tag
        $toast.Tag   = $ttimer  # store timer ref in toast's Tag (prevents GC)
        $ttimer.Add_Tick({
            param($sender, $eArgs)
            $sender.Stop()
            $toastRef = $sender.Tag
            if ($toastRef -and -not $toastRef.IsDisposed) {
                $toastRef.Close()
            }
            $sender.Dispose()
        })
        $ttimer.Start()
        $toast.Show($form)
    } catch {
        Append-Status ("Toast warning: {0}" -f $_.Exception.Message)
    }
}

function Update-CleanupProgress {
    if (-not $script:cleanupStartedAt) {
        return
    }

    $elapsedSec = [math]::Round(((Get-Date) - $script:cleanupStartedAt).TotalSeconds, 0)
    $timeoutSec = [math]::Max(1, $script:cleanupTimeoutSec)
    $pct = [math]::Min(95, [int](($elapsedSec / $timeoutSec) * 100))

    if ($pct -lt $progressAnalysis.Minimum) {
        $pct = $progressAnalysis.Minimum
    }
    if ($pct -gt $progressAnalysis.Maximum) {
        $pct = $progressAnalysis.Maximum
    }

    $progressAnalysis.Value = $pct
    $script:spinIdx = ($script:spinIdx + 1) % $script:spinFrames.Count
    $lblAnalysisState.Text = ("Cleanup running{0}  {1}s / {2}s" -f $script:spinFrames[$script:spinIdx], $elapsedSec, $timeoutSec)

    if (($elapsedSec -gt $timeoutSec) -and (-not $script:cleanupSoftTimeoutWarned)) {
        $script:cleanupSoftTimeoutWarned = $true
        Append-Status ("Cleanup exceeded expected time ({0}s). No forced stop applied; you can cancel manually." -f $timeoutSec)
        $lblAnalysisState.Text = ("Cleanup slower than expected ({0}s > {1}s)." -f $elapsedSec, $timeoutSec)
    }
}

function Update-AnalysisProgress {
    if (-not $script:analysisStartedAt) {
        return
    }

    $elapsedSec = [math]::Round(((Get-Date) - $script:analysisStartedAt).TotalSeconds, 0)
    $timeoutSec = [math]::Max(1, $script:analysisTimeoutSec)
    $pct = [math]::Min(95, [int](($elapsedSec / $timeoutSec) * 100))

    if ($pct -lt $progressAnalysis.Minimum) {
        $pct = $progressAnalysis.Minimum
    }
    if ($pct -gt $progressAnalysis.Maximum) {
        $pct = $progressAnalysis.Maximum
    }

    $progressAnalysis.Value = $pct
    $script:spinIdx = ($script:spinIdx + 1) % $script:spinFrames.Count
    $lblAnalysisState.Text = ("Scanning{0}  {1}s / {2}s" -f $script:spinFrames[$script:spinIdx], $elapsedSec, $timeoutSec)

    if (($elapsedSec -gt $timeoutSec) -and (-not $script:analysisSoftTimeoutWarned)) {
        $script:analysisSoftTimeoutWarned = $true
        Append-Status ("Analyzer exceeded expected time ({0}s). No forced stop applied; you can cancel manually." -f $timeoutSec)
        $lblAnalysisState.Text = ("Analyzer slower than expected ({0}s > {1}s)." -f $elapsedSec, $timeoutSec)
    }
}

function Update-ComputeProgress {
    if (-not $script:computeStartedAt) {
        return
    }

    $elapsedSec = [math]::Round(((Get-Date) - $script:computeStartedAt).TotalSeconds, 0)
    $timeoutSec = [math]::Max(1, $script:computeTimeoutSec)
    $pct = [math]::Min(95, [int](($elapsedSec / $timeoutSec) * 100))

    if ($pct -lt $progressAnalysis.Minimum) { $pct = $progressAnalysis.Minimum }
    if ($pct -gt $progressAnalysis.Maximum) { $pct = $progressAnalysis.Maximum }

    $progressAnalysis.Value = $pct
    $script:spinIdx = ($script:spinIdx + 1) % $script:spinFrames.Count
    $lblAnalysisState.Text = ("Compute analysis{0}  {1}s / {2}s" -f $script:spinFrames[$script:spinIdx], $elapsedSec, $timeoutSec)

    if (($elapsedSec -gt $timeoutSec) -and (-not $script:computeSoftTimeoutWarned)) {
        $script:computeSoftTimeoutWarned = $true
        Append-Status ("Compute analysis exceeded expected time ({0}s). No forced stop applied; you can cancel manually." -f $timeoutSec)
        $lblAnalysisState.Text = ("Compute analysis slower than expected ({0}s > {1}s)." -f $elapsedSec, $timeoutSec)
    }
}

function Update-QuickCleanupProgress {
    if (-not $script:quickCleanupStartedAt) {
        return
    }

    $elapsedSec = [math]::Round(((Get-Date) - $script:quickCleanupStartedAt).TotalSeconds, 0)
    $timeoutSec = [math]::Max(1, $script:quickCleanupTimeoutSec)
    $pct = [math]::Min(95, [int](($elapsedSec / $timeoutSec) * 100))

    if ($pct -lt $progressAnalysis.Minimum) { $pct = $progressAnalysis.Minimum }
    if ($pct -gt $progressAnalysis.Maximum) { $pct = $progressAnalysis.Maximum }

    $progressAnalysis.Value = $pct
    $script:spinIdx = ($script:spinIdx + 1) % $script:spinFrames.Count
    $lblAnalysisState.Text = ("Quick clean{0}  {1}s / {2}s" -f $script:spinFrames[$script:spinIdx], $elapsedSec, $timeoutSec)

    if (($elapsedSec -gt $timeoutSec) -and (-not $script:quickCleanupSoftTimeoutWarned)) {
        $script:quickCleanupSoftTimeoutWarned = $true
        Append-Status ("Quick cleanup exceeded expected time ({0}s). No forced stop applied; you can cancel manually." -f $timeoutSec)
        $lblAnalysisState.Text = ("Quick cleanup slower than expected ({0}s > {1}s)." -f $elapsedSec, $timeoutSec)
    }
}

function Stop-GarbageAnalysis {
    param([string]$Reason)

    if ($script:analysisProcess -and (-not $script:analysisProcess.HasExited)) {
        try {
            Stop-Process -Id $script:analysisProcess.Id -Force -ErrorAction Stop
            Append-Status ("Analyzer stopped. Reason: {0}" -f $Reason)
        } catch {
            Append-Status ("Unable to stop analyzer cleanly: {0}" -f $_.Exception.Message)
        }
    }

    $analysisTimer.Stop()
    $script:analysisProcess = $null
    $script:analysisStartedAt = $null
    $script:analysisTimeoutSec = 0
    $script:analysisSoftTimeoutWarned = $false
    Set-AnalysisUiState -IsBusy:$false -StateText "Analyzer idle"
}

function Stop-CleanupOperation {
    param([string]$Reason)

    if ($script:cleanupProcess -and (-not $script:cleanupProcess.HasExited)) {
        try {
            Stop-Process -Id $script:cleanupProcess.Id -Force -ErrorAction Stop
            Append-Status ("Cleanup stopped. Reason: {0}" -f $Reason)
        } catch {
            Append-Status ("Unable to stop cleanup cleanly: {0}" -f $_.Exception.Message)
        }
    }

    $cleanupTimer.Stop()
    $script:cleanupProcess = $null
    $script:cleanupStartedAt = $null
    $script:cleanupTimeoutSec = 0
    $script:cleanupSoftTimeoutWarned = $false
    $script:cleanupRunAnalyzeAfter = $false
    Set-AnalysisUiState -IsBusy:$false -StateText "Cleanup idle"
}

function Stop-ComputeAnalysis {
    param([string]$Reason)

    if ($script:computeProcess -and (-not $script:computeProcess.HasExited)) {
        try {
            Stop-Process -Id $script:computeProcess.Id -Force -ErrorAction Stop
            Append-Status ("Compute analysis stopped. Reason: {0}" -f $Reason)
        } catch {
            Append-Status ("Unable to stop compute analysis cleanly: {0}" -f $_.Exception.Message)
        }
    }

    $computeTimer.Stop()
    $script:computeProcess = $null
    $script:computeStartedAt = $null
    $script:computeSoftTimeoutWarned = $false
    Set-AnalysisUiState -IsBusy:$false -StateText "Compute analyzer idle"
}

function Stop-QuickCleanupOperation {
    param([string]$Reason)

    if ($script:quickCleanupProcess -and (-not $script:quickCleanupProcess.HasExited)) {
        try {
            Stop-Process -Id $script:quickCleanupProcess.Id -Force -ErrorAction Stop
            Append-Status ("Quick cleanup stopped. Reason: {0}" -f $Reason)
        } catch {
            Append-Status ("Unable to stop quick cleanup cleanly: {0}" -f $_.Exception.Message)
        }
    }

    $quickCleanupTimer.Stop()
    $script:quickCleanupProcess = $null
    $script:quickCleanupStartedAt = $null
    $script:quickCleanupSoftTimeoutWarned = $false
    Set-AnalysisUiState -IsBusy:$false -StateText "Quick cleanup idle"
}

function Poll-GarbageAnalysis {
    if (-not $script:analysisProcess) {
        return
    }

    if (-not $script:analysisProcess.HasExited) {
        Update-AnalysisProgress
        return
    }

    $analysisTimer.Stop()
    $durationSec = 0
    if ($script:analysisStartedAt) {
        $durationSec = [math]::Round(((Get-Date) - $script:analysisStartedAt).TotalSeconds, 1)
    }

    $analysisExitCode = Get-ProcessExitCodeSafe -Process $script:analysisProcess
    if ($analysisExitCode -ne 0) {
        $errTail = Get-WorkerErrorTail -ErrorPath $script:analysisStdErr
        if ($errTail) {
            Append-Status ("Analyzer process ended with exit code {0}. Error: {1}" -f $analysisExitCode, $errTail)
        } else {
            Append-Status ("Analyzer process ended with exit code {0}." -f $analysisExitCode)
        }
        $script:analysisProcess = $null
        $script:analysisStartedAt = $null
        $script:analysisTimeoutSec = 0
        $script:analysisSoftTimeoutWarned = $false
        Set-AnalysisUiState -IsBusy:$false -StateText "Analyzer idle"
        return
    }

    if (Wait-ForOutputFile -Path $script:analysisCsv -TimeoutMs 4000) {
        $rows = Import-Csv -LiteralPath $script:analysisCsv -ErrorAction SilentlyContinue
        if ($rows) {
            Populate-Explorer -Rows @($rows)
            Append-Status ("Explorer updated with {0} ranked paths in {1}s." -f @($rows).Count, $durationSec)
            Show-Toast -Title "Scan Complete" -Body ("Found $(@($rows).Count) hotspot paths in ${durationSec}s") -Level "Success"
            $progressAnalysis.Value = 100
            $lblAnalysisState.Text = ("Analyzer completed in {0}s." -f $durationSec)
        } else {
            Populate-Explorer -Rows @()
            Append-Status ("Analyzer completed in {0}s but returned no rows." -f $durationSec)
            $lblAnalysisState.Text = ("Analyzer completed in {0}s with no rows." -f $durationSec)
        }
    } else {
        Populate-Explorer -Rows @()
        Append-Status ("Analyzer completed in {0}s but output CSV was not found." -f $durationSec)
        $lblAnalysisState.Text = ("Analyzer completed in {0}s but output CSV missing." -f $durationSec)
    }

    $script:analysisProcess = $null
    $script:analysisStartedAt = $null
    $script:analysisTimeoutSec = 0
    $script:analysisSoftTimeoutWarned = $false
    Set-AnalysisUiState -IsBusy:$false -StateText $lblAnalysisState.Text
}

function Poll-CleanupOperation {
    if (-not $script:cleanupProcess) {
        return
    }

    if (-not $script:cleanupProcess.HasExited) {
        Update-CleanupProgress
        return
    }

    $cleanupTimer.Stop()
    $durationSec = 0
    if ($script:cleanupStartedAt) {
        $durationSec = [math]::Round(((Get-Date) - $script:cleanupStartedAt).TotalSeconds, 1)
    }

    $cleanupExitCode = Get-ProcessExitCodeSafe -Process $script:cleanupProcess
    if ($cleanupExitCode -ne 0) {
        $errTail = Get-WorkerErrorTail -ErrorPath $script:cleanupStdErr
        if ($errTail) {
            Append-Status ("Cleanup process ended with exit code {0}. Error: {1}" -f $cleanupExitCode, $errTail)
        } else {
            Append-Status ("Cleanup process ended with exit code {0}." -f $cleanupExitCode)
        }
        $script:cleanupProcess = $null
        $script:cleanupStartedAt = $null
        $script:cleanupTimeoutSec = 0
        $script:cleanupSoftTimeoutWarned = $false
        $script:cleanupRunAnalyzeAfter = $false
        Set-AnalysisUiState -IsBusy:$false -StateText "Cleanup idle"
        return
    }

    if (Wait-ForOutputFile -Path $script:cleanupJson -TimeoutMs 4000) {
        try {
            $cleanupResult = Get-Content -LiteralPath $script:cleanupJson -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $cleanupSummary = "Cleanup completed in {0}s: Mode={1} CandidateFiles={2} CandidateGB={3} DeletedFiles={4} DeletedGB={5}" -f 
                $durationSec,
                [string]$cleanupResult.Mode,
                [int]$cleanupResult.CandidateFiles,
                [decimal]$cleanupResult.CandidateGB,
                [int]$cleanupResult.DeletedFiles,
                [decimal]$cleanupResult.DeletedGB
            Append-Status $cleanupSummary
            Show-Toast -Title "Cleanup Done" -Body ("Mode=$([string]$cleanupResult.Mode)  Deleted $([int]$cleanupResult.DeletedFiles) files ($([decimal]$cleanupResult.DeletedGB) GB)") -Level "Success"
        } catch {
            Append-Status ("Cleanup completed in {0}s but result parse failed: {1}" -f $durationSec, $_.Exception.Message)
        }
    } else {
        Append-Status ("Cleanup completed in {0}s but output JSON was not found." -f $durationSec)
    }

    Refresh-Drives
    $progressAnalysis.Value = 100
    $lblAnalysisState.Text = ("Cleanup completed in {0}s." -f $durationSec)

    $rerunAnalyze = $script:cleanupRunAnalyzeAfter
    $script:cleanupProcess = $null
    $script:cleanupStartedAt = $null
    $script:cleanupTimeoutSec = 0
    $script:cleanupSoftTimeoutWarned = $false
    $script:cleanupRunAnalyzeAfter = $false
    Set-AnalysisUiState -IsBusy:$false -StateText $lblAnalysisState.Text

    if ($rerunAnalyze) {
        Run-GarbageAnalysis
    }
}

function Poll-ComputeAnalysis {
    if (-not $script:computeProcess) {
        return
    }

    if (-not $script:computeProcess.HasExited) {
        Update-ComputeProgress
        return
    }

    $computeTimer.Stop()
    $durationSec = 0
    if ($script:computeStartedAt) {
        $durationSec = [math]::Round(((Get-Date) - $script:computeStartedAt).TotalSeconds, 1)
    }

    $computeExitCode = Get-ProcessExitCodeSafe -Process $script:computeProcess
    if ($computeExitCode -ne 0) {
        $errTail = Get-WorkerErrorTail -ErrorPath $script:computeStdErr
        if ($errTail) {
            Append-Status ("Compute analysis process ended with exit code {0}. Error: {1}" -f $computeExitCode, $errTail)
        } else {
            Append-Status ("Compute analysis process ended with exit code {0}." -f $computeExitCode)
        }
        $script:computeProcess = $null
        $script:computeStartedAt = $null
        $script:computeSoftTimeoutWarned = $false
        Set-AnalysisUiState -IsBusy:$false -StateText "Compute analyzer idle"
        return
    }

    if (Wait-ForOutputFile -Path $script:computeJson -TimeoutMs 4000) {
        try {
            $computeResult = Get-Content -LiteralPath $script:computeJson -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $topRows = @($computeResult.TopProcesses)
            Append-Status ("Compute analysis completed in {0}s. Observed={1} Top={2}" -f $durationSec, [int]$computeResult.TotalProcessesObserved, $topRows.Count)
            Show-Toast -Title "Compute Done" -Body ("Observed $([int]$computeResult.TotalProcessesObserved) processes in ${durationSec}s") -Level "Success"

            foreach ($proc in ($topRows | Select-Object -First 5)) {
                $computeSummary = "Compute Top PID={0} Name={1} Score={2} CPU={3}% RAM={4}MB IO={5}MB/s Pressure={6} Action={7}" -f 
                    [int]$proc.PID,
                    [string]$proc.ProcessName,
                    [decimal]$proc.Score,
                    [decimal]$proc.CpuPercent,
                    [decimal]$proc.WorkingSetMB,
                    [decimal]$proc.IoMBps,
                    [string]$proc.DominantPressure,
                    [string]$proc.Recommendation
                Append-Status $computeSummary
            }
        } catch {
            Append-Status ("Compute analysis completed in {0}s but result parse failed: {1}" -f $durationSec, $_.Exception.Message)
        }
    } else {
        Append-Status ("Compute analysis completed in {0}s but output JSON was not found." -f $durationSec)
    }

    $progressAnalysis.Value = 100
    $lblAnalysisState.Text = ("Compute analysis completed in {0}s." -f $durationSec)
    $script:computeProcess = $null
    $script:computeStartedAt = $null
    $script:computeSoftTimeoutWarned = $false
    Set-AnalysisUiState -IsBusy:$false -StateText $lblAnalysisState.Text
}

function Poll-QuickCleanup {
    if (-not $script:quickCleanupProcess) {
        return
    }

    if (-not $script:quickCleanupProcess.HasExited) {
        Update-QuickCleanupProgress
        return
    }

    $quickCleanupTimer.Stop()
    $durationSec = 0
    if ($script:quickCleanupStartedAt) {
        $durationSec = [math]::Round(((Get-Date) - $script:quickCleanupStartedAt).TotalSeconds, 1)
    }

    $quickExitCode = Get-ProcessExitCodeSafe -Process $script:quickCleanupProcess
    if ($quickExitCode -ne 0) {
        $errTail = Get-WorkerErrorTail -ErrorPath $script:quickCleanupStdErr
        if ($errTail) {
            Append-Status ("Quick cleanup process ended with exit code {0}. Error: {1}" -f $quickExitCode, $errTail)
        } else {
            Append-Status ("Quick cleanup process ended with exit code {0}." -f $quickExitCode)
        }
        $script:quickCleanupProcess = $null
        $script:quickCleanupStartedAt = $null
        $script:quickCleanupSoftTimeoutWarned = $false
        Set-AnalysisUiState -IsBusy:$false -StateText "Quick cleanup idle"
        return
    }

    if (Wait-ForOutputFile -Path $script:quickCleanupJson -TimeoutMs 4000) {
        try {
            $quickResult = Get-Content -LiteralPath $script:quickCleanupJson -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $quickSummary = "Quick cleanup completed in {0}s: Mode={1} CandidateFiles={2} CandidateGB={3} DeletedFiles={4} DeletedGB={5}" -f 
                $durationSec,
                [string]$quickResult.Mode,
                [int]$quickResult.CandidateFiles,
                [decimal]$quickResult.CandidateGB,
                [int]$quickResult.DeletedFiles,
                [decimal]$quickResult.DeletedGB
            Append-Status $quickSummary
            Show-Toast -Title "Quick Clean Done" -Body ("Deleted $([int]$quickResult.DeletedFiles) files ($([decimal]$quickResult.DeletedGB) GB) in ${durationSec}s") -Level "Success"
        } catch {
            Append-Status ("Quick cleanup completed in {0}s but result parse failed: {1}" -f $durationSec, $_.Exception.Message)
        }
    } else {
        Append-Status ("Quick cleanup completed in {0}s but output JSON was not found." -f $durationSec)
    }

    Refresh-Drives
    $progressAnalysis.Value = 100
    $lblAnalysisState.Text = ("Quick cleanup completed in {0}s." -f $durationSec)
    $script:quickCleanupProcess = $null
    $script:quickCleanupStartedAt = $null
    $script:quickCleanupSoftTimeoutWarned = $false
    Set-AnalysisUiState -IsBusy:$false -StateText $lblAnalysisState.Text
}

function Update-HealthAuditProgress {
    if (-not $script:healthAuditStartedAt) { return }
    $elapsedSec = [math]::Round(((Get-Date) - $script:healthAuditStartedAt).TotalSeconds, 0)
    $timeoutSec = [math]::Max(1, $script:healthAuditTimeoutSec)
    $pct = [math]::Min(95, [int](($elapsedSec / $timeoutSec) * 100))
    if ($pct -lt $progressAnalysis.Minimum) { $pct = $progressAnalysis.Minimum }
    if ($pct -gt $progressAnalysis.Maximum) { $pct = $progressAnalysis.Maximum }
    $progressAnalysis.Value = $pct
    $script:spinIdx = ($script:spinIdx + 1) % $script:spinFrames.Count
    $lblAnalysisState.Text = ("Health Audit{0}  {1}s / {2}s" -f $script:spinFrames[$script:spinIdx], $elapsedSec, $timeoutSec)
    if (($elapsedSec -gt $timeoutSec) -and (-not $script:healthAuditSoftTimeoutWarned)) {
        $script:healthAuditSoftTimeoutWarned = $true
        Append-Status ("Health Audit exceeded expected time ({0}s). No forced stop; cancel manually if needed." -f $timeoutSec)
    }
}

function Stop-HealthAudit {
    param([string]$Reason)
    if ($script:healthAuditProcess -and (-not $script:healthAuditProcess.HasExited)) {
        try {
            Stop-Process -Id $script:healthAuditProcess.Id -Force -ErrorAction Stop
            Append-Status ("Health Audit stopped. Reason: {0}" -f $Reason)
        } catch {
            Append-Status ("Unable to stop Health Audit cleanly: {0}" -f $_.Exception.Message)
        }
    }
    $healthAuditTimer.Stop()
    $script:healthAuditProcess = $null
    $script:healthAuditStartedAt = $null
    $script:healthAuditSoftTimeoutWarned = $false
    $script:healthAuditApplyAfter = $false
    Set-AnalysisUiState -IsBusy:$false -StateText "Health Audit idle"
}

function Poll-HealthAudit {
    if (-not $script:healthAuditProcess) { return }
    if (-not $script:healthAuditProcess.HasExited) {
        Update-HealthAuditProgress
        return
    }

    $healthAuditTimer.Stop()
    $durationSec = 0
    if ($script:healthAuditStartedAt) {
        $durationSec = [math]::Round(((Get-Date) - $script:healthAuditStartedAt).TotalSeconds, 1)
    }
    $exitCode = Get-ProcessExitCodeSafe -Process $script:healthAuditProcess
    if ($exitCode -ne 0) {
        $errTail = Get-WorkerErrorTail -ErrorPath $script:healthAuditStdErr
        if ($errTail) {
            Append-Status ("Health Audit ended with exit code {0}. Error: {1}" -f $exitCode, $errTail)
        } else {
            Append-Status ("Health Audit ended with exit code {0}." -f $exitCode)
        }
        $script:healthAuditProcess = $null
        $script:healthAuditStartedAt = $null
        $script:healthAuditSoftTimeoutWarned = $false
        $script:healthAuditApplyAfter = $false
        Set-AnalysisUiState -IsBusy:$false -StateText "Health Audit idle"
        return
    }

    $shouldApply = $script:healthAuditApplyAfter
    $applyLevel  = $script:healthAuditMaxLevel

    if (Wait-ForOutputFile -Path $script:healthAuditJson -TimeoutMs 4000) {
        try {
            $auditResult = Get-Content -LiteralPath $script:healthAuditJson -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $findingsCount = @($auditResult.Findings).Count
            $optimizedCount = @($auditResult.AlreadyOptimized).Count
            $critCount = [int]$auditResult.Summary.Critical
            $impCount  = [int]$auditResult.Summary.Important
            Append-Status ("Health Audit completed in {0}s. Findings={1} (Critical={2} Important={3}) AlreadyOK={4}" -f $durationSec, $findingsCount, $critCount, $impCount, $optimizedCount)
            Show-Toast -Title "Health Audit Done" -Body ("{0} findings, {1} already optimized ({2}s)" -f $findingsCount, $optimizedCount, $durationSec) -Level $(if ($critCount -gt 0) { "Warning" } else { "Success" })

            foreach ($f in $auditResult.Findings) {
                $solLevels = ($f.Solutions | ForEach-Object { $_.Level }) -join '/'
                Append-Status ("  [{0}] {1} — {2}  (Fixes: {3})" -f [string]$f.Severity, [string]$f.Id, [string]$f.Title, $solLevels)
            }
            if ($optimizedCount -gt 0) {
                Append-Status "  Already optimized: $(($auditResult.AlreadyOptimized | ForEach-Object { $_.Id }) -join ', ')"
            }
        } catch {
            Append-Status ("Health Audit completed in {0}s but parse failed: {1}" -f $durationSec, $_.Exception.Message)
            $shouldApply = $false
        }
    } else {
        Append-Status ("Health Audit completed in {0}s but output JSON was not found." -f $durationSec)
        $shouldApply = $false
    }

    $progressAnalysis.Value = 100
    $lblAnalysisState.Text = ("Health Audit completed in {0}s." -f $durationSec)
    $script:healthAuditProcess = $null
    $script:healthAuditStartedAt = $null
    $script:healthAuditSoftTimeoutWarned = $false
    $script:healthAuditApplyAfter = $false

    if ($shouldApply) {
        Append-Status ("Auto-applying fixes at level: {0}" -f $applyLevel)
        Run-HealthApply -MaxLevel $applyLevel
    } else {
        Set-AnalysisUiState -IsBusy:$false -StateText $lblAnalysisState.Text
    }
}

function Run-HealthAudit {
    param([switch]$ApplyAfter)

    if (-not (Test-Path -LiteralPath $script:healthAuditScript)) {
        Append-Status "Health audit script not found: $script:healthAuditScript"
        return
    }
    if (Test-AnyOperationRunning) {
        Append-Status "Another operation is already running. Wait for completion."
        return
    }
    try {
        Remove-IfExists -Path $script:healthAuditJson
        Remove-IfExists -Path $script:healthAuditStdOut
        Remove-IfExists -Path $script:healthAuditStdErr

        $args = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $script:healthAuditScript,
            "-OutputJson", $script:healthAuditJson
        )

        $script:healthAuditStartedAt = Get-Date
        $script:healthAuditSoftTimeoutWarned = $false
        $script:healthAuditApplyAfter = [bool]$ApplyAfter
        $script:healthAuditMaxLevel = [string]$cmbFixLevel.SelectedItem
        $script:healthAuditProcess = Start-Process -FilePath $script:psHost -ArgumentList $args -WindowStyle Hidden -RedirectStandardOutput $script:healthAuditStdOut -RedirectStandardError $script:healthAuditStdErr -PassThru
        $progressAnalysis.Value = 1
        Set-AnalysisUiState -IsBusy:$true -StateText ("Health Audit starting (target {0}s)..." -f $script:healthAuditTimeoutSec)
        $healthAuditTimer.Start()
        Append-Status "Health Audit started in background."
    } catch {
        Append-Status ("Health Audit error: {0}" -f $_.Exception.Message)
        $script:healthAuditProcess = $null
        $script:healthAuditStartedAt = $null
        $script:healthAuditSoftTimeoutWarned = $false
        $script:healthAuditApplyAfter = $false
        Set-AnalysisUiState -IsBusy:$false -StateText "Health Audit idle"
    }
}

function Run-HealthApply {
    param([string]$MaxLevel = 'Safe')

    if (-not (Test-Path -LiteralPath $script:applyFixesScript)) {
        Append-Status "Apply fixes script not found: $script:applyFixesScript"
        Set-AnalysisUiState -IsBusy:$false -StateText "Health Audit idle"
        return
    }
    if (-not (Test-Path -LiteralPath $script:healthAuditJson)) {
        Append-Status "Health audit JSON not found. Run Health Audit first."
        Set-AnalysisUiState -IsBusy:$false -StateText "Health Audit idle"
        return
    }
    try {
        Remove-IfExists -Path $script:healthApplyJson
        $args = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $script:applyFixesScript,
            "-InputJson", $script:healthAuditJson,
            "-OutputJson", $script:healthApplyJson,
            "-MaxLevel", $MaxLevel
        )
        $script:healthAuditStartedAt = Get-Date
        $script:healthAuditSoftTimeoutWarned = $false
        $script:healthAuditApplyAfter = $false
        $script:healthAuditProcess = Start-Process -FilePath $script:psHost -ArgumentList $args -WindowStyle Hidden -RedirectStandardOutput $script:healthAuditStdOut -RedirectStandardError $script:healthAuditStdErr -PassThru
        $progressAnalysis.Value = 1
        Set-AnalysisUiState -IsBusy:$true -StateText ("Applying {0} fixes..." -f $MaxLevel)
        $healthApplyTimer.Start()
        Append-Status ("Applying {0}-level fixes in background." -f $MaxLevel)
    } catch {
        Append-Status ("Apply fixes error: {0}" -f $_.Exception.Message)
        $script:healthAuditProcess = $null
        $script:healthAuditStartedAt = $null
        $script:healthAuditSoftTimeoutWarned = $false
        Set-AnalysisUiState -IsBusy:$false -StateText "Health Audit idle"
    }
}

function Poll-HealthApply {
    if (-not $script:healthAuditProcess) { return }
    if (-not $script:healthAuditProcess.HasExited) {
        Update-HealthAuditProgress
        return
    }
    $healthApplyTimer.Stop()
    $durationSec = 0
    if ($script:healthAuditStartedAt) {
        $durationSec = [math]::Round(((Get-Date) - $script:healthAuditStartedAt).TotalSeconds, 1)
    }
    $exitCode = Get-ProcessExitCodeSafe -Process $script:healthAuditProcess
    if ($exitCode -ne 0) {
        $errTail = Get-WorkerErrorTail -ErrorPath $script:healthAuditStdErr
        Append-Status ("Apply fixes ended with exit code {0}. {1}" -f $exitCode, $errTail)
        $script:healthAuditProcess = $null
        $script:healthAuditStartedAt = $null
        $script:healthAuditSoftTimeoutWarned = $false
        Set-AnalysisUiState -IsBusy:$false -StateText "Apply fixes idle"
        return
    }
    if (Wait-ForOutputFile -Path $script:healthApplyJson -TimeoutMs 4000) {
        try {
            $applyResult = Get-Content -LiteralPath $script:healthApplyJson -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $applied = [int]$applyResult.Summary.Applied
            $failed  = [int]$applyResult.Summary.Failed
            $skipped = [int]$applyResult.Summary.Skipped
            Append-Status ("Fixes applied in {0}s: Applied={1} Failed={2} Skipped={3}" -f $durationSec, $applied, $failed, $skipped)
            Show-Toast -Title "Fixes Applied" -Body ("Applied={0} Failed={1} ({2}s)" -f $applied, $failed, $durationSec) -Level $(if ($failed -gt 0) { "Warning" } else { "Success" })
            foreach ($r in $applyResult.Results) {
                if ($r.Status -eq 'Applied') {
                    Append-Status ("  APPLIED [{0}] {1} — {2}" -f $r.Level, $r.FindingId, $r.Label)
                } elseif ($r.Status -eq 'Failed') {
                    Append-Status ("  FAILED [{0}] {1} — {2}: {3}" -f $r.Level, $r.FindingId, $r.Label, $r.Error)
                }
            }
        } catch {
            Append-Status ("Apply completed in {0}s but parse failed: {1}" -f $durationSec, $_.Exception.Message)
        }
    } else {
        Append-Status ("Apply completed in {0}s but output JSON was not found." -f $durationSec)
    }
    Refresh-Drives
    $progressAnalysis.Value = 100
    $script:healthAuditProcess = $null
    $script:healthAuditStartedAt = $null
    $script:healthAuditSoftTimeoutWarned = $false
    Set-AnalysisUiState -IsBusy:$false -StateText ("Fixes applied in {0}s." -f $durationSec)
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Deep Scan functions
# ═══════════════════════════════════════════════════════════════════════════════

function Get-DeepScanFilteredFindings {
    $result = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $script:deepScanFindings.Count; $i++) {
        $f = $script:deepScanFindings[$i]
        $include = switch ($script:deepScanFilter) {
            "Critical" { [string]$f.Severity -eq "Critical" }
            "Important+" { @("Critical", "Important") -contains [string]$f.Severity }
            "Critical+Important" { @("Critical", "Important") -contains [string]$f.Severity }
            default { $true }
        }
        if ($include) {
            $result.Add([pscustomobject]@{
                __SourceIndex     = $i
                Severity          = [string]$f.Severity
                Category          = [string]$f.Category
                Id                = [string]$f.Id
                Title             = [string]$f.Title
                CurrentValue      = [string]$f.CurrentValue
                RecommendedValue  = [string]$f.RecommendedValue
            })
        }
    }
    return @($result)
}

function Export-DeepScanReport {
    if ($script:deepScanFindings.Count -eq 0) {
        Append-Status "No Deep Scan data to export. Run Deep Scan first."
        return
    }

    $exportDir = Join-Path $script:hubRoot "logs\diagnostics"
    if (-not (Test-Path -LiteralPath $exportDir)) {
        New-Item -ItemType Directory -Path $exportDir -Force | Out-Null
    }

    $stamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
    $path = Join-Path $exportDir ("deepscan-report-{0}.txt" -f $stamp)

    $crit = @($script:deepScanFindings | Where-Object { [string]$_.Severity -eq "Critical" }).Count
    $imp  = @($script:deepScanFindings | Where-Object { [string]$_.Severity -eq "Important" }).Count
    $mod  = @($script:deepScanFindings | Where-Object { [string]$_.Severity -eq "Moderate" }).Count
    $inf  = @($script:deepScanFindings | Where-Object { [string]$_.Severity -eq "Info" }).Count

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(("Deep Scan Report - {0}" -f (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")))
    $lines.Add(("Filter: {0}" -f $script:deepScanFilter))
    $lines.Add(("Summary: Total={0} Critical={1} Important={2} Moderate={3} Info={4}" -f $script:deepScanFindings.Count, $crit, $imp, $mod, $inf))
    $lines.Add("")

    foreach ($f in $script:deepScanFindings) {
        $lines.Add(("[{0}] {1} - {2}" -f [string]$f.Severity, [string]$f.Id, [string]$f.Title))
        $lines.Add(("  Category: {0}" -f [string]$f.Category))
        $lines.Add(("  Current : {0}" -f [string]$f.CurrentValue))
        $lines.Add(("  Target  : {0}" -f [string]$f.RecommendedValue))
        $lines.Add(("  Impact  : {0}" -f [string]$f.Impact))
        $solIndex = 1
        foreach ($sol in $f.Solutions) {
            $lines.Add(("    {0}. [{1}] {2}" -f $solIndex, [string]$sol.Level, [string]$sol.Label))
            $solIndex++
        }
        $lines.Add("")
    }

    $lines | Out-File -LiteralPath $path -Encoding utf8 -Force
    Append-Status ("Deep Scan report exported: {0}" -f $path)
    Start-Process explorer.exe -ArgumentList $exportDir
}

function Populate-DeepScanFindings {
    param([object[]]$Findings)

    $listDeepFindings.Items.Clear()
    $listDeepFindings.BeginUpdate()
    foreach ($f in $Findings) {
        $item = New-Object System.Windows.Forms.ListViewItem([string]$f.Severity)
        [void]$item.SubItems.Add([string]$f.Category)
        [void]$item.SubItems.Add([string]$f.Id)
        [void]$item.SubItems.Add([string]$f.Title)
        [void]$item.SubItems.Add([string]$f.CurrentValue)
        [void]$item.SubItems.Add([string]$f.RecommendedValue)
        $item.Tag = [int]$f.__SourceIndex
        switch ([string]$f.Severity) {
            "Critical"  { $item.BackColor = $clrRowHigh;  $item.ForeColor = $clrTxtHigh  }
            "Important" { $item.BackColor = $clrRowAmber; $item.ForeColor = $clrTxtAmber }
            "Moderate"  { $item.BackColor = [System.Drawing.Color]::FromArgb(14,40,55); $item.ForeColor = $clrCyan }
            default     { $item.BackColor = $clrSurface;  $item.ForeColor = $clrMuted    }
        }
        [void]$listDeepFindings.Items.Add($item)
    }
    $listDeepFindings.EndUpdate()
    if ($listDeepFindings.Items.Count -eq 0) {
        $txtDeepFindingDetail.Text = "No findings for filter: $script:deepScanFilter"
        $listDeepSolutions.Items.Clear()
        $btnDeepApply.Enabled = $false
        $btnDeepApply.ForeColor = $clrMuted
        $lblDeepApplyState.Text = "No actionable rows under current filter"
    }
}

function Show-DeepFindingDetail {
    param([int]$Index)

    if ($Index -lt 0 -or $Index -ge $script:deepScanFindings.Count) {
        $txtDeepFindingDetail.Text = ""
        $listDeepSolutions.Items.Clear()
        $btnDeepApply.Enabled   = $false
        $btnDeepApply.ForeColor = $clrMuted
        $lblDeepApplyState.Text = "Select a finding"
        return
    }

    $f = $script:deepScanFindings[$Index]
    $lines = @(
        "[{0}]  {1}  —  {2}" -f $f.Severity, $f.Id, $f.Title,
        "Category : {0}" -f $f.Category,
        "Impact   : {0}" -f $f.Impact,
        "",
        [string]$f.Description,
        "",
        "Current  : {0}" -f $f.CurrentValue,
        "Target   : {0}" -f $f.RecommendedValue
    )
    $txtDeepFindingDetail.Text = $lines -join "`r`n"

    $listDeepSolutions.Items.Clear()
    $solIndex = 0
    foreach ($sol in $f.Solutions) {
        $si = New-Object System.Windows.Forms.ListViewItem([string]$sol.Level)
        [void]$si.SubItems.Add([string]$sol.Label)
        [void]$si.SubItems.Add([string]$sol.RiskNote)
        [void]$si.SubItems.Add($(if ($sol.Rollback) { [string]$sol.Rollback } else { "—" }))
        $si.Tag = $solIndex
        switch ([string]$sol.Level) {
            "Safe"       { $si.ForeColor = $clrGreen }
            "Moderate"   { $si.ForeColor = $clrAmber }
            "Aggressive" { $si.ForeColor = $clrRed   }
        }
        [void]$listDeepSolutions.Items.Add($si)
        $solIndex++
    }
    $btnDeepApply.Enabled   = $false
    $btnDeepApply.ForeColor = $clrMuted
    $lblDeepApplyState.Text = "Select a solution row to apply"
}

function Update-DeepScanProgress {
    if (-not $script:deepScanStartedAt) { return }
    $elapsedSec = [math]::Round(((Get-Date) - $script:deepScanStartedAt).TotalSeconds, 0)
    $script:spinIdx = ($script:spinIdx + 1) % $script:spinFrames.Count
    $lblDeepScanState.Text = ("Deep Scan{0}  {1}s / {2}s" -f $script:spinFrames[$script:spinIdx], $elapsedSec, $script:deepScanTimeoutSec)
    if (($elapsedSec -gt $script:deepScanTimeoutSec) -and (-not $script:deepScanSoftTimeoutWarned)) {
        $script:deepScanSoftTimeoutWarned = $true
        Append-Status ("Deep Scan exceeded expected time ({0}s). Cancel manually if needed." -f $script:deepScanTimeoutSec)
    }
}

function Stop-DeepScan {
    param([string]$Reason)

    if ($script:deepScanProcess -and (-not $script:deepScanProcess.HasExited)) {
        try {
            Stop-Process -Id $script:deepScanProcess.Id -Force -ErrorAction Stop
            Append-Status ("Deep Scan stopped. Reason: {0}" -f $Reason)
        } catch {
            Append-Status ("Unable to stop Deep Scan cleanly: {0}" -f $_.Exception.Message)
        }
    }
    $deepScanTimer.Stop()
    $script:deepScanProcess          = $null
    $script:deepScanStartedAt        = $null
    $script:deepScanSoftTimeoutWarned = $false
    $pnlDeepScanProgress.Visible     = $false
    $progressDeepScan.Style          = "Continuous"
    $progressDeepScan.Value          = 0
    Set-AnalysisUiState -IsBusy:$false -StateText "Deep Scan idle"
}

function Poll-DeepScan {
    if (-not $script:deepScanProcess) { return }
    if (-not $script:deepScanProcess.HasExited) {
        Update-DeepScanProgress
        return
    }

    $deepScanTimer.Stop()
    $durationSec = 0
    if ($script:deepScanStartedAt) {
        $durationSec = [math]::Round(((Get-Date) - $script:deepScanStartedAt).TotalSeconds, 1)
    }
    $exitCode = Get-ProcessExitCodeSafe -Process $script:deepScanProcess

    if ($exitCode -ne 0) {
        $errTail = Get-WorkerErrorTail -ErrorPath $script:deepScanStdErr
        Append-Status ("Deep Scan ended with exit code {0}. {1}" -f $exitCode, $errTail)
        $script:deepScanProcess = $null
        $script:deepScanStartedAt = $null
        $script:deepScanSoftTimeoutWarned = $false
        $pnlDeepScanProgress.Visible = $false
        $progressDeepScan.Style = "Continuous"
        $progressDeepScan.Value = 0
        $btnDeepScanCancel.Enabled   = $false
        $btnDeepScanCancel.ForeColor = $clrMuted
        Set-AnalysisUiState -IsBusy:$false -StateText "Deep Scan idle"
        return
    }

    if (Wait-ForOutputFile -Path $script:deepScanJson -TimeoutMs 4000) {
        try {
            $auditResult = Get-Content -LiteralPath $script:deepScanJson -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $script:deepScanFindings = @($auditResult.Findings)
            $script:deepScanLastSummary = $auditResult.Summary
            $alreadyOK = @($auditResult.AlreadyOptimized).Count
            $critCount = [int]$auditResult.Summary.Critical
            $impCount  = [int]$auditResult.Summary.Important
            Populate-DeepScanFindings -Findings (Get-DeepScanFilteredFindings)
            $stateMsg = ("Scan complete — {0} findings  ({1} critical  {2} important  {3} already OK)" -f $script:deepScanFindings.Count, $critCount, $impCount, $alreadyOK)
            $lblDeepScanState.Text = $stateMsg
            Append-Status ("Deep Scan completed in {0}s. Findings={1} (Critical={2} Important={3}) AlreadyOK={4}" -f $durationSec, $script:deepScanFindings.Count, $critCount, $impCount, $alreadyOK)
            Show-Toast -Title "Deep Scan Done" -Body ("{0} findings in {1}s" -f $script:deepScanFindings.Count, $durationSec) -Level $(if ($critCount -gt 0) { "Warning" } else { "Success" })
            # Auto-select first finding
            if ($script:deepScanFindings.Count -gt 0) {
                $listDeepFindings.Items[0].Selected = $true
                $listDeepFindings.Items[0].Focused  = $true
            }
        } catch {
            Append-Status ("Deep Scan completed in {0}s but parse failed: {1}" -f $durationSec, $_.Exception.Message)
            $lblDeepScanState.Text = "Deep Scan parse error — see Logs tab."
        }
    } else {
        Append-Status ("Deep Scan completed in {0}s but output JSON not found." -f $durationSec)
        $lblDeepScanState.Text = "Deep Scan output missing."
    }

    $pnlDeepScanProgress.Visible = $false
    $progressDeepScan.Style = "Continuous"
    $progressDeepScan.Value = 0
    $script:deepScanProcess = $null
    $script:deepScanStartedAt = $null
    $script:deepScanSoftTimeoutWarned = $false
    $btnDeepScanCancel.Enabled   = $false
    $btnDeepScanCancel.ForeColor = $clrMuted
    Set-AnalysisUiState -IsBusy:$false -StateText $lblDeepScanState.Text
}

function Run-DeepScan {
    if (-not (Test-Path -LiteralPath $script:healthAuditScript)) {
        Append-Status "Health audit script not found: $script:healthAuditScript"
        return
    }
    if (Test-AnyOperationRunning) {
        Append-Status "Another operation is already running. Wait for completion."
        return
    }
    try {
        Remove-IfExists -Path $script:deepScanJson
        Remove-IfExists -Path $script:deepScanStdOut
        Remove-IfExists -Path $script:deepScanStdErr
        $listDeepFindings.Items.Clear()
        $txtDeepFindingDetail.Text = ""
        $listDeepSolutions.Items.Clear()
        $script:deepScanLastSummary = $null
        $btnDeepApply.Enabled   = $false
        $btnDeepApply.ForeColor = $clrMuted
        $lblDeepApplyState.Text = "Running scan..."

        $args = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $script:healthAuditScript,
            "-OutputJson", $script:deepScanJson
        )
        $script:deepScanStartedAt        = Get-Date
        $script:deepScanSoftTimeoutWarned = $false
        $script:deepScanProcess = Start-Process -FilePath $script:psHost -ArgumentList $args `
            -WindowStyle Hidden `
            -RedirectStandardOutput $script:deepScanStdOut `
            -RedirectStandardError  $script:deepScanStdErr `
            -PassThru

        $progressDeepScan.Style                 = "Marquee"
        $progressDeepScan.MarqueeAnimationSpeed = 28
        $progressDeepScan.Value                 = 0
        $pnlDeepScanProgress.Visible            = $true
        $lblDeepScanState.Text = ("Deep Scan starting (target {0}s)..." -f $script:deepScanTimeoutSec)
        $btnDeepScanCancel.Enabled   = $true
        $btnDeepScanCancel.ForeColor = $clrRed
        $deepScanTimer.Start()
        Set-AnalysisUiState -IsBusy:$true -StateText "Deep Scan running..."
        Append-Status "Deep Scan started in background."
    } catch {
        Append-Status ("Deep Scan error: {0}" -f $_.Exception.Message)
        $script:deepScanProcess = $null
        $script:deepScanStartedAt = $null
        $script:deepScanSoftTimeoutWarned = $false
        $pnlDeepScanProgress.Visible = $false
        $btnDeepScanCancel.Enabled   = $false
        $btnDeepScanCancel.ForeColor = $clrMuted
        Set-AnalysisUiState -IsBusy:$false -StateText "Deep Scan idle"
    }
}

function Apply-DeepFix {
    param([string]$FindingId, [string]$SolutionLevel)

    if (-not (Test-Path -LiteralPath $script:applyFixesScript)) {
        Append-Status "Apply fixes script not found: $script:applyFixesScript"
        return
    }
    if (-not (Test-Path -LiteralPath $script:deepScanJson)) {
        Append-Status "Deep Scan JSON not found. Run Deep Scan first."
        return
    }
    if (Test-AnyOperationRunning) {
        Append-Status "Another operation is already running. Wait for completion."
        return
    }
    try {
        Remove-IfExists -Path $script:deepScanApplyJson
        $args = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $script:applyFixesScript,
            "-InputJson",    $script:deepScanJson,
            "-OutputJson",   $script:deepScanApplyJson,
            "-MaxLevel",     $SolutionLevel,
            "-FindingIds",   $FindingId
        )
        $script:deepScanApplyStartedAt = Get-Date
        $script:deepScanApplyFindingId = $FindingId
        $script:deepScanApplyLevel     = $SolutionLevel
        $script:deepScanApplyProcess = Start-Process -FilePath $script:psHost -ArgumentList $args `
            -WindowStyle Hidden `
            -RedirectStandardOutput $script:deepScanStdOut `
            -RedirectStandardError  $script:deepScanStdErr `
            -PassThru

        $btnDeepApply.Enabled   = $false
        $btnDeepApply.ForeColor = $clrMuted
        $lblDeepApplyState.Text = ("Applying [{0}] {1}..." -f $SolutionLevel, $FindingId)
        $deepScanApplyTimer.Start()
        Set-AnalysisUiState -IsBusy:$true -StateText ("Applying {0} fix for {1}..." -f $SolutionLevel, $FindingId)
        Append-Status ("Applying [{0}] fix for finding: {1}" -f $SolutionLevel, $FindingId)
    } catch {
        Append-Status ("Apply fix error: {0}" -f $_.Exception.Message)
        $script:deepScanApplyProcess = $null
        $script:deepScanApplyStartedAt = $null
        $lblDeepApplyState.Text = "Apply failed — see status log."
        Set-AnalysisUiState -IsBusy:$false -StateText "Deep Scan idle"
    }
}

function Poll-DeepScanApply {
    if (-not $script:deepScanApplyProcess) { return }
    if (-not $script:deepScanApplyProcess.HasExited) {
        $elapsed = [math]::Round(((Get-Date) - $script:deepScanApplyStartedAt).TotalSeconds, 0)
        $script:spinIdx = ($script:spinIdx + 1) % $script:spinFrames.Count
        $lblDeepApplyState.Text = ("Applying{0}  {1}s" -f $script:spinFrames[$script:spinIdx], $elapsed)
        return
    }

    $deepScanApplyTimer.Stop()
    $durationSec = 0
    if ($script:deepScanApplyStartedAt) {
        $durationSec = [math]::Round(((Get-Date) - $script:deepScanApplyStartedAt).TotalSeconds, 1)
    }
    $exitCode = Get-ProcessExitCodeSafe -Process $script:deepScanApplyProcess
    if ($exitCode -ne 0) {
        $errTail = Get-WorkerErrorTail -ErrorPath $script:deepScanStdErr
        Append-Status ("Apply fix ended with exit code {0}. {1}" -f $exitCode, $errTail)
        $lblDeepApplyState.Text = "Apply failed — see Logs tab."
        $script:deepScanApplyProcess = $null
        $script:deepScanApplyStartedAt = $null
        Set-AnalysisUiState -IsBusy:$false -StateText "Deep Scan idle"
        return
    }

    if (Wait-ForOutputFile -Path $script:deepScanApplyJson -TimeoutMs 4000) {
        try {
            $applyResult = Get-Content -LiteralPath $script:deepScanApplyJson -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $applied = [int]$applyResult.Summary.Applied
            $failed  = [int]$applyResult.Summary.Failed
            $msg = ("Fix applied in {0}s: Applied={1} Failed={2}" -f $durationSec, $applied, $failed)
            Append-Status $msg
            $lblDeepApplyState.Text = $msg
            Show-Toast -Title "Fix Applied" -Body ("{0} [{1}]  Applied={2}  Failed={3}" -f $script:deepScanApplyFindingId, $script:deepScanApplyLevel, $applied, $failed) -Level $(if ($failed -gt 0) { "Warning" } else { "Success" })
            # Mark the finding row visually as applied
            foreach ($item in $listDeepFindings.Items) {
                if ($item.SubItems[2].Text -eq $script:deepScanApplyFindingId) {
                    $item.SubItems[3].Text = "[APPLIED] " + $item.SubItems[3].Text
                    $item.ForeColor = $clrGreen
                    break
                }
            }
        } catch {
            Append-Status ("Apply completed in {0}s but parse failed: {1}" -f $durationSec, $_.Exception.Message)
            $lblDeepApplyState.Text = "Apply parse error."
        }
    } else {
        Append-Status ("Apply completed in {0}s but output JSON not found." -f $durationSec)
        $lblDeepApplyState.Text = "Apply output missing."
    }

    $script:deepScanApplyProcess = $null
    $script:deepScanApplyStartedAt = $null
    Set-AnalysisUiState -IsBusy:$false -StateText ("Fix applied in {0}s." -f $durationSec)
}

function Run-GarbageAnalysis {
    if (-not (Test-Path -LiteralPath $script:analyzerScript)) {
        Append-Status "Analyzer script not found: $script:analyzerScript"
        return
    }

    if (Test-AnyOperationRunning) {
        Append-Status "Another operation is already running. Wait for completion."
        return
    }

    $depth = [string]$cmbDepth.SelectedItem
    $auditLevel = [string]$cmbAuditLevel.SelectedItem
    $cleanupMode = [string]$cmbCleanupMode.SelectedItem
    $top = [int]$numTop.Value

    try {
        Append-Status ("Analyzing garbage hotspots Depth={0} Audit={1} Mode={2} Top={3}" -f $depth, $auditLevel, $cleanupMode, $top)
        Remove-IfExists -Path $script:analysisCsv
        Remove-IfExists -Path $script:analysisStdOut
        Remove-IfExists -Path $script:analysisStdErr

        $args = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $script:analyzerScript,
            "-Drives", "C,D",
            "-Top", "$top",
            "-Depth", $depth,
            "-AuditLevel", $auditLevel,
            "-CleanupMode", $cleanupMode,
            "-OutputCsv", $script:analysisCsv
        )

        $script:analysisStartedAt = Get-Date
        $script:analysisTimeoutSec = Get-AnalysisTimeoutSec -Depth $depth
        $script:analysisSoftTimeoutWarned = $false
        $script:analysisProcess = Start-Process -FilePath $script:psHost -ArgumentList $args -WindowStyle Hidden -RedirectStandardOutput $script:analysisStdOut -RedirectStandardError $script:analysisStdErr -PassThru
        $progressAnalysis.Value = 1
        Set-AnalysisUiState -IsBusy:$true -StateText ("Analyzer starting (target {0}s)..." -f $script:analysisTimeoutSec)
        $analysisTimer.Start()
        Append-Status "Analyzer started in background. UI remains responsive."
    } catch {
        Append-Status ("Analyzer error: {0}" -f $_.Exception.Message)
        $script:analysisProcess = $null
        $script:analysisStartedAt = $null
        $script:analysisTimeoutSec = 0
        $script:analysisSoftTimeoutWarned = $false
        Set-AnalysisUiState -IsBusy:$false -StateText "Analyzer idle"
    }
}

function Run-Cleanup {
    param(
        [bool]$ExecuteNow,
        [bool]$RunAnalyzeAfter
    )

    if (-not (Test-Path -LiteralPath $script:cleanupScript)) {
        Append-Status "Cleanup script not found: $script:cleanupScript"
        return
    }

    if (Test-AnyOperationRunning) {
        Append-Status "Another operation is already running. Wait for completion."
        return
    }

    $depth = [string]$cmbDepth.SelectedItem
    $auditLevel = [string]$cmbAuditLevel.SelectedItem
    $cleanupMode = [string]$cmbCleanupMode.SelectedItem

    $args = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $script:cleanupScript,
        "-AuditDepth", $depth,
        "-AuditLevel", $auditLevel,
        "-CleanupMode", $cleanupMode,
        "-OutputJson", $script:cleanupJson
    )
    if ($ExecuteNow) {
        $args += "-Execute"
    }

    $action = if ($ExecuteNow) { "execute" } else { "audit" }
    Append-Status ("Running cleanup {0} with Depth={1}, Audit={2}, Mode={3}" -f $action, $depth, $auditLevel, $cleanupMode)
    try {
        Remove-IfExists -Path $script:cleanupJson
        Remove-IfExists -Path $script:cleanupStdOut
        Remove-IfExists -Path $script:cleanupStdErr

        $script:cleanupStartedAt = Get-Date
        $script:cleanupTimeoutSec = Get-CleanupTimeoutSec -Depth $depth -ExecuteNow:$ExecuteNow
        $script:cleanupSoftTimeoutWarned = $false
        $script:cleanupRunAnalyzeAfter = $RunAnalyzeAfter
        $script:cleanupProcess = Start-Process -FilePath $script:psHost -ArgumentList $args -WindowStyle Hidden -RedirectStandardOutput $script:cleanupStdOut -RedirectStandardError $script:cleanupStdErr -PassThru
        $progressAnalysis.Value = 1
        Set-AnalysisUiState -IsBusy:$true -StateText ("Cleanup starting (target {0}s)..." -f $script:cleanupTimeoutSec)
        $cleanupTimer.Start()
        Append-Status "Cleanup started in background. UI remains responsive."
    } catch {
        Append-Status ("Cleanup error: {0}" -f $_.Exception.Message)
        $script:cleanupProcess = $null
        $script:cleanupStartedAt = $null
        $script:cleanupTimeoutSec = 0
        $script:cleanupSoftTimeoutWarned = $false
        $script:cleanupRunAnalyzeAfter = $false
        Set-AnalysisUiState -IsBusy:$false -StateText "Cleanup idle"
    }
}

function Run-ComputeAnalysis {
    if (-not (Test-Path -LiteralPath $script:computeAnalyzerScript)) {
        Append-Status "Compute analyzer script not found: $script:computeAnalyzerScript"
        return
    }

    if (Test-AnyOperationRunning) {
        Append-Status "Another operation is already running. Wait for completion."
        return
    }

    try {
        Remove-IfExists -Path $script:computeJson
        Remove-IfExists -Path $script:computeStdOut
        Remove-IfExists -Path $script:computeStdErr

        $durationStr = "$($script:computeAnalyzeDurationSec)"
        $topStr = "$($script:computeAnalyzeTop)"
        $args = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $script:computeAnalyzerScript,
            "-DurationSec", $durationStr,
            "-Top", $topStr,
            "-OutputJson", $script:computeJson
        )

        $script:computeStartedAt = Get-Date
        $script:computeSoftTimeoutWarned = $false
        $script:computeProcess = Start-Process -FilePath $script:psHost -ArgumentList $args -WindowStyle Hidden -RedirectStandardOutput $script:computeStdOut -RedirectStandardError $script:computeStdErr -PassThru
        $progressAnalysis.Value = 1
        Set-AnalysisUiState -IsBusy:$true -StateText "Compute analysis starting (target 45s)..."
        $computeTimer.Start()
        Append-Status "Compute analysis started in background."
    } catch {
        Append-Status ("Compute analysis error: {0}" -f $_.Exception.Message)
        $script:computeProcess = $null
        $script:computeStartedAt = $null
        $script:computeSoftTimeoutWarned = $false
        Set-AnalysisUiState -IsBusy:$false -StateText "Compute analyzer idle"
    }
}

function Run-QuickCleanup {
    if (-not (Test-Path -LiteralPath $script:quickCleanupScript)) {
        Append-Status "Quick cleanup script not found: $script:quickCleanupScript"
        return
    }

    if (Test-AnyOperationRunning) {
        Append-Status "Another operation is already running. Wait for completion."
        return
    }

    try {
        Remove-IfExists -Path $script:quickCleanupJson
        Remove-IfExists -Path $script:quickCleanupStdOut
        Remove-IfExists -Path $script:quickCleanupStdErr

        $retDaysStr = "$($script:quickCleanupRetentionDays)"
        $maxFilesStr = "$($script:quickCleanupMaxFilesPerTarget)"
        $args = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $script:quickCleanupScript,
            "-Execute",
            "-RetentionDays", $retDaysStr,
            "-MaxFilesPerTarget", $maxFilesStr,
            "-OutputJson", $script:quickCleanupJson
        )

        $script:quickCleanupStartedAt = Get-Date
        $script:quickCleanupSoftTimeoutWarned = $false
        $script:quickCleanupProcess = Start-Process -FilePath $script:psHost -ArgumentList $args -WindowStyle Hidden -RedirectStandardOutput $script:quickCleanupStdOut -RedirectStandardError $script:quickCleanupStdErr -PassThru
        $progressAnalysis.Value = 1
        Set-AnalysisUiState -IsBusy:$true -StateText "Quick cleanup starting (target 120s)..."
        $quickCleanupTimer.Start()
        Append-Status "Quick cleanup started in background."
    } catch {
        Append-Status ("Quick cleanup error: {0}" -f $_.Exception.Message)
        $script:quickCleanupProcess = $null
        $script:quickCleanupStartedAt = $null
        $script:quickCleanupSoftTimeoutWarned = $false
        Set-AnalysisUiState -IsBusy:$false -StateText "Quick cleanup idle"
    }
}

$listExplorer.Add_DoubleClick({
    if ($listExplorer.SelectedItems.Count -eq 0) {
        return
    }

    $path = $listExplorer.SelectedItems[0].SubItems[3].Text
    if (Test-Path -LiteralPath $path) {
        Start-Process explorer.exe -ArgumentList $path
        Append-Status ("Opened: {0}" -f $path)
    }
})

$btnAnalyze.Add_Click({ Run-GarbageAnalysis })
$btnDiagnostics.Add_Click({ Open-DiagnosticsBundle })
$btnCancelAnalyze.Add_Click({
    if ($script:analysisProcess -and (-not $script:analysisProcess.HasExited)) {
        $confirm = [System.Windows.Forms.MessageBox]::Show("Cancel running analysis?", "Confirm", "YesNo", "Question")
        if ($confirm -eq "Yes") {
            Stop-GarbageAnalysis -Reason "Manual cancel requested by user."
        }
        return
    }

    if ($script:cleanupProcess -and (-not $script:cleanupProcess.HasExited)) {
        $confirm = [System.Windows.Forms.MessageBox]::Show("Cancel running cleanup?", "Confirm", "YesNo", "Question")
        if ($confirm -eq "Yes") {
            Stop-CleanupOperation -Reason "Manual cancel requested by user."
        }
        return
    }

    if ($script:computeProcess -and (-not $script:computeProcess.HasExited)) {
        $confirm = [System.Windows.Forms.MessageBox]::Show("Cancel running compute analysis?", "Confirm", "YesNo", "Question")
        if ($confirm -eq "Yes") {
            Stop-ComputeAnalysis -Reason "Manual cancel requested by user."
        }
        return
    }

    if ($script:quickCleanupProcess -and (-not $script:quickCleanupProcess.HasExited)) {
        $confirm = [System.Windows.Forms.MessageBox]::Show("Cancel running quick cleanup?", "Confirm", "YesNo", "Question")
        if ($confirm -eq "Yes") {
            Stop-QuickCleanupOperation -Reason "Manual cancel requested by user."
        }
    }

    if ($script:healthAuditProcess -and (-not $script:healthAuditProcess.HasExited)) {
        $confirm = [System.Windows.Forms.MessageBox]::Show("Cancel running Health Audit?", "Confirm", "YesNo", "Question")
        if ($confirm -eq "Yes") {
            Stop-HealthAudit -Reason "Manual cancel requested by user."
        }
    }
})
$btnAudit.Add_Click({ Run-Cleanup -ExecuteNow:$false -RunAnalyzeAfter:$false })
$btnExecute.Add_Click({
    $mode = [string]$cmbCleanupMode.SelectedItem
    $confirm = [System.Windows.Forms.MessageBox]::Show(("Execute {0} cleanup now?" -f $mode), "Confirm", "YesNo", "Warning")
    if ($confirm -eq "Yes") {
        Run-Cleanup -ExecuteNow:$true -RunAnalyzeAfter:$true
    }
})
$btnCompute.Add_Click({ Run-ComputeAnalysis })
$btnQuickClean.Add_Click({
    $confirm = [System.Windows.Forms.MessageBox]::Show("Run quick safe cleanup now?", "Confirm", "YesNo", "Question")
    if ($confirm -eq "Yes") {
        Run-QuickCleanup
    }
})
$btnHealthAudit.Add_Click({
    $level = [string]$cmbFixLevel.SelectedItem
    $msg = "Run Health Audit?`n`nAfter scan, fixes at '$level' level will be applied automatically."
    $confirm = [System.Windows.Forms.MessageBox]::Show($msg, "Health Audit", "YesNo", "Question")
    if ($confirm -eq "Yes") {
        Run-HealthAudit -ApplyAfter
    }
})
$btnReloadTasks.Add_Click({ Reload-Tasks })
$btnInstallTasks.Add_Click({
    $args = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $script:coreScript,
        "-InstallIfMissing",
        "-ApplyTasksCoreOnly",
        "-MonitorInstallerPath", $script:monitorInstaller,
        "-CleanupInstallerPath", $script:cleanupInstaller
    )
    try {
        Invoke-ChildPowerShell -Args $args | Out-Null
        Reload-Tasks
        Append-Status "Core tasks installation completed."
    } catch {
        Append-Status ("Core install error: {0}" -f $_.Exception.Message)
    }
})
$btnLoadLogs.Add_Click({
    $logMap = @{
        "Garbage Analyzer (stdout)" = $script:analysisStdOut
        "Garbage Analyzer (stderr)" = $script:analysisStdErr
        "Cleanup (stdout)"          = $script:cleanupStdOut
        "Cleanup (stderr)"          = $script:cleanupStdErr
        "Compute Analyzer (stdout)" = $script:computeStdOut
        "Compute Analyzer (stderr)" = $script:computeStdErr
        "Quick Cleanup (stdout)"    = $script:quickCleanupStdOut
        "Quick Cleanup (stderr)"    = $script:quickCleanupStdErr
        "Quick Cleanup (log)"       = (Join-Path $script:hubRoot "logs\quick-cleanup.log")
        "Storage Cleanup (log)"     = $script:defaultLog
        "Health Audit (stdout)"     = $script:healthAuditStdOut
        "Health Audit (stderr)"     = $script:healthAuditStdErr
    }
    $selected = [string]$cmbLogSource.SelectedItem
    $logPath = $logMap[$selected]
    if ($logPath -and (Test-Path -LiteralPath $logPath)) {
        $txtLogs.Text = (Get-Content -LiteralPath $logPath -Tail 200 -ErrorAction SilentlyContinue) -join "`r`n"
    } else {
        $txtLogs.Text = "Log file not found: $logPath"
    }
})
$btnOpenConfig.Add_Click({
    if (Test-Path -LiteralPath $script:configPath) {
        Start-Process notepad.exe -ArgumentList $script:configPath
    }
})

# ── Deep Scan event handlers ───────────────────────────────────────────────────
$btnDeepScanRun.Add_Click({ Run-DeepScan })

$btnDeepScanCancel.Add_Click({
    if ($script:deepScanProcess -and (-not $script:deepScanProcess.HasExited)) {
        $confirm = [System.Windows.Forms.MessageBox]::Show("Cancel the running Deep Scan?", "Confirm", "YesNo", "Question")
        if ($confirm -eq "Yes") {
            Stop-DeepScan -Reason "Manual cancel requested by user."
        }
    }
})

$listDeepFindings.Add_SelectedIndexChanged({
    if ($listDeepFindings.SelectedIndices.Count -eq 0) { return }
    $selected = $listDeepFindings.SelectedItems[0]
    $idx = [int]$selected.Tag
    Show-DeepFindingDetail -Index $idx
})

$cmbDeepFilter.Add_SelectedIndexChanged({
    $script:deepScanFilter = [string]$cmbDeepFilter.SelectedItem
    Populate-DeepScanFindings -Findings (Get-DeepScanFilteredFindings)
    Append-Status ("Deep Scan filter applied: {0}" -f $script:deepScanFilter)
})

$btnDeepExport.Add_Click({ Export-DeepScanReport })

$listDeepSolutions.Add_SelectedIndexChanged({
    if ($listDeepSolutions.SelectedIndices.Count -eq 0) {
        $btnDeepApply.Enabled   = $false
        $btnDeepApply.ForeColor = $clrMuted
        return
    }
    $canApply = -not (Test-AnyOperationRunning)
    $btnDeepApply.Enabled   = $canApply
    $btnDeepApply.ForeColor = if ($canApply) { $clrText } else { $clrMuted }
    $solItem = $listDeepSolutions.SelectedItems[0]
    $lblDeepApplyState.Text = ("Ready to apply [{0}] fix — click button to confirm" -f $solItem.Text)
})

$btnDeepApply.Add_Click({
    if ($listDeepFindings.SelectedIndices.Count -eq 0 -or $listDeepSolutions.SelectedIndices.Count -eq 0) {
        Append-Status "Select a finding AND a solution row first."
        return
    }
    $findingIdx = [int]$listDeepFindings.SelectedItems[0].Tag
    if ($findingIdx -ge $script:deepScanFindings.Count) { return }
    $finding     = $script:deepScanFindings[$findingIdx]
    $solItem     = $listDeepSolutions.SelectedItems[0]
    $solLevel    = $solItem.Text
    $solLabel    = $solItem.SubItems[1].Text
    $solRiskNote = $solItem.SubItems[2].Text
    $solRollback = $solItem.SubItems[3].Text

    $confirmMsg = "Apply fix for: $([string]$finding.Id)`r`nLevel    : $solLevel`r`nFix      : $solLabel`r`nRisk     : $solRiskNote`r`nRollback : $solRollback`r`n`r`nProceed?"
    $confirm = [System.Windows.Forms.MessageBox]::Show($confirmMsg, "Confirm Fix Application", "YesNo", "Warning")
    if ($confirm -ne "Yes") { return }
    Apply-DeepFix -FindingId ([string]$finding.Id) -SolutionLevel $solLevel
})

Load-GuiPreferences
Cleanup-DiagnosticLogs -RetentionDays $script:diagnosticRetentionDays
if ($cmbDepth.Items.Contains($script:startupAnalyzeDepth)) {
    $cmbDepth.SelectedItem = $script:startupAnalyzeDepth
}
$numTop.Value = [decimal]$script:startupAnalyzeTop

$analysisTimer = New-Object System.Windows.Forms.Timer
$analysisTimer.Interval = 1000
$analysisTimer.Add_Tick({ Poll-GarbageAnalysis })

$cleanupTimer = New-Object System.Windows.Forms.Timer
$cleanupTimer.Interval = 1000
$cleanupTimer.Add_Tick({ Poll-CleanupOperation })

$computeTimer = New-Object System.Windows.Forms.Timer
$computeTimer.Interval = 1000
$computeTimer.Add_Tick({ Poll-ComputeAnalysis })

$quickCleanupTimer = New-Object System.Windows.Forms.Timer
$quickCleanupTimer.Interval = 1000
$quickCleanupTimer.Add_Tick({ Poll-QuickCleanup })

$healthAuditTimer = New-Object System.Windows.Forms.Timer
$healthAuditTimer.Interval = 1000
$healthAuditTimer.Add_Tick({ Poll-HealthAudit })

$healthApplyTimer = New-Object System.Windows.Forms.Timer
$healthApplyTimer.Interval = 1000
$healthApplyTimer.Add_Tick({ Poll-HealthApply })

$deepScanTimer = New-Object System.Windows.Forms.Timer
$deepScanTimer.Interval = 1000
$deepScanTimer.Add_Tick({ Poll-DeepScan })

$deepScanApplyTimer = New-Object System.Windows.Forms.Timer
$deepScanApplyTimer.Interval = 1000
$deepScanApplyTimer.Add_Tick({ Poll-DeepScanApply })

$form.Add_Shown({
    Set-NoTheme -Ctrl $listExplorer
    Set-NoTheme -Ctrl $listTasks
    Set-NoTheme -Ctrl $listDeepFindings
    Set-NoTheme -Ctrl $listDeepSolutions
    $lblStatusRight.Text = ("PSHost: {0}" -f (Split-Path -Leaf $script:psHost))
    Refresh-Drives
    Reload-Tasks
    if ($script:autoAnalyzeOnStartup) {
        Append-Status ("Startup auto-analyze enabled. Depth={0}, Top={1}." -f [string]$cmbDepth.SelectedItem, [int]$numTop.Value)
        Run-GarbageAnalysis
    } else {
        Append-Status "Startup auto-analyze disabled by config. UI ready."
    }
})
[void]$form.ShowDialog()
