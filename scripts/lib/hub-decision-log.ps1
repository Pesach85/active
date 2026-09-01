# Structured decision / HITL effectiveness log for NBD and agent self-assessment (JSONL + snapshot).

function Get-HubDecisionLogPath {
    param([string]$HubRoot = '')
    if (-not $HubRoot) { $HubRoot = $env:HUB_ROOT }
    if (-not $HubRoot) {
        $libDir = $PSScriptRoot
        $HubRoot = Split-Path (Split-Path -Parent $libDir) -Parent
    }
    $logsDir = Join-Path $HubRoot 'logs'
    if (-not (Test-Path -LiteralPath $logsDir)) {
        New-Item -Path $logsDir -ItemType Directory -Force | Out-Null
    }
    return Join-Path $logsDir 'hub-decision-log.jsonl'
}

function Get-HubDecisionEffectivenessPath {
    param([string]$HubRoot = '')
    if (-not $HubRoot) { $HubRoot = $env:HUB_ROOT }
    if (-not $HubRoot) {
        $libDir = $PSScriptRoot
        $HubRoot = Split-Path (Split-Path -Parent $libDir) -Parent
    }
    return Join-Path $HubRoot 'logs\hub-decision-effectiveness-latest.json'
}

function Write-HubDecisionLog {
    param(
        [string]$HubRoot = '',
        [Parameter(Mandatory = $true)][string]$Domain,
        [string]$Path = 'ps',
        [Parameter(Mandatory = $true)][string]$Action,
        [string]$Outcome = '',
        [bool]$Success = $true,
        [string]$HubCoreVersion = '',
        [int]$DurationMs = 0,
        [hashtable]$Context = @{},
        [string]$EffectivenessHint = ''
    )

    $logPath = Get-HubDecisionLogPath -HubRoot $HubRoot
    if (-not $EffectivenessHint) {
        $EffectivenessHint = if ($Success) { 'success' } else { 'failed' }
        if ($Outcome -match 'Blocked|NotRunning|expired|missing|failed') { $EffectivenessHint = 'blocked-or-failed' }
    }

    $entry = [ordered]@{
        SchemaVersion = 'HubDecisionLogEntry.v1'
        Timestamp = (Get-Date).ToString('o')
        Domain = $Domain
        Path = $Path
        Action = $Action
        Outcome = $Outcome
        Success = [bool]$Success
        HubCoreVersion = $HubCoreVersion
        DurationMs = $DurationMs
        Context = $Context
        EffectivenessHint = $EffectivenessHint
    }

    ($entry | ConvertTo-Json -Compress -Depth 6) | Out-File -LiteralPath $logPath -Encoding utf8 -Append
}

function Read-HubDecisionLogEntries {
    param(
        [string]$HubRoot = '',
        [int]$MaxLines = 2000,
        [int]$LookbackDays = 30
    )

    $logPath = Get-HubDecisionLogPath -HubRoot $HubRoot
    if (-not (Test-Path -LiteralPath $logPath)) { return @() }

    $cutoff = (Get-Date).AddDays(-1 * [math]::Abs($LookbackDays))
    $lines = Get-Content -LiteralPath $logPath -Tail $MaxLines -ErrorAction SilentlyContinue
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($line in @($lines)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $e = $line | ConvertFrom-Json
            $ts = [datetime]$e.Timestamp
            if ($ts -lt $cutoff) { continue }
            [void]$entries.Add($e)
        } catch { }
    }
    return @($entries)
}

