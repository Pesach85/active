# SystemOptimizerHub — Documentazione Piattaforma

Piattaforma di manutenzione intelligente per Windows: automazioni, monitoraggio, diagnostica e knowledge base persistente.

## Navigazione rapida

| Area | Percorso | Contenuto |
|------|----------|-----------|
| Architettura | [architecture/overview.md](architecture/overview.md) | Componenti, flussi, pattern |
| Decisioni (ADR) | [architecture/adr/](architecture/adr/) | Architecture Decision Records |
| Knowledge | [knowledge/](knowledge/) | Framework decisionale, orchestrazione agenti |
| Agenti | [agents/roster.md](agents/roster.md) | Roster specializzato dominio manutenzione |
| Runbook | [runbooks/](runbooks/) | Procedure operative ripetibili |
| Playbook | [playbooks/](playbooks/) | Scenari multi-step con decomposizione |
| Checklist | [checklists/](checklists/) | Gate di qualità e completamento |
| Template | [templates/](templates/) | Modelli ADR, runbook, playbook |
| Hardware | [hardware/](hardware/) | Inventario, WHEA, memoria, NVMe |
| Software | [software/](software/) | Stack, servizi, applicazioni |
| Manutenzione | [maintenance/](maintenance/) | Cicli, campagne, rollback |
| Automazione | [automation/](automation/) | Script, task schedulati, MCP |
| Monitoraggio | [monitoring/](monitoring/) | KPI, soglie, alert |
| Sicurezza | [security/](security/) | Policy dati sensibili, audit |
| Troubleshooting | [troubleshooting/](troubleshooting/) | Problemi noti e fix |
| Lessons learned | [lessons-learned/](lessons-learned/) | Retrospettive e insight |
| History | [history/](history/) | Cronologia eventi significativi |

## KB operativa (legacy + journal)

La KB operativa giornaliera resta in [`../KB/`](../KB/):

- `journal.md` — storico decisionale (generato da `scripts/kb-add-entry.ps1`)
- `task-board.md` — stato task correnti
- `architecture.md` — architettura tecnica script/GUI (riferimento storico; overview aggiornata in `docs/architecture/`)

## Flusso operativo standard

```
Analisi → Piano → Implementazione → Test → Documentazione → KB → Runbook → ADR → Suggerimenti futuri
```

## Multi-piattaforma

- Entry point repo: [`../README.md`](../README.md)
- Setup clone su macchine nuove: [`automation/cross-platform-setup.md`](automation/cross-platform-setup.md)
- ADR layout portabile: [`architecture/adr/0002-portable-repo-layout.md`](architecture/adr/0002-portable-repo-layout.md)

## Regole

1. Ogni scoperta va persistita — mai solo in chat.
2. Ogni procedura ripetibile diventa runbook.
3. Ogni decisione architetturale diventa ADR.
4. Preferire API/script locali; browser MCP solo quando necessario.
5. Multi-agente solo per task con competenze distinte simultanee.
