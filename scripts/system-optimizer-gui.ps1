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

$script:guiDir = Join-Path $script:scriptRoot "gui"
# Pre-init registries before StrictMode modules (ps2exe + hub-common safe)
$global:HubWorkers = @{}
$global:HubTransparencyPanel = $null
$hubCommonPath = Join-Path $script:scriptRoot "hub-common.ps1"
if (Test-Path -LiteralPath $hubCommonPath) {
    . $hubCommonPath
}
if (Test-Path -LiteralPath (Join-Path $script:guiDir "theme.ps1")) {
    . (Join-Path $script:guiDir "theme.ps1")
}
if (Test-Path -LiteralPath (Join-Path $script:guiDir "worker-helpers.ps1")) {
    . (Join-Path $script:guiDir "worker-helpers.ps1")
}
if (Test-Path -LiteralPath (Join-Path $script:guiDir "async-worker.ps1")) {
    . (Join-Path $script:guiDir "async-worker.ps1")
    if (Get-Command Initialize-HubWorkerRegistry -ErrorAction SilentlyContinue) {
        Initialize-HubWorkerRegistry
    }
}
if (Test-Path -LiteralPath (Join-Path $script:guiDir "i18n.ps1")) {
    . (Join-Path $script:guiDir "i18n.ps1")
}
if (Test-Path -LiteralPath (Join-Path $script:guiDir "command-help.ps1")) {
    . (Join-Path $script:guiDir "command-help.ps1")
}
if (Test-Path -LiteralPath (Join-Path $script:guiDir "keep-service-wizard.ps1")) {
    . (Join-Path $script:guiDir "keep-service-wizard.ps1")
}
if (Test-Path -LiteralPath (Join-Path $script:guiDir "transparency-panel.ps1")) {
    . (Join-Path $script:guiDir "transparency-panel.ps1")
}
if (Test-Path -LiteralPath (Join-Path $script:guiDir "operator-auth-dialog.ps1")) {
    . (Join-Path $script:guiDir "operator-auth-dialog.ps1")
}
if (Test-Path -LiteralPath (Join-Path $script:guiDir "hitl-paths-panel.ps1")) {
    . (Join-Path $script:guiDir "hitl-paths-panel.ps1")
}
$operatorAuthLib = Join-Path $script:scriptRoot "lib\operator-auth.ps1"
if (Test-Path -LiteralPath $operatorAuthLib) {
    . $operatorAuthLib
}
if (Test-Path -LiteralPath (Join-Path $script:guiDir "unknown-process-wizard.ps1")) {
    . (Join-Path $script:guiDir "unknown-process-wizard.ps1")
}
$script:guiLanguage = 'en'
if (Get-Command Initialize-I18n -ErrorAction SilentlyContinue) {
    Initialize-I18n -HubRoot $script:hubRoot -Language $script:guiLanguage
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
$script:computeAnalyzerScript = Join-Path $script:scriptRoot "analyze-process-pressure.ps1"
$script:applyPressureScript = Join-Path $script:scriptRoot "apply-process-pressure-safe.ps1"
$script:evaluateDefenderScript = Join-Path $script:scriptRoot "evaluate-defender-extreme-necessity.ps1"
$script:applyDefenderScript = Join-Path $script:scriptRoot "apply-defender-extreme-necessity.ps1"
$script:guiKeepExtremeWizard = $true
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
$script:autoAnalyzeOnStartup = $false
$script:startupAnalyzeDepth = "Quick"
$script:startupAnalyzeTop = 15
$script:computeAnalyzeDurationSec = 8
$script:computeAnalyzeTop = 8
$script:offerSafeThrottleAfterCompute = $true
$script:showDefenderReviewAfterCompute = $true
$script:defenderMinScoreForPrompt = 85
$script:quickCleanupRetentionDays = 2
$script:quickCleanupMaxFilesPerTarget = 2000
$script:diagnosticRetentionDays = 7
$script:cfgTempRetentionDays = 7
$script:cfgLogRetentionDays = 30
$script:cfgTier2Enabled = $false
$script:cfgTier2SimulateOnly = $true
$script:diagnosticsDir = Join-Path $script:hubRoot "logs\diagnostics"
$script:healthAuditScript  = Join-Path $script:scriptRoot "system-health-audit.ps1"
$script:nvmeAdvisorScript  = Join-Path $script:scriptRoot "analyze-nvme-readonly-plan.ps1"
$script:partitionLegacyScript = Join-Path $script:scriptRoot "analyze-recovery-partition-legacy.ps1"
$script:applyFixesScript   = Join-Path $script:scriptRoot "apply-safe-fixes.ps1"
$script:healthAuditProcess = $null
$script:healthAuditJson    = Join-Path $script:hubRoot "logs\health-audit-live.json"
$script:healthApplyJson    = Join-Path $script:hubRoot "logs\health-apply-live.json"
$script:healthAuditStdOut  = Join-Path $script:hubRoot "logs\health-audit-live.out.log"
$script:healthAuditStdErr  = Join-Path $script:hubRoot "logs\health-audit-live.err.log"
$script:healthAuditStartedAt = $null
$script:healthAuditTimeoutSec = 90
$script:healthApplyTimeoutSec = 600
$script:healthApplyInProgress = $false
$script:healthAuditSoftTimeoutWarned = $false
$script:healthAuditApplyAfter = $false
$script:healthAuditMaxLevel   = 'Safe'
$script:healthAuditApplyPackagesOnly = $false
$script:healthAuditApplyFindingIds = @()
$script:nvmeAdvisorProcess = $null
$script:nvmeAdvisorJson    = Join-Path $script:hubRoot "logs\nvme-advisor-live.json"
$script:nvmeAdvisorStdOut  = Join-Path $script:hubRoot "logs\nvme-advisor-live.out.log"
$script:nvmeAdvisorStdErr  = Join-Path $script:hubRoot "logs\nvme-advisor-live.err.log"
$script:nvmeAdvisorStartedAt = $null
$script:nvmeAdvisorTimeoutSec = 75
$script:nvmeAdvisorSoftTimeoutWarned = $false
$script:partitionLegacyProcess = $null
$script:partitionLegacyJson    = Join-Path $script:hubRoot "logs\partition-legacy-live.json"
$script:partitionLegacyStdOut  = Join-Path $script:hubRoot "logs\partition-legacy-live.out.log"
$script:partitionLegacyStdErr  = Join-Path $script:hubRoot "logs\partition-legacy-live.err.log"
$script:partitionLegacyStartedAt = $null
$script:partitionLegacyTimeoutSec = 90
$script:partitionLegacySoftTimeoutWarned = $false
$script:partitionLegacyApplyRequested = $false
$script:coreInstallProcess = $null
$script:coreInstallStartedAt = $null
$script:coreInstallTimeoutSec = 300
$script:coreInstallStdOut = Join-Path $script:hubRoot "logs\core-install-live.out.log"
$script:coreInstallStdErr = Join-Path $script:hubRoot "logs\core-install-live.err.log"

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

# ─── Privacy Scan state ───────────────────────────────────────────────────────
$script:privacyScanScript   = Join-Path $script:scriptRoot "privacy-scan-secrets.ps1"
$script:privacyProcess      = $null
$script:privacyJson         = Join-Path $script:hubRoot "logs\privacy-scan-live.json"
$script:privacyStdOut       = Join-Path $script:hubRoot "logs\privacy-scan-live.out.log"
$script:privacyStdErr       = Join-Path $script:hubRoot "logs\privacy-scan-live.err.log"
$script:privacyStartedAt    = $null
$script:privacyTimeoutSec   = 180
$script:privacySoftTimeoutWarned = $false
$script:privacyFindings     = @()
$script:showAdvancedTools   = $false


if (-not $script:appVersion) { $script:appVersion = "3.2.0" }
if (-not $clrBg) { throw "GUI theme not loaded. Expected scripts/gui/theme.ps1." }
if (-not (Get-Command Wait-ForOutputFile -ErrorAction SilentlyContinue)) { throw "GUI worker-helpers not loaded. Expected scripts/gui/worker-helpers.ps1." }

# ═══════════════════════════════════════════════════════════════════════════════
#  Main Form
# ═══════════════════════════════════════════════════════════════════════════════
$form = New-Object System.Windows.Forms.Form
$form.Text          = "System Optimizer Hub"
$form.Size          = New-Object System.Drawing.Size(1440, 900)
$form.MinimumSize   = New-Object System.Drawing.Size(1150, 720)
$form.StartPosition = "CenterScreen"
$form.BackColor     = $clrBg
$form.Font          = $fntUI

# ── Header bar ────────────────────────────────────────────────────────────────
$pnlHeader = New-Object System.Windows.Forms.Panel
$pnlHeader.Dock = "Top"
$pnlHeader.Height = 76
$pnlHeader.BackColor = $clrSurface

$pnlHeaderAccent = New-Object System.Windows.Forms.Panel
$pnlHeaderAccent.Dock = "Left"
$pnlHeaderAccent.Width = 5
$pnlHeaderAccent.BackColor = $clrAccent

$lblAppTitle = New-Object System.Windows.Forms.Label
$lblAppTitle.Text      = "System Optimizer Hub"
$lblAppTitle.Font      = $fntHead
$lblAppTitle.ForeColor = $clrText
$lblAppTitle.AutoSize  = $true
$lblAppTitle.Location  = New-Object System.Drawing.Point(18, 12)
$lblAppTitle.BackColor = [System.Drawing.Color]::Transparent

$lblAppSubtitle = New-Object System.Windows.Forms.Label
$lblAppSubtitle.Text      = ("Intelligent maintenance console  |  v{0}" -f $script:appVersion)
$lblAppSubtitle.Font      = $fntSmall
$lblAppSubtitle.ForeColor = $clrMuted
$lblAppSubtitle.AutoSize  = $true
$lblAppSubtitle.Location  = New-Object System.Drawing.Point(20, 42)
$lblAppSubtitle.BackColor = [System.Drawing.Color]::Transparent

$lblHubPath = New-Object System.Windows.Forms.Label
$lblHubPath.Text      = $script:hubRoot
$lblHubPath.Font      = $fntSmall
$lblHubPath.ForeColor = $clrAccent2
$lblHubPath.AutoSize  = $false
$lblHubPath.Width     = 380
$lblHubPath.Height    = 32
$lblHubPath.TextAlign = "MiddleRight"
$lblHubPath.Location  = New-Object System.Drawing.Point(430, 22)
$lblHubPath.Anchor    = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$lblHubPath.BackColor = [System.Drawing.Color]::Transparent

# Drive C card
$pnlDriveC = New-Object System.Windows.Forms.Panel
$pnlDriveC.Size      = New-Object System.Drawing.Size(210, 48)
$pnlDriveC.Location  = New-Object System.Drawing.Point(860, 14)
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
$pnlDriveD.Location  = New-Object System.Drawing.Point(1084, 14)
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

$pnlHeader.Controls.AddRange(@($pnlHeaderAccent, $lblAppTitle, $lblAppSubtitle, $lblHubPath, $pnlDriveC, $pnlDriveD, $pnlHeaderLine))

# ── Status bar (bottom) ───────────────────────────────────────────────────────
$pnlStatusBar = New-Object System.Windows.Forms.Panel
$pnlStatusBar.Dock      = "Bottom"
$pnlStatusBar.Height    = 32
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
$lblStatusRight.Width     = 520
$lblStatusRight.AutoSize  = $false
$lblStatusRight.TextAlign = "MiddleRight"
$lblStatusRight.Location  = New-Object System.Drawing.Point(880, 7)
$lblStatusRight.BackColor = [System.Drawing.Color]::Transparent
$lblStatusRight.Anchor    = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right

$pnlStatusBar.Controls.AddRange(@($pnlStatusBarLine, $lblStatusLeft, $lblStatusRight))

# ── TabControl ────────────────────────────────────────────────────────────────
$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock      = "Fill"
$tabs.DrawMode  = "OwnerDrawFixed"
$tabs.ItemSize  = New-Object System.Drawing.Size(148, 38)
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
            $e.Bounds.X + 6, $e.Bounds.Bottom - 4, $e.Bounds.Width - 12, 4)
        $e.Graphics.FillRectangle(
            (New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(40, $clrAccent2.R, $clrAccent2.G, $clrAccent2.B))),
            $e.Bounds.X + 1, $e.Bounds.Y + 1, $e.Bounds.Width - 2, $e.Bounds.Height - 6)
    }
})

$tabDashboard = New-Object System.Windows.Forms.TabPage
$tabDashboard.Text                 = "Home"
$tabDashboard.BackColor            = $clrBg
$tabDashboard.UseVisualStyleBackColor = $false

$tabTasks = New-Object System.Windows.Forms.TabPage
$tabTasks.Text                 = "Automation"
$tabTasks.BackColor            = $clrBg
$tabTasks.UseVisualStyleBackColor = $false

$tabLogs = New-Object System.Windows.Forms.TabPage
$tabLogs.Text                 = "Diagnostics"
$tabLogs.BackColor            = $clrBg
$tabLogs.UseVisualStyleBackColor = $false

$tabConfig = New-Object System.Windows.Forms.TabPage
$tabConfig.Text                 = "Settings"
$tabConfig.BackColor            = $clrBg
$tabConfig.UseVisualStyleBackColor = $false

$tabDeepScan = New-Object System.Windows.Forms.TabPage
$tabDeepScan.Text                 = "Health & Fixes"
$tabDeepScan.BackColor            = $clrBg
$tabDeepScan.UseVisualStyleBackColor = $false

$tabPrivacy = New-Object System.Windows.Forms.TabPage
$tabPrivacy.Text                 = "Privacy"
$tabPrivacy.BackColor            = $clrBg
$tabPrivacy.UseVisualStyleBackColor = $false

# ═══════════════════════════════════════════════════════════════════════════════
#  Dashboard Tab
# ═══════════════════════════════════════════════════════════════════════════════

# Action panel — v3: primary actions row only
$pnlActions = New-Object System.Windows.Forms.Panel
$pnlActions.Dock      = "Top"
$pnlActions.Height    = 80
$pnlActions.BackColor = $clrSurface

$clrTeal = [System.Drawing.Color]::FromArgb(13, 148, 136)
$btnAnalyze       = New-Btn "Scan Storage"   $clrAccent  144 38
$btnQuickClean    = New-Btn "Quick Clean"    $clrGreen   132 38
$btnHealthAudit   = New-Btn "Health Scan"   $clrTeal    148 38
$btnHealthApply   = New-Btn "Scan + Apply"  $clrAmber   188 38
$btnPrivacyHome   = New-Btn "Privacy Scan"   $clrPurple  148 38
$btnMoreTools     = New-Btn "More tools"     $clrRaised  128 38
$btnPkgFix        = New-Btn "Pkg Prereq Fix" $clrTeal    148 38
$btnNvmePlan      = New-Btn "NVMe Plan"       $clrAmber   138 38
$btnDeepScanJump  = New-Btn "Health Tab"     $clrPurple  118 38
$btnPartitionPlan = New-Btn "Partition Plan"  $clrCyan    148 38
$btnCompute       = New-Btn "Compute"         $clrPurple  118 38
$btnApplyThrottle = New-Btn "Safe Throttle"   $clrGreen   118 38
$btnDefenderReview = New-Btn "Defender"      $clrAmber   108 38
$btnAudit         = New-Btn "Storage Audit"   $clrCyan    120 38
$btnExecute       = New-Btn "Storage Clean"   $clrRed     120 38
$btnDiagnostics   = New-Btn "Diagnostics"    $clrAmber   128 38
$btnCancelAnalyze = New-Btn "Cancel"          $clrRaised   96 38

