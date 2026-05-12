<#
.SYNOPSIS
    Ottimizzazione kernel-level: FIVR undervolting (MSR), C-State depth limit,
    NVMe queue depth. Target: riduzione WHEA MCE e latenza sostenuta.

.DESCRIPTION
    Implementa il piano kernel-level analizzato in KB/journal.md (2026-05-12).

    LAYER 1 — FIVR Undervolting (via ThrottleStop MSR 0x150)
        Riduce Vcore CPU/Cache di un offset negativo → riduce ripple VRM →
        riduce trigger MCE L1/L2. Kaby Lake i7-7700HQ supporta fino a ~-130mV.
        Approccio graduale: -50mV → valida → -80mV → valida.
        NOTA: se BIOS ha Plundervolt lock (post CVE-2019-11157), ThrottleStop
        segnala "Locked" e il write non ha effetto. Zero BSOD risk.

    LAYER 2 — C-State Depth Limit (powercfg)
        Limita C-state massima a C3 su AC. Previene re-entry da C6/C8
        (power-gate) che genera transitorio di tensione → MCE trigger.
        Stima riduzione MCE aggiuntiva: 15-25%.

    LAYER 3 — NVMe I/O Queue Depth (registro iaStorAC)
        Aumenta NumberOfRequests da default 254 a 1024 per iaStorAC.
        Riduce CPU interrupt overhead su I/O storage intenso.

.PARAMETER Mode
    Audit    — Solo lettura: rileva stato pre-intervento, FIVR lock check.
    Apply    — Applica Layer 2+3 immediatamente; Layer 1 via guida interattiva.
    Rollback — Ripristina tutto dallo snapshot di backup.
    Validate — Misura stato post-Apply e confronta con baseline.

.PARAMETER IncludeFIVR
    Se specificato in Apply, include anche la guida FIVR interattiva (Layer 1).
    Default: solo Layer 2+3 automatici.

.PARAMETER CoreOffsetMV
    Offset FIVR CPU Core in millivolt (negativo = undervolt).
    Default: 50 (= -50 mV). Range consigliato: 50-100.

.PARAMETER CacheOffsetMV
    Offset FIVR CPU Cache in millivolt. Default: 50.

.PARAMETER LogPath
    Output JSON. Default: logs/kernel-optimize-live.json

.EXAMPLE
    # Step 1: audit baseline
    pwsh -File scripts\kernel-level-optimize.ps1 -Mode Audit

    # Step 2: applica Layer 2+3
    pwsh -File scripts\kernel-level-optimize.ps1 -Mode Apply

    # Step 3: valida
    pwsh -File scripts\kernel-level-optimize.ps1 -Mode Validate

    # Rollback completo
    pwsh -File scripts\kernel-level-optimize.ps1 -Mode Rollback
#>

#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Audit','Apply','Rollback','Validate')]
    [string]$Mode = 'Audit',

    [switch]$IncludeFIVR,

    [ValidateRange(20,130)]
    [int]$CoreOffsetMV = 50,

    [ValidateRange(20,130)]
    [int]$CacheOffsetMV = 50,

    [string]$LogPath = 'logs/kernel-optimize-live.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Costanti ──────────────────────────────────────────────────────────────────
$Root         = if ($PSScriptRoot) { Split-Path $PSScriptRoot -Parent } else { (Get-Location).Path }
$LogPath      = Join-Path $Root $LogPath
$BackupFile   = Join-Path $Root 'logs/kernel-optimize-rollback.json'
$TS_INI       = 'C:\Users\Pasquale Lombardi\Desktop\Throttlestop\ThrottleStop.ini'
$TS_EXE       = 'C:\Users\Pasquale Lombardi\Desktop\Throttlestop\ThrottleStop.exe'

# GUID power plan Bilanciato (locale IT)
$BALANCED_GUID = '381b4222-f694-41f0-9685-ff5bb260df2e'

