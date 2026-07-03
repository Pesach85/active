# ADR-0001: Piattaforma di Manutenzione Intelligente

**Stato:** Accettato  
**Data:** 2026-07-03  
**Autore:** Lead AI Engineer

## Contesto

SystemOptimizerHub è un workspace operativo Windows con script PowerShell, GUI WinForms, task schedulati e una KB parziale (`KB/`). L'obiettivo è evolvere il repository in una piattaforma che:

- si documenta autonomamente
- apprende procedure nuove
- orchestra agenti specializzati quando serve
- integra browser automation via MCP solo quando necessario

Concetti assimilati (non copiati) da:

- [agency-agents](https://github.com/msitarzewski/agency-agents) — agenti specializzati con responsabilità, workflow e deliverable chiari; decomposizione per competenza
- [stealth-browser-mcp](https://github.com/vibheksoni/stealth-browser-mcp) — automazione browser modulare via MCP; preferire API/script quando sufficienti

## Decisione

1. **Struttura documentale** in `docs/` con sottodirectory per architecture, knowledge, runbooks, playbooks, agenti, hardware, software, monitoring, security, troubleshooting.
2. **KB operativa** (`KB/journal.md`, `task-board.md`) resta il journal decisionale; `docs/` è la knowledge strutturata e permanente.
3. **Roster agenti dominio-specifico** in `docs/agents/` — non il roster generico di agency-agents, ma 6 ruoli allineati a manutenzione Windows.
4. **Framework decisionale** in `docs/knowledge/decision-framework.md` per routing task: diretto / multi-agente / browser MCP.
5. **Compatibilità** con `.github/AGENTS.md`, `scripts/kb-add-entry.ps1` e guardrail esistenti (audit-first, rollback JSON).

## Conseguenze

### Positive

- Conoscenza persistente e navigabile
- Decisioni tracciabili via ADR
- Onboarding agenti/umani più rapido
- Crescita incrementale senza rewrite del codice esistente

### Negative

- Overhead documentale iniziale
- Richiede disciplina: ogni task deve aggiornare KB/docs

### Neutrali

- `KB/architecture.md` resta come riferimento tecnico script; overview piattaforma in `docs/architecture/overview.md`

## Rollback

Rimuovere `docs/` e ripristinare solo `KB/` + `.github/AGENTS.md` originale. Nessun impatto su script runtime.

## Riferimenti

- `docs/knowledge/decision-framework.md`
- `docs/agents/roster.md`
- `KB/README.md`
