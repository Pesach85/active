<#
.SYNOPSIS
    Level 3 optimization: disabilita servizi background ad alto costo RAM/CPU
    su un sistema laptop standalone (Dell Inspiron 7577).

.DESCRIPTION
    Analisi pre-intervento identificò 10 processi Dell bloatware che consumano
    ~1.25 GB di RAM in idle, generando:
      - paging continuo (RAM al 94%) → System process disk I/O
      - CPU polling background (telemetria, diagnostica, aggiornamenti)
      - Event Log noise (SupportAssist genera eventi propri)

    Target:
      DISABLE  — servizi non necessari su laptop personale standalone
      MANUAL   — servizi utili solo su richiesta esplicita (non sempre in esecuzione)

    NON TOCCA:
      - Antivirus (MsMpEng / Windows Defender)
      - Windows Update services (wuauserv, WaaSMedicSvc)
      - Servizi VMware (l'utente usa VMware Workstation attivamente)
      - camsvc (Capability Access Manager — sistema Windows)

    Security audit:
      - Logon success → failure only (riduce Security log event 4624/4672)
      - Security.evtx cap 20MB → 8MB

.PARAMETER Mode
    Audit    - Solo lettura: mostra stato attuale, RAM consumata, piano.
    Apply    - Applica con backup rollback.
    Rollback - Ripristina StartType originali e riavvia i servizi.

.PARAMETER LogPath
    Output JSON. Default: logs/bloatware-services-live.json

.EXAMPLE
    pwsh -File scripts\tune-bloatware-services.ps1 -Mode Audit
    pwsh -File scripts\tune-bloatware-services.ps1 -Mode Apply
    pwsh -File scripts\tune-bloatware-services.ps1 -Mode Rollback
#>

#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Audit','Apply','Rollback')]
    [string]$Mode = 'Audit',

    [string]$LogPath = 'logs/bloatware-services-live.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Percorsi ──────────────────────────────────────────────────────────────────
$Root       = if ($PSScriptRoot) { Split-Path $PSScriptRoot -Parent } else { (Get-Location).Path }
$LogPath    = Join-Path $Root $LogPath
$BackupFile = Join-Path $Root 'logs/bloatware-services-rollback.json'

# ── Piano di intervento ───────────────────────────────────────────────────────
# ServiceName: nome servizio Windows
# Action: Disable | Manual
# ProcessNames: processi da terminare (array)
# Rationale: motivo tecnico
$SERVICE_PLAN = @(
    [pscustomobject]@{
        ServiceName  = 'SupportAssistAgent'
        DisplayName  = 'Dell SupportAssist'
        Action       = 'Disable'
        ProcessNames = @('SupportAssistAgent')
        Rationale    = 'Telemetria/diagnostica remota Dell. ~300MB RAM. Inutile su laptop personale. Riabilitare solo per assistenza Dell attiva.'
    },
    [pscustomobject]@{
        ServiceName  = 'Dell SupportAssist Remediation'
        DisplayName  = 'Dell SupportAssist Remediation'
        Action       = 'Disable'
        ProcessNames = @('DellSupportAssistRemedationService')
        Rationale    = 'Remediation agent per supporto remoto Dell. ~114MB. Inutile.'
    },
    [pscustomobject]@{
        ServiceName  = 'DellClientManagementService'
        DisplayName  = 'Dell Client Management Service'
        Action       = 'Disable'
        ProcessNames = @('Dell.CoreServices.Client','Dell.ClientManagementService')
        Rationale    = 'Fleet management enterprise. ~123MB. Completamente inutile su laptop personale non gestito.'
    },
    [pscustomobject]@{
        ServiceName  = 'DellTechHub'
        DisplayName  = 'Dell TechHub'
        Action       = 'Manual'
        ProcessNames = @('Dell.TechHub','Dell.TechHub.Analytics.SubAgent','Dell.TechHub.DataManager.SubAgent',
                         'Dell.TechHub.Diagnostics.SubAgent','Dell.TechHub.Instrumentation.SubAgent',
                         'Dell.TechHub.Instrumentation.UserProcess','Dell.Update.SubAgent')
        Rationale    = 'App hub telemetria Dell. 7 sottoagenti per ~710MB totali. Impostato Manual (non Disable): app TechHub rimane avviabile, ma non parte in background.'
    },
    [pscustomobject]@{
        ServiceName  = 'DSAUpdateService'
        DisplayName  = 'Intel Driver & Support Assistant Updater'
        Action       = 'Manual'
        ProcessNames = @('DSAUpdateService')
        Rationale    = 'Check aggiornamenti driver Intel in background. Manual: si attiva solo quando apri DSA manualmente.'
    },
    [pscustomobject]@{
        ServiceName  = 'DSAService'
        DisplayName  = 'Intel Driver & Support Assistant'
        Action       = 'Manual'
        ProcessNames = @('DSAService')
        Rationale    = 'Driver scan Intel. Manual: disponibile su richiesta, non in polling continuo.'
    }
)

# ── Security audit target ──────────────────────────────────────────────────────
# Riduzione event 4624/4672 (logon success) - su standalone non ha valore diagnostico
$AUDIT_LOGON = 'Accesso'   # italiano

# ── Helper: processo in esecuzione ────────────────────────────────────────────
function Get-ProcessRAM ([string[]]$Names) {
    $total = 0
    foreach ($n in $Names) {
        Get-Process -Name $n -ErrorAction SilentlyContinue | ForEach-Object {
            $total += $_.WorkingSet64
        }
    }
    return [math]::Round($total/1MB, 1)
}

function Get-ServiceState ([string]$Name) {
    try {
        $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if ($null -eq $svc) { return $null }
        return [pscustomobject]@{
            Name      = $svc.Name
            Status    = $svc.Status.ToString()
            StartType = $svc.StartType.ToString()
        }
    } catch { return $null }
}

# ── RAM totale del sistema ────────────────────────────────────────────────────
function Get-SystemRAMPressure {
    $os = Get-CimInstance Win32_OperatingSystem
    return [pscustomobject]@{
        TotalGB  = [math]::Round($os.TotalVisibleMemorySize/1MB, 1)
        FreeGB   = [math]::Round($os.FreePhysicalMemory/1MB, 2)
        UsedPct  = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory)/$os.TotalVisibleMemorySize*100, 1)
    }
}

