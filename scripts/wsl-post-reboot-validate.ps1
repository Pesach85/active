# One-shot post-reboot WSL validation. Registered by repair flow, self-deletes task.
$ErrorActionPreference = 'Continue'
$hubRoot = Split-Path -Parent $PSScriptRoot
$repairScript = Join-Path $PSScriptRoot 'repair-wsl-config.ps1'
$outPath = Join-Path $hubRoot 'logs\diagnostics\wsl-post-reboot-validation.json'
$taskName = 'SystemOptimizerHub-WslPostRebootValidate'

function Write-Result {
    param([hashtable]$Payload)
    $dir = Split-Path -Parent $outPath
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
    ($Payload | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $outPath -Encoding UTF8
}

$report = [ordered]@{
    Timestamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    Phase     = 'PostReboot'
}

try {
    $deadline = (Get-Date).AddMinutes(3)
    while ((Get-Date) -lt $deadline) {
        $svc = Get-Service -Name 'WslService' -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') { break }
        Start-Sleep -Seconds 5
    }

  Start-Sleep -Seconds 15

    $assessRaw = & pwsh -NoProfile -ExecutionPolicy Bypass -File $repairScript 2>&1 | Out-String
    $assessment = $assessRaw | ConvertFrom-Json
    $report.Assessment = $assessment

    if ($assessment.Status -eq 'Ready') {
        $launchRaw = & pwsh -NoProfile -ExecutionPolicy Bypass -File $repairScript -ValidateLaunch 2>&1 | Out-String
        $report.LaunchValidation = $launchRaw | ConvertFrom-Json
        $report.Success = ($report.LaunchValidation.Status -eq 'Ready')
    } else {
        $report.Success = $false
        $report.Note = 'Assessment not Ready after reboot; launch probe skipped.'
    }
} catch {
    $report.Success = $false
    $report.Error = $_.Exception.Message
}

Write-Result -Payload $report

schtasks /Delete /TN $taskName /F 2>$null | Out-Null
