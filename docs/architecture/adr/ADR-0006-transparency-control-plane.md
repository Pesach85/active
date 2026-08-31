# ADR-0006: Transparency & Control Plane (Human + AI Shared Contract)

## Status

Accepted (2026-08-31)

## Context

Operators delegate maintenance to SystemOptimizerHub and AI agents. High RAM usage and background activity must never be opaque. Legal and operational requirements demand:

1. No hidden OS mutations outside whitelisted scripts
2. Clear audit trail for human and AI-delegated actions
3. Unknown high-resource processes flagged before any automated response
4. UX that reduces cognitive load while preserving full inspectability

## Decision

Introduce a **Transparency & Control Plane** parallel to the optimization control plane:

| Layer | Component | Role |
|-------|-----------|------|
| Policy | `scripts/lib/transparency-policy.ps1` | Shared T0–T3 control levels + agent registry |
| Sensor | `build-transparency-report.ps1` | `TransparencyReport.v1` JSON |
| Events | `transparency-events.jsonl` | Structured throttle/terminate audit |
| EXE UI | Tab **Controllo** in main GUI | Posture, agents, RAM trust, contract |
| Web UI | `web/transparency/` + `serve-transparency-dashboard.ps1` | localhost read-only dashboard |
| Orchestrator | Builds report each cycle when enabled | Always-fresh posture |

### Control levels (shared contract)

| Level | Meaning | Auto-action |
|-------|---------|-------------|
| **T0_Observed** | Human-initiated or trusted OS/toolchain | None by hub |
| **T1_Delegated** | Whitelisted hub agent, audit required | Safe actions only per script |
| **T2_Review** | Sensitive or LLM — human gate | Block until approved |
| **T3_Unknown** | Not in registry/catalog | **Never** auto-apply; flag operator |

### Security boundaries

- Web dashboard binds **127.0.0.1 only**; no remote access
- Dashboard is **read-only**; no API mutations
- LLM remains advisory-only (ADR-0005); never T1 without explicit future ADR
- `AutoTerminate` on monitor logged as T2_Review events

## Consequences

### Positive

- Operator sees RAM hogs with trust classification instantly
- AI and human share explicit delegation manifest from config
- Posture score drives prioritization (unknown RAM, missing agents, disk pressure)

### Negative

- Additional JSON generation each orchestrator cycle (~1–2s)
- Unknown process classification requires ongoing catalog curation (PPI)

## Compliance

- ADR-0004: PPI catalog feeds T1 trust for known processes
- ADR-0005: LLM gated to T2_Review; off on Tier C
- Security Reviewer: dev-time secrets; Transparency Guardian: runtime posture

## References

- `KB/transparency-control-plan.md`
- `docs/agents/transparency-guardian.md`
- `docs/skills/transparency-control/SKILL.md`
