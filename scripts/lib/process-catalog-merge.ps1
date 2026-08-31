# Auto-merge operator-identified processes into process-intelligence.json + report refresh.
# HITL gate: catalog write runs only after password-verified identify (unless test SkipAuth + config).

. (Join-Path $PSScriptRoot 'process-pressure-core.ps1')

function Get-CatalogMergeSettings {
    param([string]$HubRoot, $KnowledgeConfig)

    if (-not $KnowledgeConfig) {
        $KnowledgeConfig = Get-ProcessKnowledgeConfig -HubRoot $HubRoot
    }

    $catalogRel = 'config/process-intelligence.json'
    if ($KnowledgeConfig.CatalogPath) { $catalogRel = [string]$KnowledgeConfig.CatalogPath }

    return @{
        Enabled = ($KnowledgeConfig.AutoMergeCatalogOnIdentify -ne $false)
        RebuildReport = ($KnowledgeConfig.AutoRebuildTransparencyReport -ne $false)
        RequireAuth = ($KnowledgeConfig.RequireAuthForCatalogMerge -ne $false)
        MinConfidence = if ($KnowledgeConfig.CatalogMergeMinConfidence) { [double]$KnowledgeConfig.CatalogMergeMinConfidence } else { 0.85 }
        CatalogPath = Join-Path $HubRoot ($catalogRel -replace '/', '\')
        ReportPath = Join-Path $HubRoot 'logs\transparency-report-latest.json'
    }
}

function Build-CatalogEntryFromSources {
    param(
        [string]$ProcessName,
        $Hint,
        $CacheEntry
    )

    $draft = $null
    if ($Hint -and $Hint.SuggestedCatalogEntry) { $draft = $Hint.SuggestedCatalogEntry }

    $category = [string](Get-JsonPropertySafe $CacheEntry 'SuggestedCategory')
    if (-not $category -or $category -eq 'Unknown') {
        $category = if ($draft -and $draft.category) { [string]$draft.category } else { [string]$Hint.SuggestedCategory }
    }
    if (-not $category) { $category = 'Other' }

    $priority = [string](Get-JsonPropertySafe $CacheEntry 'SuggestedPriority')
    if (-not $priority) {
        $priority = if ($draft -and $draft.priority) { [string]$draft.priority } else { [string]$Hint.SuggestedPriority }
    }
    if (-not $priority) { $priority = 'Review' }

    $whatItIs = [string](Get-JsonPropertySafe $CacheEntry 'WhatItIs')
    if (-not $whatItIs) { $whatItIs = [string]$Hint.WhatItIs }

    $whatItDoes = [string](Get-JsonPropertySafe $CacheEntry 'WhatItDoes')
    if (-not $whatItDoes) { $whatItDoes = [string]$Hint.WhatItDoes }

    $resourceProfile = [string](Get-JsonPropertySafe $CacheEntry 'ResourceProfile')
    if (-not $resourceProfile -and $draft -and $draft.resourceProfile) {
        $resourceProfile = [string]$draft.resourceProfile
    }
    if (-not $resourceProfile) { $resourceProfile = [string]$Hint.ResourceProfile }
    if (-not $resourceProfile) { $resourceProfile = 'Mixed' }

    $pressureMitigations = $null
    if ($draft -and $draft.pressureMitigations) { $pressureMitigations = $draft.pressureMitigations }
    if (-not $pressureMitigations) {
        $pressureMitigations = [ordered]@{
            MemoryHeavy = @("Review if RAM justified for active work on $ProcessName")
            CPUBound = @('Check for runaway loops or updates')
            IOHeavy = @('Check disk usage by parent application')
        }
    }

    $refs = [System.Collections.Generic.List[string]]::new()
    foreach ($s in @($Hint.Sources)) {
        if ([string]$s -match '^https?://') { [void]$refs.Add([string]$s) }
    }
    if ($draft -and $draft.references) {
        foreach ($r in @($draft.references)) {
            if ($r -and [string]$r -notin $refs) { [void]$refs.Add([string]$r) }
        }
    }

    $businessHint = [string](Get-JsonPropertySafe $CacheEntry 'BusinessHint')
    if (-not $businessHint) { $businessHint = [string]$Hint.BusinessHint }

    return [ordered]@{
        category = $category
        priority = $priority
        displayName = $ProcessName
        description = $whatItIs
        whatItDoes = $whatItDoes
        resourceProfile = $resourceProfile
        businessHint = $businessHint
        pressureMitigations = $pressureMitigations
        references = @($refs)
        mergedAt = (Get-Date).ToString('o')
        mergedFrom = @('operator-manual-identify', 'kb-hint-enrichment')
    }
}

function Merge-CatalogEntryFields {
    param($Existing, $Incoming)

    if (-not $Existing) { return $Incoming }

    $out = [ordered]@{}
    foreach ($k in @($Incoming.Keys)) { $out[$k] = $Incoming[$k] }

    $existingDesc = [string](Get-JsonPropertySafe $Existing 'description')
    $incomingDesc = [string]$Incoming.description
    if ($existingDesc.Length -gt $incomingDesc.Length + 10) {
        $out.description = $existingDesc
    }

    $existingDoes = [string](Get-JsonPropertySafe $Existing 'whatItDoes')
    $incomingDoes = [string]$Incoming.whatItDoes
    if ($existingDoes.Length -gt $incomingDoes.Length + 10) {
        $out.whatItDoes = $existingDoes
    }

    $prioRank = @{ Keep = 3; Tune = 2; Review = 1 }
    $existPri = [string](Get-JsonPropertySafe $Existing 'priority')
    $inPri = [string]$Incoming.priority
    if ($prioRank.ContainsKey($existPri) -and $prioRank.ContainsKey($inPri)) {
        if ($prioRank[$existPri] -gt $prioRank[$inPri]) { $out.priority = $existPri }
    }

    $refSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($r in @(Get-JsonPropertySafe $Existing 'references')) { if ($r) { [void]$refSet.Add([string]$r) } }
    foreach ($r in @($Incoming.references)) { if ($r) { [void]$refSet.Add([string]$r) } }
    $out.references = @($refSet)

    $mergedFrom = [System.Collections.Generic.List[string]]::new()
    foreach ($s in @(Get-JsonPropertySafe $Existing 'mergedFrom')) { if ($s) { [void]$mergedFrom.Add([string]$s) } }
    foreach ($s in @($Incoming.mergedFrom)) { if ($s -and $s -notin $mergedFrom) { [void]$mergedFrom.Add([string]$s) } }
    $out.mergedFrom = @($mergedFrom)

    return $out
}

function Save-ProcessIntelligenceCatalog {
    param(
        [string]$CatalogPath,
        $CatalogObject
    )

    $dir = Split-Path -Parent $CatalogPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
    ($CatalogObject | ConvertTo-Json -Depth 12) | Out-File -LiteralPath $CatalogPath -Encoding utf8 -Force
}

function Merge-ProcessIntoIntelligenceCatalog {
    param(
        [string]$HubRoot,
        [string]$ProcessName,
        [object]$CatalogEntry,
        [string]$CatalogPath = '',
        [double]$Confidence = 0.98
    )

    if (-not $CatalogPath) {
        $CatalogPath = (Get-CatalogMergeSettings -HubRoot $HubRoot).CatalogPath
    }

    $key = Get-CacheEntryKey -ProcessName $ProcessName
    if ([string]::IsNullOrWhiteSpace($key)) {
        return @{ Ok = $false; Reason = 'empty_process_name' }
    }

    $catalog = Get-ProcessIntelligenceCatalog -CatalogPath $CatalogPath
    if (@($catalog.vitalExact) -contains $key -or @($catalog.securityExact) -contains $key) {
        return @{ Ok = $false; Reason = 'protected_system_process'; ProcessName = $key }
    }

    $logs = Join-Path $HubRoot 'logs'
    if (-not (Test-Path -LiteralPath $logs)) { New-Item -Path $logs -ItemType Directory -Force | Out-Null }
    $rollbackPath = Join-Path $logs ("process-intelligence-rollback-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    if (Test-Path -LiteralPath $CatalogPath) {
        Copy-Item -LiteralPath $CatalogPath -Destination $rollbackPath -Force
    }

    $existingEntry = $null
    if ($catalog.knownApplications) {
        $prop = $catalog.knownApplications.PSObject.Properties[$key]
        if ($prop) { $existingEntry = $prop.Value }
    }

    $mergedEntry = Merge-CatalogEntryFields -Existing $existingEntry -Incoming $CatalogEntry
    if (-not $catalog.knownApplications) {
        $catalog | Add-Member -NotePropertyName knownApplications -NotePropertyValue ([ordered]@{}) -Force
    }

    $known = [ordered]@{}
    foreach ($prop in $catalog.knownApplications.PSObject.Properties) {
        $known[$prop.Name] = $prop.Value
    }
    $known[$key] = $mergedEntry
    $catalog.knownApplications = $known

    Save-ProcessIntelligenceCatalog -CatalogPath $CatalogPath -CatalogObject $catalog

    return [ordered]@{
        Ok = $true
        ProcessName = $key
        CatalogPath = $CatalogPath
        RollbackPath = $rollbackPath
        WasUpdate = ($null -ne $existingEntry)
        Confidence = $Confidence
        TrustLevel = 'T1_Delegated'
    }
}

function Invoke-PostIdentifyCatalogPipeline {
    param(
        [string]$HubRoot,
        [string]$ProcessName,
        [object]$CacheEntry,
        [object]$ProcessSnapshot,
        [double]$Confidence = 0.98,
        [switch]$Offline,
        [switch]$SkipAuth,
        [switch]$SkipCatalogMerge
    )

    $settings = Get-CatalogMergeSettings -HubRoot $HubRoot
    if (-not $settings.Enabled -or $SkipCatalogMerge) {
        return [ordered]@{ Skipped = $true; Reason = if ($SkipCatalogMerge) { 'SkipCatalogMerge' } else { 'disabled' } }
    }
    if ($settings.RequireAuth -and $SkipAuth) {
        return [ordered]@{ Skipped = $true; Reason = 'auth_required_for_catalog_merge' }
    }
    if ($Confidence -lt $settings.MinConfidence) {
        return [ordered]@{ Skipped = $true; Reason = 'confidence_below_threshold'; Confidence = $Confidence }
    }

    $knowCfg = Get-ProcessKnowledgeConfig -HubRoot $HubRoot
    $hub = Get-HubPaths -HubRoot $HubRoot
    $catalog = Get-ProcessIntelligenceCatalog -CatalogPath $settings.CatalogPath
    $maintenanceConfig = $null
    if (Test-Path -LiteralPath $hub.ConfigFile) {
        $maintenanceConfig = Get-MaintenanceConfig -ConfigPath $hub.ConfigFile
    }

    $pid = 0
    $ramMb = 0.0
    $imagePath = [string](Get-JsonPropertySafe $CacheEntry 'ImagePath')
    if ($ProcessSnapshot) {
        if ($ProcessSnapshot.PID) { $pid = [int]$ProcessSnapshot.PID }
        if ($ProcessSnapshot.RamMb) { $ramMb = [double]$ProcessSnapshot.RamMb }
        if ($ProcessSnapshot.Path) { $imagePath = [string]$ProcessSnapshot.Path }
    }

    $hint = Build-ProcessKnowledgeHint `
        -ProcessName $ProcessName `
        -ProcessId $pid `
        -ImagePath $imagePath `
        -RamMb $ramMb `
        -HubRoot $HubRoot `
        -Catalog $catalog `
        -KnowledgeConfig $knowCfg `
        -MaintenanceConfig $maintenanceConfig `
        -Offline:$Offline `
        -AllowWeb:(-not $Offline) `
        -AllowLlm:(-not $Offline)

    $catalogEntry = Build-CatalogEntryFromSources -ProcessName $ProcessName -Hint $hint -CacheEntry $CacheEntry
    $merge = Merge-ProcessIntoIntelligenceCatalog `
        -HubRoot $HubRoot `
        -ProcessName $ProcessName `
        -CatalogEntry $catalogEntry `
        -CatalogPath $settings.CatalogPath `
        -Confidence $Confidence

    $report = [ordered]@{ Rebuilt = $false }
    if ($merge.Ok -and $settings.RebuildReport) {
        $buildScript = Join-Path $HubRoot 'scripts\build-transparency-report.ps1'
        if (Test-Path -LiteralPath $buildScript) {
            & $buildScript -HubRoot $HubRoot -OutputJson $settings.ReportPath | Out-Null
            $report.Rebuilt = $true
            $report.ReportPath = $settings.ReportPath
        }
    }

    return [ordered]@{
        Skipped = $false
        CatalogMerge = $merge
        ReportRefresh = $report
        EnrichedHint = @{
            WhatItIs = [string]$hint.WhatItIs
            WhatItDoes = [string]$hint.WhatItDoes
            BusinessHint = [string]$hint.BusinessHint
            Sources = @($hint.Sources)
        }
    }
}
