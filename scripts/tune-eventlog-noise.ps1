<#
.SYNOPSIS
    Riduce il disk I/O dell'Event Log silenziando canali verbose inutili su un
    sistema laptop non-server (Dell Inspiron 7577).

.DESCRIPTION
    Analisi pre-intervento identificò 170+ MB di file .evtx in canali operativi
    che non producono valore diagnostico in idle:
      - WHEA/Errors:                  32MB (500 eventi/h, MCE correctable)
      - Store/Operational:            19MB (noise app store)
      - Hyper-V-VmSwitch-Operational: 17MB (noise WSL2 vSwitch — NON disabilitiamo l'adapter)
      - StorageManagement/Operational: 16MB (debug storage spaces)
      - Ntfs/Operational:             19MB (debug NTFS operativo)
      - AppXDeployment/Operational:    ~7MB (debug AppX)
      - StateRepository/Operational:   ~5MB (debug app state DB)

    SICUREZZA: C:\Users condivisa via SMB (LanmanServer) = HIGH risk su laptop
    personale. Lo script emette warning e fornisce comando di rimozione.

    Azioni per categoria:
      DISABLE  — canal Operational/Debug senza valore diagnostico in produzione
      CAP      — riduce maxSize per log utili mantenendoli circolari
      AUDITPOL — riduce verbosità Security log (Event 5379 credential reads)

.PARAMETER Mode
    Audit    - Solo lettura. Mostra stato attuale e piano di intervento.
    Apply    - Applica tutte le modifiche con backup rollback.
    Rollback - Ripristina stato pre-Apply dal file di backup.

.PARAMETER SkipAuditPol
    Non modifica le policy di audit di sicurezza (usa se sei in dominio AD).

.PARAMETER LogPath
    Output JSON. Default: logs/eventlog-noise-live.json

.EXAMPLE
    # Step 1: verifica piano
    pwsh -File scripts\tune-eventlog-noise.ps1 -Mode Audit

    # Step 2: applica
    pwsh -File scripts\tune-eventlog-noise.ps1 -Mode Apply

    # Rollback se necessario
    pwsh -File scripts\tune-eventlog-noise.ps1 -Mode Rollback
#>

#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Audit','Apply','Rollback')]
    [string]$Mode = 'Audit',

    [switch]$SkipAuditPol,

    [string]$LogPath = 'logs/eventlog-noise-live.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Percorsi ──────────────────────────────────────────────────────────────────
$Root        = if ($PSScriptRoot) { Split-Path $PSScriptRoot -Parent } else { (Get-Location).Path }
$LogPath     = Join-Path $Root $LogPath
$BackupFile  = Join-Path $Root 'logs/eventlog-noise-rollback.json'
$EvtxDir     = 'C:\Windows\System32\winevt\Logs'

# ── Piano di intervento ───────────────────────────────────────────────────────
# Ogni voce: Name (log channel), Action (Disable|Cap), NewSizeMB (solo Cap)
# Rationale documenta il motivo tecnico.
$PLAN = @(
    # --- DISABLE: nessun valore diagnostico in normale operatività ---
    [pscustomobject]@{
        Name      = 'Microsoft-Windows-Store/Operational'
        Action    = 'Disable'
        NewSizeMB = $null
        Rationale = 'App store telemetry: ~25k record accumulati, puro noise su sistema non-server'
    },
    [pscustomobject]@{
        Name      = 'Microsoft-Windows-StorageManagement/Operational'
        Action    = 'Disable'
        NewSizeMB = $null
        Rationale = 'Storage Spaces management debug log: irrilevante su single-disk laptop'
    },
    [pscustomobject]@{
        Name      = 'Microsoft-Windows-Hyper-V-VmSwitch-Operational'
        Action    = 'Disable'
        NewSizeMB = $null
        Rationale = 'WSL2 vSwitch genera 294 eventi/h su questo log; WSL2 funziona indipendentemente da questo canale. Riabilitare se serve debug WSL2 networking.'
    },
    [pscustomobject]@{
        Name      = 'Microsoft-Windows-StateRepository/Operational'
        Action    = 'Disable'
        NewSizeMB = $null
        Rationale = 'App package state DB: debug noise puro, ~12k record'
    },
    [pscustomobject]@{
        Name      = 'Microsoft-Windows-Ntfs/Operational'
        Action    = 'Disable'
        NewSizeMB = $null
        Rationale = 'NTFS operational verbose log (19MB): irrilevante in assenza di problemi NTFS attivi'
    },
    [pscustomobject]@{
        Name      = 'Microsoft-Windows-AppXDeploymentServer/Operational'
        Action    = 'Disable'
        NewSizeMB = $null
        Rationale = 'AppX deployment debug: ~6.7k record, irrilevante dopo installazione app'
    },
    [pscustomobject]@{
        Name      = 'Microsoft-Windows-AppReadiness/Admin'
        Action    = 'Disable'
        NewSizeMB = $null
        Rationale = 'App readiness admin log: ~6k record, irrilevante in idle'
    },
    [pscustomobject]@{
        Name      = 'Microsoft-Windows-GroupPolicy/Operational'
        Action    = 'Disable'
        NewSizeMB = $null
        Rationale = 'Group Policy refresh log (~9.5k record): irrilevante su standalone laptop non in dominio'
    },

    # --- CAP: mantieni canale attivo ma limita footprint disco ---
    [pscustomobject]@{
        Name      = 'Microsoft-Windows-Kernel-WHEA/Errors'
        Action    = 'Cap'
        NewSizeMB = 8
        Rationale = 'WHEA errors: mantieni per safety, ma 32MB file è eccessivo. Cap a 8MB circular.'
    },
    [pscustomobject]@{
        Name      = 'Microsoft-Windows-TaskScheduler/Operational'
        Action    = 'Cap'
        NewSizeMB = 2
        Rationale = 'Task scheduler: utile per debug task, ma 13k record/h è eccessivo. Cap a 2MB circular.'
    },
    [pscustomobject]@{
        Name      = 'Microsoft-Windows-PowerShell/Operational'
        Action    = 'Cap'
        NewSizeMB = 4
        Rationale = 'PowerShell operational: utile per audit, cap a 4MB (era 15MB).'
    },
    [pscustomobject]@{
        Name      = 'PowerShellCore/Operational'
        Action    = 'Cap'
        NewSizeMB = 4
        Rationale = 'PowerShell Core operational: utile per audit, cap a 4MB (era 15MB).'
    },
    [pscustomobject]@{
        Name      = 'Microsoft-Windows-Storage-Storport/Operational'
        Action    = 'Cap'
        NewSizeMB = 4
        Rationale = 'Storport operational: mantieni per diagnostica storage, cap a 4MB (era 9MB).'
    },
    [pscustomobject]@{
        Name      = 'Microsoft-Windows-SMBServer/Operational'
        Action    = 'Cap'
        NewSizeMB = 2
        Rationale = 'SMB server: mantieni per debug, cap a 2MB. WARNING: C:\Users share attiva.'
    },
    [pscustomobject]@{
        Name      = 'Microsoft-Windows-SmbClient/Connectivity'
        Action    = 'Cap'
        NewSizeMB = 2
        Rationale = 'SMB client connectivity: 45 eventi/h, cap a 2MB circular.'
    }
)

# ── Audit Policy: Security Event ID 5379 (Credential Manager reads) ───────────
# Subcategory (IT locale): "Altri eventi di gestione account"
# Equivalente EN: "Other Account Management Events"
# Disabilita solo SUCCESS (mantiene FAILURE per sicurezza)
$AUDITPOL_TARGETS = @(
    [pscustomobject]@{
        SubcategoryIT = 'Altri eventi di gestione account'
        SubcategoryEN = 'Other Account Management Events'
        Name          = 'Other Account Management Events (IT: Altri eventi di gestione account)'
        Disable       = 'success'   # disabilita: success=5379 credential reads
        KeepAlways    = 'failure'   # mantieni: failure events sono security-relevant
        Rationale     = 'Event 5379 (Credential Manager reads) = 77/h. Success audit non aggiunge valore di security; failure sì.'
    }
)

# ── Helper: legge stato corrente di un log channel ────────────────────────────
function Get-LogState ([string]$Name) {
    try {
        $raw = wevtutil gl $Name 2>&1
        if ($LASTEXITCODE -ne 0 -or $raw -match 'non trovato|not found|inesistente') {
            return [pscustomobject]@{ Name=$Name; Exists=$false; Enabled=$null; MaxSizeMB=$null; FileSizeMB=$null }
        }
        $enabled  = ($raw | Select-String 'enabled:\s+(true|false)').Matches[0].Groups[1].Value -eq 'true'
        $maxBytes = [long]($raw | Select-String 'maxSize:\s+(\d+)').Matches[0].Groups[1].Value
        
        # File fisico
        $safeFile = $Name -replace '[/\\]','%4' -replace ':',''
        $evtxPath = Join-Path $EvtxDir "$safeFile.evtx"
        $fileSizeMB = if (Test-Path $evtxPath) { [math]::Round((Get-Item $evtxPath).Length/1MB, 2) } else { 0 }
        
        return [pscustomobject]@{
            Name       = $Name
            Exists     = $true
            Enabled    = $enabled
            MaxSizeMB  = [math]::Round($maxBytes/1MB, 2)
            FileSizeMB = $fileSizeMB
        }
    } catch {
        return [pscustomobject]@{ Name=$Name; Exists=$false; Enabled=$null; MaxSizeMB=$null; FileSizeMB=$null }
    }
}

# ── Helper: legge auditpol per GUID ───────────────────────────────────────────
function Get-AuditPolState ([string]$SubcategoryIT) {
    try {
        $out = auditpol /get /subcategory:$SubcategoryIT 2>&1 | Out-String
        $line = ($out -split "`n") | Where-Object { $_ -notmatch '^\s*$|Sistema di controllo|Categoria' } |
            Select-Object -Last 1
        return $line.Trim()
    } catch { return 'N/A' }
}

# ── Helper: calcola totale MB recuperabili ────────────────────────────────────
function Get-TotalEvtxMB {
    $total = 0
    Get-ChildItem $EvtxDir -Filter '*.evtx' -ErrorAction SilentlyContinue |
        ForEach-Object { $total += $_.Length }
    return [math]::Round($total/1MB, 1)
}

# ── Helper: rilevazione SMB share C:\Users ────────────────────────────────────
function Get-UsersShareStatus {
    $share = Get-SmbShare -ErrorAction SilentlyContinue | 
        Where-Object { $_.Path -eq 'C:\Users' }
    return $null -ne $share
}

# =============================================================================
# AUDIT
# =============================================================================
function Invoke-Audit {
    Write-Host "Raccolta stato corrente Event Log..." -ForegroundColor Cyan

    $logStates = foreach ($entry in $PLAN) {
        $state = Get-LogState $entry.Name
        [pscustomobject]@{
            LogName    = $entry.Name -replace 'Microsoft-Windows-',''
            Action     = $entry.Action
            Enabled    = $state.Enabled
            FileSizeMB = $state.FileSizeMB
            MaxSizeMB  = $state.MaxSizeMB
            NewSizeMB  = $entry.NewSizeMB
            Rationale  = $entry.Rationale
        }
    }

    # Totale file .evtx su disco
    $totalMB = Get-TotalEvtxMB

    # Stima riduzione: Disable = elimina FileSizeMB; Cap = riduce a NewSizeMB
    $potentialSavingMB = ($logStates | ForEach-Object {
        if ($_.Action -eq 'Disable' -and $_.Enabled -eq $true) { $_.FileSizeMB }
        elseif ($_.Action -eq 'Cap' -and $_.FileSizeMB -gt $_.NewSizeMB) { $_.FileSizeMB - $_.NewSizeMB }
        else { 0 }
    } | Measure-Object -Sum).Sum

    # Security ID 5379
    $auditStates = foreach ($a in $AUDITPOL_TARGETS) {
        [pscustomobject]@{
            Name    = $a.Name
            Current = Get-AuditPolState $a.SubcategoryIT
        }
    }

    # Security alert
    $usersShareActive = Get-UsersShareStatus

    $result = [ordered]@{
        CapturedAt           = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Mode                 = 'Audit'
        TotalEvtxDiskMB      = $totalMB
        EstimatedSavingMB    = [math]::Round($potentialSavingMB, 1)
        SecurityAlert        = if ($usersShareActive) {
            '⚠ HIGH: C:\Users condivisa via SMB (LanmanServer). Rimuovere con: net share Users /delete'
        } else { 'OK' }
        LogPlan              = $logStates
        AuditPolPlan         = $auditStates
        NextStep             = 'pwsh -File scripts\tune-eventlog-noise.ps1 -Mode Apply'
    }

    return $result
}

# =============================================================================
# APPLY
# =============================================================================
function Invoke-Apply {
    Write-Host "Raccolta baseline pre-apply..." -ForegroundColor Cyan
    $auditBefore = Invoke-Audit

    # ── Backup completo stato attuale ─────────────────────────────────────────
    $backupLogStates = foreach ($entry in $PLAN) {
        $state = Get-LogState $entry.Name
        [pscustomobject]@{
            Name       = $entry.Name
            Enabled    = $state.Enabled
            MaxSizeMB  = $state.MaxSizeMB
        }
    }
    $backupAuditPol = auditpol /backup /file:"$Root\logs\auditpol-backup-pre-eventlog-tune.csv" 2>&1
    $backup = [ordered]@{
        CreatedAt   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        LogStates   = $backupLogStates
        AuditPolCSV = "$Root\logs\auditpol-backup-pre-eventlog-tune.csv"
    }
    $backup | ConvertTo-Json -Depth 5 | Set-Content $BackupFile -Encoding UTF8
    Write-Host "Backup salvato: $BackupFile" -ForegroundColor Green

    $applied = [System.Collections.Generic.List[object]]::new()
    $errors  = [System.Collections.Generic.List[string]]::new()

    # ── Applica ogni entry del piano ──────────────────────────────────────────
    foreach ($entry in $PLAN) {
        $state = Get-LogState $entry.Name
        if (-not $state.Exists) {
            Write-Host "  SKIP (non trovato): $($entry.Name)" -ForegroundColor DarkGray
            continue
        }

        try {
            if ($entry.Action -eq 'Disable') {
                if ($state.Enabled -eq $false) {
                    Write-Host "  ALREADY OFF: $($entry.Name)" -ForegroundColor DarkGray
                } else {
                    wevtutil sl $entry.Name /e:false
                    if ($LASTEXITCODE -ne 0) { throw "wevtutil exit $LASTEXITCODE" }
                    Write-Host "  DISABLED: $($entry.Name)" -ForegroundColor Yellow
                    $applied.Add([pscustomobject]@{ Log=$entry.Name; Change="Disabled (era Enabled)" })
                }
            }
            elseif ($entry.Action -eq 'Cap') {
                $newBytes = [long]($entry.NewSizeMB * 1MB)
                # Imposta: size + circular (retention:false) + no autobackup
                wevtutil sl $entry.Name /ms:$newBytes /rt:false /ab:false
                if ($LASTEXITCODE -ne 0) { throw "wevtutil exit $LASTEXITCODE" }
                Write-Host "  CAPPED: $($entry.Name) → $($entry.NewSizeMB)MB" -ForegroundColor Cyan
                $applied.Add([pscustomobject]@{
                    Log    = $entry.Name
                    Change = "Cap $($state.MaxSizeMB)MB → $($entry.NewSizeMB)MB circular"
                })
            }
        }
        catch {
            $msg = "ERRORE su $($entry.Name): $_"
            Write-Warning $msg
            $errors.Add($msg)
        }
    }

    # ── AuditPol: disabilita Success per "Other Account Management Events" ────
    if (-not $SkipAuditPol) {
        foreach ($a in $AUDITPOL_TARGETS) {
            try {
                $ret = auditpol /set /subcategory:$a.SubcategoryIT /success:disable /failure:enable 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "  AUDITPOL: $($a.SubcategoryIT) success=disable, failure=enable" -ForegroundColor Cyan
                    $applied.Add([pscustomobject]@{
                        Log    = "AuditPol:$($a.Name)"
                        Change = 'success=disable / failure=enable (riduce Event 5379)'
                    })
                } else {
                    Write-Warning "auditpol non applicato ($($a.SubcategoryIT)): $ret"
                }
            } catch { Write-Warning "auditpol exception: $_" }
        }
    }

    # ── Security alert per C:\Users share ────────────────────────────────────
    $usersShareAlert = if (Get-UsersShareStatus) {
        Write-Host ''
        Write-Host '  ⚠ SECURITY ALERT: C:\Users condivisa via SMB!' -ForegroundColor Red
        Write-Host '    Questa share espone tutti i file utente sulla rete locale.' -ForegroundColor Red
        Write-Host '    Per rimuoverla: net share Users /delete' -ForegroundColor Yellow
        Write-Host '    Oppure: Remove-SmbShare -Name Users -Force' -ForegroundColor Yellow
        '⚠ ATTIVA - rimuovere manualmente con: net share Users /delete'
    } else { 'OK - non presente' }

    # ── Risultato ─────────────────────────────────────────────────────────────
    $result = [ordered]@{
        CapturedAt       = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Mode             = 'Apply'
        Applied          = $applied
        Errors           = $errors
        SecurityAlert    = $usersShareAlert
        BackupFile       = $BackupFile
        AntiRegression   = @(
            'Rollback: pwsh -File scripts\tune-eventlog-noise.ps1 -Mode Rollback',
            'I log disabilitati possono essere riabilitati con: wevtutil sl <nome> /e:true',
            'Nessun dato storico perso: i file .evtx esistenti rimangono intatti fino a wrap',
            'WSL2 funziona normalmente con Hyper-V-VmSwitch log disabilitato',
            'Verifica disco I/O in Resource Monitor o: Get-Counter "\Disco\*"'
        )
        Before           = $auditBefore
    }

    return $result
}

