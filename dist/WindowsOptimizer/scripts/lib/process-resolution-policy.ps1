# Unknown process resolution â€” mathematically efficient action ranking (reversible first).
# Human operator is sole authority; AI aids advisory only.

function Get-ProcessResolutionConfig {
    param([string]$HubRoot)

    $path = Join-Path $HubRoot 'config\process-resolution.json'
    if (-not (Test-Path -LiteralPath $path)) {
        return @{
            ConfirmPhraseTerminate = 'STOP UNKNOWN'
            ConfirmPhraseMarkNecessary = 'KEEP FOR WORK'
            HighRamThresholdMb = 400
            LowRamThresholdMb = 80
            UnidentifiedConfidenceThreshold = 0.72
            PreferReversibleActions = $true
            OperatorDecisionsPath = 'KB/operator-process-decisions.json'
            NeverTerminateExact = @('System', 'csrss', 'lsass', 'MsMpEng', 'Cursor', 'pwsh')
        }
    }
    return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
}

function Get-OperatorProcessDecisions {
    param([string]$HubRoot, [string]$RelPath)

    $path = Join-Path $HubRoot ($RelPath -replace '/', '\')
    if (-not (Test-Path -LiteralPath $path)) {
        return @{ Path = $path; Decisions = @{} }
    }
    try {
        $raw = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        return @{ Path = $path; Raw = $raw; Decisions = $raw.Decisions }
    } catch {
        return @{ Path = $path; Decisions = @{} }
    }
}

function Get-OperatorDecisionForProcess {
    param($DecisionsObj, [string]$ProcessName)

    if (-not $DecisionsObj) { return $null }
    $key = ([string]$ProcessName).ToLowerInvariant().Replace('.exe', '')
    $dec = $DecisionsObj.Decisions
    if (-not $dec) { return $null }
    if ($dec -is [System.Collections.IDictionary]) {
        if ($dec.ContainsKey($key)) { return $dec[$key] }
    } else {
        $p = $dec.PSObject.Properties[$key]
        if ($p) { return $p.Value }
    }
    return $null
}

function Save-OperatorProcessDecision {
    param(
        [string]$Path,
        [string]$ProcessName,
        [string]$Decision,
        [string]$Note = ''
    )

    $key = ([string]$ProcessName).ToLowerInvariant().Replace('.exe', '')
    $doc = @{ SchemaVersion = 'OperatorProcessDecisions.v1'; UpdatedAt = (Get-Date).ToString('o'); Decisions = @{} }
    if (Test-Path -LiteralPath $Path) {
        try {
            $existing = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
            if ($existing.Decisions) {
                foreach ($prop in $existing.Decisions.PSObject.Properties) {
                    $doc.Decisions[$prop.Name] = $prop.Value
                }
            }
        } catch { }
    }

    $doc.Decisions[$key] = [ordered]@{
        ProcessName = $ProcessName
        Decision = $Decision
        Note = $Note
        RecordedAt = (Get-Date).ToString('o')
        RecordedBy = 'operator'
    }

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    ($doc | ConvertTo-Json -Depth 8) | Out-File -LiteralPath $Path -Encoding utf8 -Force
}

function Get-ProcessLiveSnapshot {
    param([int]$ProcessId, [string]$ProcessName = '')

    $proc = $null
    if ($ProcessId -gt 0) {
        try { $proc = Get-Process -Id $ProcessId -ErrorAction Stop } catch { }
    }
    if (-not $proc -and $ProcessName) {
        try { $proc = Get-Process -Name ($ProcessName -replace '\.exe$','') -ErrorAction Stop | Select-Object -First 1 } catch { }
    }
    if (-not $proc) { return $null }

    return [ordered]@{
        PID = $proc.Id
        ProcessName = $proc.ProcessName
        RamMb = [math]::Round($proc.WorkingSet64 / 1MB, 1)
        CpuSec = [math]::Round($proc.CPU, 1)
        Responding = $proc.Responding
        PriorityClass = [string]$proc.PriorityClass
        Path = try { [string]$proc.Path } catch { '' }
    }
}

function Get-ProcessResolutionAdvisory {
    param(
        $ProcessSnapshot,
        $KnowledgeHint,
        $ResolutionConfig,
        $OperatorDecision = $null
    )

    if (-not $ProcessSnapshot) { throw 'ProcessSnapshot required' }

    $name = [string]$ProcessSnapshot.ProcessName
    $ram = [double]$ProcessSnapshot.RamMb
    $highRam = [double]$ResolutionConfig.HighRamThresholdMb
    $lowRam = [double]$ResolutionConfig.LowRamThresholdMb
    $confThreshold = [double]$ResolutionConfig.UnidentifiedConfidenceThreshold

    $confidence = 0.55
    $trustLevel = 'T3_Unknown'
    $whatItIs = 'Unknown process'
    $category = 'Unknown'
    if ($KnowledgeHint) {
        $confidence = [double]$KnowledgeHint.Confidence
        $trustLevel = [string]$KnowledgeHint.TrustLevel
        $whatItIs = [string]$KnowledgeHint.WhatItIs
        $category = [string]$KnowledgeHint.SuggestedCategory
    }

    $identifiable = $confidence -ge $confThreshold -and $category -ne 'Unknown'
    $operatorChoice = $null
    if ($OperatorDecision) { $operatorChoice = [string]$OperatorDecision.Decision }

    $warnings = [System.Collections.Generic.List[string]]::new()
    $options = [System.Collections.Generic.List[object]]::new()

    function Add-Option {
        param([string]$Id, [string]$Label, [int]$Cost, [string]$Rationale, [bool]$Reversible, [bool]$RequiresHitl)
        [void]$options.Add([ordered]@{
            ActionId = $Id
            Label = $Label
            EfficiencyCost = $Cost
            Rationale = $Rationale
            Reversible = $Reversible
            RequiresHitl = $RequiresHitl
        })
    }

    if ($operatorChoice -eq 'WorkNecessary') {
        [void]$warnings.Add('Operator marked this process as necessary for work â€” terminate not recommended.')
        Add-Option -Id 'Observe' -Label 'Keep running (operator approved)' -Cost 0 -Rationale 'You marked it work-necessary.' -Reversible $true -RequiresHitl $false
        Add-Option -Id 'ThrottleBelowNormal' -Label 'Throttle if RAM/CPU spikes' -Cost 1 -Rationale 'Reversible relief without stopping work tool.' -Reversible $true -RequiresHitl $false
        $recommended = 'Observe'
    }
    elseif ($operatorChoice -eq 'Unneeded') {
        [void]$warnings.Add('Operator marked unneeded â€” terminate available with confirmation.')
        Add-Option -Id 'ThrottleBelowNormal' -Label 'Throttle first (reversible)' -Cost 1 -Rationale 'Try cheap relief before kill.' -Reversible $true -RequiresHitl $false
        Add-Option -Id 'Terminate' -Label 'Stop process' -Cost 10 -Rationale 'You marked it unneeded.' -Reversible $false -RequiresHitl $true
        $recommended = 'ThrottleBelowNormal'
    }
    elseif (-not $identifiable -and $ram -ge $highRam) {
        [void]$warnings.Add('Cannot reliably identify this process and it uses significant RAM.')
        [void]$warnings.Add('Most efficient safe path: reversible throttle BEFORE terminate.')
        Add-Option -Id 'ThrottleBelowNormal' -Label 'Throttle (BelowNormal) â€” recommended' -Cost 1 `
            -Rationale 'Mathematically cheapest reversible action for unknown high-RAM.' -Reversible $true -RequiresHitl $false
        Add-Option -Id 'Observe' -Label 'Observe 24h' -Cost 0 -Rationale 'Zero cost if you need time to investigate.' -Reversible $true -RequiresHitl $false
        Add-Option -Id 'MarkWorkNecessary' -Label 'Mark necessary for my work' -Cost 0 `
            -Rationale 'Stops future terminate recommendations.' -Reversible $true -RequiresHitl $true
        Add-Option -Id 'Terminate' -Label 'Stop process (last resort)' -Cost 10 `
            -Rationale 'Use only if you accept data loss risk for this app.' -Reversible $false -RequiresHitl $true
        $recommended = 'ThrottleBelowNormal'
    }
    elseif (-not $identifiable -and $ram -lt $lowRam) {
        [void]$warnings.Add('Low RAM unknown process â€” observe unless network egress is suspicious.')
        Add-Option -Id 'Observe' -Label 'Observe â€” recommended' -Cost 0 -Rationale 'Low resource cost; investigate before action.' -Reversible $true -RequiresHitl $false
        Add-Option -Id 'MarkWorkNecessary' -Label 'Mark work-necessary' -Cost 0 -Rationale 'If you know this belongs to your workflow.' -Reversible $true -RequiresHitl $true
        Add-Option -Id 'Terminate' -Label 'Stop process' -Cost 10 -Rationale 'Only if you are sure it is unwanted.' -Reversible $false -RequiresHitl $true
        $recommended = 'Observe'
    }
    elseif ($identifiable) {
        [void]$warnings.Add("Identified with confidence $confidence â€” prefer classify in catalog over terminate.")
        Add-Option -Id 'Observe' -Label 'Keep + classify in catalog' -Cost 0 -Rationale 'Add to process-intelligence after review.' -Reversible $true -RequiresHitl $false
        Add-Option -Id 'MarkWorkNecessary' -Label 'Mark necessary for work' -Cost 0 -Rationale 'Document operator decision now.' -Reversible $true -RequiresHitl $true
        Add-Option -Id 'ThrottleBelowNormal' -Label 'Throttle if pressure continues' -Cost 1 -Rationale 'Tune without kill.' -Reversible $true -RequiresHitl $false
        Add-Option -Id 'Terminate' -Label 'Stop anyway (override)' -Cost 10 -Rationale 'Operator override â€” HITL only.' -Reversible $false -RequiresHitl $true
        $recommended = 'Observe'
    }
    else {
        Add-Option -Id 'Observe' -Label 'Observe' -Cost 0 -Rationale 'Default when uncertain.' -Reversible $true -RequiresHitl $false
        Add-Option -Id 'ThrottleBelowNormal' -Label 'Throttle' -Cost 1 -Rationale 'Reversible step.' -Reversible $true -RequiresHitl $false
        Add-Option -Id 'Terminate' -Label 'Terminate' -Cost 10 -Rationale 'HITL required.' -Reversible $false -RequiresHitl $true
        $recommended = 'Observe'
    }

    $sorted = @($options | Sort-Object { [int]$_.EfficiencyCost })
    $recObj = @($sorted | Where-Object { $_.ActionId -eq $recommended } | Select-Object -First 1)

    return [ordered]@{
        SchemaVersion = 'ProcessResolutionAdvisory.v1'
        ProcessName = $name
        PID = [int]$ProcessSnapshot.PID
        RamMb = $ram
        Identifiable = $identifiable
        Confidence = $confidence
        TrustLevel = $trustLevel
        WhatItIs = $whatItIs
        OperatorDecision = $operatorChoice
        Warnings = @($warnings)
        RecommendedActionId = $recommended
        Recommended = if ($recObj) { $recObj[0] } else { $null }
        Options = $sorted
        AiAidedSummary = if ($identifiable) {
            "AI/KB suggests: $whatItIs ($category). Prefer catalog merge over kill."
        } else {
            "AI/KB cannot fully identify '$name'. Reversible throttle is the efficient first step if RAM is high."
        }
        ControlLevel = 'T2_Review'
        RequiresOperatorApproval = $true
    }
}

function Test-ProcessTerminateAllowed {
    param([string]$ProcessName, $ResolutionConfig)

    $never = @($ResolutionConfig.NeverTerminateExact)
    $base = ($ProcessName -replace '\.exe$','')
    foreach ($n in $never) {
        if ($base -ieq $n) {
            return @{ Allowed = $false; Reason = "Process '$base' is protected by resolution policy" }
        }
    }
    return @{ Allowed = $true; Reason = 'OK' }
}
