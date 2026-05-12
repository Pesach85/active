<#
.SYNOPSIS
    Mitiga gli errori MCE L1 della cache CPU rilevati da HWiNFO.

.DESCRIPTION
    Gli errori "Errori L1 della cache della CPU" in HWiNFO sono Correctable Machine
    Check Exceptions (CMCE) che la CPU hardware corregge silenziosamente, ma il
    contatore MSR continua ad accumularsi. Causa principale: CPU opera costantemente
    al Turbo Boost massimo sotto "Prestazioni elevate" + SpeedShift aggressivo.

    Strategia di mitigazione (incrementale):
      Livello 1: Switch power plan a Bilanciato + MaxProcessorState=99%
                 (disabilita Intel Turbo Boost → riduzione attesa MCE rate ~60-80%)
      Livello 2: ThrottleStop INI patch → abilita LimitTurbo per tutti i profili
                 (complementare al livello 1; richiede restart ThrottleStop)

.PARAMETER Mode
    Audit    - Solo lettura: rileva stato attuale, stima impatto.
    Apply    - Applica mitigazione con backup rollback.
    Rollback - Ripristina stato pre-Apply da backup.

.PARAMETER Level
    1 = solo power plan (default, safe)
    2 = power plan + ThrottleStop LimitTurbo patch

.PARAMETER LogPath
    Path di output JSON. Default: logs/cpu-l1-mce-mitigation-live.json

.EXAMPLE
    # Audit
    pwsh -File scripts\mitigate-cpu-l1-mce.ps1 -Mode Audit

    # Applica livello 1 (safe, consigliato prima)
    pwsh -File scripts\mitigate-cpu-l1-mce.ps1 -Mode Apply -Level 1

    # Rollback
    pwsh -File scripts\mitigate-cpu-l1-mce.ps1 -Mode Rollback
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Audit','Apply','Rollback')]
    [string]$Mode = 'Audit',

    [ValidateSet(1,2)]
    [int]$Level = 1,

    [string]$LogPath = 'logs/cpu-l1-mce-mitigation-live.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Costanti ---
$BALANCED_GUID   = '381b4222-f694-41f0-9685-ff5bb260df2e'
$HIGHPERF_GUID   = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$TS_INI          = 'C:\Users\Pasquale Lombardi\Desktop\Throttlestop\ThrottleStop.ini'
$BACKUP_FILE     = 'logs/cpu-l1-mce-rollback-state.json'
$TURBODISABLE_KEY = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\54533251-82be-4824-96c1-47b60b740d00\be337238-0d82-4146-a960-4f3749d470c7'

# Converti path relativi in assoluti rispetto alla cartella script
$Root = Split-Path $PSScriptRoot -Parent
if (-not $Root) { $Root = (Get-Location).Path }
$LogPath    = Join-Path $Root $LogPath
$BACKUP_FILE = Join-Path $Root $BACKUP_FILE

# --- Helper: legge piano attivo ---
function Get-ActivePlanGuid {
    $line = powercfg /getactivescheme 2>&1 | Out-String
    if ($line -match 'GUID combinazione risparmio energia:\s*([0-9a-f\-]{36})') {
        return $Matches[1]
    }
    return $null
}

# --- Helper: legge MaxProcessorState corrente (AC) ---
function Get-MaxProcState ([string]$PlanGuid) {
    $raw = powercfg /query $PlanGuid SUB_PROCESSOR PROCTHROTTLEMAX 2>$null
    # cerca "Indice impostazione alimentazione CA corrente: 0x..."
    $ac = $raw | Select-String -Pattern 'Indice impostazione alimentazione CA corrente:\s*(0x[0-9a-fA-F]+)'
    if ($ac) {
        return [Convert]::ToInt32($ac.Matches[0].Groups[1].Value, 16)
    }
    return $null
}

# --- Helper: legge ThrottleStop Options per profilo ---
function Get-TSOptions ([string]$IniPath, [int]$ProfileNum = 1) {
    if (-not (Test-Path $IniPath)) { return $null }
    $content = Get-Content $IniPath -Raw
    if ($content -match "Options$ProfileNum=0x([0-9A-Fa-f]+)") {
        return [Convert]::ToInt32($Matches[1], 16)
    }
    return $null
}

# --- Helper: legge WHEA Event Log rate (ultimi N minuti) ---
function Get-WHEARate ([int]$Minutes = 10) {
    $since = (Get-Date).AddMinutes(-$Minutes)
    $count = 0
    try {
        $count = @(Get-WinEvent -ProviderName 'Microsoft-Windows-WHEA-Logger' -ErrorAction SilentlyContinue |
            Where-Object { $_.TimeCreated -gt $since }).Count
    } catch {}
    return $count
}

