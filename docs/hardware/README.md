# Hardware

Inventario, note WHEA, memoria, NVMe, termiche.

Documentazione correlata:

- Agent: [`../agents/hardware-health-agent.md`](../agents/hardware-health-agent.md)
- KB campagne: [`../../KB/wave1-4-campaign-summary.md`](../../KB/wave1-4-campaign-summary.md)
- Log rollback: `logs/*-rollback*.json`

## Ledger campagne WHEA / memoria

| Data | Fase | Artifact / nota |
|------|------|-----------------|
| 2026-10-07 | FASE 0 baseline dual-channel (read-only) | [`../../artifacts/whea-dualchannel-20261007/00_baseline.md`](../../artifacts/whea-dualchannel-20261007/00_baseline.md) — 2× Hynix 16 GB @2400, badmemorylist 722 PFN invariata, WinSAT mean 26.74 GB/s, Secure Boot OFF; CPU-Z Dual Channel confermato |
| 2026-10-07 | FASE 1 forensics WHEA (read-only) | [`../../artifacts/whea-dualchannel-20261007/01_summary.md`](../../artifacts/whea-dualchannel-20261007/01_summary.md) — periodi (a)/(b)/(c); ID20 live NON CONCLUSIVO; Errors Retain pieno 2026-05-12; H3 ritirata → H3′ |
