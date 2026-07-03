# Manutenzione

Campagne, cicli e rollback Windows/router.

## Campagne documentate

- [`KB/wave1-4-campaign-summary.md`](../../KB/wave1-4-campaign-summary.md) — hardware stability waves
- [`KB/resource-pressure-playbook.md`](../../KB/resource-pressure-playbook.md) — startup I/O tuning
- [`KB/dd-wrt-hotspot-playbook.md`](../../KB/dd-wrt-hotspot-playbook.md) — router permanent tuning
- [`script-audit-2026-07-03.md`](script-audit-2026-07-03.md) — audit script + GUI config

## Pattern comune

1. Audit → Apply con rollback JSON → Post-reboot verify
2. Entry KB journal
3. Runbook se procedura ripetibile