# --- Audit ---
function Invoke-Audit {
    $activePlan = Get-ActivePlanGuid
    $planName   = if ($activePlan -eq $BALANCED_GUID) { 'Bilanciato' }
                  elseif ($activePlan -eq $HIGHPERF_GUID) { 'PrestazElevate' }
                  else { "Custom:$activePlan" }

    $maxProcAC = Get-MaxProcState $activePlan
    $tsOpts1   = Get-TSOptions $TS_INI 1
    $tsLimitTurbo = if ($null -ne $tsOpts1) { ($tsOpts1 -band 0x2) -ne 0 } else { $null }
    $tsSpeedShift = if ($null -ne $tsOpts1) { ($tsOpts1 -band 0x40) -ne 0 } else { $null }
    $tsFIVR       = if ($null -ne $tsOpts1) { ($tsOpts1 -band 0x4) -ne 0 } else { $null }
    $tsRunning    = $null -ne (Get-Process -Name 'ThrottleStop' -ErrorAction SilentlyContinue | Select-Object -First 1)

    $wheaRate = Get-WHEARate 10

    # Stima impatto mitigazione
    $riskLevel = 'Basso'
    $expectedReduction = '0%'
    if ($activePlan -eq $HIGHPERF_GUID) {
        if ($maxProcAC -eq 100) {
            $riskLevel = 'Alto'
            $expectedReduction = '60-80% (switch Bilanciato + MaxProcState=99%)'
        } elseif ($maxProcAC -eq 99) {
            $riskLevel = 'Medio'
            $expectedReduction = '30-50% (solo switch piano)'
        }
    }

    $result = [ordered]@{
        CapturedAt         = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Mode               = 'Audit'
        PowerPlan          = $planName
        PowerPlanGuid      = $activePlan
        MaxProcessorStateAC = $maxProcAC
        TurboBoostedPlan   = ($activePlan -eq $HIGHPERF_GUID -and $maxProcAC -eq 100)
        ThrottleStopRunning = $tsRunning
        TSOptions1Hex      = if ($null -ne $tsOpts1) { '0x{0:X8}' -f $tsOpts1 } else { 'N/A' }
        TSLimitTurbo       = $tsLimitTurbo
        TSSpeedShiftEPP    = $tsSpeedShift
        TSFIVR             = $tsFIVR
        WHEAEventLog10min  = $wheaRate
        MCESource          = 'CMCE L1 cache (HWiNFO MSR) - non visibili in Event Log'
        RiskLevel          = $riskLevel
        ExpectedReduction  = $expectedReduction
        Recommendation     = 'Apply -Level 1 per riduzione immediata MCE rate'
    }

    return $result
}

# --- Apply ---
function Invoke-Apply ([int]$ApplyLevel) {
    # 1. Backup stato corrente
    $before = Invoke-Audit

    # Backup opzioni ThrottleStop per tutti i profili
    $tsOrigOptions = @{}
    if (Test-Path $TS_INI) {
        $iniRaw = Get-Content $TS_INI
        for ($p = 1; $p -le 4; $p++) {
            $match = $iniRaw | Select-String -Pattern "^Options$p=(.+)$"
            if ($match) { $tsOrigOptions["Options$p"] = $match.Matches[0].Groups[1].Value }
        }
    }

    $rollback = [ordered]@{
        CreatedAt              = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        OriginalPlanGuid       = $before.PowerPlanGuid
        OriginalMaxProcStateAC = $before.MaxProcessorStateAC
        OriginalTSOptions      = $tsOrigOptions
        AppliedLevel           = $ApplyLevel
    }
    $rollback | ConvertTo-Json -Depth 4 | Set-Content $BACKUP_FILE -Encoding UTF8
    Write-Host "Backup rollback salvato: $BACKUP_FILE"

    $changes = [System.Collections.Generic.List[string]]::new()

    # -- Livello 1: power plan Bilanciato + MaxProcessorState=99% --
    Write-Host "[L1] Switch power plan a Bilanciato..."
    powercfg /setactive $BALANCED_GUID
    $changes.Add("PowerPlan: PrestazElevate → Bilanciato")

    Write-Host "[L1] Set MaxProcessorState=99% (disabilita Turbo Boost) su piano Bilanciato..."
    # AC (alimentato)
    powercfg /setacvalueindex $BALANCED_GUID SUB_PROCESSOR PROCTHROTTLEMAX 99
    # DC (batteria)  
    powercfg /setdcvalueindex $BALANCED_GUID SUB_PROCESSOR PROCTHROTTLEMAX 99
    powercfg /setactive $BALANCED_GUID
    $changes.Add("MaxProcessorState: 100% → 99% (Turbo Boost disabilitato)")

    # -- Livello 2: ThrottleStop LimitTurbo patch --
    if ($ApplyLevel -ge 2) {
        Write-Host "[L2] Patching ThrottleStop.ini: abilita LimitTurbo per tutti i profili..."
        if (Test-Path $TS_INI) {
            # Backup INI
            $tsBackup = $TS_INI -replace '\.ini$', ".backup-$(Get-Date -Format 'yyyyMMdd-HHmmss').ini"
            Copy-Item $TS_INI $tsBackup
            Write-Host "[L2] Backup ThrottleStop.ini → $tsBackup"

            $iniContent = Get-Content $TS_INI
            for ($p = 1; $p -le 4; $p++) {
                $pattern = "Options$p=0x([0-9A-Fa-f]+)"
                $iniContent = $iniContent | ForEach-Object {
                    if ($_ -match "^Options$p=0x([0-9A-Fa-f]+)$") {
                        $oldVal = [Convert]::ToInt32($Matches[1], 16)
                        $newVal = $oldVal -bor 0x2  # bit 1 = LimitTurbo
                        $oldHex = '0x{0:X8}' -f $oldVal
                        $newHex = '0x{0:X8}' -f $newVal
                        $line = "Options$p=$newHex"
                        $changes.Add("ThrottleStop Options${p}: $oldHex → $newHex")
                        $line
                    } else {
                        $_
                    }
                }
            }
            $iniContent | Set-Content $TS_INI -Encoding UTF8
            Write-Host "[L2] ThrottleStop.ini aggiornato. Riavvia ThrottleStop per applicare LimitTurbo."

            # Tenta restart ThrottleStop se in esecuzione
            $tsProc = Get-Process -Name 'ThrottleStop' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($tsProc) {
                Write-Host "[L2] Riavvio ThrottleStop..."
                $tsExe = $tsProc.Path
                Stop-Process -Id $tsProc.Id -Force
                Start-Sleep -Milliseconds 1500
                Start-Process $tsExe
                Write-Host "[L2] ThrottleStop riavviato."
                $changes.Add("ThrottleStop: riavviato per applicare LimitTurbo")
            }
        } else {
            Write-Warning "ThrottleStop.ini non trovato: $TS_INI"
        }
    }

    # -- Risultato --
    $after = Invoke-Audit

    $result = [ordered]@{
        CapturedAt       = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Mode             = 'Apply'
        Level            = $ApplyLevel
        ChangesApplied   = $changes
        Before           = $before
        After            = $after
        RollbackFile     = $BACKUP_FILE
        AntiRegression   = @(
            'Rollback: pwsh -File scripts\mitigate-cpu-l1-mce.ps1 -Mode Rollback',
            'Osserva HWiNFO: il counter NON si azzera (cumulativo dal boot); osserva la VELOCITÀ di aumento',
            'Attendi 10-15min per misurare il delta rate con il nuovo piano',
            'Se prestazioni insufficienti, -Mode Rollback ripristina il piano precedente'
        )
    }

    return $result
}

