# ADR-0005: Local LLM (Ollama) Advisory Layer for Continuous Optimization

## Status

Proposed (2026-08-29)

## Context

SystemOptimizerHub has deterministic engines (PPI, health audit, monitor, orchestrator) and a growing KB. Users want **continuous** RAM/CPU/disk optimization. A local Ollama install and system KB suggest using a lightweight LLM to maintain performance.

Industry pattern: metrics + policy engine + optional AI copilot. AI copilots that **directly mutate OS state** without gates fail in production (hallucinated commands, security regressions, non-reproducible outcomes).

## Decision

Introduce a **Tier-2 advisory layer** only:

1. **Sensors (Tier 0–1)** remain 100% deterministic — existing scripts, JSON schemas, smoke gates.
2. **Ollama** receives `OptimizationContext.v1` (bounded JSON) and returns `OptimizationAdvisory.v1` with **actionId references** to existing scripts — never raw shell.
3. **Apply (Tier 3)** unchanged: Safe auto only where already gated; Keep/HITL/Defender ladder preserved.
4. **KB loop (Tier 4)**: LLM may draft journal/catalog entries; human or PR-style approve before merge.

Default: **LLM disabled** (`LlmAdvisory.Enabled=false`). Offline hub behavior identical.

## Model strategy

> Resource sizing: [`KB/continuous-optimization-resource-budget.md`](../../../KB/continuous-optimization-resource-budget.md)

| Host tier | Profile | LLM default |
|-----------|---------|-------------|
| C (≤16GB / low free RAM / C: <10%) | feather | **Off** — deterministic only |
| B (17–24GB) | light | `qwen2.5:0.5b-instruct`, `keep_alive=0` |
| A (≥24GB) | standard | `qwen2.5:1.5b-instruct`, gated by free RAM ≥6GB |

Never load 3B+ on Tier C. Ollama on-demand only; hub always-on budget <80 MB RAM.

## Consequences

### Positive

- Natural-language explanations for operators (low cognitive load UX)
- Semantic recall from KB/journal (Phase 2 RAG)
- Faster triage of multi-signal incidents (health + PPI + disk)

### Negative

- Additional moving part (Ollama service health)
- Non-deterministic rationales — must not drive auto-apply without actionId whitelist
- GPU/CPU contention if model runs during heavy workload

## Alternatives considered

| Alternative | Rejected because |
|-------------|------------------|
| LLM as sole optimizer | Non-reproducible; violates audit-first |
| Cloud LLM API | Privacy, latency, offline requirement |
| Live web scrape per process | ADR-0004 — flaky, blocked |
| Expand monitor-only throttle | No semantic context; no KB learning |

## Implementation phases

See `KB/continuous-optimization-ollama-plan.md` — Fase 0 (deterministic loop) before Fase 1 (Ollama).

## Compliance with existing ADRs

- ADR-0001: Extends platform with advisory agent; actuators unchanged
- ADR-0004: PPI remains deterministic; LLM does not replace scoring
