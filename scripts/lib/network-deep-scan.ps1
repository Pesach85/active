# Multi-layer network deep scan: cross-source diff, UDP/IPv6, DNS cache, Tor heuristics, memory forensics.
# Read-only. Requires admin for some layers (WFP); degrades gracefully.

. (Join-Path $PSScriptRoot 'process-forensics.ps1')
. (Join-Path $PSScriptRoot 'network-transparency.ps1')

$script:TorPorts = @(9050, 9051, 9150, 9151, 4443, 9001, 9030)
$script:TorProcessNames = @('tor', 'tor.exe', 'firefox', 'BraveBrowser', 'i2pd', 'i2pd.exe')
$script:TorMemoryPatterns = @(
    '\.onion', 'socks5', 'SOCKS5', 'obfs4', 'meek', 'TorBrowser', 'tor2web', '9050', '9150'
)

function Get-NetstatTcpMap {
    $map = @{}
    try {
        $lines = & netstat.exe -ano -p tcp 2>$null
        foreach ($line in @($lines)) {
            if ($line -notmatch '^\s*TCP\s+(\S+)\s+(\S+)\s+(\S+)\s+(\d+)\s*$') { continue }
            $local = $Matches[1]; $remote = $Matches[2]; $state = $Matches[3]; $pid = [int]$Matches[4]
            $key = "$local|$remote|$state|$pid"
            $map[$key] = [ordered]@{ Local = $local; Remote = $remote; State = $state; PID = $pid; Source = 'netstat' }
        }
    } catch { }
    return $map
}

function Get-PowerShellTcpMap {
    $map = @{}
    try {
        $conns = @(Get-NetTCPConnection -ErrorAction Stop | Where-Object { $_.State -in @('Established', 'Listen', 'CloseWait', 'TimeWait') })
        foreach ($c in $conns) {
            $local = ('{0}:{1}' -f $c.LocalAddress, $c.LocalPort)
            $remote = ('{0}:{1}' -f $c.RemoteAddress, $c.RemotePort)
            $key = "$local|$remote|$($c.State)|$($c.OwningProcess)"
            $map[$key] = [ordered]@{
                Local = $local; Remote = $remote; State = [string]$c.State
                PID = [int]$c.OwningProcess; Source = 'Get-NetTCPConnection'
            }
        }
    } catch { }
    return $map
}

function Compare-NetworkConnectionSources {
    $netstat = Get-NetstatTcpMap
    $ps = Get-PowerShellTcpMap
    $onlyNetstat = [System.Collections.Generic.List[object]]::new()
    $onlyPs = [System.Collections.Generic.List[object]]::new()

    foreach ($k in $netstat.Keys) {
        if (-not $ps.ContainsKey($k)) {
            [void]$onlyNetstat.Add($netstat[$k])
        }
    }
    foreach ($k in $ps.Keys) {
        if (-not $netstat.ContainsKey($k)) {
            [void]$onlyPs.Add($ps[$k])
        }
    }

    return [ordered]@{
        NetstatCount = $netstat.Count
        PowerShellCount = $ps.Count
        OnlyInNetstat = @($onlyNetstat)
        OnlyInPowerShell = @($onlyPs)
        AnomalyScore = @($onlyNetstat).Count + @($onlyPs).Count
    }
}

function Get-UdpEndpointSnapshot {
    $rows = [System.Collections.Generic.List[object]]::new()
    try {
        $udp = @(Get-NetUDPEndpoint -ErrorAction Stop)
        foreach ($u in $udp) {
            [void]$rows.Add([ordered]@{
                Local = ('{0}:{1}' -f $u.LocalAddress, $u.LocalPort)
                PID = [int]$u.OwningProcess
                ProcessName = try { (Get-Process -Id $u.OwningProcess -ErrorAction Stop).ProcessName } catch { '?' }
            })
        }
    } catch {
        return [ordered]@{ Available = $false; Error = $_.Exception.Message; Endpoints = @() }
    }
    return [ordered]@{ Available = $true; Endpoints = @($rows) }
}

