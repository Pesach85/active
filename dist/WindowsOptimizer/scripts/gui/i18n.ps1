# Internationalization helpers for System Optimizer GUI (dot-source).
Set-StrictMode -Version Latest

$script:I18nHubRoot = $null
$script:I18nLang = 'en'
$script:I18nStrings = @{}
$script:I18nCatalog = $null

function Initialize-I18n {
    param(
        [string]$HubRoot,
        [string]$Language = 'en'
    )

    $script:I18nHubRoot = $HubRoot
    $script:I18nLang = if ($Language) { $Language.ToLowerInvariant() } else { 'en' }

    $localeDir = Join-Path $HubRoot 'config\locale'
    $localeFile = Join-Path $localeDir ("{0}.json" -f $script:I18nLang)
    if (-not (Test-Path -LiteralPath $localeFile)) {
        $localeFile = Join-Path $localeDir 'en.json'
        $script:I18nLang = 'en'
    }

    try {
        $raw = Get-Content -LiteralPath $localeFile -Raw -Encoding UTF8
        $script:I18nStrings = ($raw | ConvertFrom-Json)
    } catch {
        $script:I18nStrings = @{}
        Write-Warning ("I18n load failed: {0}" -f $_.Exception.Message)
    }

    $catalogPath = Join-Path $HubRoot 'config\command-catalog.json'
    if (Test-Path -LiteralPath $catalogPath) {
        try {
            $script:I18nCatalog = Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            $script:I18nCatalog = $null
        }
    }
}

function Get-I18nLang { return $script:I18nLang }

function Get-I18nSupportedLanguages {
    param([string]$HubRoot)

    $localeDir = Join-Path $HubRoot 'config\locale'
    if (-not (Test-Path -LiteralPath $localeDir)) { return @('en') }

    $langs = @()
    Get-ChildItem -LiteralPath $localeDir -Filter '*.json' -File | ForEach-Object {
        $code = $_.BaseName.ToLowerInvariant()
        if ($code -match '^[a-z]{2}(-[a-z]{2})?$') { $langs += $code }
    }
    if ($langs.Count -eq 0) { return @('en') }
    return @($langs | Sort-Object -Unique)
}

function Get-I18n {
    param([string]$Key)

    if ([string]::IsNullOrWhiteSpace($Key)) { return '' }

    $parts = $Key.Split('.')
    $node = $script:I18nStrings
    foreach ($p in $parts) {
        if ($null -eq $node) { return $Key }
        if ($node.PSObject.Properties.Name -contains $p) {
            $node = $node.$p
        } else {
            return $Key
        }
    }

    if ($null -eq $node) { return $Key }
    return [string]$node
}

function Get-CommandCatalogEntry {
    param([string]$CommandId)

    if (-not $script:I18nCatalog -or -not $script:I18nCatalog.commands) { return $null }
    $cmds = $script:I18nCatalog.commands
    if ($cmds.PSObject.Properties.Name -contains $CommandId) {
        return $cmds.$CommandId
    }
    return $null
}

function Format-CommandHelpText {
    param(
        [string]$CommandId,
        [string]$Lang = ''
    )

    if (-not $Lang) { $Lang = $script:I18nLang }
    $entry = Get-CommandCatalogEntry -CommandId $CommandId
    if (-not $entry) { return '' }

    $loc = $null
    if ($entry.PSObject.Properties.Name -contains $Lang) {
        $loc = $entry.$Lang
    } elseif ($entry.PSObject.Properties.Name -contains 'en') {
        $loc = $entry.en
    }
    if (-not $loc) { return '' }

    $eff = if ($entry.efficacy) { [int]$entry.efficacy } else { 0 }
    $impact = if ($entry.effortImpact) { [int]$entry.effortImpact } else { 0 }
    $risk = if ($entry.risk) { [string]$entry.risk } else { '?' }
    $writes = if ($entry.writesSystem) { 'Yes' } else { 'No' }

    $doesLabel = if ($Lang -eq 'it') { 'Cosa fa' } else { 'What it does' }
    $notLabel = if ($Lang -eq 'it') { 'Cosa NON fa' } else { 'What it does NOT' }
    $expectLabel = if ($Lang -eq 'it') { 'Risultato atteso' } else { 'Expected outcome' }
    $tipLabel = if ($Lang -eq 'it') { 'Suggerimento' } else { 'Tip' }
    $rateLabel = if ($Lang -eq 'it') { 'Efficacia / Impatto / Rischio / Scrive sistema' } else { 'Efficacy / Impact / Risk / Writes system' }

    return @(
        ("{0}" -f $loc.title),
        ("{0}" -f $loc.summary),
        '',
        ("{0}: {1}" -f $doesLabel, $loc.does),
        ("{0}: {1}" -f $notLabel, $loc.doesNot),
        ("{0}: {1}" -f $expectLabel, $loc.expect),
        ("{0}: {1}" -f $tipLabel, $loc.tip),
        '',
        ("{0}: {1}% / {2}% / {3} / {4}" -f $rateLabel, $eff, $impact, $risk, $writes)
    ) -join "`r`n"
}

function Get-CommandTooltip {
    param([string]$CommandId)

    $entry = Get-CommandCatalogEntry -CommandId $CommandId
    if (-not $entry) { return '' }

    $Lang = $script:I18nLang
    $loc = $null
    if ($entry.PSObject.Properties.Name -contains $Lang) { $loc = $entry.$Lang }
    elseif ($entry.PSObject.Properties.Name -contains 'en') { $loc = $entry.en }
    if (-not $loc) { return '' }

    $eff = if ($entry.efficacy) { [int]$entry.efficacy } else { 0 }
    return ("{0}`n{1}`n(Efficacy {2}% | Risk {3})" -f $loc.title, $loc.summary, $eff, $entry.risk)
}
