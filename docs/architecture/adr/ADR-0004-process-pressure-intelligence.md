# ADR-0004: Process Pressure Intelligence Engine

## Status

Accepted (2026-08-28)

## Context

The hub needed deterministic detection of resource-heavy processes beyond advisory compute scoring, with:

- Vital/security process preservation
- Catalog-enriched research (known apps, online references)
- Safe automatic remediation vs human-in-the-loop (HITL) paths
- Cross-platform packaging (Windows primary, Linux analyzer)

## Decision

Introduce **Process Pressure Intelligence (PPI)** as a layered stack:

1. **Catalog** (`config/process-intelligence.json`) — shared knowledge
2. **Core library** (`scripts/lib/process-pressure-core.ps1`) — scoring + classification
3. **Analyze** (`analyze-process-pressure.ps1`) — `ProcessPressureReport.v1`
4. **Apply** (`apply-process-pressure-safe.ps1`) — audit-first, rollback JSON, Safe level only by default
5. **Legacy wrapper** (`analyze-compute-resources.ps1`) — unchanged consumer contract
6. **Linux** — bash analyzer + `package-linux-suite.ps1`

GUI Compute action switches to the full engine in v3.3.0.

## Consequences

### Positive

- Deterministic, testable scoring pipeline
- Explicit Keep/Tune/Review gates before OS mutation
- Smoke gate validates report schema
- Shared catalog extensible without code changes

### Negative / limits

- Linux apply not automated yet (analyze-only)
- IO metrics on Windows depend on process IO counters availability
- Online research is catalog/static links, not live web fetch (by design for reliability)

## Alternatives considered

- Extend `monitor-resources.ps1` only — rejected; conflates continuous throttle with on-demand audit
- Live web scraping per process — rejected; flaky, privacy/security concerns