function Get-DnsCacheSnapshot {
    $rows = [System.Collections.Generic.List[object]]::new()
    try {
        $entries = @(Get-DnsClientCache -ErrorAction Stop)
        foreach ($e in $entries) {
            $name = [string]$e.Entry
            $isOnion = $name -match '\.onion$'
            $isTorRelated = $name -match 'torproject|tor2web|bridges\.torproject'
            [void]$rows.Add([ordered]@{
                Name = $name
                Type = [string]$e.Type
                Data = [string]$e.Data
                TorIndicator = ($isOnion -or $isTorRelated)
            })
        }
    } catch {
        return [ordered]@{ Available = $false; Error = $_.Exception.Message; Entries = @() }
    }
    $torHits = @($rows | Where-Object { $_.TorIndicator })
    return [ordered]@{
        Available = $true
        EntryCount = $rows.Count
        TorRelatedCount = @($torHits).Count
        TorRelated = @($torHits | Select-Object -First 20)
        Entries = @($rows | Select-Object -First 100)
    }
}

function Get-TorSurfaceIndicators {
    $indicators = [System.Collections.Generic.List[object]]::new()

    foreach ($port in $script:TorPorts) {
        try {
            $listeners = @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
            foreach ($l in $listeners) {
                [void]$indicators.Add([ordered]@{
                    Kind = 'TorPortListen'
                    Detail = "TCP listen :$port PID=$($l.OwningProcess)"
                    Severity = 'High'
                })
            }
        } catch { }
    }

    Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -in $script:TorProcessNames
    } | ForEach-Object {
        $cmd = try { (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)" -ErrorAction SilentlyContinue).CommandLine } catch { '' }
        if ($cmd -match 'tor|onion|socks|9050|9150|Tor Browser') {
            [void]$indicators.Add([ordered]@{
                Kind = 'TorProcess'
                Detail = "$($_.ProcessName) PID=$($_.Id)"
                Severity = 'Review'
            })
        }
    }

    return @($indicators)
}