# =============================================================================
# AUDIT
# =============================================================================
function Invoke-Audit {
    $ram = Get-SystemRAMPressure

    $plan = foreach ($entry in $SERVICE_PLAN) {
        $svcState = Get-ServiceState $entry.ServiceName
        $ramMB    = Get-ProcessRAM $entry.ProcessNames
        [pscustomobject]@{
            Service      = $entry.ServiceName
            Action       = $entry.Action
            CurrentState = if ($svcState) { "$($svcState.Status)/$($svcState.StartType)" } else { 'NotFound' }
            ProcessRAMMB = $ramMB
            Rationale    = $entry.Rationale
        }
    }

    $totalBloatRAM = ($plan | Measure-Object ProcessRAMMB -Sum).Sum

    # VMware RAM
    $vmwareRAM = Get-ProcessRAM @('vmware-vmx','mksSandbox','vmware')

    # Security log Logon state
    $logonState = auditpol /get /subcategory:$AUDIT_LOGON 2>&1 |
        Out-String | ForEach-Object { ($_ -split "`n") | Where-Object { $_ -match 'Accesso\s+' } | Select-Object -First 1 }

    $result = [ordered]@{
        CapturedAt          = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Mode                = 'Audit'
        RAM_UsedPct         = $ram.UsedPct
        RAM_FreeGB          = $ram.FreeGB
        RAM_TotalGB         = $ram.TotalGB
        BloatwareRAM_MB     = [math]::Round($totalBloatRAM, 1)
        VMwareRAM_MB        = $vmwareRAM
        EstimatedRecoveryMB = [math]::Round(($plan | Where-Object { $_.Action -eq 'Disable' } |
            Measure-Object ProcessRAMMB -Sum).Sum +
            ($plan | Where-Object { $_.Action -eq 'Manual' } | Measure-Object ProcessRAMMB -Sum).Sum, 1)
        SecurityLogonAudit  = if ($logonState) { $logonState.Trim() } else { 'N/A' }
        ServicePlan         = $plan
        VMwareNote          = "⚠ VM TIA Portal V16 attiva: $vmwareRAM MB. Suspendi quando non in uso per recuperare ~9 GB RAM istantaneamente."
        NextStep            = 'pwsh -File scripts\tune-bloatware-services.ps1 -Mode Apply'
    }

    return $result
}