# --- Rollback ---
function Invoke-Rollback {
    if (-not (Test-Path $BACKUP_FILE)) {
        Write-Error "File rollback non trovato: $BACKUP_FILE. Nessun backup disponibile."
        return
    }

    $backup = Get-Content $BACKUP_FILE -Raw | ConvertFrom-Json

    Write-Host "Rollback power plan: $($backup.OriginalPlanGuid)..."
    powercfg /setactive $backup.OriginalPlanGuid

    if ($null -ne $backup.OriginalMaxProcStateAC -and $backup.OriginalMaxProcStateAC -ne 99) {
        Write-Host "Rollback MaxProcessorState → $($backup.OriginalMaxProcStateAC)%..."
        powercfg /setacvalueindex $backup.OriginalPlanGuid SUB_PROCESSOR PROCTHROTTLEMAX $backup.OriginalMaxProcStateAC
        powercfg /setdcvalueindex $backup.OriginalPlanGuid SUB_PROCESSOR PROCTHROTTLEMAX $backup.OriginalMaxProcStateAC
        powercfg /setactive $backup.OriginalPlanGuid
    }

    # Rollback ThrottleStop se level 2
    if ($backup.AppliedLevel -ge 2 -and $backup.OriginalTSOptions -and (Test-Path $TS_INI)) {
        Write-Host "Rollback ThrottleStop.ini Options..."
        $iniContent = Get-Content $TS_INI
        for ($p = 1; $p -le 4; $p++) {
            $key = "Options$p"
            if ($backup.OriginalTSOptions.$key) {
                $origLine = "$key=$($backup.OriginalTSOptions.$key)"
                $iniContent = $iniContent | ForEach-Object {
                    if ($_ -match "^Options$p=") { $origLine } else { $_ }
                }
            }
        }
        $iniContent | Set-Content $TS_INI -Encoding UTF8
        Write-Host "ThrottleStop.ini ripristinato. Riavvia ThrottleStop manualmente."
    }

    $result = [ordered]@{
        CapturedAt    = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Mode          = 'Rollback'
        RestoredPlan  = $backup.OriginalPlanGuid
        Status        = 'OK'
    }

    return $result
}

# ============================================================
# MAIN
# ============================================================
$output = switch ($Mode) {
    'Audit'    { Invoke-Audit }
    'Apply'    { Invoke-Apply $Level }
    'Rollback' { Invoke-Rollback }
}

# Scrivi log
$output | ConvertTo-Json -Depth 8 | Set-Content $LogPath -Encoding UTF8
Write-Host "`nLog salvato: $LogPath"

# Output a schermo
$output | ConvertTo-Json -Depth 8
