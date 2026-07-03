# Lesson Learned — Migrazione Hub Portabile

**Data:** 2026-07-03  

## Contesto

Hub spostato da `C:\SystemOptimizerHub` a `D:\SystemOptimizerHub` con ADR-0002 (layout portabile).

## Cosa è successo

- Script core già path-agnostic (`activate-hub-profile`, `monitor-resources`)
- Batch launcher e alcuni default legacy ancora su path C:
- `dist/` richiede `package-suite.ps1` dopo ogni sync sorgente

## Root cause documentale

Documentazione (`KB/architecture.md`, task-board) non aggiornata contestualmente al move.

## Azioni

1. `hub-common.ps1` centralizza risoluzione path
2. `sys-maintenance.json` unico file configurazione (monitor, cleanup, WHEA, orchestrator, GUI)
3. GUI tab Config con Save/Reload
4. Runbook relocation + orchestrator + fs-integrity

## Prevenzione

- Ogni relocation → aggiornare runbook, task-board, rieseguire `activate-hub-profile.ps1`
- Non committare path host-specific; usare `LogDirectory: "logs"` relativo