# =============================================================================
# APPLY
# =============================================================================
function Invoke-Apply {
    $before = Invoke-Audit

    # Backup
    $backupData = @{
        CreatedAt    = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        ServiceStates = foreach ($entry in $SERVICE_PLAN) {
            $s = Get-ServiceState $entry.ServiceName
            if ($s) { $s }
        }
    }
    $backupData | ConvertTo-Json -Depth 5 | Set-Content $BackupFile -Encoding UTF8
    Write-Host "Backup rollback salvato: $BackupFile" -ForegroundColor Green

    $applied = [System.Collections.Generic.List[object]]::new()
    $skipped = [System.Collections.Generic.List[string]]::new()

    foreach ($entry in $SERVICE_PLAN) {
        $svc = Get-Service -Name $entry.ServiceName -ErrorAction SilentlyContinue
        if (-not $svc) {
            Write-Host "  SKIP (non trovato): $($entry.ServiceName)" -ForegroundColor DarkGray
            $skipped.Add($entry.ServiceName)
            continue
        }

        $targetStartup = if ($entry.Action -eq 'Disable') { 'Disabled' } else { 'Manual' }
        $before_state  = $svc.StartType.ToString()

        # Ferma i processi relativi
        $stoppedPIDs = @()
        foreach ($pname in $entry.ProcessNames) {
            Get-Process -Name $pname -ErrorAction SilentlyContinue | ForEach-Object {
                try {
                    $ramMB = [math]::Round($_.WorkingSet64/1MB, 1)
                    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
                    Write-Host "  STOPPED process: $pname (PID=$($_.Id), RAM=$ramMB MB)" -ForegroundColor Yellow
                    $stoppedPIDs += $_.Id
                } catch { Write-Warning "  CANNOT stop $pname : $_" }
            }
        }

        # Cambia startup type del servizio
        try {
            Set-Service -Name $entry.ServiceName -StartupType $targetStartup -ErrorAction Stop
            if ($entry.Action -eq 'Disable') {
                Stop-Service -Name $entry.ServiceName -Force -ErrorAction SilentlyContinue
            }
            Write-Host "  $($entry.Action.ToUpper()): $($entry.ServiceName) ($before_state → $targetStartup)" -ForegroundColor Cyan
            $applied.Add([pscustomobject]@{
                Service  = $entry.ServiceName
                Change   = "$before_state → $targetStartup"
                Action   = $entry.Action
            })
        } catch {
            Write-Warning "  ERRORE su $($entry.ServiceName): $_"
        }
    }

    # Security audit: Logon success → failure only
    Write-Host "`n  AUDITPOL: Logon success=disable (riduce event 4624/4672)..." -ForegroundColor Cyan
    $ret = auditpol /set /subcategory:$AUDIT_LOGON /success:disable /failure:enable 2>&1
    if ($LASTEXITCODE -eq 0) {
        $applied.Add([pscustomobject]@{
            Service = "AuditPol:$AUDIT_LOGON"
            Change  = 'success=disable / failure=enable (elimina eventi 4624/4672)'
            Action  = 'AuditPol'
        })
        Write-Host "  AUDITPOL: $AUDIT_LOGON → success=disable OK" -ForegroundColor Cyan
    } else {
        Write-Warning "  auditpol warning: $ret"
    }

    # Security log cap 8MB
    Write-Host "  CAP: Security.evtx 20MB → 8MB..." -ForegroundColor Cyan
    wevtutil sl Security /ms:$([long](8*1MB)) /rt:false /ab:false 2>$null
    if ($LASTEXITCODE -eq 0) {
        $applied.Add([pscustomobject]@{
            Service = 'Security EventLog'
            Change  = 'MaxSize 20MB → 8MB circular'
            Action  = 'Cap'
        })
    }

    $after = Invoke-Audit

    $result = [ordered]@{
        CapturedAt         = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Mode               = 'Apply'
        Applied            = $applied
        Skipped            = $skipped
        RAMBefore_UsedPct  = $before.RAM_UsedPct
        RAMAfter_UsedPct   = $after.RAM_UsedPct
        RAMBefore_FreeGB   = $before.RAM_FreeGB
        RAMAfter_FreeGB    = $after.RAM_FreeGB
        RecoveredRAM_MB    = [math]::Round(($after.RAM_FreeGB - $before.RAM_FreeGB) * 1024, 0)
        BackupFile         = $BackupFile
        AntiRegression     = @(
            'Rollback: pwsh -File scripts\tune-bloatware-services.ps1 -Mode Rollback',
            'Dell SupportAssist può essere riavviato manualmente: Start-Service SupportAssistAgent',
            'DellTechHub è impostato Manual: si avvia solo aprendo manualmente l''app',
            'Per aggiornamenti driver Intel: avvia DSAService manualmente quando serve',
            'IMPORTANTE: vmware-vmx NON toccato. Suspendi VM TIA Portal quando non in uso per recuperare ~9GB RAM'
        )
        VMwareReminder     = $after.VMwareNote
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

    foreach ($saved in $backup.ServiceStates) {
        try {
            $startType = switch ($saved.StartType) {
                'Automatic'          { 'Automatic' }
                'AutomaticDelayed'   { 'AutomaticDelayedStart' }
                'Manual'             { 'Manual' }
                'Disabled'           { 'Disabled' }
                default              { 'Manual' }
            }
            Set-Service -Name $saved.Name -StartupType $startType -ErrorAction SilentlyContinue
            if ($saved.Status -eq 'Running') {
                Start-Service -Name $saved.Name -ErrorAction SilentlyContinue
            }
            Write-Host "  RESTORED: $($saved.Name) → $startType" -ForegroundColor Green
            $restored.Add("$($saved.Name): $startType")
        } catch {
            Write-Warning "Rollback fallito per $($saved.Name): $_"
        }
    }

    # Rollback auditpol Logon
    auditpol /set /subcategory:$AUDIT_LOGON /success:enable /failure:enable 2>&1 | Out-Null
    Write-Host "  AuditPol Logon ripristinato (success=enable)" -ForegroundColor Green

    # Rollback Security log cap
    wevtutil sl Security /ms:$([long](20*1MB)) 2>$null
    Write-Host "  Security log: cap ripristinato a 20MB" -ForegroundColor Green

    return [ordered]@{
        CapturedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Mode       = 'Rollback'
        Restored   = $restored
        Status     = 'Completato'
    }
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

$display = [ordered]@{}
foreach ($key in $output.Keys) { $display[$key] = $output[$key] }
$display | ConvertTo-Json -Depth 5
