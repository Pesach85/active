#Requires -RunAsAdministrator
<#
.SYNOPSIS
GUI dashboard for WHEA monitoring and post-mitigation analysis.
Interactive visualization of error trends, event breakdown, and system stability metrics.

.PARAMETER MonitorLogPath
Path to the continuous monitoring JSON (default: logs/whea-monitoring-continuous.json)

.NOTES
Displays:
  - Live WHEA rate gauge (green <300, yellow 300-600, red >600)
  - 24h trend graph
  - Event ID histogram (corrected vs uncorrected)
  - System WHEA-Logger indicator (should show 0 uncorrected events)
  - Refresh capability + CSV export

Anti-pattern guard: All event handlers use .Tag-based references per KB/powershell-winforms-patterns.md
#>

param(
    [string]$MonitorLogPath = "C:\SystemOptimizerHub\active\logs\whea-monitoring-continuous.json"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# ============================================================================
# Load Data
# ============================================================================
function Load-WHEAData {
    if (-not (Test-Path -LiteralPath $MonitorLogPath)) {
        return $null
    }
    try {
        return Get-Content -LiteralPath $MonitorLogPath -Raw | ConvertFrom-Json -AsHashtable
    } catch {
        Write-Warning "Failed to load WHEA data: $_"
        return $null
    }
}

function Get-StatusColor {
    param([int]$Value)
    if ($Value -le 300) { return [System.Drawing.Color]::FromArgb(76, 175, 80) }      # Green
    if ($Value -le 600) { return [System.Drawing.Color]::FromArgb(255, 193, 7) }     # Yellow
    return [System.Drawing.Color]::FromArgb(244, 67, 54)                            # Red
}

function Get-StatusText {
    param([int]$Value)
    if ($Value -le 300) { return "HEALTHY" }
    if ($Value -le 600) { return "CAUTION" }
    return "CRITICAL"
}

# ============================================================================
# UI Setup
# ============================================================================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$form = New-Object System.Windows.Forms.Form
$form.Text = "WHEA Monitor — Post-Mitigation Analysis"
$form.Width = 1200
$form.Height = 700
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.BackColor = [System.Drawing.Color]::FromArgb(240, 240, 240)

$font_title = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$font_normal = New-Object System.Drawing.Font("Segoe UI", 10)
$font_small = New-Object System.Drawing.Font("Segoe UI", 9)

# ============================================================================
# Top Control Panel (Horizontal)
# ============================================================================
$topPanel = New-Object System.Windows.Forms.Panel
$topPanel.Dock = [System.Windows.Forms.DockStyle]::Top
$topPanel.Height = 60
$topPanel.BackColor = [System.Drawing.Color]::FromArgb(33, 150, 243)
$topPanel.Padding = New-Object System.Windows.Forms.Padding(10)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "WHEA Error Rate Monitoring — Live Dashboard"
$lblTitle.Font = $font_title
$lblTitle.ForeColor = [System.Drawing.Color]::White
$lblTitle.AutoSize = $false
$lblTitle.Width = 600
$lblTitle.Height = 40
$lblTitle.Left = 10
$lblTitle.Top = 10

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = "🔄 Refresh"
$btnRefresh.Width = 100
$btnRefresh.Height = 35
$btnRefresh.Left = 900
$btnRefresh.Top = 12
$btnRefresh.Font = $font_small
$btnRefresh.BackColor = [System.Drawing.Color]::White
$btnRefresh.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat

$btnExport = New-Object System.Windows.Forms.Button
$btnExport.Text = "📊 Export CSV"
$btnExport.Width = 100
$btnExport.Height = 35
$btnExport.Left = 1010
$btnExport.Top = 12
$btnExport.Font = $font_small
$btnExport.BackColor = [System.Drawing.Color]::White
$btnExport.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat

# Shared refresh data object
$refreshData = @{
    WheatData = $null
    LastUpdateTime = [DateTime]::MinValue
}

# Store form ref for event handlers
$form.Tag = @{ RefreshData = $refreshData }

# ============================================================================
# Content Container (SuspendLayout/ResumeLayout guard)
# ============================================================================
$contentPanel = New-Object System.Windows.Forms.Panel
$contentPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$contentPanel.BackColor = [System.Drawing.Color]::White
$contentPanel.AutoScroll = $true

# Left panel: gauge + info
$leftPanel = New-Object System.Windows.Forms.Panel
$leftPanel.Dock = [System.Windows.Forms.DockStyle]::Left
$leftPanel.Width = 280
$leftPanel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$leftPanel.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 250)
$leftPanel.Padding = New-Object System.Windows.Forms.Padding(10)