$lblPrimaryActions = New-Object System.Windows.Forms.Label
$lblPrimaryActions.Text      = "PRIMARY ACTIONS"
$lblPrimaryActions.Font      = $fntSmall
$lblPrimaryActions.ForeColor = $clrMuted
$lblPrimaryActions.AutoSize  = $true
$lblPrimaryActions.Location  = New-Object System.Drawing.Point(12, 8)
$lblPrimaryActions.BackColor = [System.Drawing.Color]::Transparent

$lblAdvancedActions = New-Object System.Windows.Forms.Label
$lblAdvancedActions.Text      = "ADVANCED TOOLS"
$lblAdvancedActions.Font      = $fntSmall
$lblAdvancedActions.ForeColor = $clrMuted
$lblAdvancedActions.AutoSize  = $true
$lblAdvancedActions.Location  = New-Object System.Drawing.Point(12, 8)
$lblAdvancedActions.BackColor = [System.Drawing.Color]::Transparent

$btnHealthAudit.Location   = New-Object System.Drawing.Point(12,  30)
$btnAnalyze.Location       = New-Object System.Drawing.Point(168, 30)
$btnQuickClean.Location    = New-Object System.Drawing.Point(312, 30)
$btnPrivacyHome.Location   = New-Object System.Drawing.Point(452, 30)
$btnMoreTools.Location     = New-Object System.Drawing.Point(608, 30)
$btnCancelAnalyze.Location = New-Object System.Drawing.Point(744, 30)

$pnlAdvancedTools = New-Object System.Windows.Forms.Panel
$pnlAdvancedTools.Dock      = "Top"
$pnlAdvancedTools.Height    = 116
$pnlAdvancedTools.BackColor = $clrSurface
$pnlAdvancedTools.Visible   = $false

$btnHealthApply.Location   = New-Object System.Drawing.Point(12, 30)
$btnPkgFix.Location        = New-Object System.Drawing.Point(208, 30)
$btnNvmePlan.Location      = New-Object System.Drawing.Point(364, 30)
$btnDeepScanJump.Location  = New-Object System.Drawing.Point(510, 30)
$btnPartitionPlan.Location = New-Object System.Drawing.Point(636, 30)
$btnDiagnostics.Location   = New-Object System.Drawing.Point(792, 30)
$btnCompute.Location       = New-Object System.Drawing.Point(12, 74)
$btnApplyThrottle.Location = New-Object System.Drawing.Point(136, 74)
$btnDefenderReview.Location = New-Object System.Drawing.Point(260, 74)
$btnAudit.Location         = New-Object System.Drawing.Point(376, 74)
$btnExecute.Location       = New-Object System.Drawing.Point(504, 74)

$pnlAdvancedTools.Controls.AddRange(@(
    $lblAdvancedActions,
    $btnHealthApply, $btnPkgFix, $btnNvmePlan, $btnDeepScanJump, $btnPartitionPlan, $btnDiagnostics,
    $btnCompute, $btnApplyThrottle, $btnDefenderReview, $btnAudit, $btnExecute
))

$btnCancelAnalyze.Enabled  = $false
$btnCancelAnalyze.ForeColor = $clrMuted

# Scan options row — separate panel to avoid overlap with primary buttons
$pnlScanOptions = New-Object System.Windows.Forms.Panel
$pnlScanOptions.Dock      = "Top"
$pnlScanOptions.Height    = 58
$pnlScanOptions.BackColor = $clrSurface

$lblDepth = New-Object System.Windows.Forms.Label
$lblDepth.Text      = "SCAN"
$lblDepth.Font      = $fntSmall
$lblDepth.ForeColor = $clrMuted
$lblDepth.AutoSize  = $true
$lblDepth.Location  = New-Object System.Drawing.Point(12, 6)
$lblDepth.BackColor = [System.Drawing.Color]::Transparent

$cmbDepth = New-Object System.Windows.Forms.ComboBox
$cmbDepth.DropDownStyle = "DropDownList"
$cmbDepth.Items.AddRange(@("Quick", "Standard", "Deep"))
$cmbDepth.SelectedItem = "Standard"
$cmbDepth.Width = 108
$cmbDepth.Location = New-Object System.Drawing.Point(12, 24)
$cmbDepth.BackColor = $clrRaised
$cmbDepth.ForeColor = $clrText
$cmbDepth.Font = $fntUI
$cmbDepth.FlatStyle = "Flat"

$lblAuditLevel = New-Object System.Windows.Forms.Label
$lblAuditLevel.Text      = "DETAIL"
$lblAuditLevel.Font      = $fntSmall
$lblAuditLevel.ForeColor = $clrMuted
$lblAuditLevel.AutoSize  = $true
$lblAuditLevel.Location  = New-Object System.Drawing.Point(132, 6)
$lblAuditLevel.BackColor = [System.Drawing.Color]::Transparent

$cmbAuditLevel = New-Object System.Windows.Forms.ComboBox
$cmbAuditLevel.DropDownStyle = "DropDownList"
$cmbAuditLevel.Items.AddRange(@("FileLevel", "BitLevel"))
$cmbAuditLevel.SelectedItem = "FileLevel"
$cmbAuditLevel.Width = 108
$cmbAuditLevel.Location = New-Object System.Drawing.Point(132, 24)
$cmbAuditLevel.BackColor = $clrRaised
$cmbAuditLevel.ForeColor = $clrText
$cmbAuditLevel.Font = $fntUI
$cmbAuditLevel.FlatStyle = "Flat"

$lblCleanupMode = New-Object System.Windows.Forms.Label
$lblCleanupMode.Text      = "MODE"
$lblCleanupMode.Font      = $fntSmall
$lblCleanupMode.ForeColor = $clrMuted
$lblCleanupMode.AutoSize  = $true
$lblCleanupMode.Location  = New-Object System.Drawing.Point(252, 6)
$lblCleanupMode.BackColor = [System.Drawing.Color]::Transparent

$cmbCleanupMode = New-Object System.Windows.Forms.ComboBox
$cmbCleanupMode.DropDownStyle = "DropDownList"
$cmbCleanupMode.Items.AddRange(@("Safe", "Radical"))
$cmbCleanupMode.SelectedItem = "Safe"
$cmbCleanupMode.Width = 92
$cmbCleanupMode.Location = New-Object System.Drawing.Point(252, 24)
$cmbCleanupMode.BackColor = $clrRaised
$cmbCleanupMode.ForeColor = $clrText
$cmbCleanupMode.Font = $fntUI
$cmbCleanupMode.FlatStyle = "Flat"

$lblFixLevel = New-Object System.Windows.Forms.Label
$lblFixLevel.Text      = "MAX FIX"
$lblFixLevel.Font      = $fntSmall
$lblFixLevel.ForeColor = $clrMuted
$lblFixLevel.AutoSize  = $true
$lblFixLevel.Location  = New-Object System.Drawing.Point(356, 6)
$lblFixLevel.BackColor = [System.Drawing.Color]::Transparent

$cmbFixLevel = New-Object System.Windows.Forms.ComboBox
$cmbFixLevel.DropDownStyle = "DropDownList"
$cmbFixLevel.Items.AddRange(@("Safe", "Moderate", "Aggressive"))
$cmbFixLevel.SelectedItem = "Safe"
$cmbFixLevel.Width = 108
$cmbFixLevel.Location = New-Object System.Drawing.Point(356, 24)
$cmbFixLevel.BackColor = $clrRaised
$cmbFixLevel.ForeColor = $clrText
$cmbFixLevel.Font = $fntUI
$cmbFixLevel.FlatStyle = "Flat"

$lblTop = New-Object System.Windows.Forms.Label
$lblTop.Text      = "TOP"
$lblTop.Font      = $fntSmall
$lblTop.ForeColor = $clrMuted
$lblTop.AutoSize  = $true
$lblTop.Location  = New-Object System.Drawing.Point(476, 6)
$lblTop.BackColor = [System.Drawing.Color]::Transparent

$numTop = New-Object System.Windows.Forms.NumericUpDown
$numTop.Minimum  = 5
$numTop.Maximum  = 100
$numTop.Value    = 25
$numTop.Width    = 58
$numTop.Location = New-Object System.Drawing.Point(476, 24)
$numTop.BackColor = $clrRaised
$numTop.ForeColor = $clrText
$numTop.Font = $fntUI

$lblExplorerHint = New-Object System.Windows.Forms.Label
$lblExplorerHint.Text      = "Double-click a row to open the path"
$lblExplorerHint.Font      = $fntSmall
$lblExplorerHint.ForeColor = $clrMuted
$lblExplorerHint.AutoSize  = $true
$lblExplorerHint.Location  = New-Object System.Drawing.Point(548, 28)
$lblExplorerHint.BackColor = [System.Drawing.Color]::Transparent

$pnlScanOptionsBorder = New-Object System.Windows.Forms.Panel
$pnlScanOptionsBorder.Dock      = "Bottom"
$pnlScanOptionsBorder.Height    = 1
$pnlScanOptionsBorder.BackColor = $clrBorderC

$pnlScanOptions.Controls.AddRange(@(
    $lblDepth, $cmbDepth, $lblAuditLevel, $cmbAuditLevel,
    $lblCleanupMode, $cmbCleanupMode, $lblFixLevel, $cmbFixLevel,
    $lblTop, $numTop, $lblExplorerHint, $pnlScanOptionsBorder
))

$pnlActionsBorder = New-Object System.Windows.Forms.Panel
$pnlActionsBorder.Dock      = "Bottom"
$pnlActionsBorder.Height    = 1
$pnlActionsBorder.BackColor = $clrBorderC

$pnlActions.Controls.AddRange(@(
    $lblPrimaryActions,
    $btnHealthAudit, $btnAnalyze, $btnQuickClean, $btnPrivacyHome, $btnMoreTools, $btnCancelAnalyze,
    $pnlActionsBorder
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

$pnlCommandHelp = New-Object System.Windows.Forms.Panel
$pnlCommandHelp.Dock      = "Bottom"
$pnlCommandHelp.Height    = 132
$pnlCommandHelp.BackColor = $clrSurface

$lblCommandHelpTitle = New-Object System.Windows.Forms.Label
$lblCommandHelpTitle.Text      = "What this does"
$lblCommandHelpTitle.Font      = $fntH2
$lblCommandHelpTitle.ForeColor = $clrAccent2
$lblCommandHelpTitle.AutoSize  = $true
$lblCommandHelpTitle.Location  = New-Object System.Drawing.Point(12, 8)
$lblCommandHelpTitle.BackColor = [System.Drawing.Color]::Transparent

$txtCommandHelp = New-Object System.Windows.Forms.TextBox
$txtCommandHelp.Multiline   = $true
$txtCommandHelp.ScrollBars  = "Vertical"
$txtCommandHelp.ReadOnly    = $true
$txtCommandHelp.BackColor   = $clrBg
$txtCommandHelp.ForeColor   = $clrText
$txtCommandHelp.Font        = $fntSmall
$txtCommandHelp.BorderStyle = "None"
$txtCommandHelp.Location    = New-Object System.Drawing.Point(12, 28)
$txtCommandHelp.Size        = New-Object System.Drawing.Size(1380, 96)
$txtCommandHelp.Anchor      = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Bottom

$pnlCommandHelpBorder = New-Object System.Windows.Forms.Panel
$pnlCommandHelpBorder.Dock      = "Top"
$pnlCommandHelpBorder.Height    = 1
$pnlCommandHelpBorder.BackColor = $clrBorderC

$pnlCommandHelp.Controls.AddRange(@($pnlCommandHelpBorder, $lblCommandHelpTitle, $txtCommandHelp))

$tabDashboard.Controls.Add($splitDash)
$tabDashboard.Controls.Add($pnlCommandHelp)
$tabDashboard.Controls.Add($pnlProgress)
$tabDashboard.Controls.Add($pnlScanOptions)
$tabDashboard.Controls.Add($pnlAdvancedTools)
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

$btnReloadTasks  = New-Btn "Reload Tasks"  $clrRaised  128 38
$btnInstallTasks = New-Btn "Install Core"  $clrAccent  128 38
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
    "Health Audit (stdout)", "Health Audit (stderr)",
    "NVMe Plan (stdout)", "NVMe Plan (stderr)",
    "Partition Plan (stdout)", "Partition Plan (stderr)",
    "Core Install (stdout)", "Core Install (stderr)"
))
$cmbLogSource.SelectedIndex = 0

$btnLoadLogs = New-Btn "Load Last 200"  $clrRaised  130 38
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

$btnOpenConfig = New-Btn "Open in Notepad"  $clrRaised  150 38
$btnOpenConfig.Location = New-Object System.Drawing.Point(24, 88)

$btnSaveConfig = New-Btn "Save GUI Settings"  $clrAccent  150 38
$btnSaveConfig.Location = New-Object System.Drawing.Point(190, 88)

$btnReloadConfig = New-Btn "Reload"  $clrRaised  90 38
$btnReloadConfig.Location = New-Object System.Drawing.Point(356, 88)

$chkAutoAnalyze = New-Object System.Windows.Forms.CheckBox
$chkAutoAnalyze.Text = "Auto-analyze on startup"
$chkAutoAnalyze.ForeColor = $clrText
$chkAutoAnalyze.BackColor = [System.Drawing.Color]::Transparent
$chkAutoAnalyze.AutoSize = $true
$chkAutoAnalyze.Location = New-Object System.Drawing.Point(24, 140)

$lblCfgTemp = New-Object System.Windows.Forms.Label
$lblCfgTemp.Text = "Temp retention (days)"
$lblCfgTemp.ForeColor = $clrMuted
$lblCfgTemp.AutoSize = $true
$lblCfgTemp.Location = New-Object System.Drawing.Point(24, 176)
$lblCfgTemp.BackColor = [System.Drawing.Color]::Transparent

$numCfgTemp = New-Object System.Windows.Forms.NumericUpDown
$numCfgTemp.Minimum = 1; $numCfgTemp.Maximum = 30; $numCfgTemp.Value = 7
$numCfgTemp.Width = 72
$numCfgTemp.Location = New-Object System.Drawing.Point(180, 172)
$numCfgTemp.BackColor = $clrRaised; $numCfgTemp.ForeColor = $clrText

$lblCfgLog = New-Object System.Windows.Forms.Label
$lblCfgLog.Text = "Log retention (days)"
$lblCfgLog.ForeColor = $clrMuted
$lblCfgLog.AutoSize = $true
$lblCfgLog.Location = New-Object System.Drawing.Point(24, 208)
$lblCfgLog.BackColor = [System.Drawing.Color]::Transparent

$numCfgLog = New-Object System.Windows.Forms.NumericUpDown
$numCfgLog.Minimum = 1; $numCfgLog.Maximum = 90; $numCfgLog.Value = 30
$numCfgLog.Width = 72
$numCfgLog.Location = New-Object System.Drawing.Point(180, 204)
$numCfgLog.BackColor = $clrRaised; $numCfgLog.ForeColor = $clrText

$lblCfgDiag = New-Object System.Windows.Forms.Label
$lblCfgDiag.Text = "Diagnostic log retention"
$lblCfgDiag.ForeColor = $clrMuted
$lblCfgDiag.AutoSize = $true
$lblCfgDiag.Location = New-Object System.Drawing.Point(24, 240)
$lblCfgDiag.BackColor = [System.Drawing.Color]::Transparent

