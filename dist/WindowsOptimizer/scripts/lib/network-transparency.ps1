# Network + hidden-process transparency sensors (read-only, Tier C feather-safe).
# Dot-source from build-transparency-report.ps1

. (Join-Path $PSScriptRoot 'transparency-policy.ps1')

function Get-KnownNetworkEndpoints {
    return [ordered]@{
        LocalHubWeb = @{ Port = 8765; AgentId = 'transparency-web'; ControlLevel = 'T1_Delegated' }
        OllamaLocal = @{ Port = 11434; AgentId = 'ollama-advisory'; ControlLevel = 'T2_Review' }
        Dns = @{ Ports = @(53); ControlLevel = 'T0_Observed' }
        HttpHttps = @{ Ports = @(80, 443); ControlLevel = 'T2_Review' }
    }
}

function Test-IsLoopbackAddress {
    param([string]$Address)
    if ([string]::IsNullOrWhiteSpace($Address)) { return $false }
    return $Address -eq '127.0.0.1' -or $Address -eq '::1' -or $Address -eq '0.0.0.0' -or $Address -eq '::'
}

function Test-IsPrivateAddress {
    param([string]$Address)
    if ([string]::IsNullOrWhiteSpace($Address)) { return $false }
    if (Test-IsLoopbackAddress $Address) { return $true }
    if ($Address -match '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)') { return $true }
    if ($Address -match '^fe80:' -or $Address -match '^fd') { return $true }
    return $false
}

function Get-ProcessInfoCache {
    $cache = @{}
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | ForEach-Object {
        $procId = [int]$_.ProcessId
        $ramMb = 0.0
        try {
            $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
            if ($p) { $ramMb = [math]::Round($p.WorkingSet64 / 1MB, 1) }
        } catch { }
        $cache[$procId] = [ordered]@{
            PID = $procId
            Name = [string]$_.Name
            Path = [string]$_.ExecutablePath
            CommandLine = [string]$_.CommandLine
            ParentPID = [int]$_.ParentProcessId
            RamMb = $ramMb
        }
    }
    return $cache
}

function Resolve-ConnectionTrustLevel {
    param(
        $Connection,
        $ProcessInfo,
        [string[]]$CatalogNames,
        $KnownEndpoints
    )

    $procName = if ($ProcessInfo) { [string]$ProcessInfo.Name } else { 'unknown' }
    $remoteAddr = [string]$Connection.RemoteAddress
    $remotePort = [int]$Connection.RemotePort
    $localPort = [int]$Connection.LocalPort
    $state = [string]$Connection.State

    if ($localPort -eq 8765 -or $remotePort -eq 8765) {
        return @{ Level = 'T1_Delegated'; Reason = 'Hub transparency web (localhost)'; AgentId = 'transparency-web' }
    }
    if ($localPort -eq 11434 -or $remotePort -eq 11434) {
        return @{ Level = 'T2_Review'; Reason = 'Ollama local advisory port'; AgentId = 'ollama-advisory' }
    }

    if (Test-IsLoopbackAddress $remoteAddr) {
        return @{ Level = 'T0_Observed'; Reason = 'Loopback-only traffic'; AgentId = 'loopback' }
    }

    if ($CatalogNames -contains $procName) {
        $level = if (Test-IsPrivateAddress $remoteAddr) { 'T1_Delegated' } else { 'T2_Review' }
        return @{ Level = $level; Reason = 'Catalog process with network I/O'; AgentId = 'ppi-catalog' }
    }

    if ($procName -in @('System', 'svchost', 'lsass', 'services', 'dns', 'SearchApp')) {
        return @{ Level = 'T0_Observed'; Reason = 'OS core networking'; AgentId = 'trusted-os' }
    }

    if ($procName -match '^(Cursor|Code|chrome|msedge|firefox|pwsh|powershell|WindowsOptimizer|SystemOptimizer)$') {
        $level = if (Test-IsPrivateAddress $remoteAddr) { 'T0_Observed' } else { 'T2_Review' }
        return @{ Level = $level; Reason = 'Operator toolchain network'; AgentId = 'trusted-toolchain' }
    }

    if (Test-IsPrivateAddress $remoteAddr) {
        return @{ Level = 'T2_Review'; Reason = 'Private LAN endpoint — verify business need'; AgentId = '' }
    }

    if ($remotePort -in @(80, 443) -and $state -eq 'Established') {
        return @{ Level = 'T2_Review'; Reason = 'Outbound web — verify destination'; AgentId = '' }
    }

    return @{ Level = 'T3_Unknown'; Reason = 'Unattributed network I/O'; AgentId = '' }
}