$lblGaugeTitle = New-Object System.Windows.Forms.Label
$lblGaugeTitle.Text = "Current Rate (10-min)"
$lblGaugeTitle.Font = $font_title
$lblGaugeTitle.AutoSize = $false
$lblGaugeTitle.Width = 260
$lblGaugeTitle.Height = 30
$lblGaugeTitle.Top = 10

$gaugeCanvas = New-Object System.Windows.Forms.PictureBox
$gaugeCanvas.Width = 260
$gaugeCanvas.Height = 150
$gaugeCanvas.Top = 45
$gaugeCanvas.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$gaugeCanvas.BackColor = [System.Drawing.Color]::White

# Create gauge bitmap
$gaugeBitmap = New-Object System.Drawing.Bitmap(260, 150)
$gaugeGraphics = [System.Drawing.Graphics]::FromImage($gaugeBitmap)
$gaugeGraphics.Clear([System.Drawing.Color]::White)

# Draw gauge background (arc)
$pen = New-Object System.Drawing.Pen([System.Drawing.Color]::Gray, 2)
$brush_green = New-Object System.Drawing.SolidBrush((Get-StatusColor 100))
$brush_yellow = New-Object System.Drawing.SolidBrush((Get-StatusColor 400))
$brush_red = New-Object System.Drawing.SolidBrush((Get-StatusColor 800))
$font_gauge = New-Object System.Drawing.Font("Segoe UI", 24, [System.Drawing.FontStyle]::Bold)

$gaugeGraphics.DrawArc($pen, 30, 20, 200, 200, 180, 60)  # Green zone
$gaugeGraphics.DrawArc($pen, 30, 20, 200, 200, 240, 60)  # Yellow zone
$gaugeGraphics.DrawArc($pen, 30, 20, 200, 200, 300, 60)  # Red zone

$gaugeGraphics.DrawString("0", $font_gauge, $brush_green, 40, 80)
$gaugeGraphics.DrawString("300", $font_gauge, $brush_yellow, 115, 40)
$gaugeGraphics.DrawString("600+", $font_gauge, $brush_red, 185, 80)

$gaugeCanvas.Image = $gaugeBitmap

$lblValue = New-Object System.Windows.Forms.Label
$lblValue.Text = "— events"
$lblValue.Font = $font_title
$lblValue.ForeColor = [System.Drawing.Color]::Gray
$lblValue.AutoSize = $false
$lblValue.Width = 260
$lblValue.Height = 30
$lblValue.Top = 200
$lblValue.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = "UNKNOWN"
$lblStatus.Font = $font_normal
$lblStatus.ForeColor = [System.Drawing.Color]::Gray
$lblStatus.AutoSize = $false
$lblStatus.Width = 260
$lblStatus.Height = 25
$lblStatus.Top = 235
$lblStatus.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter

$lblCorrected = New-Object System.Windows.Forms.Label
$lblCorrected.Text = "Corrected: —"
$lblCorrected.Font = $font_small
$lblCorrected.AutoSize = $false
$lblCorrected.Width = 260
$lblCorrected.Height = 20
$lblCorrected.Top = 270

$lblUncorrected = New-Object System.Windows.Forms.Label
$lblUncorrected.Text = "Uncorrected: —"
$lblUncorrected.Font = $font_small
$lblUncorrected.AutoSize = $false
$lblUncorrected.Width = 260
$lblUncorrected.Height = 20
$lblUncorrected.Top = 295

$lblAvg24h = New-Object System.Windows.Forms.Label
$lblAvg24h.Text = "24h Avg: — events/10min"
$lblAvg24h.Font = $font_small
$lblAvg24h.AutoSize = $false
$lblAvg24h.Width = 260
$lblAvg24h.Height = 20
$lblAvg24h.Top = 325

