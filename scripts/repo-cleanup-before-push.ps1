param(
    [switch]$Apply,
    [switch]$CheckOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info {
    param([string]$Message)
    Write-Host "[REPO-CLEANUP] $Message"
}

function Normalize-Path {
    param([string]$Path)
    return ($Path -replace '\\','/').Trim()
}

function Test-IsRuntimeArtifact {
    param([string]$Path)

    $p = Normalize-Path -Path $Path

    if ($p -match '^dist/.+/logs/.+\.(json|log|csv)$') { return $true }
    if ($p -match '^logs/.+-live\.json$') { return $true }
    if ($p -match '^logs/health-audit-postreboot\.json$') { return $true }
    if ($p -match '^logs/post-reboot-verification\.json$') { return $true }
    if ($p -match '^logs/deepscan-.+\.json$') { return $true }

    return $false
}

function Get-GitStatusEntries {
    $lines = @(git status --porcelain)
    $entries = New-Object System.Collections.Generic.List[object]

    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        if ($line.Length -lt 4) { continue }

        $code = $line.Substring(0, 2)
        $rawPath = $line.Substring(3)

        if ($code -like 'R*' -and $rawPath -like '* -> *') {
            $rawPath = ($rawPath -split ' -> ')[1]
        }

        $entries.Add([pscustomobject]@{
            Code = $code
            Path = $rawPath.Trim()
        })
    }

    return $entries.ToArray()
}

$mode = if ($CheckOnly) { 'check-only' } elseif ($Apply) { 'apply' } else { 'apply' }
$doApply = $mode -eq 'apply'

Write-Info "Mode: $mode"

$entries = Get-GitStatusEntries
$runtimeEntries = @($entries | Where-Object { Test-IsRuntimeArtifact -Path $_.Path })

if (-not $runtimeEntries -or $runtimeEntries.Count -eq 0) {
    Write-Info "No runtime artifacts detected in working tree."
    exit 0
}

Write-Info ("Detected {0} runtime artifact change(s)." -f $runtimeEntries.Count)

if ($doApply) {
    $restored = 0
    $removed = 0

    foreach ($entry in $runtimeEntries) {
        $path = $entry.Path
        $code = $entry.Code

        if ($code -eq '??') {
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
                $removed++
                Write-Info ("Removed untracked runtime file: {0}" -f $path)
            }
            continue
        }

        git restore -- $path | Out-Null
        $restored++
        Write-Info ("Restored tracked runtime file: {0}" -f $path)
    }

    Write-Info ("Cleanup actions completed. Restored={0}, Removed={1}" -f $restored, $removed)
}

$remaining = @(Get-GitStatusEntries | Where-Object { Test-IsRuntimeArtifact -Path $_.Path })
if ($remaining.Count -gt 0) {
    Write-Info "Runtime artifacts still dirty after cleanup/check. Push blocked."
    foreach ($r in $remaining) {
        Write-Info ("  {0} {1}" -f $r.Code, $r.Path)
    }
    exit 2
}

Write-Info "Runtime artifact gate passed."
exit 0
