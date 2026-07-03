# SystemOptimizerHub

Piattaforma di manutenzione intelligente multi-piattaforma: automazioni Windows, tuning router DD-WRT, knowledge base persistente e orchestrazione agenti AI.

## Piattaforme supportate

| Piattaforma | Contenuto | Runtime |
|-------------|-----------|---------|
| **Windows 10/11** | Script PowerShell, GUI WinForms, scheduled tasks | PowerShell 7+ |
| **DD-WRT / Linux (router)** | Shell scripts, NVRAM tuning, WiFi watchdog | bash + SSH |
| **Dev (qualsiasi OS)** | Documentazione, agenti, ADR, KB | Git + editor |

## Quick start

```bash
git clone https://github.com/Pesach85/active.git
cd active
```

### Windows

```powershell
# Dalla root del repo clonato (qualsiasi path)
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/ensure-powershell-core.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/activate-hub-profile.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/system-health-audit.ps1
```

### DD-WRT / router

Vedi [`KB/dd-wrt-hotspot-playbook.md`](KB/dd-wrt-hotspot-playbook.md) e [`docs/automation/cross-platform-setup.md`](docs/automation/cross-platform-setup.md).

## Struttura repository

```
active/
├── docs/           # Knowledge strutturata (agenti, ADR, runbook, framework)
├── KB/             # Journal operativo, playbooks, architecture tecnica
├── scripts/        # Automazioni Windows (.ps1) e router (.sh)
├── config/         # Configurazione sys-maintenance.json
├── logs/           # Runtime (gitignored — rollback, audit live)
├── dist/           # Package WindowsOptimizer
└── .github/        # Agent policy workspace
```

## Documentazione

| Doc | Descrizione |
|-----|-------------|
| [`docs/README.md`](docs/README.md) | Indice piattaforma manutenzione intelligente |
| [`docs/knowledge/decision-framework.md`](docs/knowledge/decision-framework.md) | Quando usare script / multi-agente / browser MCP |
| [`docs/agents/roster.md`](docs/agents/roster.md) | Agenti dominio specializzati |
| [`KB/README.md`](KB/README.md) | KB operativa e journal |
| [`docs/automation/cross-platform-setup.md`](docs/automation/cross-platform-setup.md) | Setup su macchine nuove |

## Regole operative

1. **Audit-first** — osservare prima di modificare
2. **Rollback JSON** — stato in `logs/` prima di ogni apply
3. **KB growth** — ogni task significativo → `docs/` + journal
4. **Pre-push cleanup** — `git config core.hooksPath .githooks`

## Agenti AI (Cursor / Claude)

Policy workspace: [`.github/AGENTS.md`](.github/AGENTS.md)

Flusso: Analisi → Piano → Implementazione → Test → Documentazione → KB → Runbook → ADR

## Licenza e dati sensibili

Vedi [`REPOSITORY-NOTES.md`](REPOSITORY-NOTES.md). Non committare credenziali router (`ddwrtkey/`), journal runtime personale, o log live.
