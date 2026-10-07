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
| 2026-10-07 | FASE 1b instrumentation restore (proposed only) | [`../../artifacts/whea-dualchannel-20261007/01b_instrumentation_restore_proposal.md`](../../artifacts/whea-dualchannel-20261007/01b_instrumentation_restore_proposal.md) + `scripts/proposed/*` — STRUMENTO CIECO; wevtutil syntax verified; no exec |
| 2026-10-07 | FASE 2 mapping analysis (read-only) | [`../../artifacts/whea-dualchannel-20261007/02_mapping_analysis.md`](../../artifacts/whea-dualchannel-20261007/02_mapping_analysis.md) — PFN single-ch stantia in dual; 2.82 MB false-confidence risk |
| 2026-10-07 | HITL script gate + soak plan (proposed) | `scripts/proposed/Restore-KernelWheaErrors-HITL.ps1`, `Validate-SoakGate.ps1`, [`04_soak_ab_plan_proposed.md`](../../artifacts/whea-dualchannel-20261007/04_soak_ab_plan_proposed.md) |
| 2026-10-07 | Soak A early eval | Gate PASS; ID20/HWiNFO ≫300; ESCALATION_PROVVISORIA; isolamento 1h×3 proposto; canale circular cieco su 10min |
| 2026-10-07 | FASE 3 MemTest chiusa | [`03_memtest_coverage.md`](../../artifacts/whea-dualchannel-20261007/03_memtest_coverage.md) — MemTest86 PASS su i3-6100U (celle OK; non IMC Inspiron); pass/errori/data NON MISURATO accettati |
