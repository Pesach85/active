#Requires -Version 5.1
<#
.SYNOPSIS
    Apply permanent DD-WRT tuning via SSH key (hotspot client -> LAN switch).
#>
[CmdletBinding()]
param(
    [string]$RouterHost = '192.168.1.250',
    [string]$SshUser = 'root',
    [string]$KeyPath = '',
    [string]$KnownHosts = '',
    [switch]$AuditOnly
)

$ErrorActionPreference = 'Stop'
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$scriptPath = Join-Path $PSScriptRoot 'ddwrt-apply-permanent-tuning.sh'
$remoteScript = '/tmp/ddwrt-apply-permanent-tuning.sh'

if (-not $KeyPath) { $KeyPath = Join-Path $repoRoot 'ddwrtkey\id_ed25519.ssh' }
if (-not $KnownHosts) { $KnownHosts = Join-Path $repoRoot 'logs\ddwrt-known-hosts' }
if (-not (Test-Path -LiteralPath $KeyPath)) { throw "SSH key not found: $KeyPath" }
if (-not (Test-Path -LiteralPath $scriptPath)) { throw "Script not found: $scriptPath" }

$target = "${SshUser}@${RouterHost}"
$sshBase = @('-i', $KeyPath, '-o', "UserKnownHostsFile=$KnownHosts", '-o', 'StrictHostKeyChecking=accept-new', '-o', 'IdentitiesOnly=yes', '-o', 'ConnectTimeout=25')

if ($AuditOnly) {
    # Interroga la NVRAM su tutte le possibili nomenclature wireless e lo stato del link
    $cmd = 'echo "=== VERIFICA NVRAM WIRELESS ==="; ' +
           'echo "wl0_mode:"; nvram get wl0_mode; ' +
           'echo "wlan0_mode:"; nvram get wlan0_mode; ' +
           'echo "wl0_ssid:"; nvram get wl0_ssid; ' +
           'echo "wlan0_ssid:"; nvram get wlan0_ssid; ' +
           'echo "wl0_akm:"; nvram get wl0_akm; ' +
           'echo "wlan0_akm:"; nvram get wlan0_akm; ' +
           'echo "=== STATO INTERFACCE LINUX ==="; ' +
           'ifconfig wlan0 | grep -E "Link|inet"; ' +
           'iwconfig wlan0 2>/dev/null | grep -E "ESSID|Access Point"; ' +
           'echo "=== SISTEMA ==="; ' +
           'uname -a; ' +
           'echo "DD_BOARD:"; nvram get DD_BOARD; ' +
           'echo "=== PROCESSI ==="; ' +
           'ps | grep -E "hostapd|wpa|nas"'
        & ssh.exe @sshBase $target $cmd
    return
}

# Pipe LF-normalized script (BusyBox sh rejects CRLF from Windows scp)
$scriptLf = [string]::Join("`n", (Get-Content -LiteralPath $scriptPath -Raw).Replace("`r`n", "`n").Replace("`r", "`n").TrimEnd().Split("`n"))
$scriptLf | & ssh.exe @sshBase $target "cat > $remoteScript && chmod +x $remoteScript && sh $remoteScript"
if ($LASTEXITCODE -ne 0) { throw "ssh apply failed: $LASTEXITCODE" }

Write-Host '[DDWRT] Permanent tuning applied.'