# =============================================================================
# ROLLBACK
# =============================================================================
function Invoke-Rollback {
    if (-not (Test-Path $BackupFile)) {
        Write-Error "Backup non trovato: $BackupFile"
        return
    }

    $backup = Get-Content $BackupFile -Raw | ConvertFrom-Json
    Write-Host "Rollback da backup del $($backup.CreatedAt)..." -ForegroundColor Yellow

    $restored = [System.Collections.Generic.List[string]]::new()

    foreach ($saved in $backup.LogStates) {
        try {
            if ($saved.Enabled -eq $true) {
                wevtutil sl $saved.Name /e:true
                $maxBytes = [long]([double]$saved.MaxSizeMB * 1MB)
                if ($maxBytes -gt 0) { wevtutil sl $saved.Name /ms:$maxBytes }
                Write-Host "  RESTORED: $($saved.Name) enabled, $($saved.MaxSizeMB)MB" -ForegroundColor Green
                $restored.Add("$($saved.Name): re-enabled, $($saved.MaxSizeMB)MB")
            } else {
                Write-Host "  SKIP (era già disabilitato): $($saved.Name)" -ForegroundColor DarkGray
            }
        } catch {
            Write-Warning "Rollback fallito per $($saved.Name): $_"
        }
    }

    # Rollback auditpol
    $auditCsv = $backup.AuditPolCSV
    if ($auditCsv -and (Test-Path $auditCsv)) {
        Write-Host "  Ripristino auditpol da $auditCsv..."
        auditpol /restore /file:$auditCsv 2>&1 | Out-Null
        Write-Host "  AuditPol ripristinato" -ForegroundColor Green
    }

    $result = [ordered]@{
        CapturedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Mode       = 'Rollback'
        Restored   = $restored
        Status     = 'Completato'
    }

    return $result
}

# =============================================================================
# MAIN
# =============================================================================
$output = switch ($Mode) {
    'Audit'    { Invoke-Audit }
    'Apply'    { Invoke-Apply }
    'Rollback' { Invoke-Rollback }
}

$output | ConvertTo-Json -Depth 8 | Set-Content $LogPath -Encoding UTF8
Write-Host "`nLog: $LogPath" -ForegroundColor DarkGray

# Output a console (compatto: escludi Before dall'output diretto)
$display = [ordered]@{}
foreach ($key in $output.Keys) {
    if ($key -ne 'Before') { $display[$key] = $output[$key] }
}
$display | ConvertTo-Json -Depth 6
