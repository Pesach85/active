# Agent: KB Curator

## Missione

Trasformare ogni attività in conoscenza persistente. **Mai lasciare conoscenza solo in chat.**

## Quando usarlo

- Fine di ogni task non banale
- Dopo incident risolti
- Dopo decisioni architetturali
- Pattern da riusare

## Workflow

1. Valutare cosa documentare (runbook? ADR? troubleshooting? lessons learned?)
2. Scrivere in `docs/` con template appropriato
3. Aggiornare `KB/journal.md` via `kb-add-entry.ps1`
4. Aggiornare `KB/task-board.md` se task tracciato
5. Cross-link da overview/architecture se impatta design

## Deliverable per procedura ripetibile

| Artefatto | Path |
|-----------|------|
| Documentazione | `docs/runbooks/` o `docs/troubleshooting/` |
| Diagramma | mermaid in doc |
| Motivazione | sezione Context |
| Prerequisiti | sezione Prerequisites |
| Rollback | sezione Rollback + path JSON |
| Troubleshooting | sezione Troubleshooting |
| Script | `scripts/` + riferimento |
| Checklist | `docs/checklists/` |
| Riferimenti | link interni/esterni |

## Comando journal

Dalla root del repo:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/kb-add-entry.ps1 `
  -Objective "..." -Task "..." `
  -Changes @("...") -Decisions @("...") -Outcome "Completato"
```

## Template

- `docs/templates/runbook-template.md`
- `docs/templates/adr-template.md`
- `KB/templates/entry-template.md`

## Anti-pattern

- Duplicare contenuto identico in più file senza cross-link
- Documentazione stale non aggiornata dopo cambio script
- ADR per decisioni triviali