$numCfgDiag = New-Object System.Windows.Forms.NumericUpDown
$numCfgDiag.Minimum = 1; $numCfgDiag.Maximum = 30; $numCfgDiag.Value = 7
$numCfgDiag.Width = 72
$numCfgDiag.Location = New-Object System.Drawing.Point(180, 236)
$numCfgDiag.BackColor = $clrRaised; $numCfgDiag.ForeColor = $clrText

$chkTier2 = New-Object System.Windows.Forms.CheckBox
$chkTier2.Text = "Cleanup Tier-2 enabled (D: whitelist)"
$chkTier2.ForeColor = $clrText
$chkTier2.BackColor = [System.Drawing.Color]::Transparent
$chkTier2.AutoSize = $true
$chkTier2.Location = New-Object System.Drawing.Point(24, 276)

$chkTier2Sim = New-Object System.Windows.Forms.CheckBox
$chkTier2Sim.Text = "Tier-2 simulate only (audit, no delete)"
$chkTier2Sim.ForeColor = $clrText
$chkTier2Sim.BackColor = [System.Drawing.Color]::Transparent
$chkTier2Sim.AutoSize = $true
$chkTier2Sim.Location = New-Object System.Drawing.Point(24, 302)

$lblCfgHint = New-Object System.Windows.Forms.Label
$lblCfgHint.Text = "Monitor/WHEA/Orchestrator thresholds: edit JSON or use Save to persist GUI section."
$lblCfgHint.Font = $fntSmall
$lblCfgHint.ForeColor = $clrMuted
$lblCfgHint.AutoSize = $true
$lblCfgHint.MaximumSize = New-Object System.Drawing.Size(640, 0)
$lblCfgHint.Location = New-Object System.Drawing.Point(24, 340)
$lblCfgHint.BackColor = [System.Drawing.Color]::Transparent

$lblCfgLang = New-Object System.Windows.Forms.Label
$lblCfgLang.Text = "Language"
$lblCfgLang.ForeColor = $clrMuted
$lblCfgLang.AutoSize = $true
$lblCfgLang.Location = New-Object System.Drawing.Point(24, 372)
$lblCfgLang.BackColor = [System.Drawing.Color]::Transparent

$cmbLanguage = New-Object System.Windows.Forms.ComboBox
$cmbLanguage.DropDownStyle = "DropDownList"
$cmbLanguage.Width = 160
$cmbLanguage.Location = New-Object System.Drawing.Point(180, 368)
$cmbLanguage.BackColor = $clrRaised
$cmbLanguage.ForeColor = $clrText
$cmbLanguage.Font = $fntUI
$cmbLanguage.FlatStyle = "Flat"

$pnlConfigBody.Controls.AddRange(@(
    $lblConfigHeading, $lblConfig, $btnOpenConfig, $btnSaveConfig, $btnReloadConfig,
    $chkAutoAnalyze, $lblCfgTemp, $numCfgTemp, $lblCfgLog, $numCfgLog,
    $lblCfgDiag, $numCfgDiag, $chkTier2, $chkTier2Sim, $lblCfgHint,
    $lblCfgLang, $cmbLanguage
))
$tabConfig.Controls.Add($pnlConfigBody)

# ═══════════════════════════════════════════════════════════════════════════════
#  Deep Scan Tab
# ═══════════════════════════════════════════════════════════════════════════════

# ── Header ────────────────────────────────────────────────────────────────────
$pnlDeepScanHeader = New-Object System.Windows.Forms.Panel
$pnlDeepScanHeader.Dock      = "Top"
$pnlDeepScanHeader.Height    = 72
$pnlDeepScanHeader.BackColor = $clrSurface

$btnDeepScanRun = New-Btn "Run Deep Scan"  $clrCyan   130 38
$btnDeepScanRun.Location = New-Object System.Drawing.Point(12, 19)

$btnDeepScanCancel = New-Btn "Cancel"  $clrRaised  90 38
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

$btnDeepExport = New-Btn "Export Report"  $clrRaised  118 38
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
$listDeepSolutions.Columns.Add("Kind",     72)  | Out-Null
$listDeepSolutions.Columns.Add("Fix",      220) | Out-Null
$listDeepSolutions.Columns.Add("Risk",     180) | Out-Null
$listDeepSolutions.Columns.Add("Rollback", 180) | Out-Null

# Apply button panel  (Dock=Bottom, wraps solutions list)
$pnlDeepApply = New-Object System.Windows.Forms.Panel
$pnlDeepApply.Dock      = "Bottom"
$pnlDeepApply.Height    = 50
$pnlDeepApply.BackColor = $clrSurface

$btnDeepApply = New-Btn "Apply Selected Fix"  $clrGreen  180 38
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

# ═══════════════════════════════════════════════════════════════════════════════
#  Privacy Tab
# ═══════════════════════════════════════════════════════════════════════════════

$pnlPrivacyHeader = New-Object System.Windows.Forms.Panel
$pnlPrivacyHeader.Dock      = "Top"
$pnlPrivacyHeader.Height    = 64
$pnlPrivacyHeader.BackColor = $clrSurface

$btnPrivacyRun = New-Btn "Run Privacy Scan" $clrPurple 170 38
$btnPrivacyRun.Location = New-Object System.Drawing.Point(12, 14)

$btnPrivacyCancel = New-Btn "Cancel" $clrRaised 90 38
$btnPrivacyCancel.Location = New-Object System.Drawing.Point(168, 14)
$btnPrivacyCancel.Enabled = $false
$btnPrivacyCancel.ForeColor = $clrMuted

$lblPrivacyDesc = New-Object System.Windows.Forms.Label
$lblPrivacyDesc.Text      = "Read-only scan for plaintext credentials. Values are redacted in reports."
$lblPrivacyDesc.Font      = $fntSmall
$lblPrivacyDesc.ForeColor = $clrMuted
$lblPrivacyDesc.AutoSize  = $true
$lblPrivacyDesc.Location  = New-Object System.Drawing.Point(300, 20)
$lblPrivacyDesc.BackColor = [System.Drawing.Color]::Transparent

$pnlPrivacyHeaderBorder = New-Object System.Windows.Forms.Panel
$pnlPrivacyHeaderBorder.Dock      = "Bottom"
$pnlPrivacyHeaderBorder.Height    = 1
$pnlPrivacyHeaderBorder.BackColor = $clrBorderC

$pnlPrivacyHeader.Controls.AddRange(@($btnPrivacyRun, $btnPrivacyCancel, $lblPrivacyDesc, $pnlPrivacyHeaderBorder))

$pnlPrivacyProgress = New-Object System.Windows.Forms.Panel
$pnlPrivacyProgress.Dock      = "Top"
$pnlPrivacyProgress.Height    = 44
$pnlPrivacyProgress.BackColor = $clrRaised
$pnlPrivacyProgress.Visible   = $false

$progressPrivacy = New-Object System.Windows.Forms.ProgressBar
$progressPrivacy.Style                 = "Marquee"
$progressPrivacy.MarqueeAnimationSpeed = 28
$progressPrivacy.Dock                  = "Top"
$progressPrivacy.Height                = 5

$lblPrivacyState = New-Object System.Windows.Forms.Label
$lblPrivacyState.Text      = "Idle"
$lblPrivacyState.Font      = $fntH2
$lblPrivacyState.ForeColor = $clrPurple
$lblPrivacyState.AutoSize  = $true
$lblPrivacyState.Location  = New-Object System.Drawing.Point(14, 12)
$lblPrivacyState.BackColor = [System.Drawing.Color]::Transparent

$pnlPrivacyProgress.Controls.AddRange(@($progressPrivacy, $lblPrivacyState))

$listPrivacyFindings = New-Object System.Windows.Forms.ListView
$listPrivacyFindings.View          = "Details"
$listPrivacyFindings.FullRowSelect = $true
$listPrivacyFindings.GridLines     = $false
$listPrivacyFindings.Dock          = "Fill"
$listPrivacyFindings.HideSelection = $false
$listPrivacyFindings.BackColor     = $clrSurface
$listPrivacyFindings.ForeColor     = $clrText
$listPrivacyFindings.Font          = $fntUI
$listPrivacyFindings.BorderStyle   = "None"
$listPrivacyFindings.Columns.Add("Sev",      80)  | Out-Null
$listPrivacyFindings.Columns.Add("Category", 100) | Out-Null
$listPrivacyFindings.Columns.Add("Pattern",  110) | Out-Null
$listPrivacyFindings.Columns.Add("File",     360) | Out-Null
$listPrivacyFindings.Columns.Add("Line",     50)  | Out-Null
$listPrivacyFindings.Columns.Add("Preview",  140) | Out-Null

$txtPrivacyDetail = New-Object System.Windows.Forms.TextBox
$txtPrivacyDetail.Multiline   = $true
$txtPrivacyDetail.ScrollBars  = "Vertical"
$txtPrivacyDetail.Dock        = "Fill"
$txtPrivacyDetail.ReadOnly    = $true
$txtPrivacyDetail.BackColor   = $clrBg
$txtPrivacyDetail.ForeColor   = $clrText
$txtPrivacyDetail.Font        = $fntUI
$txtPrivacyDetail.BorderStyle = "None"

$splitPrivacy = New-Object System.Windows.Forms.SplitContainer
$splitPrivacy.Dock             = "Fill"
$splitPrivacy.Orientation      = "Horizontal"
$splitPrivacy.SplitterDistance = 380
$splitPrivacy.SplitterWidth    = 3
$splitPrivacy.BackColor        = $clrBorderC
$splitPrivacy.Panel1.BackColor = $clrBg
$splitPrivacy.Panel2.BackColor = $clrBg
$splitPrivacy.Panel1.Controls.Add($listPrivacyFindings)
$splitPrivacy.Panel2.Controls.Add($txtPrivacyDetail)

$tabPrivacy.SuspendLayout()
$tabPrivacy.Controls.Add($splitPrivacy)
$tabPrivacy.Controls.Add($pnlPrivacyProgress)
$tabPrivacy.Controls.Add($pnlPrivacyHeader)
$tabPrivacy.ResumeLayout($false)

# ═══════════════════════════════════════════════════════════════════════════════
#  Control & Transparency Tab
# ═══════════════════════════════════════════════════════════════════════════════
$script:transparencyUi = $null
if (Get-Command New-TransparencyTab -ErrorAction SilentlyContinue) {
    $hubPathsForTransparency = Get-HubPaths -HubRoot $script:hubRoot
    $script:transparencyUi = New-TransparencyTab `
        -HubRoot $script:hubRoot `
        -ScriptRoot $script:scriptRoot `
        -ConfigPath $hubPathsForTransparency.ConfigFile `
        -OnStatus { param($m) Append-Status $m } `
        -TestBusy { Test-AnyOperationRunning } `
        -OnDefenderReview { Run-DefenderExtremeReview }
    $tabTransparency = $script:transparencyUi.Tab
} else {
    $tabTransparency = New-Object System.Windows.Forms.TabPage
    $tabTransparency.Text = 'Control'
    $tabTransparency.BackColor = $clrBg
}

# ── Assemble ──────────────────────────────────────────────────────────────────
$tabs.TabPages.AddRange(@($tabDashboard, $tabDeepScan, $tabPrivacy, $tabTransparency, $tabTasks, $tabLogs, $tabConfig))

# Dock layout processes children from highest index first. Edge-docked controls
# (Top/Bottom) must have HIGHER indices so they claim space BEFORE Fill.
$form.SuspendLayout()
$form.Controls.Add($tabs)          # index 0 → Dock=Fill  → docked last  → remaining space
$form.Controls.Add($pnlStatusBar)  # index 1 → Dock=Bottom → docked second
$form.Controls.Add($pnlHeader)     # index 2 → Dock=Top    → docked first → 64px from top
$form.ResumeLayout($false)

$tabs.Add_SelectedIndexChanged({
    if ($tabs.SelectedTab -eq $tabTransparency -and $script:transparencyUi -and $script:transparencyUi.Refresh) {
        & $script:transparencyUi.Refresh
    }
})

function Apply-GuiLanguage {
    if (-not (Get-Command Get-I18n -ErrorAction SilentlyContinue)) { return }

    $form.Text = Get-I18n 'app.title'
    $lblAppTitle.Text = Get-I18n 'app.title'
    $lblAppSubtitle.Text = (Get-I18n 'app.subtitle') -f $script:appVersion
    $tabDashboard.Text = Get-I18n 'tabs.home'
    $tabDeepScan.Text = Get-I18n 'tabs.health'
    $tabPrivacy.Text = Get-I18n 'tabs.privacy'
    $tabTransparency.Text = Get-I18n 'tabs.control'
    if (Get-Command Set-TransparencyTabLanguage -ErrorAction SilentlyContinue) {
        Set-TransparencyTabLanguage -Controls $script:transparencyUi
    }
    $tabTasks.Text = Get-I18n 'tabs.automation'
    $tabLogs.Text = Get-I18n 'tabs.diagnostics'
    $tabConfig.Text = Get-I18n 'tabs.settings'
    $lblPrimaryActions.Text = Get-I18n 'sections.primary_actions'
    $lblAdvancedActions.Text = Get-I18n 'sections.advanced_tools'
    $lblCommandHelpTitle.Text = Get-I18n 'sections.command_help'
    $btnHealthAudit.Text = Get-I18n 'buttons.health_check'
    $btnHealthApply.Text = Get-I18n 'buttons.health_apply'
    $btnAnalyze.Text = Get-I18n 'buttons.scan_storage'
    $btnQuickClean.Text = Get-I18n 'buttons.quick_clean'
    $btnPrivacyHome.Text = Get-I18n 'buttons.privacy_scan'
    $btnMoreTools.Text = if ($script:showAdvancedTools) { Get-I18n 'buttons.less_tools' } else { Get-I18n 'buttons.more_tools' }
    $btnPkgFix.Text = Get-I18n 'buttons.pkg_fix'
    $btnNvmePlan.Text = Get-I18n 'buttons.nvme_plan'
    $btnDeepScanJump.Text = Get-I18n 'buttons.health_tab'
    $btnPartitionPlan.Text = Get-I18n 'buttons.partition_plan'
    $btnCompute.Text = Get-I18n 'buttons.compute'
    $btnApplyThrottle.Text = Get-I18n 'buttons.apply_throttle'
    $btnDefenderReview.Text = Get-I18n 'buttons.defender_review'
    $btnAudit.Text = Get-I18n 'buttons.storage_audit'
    $btnExecute.Text = Get-I18n 'buttons.storage_execute'
    $btnDiagnostics.Text = Get-I18n 'buttons.diagnostics'
    $btnCancelAnalyze.Text = Get-I18n 'buttons.cancel'
    $btnDeepScanRun.Text = Get-I18n 'buttons.run_deep_scan'
    $btnDeepApply.Text = Get-I18n 'buttons.apply_fix'
    $btnDeepExport.Text = Get-I18n 'buttons.export_report'
    $btnPrivacyRun.Text = Get-I18n 'buttons.run_privacy_scan'
    $btnPrivacyCancel.Text = Get-I18n 'buttons.cancel'
    $btnReloadTasks.Text = Get-I18n 'buttons.reload_tasks'
    $btnInstallTasks.Text = Get-I18n 'buttons.install_core'
    $btnLoadLogs.Text = Get-I18n 'buttons.load_logs'
    $btnSaveConfig.Text = Get-I18n 'buttons.save_settings'
    $btnReloadConfig.Text = Get-I18n 'buttons.reload'
    $lblDepth.Text = Get-I18n 'labels.scan_depth'
    $lblAuditLevel.Text = Get-I18n 'labels.detail'
    $lblCleanupMode.Text = Get-I18n 'labels.mode'
    $lblTop.Text = Get-I18n 'labels.top'
    $lblFixLevel.Text = Get-I18n 'labels.max_fix'
    $lblDeepFixLabel.Text = Get-I18n 'labels.max_fix'
    $lblDeepFilterLabel.Text = Get-I18n 'labels.show'
    $lblExplorerHint.Text = Get-I18n 'labels.explorer_hint'
    $lblPrivacyDesc.Text = Get-I18n 'labels.privacy_desc'
    $lblDeepScanDesc.Text = Get-I18n 'labels.deep_scan_desc'
    $lblCfgHint.Text = Get-I18n 'labels.config_hint'
    $lblCfgLang.Text = Get-I18n 'labels.language'
    $lblStatusLeft.Text = Get-I18n 'app.ready'
}

