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
    $cmd = 'echo AUDIT; nvram get wan_dns; nvram get wan_mtu; nvram get wl0_bss_enabled; nvram get wlan0_mode; nvram get telnetd_enable; nvram get remote_management; ping -c 1 -W 3 1.1.1.1'
    & ssh.exe @sshBase $target $cmd
    return
}

# Pipe LF-normalized script (BusyBox sh rejects CRLF from Windows scp)
$scriptLf = [string]::Join("`n", (Get-Content -LiteralPath $scriptPath -Raw).Replace("`r`n", "`n").Replace("`r", "`n").TrimEnd().Split("`n"))
$scriptLf | & ssh.exe @sshBase $target "cat > $remoteScript && chmod +x $remoteScript && sh $remoteScript"
if ($LASTEXITCODE -ne 0) { throw "ssh apply failed: $LASTEXITCODE" }

Write-Host '[DDWRT] Permanent tuning applied.'
