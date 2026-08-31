# Roster Agenti — SystemOptimizerHub

Agenti dominio-specifici per manutenzione Windows. Ispirati al modello [agency-agents](https://github.com/msitarzewski/agency-agents) ma **non copiati** — adattati a questo repository.

## Roster

| Agente | File | Specialty | Quando attivare |
|--------|------|-----------|-----------------|
| Lead AI Engineer | (system prompt) | Coordinamento, architettura, KB growth | Default — ogni sessione |
| Windows Optimization Guardian | [windows-optimization-guardian.md](windows-optimization-guardian.md) | Ottimizzazione SO, anti-regression, audit-first | Task ottimizzazione/cleanup/monitor |
| Diagnostics Agent | [diagnostics-agent.md](diagnostics-agent.md) | Event Log, WHEA, servizi, correlazione | Root cause, incident |
| Hardware Health Agent | [hardware-health-agent.md](hardware-health-agent.md) | Memoria, NVMe, CPU MCE, termiche | Problemi hardware/firmware |
| Automation Engineer | [automation-engineer.md](automation-engineer.md) | Script PS, task schedulati, rollback JSON | Nuove automazioni, packaging |
| Security Reviewer | [security-reviewer.md](security-reviewer.md) | Secrets, permessi, pre-push, dati sensibili | Prima di commit/push/apply |
| Transparency Guardian | [transparency-guardian.md](transparency-guardian.md) | Postura runtime, T0–T3, control plane, RAM unknown | Monitoraggio attivo, audit cybersecurity |
| KB Curator | [kb-curator.md](kb-curator.md) | Documentazione, runbook, ADR, journal | Dopo ogni task significativo |

## Decomposizione tipica

| Task | Agenti |
|------|--------|
| Nuovo script mitigazione | Diagnostics → Automation → Security → KB Curator |
| Campagna wave/post-reboot | Hardware Health → Guardian → Automation → KB Curator |
| Fix GUI regression | Guardian → Automation → KB Curator |
| Pre-push remoto | Security Reviewer → KB Curator (se policy change) |

## Implementazione Cursor

Per attivare un agente in sessione, caricare il file corrispondente come contesto o istruzione. Il Lead decompone e coordina; non tutti gli agenti servono sempre.

## Estensione futura

Nuovi agenti solo se emerge competenza distinta ripetuta (es. `Network Agent` per WSL/hypervisor se il volume task cresce).