function Initialize-GuiCommandHelp {
    if (-not (Get-Command Initialize-CommandHelp -ErrorAction SilentlyContinue)) { return }

    Register-CommandHelpTextBox -TextBox $txtCommandHelp
    $map = @{
        $btnHealthAudit   = 'health_scan'
        $btnHealthApply   = 'health_apply'
        $btnAnalyze       = 'scan_storage'
        $btnQuickClean    = 'quick_clean'
        $btnPrivacyHome   = 'privacy_scan'
        $btnPrivacyRun    = 'privacy_scan'
        $btnAudit         = 'storage_audit'
        $btnExecute       = 'storage_execute'
        $btnCompute       = 'compute'
        $btnApplyThrottle = 'apply_throttle'
        $btnDefenderReview = 'defender_review'
        $btnNvmePlan      = 'nvme_plan'
        $btnPartitionPlan = 'partition_plan'
        $btnPkgFix        = 'pkg_fix'
        $btnDeepScanRun   = 'run_deep_scan'
        $btnInstallTasks  = 'install_core'
    }
    Initialize-CommandHelp -Form $form -ControlToCommandId $map
}

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
        if (Get-Command Get-MaintenanceConfig -ErrorAction SilentlyContinue) {
            $cfg = Get-MaintenanceConfig -ConfigPath $script:configPath
            $gui = Get-ConfigSection -Config $cfg -SectionName 'Gui'
            $cleanup = Get-ConfigSection -Config $cfg -SectionName 'Cleanup'
            $pp = Get-ConfigSection -Config $cfg -SectionName 'ProcessPressure'
        } else {
            $raw = Get-Content -LiteralPath $script:configPath -Raw -ErrorAction Stop | ConvertFrom-Json
            $gui = if ($raw.Gui) { $raw.Gui } else { $null }
            $cleanup = if ($raw.Cleanup) { $raw.Cleanup } else { $null }
            $pp = if ($raw.ProcessPressure) { $raw.ProcessPressure } else { $null }
            $cfg = $raw
        }
    } catch {
        Append-Status ("Config read warning: {0}" -f $_.Exception.Message)
        return
    }

    if (-not $cfg) { return }

    if ($gui) {
        $auto = if ($gui -is [hashtable]) { $gui['AutoAnalyzeOnStartup'] } else { $gui.AutoAnalyzeOnStartup }
        if ($null -ne $auto) { $script:autoAnalyzeOnStartup = [bool]$auto }

        $depth = if ($gui -is [hashtable]) { $gui['DefaultAnalyzeDepth'] } else { $gui.DefaultAnalyzeDepth }
        if ($depth -and @("Quick", "Standard", "Deep") -contains [string]$depth) {
            $script:startupAnalyzeDepth = [string]$depth
        }

        $top = if ($gui -is [hashtable]) { $gui['DefaultAnalyzeTop'] } else { $gui.DefaultAnalyzeTop }
        if ($null -ne $top) {
            $requestedTop = [int]$top
            if ($requestedTop -lt 5) { $requestedTop = 5 }
            if ($requestedTop -gt 100) { $requestedTop = 100 }
            $script:startupAnalyzeTop = $requestedTop
        }

        $cad = if ($gui -is [hashtable]) { $gui['ComputeAnalyzeDurationSec'] } else { $gui.ComputeAnalyzeDurationSec }
        if ($null -ne $cad) {
            $v = [int]$cad
            if ($v -lt 2) { $v = 2 }
            if ($v -gt 30) { $v = 30 }
            $script:computeAnalyzeDurationSec = $v
        }

        $cat = if ($gui -is [hashtable]) { $gui['ComputeAnalyzeTop'] } else { $gui.ComputeAnalyzeTop }
        if ($null -ne $cat) {
            $v = [int]$cat
            if ($v -lt 3) { $v = 3 }
            if ($v -gt 30) { $v = 30 }
            $script:computeAnalyzeTop = $v
        }

        $qrd = if ($gui -is [hashtable]) { $gui['QuickCleanupRetentionDays'] } else { $gui.QuickCleanupRetentionDays }
        if ($null -ne $qrd) {
            $v = [int]$qrd
            if ($v -lt 1) { $v = 1 }
            if ($v -gt 14) { $v = 14 }
            $script:quickCleanupRetentionDays = $v
        }

        $qmf = if ($gui -is [hashtable]) { $gui['QuickCleanupMaxFilesPerTarget'] } else { $gui.QuickCleanupMaxFilesPerTarget }
        if ($null -ne $qmf) {
            $v = [int]$qmf
            if ($v -lt 200) { $v = 200 }
            if ($v -gt 10000) { $v = 10000 }
            $script:quickCleanupMaxFilesPerTarget = $v
        }

        $diag = if ($gui -is [hashtable]) { $gui['DiagnosticRetentionDays'] } else { $gui.DiagnosticRetentionDays }
        if ($null -ne $diag) {
            $v = [int]$diag
            if ($v -lt 1) { $v = 1 }
            if ($v -gt 30) { $v = 30 }
            $script:diagnosticRetentionDays = $v
        }

        $adv = if ($gui -is [hashtable]) { $gui['ShowAdvancedTools'] } else { $gui.ShowAdvancedTools }
        if ($null -ne $adv) {
            $script:showAdvancedTools = [bool]$adv
            $pnlAdvancedTools.Visible = $script:showAdvancedTools
        }

        $lang = if ($gui -is [hashtable]) { $gui['Language'] } else { $gui.Language }
        if ($lang -and [string]$lang -match '^[a-z]{2}') {
            $script:guiLanguage = [string]$lang.ToLowerInvariant()
            if (Get-Command Initialize-I18n -ErrorAction SilentlyContinue) {
                Initialize-I18n -HubRoot $script:hubRoot -Language $script:guiLanguage
            }
        }
    }

    if ($cleanup) {
        $tr = if ($cleanup -is [hashtable]) { $cleanup['TempRetentionDays'] } else { $cleanup.TempRetentionDays }
        if ($null -ne $tr) { $script:cfgTempRetentionDays = [int]$tr }
        $lr = if ($cleanup -is [hashtable]) { $cleanup['LogRetentionDays'] } else { $cleanup.LogRetentionDays }
        if ($null -ne $lr) { $script:cfgLogRetentionDays = [int]$lr }
        $t2 = if ($cleanup -is [hashtable]) { $cleanup['Tier2'] } else { $cleanup.Tier2 }
        if ($t2) {
            $t2e = if ($t2 -is [hashtable]) { $t2['Enabled'] } else { $t2.Enabled }
            $t2s = if ($t2 -is [hashtable]) { $t2['SimulateOnly'] } else { $t2.SimulateOnly }
            if ($null -ne $t2e) { $script:cfgTier2Enabled = [bool]$t2e }
            if ($null -ne $t2s) { $script:cfgTier2SimulateOnly = [bool]$t2s }
        }
    }

    if ($pp) {
        $ost = if ($pp -is [hashtable]) { $pp['OfferSafeThrottleAfterCompute'] } else { $pp.OfferSafeThrottleAfterCompute }
        if ($null -ne $ost) { $script:offerSafeThrottleAfterCompute = [bool]$ost }
        $sdr = if ($pp -is [hashtable]) { $pp['DefenderExtreme'] } else { $pp.DefenderExtreme }
        if ($sdr) {
            $show = if ($sdr -is [hashtable]) { $sdr['ShowReviewAfterCompute'] } else { $sdr.ShowReviewAfterCompute }
            if ($null -ne $show) { $script:showDefenderReviewAfterCompute = [bool]$show }
            $minSc = if ($sdr -is [hashtable]) { $sdr['MinCompositeScoreForPrompt'] } else { $sdr.MinCompositeScoreForPrompt }
            if ($null -ne $minSc) { $script:defenderMinScoreForPrompt = [int]$minSc }
            $gw = if ($sdr -is [hashtable]) { $sdr['GuiKeepExtremeWizard'] } else { $sdr.GuiKeepExtremeWizard }
            if ($null -ne $gw) { $script:guiKeepExtremeWizard = [bool]$gw }
        }
    }
}

function Apply-ConfigControls {
    if ($null -ne $script:cfgTempRetentionDays) { $numCfgTemp.Value = [decimal]$script:cfgTempRetentionDays }
    if ($null -ne $script:cfgLogRetentionDays) { $numCfgLog.Value = [decimal]$script:cfgLogRetentionDays }
    $numCfgDiag.Value = [decimal]$script:diagnosticRetentionDays
    $chkAutoAnalyze.Checked = $script:autoAnalyzeOnStartup
    if ($null -ne $script:cfgTier2Enabled) { $chkTier2.Checked = $script:cfgTier2Enabled }
    if ($null -ne $script:cfgTier2SimulateOnly) { $chkTier2Sim.Checked = $script:cfgTier2SimulateOnly }
    $pnlAdvancedTools.Visible = $script:showAdvancedTools

    if (Get-Command Get-I18nSupportedLanguages -ErrorAction SilentlyContinue) {
        $cmbLanguage.Items.Clear()
        foreach ($lang in (Get-I18nSupportedLanguages -HubRoot $script:hubRoot)) {
            [void]$cmbLanguage.Items.Add($lang)
        }
        if ($cmbLanguage.Items.Contains($script:guiLanguage)) {
            $cmbLanguage.SelectedItem = $script:guiLanguage
        } elseif ($cmbLanguage.Items.Count -gt 0) {
            $cmbLanguage.SelectedIndex = 0
            $script:guiLanguage = [string]$cmbLanguage.SelectedItem
        }
    }
}

