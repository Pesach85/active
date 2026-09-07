# Troubleshooting — leftover startup / scheduled tasks after hub relocation

**Sintomo:** all'avvio Windows apre un terminale PowerShell (spesso come Administrator) con:

`L'argomento '...verify-nvme-writeoffload-postboot.ps1' per il parametro -File non esiste`

Il path tipico è `C:\SystemOptimizerHub\active\scripts\...` mentre il clone attuale è su `D:\SystemOptimizerHub\active`.

## Causa

Task Utilità di pianificazione creato durante una campagna (es. `NVMe-WriteOffload-PostBootVerify`, trigger **AtStartup**) con `-File` assoluto sulla root hub vecchia. Dopo `robocopy` + delete di `C:\SystemOptimizerHub` il file non c'è più, ma il task resta Enabled. Exit code visto: `4294770688` (`0xFFFD0000`).

`activate-hub-profile.ps1` / `install-suite.ps1` reinstallano monitor e cleanup sulla nuova root, **non** ripuliscono i one-shot di campagna.

## Cosa fare (Safe)

```powershell
cd D:\SystemOptimizerHub\active
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts\audit-startup-integrity.ps1
# revisione JSON: logs\startup-integrity-latest.json

# da sessione Administrator:
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts\audit-startup-integrity.ps1 -Apply
```

In GUI: **Health Scan** → finding `STARTUP-LEGACY-001` → **Scan + Apply Fixes** (livello Safe).

Rollback: `audit-startup-integrity.ps1 -RestoreLatest` (ri-registra l'XML esportato).

## Cosa non fa

Non rimuove Run key vendor (Adobe, VMware, Sophos, Security Health).

## Prevenzione

- `verify-nvme-writeoffload-postboot.ps1` ora si auto-unregister dopo l'esecuzione.
- `activate-hub-profile.ps1` lancia l'apply di startup-integrity quando elevato.
- Non registrare task AtStartup con path `C:\SystemOptimizerHub` hardcoded.

## Riferimenti

- ADR-0002 portable repo layout
- Runbook `docs/runbooks/hub-relocation-d-drive.md`
- Bug 32 in `KB/bugs-fixed.md`
