# Task Board

- Onda 1 refactor: migrare worker rimanenti (cleanup/compute/nvme/deep) su async-worker.
- GUI: tab Salute mostra fs-integrity/orchestrator status (1.5.9).
- Privacy: profili scan Fast/Standard (1.5.10).
- Validare post-sostituzione DIMM: WHEA ≤ 50/10min per 24h (HITL hardware).
- Registrare scheduled task per `hub-orchestrator.ps1` (HITL se serve conferma SYSTEM).
- Abilitare Cleanup Tier-2 su D: solo dopo review whitelist (HITL — write su D:).

## In Progress
- Nessuno.

## Done
- Setup iniziale struttura modulare e monitor risorse.
- Profilo operativo portabile (hub root auto-rilevata; relocation su `D:\SystemOptimizerHub\active`).
- Runtime Core-only per task always-on.
- Dashboard con explorer garbage intelligence e criteri audit/cleanup regolabili.
- Packaging trasferibile con GUI EXE e script install/uninstall.
- WSL auto-check/autofix: `repair-wsl-config.ps1` + finding `WSL-CONFIG-001` in Health Audit.
- `hub-common.ps1` — helper path/config condivisi (+ admin assert 2026-08-27).
- `fs-integrity.ps1` — scan-only integrità filesystem.
- `hub-orchestrator.ps1` — heartbeat, log rotation, trigger WHEA/fs-integrity.
- WHEA monitor: fallback `wevtutil` + check servizi EventLog/RPC.
- Cleanup tier-2 configurabile da `sys-maintenance.json` + tab Config GUI.
- GUI Config tab: Save/Reload impostazioni persistenti.
- Privacy scanner + tab Privacy + config Privacy + package (Fase 1).
- GUI v3 IA: 4 CTA + More tools; i18n IT/EN; command-catalog + pannello help.
- Health Scan read-only vs Scan+Apply avanzato; apply 1 soluzione/finding; sort garbage fix.
- GUI v3.1.2: parse AlreadyOptimized stringhe; layout advanced tools; AutoAnalyze default false.
- GUI v3.1.3: `theme.ps1` + `worker-helpers.ps1`; `test-hub-smoke.ps1`; KB/refactor plan sync.
- **Onda 1–3 (2026-08-27):** `async-worker.ps1`; Privacy/Garbage/Health via hub workers; Save/Load config via hub-common; STARTUP whitelist; PKG Kind OpenLink/Install; WSL header allineato; GUI v3.2.0.
- **Bug 28 (2026-08-27):** HubWorkers global + smoke registry; GUI/EXE **v3.2.1**.
