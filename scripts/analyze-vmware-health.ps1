<#
.SYNOPSIS
    Deep VMware Workstation healthcheck: inventory, diagnose, optional safe repair.

.DESCRIPTION
    Discovers VMware Workstation install, inventories .vmx under configurable roots
    (default includes D:\Macchine_Virtuali), diagnoses per-VM locks / MKS crashes /
    3D settings / disk presence, and optionally applies safe repairs.

    Default is audit-only (dry-run). Use -Apply for:
      - Clear stale .lck when VM is powered off (no live vmware-vmx)
      - Set mks.enable3d = FALSE after .vmx backup under logs/vmware-vmx-rollback

    Never deletes .vmdk or snapshots. Never force-powers-off running VMs.

.PARAMETER Apply
    Apply safe repairs after diagnosis.

.PARAMETER InventoryRoot
    Extra inventory root(s). Merged with config Vmware.InventoryRoots / defaults.

.PARAMETER VmxPath
    Limit diagnosis to one .vmx path or VM folder (substring / literal).

.PARAMETER OutputJson
    Report path (default logs/vmware-health-latest.json).
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [string[]]$InventoryRoot = @(),
    [string]$VmxPath = '',
    [string]$OutputJson = '',
    [string]$BackupDirectory = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'lib\vmware-health.ps1')
. (Join-Path $scriptDir 'hub-common.ps1')
$hub = Get-HubPaths

if ([string]::IsNullOrWhiteSpace($OutputJson)) {
    $OutputJson = Join-Path $hub.Logs 'vmware-health-latest.json'
}
if ([string]::IsNullOrWhiteSpace($BackupDirectory)) {
    $BackupDirectory = Join-Path $hub.Logs 'vmware-vmx-rollback'
}

$report = New-VmwareHealthReport `
    -InventoryRoots $InventoryRoot `
    -HubPaths $hub `
    -VmxFilter $VmxPath `
    -Apply:$Apply `
    -BackupDirectory $BackupDirectory

$outDir = Split-Path -Parent $OutputJson
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}
$report | ConvertTo-Json -Depth 10 | Out-File -LiteralPath $OutputJson -Encoding utf8 -Force

$evtLib = Join-Path $scriptDir 'lib\transparency-events.ps1'
if ((Test-Path -LiteralPath $evtLib) -and -not (Get-Command Write-TransparencyEvent -ErrorAction SilentlyContinue)) {
    . $evtLib
}
if (Get-Command Write-TransparencyEvent -ErrorAction SilentlyContinue) {
    Write-TransparencyEvent -EventsPath (Join-Path $hub.Logs 'transparency-events.jsonl') `
        -Action 'vmware-health' `
        -Detail ("VMs={0} MksCrash={1} StaleLocks={2} Mode={3}" -f $report.Summary.VmCount, $report.Summary.MksCrashVmCount, $report.Summary.StaleLockVmCount, $report.Mode) `
        -AgentId 'vmware-health' `
        -ControlLevel $(if ($Apply) { 'T1_Delegated' } else { 'T0_Observed' }) `
        -Extra @{
            VmCount = $report.Summary.VmCount
            MksCrashVmCount = $report.Summary.MksCrashVmCount
            Applied = $report.Summary.AppliedActionCount
        }
}

[pscustomobject]@{
    SchemaVersion    = $report.SchemaVersion
    Mode             = $report.Mode
    VmCount          = $report.Summary.VmCount
    CriticalCount    = $report.Summary.CriticalCount
    ImportantCount   = $report.Summary.ImportantCount
    MksCrashVmCount  = $report.Summary.MksCrashVmCount
    StaleLockVmCount = $report.Summary.StaleLockVmCount
    BestNextDecision = $report.BestNextDecision
    OutputJson       = $OutputJson
    InstallFound     = [bool]$report.Install.Found
    ProductVersion   = $report.Install.ProductVersion
}
