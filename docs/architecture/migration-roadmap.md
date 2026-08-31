# Migration Roadmap — PowerShell → C# Core

**Strategy:** Strangler fig. Each phase delivers user-visible value, passes smoke + parity, updates KB. PowerShell remains fallback until gate passes.

## Phase 0 — Foundation (2026-08, **DONE**)

- [x] ADR-0007 decision (C# over Python)
- [x] Solution scaffold `src/SystemOptimizerHub.sln`
- [x] Core: catalog load, necessity resolve, action block, pressure score
- [x] Windows + Linux platform stubs
- [x] `hub` CLI preview
- [x] xUnit tests (5 passing)
- [x] Linux package version **0.2.0**

**Validation:** `dotnet test` + existing PS smoke unchanged.

## Phase 1 — Read-only parity (Q4 2026)

Port read-only analyzers; PS calls Core via CLI or embedded DLL.

| Domain | PS script | Core module | Parity test |
|--------|-----------|-------------|-------------|
| PPI analyze | `analyze-process-pressure.ps1` | `ProcessPressureAnalyzer` | JSON diff vs golden |
| Advisory | `resolve-unknown-process.ps1 -Action Advisory` | `ResolutionAdvisoryService` | Field-by-field |
| Transparency report | `build-transparency-report.ps1` | `TransparencyReportBuilder` | Schema + posture score |

Deliverable: `hub analyze pressure`, `hub transparency report` producing identical JSON.

## Phase 2 — Mutating actions with HITL (Q1 2027)

| Domain | Notes |
|--------|-------|
| Identify + catalog merge | Password gate port from `operator-auth.ps1` |
| Resolve actions | Observe, throttle, terminate with rollback JSON |
| Linux renice apply | Replace bash apply with Core.Linux |
| Defender evaluate/apply | Windows-only adapter |

Deliverable: Web dashboard calls ASP.NET API (Phase 3 prep); PS scripts become 10-line wrappers.

## Phase 3 — Web control plane (Q2 2027)

- ASP.NET Core Minimal API replaces `HttpListener` in `serve-transparency-dashboard.ps1`
- Static `web/transparency/` unchanged initially
- Operator auth: Windows integrated + password gate parity

## Phase 4 — Desktop (Q3 2027)

- Avalonia UI replaces WinForms monolith (`system-optimizer-gui.ps1`)
- Module tabs ported incrementally (Control/Transparency first)
- Retire ps2exe EXE

## Phase 5 — Decommission PS execution layer (Q4 2027)

- Scheduled tasks invoke `hub orchestrator` not `.ps1`
- Remove `scripts/lib/*.ps1` domains with full parity
- Keep PS only for one-off lab/campaign scripts or remove to `archive/`

## Regression policy (every phase)

1. Run `evaluate-migration-nbd.ps1 -Apply` — gates + scored NBD
2. Run `test-hub-smoke.ps1` — must stay ALL PASSED
3. Run `test-core-parity.ps1` — new domains must PASS
4. Run `test-identify-chain-e2e.ps1` when touching identify/resolve
5. Rollback JSON format unchanged in `logs/`
6. KB journal entry per phase with pattern hints

## What we do NOT migrate

- DD-WRT bash (`ddwrt-*.sh`) — different domain
- One-off hardware lab scripts (`execute-nvme-*`, `mitigate-cpu-lme-*`) — archive or manual
- Git hooks / repo cleanup — stay PS or shell

## Effort estimate

| Phase | Engineering | Risk |
|-------|-------------|------|
| 0 | 1 week | Low |
| 1 | 6–8 weeks | Medium (JSON parity) |
| 2 | 8–10 weeks | High (HITL auth) |
| 3 | 4 weeks | Medium |
| 4 | 12–16 weeks | High (GUI rewrite) |
| 5 | 4 weeks | Low |

Total: ~12–18 months calendar with production PS stack running throughout.
