# ADR-0007: Cross-Platform C# Core (Migration from PowerShell)

## Status

**Proposed → Phase 0 accepted** (2026-08-31)

## Context

SystemOptimizerHub today is ~30k LOC PowerShell with:

- WinForms GUI + ps2exe EXE (Windows PowerShell 5.1 parser fragility)
- ~97 scripts, deep Windows coupling (Defender, registry, BCD, Task Scheduler, P/Invoke forensics)
- JSON schema contracts (`ProcessPressureReport.v1`, `ProcessResolutionResult.v1`, transparency reports) already portable
- Linux: 2 bash PPI scripts + shared catalog (ADR-0004 analyze-only)
- Recurring PS pitfalls: Unicode parsing, `$PID`, StrictMode, encoding, HttpListener ad-hoc server

Goal: **one deterministic core**, platform adapters, gradual migration **without regression**.

## Decision: C# (.NET 9) — not Python

| Criterion | C# (.NET 9) | Python 3 |
|-----------|-------------|----------|
| Windows native APIs (WMI, registry, Defender, services) | First-class via BCL + targeted packages | pywin32 — fragile, version-sensitive |
| Single language for Core + Windows + Linux hosts | Yes | Yes, but weaker on Windows system layer |
| GUI cross-platform | Avalonia (Phase 4) | PyQt — heavy packaging |
| Web dashboard | ASP.NET Core Minimal API | FastAPI — good but second stack |
| Deploy | Native AOT / single-file `hub` CLI | PyInstaller — AV false positives, size |
| Type safety vs JSON schemas | Strong | Runtime-only |
| Team pain already hit | PS parser/encoding | New packaging class of issues |
| Linux `/proc` | Custom adapter in Core.Linux | Natural (psutil) — **only clear Python win** |

**Verdict:** C# for unified core. Linux `/proc` reads are straightforward in .NET; Python does not outweigh Windows-first production requirements.

## Architecture: Hexagonal (Ports & Adapters)

```
                    ┌─────────────────────────────────────┐
                    │         SystemOptimizerHub.Core      │
                    │  Catalog, PPI scoring, Transparency  │
                    │  Policy T0-T3, Resolution advisory   │
                    │  (pure, unit-tested, no OS calls)    │
                    └─────────────────┬───────────────────┘
                                      │ interfaces
              ┌───────────────────────┼───────────────────────┐
              ▼                       ▼                       ▼
   SystemOptimizerHub.Abstractions   │              (future Web/Desktop)
   IProcessSnapshotProvider           │
   IProcessMutator                    │
   IRegistryStore / IDefenderPolicy  │  (Phase 2+ ports)
              │                       │
     ┌────────┴────────┐     ┌───────┴────────┐
     ▼                 ▼     ▼                ▼
 .Windows          .Linux   .Cli host    ASP.NET Core (Phase 3)
 WMI/Registry     /proc    `hub` cmd    transparency API
 Defender          renice
 TaskScheduler
```

### Repository layout (Phase 0 — created)

```
src/
  SystemOptimizerHub.sln
  SystemOptimizerHub.Core/           # Domain + JSON catalog (NO OS)
  SystemOptimizerHub.Abstractions/ # Ports
  SystemOptimizerHub.Windows/      # Windows adapters
  SystemOptimizerHub.Linux/          # Linux adapters
  SystemOptimizerHub.Cli/            # Cross-platform entry: `hub`
tests/
  SystemOptimizerHub.Core.Tests/   # xUnit parity unit tests
```

PowerShell scripts remain **authoritative for production** until each domain passes the **Parity Gate** (see migration roadmap).

## Versioning

| Track | Version | Meaning |
|-------|---------|---------|
| Windows PS/GUI | 3.11.x | Current production stack |
| Hub Core / CLI | **0.2.0** | Migration preview (catalog + scoring parity) |
| Linux package | **0.2.0** | Bash PPI + shared catalog; CLI preview on Linux |

## Consequences

### Positive

- Eliminates PS 5.1 parser class of bugs for migrated modules
- One testable core; JSON contracts unchanged → no KB/config regression
- `hub` CLI works on Windows and Linux today for catalog classify
- Clear path to Avalonia GUI + ASP.NET dashboard

### Negative / accepted

- Dual stack during migration (PS + C#) — mitigated by parity tests
- Large rewrite (~18–24 months phased) — **not big-bang**
- Lab/campaign scripts (~30) may stay PS or be retired

## Alternatives rejected

1. **Python-only rewrite** — weak Windows system integration
2. **Rust core** — excellent but steeper GUI/web ergonomics for this team
3. **Keep PS forever** — proven ceiling (encoding, EXE, cross-platform)
4. **Big-bang rewrite** — violates audit-first / no-regression policy

## References

- ADR-0004 PPI shared catalog
- ADR-0006 Transparency control plane
- `docs/architecture/cross-platform-core.md`
- `docs/architecture/migration-roadmap.md`
