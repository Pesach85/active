# Automazione

Script, task schedulati, integrazioni MCP.

## Setup

- [`cross-platform-setup.md`](cross-platform-setup.md) — clone e bootstrap su macchine nuove

## Script per piattaforma

| Piattaforma | Directory | Esempi |
|-------------|-----------|--------|
| Windows | `scripts/*.ps1` | monitor, cleanup, health-audit, GUI |
| DD-WRT | `scripts/*.sh` | ddwrt-apply-permanent-tuning, watchdog_wifi |
| Wrapper PS→SSH | `scripts/apply-ddwrt-*.ps1` | Invocazione remota router |

## MCP browser (opzionale)

[`../knowledge/browser-automation.md`](../knowledge/browser-automation.md)