function Save-GuiPreferences {
    if (-not (Test-Path -LiteralPath $script:configPath)) {
        Append-Status "Config file missing; cannot save."
        return
    }

    try {
        if (-not (Get-Command Get-MaintenanceConfig -ErrorAction SilentlyContinue)) {
            throw "hub-common Get-MaintenanceConfig not loaded"
        }
        $cfg = Get-MaintenanceConfig -ConfigPath $script:configPath
        if (-not $cfg.ContainsKey('Gui') -or $null -eq $cfg['Gui']) { $cfg['Gui'] = @{} }
        if ($cfg['Gui'] -isnot [hashtable]) { $cfg['Gui'] = ConvertFrom-JsonToHashtable -InputObject $cfg['Gui'] }
        if (-not $cfg.ContainsKey('Cleanup') -or $null -eq $cfg['Cleanup']) { $cfg['Cleanup'] = @{} }
        if ($cfg['Cleanup'] -isnot [hashtable]) { $cfg['Cleanup'] = ConvertFrom-JsonToHashtable -InputObject $cfg['Cleanup'] }
        if (-not $cfg['Cleanup'].ContainsKey('Tier2') -or $null -eq $cfg['Cleanup']['Tier2']) { $cfg['Cleanup']['Tier2'] = @{} }
        if ($cfg['Cleanup']['Tier2'] -isnot [hashtable]) {
            $cfg['Cleanup']['Tier2'] = ConvertFrom-JsonToHashtable -InputObject $cfg['Cleanup']['Tier2']
        }

        $cfg['Gui']['AutoAnalyzeOnStartup'] = [bool]$chkAutoAnalyze.Checked
        $cfg['Gui']['DefaultAnalyzeDepth'] = [string]$cmbDepth.SelectedItem
        $cfg['Gui']['DefaultAnalyzeTop'] = [int]$numTop.Value
        $cfg['Gui']['ComputeAnalyzeDurationSec'] = [int]$script:computeAnalyzeDurationSec
        $cfg['Gui']['ComputeAnalyzeTop'] = [int]$script:computeAnalyzeTop
        $cfg['Gui']['QuickCleanupRetentionDays'] = [int]$script:quickCleanupRetentionDays
        $cfg['Gui']['QuickCleanupMaxFilesPerTarget'] = [int]$script:quickCleanupMaxFilesPerTarget
        $cfg['Gui']['DiagnosticRetentionDays'] = [int]$numCfgDiag.Value
        $cfg['Gui']['ShowAdvancedTools'] = [bool]$script:showAdvancedTools
        if ($cmbLanguage.SelectedItem) {
            $cfg['Gui']['Language'] = [string]$cmbLanguage.SelectedItem
        }

        $cfg['Cleanup']['TempRetentionDays'] = [int]$numCfgTemp.Value
        $cfg['Cleanup']['LogRetentionDays'] = [int]$numCfgLog.Value
        $cfg['Cleanup']['Tier2']['Enabled'] = [bool]$chkTier2.Checked
        $cfg['Cleanup']['Tier2']['SimulateOnly'] = [bool]$chkTier2Sim.Checked

        Save-MaintenanceConfig -ConfigPath $script:configPath -Config $cfg
        $script:autoAnalyzeOnStartup = [bool]$chkAutoAnalyze.Checked
        $script:diagnosticRetentionDays = [int]$numCfgDiag.Value
        $script:cfgTempRetentionDays = [int]$numCfgTemp.Value
        $script:cfgLogRetentionDays = [int]$numCfgLog.Value
        $script:cfgTier2Enabled = [bool]$chkTier2.Checked
        $script:cfgTier2SimulateOnly = [bool]$chkTier2Sim.Checked
        Append-Status "Configuration saved to sys-maintenance.json (hub-common)"
    } catch {
        Append-Status ("Config save failed: {0}" -f $_.Exception.Message)
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
    $names = @('SystemResourceMonitor', 'SystemOptimizerHub-Orchestrator', 'StorageCleanupSafe')

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
    if ($script:nvmeAdvisorProcess -and (-not $script:nvmeAdvisorProcess.HasExited)) { $busy = $true }
    if ($script:partitionLegacyProcess -and (-not $script:partitionLegacyProcess.HasExited)) { $busy = $true }
    if ($script:coreInstallProcess -and (-not $script:coreInstallProcess.HasExited)) { $busy = $true }
    if ($script:deepScanProcess -and (-not $script:deepScanProcess.HasExited)) { $busy = $true }
    if ($script:deepScanApplyProcess -and (-not $script:deepScanApplyProcess.HasExited)) { $busy = $true }
    if ($script:privacyProcess -and (-not $script:privacyProcess.HasExited)) { $busy = $true }
    if (Get-Command Test-AnyHubAsyncWorkerRunning -ErrorAction SilentlyContinue) {
        if (Test-AnyHubAsyncWorkerRunning) { $busy = $true }
    }

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
    $btnApplyThrottle.Enabled = -not $IsBusy
    $btnDefenderReview.Enabled = -not $IsBusy
    $btnQuickClean.Enabled = -not $IsBusy
    $btnHealthAudit.Enabled = -not $IsBusy
    $btnPkgFix.Enabled = -not $IsBusy
    $btnNvmePlan.Enabled = -not $IsBusy
    $btnPartitionPlan.Enabled = -not $IsBusy
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
    $btnPrivacyHome.Enabled  = -not $IsBusy
    $btnPrivacyRun.Enabled   = -not $IsBusy
    $btnPrivacyCancel.Enabled = $IsBusy
    $btnPrivacyCancel.ForeColor = if ($IsBusy) { $clrRed } else { $clrMuted }
    $btnMoreTools.Enabled    = -not $IsBusy
    $btnHealthApply.Enabled  = -not $IsBusy

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

    $analysisExitCode = -1
    if (Get-Command Complete-HubAsyncWorker -ErrorAction SilentlyContinue) {
        $done = Complete-HubAsyncWorker -Name 'garbage'
        if ($done) { $analysisExitCode = [int]$done.ExitCode }
        else { $analysisExitCode = Get-ProcessExitCodeSafe -Process $script:analysisProcess }
    } else {
        $analysisExitCode = Get-ProcessExitCodeSafe -Process $script:analysisProcess
    }
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
                $priority = if ($proc.PSObject.Properties['Priority']) { [string]$proc.Priority } else { 'Review' }
                $necessity = if ($proc.PSObject.Properties['Necessity']) { [string]$proc.Necessity } else { 'Unknown' }
                $rec = if ($proc.PSObject.Properties['Recommendation']) { [string]$proc.Recommendation } else { 'Observe' }
                $computeSummary = "Compute Top PID={0} Name={1} Score={2} CPU={3}% RAM={4}MB IO={5}MB/s Pressure={6} Necessity={7} Priority={8} Action={9}" -f 
                    [int]$proc.PID,
                    [string]$proc.ProcessName,
                    [decimal]$proc.Score,
                    [decimal]$proc.CpuPercent,
                    [decimal]$proc.WorkingSetMB,
                    [decimal]$proc.IoMBps,
                    [string]$proc.DominantPressure,
                    $necessity,
                    $priority,
                    $rec
                Append-Status $computeSummary
            }
            if ($computeResult.PSObject.Properties['Summary']) {
                $s = $computeResult.Summary
                Append-Status ("Process pressure summary: high={0} vital={1} autoEligible={2} hitl={3}" -f `
                    [int]$s.HighPressureCount, [int]$s.VitalPreserved, [int]$s.AutoEligibleCount, [int]$s.HitlRequiredCount)

                if ($script:offerSafeThrottleAfterCompute -and [int]$s.AutoEligibleCount -gt 0) {
                    $msg = if ($script:guiLanguage -eq 'it') {
                        "Trovati {0} processi con throttle safe reversibile.`n`nApplicare ora (solo BelowNormal, esclusi vitali)?" -f [int]$s.AutoEligibleCount
                    } else {
                        "Found {0} process(es) eligible for reversible safe throttle.`n`nApply now (BelowNormal only, vitals excluded)?" -f [int]$s.AutoEligibleCount
                    }
                    $ans = [System.Windows.Forms.MessageBox]::Show($msg, (Get-I18n 'buttons.apply_throttle'), "YesNo", "Question")
                    if ($ans -eq 'Yes') { Run-ApplySafeThrottle -SkipConfirm }
                }
            }

            $defRow = $topRows | Where-Object { [string]$_.ProcessName -eq 'MsMpEng' } | Select-Object -First 1
            if ($defRow -and $script:showDefenderReviewAfterCompute -and [double]$defRow.Score -ge $script:defenderMinScoreForPrompt) {
                Append-Status ("Defender MsMpEng elevated: Score={0} CPU={1}% IO={2}MB/s — use Defender button for deterministic tier review." -f `
                    [decimal]$defRow.Score, [decimal]$defRow.CpuPercent, [decimal]$defRow.IoMBps)
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
    $timeoutSec = if ($script:healthApplyInProgress) {
        [math]::Max(1, $script:healthApplyTimeoutSec)
    } else {
        [math]::Max(1, $script:healthAuditTimeoutSec)
    }
    $label = if ($script:healthApplyInProgress) { 'Applying fixes' } else { 'Health Audit' }
    $pct = [math]::Min(95, [int](($elapsedSec / $timeoutSec) * 100))
    if ($pct -lt $progressAnalysis.Minimum) { $pct = $progressAnalysis.Minimum }
    if ($pct -gt $progressAnalysis.Maximum) { $pct = $progressAnalysis.Maximum }
    $progressAnalysis.Value = $pct
    $script:spinIdx = ($script:spinIdx + 1) % $script:spinFrames.Count
    $lblAnalysisState.Text = ("{0}{1}  {2}s / {3}s" -f $label, $script:spinFrames[$script:spinIdx], $elapsedSec, $timeoutSec)
    if (($elapsedSec -gt $timeoutSec) -and (-not $script:healthAuditSoftTimeoutWarned)) {
        $script:healthAuditSoftTimeoutWarned = $true
        Append-Status ("{0} exceeded expected time ({1}s). No forced stop; cancel manually if needed." -f $label, $timeoutSec)
    }
}

function Stop-HealthAudit {
    param([string]$Reason)
    if ($script:healthAuditProcess -and (-not $script:healthAuditProcess.HasExited)) {
        try {
            Stop-Process -Id $script:healthAuditProcess.Id -Force -ErrorAction Stop
            Append-Status ($(if ($script:healthApplyInProgress) { "Apply fixes stopped. Reason: {0}" } else { "Health Audit stopped. Reason: {0}" }) -f $Reason)
        } catch {
            Append-Status ("Unable to stop health worker cleanly: {0}" -f $_.Exception.Message)
        }
    }
    $healthAuditTimer.Stop()
    $healthApplyTimer.Stop()
    $script:healthAuditProcess = $null
    $script:healthAuditStartedAt = $null
    $script:healthAuditSoftTimeoutWarned = $false
    $script:healthAuditApplyAfter = $false
    $script:healthAuditApplyPackagesOnly = $false
    $script:healthAuditApplyFindingIds = @()
    $script:healthApplyInProgress = $false
    Set-AnalysisUiState -IsBusy:$false -StateText "Health idle"
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
    $exitCode = -1
    if (Get-Command Complete-HubAsyncWorker -ErrorAction SilentlyContinue) {
        $done = Complete-HubAsyncWorker -Name 'health-audit'
        if ($done) { $exitCode = [int]$done.ExitCode }
        else { $exitCode = Get-ProcessExitCodeSafe -Process $script:healthAuditProcess }
    } else {
        $exitCode = Get-ProcessExitCodeSafe -Process $script:healthAuditProcess
    }
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
    $applyPackagesOnly = $script:healthAuditApplyPackagesOnly
    $applyFindingIds = @()

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
                Append-Status ("  Already optimized: {0}" -f (Format-AlreadyOptimizedLog -Items $auditResult.AlreadyOptimized))
            }

            if ($applyPackagesOnly) {
                $applyFindingIds = @($auditResult.Findings | Where-Object { [string]$_.Id -like 'PKG-*' } | ForEach-Object { [string]$_.Id })
                if ($applyFindingIds.Count -eq 0) {
                    Append-Status "Required packages already compliant. No PKG-* fixes to apply."
                    $shouldApply = $false
                } else {
                    Append-Status ("Package-only remediation queue: {0}" -f ($applyFindingIds -join ', '))
                }
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
    $script:healthAuditApplyPackagesOnly = $false
    $script:healthAuditApplyFindingIds = @()

    if ($shouldApply) {
        if ($applyPackagesOnly -and $applyFindingIds.Count -gt 0) {
            Append-Status "Auto-applying package prerequisite fixes (Safe level)."
            Run-HealthApply -MaxLevel 'Safe' -FindingIds $applyFindingIds
        } else {
            Append-Status ("Auto-applying fixes at level: {0}" -f $applyLevel)
            Run-HealthApply -MaxLevel $applyLevel
        }
    } else {
        Set-AnalysisUiState -IsBusy:$false -StateText $lblAnalysisState.Text
    }
}

function Run-HealthAudit {
    param(
        [switch]$ApplyAfter,
        [switch]$ApplyPackagesOnly
    )

    if (-not (Test-Path -LiteralPath $script:healthAuditScript)) {
        Append-Status "Health audit script not found: $script:healthAuditScript"
        return
    }
    if (Test-AnyOperationRunning) {
        Append-Status "Another operation is already running. Wait for completion."
        return
    }
    try {
        $script:healthAuditSoftTimeoutWarned = $false
        $script:healthAuditApplyAfter = [bool]$ApplyAfter
        $script:healthAuditApplyPackagesOnly = [bool]$ApplyPackagesOnly
        $script:healthAuditApplyFindingIds = @()
        $script:healthApplyInProgress = $false
        $script:healthAuditMaxLevel = if ($ApplyPackagesOnly) { 'Safe' } else { [string]$cmbFixLevel.SelectedItem }

        $started = $false
        if (Get-Command Start-HubAsyncWorker -ErrorAction SilentlyContinue) {
            $started = Start-HubAsyncWorker -Name 'health-audit' `
                -PsHost $script:psHost `
                -ScriptPath $script:healthAuditScript `
                -ExtraArgs @('-OutputJson', $script:healthAuditJson) `
                -OutputPaths @($script:healthAuditJson, $script:healthAuditStdOut, $script:healthAuditStdErr) `
                -StdOutPath $script:healthAuditStdOut `
                -StdErrPath $script:healthAuditStdErr `
                -TimeoutSec $script:healthAuditTimeoutSec
            if ($started) {
                $w = Get-HubAsyncWorker -Name 'health-audit'
                $script:healthAuditProcess = $w.Process
                $script:healthAuditStartedAt = $w.StartedAt
            }
        } else {
            Remove-IfExists -Path $script:healthAuditJson
            Remove-IfExists -Path $script:healthAuditStdOut
            Remove-IfExists -Path $script:healthAuditStdErr
            $args = @(
                "-NoProfile", "-ExecutionPolicy", "Bypass",
                "-File", $script:healthAuditScript,
                "-OutputJson", $script:healthAuditJson
            )
            $script:healthAuditStartedAt = Get-Date
            $script:healthAuditProcess = Start-Process -FilePath $script:psHost -ArgumentList $args -WindowStyle Hidden -RedirectStandardOutput $script:healthAuditStdOut -RedirectStandardError $script:healthAuditStdErr -PassThru
            $started = ($null -ne $script:healthAuditProcess)
        }

        if (-not $started) {
            Append-Status "Health Audit failed to start."
            Set-AnalysisUiState -IsBusy:$false -StateText "Health Audit idle"
            return
        }

        $progressAnalysis.Value = 1
        Set-AnalysisUiState -IsBusy:$true -StateText ("Health Audit starting (target {0}s)..." -f $script:healthAuditTimeoutSec)
        $healthAuditTimer.Start()
        if ($ApplyPackagesOnly) {
            Append-Status "Health Audit started for package prerequisite remediation flow."
        } else {
            Append-Status "Health Audit started in background."
        }
    } catch {
        Append-Status ("Health Audit error: {0}" -f $_.Exception.Message)
        $script:healthAuditProcess = $null
        $script:healthAuditStartedAt = $null
        $script:healthAuditSoftTimeoutWarned = $false
        $script:healthAuditApplyAfter = $false
        $script:healthAuditApplyPackagesOnly = $false
        $script:healthAuditApplyFindingIds = @()
        Set-AnalysisUiState -IsBusy:$false -StateText "Health Audit idle"
    }
}

function Run-HealthApply {
    param(
        [string]$MaxLevel = 'Safe',
        [string[]]$FindingIds
    )

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
        if ($FindingIds -and $FindingIds.Count -gt 0) {
            $args += "-FindingIds"
            $args += @($FindingIds)
        }
        $script:healthAuditStartedAt = Get-Date
        $script:healthAuditSoftTimeoutWarned = $false
        $script:healthAuditApplyAfter = $false
        $script:healthAuditApplyPackagesOnly = $false
        $script:healthAuditApplyFindingIds = @()
        $script:healthApplyInProgress = $true
        $script:healthAuditProcess = Start-Process -FilePath $script:psHost -ArgumentList $args -WindowStyle Hidden -RedirectStandardOutput $script:healthAuditStdOut -RedirectStandardError $script:healthAuditStdErr -PassThru
        $progressAnalysis.Value = 1
        Set-AnalysisUiState -IsBusy:$true -StateText ("Applying {0} fixes..." -f $MaxLevel)
        $healthApplyTimer.Start()
        if ($FindingIds -and $FindingIds.Count -gt 0) {
            Append-Status ("Applying {0}-level fixes for selected findings: {1}" -f $MaxLevel, ($FindingIds -join ', '))
        } else {
            Append-Status ("Applying {0}-level fixes in background." -f $MaxLevel)
        }
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
        $script:healthApplyInProgress = $false
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
    $script:healthApplyInProgress = $false
    Set-AnalysisUiState -IsBusy:$false -StateText ("Fixes applied in {0}s." -f $durationSec)
}

function Update-NvmeAdvisorProgress {
    if (-not $script:nvmeAdvisorStartedAt) { return }
    $elapsedSec = [math]::Round(((Get-Date) - $script:nvmeAdvisorStartedAt).TotalSeconds, 0)
    $timeoutSec = [math]::Max(1, $script:nvmeAdvisorTimeoutSec)
    $pct = [math]::Min(95, [int](($elapsedSec / $timeoutSec) * 100))
    if ($pct -lt $progressAnalysis.Minimum) { $pct = $progressAnalysis.Minimum }
    if ($pct -gt $progressAnalysis.Maximum) { $pct = $progressAnalysis.Maximum }
    $progressAnalysis.Value = $pct
    $script:spinIdx = ($script:spinIdx + 1) % $script:spinFrames.Count
    $lblAnalysisState.Text = ("NVMe Plan{0}  {1}s / {2}s" -f $script:spinFrames[$script:spinIdx], $elapsedSec, $timeoutSec)
    if (($elapsedSec -gt $timeoutSec) -and (-not $script:nvmeAdvisorSoftTimeoutWarned)) {
        $script:nvmeAdvisorSoftTimeoutWarned = $true
        Append-Status ("NVMe Plan exceeded expected time ({0}s). No forced stop; cancel manually if needed." -f $timeoutSec)
    }
}

function Stop-NvmeAdvisor {
    param([string]$Reason)
    if ($script:nvmeAdvisorProcess -and (-not $script:nvmeAdvisorProcess.HasExited)) {
        try {
            Stop-Process -Id $script:nvmeAdvisorProcess.Id -Force -ErrorAction Stop
            Append-Status ("NVMe Plan stopped. Reason: {0}" -f $Reason)
        } catch {
            Append-Status ("Unable to stop NVMe Plan cleanly: {0}" -f $_.Exception.Message)
        }
    }
    $nvmeAdvisorTimer.Stop()
    $script:nvmeAdvisorProcess = $null
    $script:nvmeAdvisorStartedAt = $null
    $script:nvmeAdvisorSoftTimeoutWarned = $false
    Set-AnalysisUiState -IsBusy:$false -StateText "NVMe Plan idle"
}

function Poll-NvmeAdvisor {
    if (-not $script:nvmeAdvisorProcess) { return }
    if (-not $script:nvmeAdvisorProcess.HasExited) {
        Update-NvmeAdvisorProgress
        return
    }

    $nvmeAdvisorTimer.Stop()
    $durationSec = 0
    if ($script:nvmeAdvisorStartedAt) {
        $durationSec = [math]::Round(((Get-Date) - $script:nvmeAdvisorStartedAt).TotalSeconds, 1)
    }
    $exitCode = Get-ProcessExitCodeSafe -Process $script:nvmeAdvisorProcess
    if ($exitCode -ne 0) {
        $errTail = Get-WorkerErrorTail -ErrorPath $script:nvmeAdvisorStdErr
        if ($errTail) {
            Append-Status ("NVMe Plan ended with exit code {0}. Error: {1}" -f $exitCode, $errTail)
        } else {
            Append-Status ("NVMe Plan ended with exit code {0}." -f $exitCode)
        }
        $script:nvmeAdvisorProcess = $null
        $script:nvmeAdvisorStartedAt = $null
        $script:nvmeAdvisorSoftTimeoutWarned = $false
        Set-AnalysisUiState -IsBusy:$false -StateText "NVMe Plan idle"
        return
    }

    if (Wait-ForOutputFile -Path $script:nvmeAdvisorJson -TimeoutMs 4000) {
        try {
            $advisor = Get-Content -LiteralPath $script:nvmeAdvisorJson -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $risk = [string]$advisor.Assessment.RiskLevel
            $decision = [string]$advisor.BestNextDecision
            $targetDrive = [string]$advisor.TargetDrive
            $writeDrive = [string]$advisor.RecommendedWriteDrive
            Append-Status ("NVMe Plan completed in {0}s. Risk={1}. Target={2} WriteDrive={3}" -f $durationSec, $risk, $targetDrive, $writeDrive)
            Append-Status ("  Best next decision: {0}" -f $decision)
            if ($advisor.WriteOffloadPlan -and $advisor.WriteOffloadPlan.Steps) {
                foreach ($step in $advisor.WriteOffloadPlan.Steps) {
                    Append-Status ("  Step {0}: {1}" -f [int]$step.Step, [string]$step.Title)
                }
            }

            $toastLevel = if ($risk -eq 'Critical') { 'Warning' } else { 'Success' }
            Show-Toast -Title "NVMe Plan Ready" -Body ("Risk {0} - see status feed ({1}s)" -f $risk, $durationSec) -Level $toastLevel
        } catch {
            Append-Status ("NVMe Plan completed in {0}s but parse failed: {1}" -f $durationSec, $_.Exception.Message)
        }
    } else {
        Append-Status ("NVMe Plan completed in {0}s but output JSON was not found." -f $durationSec)
    }

    $progressAnalysis.Value = 100
    $lblAnalysisState.Text = ("NVMe Plan completed in {0}s." -f $durationSec)
    $script:nvmeAdvisorProcess = $null
    $script:nvmeAdvisorStartedAt = $null
    $script:nvmeAdvisorSoftTimeoutWarned = $false
    Set-AnalysisUiState -IsBusy:$false -StateText $lblAnalysisState.Text
}

function Run-NvmeAdvisor {
    if (-not (Test-Path -LiteralPath $script:nvmeAdvisorScript)) {
        Append-Status "NVMe advisor script not found: $script:nvmeAdvisorScript"
        return
    }
    if (Test-AnyOperationRunning) {
        Append-Status "Another operation is already running. Wait for completion."
        return
    }

    try {
        Remove-IfExists -Path $script:nvmeAdvisorJson
        Remove-IfExists -Path $script:nvmeAdvisorStdOut
        Remove-IfExists -Path $script:nvmeAdvisorStdErr

        $args = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $script:nvmeAdvisorScript,
            "-OutputJson", $script:nvmeAdvisorJson
        )

        $script:nvmeAdvisorStartedAt = Get-Date
        $script:nvmeAdvisorSoftTimeoutWarned = $false
        $script:nvmeAdvisorProcess = Start-Process -FilePath $script:psHost -ArgumentList $args -WindowStyle Hidden -RedirectStandardOutput $script:nvmeAdvisorStdOut -RedirectStandardError $script:nvmeAdvisorStdErr -PassThru
        $progressAnalysis.Value = 1
        Set-AnalysisUiState -IsBusy:$true -StateText ("NVMe Plan starting (target {0}s)..." -f $script:nvmeAdvisorTimeoutSec)
        $nvmeAdvisorTimer.Start()
        Append-Status "NVMe Plan started in background."
    } catch {
        Append-Status ("NVMe Plan error: {0}" -f $_.Exception.Message)
        $script:nvmeAdvisorProcess = $null
        $script:nvmeAdvisorStartedAt = $null
        $script:nvmeAdvisorSoftTimeoutWarned = $false
        Set-AnalysisUiState -IsBusy:$false -StateText "NVMe Plan idle"
    }
}

function Update-PartitionLegacyProgress {
    if (-not $script:partitionLegacyStartedAt) { return }
    $elapsedSec = [math]::Round(((Get-Date) - $script:partitionLegacyStartedAt).TotalSeconds, 0)
    $timeoutSec = [math]::Max(1, $script:partitionLegacyTimeoutSec)
    $pct = [math]::Min(95, [int](($elapsedSec / $timeoutSec) * 100))
    if ($pct -lt $progressAnalysis.Minimum) { $pct = $progressAnalysis.Minimum }
    if ($pct -gt $progressAnalysis.Maximum) { $pct = $progressAnalysis.Maximum }
    $progressAnalysis.Value = $pct
    $script:spinIdx = ($script:spinIdx + 1) % $script:spinFrames.Count
    $lblAnalysisState.Text = ("Partition Plan{0}  {1}s / {2}s" -f $script:spinFrames[$script:spinIdx], $elapsedSec, $timeoutSec)
    if (($elapsedSec -gt $timeoutSec) -and (-not $script:partitionLegacySoftTimeoutWarned)) {
        $script:partitionLegacySoftTimeoutWarned = $true
        Append-Status ("Partition Plan exceeded expected time ({0}s). No forced stop; cancel manually if needed." -f $timeoutSec)
    }
}

function Stop-PartitionLegacy {
    param([string]$Reason)
    if ($script:partitionLegacyProcess -and (-not $script:partitionLegacyProcess.HasExited)) {
        try {
            Stop-Process -Id $script:partitionLegacyProcess.Id -Force -ErrorAction Stop
            Append-Status ("Partition Plan stopped. Reason: {0}" -f $Reason)
        } catch {
            Append-Status ("Unable to stop Partition Plan cleanly: {0}" -f $_.Exception.Message)
        }
    }
    $partitionLegacyTimer.Stop()
    $script:partitionLegacyProcess = $null
    $script:partitionLegacyStartedAt = $null
    $script:partitionLegacySoftTimeoutWarned = $false
    $script:partitionLegacyApplyRequested = $false
    Set-AnalysisUiState -IsBusy:$false -StateText "Partition Plan idle"
}

function Update-CoreInstallProgress {
    if (-not $script:coreInstallStartedAt) { return }
    $elapsedSec = [math]::Round(((Get-Date) - $script:coreInstallStartedAt).TotalSeconds, 0)
    $timeoutSec = [math]::Max(1, $script:coreInstallTimeoutSec)
    $pct = [math]::Min(95, [int](($elapsedSec / $timeoutSec) * 100))
    if ($pct -lt $progressAnalysis.Minimum) { $pct = $progressAnalysis.Minimum }
    if ($pct -gt $progressAnalysis.Maximum) { $pct = $progressAnalysis.Maximum }
    $progressAnalysis.Value = $pct
    $script:spinIdx = ($script:spinIdx + 1) % $script:spinFrames.Count
    $lblAnalysisState.Text = ("Core Install{0}  {1}s / {2}s" -f $script:spinFrames[$script:spinIdx], $elapsedSec, $timeoutSec)
}

function Stop-CoreInstall {
    param([string]$Reason)

    if ($script:coreInstallProcess -and (-not $script:coreInstallProcess.HasExited)) {
        try {
            Stop-Process -Id $script:coreInstallProcess.Id -Force -ErrorAction Stop
            Append-Status ("Core Install stopped. Reason: {0}" -f $Reason)
        } catch {
            Append-Status ("Unable to stop Core Install cleanly: {0}" -f $_.Exception.Message)
        }
    }

    $coreInstallTimer.Stop()
    $script:coreInstallProcess = $null
    $script:coreInstallStartedAt = $null
    Set-AnalysisUiState -IsBusy:$false -StateText "Core Install idle"
}

function Poll-CoreInstall {
    if (-not $script:coreInstallProcess) { return }
    if (-not $script:coreInstallProcess.HasExited) {
        Update-CoreInstallProgress
        return
    }

    $coreInstallTimer.Stop()
    $durationSec = 0
    if ($script:coreInstallStartedAt) {
        $durationSec = [math]::Round(((Get-Date) - $script:coreInstallStartedAt).TotalSeconds, 1)
    }
    $exitCode = Get-ProcessExitCodeSafe -Process $script:coreInstallProcess
    if ($exitCode -ne 0) {
        $errTail = Get-WorkerErrorTail -ErrorPath $script:coreInstallStdErr

        # Parse structured tokens from stdout to surface actionable guidance
        $stdoutLines = @()
        if (Test-Path -LiteralPath $script:coreInstallStdOut) {
            try { $stdoutLines = Get-Content -LiteralPath $script:coreInstallStdOut -ErrorAction SilentlyContinue } catch {}
        }
        $fallbackUrl = $stdoutLines | Where-Object { $_ -match "^INSTALL_FALLBACK_URL:|^INSTALL_EXTERNAL_URL:" } | Select-Object -Last 1
        $externalFailed = $stdoutLines | Where-Object { $_ -match "^INSTALL_EXTERNAL_FAILED:" } | Select-Object -Last 1
        $installFailed = $stdoutLines | Where-Object { $_ -match "^INSTALL_FAILED:" } | Select-Object -Last 1

        if ($fallbackUrl) {
            $url = ($fallbackUrl -replace "^INSTALL_FALLBACK_URL:\s*|^INSTALL_EXTERNAL_URL:\s*", "").Trim()
            Append-Status "ERRORE Core Install: percorso installazione automatica non riuscito su questo host."
            if ($externalFailed) {
                Append-Status ("Dettaglio: {0}" -f ($externalFailed -replace "^INSTALL_EXTERNAL_FAILED:\s*", ""))
            }
            Append-Status "Azione: usa installer esterno PowerShell 7."
            Append-Status ("Download diretto: {0}" -f $url)
            Append-Status "Dopo installazione manuale, premi di nuovo 'Install Core'."
        } elseif ($installFailed) {
            Append-Status ("Core Install fallito: {0}" -f ($installFailed -replace "^INSTALL_FAILED:\s*", ""))
        } else {
            Append-Status ("Core Install ended with exit code {0}. {1}" -f $exitCode, $errTail)
        }

        $script:coreInstallProcess = $null
        $script:coreInstallStartedAt = $null
        Set-AnalysisUiState -IsBusy:$false -StateText "Core Install failed"
        return
    }

    Append-Status ("Core Install completed in {0}s." -f $durationSec)
    Reload-Tasks
    if ($script:transparencyUi -and $script:transparencyUi.Refresh) {
        & $script:transparencyUi.Refresh
    }
    $progressAnalysis.Value = 100
    $script:coreInstallProcess = $null
    $script:coreInstallStartedAt = $null
    Set-AnalysisUiState -IsBusy:$false -StateText ("Core Install completed in {0}s." -f $durationSec)
}

function Run-CoreInstall {
    if (-not (Test-Path -LiteralPath $script:coreScript)) {
        Append-Status "Core bootstrap script not found: $script:coreScript"
        return
    }
    if (Test-AnyOperationRunning) {
        Append-Status "Another operation is already running. Wait for completion."
        return
    }

    try {
        Remove-IfExists -Path $script:coreInstallStdOut
        Remove-IfExists -Path $script:coreInstallStdErr

        $args = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $script:coreScript,
            "-InstallIfMissing",
            "-ApplyTasksCoreOnly",
            "-MonitorInstallerPath", $script:monitorInstaller,
            "-CleanupInstallerPath", $script:cleanupInstaller
        )

        $script:coreInstallStartedAt = Get-Date
        $script:coreInstallProcess = Start-Process -FilePath $script:psHost -ArgumentList $args -WindowStyle Hidden -RedirectStandardOutput $script:coreInstallStdOut -RedirectStandardError $script:coreInstallStdErr -PassThru
        $progressAnalysis.Value = 1
        Set-AnalysisUiState -IsBusy:$true -StateText ("Core Install starting (target {0}s)..." -f $script:coreInstallTimeoutSec)
        $coreInstallTimer.Start()
        Append-Status "Core Install started in background."
    } catch {
        Append-Status ("Core Install error: {0}" -f $_.Exception.Message)
        $script:coreInstallProcess = $null
        $script:coreInstallStartedAt = $null
        Set-AnalysisUiState -IsBusy:$false -StateText "Core Install idle"
    }
}

function Poll-PartitionLegacy {
    if (-not $script:partitionLegacyProcess) { return }
    if (-not $script:partitionLegacyProcess.HasExited) {
        Update-PartitionLegacyProgress
        return
    }

    $partitionLegacyTimer.Stop()
    $durationSec = 0
    if ($script:partitionLegacyStartedAt) {
        $durationSec = [math]::Round(((Get-Date) - $script:partitionLegacyStartedAt).TotalSeconds, 1)
    }
    $exitCode = Get-ProcessExitCodeSafe -Process $script:partitionLegacyProcess
    if ($exitCode -ne 0) {
        $errTail = Get-WorkerErrorTail -ErrorPath $script:partitionLegacyStdErr
        if ($errTail) {
            Append-Status ("Partition Plan ended with exit code {0}. Error: {1}" -f $exitCode, $errTail)
        } else {
            Append-Status ("Partition Plan ended with exit code {0}." -f $exitCode)
        }
        $script:partitionLegacyProcess = $null
        $script:partitionLegacyStartedAt = $null
        $script:partitionLegacySoftTimeoutWarned = $false
        $script:partitionLegacyApplyRequested = $false
        Set-AnalysisUiState -IsBusy:$false -StateText "Partition Plan idle"
        return
    }

    if (Wait-ForOutputFile -Path $script:partitionLegacyJson -TimeoutMs 4000) {
        try {
            $plan = Get-Content -LiteralPath $script:partitionLegacyJson -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $isLegacy = [bool]$plan.Assessment.DeterministicLegacy
            $class = [string]$plan.Assessment.Classification
            $decision = [string]$plan.Assessment.BestNextDecision
            $applied = [bool]$plan.Remediation.Applied
            Append-Status ("Partition Plan completed in {0}s. Classification={1} DeterministicLegacy={2} Applied={3}" -f $durationSec, $class, $isLegacy, $applied)
            Append-Status ("  Best next decision: {0}" -f $decision)
            foreach ($ev in $plan.Assessment.Evidence) {
                $badge = if ([bool]$ev.Passed) { "OK" } else { "BLOCK" }
                Append-Status ("  [{0}] {1} - {2}" -f $badge, [string]$ev.Name, [string]$ev.Detail)
            }
            if ($plan.Remediation.Actions) {
                foreach ($action in $plan.Remediation.Actions) {
                    Append-Status ("  APPLY: {0}" -f [string]$action)
                }
            }
            if ($plan.Remediation.Error) {
                Append-Status ("  Apply error: {0}" -f [string]$plan.Remediation.Error)
            }
            $toastLevel = if ($isLegacy) { "Warning" } else { "Info" }
            if ($applied) { $toastLevel = "Success" }
            Show-Toast -Title "Partition Plan Done" -Body ("{0} (Applied={1})" -f $class, $applied) -Level $toastLevel
        } catch {
            Append-Status ("Partition Plan completed in {0}s but parse failed: {1}" -f $durationSec, $_.Exception.Message)
        }
    } else {
        Append-Status ("Partition Plan completed in {0}s but output JSON was not found." -f $durationSec)
    }

    Refresh-Drives
    $progressAnalysis.Value = 100
    $lblAnalysisState.Text = ("Partition Plan completed in {0}s." -f $durationSec)
    $script:partitionLegacyProcess = $null
    $script:partitionLegacyStartedAt = $null
    $script:partitionLegacySoftTimeoutWarned = $false
    $script:partitionLegacyApplyRequested = $false
    Set-AnalysisUiState -IsBusy:$false -StateText $lblAnalysisState.Text
}

function Run-PartitionLegacy {
    param([switch]$ApplyIfLegacy)

    if (-not (Test-Path -LiteralPath $script:partitionLegacyScript)) {
        Append-Status "Partition plan script not found: $script:partitionLegacyScript"
        return
    }
    if (Test-AnyOperationRunning) {
        Append-Status "Another operation is already running. Wait for completion."
        return
    }

    try {
        Remove-IfExists -Path $script:partitionLegacyJson
        Remove-IfExists -Path $script:partitionLegacyStdOut
        Remove-IfExists -Path $script:partitionLegacyStdErr

        $args = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $script:partitionLegacyScript,
            "-DiskNumber", "1",
            "-CandidatePartitionNumber", "4",
            "-TargetPartitionNumber", "3",
            "-OutputJson", $script:partitionLegacyJson
        )
        if ($ApplyIfLegacy) {
            $args += "-ApplyIfLegacy"
        }

        $script:partitionLegacyStartedAt = Get-Date
        $script:partitionLegacySoftTimeoutWarned = $false
        $script:partitionLegacyApplyRequested = [bool]$ApplyIfLegacy
        $script:partitionLegacyProcess = Start-Process -FilePath $script:psHost -ArgumentList $args -WindowStyle Hidden -RedirectStandardOutput $script:partitionLegacyStdOut -RedirectStandardError $script:partitionLegacyStdErr -PassThru
        $progressAnalysis.Value = 1
        $state = if ($ApplyIfLegacy) { "Partition Plan apply starting" } else { "Partition Plan audit starting" }
        Set-AnalysisUiState -IsBusy:$true -StateText ("{0} (target {1}s)..." -f $state, $script:partitionLegacyTimeoutSec)
        $partitionLegacyTimer.Start()
        if ($ApplyIfLegacy) {
            Append-Status "Partition Plan started in APPLY mode (only if deterministic legacy checks pass)."
        } else {
            Append-Status "Partition Plan started in AUDIT mode."
        }
    } catch {
        Append-Status ("Partition Plan error: {0}" -f $_.Exception.Message)
        $script:partitionLegacyProcess = $null
        $script:partitionLegacyStartedAt = $null
        $script:partitionLegacySoftTimeoutWarned = $false
        $script:partitionLegacyApplyRequested = $false
        Set-AnalysisUiState -IsBusy:$false -StateText "Partition Plan idle"
    }
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
            [void]$result.Add([pscustomobject]@{
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
    return $result.ToArray()
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
        $kind = if ($sol.Kind) { [string]$sol.Kind } else { 'Script' }
        $si = New-Object System.Windows.Forms.ListViewItem([string]$sol.Level)
        [void]$si.SubItems.Add($kind)
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

function Populate-PrivacyFindings {
    param([array]$Findings)

    $listPrivacyFindings.Items.Clear()
    $txtPrivacyDetail.Text = ""

    foreach ($row in $Findings) {
        $item = New-Object System.Windows.Forms.ListViewItem([string]$row.Severity)
        [void]$item.SubItems.Add([string]$row.Category)
        [void]$item.SubItems.Add([string]$row.PatternId)
        [void]$item.SubItems.Add([string]$row.FilePath)
        [void]$item.SubItems.Add([string]$row.LineNumber)
        [void]$item.SubItems.Add([string]$row.RedactedPreview)
        $item.Tag = $row

        switch ([string]$row.Severity) {
            "Critical" { $item.ForeColor = $clrTxtHigh }
            "Important" { $item.ForeColor = $clrTxtAmber }
            default { $item.ForeColor = $clrText }
        }

        $listPrivacyFindings.Items.Add($item) | Out-Null
    }
}

function Update-PrivacyProgress {
    $w = $null
    if (Get-Command Get-HubAsyncWorker -ErrorAction SilentlyContinue) {
        $w = Get-HubAsyncWorker -Name 'privacy'
    }
    if (-not $w -or -not $w.StartedAt) {
        if (-not $script:privacyStartedAt) { return }
        $elapsedSec = [math]::Round(((Get-Date) - $script:privacyStartedAt).TotalSeconds, 0)
        $timeoutSec = [math]::Max(1, $script:privacyTimeoutSec)
        $script:spinIdx = ($script:spinIdx + 1) % $script:spinFrames.Count
        $lblPrivacyState.Text = ("Privacy scan{0}  {1}s / {2}s" -f $script:spinFrames[$script:spinIdx], $elapsedSec, $timeoutSec)
        if (($elapsedSec -gt $timeoutSec) -and (-not $script:privacySoftTimeoutWarned)) {
            $script:privacySoftTimeoutWarned = $true
            Append-Status ("Privacy scan exceeded expected time ({0}s)." -f $timeoutSec)
        }
        return
    }

    $timeoutSec = [math]::Max(1, [int]$w.TimeoutSec)
    $info = Update-HubAsyncWorkerSoftTimeout -Name 'privacy' -OnWarn {
        param($ElapsedSec, $TimeoutSec)
        Append-Status ("Privacy scan exceeded expected time ({0}s)." -f $TimeoutSec)
        $script:privacySoftTimeoutWarned = $true
    }
    if (-not $info) { return }

    $script:spinIdx = ($script:spinIdx + 1) % $script:spinFrames.Count
    $lblPrivacyState.Text = ("Privacy scan{0}  {1}s / {2}s" -f $script:spinFrames[$script:spinIdx], $info.ElapsedSec, $timeoutSec)
}

function Run-PrivacyScan {
    if (-not (Test-Path -LiteralPath $script:privacyScanScript)) {
        Append-Status "Privacy scan script not found: $script:privacyScanScript"
        return
    }
    if (Test-AnyOperationRunning) {
        Append-Status "Another operation is already running. Wait for completion."
        return
    }

    try {
        $listPrivacyFindings.Items.Clear()
        $txtPrivacyDetail.Text = ""

        $started = $false
        if (Get-Command Start-HubAsyncWorker -ErrorAction SilentlyContinue) {
            $started = Start-HubAsyncWorker -Name 'privacy' `
                -PsHost $script:psHost `
                -ScriptPath $script:privacyScanScript `
                -ExtraArgs @(
                    '-OutputJson', $script:privacyJson,
                    '-ConfigPath', $script:configPath
                ) `
                -OutputPaths @($script:privacyJson, $script:privacyStdOut, $script:privacyStdErr) `
                -StdOutPath $script:privacyStdOut `
                -StdErrPath $script:privacyStdErr `
                -TimeoutSec $script:privacyTimeoutSec

            if ($started) {
                $w = Get-HubAsyncWorker -Name 'privacy'
                $script:privacyProcess = $w.Process
                $script:privacyStartedAt = $w.StartedAt
                $script:privacySoftTimeoutWarned = $false
            }
        }
        else {
            Remove-IfExists -Path $script:privacyJson
            Remove-IfExists -Path $script:privacyStdOut
            Remove-IfExists -Path $script:privacyStdErr
            $args = @(
                "-NoProfile",
                "-ExecutionPolicy", "Bypass",
                "-File", $script:privacyScanScript,
                "-OutputJson", $script:privacyJson,
                "-ConfigPath", $script:configPath
            )
            $script:privacyStartedAt = Get-Date
            $script:privacySoftTimeoutWarned = $false
            $script:privacyProcess = Start-Process -FilePath $script:psHost -ArgumentList $args `
                -WindowStyle Hidden `
                -RedirectStandardOutput $script:privacyStdOut `
                -RedirectStandardError $script:privacyStdErr `
                -PassThru
            $started = ($null -ne $script:privacyProcess)
        }

        if (-not $started) {
            Append-Status "Privacy scan failed to start."
            $script:privacyProcess = $null
            $script:privacyStartedAt = $null
            $pnlPrivacyProgress.Visible = $false
            $btnPrivacyCancel.Enabled = $false
            Set-AnalysisUiState -IsBusy:$false -StateText "Privacy idle"
            return
        }

        $pnlPrivacyProgress.Visible = $true
        $progressPrivacy.Style = "Marquee"
        $lblPrivacyState.Text = "Privacy scan starting..."
        $btnPrivacyCancel.Enabled = $true
        $btnPrivacyCancel.ForeColor = $clrRed
        $privacyTimer.Start()
        Set-AnalysisUiState -IsBusy:$true -StateText "Privacy scan running..."
        Append-Status "Privacy scan started (read-only)."
    } catch {
        Append-Status ("Privacy scan error: {0}" -f $_.Exception.Message)
        if (Get-Command Stop-HubAsyncWorker -ErrorAction SilentlyContinue) {
            Stop-HubAsyncWorker -Name 'privacy'
        }
        $script:privacyProcess = $null
        $script:privacyStartedAt = $null
        $pnlPrivacyProgress.Visible = $false
        $btnPrivacyCancel.Enabled = $false
        Set-AnalysisUiState -IsBusy:$false -StateText "Privacy idle"
    }
}

function Poll-PrivacyScan {
    $exitCode = $null
    $durationSec = 0
    $hubEntry = $null
    if (Get-Command Get-HubAsyncWorker -ErrorAction SilentlyContinue) {
        $hubEntry = Get-HubAsyncWorker -Name 'privacy'
    }

    if ($hubEntry -and (Get-Command Complete-HubAsyncWorker -ErrorAction SilentlyContinue)) {
        if (Test-HubAsyncWorkerRunning -Name 'privacy') {
            $script:privacyProcess = $hubEntry.Process
            Update-PrivacyProgress
            return
        }

        $done = Complete-HubAsyncWorker -Name 'privacy'
        if (-not $done) { return }

        $exitCode = [int]$done.ExitCode
        $durationSec = $done.DurationSec
    }
    elseif ($script:privacyProcess) {
        if (-not $script:privacyProcess.HasExited) {
            Update-PrivacyProgress
            return
        }
        if ($script:privacyStartedAt) {
            $durationSec = [math]::Round(((Get-Date) - $script:privacyStartedAt).TotalSeconds, 1)
        }
        $exitCode = Get-ProcessExitCodeSafe -Process $script:privacyProcess
    }
    else {
        return
    }

    $privacyTimer.Stop()
    $script:privacyProcess = $null
    $script:privacyStartedAt = $null
    $script:privacySoftTimeoutWarned = $false

    if ($exitCode -ne 0) {
        $errTail = Get-WorkerErrorTail -ErrorPath $script:privacyStdErr
        Append-Status ("Privacy scan ended with exit code {0}. {1}" -f $exitCode, $errTail)
        $pnlPrivacyProgress.Visible = $false
        $btnPrivacyCancel.Enabled = $false
        Set-AnalysisUiState -IsBusy:$false -StateText "Privacy idle"
        return
    }

    if (Wait-ForOutputFile -Path $script:privacyJson -TimeoutMs 5000) {
        try {
            $result = Get-Content -LiteralPath $script:privacyJson -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $script:privacyFindings = @($result.Findings)
            Populate-PrivacyFindings -Findings $script:privacyFindings
            $crit = [int]$result.Summary.Critical
            $lblPrivacyState.Text = ("Done — {0} findings ({1} critical) in {2}s" -f $script:privacyFindings.Count, $crit, $durationSec)
            Append-Status ("Privacy scan completed in {0}s. Findings={1} Critical={2}" -f $durationSec, $script:privacyFindings.Count, $crit)
            Show-Toast -Title "Privacy Scan" -Body ("{0} findings in {1}s" -f $script:privacyFindings.Count, $durationSec) -Level $(if ($crit -gt 0) { "Warning" } else { "Success" })
            if ($script:privacyFindings.Count -gt 0) {
                $listPrivacyFindings.Items[0].Selected = $true
                $listPrivacyFindings.Items[0].Focused = $true
            }
        } catch {
            Append-Status ("Privacy scan parse failed: {0}" -f $_.Exception.Message)
            $lblPrivacyState.Text = "Parse error — see Diagnostics tab."
        }
    } else {
        Append-Status ("Privacy scan completed in {0}s but JSON output missing." -f $durationSec)
        $lblPrivacyState.Text = "Output missing."
    }

    $pnlPrivacyProgress.Visible = $false
    $btnPrivacyCancel.Enabled = $false
    $btnPrivacyCancel.ForeColor = $clrMuted
    Set-AnalysisUiState -IsBusy:$false -StateText "Privacy idle"
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
        $script:analysisTimeoutSec = Get-AnalysisTimeoutSec -Depth $depth
        $script:analysisSoftTimeoutWarned = $false

        $started = $false
        if (Get-Command Start-HubAsyncWorker -ErrorAction SilentlyContinue) {
            $started = Start-HubAsyncWorker -Name 'garbage' `
                -PsHost $script:psHost `
                -ScriptPath $script:analyzerScript `
                -ExtraArgs @(
                    '-Drives', 'C,D',
                    '-Top', "$top",
                    '-Depth', $depth,
                    '-AuditLevel', $auditLevel,
                    '-CleanupMode', $cleanupMode,
                    '-OutputCsv', $script:analysisCsv
                ) `
                -OutputPaths @($script:analysisCsv, $script:analysisStdOut, $script:analysisStdErr) `
                -StdOutPath $script:analysisStdOut `
                -StdErrPath $script:analysisStdErr `
                -TimeoutSec $script:analysisTimeoutSec
            if ($started) {
                $w = Get-HubAsyncWorker -Name 'garbage'
                $script:analysisProcess = $w.Process
                $script:analysisStartedAt = $w.StartedAt
            }
        } else {
            Remove-IfExists -Path $script:analysisCsv
            Remove-IfExists -Path $script:analysisStdOut
            Remove-IfExists -Path $script:analysisStdErr
            $args = @(
                "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $script:analyzerScript,
                "-Drives", "C,D", "-Top", "$top", "-Depth", $depth,
                "-AuditLevel", $auditLevel, "-CleanupMode", $cleanupMode,
                "-OutputCsv", $script:analysisCsv
            )
            $script:analysisStartedAt = Get-Date
            $script:analysisProcess = Start-Process -FilePath $script:psHost -ArgumentList $args -WindowStyle Hidden -RedirectStandardOutput $script:analysisStdOut -RedirectStandardError $script:analysisStdErr -PassThru
            $started = ($null -ne $script:analysisProcess)
        }

        if (-not $started) {
            Append-Status "Analyzer failed to start."
            Set-AnalysisUiState -IsBusy:$false -StateText "Analyzer idle"
            return
        }

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

function Run-ApplySafeThrottle {
    param([switch]$SkipConfirm)

    if (-not (Test-Path -LiteralPath $script:applyPressureScript)) {
        Append-Status "Apply pressure script not found: $script:applyPressureScript"
        return
    }
    if (-not (Test-Path -LiteralPath $script:computeJson)) {
        Append-Status "Run Compute analysis first — no pressure report found."
        return
    }
    if (Test-AnyOperationRunning) {
        Append-Status "Another operation is already running."
        return
    }

    if (-not $SkipConfirm) {
        $msg = if ($script:guiLanguage -eq 'it') {
            "Applica throttle safe reversibile (BelowNormal) ai processi idonei nel report?`n`nMsMpEng e processi vitali sono esclusi."
        } else {
            "Apply reversible safe throttle (BelowNormal) to eligible processes in the report?`n`nMsMpEng and vital processes are excluded."
        }
        $ans = [System.Windows.Forms.MessageBox]::Show($msg, (Get-I18n 'buttons.apply_throttle'), "YesNo", "Question")
        if ($ans -ne 'Yes') { return }
    }

    $applyOut = Join-Path $script:hubRoot 'logs\process-pressure-apply-live.json'
    try {
        $args = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:applyPressureScript,
            '-InputJson', $script:computeJson,
            '-OutputJson', $applyOut,
            '-MaxLevel', 'Safe'
        )
        $p = Start-Process -FilePath $script:psHost -ArgumentList $args -Wait -PassThru -WindowStyle Hidden
        if ($p.ExitCode -ne 0) {
            Append-Status ("Safe throttle apply failed exit {0}" -f $p.ExitCode)
            return
        }
        if (Test-Path -LiteralPath $applyOut) {
            $res = Get-Content -LiteralPath $applyOut -Raw | ConvertFrom-Json
            Append-Status ("Safe throttle: applied={0} skipped={1} rollback={2}" -f `
                @($res.Applied).Count, @($res.Skipped).Count, [string]$res.RollbackPath)
            Show-Toast -Title "Throttle Applied" -Body ("Applied $(@($res.Applied).Count) reversible priority change(s)") -Level "Success"
        }
    } catch {
        Append-Status ("Safe throttle error: {0}" -f $_.Exception.Message)
    }
}

