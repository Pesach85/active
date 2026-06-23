# Task Board

## ToDo
- Implementare fs-integrity.ps1 (scan-only, eventi, alert).
- Aggiungere orchestratore unico con heartbeat e log rotation.
- Implementare cleanup tier-2 su D con whitelist approvata e simulazione pre-run.
- Ripristinare raccolta live WHEA (errore RPC su Get-WinEvent) con check servizi log/RPC e task monitor.
- Validare post-sostituzione DIMM: target anti-regressione WHEA <= 50/10min per 24h prima di eventuale rollback badmemorylist.

## In Progress
- Nessuno.

## Done
- Setup iniziale struttura modulare e monitor risorse.
- Centralizzazione profilo operativo in C:/SystemOptimizerHub/active.
- Runtime Core-only per task always-on.
- Dashboard con explorer garbage intelligence e criteri audit/cleanup regolabili.
- Packaging trasferibile con GUI EXE e script install/uninstall.
- WSL auto-check/autofix: `repair-wsl-config.ps1` + finding `WSL-CONFIG-001` in Health Audit (fix HKLM/HKCU desync, zombie cleanup, recovery WslService, abilitazione hypervisor per boot WSL2).