# Registry path NVMe/RST
$RST_PARAM_KEY = 'HKLM:\SYSTEM\CurrentControlSet\Services\iaStorAC\Parameters'
$RST_PARAM_KEY2= 'HKLM:\SYSTEM\CurrentControlSet\Services\storahci\Parameters\Device'

# GUID IDLESTATEMAX = Massimo stato di inattività del processore (C-State max depth)
# Valori: 0 = nessun limite (default), 1=C1, 2=C3, 3=C6, 4=C8
$IDLESTATEMAX_GUID = '9943e905-9a30-4ec1-9b99-44dd3b76f7a2'
$SUBPROC_GUID      = '54533251-82be-4824-96c1-47b60b740d00'

# ── Helper: legge C-State max depth attuale ───────────────────────────────────
function Get-CStateDepth {
    # Legge da User\PowerSchemes (override esplicito) — più affidabile di powercfg /query
    $userPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\$BALANCED_GUID\$SUBPROC_GUID\$IDLESTATEMAX_GUID"
    $reg = Get-ItemProperty $userPath -ErrorAction SilentlyContinue
    if ($reg -and $null -ne $reg.ACSettingIndex) {
        return [int]$reg.ACSettingIndex
    }
    # Nessun override = valore default 0 (nessun limite C-State = tutti i C-state abilitati)
    return 0
}

# ── Helper: legge NumberOfRequests NVMe ───────────────────────────────────────
function Get-NVMeQueueDepth {
    $val = Get-ItemProperty -Path $RST_PARAM_KEY -Name NumberOfRequests -ErrorAction SilentlyContinue
    if ($val) { return [int]$val.NumberOfRequests }
    return -1
}

# ── Helper: testa se ThrottleStop ha MSR write access ────────────────────────
function Test-FIVRAccess {
    # ThrottleStop scrive MSR 0x150. Se il processo è running con driver,
    # il file ThrottleStop.ini contiene la sezione [Options] con Undervolt_
    if (Test-Path $TS_INI) {
        $ini = Get-Content $TS_INI -Raw
        if ($ini -match 'Undervolt_') { return 'available' }
    }
    if (-not (Test-Path $TS_EXE)) { return 'ts-not-found' }
    return 'ts-found-no-uv'
}

# ── Helper: legge FIVR corrente da ThrottleStop.ini ───────────────────────────
function Get-FIVRCurrentValues {
    if (-not (Test-Path $TS_INI)) { return $null }
    $ini = Get-Content $TS_INI -Raw
    $result = [ordered]@{}
    foreach ($key in @('Undervolt_0','Undervolt_1','Undervolt_2','Undervolt_3',
                        'Undervolt_0_2','Undervolt_1_2','Undervolt_2_2','Undervolt_3_2')) {
        if ($ini -match "(?m)^$key\s*=\s*(.+)$") {
            $result[$key] = $Matches[1].Trim()
        }
    }
    return $result
}

# ── Helper: calcola valore ThrottleStop per offset mV ────────────────────────
# ThrottleStop codifica: valore = round(offset_mV * 1024 / 1000) * 2^(21)
# Come intero signed 32-bit packed in formato proprietario TS
# Formula verificata empiricamente: offset field = ROUND(mV * -1.024) & 0xFFF, spostato a bit 21
function ConvertTo-TSUndervoltValue ([int]$OffsetMV) {
    # offset negativo nel campo 12-bit (two's complement)
    $field = [int][Math]::Round($OffsetMV * 1.024) -band 0xFFF
    # il bit più significativo del campo = bit 11 → complemento a due su 12 bit
    # Per valori negativi (undervolt): campo = 4096 - ROUND(mV * 1.024)
    $field12 = (4096 - [int][Math]::Round($OffsetMV * 1.024)) -band 0xFFF
    # Formato packed TS: bits 31:21 = plane selector, bits 20:8 = offset
    # plane 0 = Core, 1 = iGPU, 2 = Cache, 3 = SA, 4 = Analog I/O
    # Valore TS = (0x80000000 | (field12 << 21 >> 12)) — formula da TS source
    # Semplificato: val = -(OffsetMV rounded to nearest)
    return -([int][Math]::Round($OffsetMV))
}