function Get-NetworkTransparencySnapshot {
    param(
        $Config,
        [string[]]$CatalogNames = @(),
        [int]$MaxConnections = 120,
        [int]$SmallProcessRamMb = 120,
        [int]$MinHiddenCandidates = 1
    )

    $summary = [ordered]@{
        TotalConnections = 0
        Established = 0
        Listen = 0
        LoopbackOnly = 0
        PrivateRemote = 0
        PublicRemote = 0
        UnknownTrustCount = 0
        HiddenNetworkProcessCount = 0
    }

    $connectionsOut = [System.Collections.Generic.List[object]]::new()
    $listenOut = [System.Collections.Generic.List[object]]::new()
    $hiddenOut = [System.Collections.Generic.List[object]]::new()
    $procCache = Get-ProcessInfoCache
    $known = Get-KnownNetworkEndpoints
    $pidsWithExternal = @{}

    $conns = @()
    try {
        $conns = @(Get-NetTCPConnection -ErrorAction Stop | Where-Object {
            $_.State -in @('Established', 'Listen') -and $_.AddressFamily -eq 'IPv4'
        })
    } catch {
        return [ordered]@{
            Available = $false
            Error = $_.Exception.Message
            Summary = $summary
            Connections = @()
            Listeners = @()
            HiddenNetworkProcesses = @()
        }
    }

    $summary.TotalConnections = @($conns).Count

    foreach ($c in ($conns | Select-Object -First $MaxConnections)) {
        $procId = [int]$c.OwningProcess
        $pinfo = $null
        if ($procCache.ContainsKey($procId)) { $pinfo = $procCache[$procId] }

        $trust = Resolve-ConnectionTrustLevel -Connection $c -ProcessInfo $pinfo -CatalogNames $CatalogNames -KnownEndpoints $known
        $remoteAddr = [string]$c.RemoteAddress
        $isLoop = Test-IsLoopbackAddress $remoteAddr
        $isPrivate = Test-IsPrivateAddress $remoteAddr

        if ([string]$c.State -eq 'Established') { $summary.Established++ }
        if ([string]$c.State -eq 'Listen') { $summary.Listen++ }
        if ($isLoop) { $summary.LoopbackOnly++ }
        elseif ($isPrivate) { $summary.PrivateRemote++ }
        else { $summary.PublicRemote++ }
        if ($trust.Level -eq 'T3_Unknown') { $summary.UnknownTrustCount++ }

        if (-not $isLoop -and [string]$c.State -eq 'Established') {
            if (-not $pidsWithExternal.ContainsKey($procId)) { $pidsWithExternal[$procId] = 0 }
            $pidsWithExternal[$procId]++
        }

        $row = [ordered]@{
            State = [string]$c.State
            Local = ('{0}:{1}' -f $c.LocalAddress, $c.LocalPort)
            Remote = ('{0}:{1}' -f $remoteAddr, $c.RemotePort)
            PID = $procId
            ProcessName = if ($pinfo) { [string]$pinfo.Name } else { '?' }
            RamMb = if ($pinfo) { $pinfo.RamMb } else { 0 }
            TrustLevel = $trust.Level
            TrustReason = $trust.Reason
        }

        if ([string]$c.State -eq 'Listen') {
            [void]$listenOut.Add($row)
        } else {
            [void]$connectionsOut.Add($row)
        }
    }

    foreach ($procId in $pidsWithExternal.Keys) {
        if (-not $procCache.ContainsKey($procId)) { continue }
        $pinfo = $procCache[$procId]
        $ram = [double]$pinfo.RamMb
        $name = [string]$pinfo.Name
        $path = [string]$pinfo.Path

        $trust = Resolve-ProcessTrustLevel -Process ([PSCustomObject]@{ ProcessName = $name; Path = $path }) `
            -CatalogNames $CatalogNames

        $isSmall = $ram -lt $SmallProcessRamMb
        $pathMissing = [string]::IsNullOrWhiteSpace($path)
        $isUnknownTrust = $trust.Level -eq 'T3_Unknown'

        if (($isSmall -or $pathMissing) -and $isUnknownTrust) {
            [void]$hiddenOut.Add([ordered]@{
                PID = $procId
                Name = $name
                RamMb = $ram
                ExternalConnections = [int]$pidsWithExternal[$procId]
                Path = if ($path) { $path } else { '(protected or inaccessible)' }
                TrustLevel = 'T3_Unknown'
                TrustReason = 'Small/hidden process with unattributed outbound traffic'
                ControlLevel = 'T3_Unknown'
            })
        }
    }

    $summary.HiddenNetworkProcessCount = @($hiddenOut).Count

    return [ordered]@{
        Available = $true
        Summary = $summary
        Connections = @($connectionsOut | Sort-Object { $_.TrustLevel -eq 'T3_Unknown' } -Descending)
        Listeners = @($listenOut)
        HiddenNetworkProcesses = @($hiddenOut)
    }
}
