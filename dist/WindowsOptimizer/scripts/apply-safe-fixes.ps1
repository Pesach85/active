<#
.SYNOPSIS
    Applies selected solutions from a system-health-audit JSON report.

.DESCRIPTION
    Reads the audit JSON, filters findings by the requested severity/level,
    executes the fix commands, records results, and writes an updated JSON
    with Applied=true for each successful fix.

.PARAMETER InputJson
    Path to the system-health-audit output JSON.

.PARAMETER OutputJson
    Path where the result JSON (with apply status) is written.

.PARAMETER MaxLevel
    Maximum invasiveness level to apply.  Safe | Moderate | Aggressive.
    Only solutions at or below this level are executed.

.PARAMETER FindingIds
    Optional list of specific finding IDs to apply. If omitted, all findings
    with solutions at or below MaxLevel are processed.

.PARAMETER DryRun
    If set, commands are logged but not executed.
#>
param(
    [Parameter(Mandatory)][string]$InputJson,
    [Parameter(Mandatory)][string]$OutputJson,
    [ValidateSet('Safe','Moderate','Aggressive')][string]$MaxLevel = 'Safe',
    [string[]]$FindingIds,
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'

function Write-Progress2 { param([string]$Msg) Write-Host "[APPLY] $Msg" }

# Execute a solution command safely.
# For winget commands: use Start-Process to avoid console-API crashes in hidden PS5.1 workers.
# Returns stdout text. Throws if command fails (non-zero exit for external, exception for PS).
function Invoke-SolutionCommand {
    param([string]$Command)

    $trimmed = $Command.Trim()

    # Detect winget invocations (direct or Start-Process) - run via Start-Process for safe capture
        if ($trimmed -match '(?i)^winget\s+') {
        $parts = $trimmed -split '\s+', 2
        $wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
        $exe = if ($wingetCmd) { $wingetCmd.Path } else { $null }
        if (-not $exe) { throw "winget not found in PATH" }
        $argStr = if ($parts.Count -gt 1) { $parts[1] } else { '' }

        $tmpOut = [System.IO.Path]::GetTempFileName()
        $tmpErr = [System.IO.Path]::GetTempFileName()
        try {
            $p = Start-Process -FilePath $exe -ArgumentList $argStr `
                -Wait -PassThru -NoNewWindow `
                -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr
            $stdout = (Get-Content -LiteralPath $tmpOut -Raw -ErrorAction SilentlyContinue) + `
                      (Get-Content -LiteralPath $tmpErr -Raw -ErrorAction SilentlyContinue)
            if ($p.ExitCode -ne 0) {
                throw ("winget exited with code {0} (0x{1:X8}): {2}" -f $p.ExitCode, $p.ExitCode, $stdout.Trim())
            }
            return $stdout.Trim()
        } finally {
            Remove-Item -LiteralPath $tmpOut -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $tmpErr -Force -ErrorAction SilentlyContinue
        }
    }

    # Default: Invoke-Expression for registry/PS cmdlet commands
    $output = Invoke-Expression $Command 2>&1 | Out-String
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        throw ("Command exited with code {0}: {1}" -f $LASTEXITCODE, $output.Trim())
    }
    return $output.Trim()
}

# Level ordering: lower = less invasive
$levelOrder = @{ 'Safe' = 0; 'Moderate' = 1; 'Aggressive' = 2; 'Info' = -1 }

if (-not (Test-Path $InputJson)) {
    Write-Error "Audit report not found: $InputJson"
    exit 1
}

Write-Progress2 "Loading audit report from $InputJson..."
$report = Get-Content -Raw $InputJson -EA Stop | ConvertFrom-Json -EA Stop

$results = [System.Collections.ArrayList]::new()
$appliedCount = 0
$failedCount  = 0
$skippedCount = 0

foreach ($finding in $report.Findings) {
    $fId = $finding.Id

    # Filter by explicit IDs if provided
    if ($FindingIds -and $FindingIds.Count -gt 0) {
        if ($fId -notin $FindingIds) {
            $skippedCount++
            continue
        }
    }

    # Skip already-applied findings
        if ($finding.Applied -eq $true) {
            Write-Progress2 "  $fId - already applied, skipping."
        $skippedCount++
        continue
    }

    # Find ALL solutions at or below MaxLevel
    $applicableSolutions = @()
    foreach ($sol in $finding.Solutions) {
        $solLevel = $levelOrder[$sol.Level]
        if ($solLevel -ge 0 -and $solLevel -le $levelOrder[$MaxLevel]) {
            $applicableSolutions += $sol
        }
    }

    if ($applicableSolutions.Count -eq 0) {
            Write-Progress2 "  $fId - no solution at level <=$MaxLevel. Skipping."
        $skippedCount++
        [void]$results.Add([ordered]@{
            FindingId = $fId
            Status    = 'Skipped'
            Reason    = "No solution at or below $MaxLevel level"
            Level     = $null
            Label     = $null
        })
        continue
    }

    foreach ($bestSolution in $applicableSolutions) {
            Write-Progress2 "  $fId - applying [$($bestSolution.Level)] $($bestSolution.Label)..."

        if ($DryRun) {
                Write-Progress2 "    DRY RUN - command: $($bestSolution.Command)"
            [void]$results.Add([ordered]@{
                FindingId = $fId
                Status    = 'DryRun'
                Level     = $bestSolution.Level
                Label     = $bestSolution.Label
                Command   = $bestSolution.Command
            })
            continue
        }

        try {
            $output = Invoke-SolutionCommand -Command $bestSolution.Command
            $finding.Applied = $true
            $finding.AppliedLevel = $bestSolution.Level
            $finding.AppliedAt = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
            $appliedCount++
            Write-Progress2 "    SUCCESS. Output: $output"
            [void]$results.Add([ordered]@{
                FindingId = $fId
                Status    = 'Applied'
                Level     = $bestSolution.Level
                Label     = $bestSolution.Label
                Output    = $output
            })
        } catch {
            $failedCount++
            Write-Progress2 "    FAILED: $($_.Exception.Message)"
            [void]$results.Add([ordered]@{
                FindingId = $fId
                Status    = 'Failed'
                Level     = $bestSolution.Level
                Label     = $bestSolution.Label
                Error     = $_.Exception.Message
            })
        }
    }
}

# Write updated report with apply status
$outputReport = [ordered]@{
    ApplyVersion  = '1.0.0'
    Timestamp     = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
    MaxLevel      = $MaxLevel
    DryRun        = [bool]$DryRun
    Results       = @($results.ToArray())
    Summary       = [ordered]@{
        Applied  = $appliedCount
        Failed   = $failedCount
        Skipped  = $skippedCount
    }
    UpdatedReport = $report
}

try {
    $json = $outputReport | ConvertTo-Json -Depth 12 -Compress:$false
    [System.IO.File]::WriteAllText($OutputJson, $json, [System.Text.Encoding]::UTF8)
    Write-Progress2 ("Done. Applied={0} Failed={1} Skipped={2}" -f $appliedCount, $failedCount, $skippedCount)
} catch {
    Write-Error "[APPLY] FATAL: Failed to write output JSON to '$OutputJson': $($_.Exception.Message)"
    exit 1
}
