# Orchestrazione Multi-Agente

Pattern assimilato da [agency-agents](https://github.com/msitarzewski/agency-agents): **agenti specializzati con responsabilità chiare**, non prompt generici.

## Principi (adattati a SystemOptimizerHub)

1. **Specializzazione dominio** — agenti per manutenzione Windows, non per marketing/design
2. **Deliverable espliciti** — ogni agente produce output definito (log, script, doc, checklist)
3. **Handoff strutturato** — output agente A = input agente B
4. **Lead coordina** — non implementa tutto; decompone e integra
5. **Parallelismo quando indipendente** — analisi + security review in parallelo

## Pattern di decomposizione

### Pattern A: Fix con rollback

```
Diagnostics Agent → analisi root cause, log, metriche
        ↓
Automation Engineer → script + rollback JSON
        ↓
Security Reviewer → guardrail, permessi, dati sensibili
        ↓
KB Curator → runbook + journal entry
```

### Pattern B: Nuova feature GUI

```
Windows Optimization Guardian → requisiti + anti-regression
        ↓
Automation Engineer → worker async + JSON handoff
        ↓
(dopo merge) KB Curator → architecture update + pattern doc
```

### Pattern C: Incident hardware

```
Hardware Health Agent → WHEA, memoria, NVMe, termiche
        ↓
Diagnostics Agent → correlazione event log
        ↓
Automation Engineer → mitigazione scriptata
        ↓
KB Curator → troubleshooting page + lessons learned
```

## Implementazione in Cursor

| Meccanismo | Uso |
|------------|-----|
| Task tool (`subagent_type`) | Esplorazione codebase, shell, review parallela |
| Agent files `docs/agents/*.md` | Istruzioni ruolo per sessioni dedicate |
| `.github/AGENTS.md` | Policy workspace default |
| Skills Cursor | Procedure MCP browser, domini PLC (altri progetti) |

## Anti-pattern

- Multi-agente per task a 1 step
- Agente "generico" senza deliverable
- Orchestrazione senza handoff documentato
- Duplicare roster agency-agents nel repo (126 agenti non pertinenti)

## Riferimenti

- [agents/roster.md](../agents/roster.md)
- [decision-framework.md](decision-framework.md)
