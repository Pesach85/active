# Task Board

## ToDo
- Validare post-sostituzione DIMM: target anti-regressione WHEA <= 50/10min per 24h prima di eventuale rollback badmemorylist.
- Registrare scheduled task per `hub-orchestrator.ps1` (heartbeat + log rotation).
- Abilitare Cleanup Tier-2 su D: dopo review whitelist in GUI/JSON.

## In Progress
- Nessuno.

## Done
- Setup iniziale struttura modulare e monitor risorse.
- Profilo operativo portabile (hub root auto-rilevata; relocation su `D:\SystemOptimizerHub\active`).
- Runtime Core-only per task always-on.
- Dashboard con explorer garbage intelligence e criteri audit/cleanup regolabili.
- Packaging trasferibile con GUI EXE e script install/uninstall.
- WSL auto-check/autofix: `repair-wsl-config.ps1` + finding `WSL-CONFIG-001` in Health Audit.
- `hub-common.ps1` — helper path/config condivisi.
- `fs-integrity.ps1` — scan-only integrità filesystem.
- `hub-orchestrator.ps1` — heartbeat, log rotation, trigger WHEA/fs-integrity.
- WHEA monitor: fallback `wevtutil` + check servizi EventLog/RPC.
- Cleanup tier-2 configurabile da `sys-maintenance.json` + tab Config GUI.
- GUI Config tab: Save/Reload impostazioni persistenti.
