<#
.SYNOPSIS
  Deterministic smoke gate for hub engines (no GUI). Exit 0 only if all pass.
.DESCRIPTION
  Validates health-audit, garbage-hotspots, and privacy-scan produce parseable output.
  Does not apply fixes or delete files.
#>
[CmdletBinding()]
param(
    [string]$HubRoot,
    [switch]$SkipPrivacy
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $HubRoot) {
    $HubRoot = Split-Path -Parent $scriptDir
}

$logs = Join-Path $HubRoot 'logs'
if (-not (Test-Path -LiteralPath $logs)) {
    New-Item -Path $logs -ItemType Directory -Force | Out-Null
}

$pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
$pwsh = if ($pwshCmd) { $pwshCmd.Path } else { (Get-Command powershell).Path }

$failures = [System.Collections.Generic.List[string]]::new()

function Invoke-SmokeStep {
    param(
        [string]$Name,
        [string]$ScriptPath,
        [string[]]$Arguments,
        [string]$OutputPath,
        [scriptblock]$Validate
    )

    Write-Host ("[SMOKE] {0}..." -f $Name)
    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        $failures.Add("$Name missing script: $ScriptPath")
        return
    }

    if (Test-Path -LiteralPath $OutputPath) {
        Remove-Item -LiteralPath $OutputPath -Force -ErrorAction SilentlyContinue
    }

    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + $Arguments
    $p = Start-Process -FilePath $pwsh -ArgumentList $argList -Wait -PassThru -WindowStyle Hidden
    if ($p.ExitCode -ne 0) {
        $failures.Add("$Name exit $($p.ExitCode)")
        return
    }

    if (-not (Test-Path -LiteralPath $OutputPath)) {
        $failures.Add("$Name missing output: $OutputPath")
        return
    }

    try {
        & $Validate $OutputPath
        Write-Host ("[SMOKE] {0} OK" -f $Name)
    } catch {
        $failures.Add("$Name validate failed: $($_.Exception.Message)")
    }
}

$healthOut = Join-Path $logs 'smoke-health.json'
Invoke-SmokeStep -Name 'health-audit' `
    -ScriptPath (Join-Path $scriptDir 'system-health-audit.ps1') `
    -Arguments @('-OutputJson', $healthOut) `
    -OutputPath $healthOut `
    -Validate {
        param($path)
        $j = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ($null -eq $j.Findings) { throw 'Findings missing' }
        if ($null -eq $j.AlreadyOptimized) { throw 'AlreadyOptimized missing' }
        if ($null -eq $j.Summary) { throw 'Summary missing' }
        # AlreadyOptimized must be strings (not objects with .Id) — GUI contract
        $sample = @($j.AlreadyOptimized) | Select-Object -First 1
        if ($null -ne $sample -and $sample -isnot [string] -and $sample.PSObject.Properties['Id']) {
            throw 'AlreadyOptimized entries look like objects with Id (unexpected schema)'
        }
    }

$garbageCsv = Join-Path $logs 'smoke-garbage.csv'
Invoke-SmokeStep -Name 'garbage-hotspots' `
    -ScriptPath (Join-Path $scriptDir 'analyze-garbage-hotspots.ps1') `
    -Arguments @('-Depth', 'Quick', '-Top', '5', '-OutputCsv', $garbageCsv, '-Drives', 'C') `
    -OutputPath $garbageCsv `
    -Validate {
        param($path)
        $rows = Import-Csv -LiteralPath $path
        if (@($rows).Count -lt 1) { throw 'CSV empty' }
        $cols = $rows[0].PSObject.Properties.Name
        foreach ($need in @('Score', 'Path', 'EstimatedReclaimGB')) {
            if ($cols -notcontains $need) { throw "Missing column $need" }
        }
    }

if (-not $SkipPrivacy) {
    $privacyOut = Join-Path $logs 'smoke-privacy.json'
    Invoke-SmokeStep -Name 'privacy-scan' `
        -ScriptPath (Join-Path $scriptDir 'privacy-scan-secrets.ps1') `
        -Arguments @('-OutputJson', $privacyOut) `
        -OutputPath $privacyOut `
        -Validate {
            param($path)
            $j = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $schema = [string]$j.SchemaVersion
            if ($schema -notmatch 'PrivacyScanReport') { throw "Unexpected schema: $schema" }
            if ($null -eq $j.Findings) { throw 'Findings missing' }
        }
}

# Module presence (GUI modularization gate)
foreach ($mod in @('gui\theme.ps1', 'gui\worker-helpers.ps1', 'gui\async-worker.ps1', 'gui\i18n.ps1', 'gui\command-help.ps1')) {
    $p = Join-Path $scriptDir $mod
    if (-not (Test-Path -LiteralPath $p)) {
        $failures.Add("Missing module: $mod")
    }
}

if ($failures.Count -gt 0) {
    Write-Host '[SMOKE] FAILED'
    $failures | ForEach-Object { Write-Host ("  - {0}" -f $_) }
    exit 1
}

Write-Host '[SMOKE] ALL PASSED'
exit 0
