# Shared hub path and maintenance-config helpers (dot-source from scripts/).
Set-StrictMode -Version Latest

function Get-HubRoot {
    param(
        [string]$ScriptRoot = $PSScriptRoot
    )

    if ([string]::IsNullOrWhiteSpace($ScriptRoot)) {
        throw "ScriptRoot is required to resolve hub root."
    }

    $leaf = (Split-Path -Leaf $ScriptRoot).ToLowerInvariant()
    if ($leaf -eq 'scripts') {
        return (Split-Path $ScriptRoot -Parent)
    }

    return (Split-Path $ScriptRoot -Parent)
}

function Get-HubPaths {
    param(
        [string]$HubRoot = (Get-HubRoot)
    )

    return [ordered]@{
        HubRoot   = $HubRoot
        Scripts   = Join-Path $HubRoot 'scripts'
        Config    = Join-Path $HubRoot 'config'
        Logs      = Join-Path $HubRoot 'logs'
        ConfigFile = Join-Path $HubRoot 'config\sys-maintenance.json'
        Diagnostics = Join-Path $HubRoot 'logs\diagnostics'
    }
}

function Resolve-HubPath {
    param(
        [string]$HubRoot,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return (Join-Path $HubRoot $Path)
}

function ConvertFrom-JsonToHashtable {
    param($InputObject)

    if ($null -eq $InputObject) { return @{} }
    if ($InputObject -is [hashtable]) { return $InputObject }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $result = @{}
        foreach ($key in $InputObject.Keys) {
            $result[$key] = ConvertFrom-JsonToHashtable -InputObject $InputObject[$key]
        }
        return $result
    }

    if ($InputObject -is [System.Array]) {
        return @($InputObject | ForEach-Object { ConvertFrom-JsonToHashtable -InputObject $_ })
    }

    if ($InputObject -is [pscustomobject]) {
        $result = @{}
        foreach ($prop in $InputObject.PSObject.Properties) {
            $result[$prop.Name] = ConvertFrom-JsonToHashtable -InputObject $prop.Value
        }
        return $result
    }

    return $InputObject
}

function Get-MaintenanceConfig {
    param(
        [string]$ConfigPath
    )

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Config file not found: $ConfigPath"
    }

    $raw = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        try {
            return ($raw | ConvertFrom-Json -AsHashtable)
        } catch {
            # Fall through for hosts where -AsHashtable is unavailable.
        }
    }

    return (ConvertFrom-JsonToHashtable -InputObject ($raw | ConvertFrom-Json))
}

function Save-MaintenanceConfig {
    param(
        [string]$ConfigPath,
        [hashtable]$Config
    )

    $dir = Split-Path -Parent $ConfigPath
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }

    ($Config | ConvertTo-Json -Depth 12) | Out-File -LiteralPath $ConfigPath -Encoding utf8 -Force
}

function Get-ConfigSection {
    param(
        [hashtable]$Config,
        [string]$SectionName
    )

    if (-not $Config.ContainsKey($SectionName)) {
        return @{}
    }

    $section = $Config[$SectionName]
    if ($section -is [hashtable]) {
        return $section
    }

    if ($null -eq $section) {
        return @{}
    }

    if ($section -is [hashtable]) {
        return $section
    }

    return (ConvertFrom-JsonToHashtable -InputObject $section)
}

function Test-EventLogServicesHealthy {
    $issues = [System.Collections.Generic.List[string]]::new()

    foreach ($name in @('EventLog', 'RpcSs')) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if (-not $svc) {
            [void]$issues.Add("Service missing: $name")
            continue
        }
        if ($svc.Status -ne 'Running') {
            [void]$issues.Add("Service not running: $name ($($svc.Status))")
        }
    }

    return @{
        Healthy = ($issues.Count -eq 0)
        Issues  = $issues.ToArray()
    }
}

function Get-WinEventCountSafe {
    param(
        [string]$LogName,
        [datetime]$StartTime,
        [string]$ProviderName = '',
        [switch]$UseWevtutilFallback
    )

    try {
        if ($ProviderName) {
            $events = @(Get-WinEvent -FilterHashtable @{
                LogName      = $LogName
                ProviderName = $ProviderName
                StartTime    = $StartTime
            } -ErrorAction Stop)
            return @{
                Count  = $events.Count
                Events = $events
                Source = 'Get-WinEvent'
            }
        }

        $events = @(Get-WinEvent -LogName $LogName -FilterScript {
            $_.TimeCreated -ge $StartTime
        } -ErrorAction Stop)
        return @{
            Count  = $events.Count
            Events = $events
            Source = 'Get-WinEvent'
        }
    } catch {
        if (-not $UseWevtutilFallback) {
            throw
        }
    }

    $iso = $StartTime.ToUniversalTime().ToString('o')
    $query = "*[System[TimeCreated[@SystemTime>='$iso']]]"
    if ($ProviderName) {
        $query = "*[System[Provider[@Name='$ProviderName'] and TimeCreated[@SystemTime>='$iso']]]"
    }

    $args = @('qe', $LogName, '/q:$query', '/f:xml', '/c:5000', '/rd:true')
    $xmlText = & wevtutil.exe @args 2>$null
    if (-not $xmlText) {
        return @{ Count = 0; Events = @(); Source = 'wevtutil-empty' }
    }

    try {
        [xml]$doc = "<root>$xmlText</root>"
        $count = @($doc.root.Event).Count
        return @{ Count = $count; Events = @(); Source = 'wevtutil' }
    } catch {
        return @{ Count = 0; Events = @(); Source = 'wevtutil-parse-failed' }
    }
}
