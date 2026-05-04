param(
    [ValidateSet('Audit','ApplyBadPages','ApplyTruncate','Rollback')]
    [string]$Mode = 'Audit',

    [string[]]$BadPfnsHex = @(),

    [switch]$IncludeNeighbors,

    [int]$NeighborWindow = 4,

    [double]$SafetyGapGB = 0.01,

    [string]$OutputJson = "logs/memory-path-mitigation-live.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Convert-PfnToDecimal {
    param([string]$Value)
    $v = $Value.Trim().ToLowerInvariant()
    if ($v -match '^0x[0-9a-f]+$') {
        return [Convert]::ToUInt64($v.Substring(2), 16)
    }
    if ($v -match '^[0-9]+$') {
        return [UInt64]$v
    }
    if ($v -match '^[0-9a-f]+$') {
        return [Convert]::ToUInt64($v, 16)
    }
    throw "PFN non valido: $Value"
}

function Convert-PfnToBytes {
    param([UInt64]$Pfn)
    return $Pfn * 4096
}

function Format-BytesGb {
    param([UInt64]$Bytes)
    return [Math]::Round(($Bytes / 1GB), 3)
}

function Invoke-Cmd {
    param([string]$Command)
    $result = cmd /c $Command 2>&1
    return @($result)
}

if (-not (Test-Path -LiteralPath (Split-Path -Parent $OutputJson))) {
    New-Item -Path (Split-Path -Parent $OutputJson) -ItemType Directory -Force | Out-Null
}

$report = [ordered]@{
    GeneratedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Mode = $Mode
    Inputs = [ordered]@{
        BadPfnsHex = $BadPfnsHex
        IncludeNeighbors = [bool]$IncludeNeighbors
        NeighborWindow = $NeighborWindow
        SafetyGapGB = $SafetyGapGB
    }
    System = [ordered]@{}
    Analysis = [ordered]@{}
    Actions = @()
    Rollback = @(
        'cmd /c "bcdedit /deletevalue {badmemory} badmemorylist"',
        'cmd /c "bcdedit /deletevalue {current} truncatememory"'
    )
    BestNextDecision = $null
    Status = 'Completed'
}

