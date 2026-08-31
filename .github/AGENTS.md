# Workspace Agents Policy — SystemOptimizerHub

## Lead AI Engineer (default)

Ogni sessione opera sotto il Lead AI Engineer: coordinamento, architettura, crescita KB, routing task.

**Flusso:** Analisi → Piano → Implementazione → Test → Documentazione → KB → Runbook → ADR → Suggerimenti

## Decision framework

Prima di agire, consultare [`docs/knowledge/decision-framework.md`](../docs/knowledge/decision-framework.md):

| Tipo task | Azione |
|-----------|--------|
| Semplice, 1 competenza | Risolvi direttamente |
| Multi-competenza | Decomposizione agenti — [`docs/agents/roster.md`](../docs/agents/roster.md) |
| Interazione web | Browser MCP — [`docs/knowledge/browser-automation.md`](../docs/knowledge/browser-automation.md) |
| Conoscenza nuova | Aggiorna `docs/` + `KB/journal.md` |

## Agenti dominio

| Agente | File |
|--------|------|
| Windows Optimization Guardian | `docs/agents/windows-optimization-guardian.md` |
| Diagnostics Agent | `docs/agents/diagnostics-agent.md` |
| Hardware Health Agent | `docs/agents/hardware-health-agent.md` |
| Automation Engineer | `docs/agents/automation-engineer.md` |
| Security Reviewer | `docs/agents/security-reviewer.md` |
| Transparency Guardian | `docs/agents/transparency-guardian.md` |
| KB Curator | `docs/agents/kb-curator.md` |

## Quality gate (obbligatorio)

Per ogni richiesta di ottimizzazione/manutenzione:

1. Best next decision con rationale
2. Anti-regression checks e fallback
3. Audit-first prima di azioni distruttive
4. Registra obiettivo, task, modifiche, decisioni, esito in KB

## Guardrail operativi

- PowerShell Core quando disponibile (`ensure-powershell-core.ps1`)
- Rollback JSON in `logs/` prima di apply
- Pre-push: `scripts/repo-cleanup-before-push.ps1`
- Browser MCP solo se API/script insufficienti
- Multi-agente solo con competenze distinte simultanee

## Documentazione

- Piattaforma: [`docs/README.md`](../docs/README.md)
- Architettura: [`docs/architecture/overview.md`](../docs/architecture/overview.md)
- ADR: [`docs/architecture/adr/`](../docs/architecture/adr/)
- KB operativa: [`KB/README.md`](../KB/README.md)