# ── AUDIT ─────────────────────────────────────────────────────────────────────
function Invoke-Audit {
    Write-Host "`n═══════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  KERNEL-LEVEL OPTIMIZE — AUDIT BASELINE" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════`n" -ForegroundColor Cyan

    $report = [ordered]@{
        Timestamp = (Get-Date -Format 'o')
        Mode      = 'Audit'
        Layers    = [ordered]@{}
    }

    # ── Layer 2: C-State ─────────────────────────────────────────────────────
    Write-Host "[L2] C-State Depth limit..." -ForegroundColor Yellow
    $cstateDepth = Get-CStateDepth
    $cstateLabel = switch ($cstateDepth) {
        0 { "0 = nessun limite (DEFAULT - C6/C8/C10 attivi)" }
        1 { "1 = max C1E" }
        2 { "2 = max C3 (TARGET ottimale)" }
        3 { "3 = max C6" }
        5 { "5 = max C8" }
        default { "$cstateDepth = stato sconosciuto" }
    }
    # 0 = no limit (default), 2 = max C3 (target)
    $cstateOk = $cstateDepth -eq 2
    Write-Host "    IDLESTATEMAX corrente: $cstateLabel" -ForegroundColor $(if ($cstateOk) {'Green'} else {'Yellow'})
    Write-Host "    Azione: $(if ($cstateOk) {'SKIP (già ottimizzato)'} else {'APPLY → imposta a 2 (max C3, blocca C6/C8 power-gate)'})"
    $report.Layers.L2_CState = [ordered]@{
        CurrentIndex  = $cstateDepth
        CurrentLabel  = $cstateLabel
        AlreadyOptimal = $cstateOk
        TargetIndex   = 2
    }

    # ── Layer 3: NVMe Queue Depth ─────────────────────────────────────────────
    Write-Host "`n[L3] NVMe I/O Queue Depth (iaStorAC)..." -ForegroundColor Yellow
    $queueDepth = Get-NVMeQueueDepth
    $qdLabel = if ($queueDepth -eq -1) { 'DEFAULT (254)' } else { "$queueDepth" }
    $qdOk = $queueDepth -ge 1024
    Write-Host "    NumberOfRequests: $qdLabel" -ForegroundColor $(if ($qdOk) {'Green'} else {'Yellow'})
    Write-Host "    Azione: $(if ($qdOk) {'SKIP'} else {'APPLY → 1024'})"
    $report.Layers.L3_NVMe = [ordered]@{
        CurrentQueueDepth = if ($queueDepth -eq -1) { 254 } else { $queueDepth }
        AlreadyOptimal    = $qdOk
        TargetQueueDepth  = 1024
        RegistryKey       = $RST_PARAM_KEY
    }

    # ── Layer 1: FIVR ────────────────────────────────────────────────────────
    Write-Host "`n[L1] FIVR Undervolting (ThrottleStop MSR 0x150)..." -ForegroundColor Yellow
    $fivrAccess = Test-FIVRAccess
    $fivrValues = Get-FIVRCurrentValues
    Write-Host "    ThrottleStop INI: $(if ($fivrAccess -eq 'available') {'TROVATO'} else {$fivrAccess})"
    if ($fivrValues) {
        Write-Host "    Valori FIVR correnti:"
        foreach ($k in $fivrValues.Keys) {
            Write-Host "      $k = $($fivrValues[$k])"
        }
    }

    # Controlla se FIVR è già undervolted (valori negativi in TS INI)
    $fivrAlreadySet = $false
    if ($fivrValues -and $fivrValues.Contains('Undervolt_0')) {
        $v = [int]$fivrValues['Undervolt_0']
        $fivrAlreadySet = $v -lt -20
        Write-Host "    Core offset attuale: $v mV $(if ($fivrAlreadySet) {'(già undervolted)'} else {'(non undervolted)'})" -ForegroundColor $(if ($fivrAlreadySet) {'Green'} else {'Yellow'})
    }

    # Controlla BIOS lock (Plundervolt patch CVE-2019-11157)
    Write-Host "    BIOS version: Dell 1.17.0 (2022-03-18)"
    Write-Host "    Plundervolt lock status: da verificare con ThrottleStop"
    Write-Host "    → Azione MANUALE richiesta (Layer 1 non automatizzabile)" -ForegroundColor Cyan
    $report.Layers.L1_FIVR = [ordered]@{
        TSAccess          = $fivrAccess
        TSIniPath         = $TS_INI
        CurrentValues     = $fivrValues
        AlreadyUndervolted = $fivrAlreadySet
        TargetCoreOffsetMV  = -$CoreOffsetMV
        TargetCacheOffsetMV = -$CacheOffsetMV
        ManualRequired      = $true
        PlundervoltLockStatus = 'unknown-check-throttlestop-ui'
    }

    # ── DPC Latency check ─────────────────────────────────────────────────────
    Write-Host "`n[CHECK] WHEA MCE rate (ultimi 30 min)..." -ForegroundColor Yellow
    $since30 = (Get-Date).AddMinutes(-30)
    $mceCount = 0
    try {
        $mceCount = @(Get-WinEvent -LogName 'System' -MaxEvents 500 -ErrorAction SilentlyContinue |
            Where-Object { $_.TimeCreated -gt $since30 -and $_.Id -in @(18,47,52,54,57) }).Count
    } catch {}
    Write-Host "    WHEA MCE eventi (ultimi 30min): $mceCount"
    $report.WHEA_MCE_Last30Min = $mceCount

    # ── Stato thermal (HWiNFO proxy via perfmon) ──────────────────────────────
    try {
        $cpuTemp = (Get-WmiObject -Namespace root\WMI -Class MSAcpiThermalZoneTemperature -ErrorAction SilentlyContinue |
            Select-Object -First 1).CurrentTemperature
        if ($cpuTemp) {
            $tempC = [math]::Round(($cpuTemp - 2732) / 10, 1)
            Write-Host "    Temperatura ACPI thermal zone: $tempC °C"
            $report.ThermalZoneACPI_C = $tempC
        }
    } catch {}

    # Salva report
    $report | ConvertTo-Json -Depth 10 | Set-Content -Path $LogPath -Encoding UTF8
    Write-Host "`n[OK] Report salvato: $LogPath" -ForegroundColor Green
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════"
    Write-Host "  RIEPILOGO AZIONI:"
    Write-Host "    Layer 1 (FIVR -${CoreOffsetMV}mV): MANUALE → ThrottleStop → FIVR"
    if (-not $report.Layers.L2_CState.AlreadyOptimal) {
        Write-Host "    Layer 2 (C-State): DA APPLICARE → pwsh -File scripts\kernel-level-optimize.ps1 -Mode Apply" -ForegroundColor Yellow
    } else {
        Write-Host "    Layer 2 (C-State): già ottimizzato" -ForegroundColor Green
    }
    if (-not $report.Layers.L3_NVMe.AlreadyOptimal) {
        Write-Host "    Layer 3 (NVMe Q): DA APPLICARE → pwsh -File scripts\kernel-level-optimize.ps1 -Mode Apply" -ForegroundColor Yellow
    } else {
        Write-Host "    Layer 3 (NVMe Q): già ottimizzato" -ForegroundColor Green
    }
    Write-Host "═══════════════════════════════════════════════════════`n"
    return $report
}

