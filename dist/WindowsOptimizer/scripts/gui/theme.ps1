# Obsidian theme + control factories for System Optimizer Hub GUI.
# Dot-sourced by system-optimizer-gui.ps1 — variables land in caller scope.

$script:appVersion = "3.2.0"

$clrBg       = [System.Drawing.Color]::FromArgb(8, 11, 19)
$clrSurface  = [System.Drawing.Color]::FromArgb(15, 22, 36)
$clrRaised   = [System.Drawing.Color]::FromArgb(22, 32, 52)
$clrBorderC  = [System.Drawing.Color]::FromArgb(36, 52, 78)
$clrAccent   = [System.Drawing.Color]::FromArgb(16, 185, 129)
$clrAccent2  = [System.Drawing.Color]::FromArgb(56, 189, 248)
$clrGreen    = [System.Drawing.Color]::FromArgb(34, 197, 94)
$clrRed      = [System.Drawing.Color]::FromArgb(239, 68, 68)
$clrAmber    = [System.Drawing.Color]::FromArgb(245, 158, 11)
$clrPurple   = [System.Drawing.Color]::FromArgb(139, 92, 246)
$clrCyan     = [System.Drawing.Color]::FromArgb(6, 182, 212)
$clrText     = [System.Drawing.Color]::FromArgb(241, 245, 249)
$clrMuted    = [System.Drawing.Color]::FromArgb(100, 116, 139)
$clrRowHigh  = [System.Drawing.Color]::FromArgb(56, 24, 24)
$clrRowAmber = [System.Drawing.Color]::FromArgb(56, 42, 12)
$clrTxtHigh  = [System.Drawing.Color]::FromArgb(254, 202, 202)
$clrTxtAmber = [System.Drawing.Color]::FromArgb(253, 230, 138)

$fntUI    = New-Object System.Drawing.Font("Segoe UI", 9.75)
$fntHead  = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
$fntH2    = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$fntMono  = New-Object System.Drawing.Font("Consolas", 9.25)
$fntSmall = New-Object System.Drawing.Font("Segoe UI", 8.25)

$script:spinFrames = @("", ".", "..", "...", "....", ".....", "....", "...", "..", ".")
$script:spinIdx    = 0

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

# Flat button factory — regular font + padding avoids clipped Italian labels
function New-Btn {
    param([string]$Text, [System.Drawing.Color]$Bg, [int]$W = 140, [int]$H = 38)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text; $b.Width = $W; $b.Height = $H
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $b.FlatAppearance.BorderSize = 1
    $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(
        [Math]::Min(255, $Bg.R + 28), [Math]::Min(255, $Bg.G + 28), [Math]::Min(255, $Bg.B + 28))
    $b.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(
        [Math]::Min(255, $Bg.R + 42), [Math]::Min(255, $Bg.G + 42), [Math]::Min(255, $Bg.B + 42))
    $b.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(
        [Math]::Max(0, $Bg.R - 18), [Math]::Max(0, $Bg.G - 18), [Math]::Max(0, $Bg.B - 18))
    $b.BackColor = $Bg
    $b.ForeColor = if ($Bg.GetBrightness() -gt 0.55) { $clrBg } else { $clrText }
    $b.Font = $fntUI
    $b.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $b.Padding = New-Object System.Windows.Forms.Padding(8, 4, 8, 4)
    $b.UseCompatibleTextRendering = $true
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    return $b
}

function Format-AlreadyOptimizedLog {
    param([array]$Items, [int]$MaxItems = 5)
    $lines = @($Items | ForEach-Object {
        $s = [string]$_
        if ($s.Length -gt 72) { $s.Substring(0, 69) + '...' }
        else { $s }
    })
    if ($lines.Count -eq 0) { return '' }
    $preview = @($lines | Select-Object -First $MaxItems)
    $suffix = if ($lines.Count -gt $MaxItems) { " (+$($lines.Count - $MaxItems) more)" } else { '' }
    return ($preview -join '; ') + $suffix
}
