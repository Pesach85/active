# Runbook — Storage Cleanup Safe

**ID:** RB-CLEANUP-001  
**Stato:** Active  
**Ultimo aggiornamento:** 2026-09-04  

## Scopo

Cleanup audit-first di temp/cache/log con modalità Safe/Radical e tier-2 opzionale su D:.

## Controlli GUI (Home)

| Controllo | Effetto |
|-----------|---------|
| **UNITÀ / DRIVE** | Volume per Scan Storage (default C; non toccare D salvo richiesta) |
| **PROFONDITÀ / DEPTH** | Budget campionamento file (Quick/Standard/Deep) |
| **DETTAGLIO** | FileLevel vs BitLevel (cluster + magic + LCN sample) |
| **PULIZIA / CLEAN MODE** | Solo Storage Audit/Clean in Altri strumenti — non Scan Storage |
| **FIX MAX** | Solo tab Salute — livello max Health Apply |

## Configurazione GUI

Tab **Config** → retention temp/log, tier-2 enabled/simulate → **Save GUI Settings**.

Oppure `config/sys-maintenance.json` → `Cleanup`:

```json
"Cleanup": {
  "TempRetentionDays": 7,
  "LogRetentionDays": 30,
  "Tier2": {
    "Enabled": false,
    "SimulateOnly": true,
    "WhitelistPaths": ["D:\\DataHub\\Temp", "D:\\DataHub\\Cache"]
  }
}
```

## Audit (default)

```powershell
pwsh -File scripts/cleanup-storage-safe.ps1 -ConfigPath config/sys-maintenance.json
```

## Execute

```powershell
pwsh -File scripts/cleanup-storage-safe.ps1 -Execute -ConfigPath config/sys-maintenance.json
```

## Occupancy granulare (unità selezionata)

```powershell
pwsh -File scripts/analyze-disk-occupancy.ps1 -ListDrives
pwsh -File scripts/analyze-disk-occupancy.ps1 -Drive C -Depth Standard -AuditLevel BitLevel
pwsh -File scripts/analyze-disk-occupancy.ps1 -Drive C -Depth Standard -AuditLevel BitLevel -ExecuteSafeDelete
```

Report: `logs/disk-occupancy-latest.json`  
HITL personale: campo `PersonalHitl` — non cancellato.

BitLevel = cluster NTFS + magic header + sample LCN. Non è un dump bit-a-bit del volume.

- Tier-2 con `SimulateOnly=true` non cancella anche in `-Execute`
- Skip `SoftwareDistribution` se `wuauserv` running
- Log: `logs/storage-cleanup.log`

## Rollback

N/A per file eliminati — usare sempre audit prima di execute.