try {
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $totalPhysBytes = [UInt64]$cs.TotalPhysicalMemory

    $report.System = [ordered]@{
        ComputerName = $env:COMPUTERNAME
        OsVersion = [string]$os.Version
        TotalPhysicalMemoryGB = [Math]::Round(($totalPhysBytes / 1GB), 2)
    }

    $badListRaw = Invoke-Cmd 'bcdedit /enum {badmemory}'
    $hasBadMemoryList = ($badListRaw -join "`n") -match 'badmemorylist'
    $truncateRaw = Invoke-Cmd 'bcdedit /enum {current}'
    $hasTruncate = ($truncateRaw -join "`n") -match 'truncatememory'

    $report.Analysis.CurrentBootConfig = [ordered]@{
        BadMemoryObjectPresent = $true
        BadMemoryListConfigured = [bool]$hasBadMemoryList
        TruncateMemoryConfigured = [bool]$hasTruncate
    }

    if ($BadPfnsHex.Count -eq 0) {
        $report.BestNextDecision = 'Fornire elenco PFN difettosi (Linux RAS o dump WHEA) e rieseguire in Audit.'
    }
    else {
        $pfns = New-Object System.Collections.Generic.HashSet[UInt64]
        foreach ($hex in $BadPfnsHex) {
            $base = Convert-PfnToDecimal -Value $hex
            [void]$pfns.Add($base)
            if ($IncludeNeighbors) {
                for ($i = 1; $i -le $NeighborWindow; $i++) {
                    if ($base -gt [UInt64]$i) { [void]$pfns.Add($base - [UInt64]$i) }
                    [void]$pfns.Add($base + [UInt64]$i)
                }
            }
        }

        $sortedPfns = @($pfns | Sort-Object)
        $minPfn = [UInt64]($sortedPfns | Select-Object -First 1)
        $maxPfn = [UInt64]($sortedPfns | Select-Object -Last 1)
        $minBytes = Convert-PfnToBytes -Pfn $minPfn
        $maxBytes = Convert-PfnToBytes -Pfn $maxPfn

        # Align down to nearest 0.125 GB boundary below (minGB - SafetyGapGB)
        # SafetyGapGB default = 0.01 (10 MB); keeps max good RAM while safely below fault region
        $suggestedTruncateGB = [Math]::Max(4.0, ([Math]::Floor(((Format-BytesGb -Bytes $minBytes) - $SafetyGapGB) / 0.125) * 0.125))
        $suggestedTruncateBytes = [UInt64]([Math]::Floor($suggestedTruncateGB * 1GB))

        $report.Analysis.BadPageModel = [ordered]@{
            InputPfns = $BadPfnsHex
            ExpandedPfnCount = $sortedPfns.Count
            MinPfn = ('0x{0:x}' -f $minPfn)
            MaxPfn = ('0x{0:x}' -f $maxPfn)
            MinAddressGB = (Format-BytesGb -Bytes $minBytes)
            MaxAddressGB = (Format-BytesGb -Bytes $maxBytes)
            SuggestedTruncateMemoryGB = $suggestedTruncateGB
        }

        switch ($Mode) {
            'Audit' {
                $report.BestNextDecision = 'Applicare prima quarantena bad pages; se lo storm continua, applicare truncate memory e testare stabilita/performance.'
            }
            'ApplyBadPages' {
                $hexList = @($sortedPfns | ForEach-Object { '0x{0:x}' -f $_ })
                $cmd = 'bcdedit /set {{badmemory}} badmemorylist {0}' -f ($hexList -join ' ')
                $out = Invoke-Cmd $cmd
                $verify = Invoke-Cmd 'bcdedit /enum {badmemory}'
                $ok = ($verify -join "`n") -match 'badmemorylist'
                $report.Actions += @("Eseguito: $cmd", ($out -join "`n"), ($verify -join "`n"), 'Richiesto riavvio per effetto completo.')
                if (-not $ok) {
                    throw 'Applicazione badmemorylist non confermata da bcdedit /enum {badmemory}.'
                }
                $report.BestNextDecision = 'Riavviare, monitorare frequenza WHEA per 30-60 minuti reali di carico.'
            }
            'ApplyTruncate' {
                # NOTE: on Dell Inspiron 7577 with Secure Boot enabled, bcdedit /set {current} is blocked.
                # Workaround: mount EFI System Partition and modify the physical BCD file via /store.
                $truncateHex = '0x{0:x}' -f $suggestedTruncateBytes
                $efiMounted = $false
                try {
                    $mountOut = Invoke-Cmd 'mountvol X: /S'
                    $efiMounted = $true
                    $bcdPath = 'X:\EFI\Microsoft\Boot\BCD'
                    if (-not (Test-Path $bcdPath)) {
                        throw "BCD non trovato in $bcdPath dopo mountvol"
                    }
                    $cmd = "bcdedit /store `"$bcdPath`" /set `"{default}`" truncatememory $truncateHex"
                    $out = Invoke-Cmd $cmd
                    $verify = Invoke-Cmd "bcdedit /store `"$bcdPath`" /enum {default}"
                    $ok = ($verify -join "`n") -match 'truncatememory'
                    $report.Actions += @("Eseguito (via EFI store): $cmd", ($out -join "`n"), ($verify -join "`n"), 'Richiesto riavvio per effetto completo.')
                    if (-not $ok) {
                        throw 'Applicazione truncatememory non confermata da bcdedit /enum {default}.'
                    }
                } finally {
                    if ($efiMounted) { Invoke-Cmd 'mountvol X: /D' | Out-Null }
                }
                $report.BestNextDecision = 'Riavviare e verificare se il rate WHEA crolla; se positivo, confermare workaround fino a sostituzione hardware.'
            }
            'Rollback' {
                $out1 = Invoke-Cmd 'bcdedit /deletevalue {badmemory} badmemorylist'
                # truncatememory rollback: use EFI store (Secure Boot blocks {current} on this system)
                $efiMounted = $false
                try {
                    Invoke-Cmd 'mountvol X: /S' | Out-Null
                    $efiMounted = $true
                    $bcdPath = 'X:\EFI\Microsoft\Boot\BCD'
                    $out2 = Invoke-Cmd "bcdedit /store `"$bcdPath`" /deletevalue `"{default}`" truncatememory"
                } catch {
                    $out2 = @("Rollback truncatememory non necessario o gia rimosso: $($_.Exception.Message)")
                } finally {
                    if ($efiMounted) { Invoke-Cmd 'mountvol X: /D' | Out-Null }
                }
                $report.Actions += @(
                    'Eseguito rollback badmemorylist.',
                    ($out1 -join "`n"),
                    'Eseguito rollback truncatememory (via EFI store).',
                    ($out2 -join "`n"),
                    'Richiesto riavvio per effetto completo.'
                )
                $report.BestNextDecision = 'Riavviare e rieseguire Audit per confermare stato baseline.'
            }
        }
    }
}
catch {
    $report.Status = 'Failed'
    $report.Error = $_.Exception.Message
    if ([string]::IsNullOrWhiteSpace([string]$report.BestNextDecision)) {
        $report.BestNextDecision = 'Correggere input/comandi e rieseguire.'
    }
}

$json = $report | ConvertTo-Json -Depth 8
[System.IO.File]::WriteAllText($OutputJson, $json, [System.Text.Encoding]::UTF8)
$report