$lblTrend = New-Object System.Windows.Forms.Label
$lblTrend.Text = "Trend: —"
$lblTrend.Font = $font_small
$lblTrend.AutoSize = $false
$lblTrend.Width = 260
$lblTrend.Height = 20
$lblTrend.Top = 350

$lblLastUpdate = New-Object System.Windows.Forms.Label
$lblLastUpdate.Text = "Last: —"
$lblLastUpdate.Font = $font_small
$lblLastUpdate.ForeColor = [System.Drawing.Color]::Gray
$lblLastUpdate.AutoSize = $false
$lblLastUpdate.Width = 260
$lblLastUpdate.Height = 20
$lblLastUpdate.Top = 600

# Right panel: graphs + histogram
$rightPanel = New-Object System.Windows.Forms.Panel
$rightPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$rightPanel.BackColor = [System.Drawing.Color]::White
$rightPanel.Padding = New-Object System.Windows.Forms.Padding(10)

$trendChart = New-Object System.Windows.Forms.PictureBox
$trendChart.Width = 880
$trendChart.Height = 280
$trendChart.Top = 10
$trendChart.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

$lblTrendTitle = New-Object System.Windows.Forms.Label
$lblTrendTitle.Text = "24-Hour Trend"
$lblTrendTitle.Font = $font_title
$lblTrendTitle.AutoSize = $false
$lblTrendTitle.Width = 880
$lblTrendTitle.Height = 25
$lblTrendTitle.Top = 305

$histogramChart = New-Object System.Windows.Forms.PictureBox
$histogramChart.Width = 880
$histogramChart.Height = 280
$histogramChart.Top = 335
$histogramChart.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

$lblHistTitle = New-Object System.Windows.Forms.Label
$lblHistTitle.Text = "Event ID Breakdown"
$lblHistTitle.Font = $font_title
$lblHistTitle.AutoSize = $false
$lblHistTitle.Width = 880
$lblHistTitle.Height = 25
$lblHistTitle.Top = 620

# ============================================================================
# Refresh Function (updates all UI elements)
# ============================================================================
function Update-Dashboard {
    try {
        $wheatData = Load-WHEAData
        if (-not $wheatData) {
            $lblValue.Text = "No data"
            $lblValue.ForeColor = [System.Drawing.Color]::Gray
            $lblStatus.Text = "NO DATA LOADED"
            return
        }
        
        # Get latest measurement
        if ($wheatData.Measurements -and $wheatData.Measurements.Count -gt 0) {
            $latest = $wheatData.Measurements[-1]
            $total = [int]$latest.TotalCount
            $corrected = [int]$latest.CorrectedCount
            $uncorrected = [int]$latest.UncorrectedCount
        } else {
            $total = 0
            $corrected = 0
            $uncorrected = 0
        }
        
        # Update gauge
        $lblValue.Text = "$total events"
        $lblValue.ForeColor = Get-StatusColor $total
        $lblStatus.Text = Get-StatusText $total
        $lblStatus.ForeColor = Get-StatusColor $total
        
        $lblCorrected.Text = "Corrected: $corrected"
        $lblUncorrected.Text = "Uncorrected: $uncorrected"
        
        if ($wheatData.RollingAverage24h) {
            $lblAvg24h.Text = "24h Avg: $($wheatData.RollingAverage24h) events/10min"
        } else {
            $lblAvg24h.Text = "24h Avg: — events/10min"
        }
        
        if ($wheatData.Trend) {
            $lblTrend.Text = "Trend: $($wheatData.Trend.ToUpper())"
        }
        
        $lblLastUpdate.Text = "Last: $(Get-Date -Format 'HH:mm:ss')"
        
        # Draw trend chart
        Draw-TrendChart -Data $wheatData -Canvas $trendChart
        
        # Draw histogram
        Draw-Histogram -Data $latest -Canvas $histogramChart
        
    } catch {
        Write-Warning "Error updating dashboard: $_"
        $lblValue.Text = "ERROR"
        $lblValue.ForeColor = [System.Drawing.Color]::Red
    }
}

