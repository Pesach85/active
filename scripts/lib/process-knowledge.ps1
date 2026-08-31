# Process knowledge enrichment — deterministic first, cache, KB, web, optional LLM.
# Transparency contract: hints are T2_Review until human merges catalog.

$script:ProcessKnowledgeSchema = 'ProcessKnowledgeHint.v1'
$script:WebRequestsThisRun = 0

. (Join-Path $PSScriptRoot 'process-forensics.ps1')

function Get-ProcessKnowledgeConfig {
    param([string]$HubRoot, [string]$ConfigPath = '')

    if (-not $ConfigPath) {
        $ConfigPath = Join-Path $HubRoot 'config\process-knowledge.json'
    }
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        return @{
            Enabled = $true
            CachePath = 'KB/process-knowledge-cache.json'
            CacheTtlDays = 30
            MaxEnrichPerRun = 6
            WebLookupEnabled = $true
            WebTimeoutSeconds = 5
            MaxWebRequestsPerRun = 2
            UseLlmWhenAllowed = $true
            PersistLearnings = $true
            WikipediaLookupEnabled = $true
            MinConfidenceToPersist = 0.65
        }
    }
    return (Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json)
}

function Get-ProcessKnowledgeCache {
    param([string]$HubRoot, [string]$CacheRelPath)

    $path = if ([System.IO.Path]::IsPathRooted($CacheRelPath)) {
        $CacheRelPath
    } else {
        Join-Path $HubRoot ($CacheRelPath -replace '/', '\')
    }
    if (-not (Test-Path -LiteralPath $path)) {
        return @{ SchemaVersion = 'ProcessKnowledgeCache.v1'; Entries = @{}; Path = $path }
    }
    try {
        $raw = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        return @{ Raw = $raw; Path = $path; Entries = $raw.Entries }
    } catch {
        return @{ SchemaVersion = 'ProcessKnowledgeCache.v1'; Entries = @{}; Path = $path }
    }
}

function Get-CacheEntryKey {
    param([string]$ProcessName)
    return ([string]$ProcessName).ToLowerInvariant().Replace('.exe', '')
}

function Get-ProcessKnowledgeFromCache {
    param($Cache, [string]$ProcessName, [int]$TtlDays = 30)

    if (-not $Cache -or -not $Cache.Entries) { return $null }
    $key = Get-CacheEntryKey $ProcessName
    $entry = $null
    if ($Cache.Entries -is [System.Collections.IDictionary]) {
        if ($Cache.Entries.ContainsKey($key)) { $entry = $Cache.Entries[$key] }
    } else {
        $prop = $Cache.Entries.PSObject.Properties[$key]
        if ($prop) { $entry = $prop.Value }
    }
    if (-not $entry) { return $null }

    $learned = Get-JsonPropertySafe $entry 'LearnedAt'
    if ($learned) {
        try {
            $dt = [datetime]$learned
            if ((Get-Date) - $dt -gt [TimeSpan]::FromDays($TtlDays)) { return $null }
        } catch { }
    }
    return $entry
}

function Get-JsonPropertySafe {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function Get-ProcessFileMetadata {
    param([string]$ImagePath, [int]$ProcessId = 0)

    $path = [string]$ImagePath
    if (-not $path -and $ProcessId -gt 0) {
        try {
            $p = Get-Process -Id $ProcessId -ErrorAction Stop
            $path = [string]$p.Path
        } catch { }
    }
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return $null }

    try {
        $vi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($path)
        return [ordered]@{
            Path = $path
            FileDescription = [string]$vi.FileDescription
            ProductName = [string]$vi.ProductName
            CompanyName = [string]$vi.CompanyName
            InternalName = [string]$vi.InternalName
            OriginalFilename = [string]$vi.OriginalFilename
        }
    } catch {
        return $null
    }
}

function Search-KnowledgeBaseForProcess {
    param([string]$HubRoot, [string]$ProcessName, [int]$MaxHits = 3)

    $hits = [System.Collections.Generic.List[string]]::new()
    $patterns = @($ProcessName, $ProcessName.Replace('.exe', ''))
    $dirs = @(
        (Join-Path $HubRoot 'KB'),
        (Join-Path $HubRoot 'docs')
    )
    foreach ($dir in $dirs) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        Get-ChildItem -LiteralPath $dir -Filter '*.md' -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            if ($hits.Count -ge $MaxHits) { return }
            foreach ($pat in $patterns) {
                if ($_.Name -match [regex]::Escape($pat)) {
                    [void]$hits.Add(('{0} (filename match)' -f $_.Name))
                    return
                }
            }
            try {
                $line = Select-String -LiteralPath $_.FullName -Pattern [regex]::Escape($ProcessName) -SimpleMatch -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($line) {
                    $snippet = $line.Line.Trim()
                    if ($snippet.Length -gt 120) { $snippet = $snippet.Substring(0, 120) + '…' }
                    [void]$hits.Add(('{0}: {1}' -f $_.Name, $snippet))
                }
            } catch { }
        }
    }
    return @($hits)
}

