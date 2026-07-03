# Runbook — Filesystem Integrity Scan

**ID:** RB-FS-001  
**Stato:** Active  
**Ultimo aggiornamento:** 2026-07-03  

## Scopo

Scan-only dell'integrità filesystem: volumi, dirty bit, symlink DataHub, eventi System correlati.

## Esecuzione

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/fs-integrity.ps1
```

Exit code: `0` = OK, `2` = findings presenti.

## Output

`logs/fs-integrity-latest.json` (path configurabile in `FsIntegrity.OutputPath`).

## Quando eseguire

- Prima di cleanup tier-2 su D:
- Dopo relocation hub o modifica symlink DataHub
- Su schedule via `hub-orchestrator.ps1`

## Rollback

N/A (read-only). Risolvere i finding prima di apply distruttivi.