function Run-DefenderExtremeReview {
    if (-not (Get-Command Start-KeepExtremeWizardFlow -ErrorAction SilentlyContinue)) {
        Append-Status 'KEEP wizard module not loaded (gui/keep-service-wizard.ps1).'
        return
    }
    if (-not (Test-Path -LiteralPath $script:evaluateDefenderScript)) {
        Append-Status "Defender evaluation script not found: $script:evaluateDefenderScript"
        return
    }
    if (Test-AnyOperationRunning) {
        Append-Status "Another operation is already running."
        return
    }

    if (-not $script:guiKeepExtremeWizard) {
        $evalOut = Join-Path $script:hubRoot 'logs\defender-extreme-necessity-eval.json'
        $inputArg = if (Test-Path -LiteralPath $script:computeJson) { $script:computeJson } else { '' }
        $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:evaluateDefenderScript, '-OutputJson', $evalOut)
        if ($inputArg) { $args += @('-InputJson', $inputArg) }
        $p = Start-Process -FilePath $script:psHost -ArgumentList $args -Wait -PassThru -WindowStyle Hidden
        if ($p.ExitCode -ne 0) { Append-Status ("Defender evaluation failed exit {0}" -f $p.ExitCode); return }
        $ev = Get-Content -LiteralPath $evalOut -Raw | ConvertFrom-Json
        Append-Status ("Defender review: tier={0} composite={1}" -f $ev.RecommendedTier, $ev.CompositeScore)
        return
    }

    $intro = if ($script:guiLanguage -eq 'it') {
        "Wizard KEEP per servizi vitali (Defender).`n`nRichiede:`n- 3 caselle di conferma`n- frase DISABLE DEFENDER`n- 3 dialoghi di conferma`n- privilegi amministratore`n`nContinuare?"
    } else {
        "KEEP wizard for vital services (Defender).`n`nRequires:`n- 3 confirmation checkboxes`n- phrase DISABLE DEFENDER`n- 3 confirmation dialogs`n- administrator elevation`n`nContinue?"
    }
    $go = [System.Windows.Forms.MessageBox]::Show($intro, (Get-I18n 'buttons.defender_review'), 'YesNo', 'Warning')
    if ($go -ne 'Yes') { return }

    try {
        $result = Start-KeepExtremeWizardFlow -Owner $form -HubRoot $script:hubRoot -ScriptRoot $script:scriptRoot `
            -PsHost $script:psHost -Language $script:guiLanguage -OnStatus { param($m) Append-Status $m } `
            -ComputeJsonPath $script:computeJson -EvaluateScript $script:evaluateDefenderScript -ProcessName 'MsMpEng'
        if ($result.Ok) {
            Show-Toast -Title "KEEP Apply" -Body ("Tier $($result.Tier) — $($result.Reason)") -Level "Warning"
        }
    } catch {
        Append-Status ("KEEP wizard error: {0}" -f $_.Exception.Message)
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
            "-OutputJson", $script:computeJson,
            "-IncludeResearch"
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
$btnDeepScanJump.Add_Click({ $tabs.SelectedTab = $tabDeepScan })

$btnMoreTools.Add_Click({
    $script:showAdvancedTools = -not $script:showAdvancedTools
    $pnlAdvancedTools.Visible = $script:showAdvancedTools
    $btnMoreTools.Text = if ($script:showAdvancedTools) { Get-I18n 'buttons.less_tools' } else { Get-I18n 'buttons.more_tools' }
})

$cmbLanguage.Add_SelectedIndexChanged({
    if (-not $cmbLanguage.SelectedItem) { return }
    $script:guiLanguage = [string]$cmbLanguage.SelectedItem
    if (Get-Command Initialize-I18n -ErrorAction SilentlyContinue) {
        Initialize-I18n -HubRoot $script:hubRoot -Language $script:guiLanguage
        Apply-GuiLanguage
        Initialize-GuiCommandHelp
    }
})

$btnPrivacyHome.Add_Click({
    $tabs.SelectedTab = $tabPrivacy
    Run-PrivacyScan
})

$btnPrivacyRun.Add_Click({ Run-PrivacyScan })

$btnPrivacyCancel.Add_Click({
    $wasRunning = $false
    if ((Get-Command Test-HubAsyncWorkerRunning -ErrorAction SilentlyContinue) -and (Test-HubAsyncWorkerRunning -Name 'privacy')) {
        $wasRunning = $true
    }
    elseif ($script:privacyProcess -and -not $script:privacyProcess.HasExited) {
        $wasRunning = $true
    }

    if (Get-Command Stop-HubAsyncWorker -ErrorAction SilentlyContinue) {
        Stop-HubAsyncWorker -Name 'privacy' -Force
    }
    elseif ($wasRunning -and $script:privacyProcess) {
        try { $script:privacyProcess.Kill() } catch {}
    }

    if ($wasRunning) {
        Append-Status "Privacy scan cancelled by user."
    }
    $privacyTimer.Stop()
    $script:privacyProcess = $null
    $script:privacyStartedAt = $null
    $script:privacySoftTimeoutWarned = $false
    $pnlPrivacyProgress.Visible = $false
    $btnPrivacyCancel.Enabled = $false
    Set-AnalysisUiState -IsBusy:$false -StateText "Privacy cancelled"
})

$listPrivacyFindings.Add_SelectedIndexChanged({
    if ($listPrivacyFindings.SelectedItems.Count -eq 0) { return }
    $row = $listPrivacyFindings.SelectedItems[0].Tag
    if (-not $row) { return }
    $lines = @(
        ("Severity: {0}" -f $row.Severity),
        ("Category: {0}" -f $row.Category),
        ("Pattern: {0}" -f $row.PatternId),
        ("File: {0}" -f $row.FilePath),
        ("Line: {0}" -f $row.LineNumber),
        ("Preview (redacted): {0}" -f $row.RedactedPreview),
        "",
        ("Recommendation: {0}" -f $row.Recommendation),
        "",
        "Vault migration available in Phase 2 (OAuth2 unlock)."
    )
    $txtPrivacyDetail.Text = ($lines -join "`r`n")
})
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
        return
    }

    if ($script:nvmeAdvisorProcess -and (-not $script:nvmeAdvisorProcess.HasExited)) {
        $confirm = [System.Windows.Forms.MessageBox]::Show("Cancel running NVMe Plan?", "Confirm", "YesNo", "Question")
        if ($confirm -eq "Yes") {
            Stop-NvmeAdvisor -Reason "Manual cancel requested by user."
        }
        return
    }

    if ($script:partitionLegacyProcess -and (-not $script:partitionLegacyProcess.HasExited)) {
        $confirm = [System.Windows.Forms.MessageBox]::Show("Cancel running Partition Plan?", "Confirm", "YesNo", "Question")
        if ($confirm -eq "Yes") {
            Stop-PartitionLegacy -Reason "Manual cancel requested by user."
        }
        return
    }

    if ($script:coreInstallProcess -and (-not $script:coreInstallProcess.HasExited)) {
        $confirm = [System.Windows.Forms.MessageBox]::Show("Cancel running Core Install?", "Confirm", "YesNo", "Question")
        if ($confirm -eq "Yes") {
            Stop-CoreInstall -Reason "Manual cancel requested by user."
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
$btnApplyThrottle.Add_Click({ Run-ApplySafeThrottle })
$btnDefenderReview.Add_Click({ Run-DefenderExtremeReview })
$btnQuickClean.Add_Click({
    $confirm = [System.Windows.Forms.MessageBox]::Show("Run quick safe cleanup now?", "Confirm", "YesNo", "Question")
    if ($confirm -eq "Yes") {
        Run-QuickCleanup
    }
})
$btnHealthAudit.Add_Click({
    $msg = if ($script:guiLanguage -eq 'it') {
        "Eseguire Scansione Salute (solo lettura)?`n`nNessuna modifica al sistema."
    } else {
        "Run Health Scan (read-only)?`n`nNo system changes will be made."
    }
    $confirm = [System.Windows.Forms.MessageBox]::Show($msg, (Get-I18n 'buttons.health_check'), "YesNo", "Question")
    if ($confirm -eq "Yes") {
        Run-HealthAudit
    }
})
$btnHealthApply.Add_Click({
    $level = [string]$cmbFixLevel.SelectedItem
    $msg = if ($script:guiLanguage -eq 'it') {
        "Scansione + fix automatici fino al livello '$level'.`n`nUna soluzione per finding. Rischio: Med-Alto.`n`nContinuare?"
    } else {
        "Scan + auto-apply fixes up to '$level' level.`n`nOne solution per finding. Risk: Med-High.`n`nContinue?"
    }
    $confirm = [System.Windows.Forms.MessageBox]::Show($msg, (Get-I18n 'buttons.health_apply'), "YesNo", "Warning")
    if ($confirm -eq "Yes") {
        Run-HealthAudit -ApplyAfter
    }
})
$btnPkgFix.Add_Click({
    $msg = "Run package prerequisite check and apply SAFE fixes for missing PKG-* items?`n`nThis targets required system packages only."
    $confirm = [System.Windows.Forms.MessageBox]::Show($msg, "Package Prerequisites", "YesNo", "Question")
    if ($confirm -eq "Yes") {
        Run-HealthAudit -ApplyAfter -ApplyPackagesOnly
    }
})
$btnNvmePlan.Add_Click({
    $confirm = [System.Windows.Forms.MessageBox]::Show("Run NVMe risk advisory and write-offload plan?`n`nThis is read-only and does not change system settings.", "NVMe Plan", "YesNo", "Question")
    if ($confirm -eq "Yes") {
        Run-NvmeAdvisor
    }
})
$btnPartitionPlan.Add_Click({
    $msg = "Partition Plan mode:`nYes = Audit only (deterministic checks).`nNo = Audit + apply (delete partition 4 and extend C only if all checks pass).`nCancel = abort."
    $choice = [System.Windows.Forms.MessageBox]::Show($msg, "Partition Plan", "YesNoCancel", "Warning")
    if ($choice -eq "Yes") {
        Run-PartitionLegacy
        return
    }
    if ($choice -eq "No") {
        $confirm = [System.Windows.Forms.MessageBox]::Show("Apply mode requires Administrator rights and changes partition layout. Continue?", "Confirm Apply", "YesNo", "Warning")
        if ($confirm -eq "Yes") {
            Run-PartitionLegacy -ApplyIfLegacy
        }
    }
})
$btnReloadTasks.Add_Click({ Reload-Tasks })
$btnInstallTasks.Add_Click({ Run-CoreInstall })
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
        "NVMe Plan (stdout)"        = $script:nvmeAdvisorStdOut
        "NVMe Plan (stderr)"        = $script:nvmeAdvisorStdErr
        "Partition Plan (stdout)"   = $script:partitionLegacyStdOut
        "Partition Plan (stderr)"   = $script:partitionLegacyStdErr
        "Core Install (stdout)"      = $script:coreInstallStdOut
        "Core Install (stderr)"      = $script:coreInstallStdErr
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
$btnSaveConfig.Add_Click({ Save-GuiPreferences })
$btnReloadConfig.Add_Click({
    Load-GuiPreferences
    Apply-ConfigControls
    Append-Status "Configuration reloaded from disk."
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
Apply-ConfigControls
Apply-GuiLanguage
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

$nvmeAdvisorTimer = New-Object System.Windows.Forms.Timer
$nvmeAdvisorTimer.Interval = 1000
$nvmeAdvisorTimer.Add_Tick({ Poll-NvmeAdvisor })

$coreInstallTimer = New-Object System.Windows.Forms.Timer
$coreInstallTimer.Interval = 1000
$coreInstallTimer.Add_Tick({ Poll-CoreInstall })

$partitionLegacyTimer = New-Object System.Windows.Forms.Timer
$partitionLegacyTimer.Interval = 1000
$partitionLegacyTimer.Add_Tick({ Poll-PartitionLegacy })

$deepScanTimer = New-Object System.Windows.Forms.Timer
$deepScanTimer.Interval = 1000
$deepScanTimer.Add_Tick({ Poll-DeepScan })

$deepScanApplyTimer = New-Object System.Windows.Forms.Timer
$deepScanApplyTimer.Interval = 1000
$deepScanApplyTimer.Add_Tick({ Poll-DeepScanApply })

$privacyTimer = New-Object System.Windows.Forms.Timer
$privacyTimer.Interval = 1000
$privacyTimer.Add_Tick({ Poll-PrivacyScan })

$form.Add_Shown({
    Set-NoTheme -Ctrl $listExplorer
    Set-NoTheme -Ctrl $listTasks
    Set-NoTheme -Ctrl $listDeepFindings
    Set-NoTheme -Ctrl $listDeepSolutions
    Set-NoTheme -Ctrl $listPrivacyFindings
    Apply-GuiLanguage
    Initialize-GuiCommandHelp
    $lblStatusRight.Text = ("Hub: {0}  |  PS: {1}" -f $script:hubRoot, (Split-Path -Leaf $script:psHost))
    Refresh-Drives
    Reload-Tasks
    if ($script:transparencyUi -and $script:transparencyUi.Refresh) {
        & $script:transparencyUi.Refresh
    }
    if ($script:autoAnalyzeOnStartup) {
        Append-Status ("Auto-analyze on startup enabled (Settings). Depth={0}, Top={1}." -f [string]$cmbDepth.SelectedItem, [int]$numTop.Value)
        $startupTimer = New-Object System.Windows.Forms.Timer
        $startupTimer.Interval = 600
        $startupTimer.Add_Tick({
            $startupTimer.Stop()
            $startupTimer.Dispose()
            if (-not $script:analysisProcess) { Run-GarbageAnalysis }
        })
        $startupTimer.Start()
    } else {
        Append-Status (Get-I18n 'app.ready')
    }
})
[void]$form.ShowDialog()