function Apply-MetadataRules {
    param($Metadata, $KnowledgeConfig)

    if (-not $Metadata) { return $null }

    $text = ('{0} {1} {2}' -f (Get-JsonPropertySafe $Metadata 'CompanyName'), (Get-JsonPropertySafe $Metadata 'ProductName'), (Get-JsonPropertySafe $Metadata 'FileDescription'))
    $rules = @()
    if ($KnowledgeConfig.CompanyCategoryRules) { $rules += @($KnowledgeConfig.CompanyCategoryRules) }
    if ($KnowledgeConfig.DescriptionKeywordRules) { $rules += @($KnowledgeConfig.DescriptionKeywordRules) }

    foreach ($rule in $rules) {
        $pat = [string]$rule.Pattern
        if ($pat -and $text -match $pat) {
            return [ordered]@{
                Category = [string]$rule.Category
                Priority = [string]$rule.Priority
                ResourceProfile = [string](Get-JsonPropertySafe $rule 'ResourceProfile')
                RuleMatched = $pat
                Confidence = 0.78
            }
        }
    }
    return $null
}

function Get-WikipediaSummary {
    param([string]$Query, [int]$TimeoutSec = 5)

    if ([string]::IsNullOrWhiteSpace($Query)) { return $null }
    if ($script:WebRequestsThisRun -ge 10) { return $null }

    $script:WebRequestsThisRun++
    $encoded = [uri]::EscapeDataString($Query.Trim())
    $url = "https://en.wikipedia.org/api/rest_v1/page/summary/$encoded"
    try {
        $resp = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec $TimeoutSec -ErrorAction Stop
        if ($resp.extract) {
            return [ordered]@{
                Source = 'wikipedia'
                Url = [string]$resp.content_urls.desktop.page
                Extract = [string]$resp.extract
                Title = [string]$resp.title
            }
        }
    } catch { }
    return $null
}

function Invoke-ProcessWebLearning {
    param(
        $Metadata,
        $KnowledgeConfig
    )

    if (-not $KnowledgeConfig.WebLookupEnabled) { return $null }
    $maxWeb = [int]$KnowledgeConfig.MaxWebRequestsPerRun
    if ($maxWeb -le 0) { $maxWeb = 2 }
    if ($script:WebRequestsThisRun -ge $maxWeb) { return $null }
    if (-not $KnowledgeConfig.WikipediaLookupEnabled) { return $null }

    $timeout = [int]$KnowledgeConfig.WebTimeoutSeconds
    if ($timeout -le 0) { $timeout = 5 }

    if (-not $Metadata) { return $null }

    $queries = @()
    $pn = Get-JsonPropertySafe $Metadata 'ProductName'
    $cn = Get-JsonPropertySafe $Metadata 'CompanyName'
    if ($pn) { $queries += [string]$pn }
    if ($cn -and $cn -notin $queries) { $queries += [string]$cn }

    foreach ($q in $queries) {
        $wiki = Get-WikipediaSummary -Query $q -TimeoutSec $timeout
        if ($wiki) { return $wiki }
    }
    return $null
}