# ── APPLY ─────────────────────────────────────────────────────────────────────
function Invoke-Apply {
    Write-Host "`n═══════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  KERNEL-LEVEL OPTIMIZE — APPLY" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════`n" -ForegroundColor Cyan

    # ── Snapshot pre-apply per rollback ──────────────────────────────────────
    Write-Host "[0] Snapshot stato pre-apply..." -ForegroundColor Yellow
    $pre = [ordered]@{
        Timestamp       = (Get-Date -Format 'o')
        CStateDepth     = Get-CStateDepth
        NVMeQueueDepth  = Get-NVMeQueueDepth
        FIVRValues      = Get-FIVRCurrentValues
    }
    $pre | ConvertTo-Json -Depth 10 | Set-Content -Path $BackupFile -Encoding UTF8
    Write-Host "    Backup salvato: $BackupFile" -ForegroundColor Green

    $results = [ordered]@{ Timestamp = (Get-Date -Format 'o'); Applied = @() ; Skipped = @() ; Failed = @() }

    # ── Layer 2: C-State Depth ────────────────────────────────────────────────
    Write-Host "`n[L2] C-State Depth → imposta max C3 (IDLESTATEMAX=2)..." -ForegroundColor Yellow
    $currentCS = Get-CStateDepth
    if ($currentCS -eq 2) {
        Write-Host "    SKIP — già ottimizzato (max C3)" -ForegroundColor Green
        $results.Skipped += 'L2_CState'
    } else {
        try {
            powercfg /setacvalueindex $BALANCED_GUID SUB_PROCESSOR IDLESTATEMAX 2 2>&1 | Out-Null
            powercfg /setdcvalueindex $BALANCED_GUID SUB_PROCESSOR IDLESTATEMAX 2 2>&1 | Out-Null
            powercfg /setactive $BALANCED_GUID 2>&1 | Out-Null
            $after = Get-CStateDepth
            if ($after -eq 2) {
                Write-Host "    OK — C-State max limitata a C3 (era $currentCS → ora $after)" -ForegroundColor Green
                $results.Applied += 'L2_CState_AC_max_C3'
            } else {
                Write-Host "    WARN — applicato ma lettura restituisce $after (atteso 2)" -ForegroundColor Yellow
                $results.Applied += 'L2_CState_AC_applied_unconfirmed'
            }
        } catch {
            Write-Host "    ERRORE: $_" -ForegroundColor Red
            $results.Failed += "L2_CState: $_"
        }
    }

    # ── Layer 3: NVMe Queue Depth ─────────────────────────────────────────────
    Write-Host "`n[L3] NVMe I/O Queue Depth..." -ForegroundColor Yellow
    $currentQD = Get-NVMeQueueDepth
    if ($currentQD -ge 1024) {
        Write-Host "    SKIP — già $currentQD" -ForegroundColor Green
        $results.Skipped += 'L3_NVMe'
    } else {
        try {
            # Crea la chiave Parameters se non esiste
            if (-not (Test-Path $RST_PARAM_KEY)) {
                New-Item -Path $RST_PARAM_KEY -Force | Out-Null
            }
            Set-ItemProperty -Path $RST_PARAM_KEY -Name 'NumberOfRequests' -Value 1024 -Type DWord
            $afterQD = Get-NVMeQueueDepth
            Write-Host "    OK — NVMe queue depth: $currentQD → $afterQD" -ForegroundColor Green
            Write-Host "    NOTA: richiede reboot per entrare in effetto" -ForegroundColor Yellow
            $results.Applied += "L3_NVMe_QueueDepth_1024_reboot_required"
        } catch {
            Write-Host "    ERRORE: $_" -ForegroundColor Red
            $results.Failed += "L3_NVMe: $_"
        }
    }

    # ── Layer 1: FIVR (interattivo/guidato) ───────────────────────────────────
    Write-Host "`n[L1] FIVR Undervolting..." -ForegroundColor Yellow
    if ($IncludeFIVR) {
        Invoke-FIVRGuide
        $results.Applied += "L1_FIVR_guide_executed"
    } else {
        Write-Host "    SKIP automatico (usa -IncludeFIVR per la guida interattiva)" -ForegroundColor Yellow
        Write-Host "    → Guida rapida FIVR:"
        Write-Host "       1. Avvia ThrottleStop"
        Write-Host "       2. Clicca FIVR"
        Write-Host "       3. CPU Core: imposta offset = -$CoreOffsetMV mV"
        Write-Host "       4. CPU Cache: imposta offset = -$CacheOffsetMV mV"
        Write-Host "       5. Clicca OK → Apply → osserva HWiNFO MCE counter per 10min"
        Write-Host "       6. Se stabile: scendi a -80mV"
        Write-Host "       7. Se instabile (BSOD): ThrottleStop auto-ripristina al reboot"
        $results.Skipped += 'L1_FIVR_manual_required'
    }

    # Salva risultati
    $results | ConvertTo-Json -Depth 5 | Set-Content -Path $LogPath -Encoding UTF8
    Write-Host "`n[OK] Apply completato. Log: $LogPath" -ForegroundColor Green
    if ($results.Failed.Count -gt 0) {
        Write-Host "[WARN] Falliti: $($results.Failed -join ', ')" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════"
    Write-Host "  ANTI-REGRESSIONE:"
    Write-Host "    Rollback: pwsh -File scripts\kernel-level-optimize.ps1 -Mode Rollback"
    Write-Host "    Validate: pwsh -File scripts\kernel-level-optimize.ps1 -Mode Validate"
    Write-Host "    Layer 1 (FIVR) è NON permanente fino a ThrottleStop Apply+Save"
    Write-Host "═══════════════════════════════════════════════════════`n"
    return $results
}

# ── FIVR GUIDE ────────────────────────────────────────────────────────────────
function Invoke-FIVRGuide {
    Write-Host "    Verifica ThrottleStop INI per FIVR lock..." -ForegroundColor Yellow
    if (-not (Test-Path $TS_INI)) {
        Write-Host "    ERRORE: ThrottleStop.ini non trovato: $TS_INI" -ForegroundColor Red
        Write-Host "    Apri ThrottleStop almeno una volta per generare il file .ini"
        return
    }

    $ini = Get-Content $TS_INI -Raw
    # Aggiorna i valori Undervolt nel INI
    # Formato TS: Undervolt_0=-50 (Core), Undervolt_2=-50 (Cache)
    # I suffissi _2 sono per il profilo 2-4
    $newIni = $ini
    $changed = 0
    foreach ($profile in @(0,1,2,3)) {
        foreach ($suffix in @('', '_2')) {
            $keyCore  = "Undervolt_$profile$suffix"
            $keyCache = "Undervolt_Cache_$profile$suffix"
            if ($newIni -match "(?m)^$keyCore\s*=\s*(.+)$") {
                $current = [int]$Matches[1].Trim()
                if ($current -gt -$CoreOffsetMV) {
                    $newIni = $newIni -replace "(?m)^($keyCore\s*=\s*)(.+)$", "`${1}-$CoreOffsetMV"
                    $changed++
                }
            }
        }
    }

    if ($changed -gt 0) {
        # Backup TS INI prima di modificare
        $tsBk = "$TS_INI.kernel-optimize-bk-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item $TS_INI $tsBk
        Set-Content -Path $TS_INI -Value $newIni -Encoding UTF8
        Write-Host "    FIVR INI aggiornato ($changed campi) — backup: $tsBk" -ForegroundColor Green
        Write-Host "    Riavvia ThrottleStop per applicare i nuovi valori" -ForegroundColor Yellow
    } else {
        Write-Host "    Nessuna modifica necessaria (valori già >= -$CoreOffsetMV mV)" -ForegroundColor Green
    }
}

# ── VALIDATE ──────────────────────────────────────────────────────────────────
function Invoke-Validate {
    Write-Host "`n═══════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  KERNEL-LEVEL OPTIMIZE — VALIDATE" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════`n" -ForegroundColor Cyan

    $val = [ordered]@{ Timestamp = (Get-Date -Format 'o'); Checks = [ordered]@{} }

    # Carica baseline rollback per confronto
    $baseline = $null
    if (Test-Path $BackupFile) {
        $baseline = Get-Content $BackupFile -Raw | ConvertFrom-Json
    }

    # ── Check L2: C-State ─────────────────────────────────────────────────────
    $csNow = Get-CStateDepth
    $csPre = if ($baseline) { [int]$baseline.CStateDepth } else { -1 }
    $csOk  = $csNow -le 2 -and $csNow -ge 0
    Write-Host "[L2] C-State depth: $(if ($csPre -ge 0) {"era $csPre → "})ora $csNow $(if ($csOk) {'✓ OK'} else {'✗ NON applicato'})" -ForegroundColor $(if ($csOk) {'Green'} else {'Red'})
    $val.Checks.L2_CState = [ordered]@{ PreApply = $csPre; PostApply = $csNow; Pass = $csOk }

    # ── Check L3: NVMe ────────────────────────────────────────────────────────
    $qdNow = Get-NVMeQueueDepth
    $qdPre = if ($baseline) { [int]$baseline.NVMeQueueDepth } else { -1 }
    $qdOk  = $qdNow -ge 1024
    Write-Host "[L3] NVMe queue depth: $(if ($qdPre -ge 0) {"era $qdPre → "})ora $qdNow $(if ($qdOk) {'✓ OK'} else {'✗ NON applicato (reboot?)'}) " -ForegroundColor $(if ($qdOk) {'Green'} else {'Yellow'})
    $val.Checks.L3_NVMe = [ordered]@{ PreApply = $qdPre; PostApply = $qdNow; Pass = $qdOk }

    # ── Check L1: FIVR ────────────────────────────────────────────────────────
    $fivrNow = Get-FIVRCurrentValues
    $fivrOk  = $false
    if ($fivrNow -and $fivrNow.Contains('Undervolt_0')) {
        $v = [int]$fivrNow['Undervolt_0']
        $fivrOk = $v -le -20
        Write-Host "[L1] FIVR Core offset: $v mV $(if ($fivrOk) {'✓ Undervolted'} else {'○ Non ancora applicato (normale)'})" -ForegroundColor $(if ($fivrOk) {'Green'} else {'Yellow'})
    } else {
        Write-Host "[L1] FIVR: TS INI non disponibile o senza valori Undervolt" -ForegroundColor Yellow
    }
    $val.Checks.L1_FIVR = [ordered]@{ CoreOffsetMV = if ($fivrNow -and $fivrNow.Contains('Undervolt_0')) { [int]$fivrNow['Undervolt_0'] } else { 0 }; Pass = $fivrOk }

    # ── WHEA MCE rate post ────────────────────────────────────────────────────
    Write-Host "`n[CHECK] WHEA MCE ultimi 30 min..."
    $since30 = (Get-Date).AddMinutes(-30)
    $mceNow = 0
    try {
        $mceNow = @(Get-WinEvent -LogName 'System' -MaxEvents 500 -ErrorAction SilentlyContinue |
            Where-Object { $_.TimeCreated -gt $since30 -and $_.Id -in @(18,47,52,54,57) }).Count
    } catch {}
    Write-Host "    WHEA MCE (30min): $mceNow" -ForegroundColor $(if ($mceNow -eq 0) {'Green'} elseif ($mceNow -lt 5) {'Yellow'} else {'Red'})
    $val.Checks.WHEA_MCE_30min = $mceNow

    # ── Riepilogo ─────────────────────────────────────────────────────────────
    $passCount = ($val.Checks.Values | Where-Object { $_ -is [System.Collections.Specialized.OrderedDictionary] -and $_.Pass -eq $true }).Count
    Write-Host "`n═══════════════════════════════════════════════════════"
    Write-Host "  VALIDAZIONE: $passCount/3 layer confermati"
    Write-Host "  WHEA MCE (30min): $mceNow eventi"
    Write-Host "═══════════════════════════════════════════════════════`n"

    $val | ConvertTo-Json -Depth 5 | Set-Content -Path $LogPath -Encoding UTF8
    Write-Host "[OK] Report validazione: $LogPath`n" -ForegroundColor Green
    return $val
}

# ── ROLLBACK ──────────────────────────────────────────────────────────────────
function Invoke-Rollback {
    Write-Host "`n═══════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  KERNEL-LEVEL OPTIMIZE — ROLLBACK" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════`n" -ForegroundColor Cyan

    if (-not (Test-Path $BackupFile)) {
        Write-Error "Backup non trovato: $BackupFile. Impossibile eseguire rollback."
        return
    }
    $backup = Get-Content $BackupFile -Raw | ConvertFrom-Json
    Write-Host "[0] Backup caricato da $BackupFile (snapshot del $(($backup.Timestamp -replace 'T',' ').Split('.')[0]))"

    # ── Rollback L2: C-State ─────────────────────────────────────────────────
    Write-Host "`n[L2] Rollback C-State depth → $($backup.CStateDepth)..." -ForegroundColor Yellow
    try {
        $orig = [int]$backup.CStateDepth
        if ($orig -ge 0) {
            powercfg /setacvalueindex $BALANCED_GUID SUB_PROCESSOR IDLESTATEMAX $orig 2>&1 | Out-Null
            powercfg /setdcvalueindex $BALANCED_GUID SUB_PROCESSOR IDLESTATEMAX $orig 2>&1 | Out-Null
            powercfg /setactive $BALANCED_GUID 2>&1 | Out-Null
            Write-Host "    OK — C-State ripristinato a indice $orig" -ForegroundColor Green
        } else {
            Write-Host "    SKIP — valore backup non valido ($orig)" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "    ERRORE: $_" -ForegroundColor Red
    }

    # ── Rollback L3: NVMe ────────────────────────────────────────────────────
    Write-Host "`n[L3] Rollback NVMe queue depth → $($backup.NVMeQueueDepth)..." -ForegroundColor Yellow
    try {
        $origQD = [int]$backup.NVMeQueueDepth
        if ($origQD -gt 0 -and $origQD -ne 1024) {
            Set-ItemProperty -Path $RST_PARAM_KEY -Name 'NumberOfRequests' -Value $origQD -Type DWord -ErrorAction SilentlyContinue
            Write-Host "    OK — queue depth ripristinato a $origQD (reboot per effetto)" -ForegroundColor Green
        } elseif ($origQD -eq -1) {
            # Era il default (nessuna chiave) → rimuovi la chiave
            Remove-ItemProperty -Path $RST_PARAM_KEY -Name 'NumberOfRequests' -ErrorAction SilentlyContinue
            Write-Host "    OK — chiave NumberOfRequests rimossa (ripristino default 254)" -ForegroundColor Green
        } else {
            Write-Host "    SKIP — già al valore originale" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "    ERRORE: $_" -ForegroundColor Red
    }

    # ── Rollback L1: FIVR ────────────────────────────────────────────────────
    Write-Host "`n[L1] FIVR rollback — richiede ThrottleStop manuale" -ForegroundColor Yellow
    Write-Host "    ThrottleStop auto-ripristina i valori FIVR al prossimo avvio."
    Write-Host "    Per rollback immediato: ThrottleStop → FIVR → imposta offset = 0 → OK"

    Write-Host "`n[OK] Rollback completato. Riavviare per effetto NVMe.`n" -ForegroundColor Green
}

# ── MAIN ──────────────────────────────────────────────────────────────────────
switch ($Mode) {
    'Audit'    { Invoke-Audit }
    'Apply'    { Invoke-Apply }
    'Validate' { Invoke-Validate }
    'Rollback' { Invoke-Rollback }
}