function Build-HubDecisionEffectivenessReport {
    param(
        [string]$HubRoot = '',
        [int]$LookbackDays = 30
    )

    $entries = Read-HubDecisionLogEntries -HubRoot $HubRoot -LookbackDays $LookbackDays
    $byDomain = @{}
    foreach ($e in $entries) {
        $d = [string]$e.Domain
        if (-not $byDomain.ContainsKey($d)) {
            $byDomain[$d] = [ordered]@{
                Domain = $d
                Total = 0
                Success = 0
                Failed = 0
                Outcomes = @{}
            }
        }
        $bucket = $byDomain[$d]
        $bucket.Total++
        if ([bool]$e.Success) { $bucket.Success++ } else { $bucket.Failed++ }
        $oc = [string]$e.Outcome
        if ($oc) {
            if (-not $bucket.Outcomes.ContainsKey($oc)) { $bucket.Outcomes[$oc] = 0 }
            $bucket.Outcomes[$oc] = [int]$bucket.Outcomes[$oc] + 1
        }
    }

    $domainStats = @($byDomain.Values | ForEach-Object {
        $rate = if ($_.Total -gt 0) { [math]::Round(100.0 * $_.Success / $_.Total, 1) } else { $null }
        [ordered]@{
            Domain = $_.Domain
            Total = $_.Total
            Success = $_.Success
            Failed = $_.Failed
            SuccessRatePercent = $rate
            Outcomes = $_.Outcomes
        }
    })

    $hitlSession = @($domainStats | Where-Object { $_.Domain -eq 'hitl-session' } | Select-Object -First 1)
    $resolve = @($domainStats | Where-Object { $_.Domain -eq 'resolve-apply' } | Select-Object -First 1)
    $identify = @($domainStats | Where-Object { $_.Domain -eq 'identify' } | Select-Object -First 1)
    $defender = @($domainStats | Where-Object { $_.Domain -eq 'defender-apply' } | Select-Object -First 1)

    $sessionOk = ($hitlSession -and $hitlSession.Success -ge 1 -and ($null -eq $hitlSession.SuccessRatePercent -or $hitlSession.SuccessRatePercent -ge 80))
    $resolveOk = (-not $resolve) -or ($resolve.Total -eq 0) -or ($resolve.SuccessRatePercent -ge 75)
    $identifyOk = (-not $identify) -or ($identify.Total -eq 0) -or ($identify.SuccessRatePercent -ge 75)

    $recommendations = [System.Collections.Generic.List[object]]::new()
    if ($sessionOk -and $resolveOk -and $identifyOk) {
        [void]$recommendations.Add([ordered]@{
            CandidateId = 'phase4-hub-use-core'
            ReadyForRollout = $true
            Reason = 'HITL session stable; resolve/identify success rates within threshold (last {0}d).' -f $LookbackDays
        })
    } else {
        $parts = @()
        if (-not $sessionOk) { $parts += 'session' }
        if (-not $resolveOk) { $parts += 'resolve' }
        if (-not $identifyOk) { $parts += 'identify' }
        [void]$recommendations.Add([ordered]@{
            CandidateId = 'phase4-hub-use-core'
            ReadyForRollout = $false
            Reason = ('Collect more successful HITL evidence: weak — {0}.' -f ($parts -join ', '))
        })
    }

    $overallSuccess = ($entries | Where-Object { [bool]$_.Success }).Count
    $overallTotal = $entries.Count
    $overallRate = if ($overallTotal -gt 0) { [math]::Round(100.0 * $overallSuccess / $overallTotal, 1) } else { $null }

    return [ordered]@{
        SchemaVersion = 'HubDecisionEffectiveness.v1'
        GeneratedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        LookbackDays = $LookbackDays
        EntryCount = $overallTotal
        OverallSuccessRatePercent = $overallRate
        ByDomain = $domainStats
        Signals = [ordered]@{
            HitlSessionStable = [bool]$sessionOk
            ResolveApplyHealthy = [bool]$resolveOk
            IdentifyHealthy = [bool]$identifyOk
        }
        NbdRecommendations = @($recommendations)
    }
}

function Export-HubDecisionEffectivenessReport {
    param(
        [string]$HubRoot = '',
        [int]$LookbackDays = 30
    )

    $report = Build-HubDecisionEffectivenessReport -HubRoot $HubRoot -LookbackDays $LookbackDays
    $outPath = Get-HubDecisionEffectivenessPath -HubRoot $HubRoot
    ($report | ConvertTo-Json -Depth 8) | Out-File -LiteralPath $outPath -Encoding utf8 -Force
    return $report
}