function Invoke-OllamaProcessHint {
    param(
        $Facts,
        $MaintenanceConfig,
        $Profile
    )

    if (-not (Get-Command Test-LlmAdvisoryAllowed -ErrorAction SilentlyContinue)) { return $null }

    . (Join-Path $PSScriptRoot 'resource-budget.ps1') -ErrorAction SilentlyContinue
    $gate = Test-LlmAdvisoryAllowed -Config $MaintenanceConfig -Profile $Profile
    if (-not $gate.Allowed) { return $null }

    $llm = $null
    if ($MaintenanceConfig -is [hashtable]) { $llm = $MaintenanceConfig['LlmAdvisory'] }
    elseif ($MaintenanceConfig.LlmAdvisory) { $llm = $MaintenanceConfig.LlmAdvisory }

    $url = 'http://127.0.0.1:11434/api/generate'
    $model = [string]$gate.Model
    if ($llm) {
        $u = if ($llm -is [hashtable]) { $llm['OllamaUrl'] } else { $llm.OllamaUrl }
        $m = if ($llm -is [hashtable]) { $llm['Model'] } else { $llm.Model }
        if ($u) { $url = ($u.TrimEnd('/')) + '/api/generate' }
        if ($m) { $model = [string]$m }
    }
    if (-not $model) { $model = 'qwen2.5:0.5b-instruct' }

    $keepAlive = 0
    if ($llm) {
        $ka = if ($llm -is [hashtable]) { $llm['KeepAliveSeconds'] } else { $llm.KeepAliveSeconds }
        if ($null -ne $ka) { $keepAlive = [int]$ka }
    }

    $prompt = @"
You classify Windows processes for IT operators. Use ONLY the facts below. Reply with JSON only:
{"WhatItIs":"","WhatItDoes":"","SuggestedCategory":"","SuggestedPriority":"Tune|Keep|Review","ResourceProfile":"","BusinessHint":"","Confidence":0.0}
Facts: $($Facts | ConvertTo-Json -Compress -Depth 4)
"@

    $body = @{
        model = $model
        prompt = $prompt
        stream = $false
        keep_alive = $keepAlive
        options = @{ temperature = 0.1; num_predict = 256 }
    } | ConvertTo-Json -Depth 5

    try {
        $resp = Invoke-RestMethod -Uri $url -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 20
        $text = [string]$resp.response
        if ($text -match '\{[\s\S]*\}') {
            $json = $Matches[0] | ConvertFrom-Json
            return [ordered]@{
                Source = 'ollama'
                Model = $model
                Payload = $json
            }
        }
    } catch { }
    return $null
}

function Save-ProcessKnowledgeCacheEntry {
    param(
        [string]$CachePath,
        [string]$ProcessName,
        [object]$Entry
    )

    $cache = @{ SchemaVersion = 'ProcessKnowledgeCache.v1'; UpdatedAt = (Get-Date).ToString('o'); Entries = @{} }
    if (Test-Path -LiteralPath $CachePath) {
        try {
            $existing = Get-Content -LiteralPath $CachePath -Raw | ConvertFrom-Json
            if ($existing.Entries) {
                foreach ($prop in $existing.Entries.PSObject.Properties) {
                    $cache.Entries[$prop.Name] = $prop.Value
                }
            }
        } catch { }
    }

    $key = Get-CacheEntryKey $ProcessName
    $cache.Entries[$key] = $Entry
    $cache.UpdatedAt = (Get-Date).ToString('o')

    $dir = Split-Path -Parent $CachePath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    ($cache | ConvertTo-Json -Depth 10) | Out-File -LiteralPath $CachePath -Encoding utf8 -Force
}