function Draw-TrendChart {
    param([object]$Data, [object]$Canvas)
    
    $bitmap = New-Object System.Drawing.Bitmap($Canvas.Width, $Canvas.Height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.Clear([System.Drawing.Color]::White)
    
    if (-not $Data.Measurements -or $Data.Measurements.Count -eq 0) {
        $font = New-Object System.Drawing.Font("Segoe UI", 10)
        $graphics.DrawString("No trend data available", $font, [System.Drawing.Brushes]::Gray, 20, 50)
        $Canvas.Image = $bitmap
        return
    }
    
    $measurements = $Data.Measurements | Select-Object -Last 144  # Last 24h (144 * 10min)
    if ($measurements -isnot [array]) { $measurements = @($measurements) }
    
    $w = [int]$Canvas.Width - 40
    $h = [int]$Canvas.Height - 40
    $margin = 30
    
    # Draw axes
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::LightGray, 1)
    $graphics.DrawLine($pen, $margin, $h, $w + $margin, $h)  # X axis
    $graphics.DrawLine($pen, $margin, 0, $margin, $h)         # Y axis
    
    # Y-axis labels
    $font = New-Object System.Drawing.Font("Segoe UI", 8)
    $brush = [System.Drawing.Brushes]::Gray
    $graphics.DrawString("0", $font, $brush, 5, $h - 10)
    $graphics.DrawString("300", $font, $brush, 5, [int]($h * 0.75) - 10)
    $graphics.DrawString("600", $font, $brush, 5, [int]($h * 0.50) - 10)
    $graphics.DrawString("900+", $font, $brush, 5, [int]($h * 0.25) - 10)
    
    # Scale
    $maxValue = 900
    $pointsX = @()
    $pointsY = @()
    
    for ($i = 0; $i -lt $measurements.Count; $i++) {
        $val = [int]$measurements[$i].TotalCount
        $x = $margin + [int](($i / $measurements.Count) * $w)
        $y = $h - [int](($val / $maxValue) * $h)
        $pointsX += $x
        $pointsY += $y
    }
    
    # Draw trend line
    if ($pointsX.Count -gt 1) {
        $pen_trend = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(76, 175, 80), 2)
        for ($i = 0; $i -lt $pointsX.Count - 1; $i++) {
            $graphics.DrawLine($pen_trend, $pointsX[$i], $pointsY[$i], $pointsX[$i + 1], $pointsY[$i + 1])
        }
    }
    
    # Draw points
    $pen_dot = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(33, 150, 243), 1)
    $brush_dot = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(33, 150, 243))
    
    foreach ($x in $pointsX) {
        $idx = [array]::IndexOf($pointsX, $x)
        if ($idx -ge 0 -and $idx -lt $pointsY.Count) {
            $graphics.DrawEllipse($pen_dot, [int]$pointsX[$idx] - 2, [int]$pointsY[$idx] - 2, 4, 4)
        }
    }
    
    # X-axis label
    $graphics.DrawString("24 hours", $font, $brush, [int]($w / 2 - 20), [int]$h + 10)
    
    $Canvas.Image = $bitmap
}

function Draw-Histogram {
    param([object]$Data, [object]$Canvas)
    
    $bitmap = New-Object System.Drawing.Bitmap($Canvas.Width, $Canvas.Height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.Clear([System.Drawing.Color]::White)
    
    if (-not $Data) {
        $font = New-Object System.Drawing.Font("Segoe UI", 10)
        $graphics.DrawString("No event data available", $font, [System.Drawing.Brushes]::Gray, 20, 50)
        $Canvas.Image = $bitmap
        return
    }
    
    $corrByID = $Data.CorrectedByID
    $uncorrByID = $Data.UncorrectedByID
    
    $allIDs = @($corrByID.Keys + $uncorrByID.Keys | Sort-Object -Unique)
    
    if ($allIDs.Count -eq 0) {
        $font = New-Object System.Drawing.Font("Segoe UI", 10)
        $graphics.DrawString("No events recorded", $font, [System.Drawing.Brushes]::Gray, 20, 50)
        $Canvas.Image = $bitmap
        return
    }
    
    $barWidth = [int](([int]$Canvas.Width - 60) / ($allIDs.Count * 2.5))
    $maxCount = ($corrByID.Values | Measure-Object -Maximum).Maximum
    if (-not $maxCount) { $maxCount = 1 }
    
    $font = New-Object System.Drawing.Font("Segoe UI", 8)
    $brush_corr = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(76, 175, 80))
    $brush_uncorr = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(244, 67, 54))
    
    $x = 30
    foreach ($id in $allIDs) {
        $corrCount = $corrByID[$id] ? $corrByID[$id] : 0
        $uncorrCount = $uncorrByID[$id] ? $uncorrByID[$id] : 0
        
        $corrHeight = [int](($corrCount / $maxCount) * 200)
        $uncorrHeight = [int](($uncorrCount / $maxCount) * 200)
        
        # Draw corrected (green)
        $graphics.FillRectangle($brush_corr, $x, [int](280 - $corrHeight), $barWidth, $corrHeight)
        
        # Draw uncorrected (red)
        $graphics.FillRectangle($brush_uncorr, $x + $barWidth + 2, [int](280 - $uncorrHeight), $barWidth, $uncorrHeight)
        
        # Label
        $graphics.DrawString("ID $id", $font, [System.Drawing.Brushes]::Black, $x, 290)
        
        $x += $barWidth * 3
    }
    
    # Legend
    $legend_y = 20
    $graphics.FillRectangle($brush_corr, 20, $legend_y, 12, 12)
    $graphics.DrawString("Corrected", $font, [System.Drawing.Brushes]::Black, 40, $legend_y - 2)
    
    $graphics.FillRectangle($brush_uncorr, 150, $legend_y, 12, 12)
    $graphics.DrawString("Uncorrected", $font, [System.Drawing.Brushes]::Black, 170, $legend_y - 2)
    
    $Canvas.Image = $bitmap
}