function Invoke-ProcessNetworkMemoryScan {
    param(
        [int[]]$ProcessIds = @(),
        [int]$MaxProcesses = 12
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $targets = if ($ProcessIds.Count -gt 0) { $ProcessIds } else {
        @(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty OwningProcess -Unique | Select-Object -First $MaxProcesses)
    }

    foreach ($procId in @($targets)) {
        if ($procId -le 4) { continue }
        try {
            $p = Get-Process -Id $procId -ErrorAction Stop
            $profile = Get-ProcessForensicProfile -ProcessId $procId -ProcessName $p.ProcessName `
                -ImagePath '' -Deep -IncludeMemory
            $hits = @()
            if ($profile -and $profile.MemoryStrings) {
                foreach ($s in @($profile.MemoryStrings)) {
                    foreach ($pat in $script:TorMemoryPatterns) {
                        if ([string]$s -match $pat) { $hits += [string]$s; break }
                    }
                }
            }
            if ($hits.Count -gt 0) {
                [void]$results.Add([ordered]@{
                    PID = $procId
                    ProcessName = $p.ProcessName
                    MemoryNetworkHits = @($hits | Select-Object -First 8)
                    Severity = if ($hits -match '\.onion|socks5|9050') { 'High' } else { 'Review' }
                })
            }
        } catch { }
    }
    return @($results)
}

function Get-OrphanNetworkPidAnomalies {
    $anomalies = [System.Collections.Generic.List[object]]::new()
    $procIds = @(Get-NetTCPConnection -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique)
    foreach ($procId in $procIds) {
        if ($procId -eq 0) {
            [void]$anomalies.Add([ordered]@{ Kind = 'SystemPidZero'; Detail = 'Connection owned by PID 0 (kernel)'; Severity = 'Info' })
            continue
        }
        if ($procId -eq 4) {
            [void]$anomalies.Add([ordered]@{ Kind = 'SystemPidFour'; Detail = 'Connection owned by PID 4 (System)'; Severity = 'Info' })
            continue
        }
        $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
        if (-not $proc) {
            [void]$anomalies.Add([ordered]@{
                Kind = 'GhostPid'
                Detail = "Active socket PID=$procId but process not visible"
                Severity = 'Critical'
            })
        }
    }
    return @($anomalies)
}

function Invoke-NetworkDeepScan {
    param(
        [string]$HubRoot = '',
        [string[]]$CatalogNames = @(),
        [switch]$IncludeMemoryScan,
        [switch]$IsAdmin
    )

    if (-not $HubRoot) {
        $HubRoot = Split-Path (Split-Path -Parent $PSScriptRoot) -Parent
    }

    $started = Get-Date
    $baseline = Get-NetworkTransparencySnapshot -CatalogNames $CatalogNames -MaxConnections 250
    $cross = Compare-NetworkConnectionSources
    $udp = Get-UdpEndpointSnapshot
    $dns = Get-DnsCacheSnapshot
    $tor = Get-TorSurfaceIndicators
    $ghosts = Get-OrphanNetworkPidAnomalies
    $memory = @()
    if ($IncludeMemoryScan) {
        $suspiciousPids = @($baseline.HiddenNetworkProcesses | ForEach-Object { [int]$_.PID })
        if ($suspiciousPids.Count -eq 0) {
            $suspiciousPids = @(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty OwningProcess -Unique | Select-Object -First 8)
        }
        $memory = Invoke-ProcessNetworkMemoryScan -ProcessIds $suspiciousPids
    }

    $findings = [System.Collections.Generic.List[object]]::new()
    if ($cross.AnomalyScore -gt 0) {
        [void]$findings.Add([ordered]@{ Layer = 'CrossSourceDiff'; Severity = 'High'; Detail = "netstat vs PS mismatch count=$($cross.AnomalyScore)" })
    }
    foreach ($g in $ghosts) {
        if ($g.Severity -eq 'Critical') {
            [void]$findings.Add([ordered]@{ Layer = 'GhostPid'; Severity = 'Critical'; Detail = $g.Detail })
        }
    }
    foreach ($t in $tor) {
        [void]$findings.Add([ordered]@{ Layer = 'TorSurface'; Severity = $t.Severity; Detail = $t.Detail })
    }
    if ($dns.TorRelatedCount -gt 0) {
        [void]$findings.Add([ordered]@{ Layer = 'DnsCache'; Severity = 'High'; Detail = "Tor-related DNS cache entries=$($dns.TorRelatedCount)" })
    }
    foreach ($m in $memory) {
        [void]$findings.Add([ordered]@{ Layer = 'MemoryForensics'; Severity = $m.Severity; Detail = "$($m.ProcessName) PID=$($m.PID) hits=$($m.MemoryNetworkHits.Count)" })
    }

    $critical = @($findings | Where-Object { $_.Severity -eq 'Critical' }).Count
    $high = @($findings | Where-Object { $_.Severity -eq 'High' }).Count

    return [ordered]@{
        SchemaVersion = 'NetworkDeepScan.v1'
        GeneratedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        DurationMs = [int]((Get-Date) - $started).TotalMilliseconds
        AdminScan = [bool]$IsAdmin
        BaselineSnapshot = $baseline
        Layers = [ordered]@{
            CrossSourceDiff = $cross
            UdpEndpoints = $udp
            DnsCache = $dns
            TorSurface = $tor
            GhostPidAnomalies = $ghosts
            MemoryNetworkScan = $memory
        }
        Findings = @($findings)
        Summary = [ordered]@{
            FindingCount = $findings.Count
            CriticalCount = $critical
            HighCount = $high
            HiddenProcessCount = if ($baseline.Summary) { $baseline.Summary.HiddenNetworkProcessCount } else { 0 }
            RecommendedAction = if ($critical -gt 0) { 'Investigate ghost PIDs immediately' }
                elseif ($high -gt 0) { 'Review Tor/hidden egress findings' }
                else { 'Continue periodic monitoring' }
        }
    }
}