function Build-ProcessKnowledgeHint {
    param(
        [string]$ProcessName,
        [int]$ProcessId = 0,
        [string]$ImagePath = '',
        [double]$RamMb = 0,
        [string]$DominantPressure = '',
        [string]$HubRoot,
        $Catalog,
        $KnowledgeConfig,
        $MaintenanceConfig = $null,
        $Profile = $null,
        [switch]$Offline,
        [switch]$AllowWeb,
        [switch]$AllowLlm
    )

    $name = [string]$ProcessName
    $sources = [System.Collections.Generic.List[string]]::new()
    $confidence = 0.0
    $whatItIs = ''
    $whatItDoes = ''
    $category = 'Unknown'
    $priority = 'Review'
    $resourceProfile = if ($DominantPressure) { $DominantPressure } else { 'Mixed' }
    $businessHint = ''
    $suggestedActions = [System.Collections.Generic.List[string]]::new()
    $catalogDraft = $null

    if ($Catalog) {
        . (Join-Path $PSScriptRoot 'process-pressure-core.ps1') -ErrorAction SilentlyContinue
        if (Get-Command Resolve-ProcessNecessity -ErrorAction SilentlyContinue) {
            $nec = Resolve-ProcessNecessity -ProcessName $name -Catalog $Catalog
            if ($nec.Level -ne 'Unknown') {
                [void]$sources.Add('process-intelligence-catalog')
                $confidence = 0.98
                $category = [string]$nec.Category
                $priority = [string]$nec.Priority
                $whatItIs = "Catalog: $($nec.Level)"
                $whatItDoes = [string]$nec.Notes
                $businessHint = 'Already classified in process-intelligence.json — no merge needed.'
            }
        }
    }

    $cacheObj = Get-ProcessKnowledgeCache -HubRoot $HubRoot -CacheRelPath ([string]$KnowledgeConfig.CachePath)
    if ($confidence -lt 0.9) {
        $cached = Get-ProcessKnowledgeFromCache -Cache $cacheObj -ProcessName $name -TtlDays ([int]$KnowledgeConfig.CacheTtlDays)
        if ($cached) {
            [void]$sources.Add('kb-cache')
            $confidence = [math]::Max($confidence, [double](Get-JsonPropertySafe $cached 'Confidence'))
            if (-not $whatItIs) { $whatItIs = [string](Get-JsonPropertySafe $cached 'WhatItIs') }
            if (-not $whatItDoes) { $whatItDoes = [string](Get-JsonPropertySafe $cached 'WhatItDoes') }
            $category = [string](Get-JsonPropertySafe $cached 'SuggestedCategory')
            $priority = [string](Get-JsonPropertySafe $cached 'SuggestedPriority')
            $rp = Get-JsonPropertySafe $cached 'ResourceProfile'
            if ($rp) { $resourceProfile = [string]$rp }
            $businessHint = [string](Get-JsonPropertySafe $cached 'BusinessHint')
            foreach ($a in @(Get-JsonPropertySafe $cached 'SuggestedActions')) { [void]$suggestedActions.Add([string]$a) }
            foreach ($s in @(Get-JsonPropertySafe $cached 'Sources')) { if ($s -and $s -notin $sources) { [void]$sources.Add([string]$s) } }
        }
    }

    $metadata = Get-ProcessFileMetadata -ImagePath $ImagePath -ProcessId $ProcessId
    if ($metadata) {
        [void]$sources.Add('file-metadata')
        if (-not $whatItIs -and $metadata.FileDescription) { $whatItIs = [string]$metadata.FileDescription }
        if (-not $whatItDoes -and $metadata.ProductName) {
            $whatItDoes = ('Product: {0} by {1}' -f $metadata.ProductName, $metadata.CompanyName)
        }
        $ruleHit = Apply-MetadataRules -Metadata $metadata -KnowledgeConfig $KnowledgeConfig
        if ($ruleHit) {
            [void]$sources.Add(('rule:{0}' -f $ruleHit.RuleMatched))
            $confidence = [math]::Max($confidence, [double]$ruleHit.Confidence)
            if ($category -eq 'Unknown') { $category = [string]$ruleHit.Category }
            if ($priority -eq 'Review') { $priority = [string]$ruleHit.Priority }
            if ($ruleHit.ResourceProfile) { $resourceProfile = [string]$ruleHit.ResourceProfile }
        }
    }

    $kbHits = Search-KnowledgeBaseForProcess -HubRoot $HubRoot -ProcessName $name
    if (@($kbHits).Count -gt 0) {
        [void]$sources.Add('kb-search')
        $confidence = [math]::Max($confidence, 0.72)
        if (-not $businessHint) { $businessHint = ($kbHits -join ' | ') }
    }

    $webFact = $null
    if (-not $Offline -and $AllowWeb -and $confidence -lt 0.88) {
        $webFact = Invoke-ProcessWebLearning -Metadata $metadata -KnowledgeConfig $KnowledgeConfig
        if ($webFact) {
            [void]$sources.Add('wikipedia')
            $confidence = [math]::Max($confidence, 0.68)
            if (-not $whatItIs) { $whatItIs = [string]$webFact.Title }
            if (-not $whatItDoes) { $whatItDoes = [string]$webFact.Extract }
            if ($webFact.Url) { [void]$sources.Add([string]$webFact.Url) }
        }
    }

    if (-not $Offline -and $AllowLlm -and $KnowledgeConfig.UseLlmWhenAllowed -and $confidence -lt 0.85 -and $MaintenanceConfig) {
        $facts = [ordered]@{
            ProcessName = $name
            RamMb = $RamMb
            DominantPressure = $DominantPressure
            Metadata = $metadata
            KbHits = $kbHits
            WebExtract = if ($webFact) { $webFact.Extract } else { $null }
        }
        $llm = Invoke-OllamaProcessHint -Facts $facts -MaintenanceConfig $MaintenanceConfig -Profile $Profile
        if ($llm -and $llm.Payload) {
            [void]$sources.Add(('ollama:{0}' -f $llm.Model))
            $p = $llm.Payload
            if ($p.WhatItIs) { $whatItIs = [string]$p.WhatItIs }
            if ($p.WhatItDoes) { $whatItDoes = [string]$p.WhatItDoes }
            if ($p.SuggestedCategory) { $category = [string]$p.SuggestedCategory }
            if ($p.SuggestedPriority) { $priority = [string]$p.SuggestedPriority }
            if ($p.ResourceProfile) { $resourceProfile = [string]$p.ResourceProfile }
            if ($p.BusinessHint) { $businessHint = [string]$p.BusinessHint }
            $lc = [double]$p.Confidence
            if ($lc -gt 0) { $confidence = [math]::Max($confidence, [math]::Min(0.84, $lc)) }
        }
    }

    if (-not $whatItIs) { $whatItIs = "Windows process '$name' — insufficient local facts" }
    if (-not $whatItDoes) { $whatItDoes = 'Run operator review; check Task Manager path, startup entries, and business ownership.' }
    if ($confidence -lt 0.55) { $confidence = 0.55 }
    if (@($suggestedActions).Count -eq 0) {
        [void]$suggestedActions.Add('Identify owner application in Task Manager → Properties → path')
        [void]$suggestedActions.Add('Add entry to process-intelligence.json after human approval')
        [void]$suggestedActions.Add('Do not auto-terminate (T3 until classified)')
    }

    $catalogDraft = [ordered]@{
        category = $category
        priority = $priority
        displayName = $name
        description = $whatItIs
        resourceProfile = $resourceProfile
        pressureMitigations = [ordered]@{
            MemoryHeavy = @("Review if RAM justified for active work on $name")
            CPUBound = @('Check for runaway loops or updates')
            IOHeavy = @('Check disk usage by parent application')
        }
        references = @($sources | Where-Object { $_ -match '^https?://' })
    }

    $hint = [ordered]@{
        SchemaVersion = $script:ProcessKnowledgeSchema
        ProcessName = $name
        PID = $ProcessId
        ImagePath = if ($metadata) { [string]$metadata.Path } else { $ImagePath }
        RamMb = $RamMb
        WhatItIs = $whatItIs
        WhatItDoes = $whatItDoes
        SuggestedCategory = $category
        SuggestedPriority = $priority
        ResourceProfile = $resourceProfile
        BusinessHint = $businessHint
        SuggestedActions = @($suggestedActions)
        SuggestedCatalogEntry = $catalogDraft
        Confidence = [math]::Round($confidence, 2)
        Sources = @($sources)
        TrustLevel = if ($confidence -ge 0.9) { 'T1_Delegated' } elseif ($confidence -ge 0.75) { 'T2_Review' } else { 'T3_Unknown' }
        RequiresHumanApproval = $true
        MergePolicy = 'Human must approve before writing process-intelligence.json'
    }

    $minPersist = [double]$KnowledgeConfig.MinConfidenceToPersist
    if (-not $Offline -and $KnowledgeConfig.PersistLearnings -and $confidence -ge $minPersist -and $cacheObj.Path) {
        $existing = Get-ProcessKnowledgeFromCache -Cache $cacheObj -ProcessName $name -TtlDays 9999
        if (-not $existing -or [double](Get-JsonPropertySafe $existing 'Confidence') -lt $confidence) {
            Save-ProcessKnowledgeCacheEntry -CachePath $cacheObj.Path -ProcessName $name -Entry ([ordered]@{
                ProcessName = $name
                WhatItIs = $whatItIs
                WhatItDoes = $whatItDoes
                SuggestedCategory = $category
                SuggestedPriority = $priority
                ResourceProfile = $resourceProfile
                BusinessHint = $businessHint
                SuggestedActions = @($suggestedActions)
                Confidence = $confidence
                Sources = @($sources)
                LearnedAt = (Get-Date).ToString('o')
            })
        }
    }

    if ($confidence -lt 0.85 -and $ProcessId -gt 0 -and (Get-Command Get-ProcessForensicProfile -ErrorAction SilentlyContinue)) {
        $forensics = Get-ProcessForensicProfile -ProcessId $ProcessId -ProcessName $name -ImagePath $ImagePath `
            -HubRoot $HubRoot -Deep -IncludeMemory:(-not $ImagePath)
        if ($forensics -and (Get-Command Merge-ForensicsIntoHint -ErrorAction SilentlyContinue)) {
            $hint = Merge-ForensicsIntoHint -Hint $hint -Forensics $forensics
            if ($hint.Sources -notcontains 'process-forensics') {
                $hint.Sources = @($hint.Sources) + @('process-forensics')
            }
        }
    }
    return $hint
}

function Get-ProcessKnowledgeHintsForTargets {
    param(
        [array]$Targets,
        [string]$HubRoot,
        $Catalog,
        $KnowledgeConfig,
        $MaintenanceConfig = $null,
        [switch]$Offline
    )

    $script:WebRequestsThisRun = 0

    $max = [int]$KnowledgeConfig.MaxEnrichPerRun
    if ($max -le 0) { $max = 6 }

    $profile = $null
    if ($MaintenanceConfig -and (Get-Command Resolve-OptimizationProfile -ErrorAction SilentlyContinue)) {
        . (Join-Path $PSScriptRoot 'resource-budget.ps1') -ErrorAction SilentlyContinue
        $profile = Resolve-OptimizationProfile -Config $MaintenanceConfig
    }

    $hints = [System.Collections.Generic.List[object]]::new()
    $count = 0
    foreach ($t in $Targets) {
        if ($count -ge $max) { break }
        $name = [string]$t.ProcessName
        if ([string]::IsNullOrWhiteSpace($name)) { continue }

        $hint = Build-ProcessKnowledgeHint `
            -ProcessName $name `
            -ProcessId ([int](Get-JsonPropertySafe $t 'PID')) `
            -ImagePath ([string](Get-JsonPropertySafe $t 'ImagePath')) `
            -RamMb ([double](Get-JsonPropertySafe $t 'RamMb')) `
            -DominantPressure ([string](Get-JsonPropertySafe $t 'DominantPressure')) `
            -HubRoot $HubRoot `
            -Catalog $Catalog `
            -KnowledgeConfig $KnowledgeConfig `
            -MaintenanceConfig $MaintenanceConfig `
            -Profile $profile `
            -Offline:$Offline `
            -AllowWeb:(-not $Offline) `
            -AllowLlm:(-not $Offline)

        [void]$hints.Add($hint)
        $count++
    }
    return @($hints)
}



