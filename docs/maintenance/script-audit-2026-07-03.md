# Manutenzione Script — Audit e Potenziamento GUI

**Data:** 2026-07-03  

## Validità script core

| Script | Stato | Note |
|--------|-------|------|
| `monitor-resources.ps1` | OK | Legge config, path log relativi |
| `cleanup-storage-safe.ps1` | Migliorato | Config-driven retention + tier-2 |
| `system-health-audit.ps1` | OK | Finding WSL-CONFIG-001 integrato |
| `repair-wsl-config.ps1` | OK | Probe gated, rollback JSON |
| `quick-cleanup-safe.ps1` | OK | Default log portabile |
| `install-*-task.ps1` | Migliorato | Default da hub root |
| `monitor-whea-rate.ps1` | Migliorato | wevtutil fallback + config |
| `fs-integrity.ps1` | Nuovo | Scan-only |
| `hub-orchestrator.ps1` | Nuovo | Heartbeat + rotation |

## Configurazione centralizzata

Tutti i parametri operativi rilevanti vivono in `config/sys-maintenance.json`:

- **Monitor** — soglie CPU/RAM, intervallo loop, drive
- **Cleanup** — retention, tier-2 whitelist
- **Whea** — soglie Go/Hold, fallback RPC
- **Orchestrator** — heartbeat, rotation, sub-task
- **FsIntegrity** — drive scan, output path
- **Gui** — preferenze dashboard e retention diagnostica

## GUI — tab Config

- Save/Reload persistente su JSON
- Controlli: auto-analyze, temp/log retention, diagnostic retention, tier-2 enable/simulate
- Parametri avanzati (monitor thresholds, WHEA): edit JSON o Notepad

## Miglioramenti futuri suggeriti

1. Tab Config: slider CPU/RAM threshold senza edit JSON
2. Pulsante "Run orchestrator once" dalla GUI
3. Visualizzazione findings fs-integrity in Deep Scan tab
4. Scheduled task installer per orchestrator in `install-suite.ps1`
