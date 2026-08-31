# Append structured audit event for transparency dashboard (jsonl).
function Write-TransparencyEvent {
    param(
        [string]$EventsPath,
        [string]$Action,
        [string]$Detail,
        [string]$AgentId = 'resource-monitor',
        [ValidateSet('T0_Observed', 'T1_Delegated', 'T2_Review', 'T3_Unknown')]
        [string]$ControlLevel = 'T1_Delegated',
        [hashtable]$Extra = @{}
    )

    if ([string]::IsNullOrWhiteSpace($EventsPath)) { return }

    $dir = Split-Path -Parent $EventsPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }

    $payload = [ordered]@{
        Timestamp = (Get-Date).ToString('o')
        Action = $Action
        Detail = $Detail
        AgentId = $AgentId
        ControlLevel = $ControlLevel
    }
    foreach ($key in $Extra.Keys) { $payload[$key] = $Extra[$key] }

    ($payload | ConvertTo-Json -Compress) | Out-File -LiteralPath $EventsPath -Encoding utf8 -Append
}
