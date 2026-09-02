# KB Operativa - System Optimization

Knowledge base operativa giornaliera. La conoscenza strutturata permanente vive in [`../docs/`](../docs/).

## Struttura

| Percorso | Ruolo |
|----------|-------|
| `journal.md` | Storico cronologico decisioni (auto via script) |
| `task-board.md` | Stato task correnti (ToDo/In Progress/Done) |
| `architecture.md` | Architettura tecnica script/GUI/pattern stabilità |
| `hub-hitl-paths-decision.md` | **Phase 3 HITL:** resolve apply, defender apply, HUB_USE_CORE — pro/contro e matrice decisionale |
| `network-deep-scan-design.md` | **Phase 5:** multi-layer network deep scan (cross-diff, UDP, DNS, Tor heuristics, memory forensics) |
| `multi-platform-install-decision.md` | **Install:** Windows dev-sync, Linux user install, Android WebView MVP |
| `../docs/checklists/hub-quality-gate-validation.md` | **Checklist deterministica** quality gate completo |
| `codebase-health.md` | Snapshot salute codice + voti per area |
| `bugs-fixed.md` | Incident risolti e check anti-regressione |
| `templates/entry-template.md` | Template entry journal manuale |
| `../docs/` | Runbook, ADR, agenti, troubleshooting, checklists |
| `../docs/product/REFACTORING-PLAN-ELITE.md` | Piano operativo refactor onde validate |

## Mappa docs/ (knowledge permanente)

| Area docs/ | Contenuto |
|------------|-----------|
| `architecture/` | Overview piattaforma + ADR |
| `knowledge/` | Decision framework, orchestrazione, browser MCP |
| `agents/` | Roster agenti dominio manutenzione Windows |
| `runbooks/` | Procedure operative |
| `playbooks/` | Scenari multi-step |
| `troubleshooting/` | Problemi noti e fix |
| `lessons-learned/` | Retrospettive |
| `hardware/` | Note hardware |
| `software/` | Stack software |
| `maintenance/` | Campagne manutenzione |
| `automation/` | Automazioni e MCP |
| `monitoring/` | KPI e soglie |
| `security/` | Policy sicurezza |
| `checklists/` | Gate qualità |
| `history/` | Eventi significativi |

## Regola operativa

Per ogni attività, registrare SEMPRE una entry nel journal con:

1. Obiettivo
2. Task
3. Modifiche
4. Decisioni
5. Esito

## Registrazione rapida

Dalla root del repo clonato (qualsiasi path):

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/kb-add-entry.ps1 `
  -Objective "..." `
  -Task "..." `
  -Changes @("modifica1","modifica2") `
  -Decisions @("decisione1") `
  -Outcome "Completato"
```

`-KbRoot` è opzionale (default: `<repo>/KB`).

## Regola repository (cleanup pre-push)

```powershell
git config core.hooksPath .githooks
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/repo-cleanup-before-push.ps1 -Apply
```
