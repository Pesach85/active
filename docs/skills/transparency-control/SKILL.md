---
name: transparency-control
description: Runtime transparency and shared human+AI control contract for SystemOptimizerHub. Use when auditing RAM/process visibility, building or reviewing TransparencyReport, Control tab GUI, web dashboard, T0-T3 trust levels, or cybersecurity posture on Windows hosts.
---

# Transparency & Control — SystemOptimizerHub

## When to load

- User asks about hidden activity, RAM hogs, monitorability, control plane
- Implementing or debugging Control tab / web dashboard
- Classifying processes T0–T3
- Cybersecurity analysis software+hardware for hub hosts

## Core artifacts

| File | Role |
|------|------|
| `scripts/lib/transparency-policy.ps1` | Agent registry, trust levels, delegation manifest |
| `scripts/build-transparency-report.ps1` | Produces `TransparencyReport.v1` |
| `scripts/serve-transparency-dashboard.ps1` | localhost:8765 read-only web UI |
| `scripts/gui/transparency-panel.ps1` | WinForms tab |
| `KB/transparency-control-plan.md` | Operational plan + cyber analysis |
| ADR-0006 | Architecture decision |

## Control levels (never skip)

| Level | Label | Auto-action |
|-------|-------|-------------|
| T0_Observed | Human / trusted OS | None |
| T1_Delegated | Hub whitelisted agent | Per script Safe gates |
| T2_Review | LLM / terminate | Human approve |
| T3_Unknown | Not classified | **Never** auto-apply |

## Quick commands

```powershell
pwsh -File scripts/build-transparency-report.ps1
pwsh -File scripts/serve-transparency-dashboard.ps1 -BuildReportFirst -OpenBrowser
pwsh -File scripts/test-hub-smoke.ps1
```

## UX principles

- One glance: posture score + unknown high-RAM count
- Three columns web: agents | RAM | recent actions
- Same JSON feeds EXE and web (single source of truth)
- Italian labels in locale; contract text bilingual in KB

## Agent handoff

- **Transparency Guardian** — runtime posture
- **Security Reviewer** — pre-commit secrets
- **Windows Optimization Guardian** — PPI catalog updates for T3
- **Lead AI Engineer** — ADR + KB

## Do not

- Expose dashboard on 0.0.0.0
- Add mutation APIs to web server
- Promote LLM to T1 auto-actuator without new ADR