# ============================================================================
# Event Handlers (using .Tag to avoid closure issues)
# ============================================================================
$btnRefresh.Add_Click({
    param($sender, $eArgs)
    Update-Dashboard
})

$btnExport.Add_Click({
    param($sender, $eArgs)
    try {
        $wheatData = Load-WHEAData
        if (-not $wheatData -or -not $wheatData.Measurements) {
            [System.Windows.Forms.MessageBox]::Show("No data to export", "Info", [System.Windows.Forms.MessageBoxButtons]::OK)
            return
        }
        
        $csv = "TimestampUTC,CorrectedCount,UncorrectedCount,TotalCount`n"
        foreach ($m in $wheatData.Measurements) {
            $csv += "$($m.TimestampUTC),$($m.CorrectedCount),$($m.UncorrectedCount),$($m.TotalCount)`n"
        }
        
        $exportPath = [System.IO.Path]::Combine([Environment]::GetFolderPath("Desktop"), "whea-export-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv")
        $csv | Out-File -LiteralPath $exportPath -Encoding utf8
        
        [System.Windows.Forms.MessageBox]::Show("Exported to: $exportPath", "Success", [System.Windows.Forms.MessageBoxButtons]::OK)
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Export failed: $_", "Error", [System.Windows.Forms.MessageBoxButtons]::OK)
    }
})

# ============================================================================
# Build Layout (with SuspendLayout guard)
# ============================================================================
$form.SuspendLayout()

# Top panel controls
$topPanel.Controls.Add($lblTitle)
$topPanel.Controls.Add($btnRefresh)
$topPanel.Controls.Add($btnExport)

# Left panel controls (gauge info)
$leftPanel.Controls.Add($lblGaugeTitle)
$leftPanel.Controls.Add($gaugeCanvas)
$leftPanel.Controls.Add($lblValue)
$leftPanel.Controls.Add($lblStatus)
$leftPanel.Controls.Add($lblCorrected)
$leftPanel.Controls.Add($lblUncorrected)
$leftPanel.Controls.Add($lblAvg24h)
$leftPanel.Controls.Add($lblTrend)
$leftPanel.Controls.Add($lblLastUpdate)

# Right panel controls (charts)
$rightPanel.Controls.Add($lblTrendTitle)
$rightPanel.Controls.Add($trendChart)
$rightPanel.Controls.Add($lblHistTitle)
$rightPanel.Controls.Add($histogramChart)

# Content assembly (Fill first, then edge panels)
$contentPanel.Controls.Add($rightPanel)      # Fill
$contentPanel.Controls.Add($leftPanel)       # Left edge
$form.Controls.Add($contentPanel)            # Fill
$form.Controls.Add($topPanel)                # Top edge

$form.ResumeLayout($false)

# ============================================================================
# Show and Initialize
# ============================================================================
Update-Dashboard
$form.ShowDialog()

exit 0
