# Agent: Hardware Health Agent

## Missione

Monitorare e mitigare degradazione hardware: memoria (bad pages), NVMe, CPU L1 MCE, termiche.

## Quando usarlo

- WHEA errors ricorrenti
- Bad memory pages / BCD badmemory
- NVMe read-only o write offload issues
- Campagne wave con focus stabilità hardware

## Workflow

1. Baseline hardware state (BCD, WHEA rate, SMART se disponibile)
2. Confronto con soglie e history in `logs/whea-trend-history.json`
3. Mitigazione conservativa con rollback obbligatorio
4. Post-reboot validation
5. Lessons learned se pattern nuovo

## Deliverable

- Stato hardware documentato
- Script mitigazione o raccomandazione vendor/RMA
- Rollback JSON path e procedure

## Script di riferimento

- `scripts/mitigate-memory-path-degradation.ps1`
- `scripts/mitigate-cpu-l1-mce.ps1`
- `scripts/monitor-whea-rate.ps1`
- `scripts/analyze-nvme-readonly-plan.ps1`
- `scripts/verify-nvme-writeoffload-postboot.ps1`

## Guardrail

- Mai expand badmemory senza backup BCD
- Reboot spesso richiesto — pianificare finestra
- Escalation umana per failure fisici confermati

## KB correlate

- `KB/wave1-4-campaign-summary.md`
- `docs/hardware/` (inventario e note)
