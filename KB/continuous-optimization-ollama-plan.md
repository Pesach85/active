# Continuous Optimization — Piano operativo (Deterministic + Ollama advisory)

## Obiettivo

Mantenere **costantemente** RAM, CPU e disco/I/O in regime ottimale su host Windows/Linux, con:

- **Attuatori deterministici** (già nel hub) per azioni reversibili e misurabili
- **Layer LLM locale ultra-leggero** (Ollama) solo per **sintesi, prioritizzazione e arricchimento KB** — mai come unico motore di mutazione OS

## Principio elite (validato in produzione SRE)

| Layer | Ruolo | Affidabilità |
|-------|--------|--------------|
| **Sensori** | Metriche + snapshot JSON | 100% deterministico |
| **Regole/Catalogo** | Soglie, Keep/Tune/Review, rollback | 100% deterministico |
| **Attuatori Safe** | throttle, cleanup, esclusioni HITL | Audit-first + rollback |
| **LLM advisory** | spiega, ranka, propone patch catalogo | Probabilistico → HITL |
| **LLM actuator** | ❌ vietato in v1 | — |

Pattern industry: **eBPF/metrics + policy engine + human/automation gate**. L'LLM sostituisce il "runbook reader" esperto, non il kernel.

## Stato attuale hub (baseline)

| Componente | Funzione continua | Gap |
|------------|-------------------|-----|
| `monitor-resources.ps1` | Loop 20s, throttle BelowNormal | Non usa catalogo PPI; reattivo |
| `hub-orchestrator.ps1` | Heartbeat, WHEA, fs-integrity | Non triggera PPI/cleanup |
| PPI v3.5 | Audit pressione processi | On-demand; research statica |
| `sys-maintenance.json` | Config centralizzata | No blocco `LlmAdvisory` |
| KB + `process-intelligence.json` | Conoscenza host/app | No write-back automatico |

## Architettura target — "Optimization Control Plane"

```
┌──────────────────────────────────────────────────────────────┐
│  Tier 0 — Always-on (zero LLM)                                │
│  monitor-resources │ hub-orchestrator (heartbeat 5m)          │
└────────────────────────────┬─────────────────────────────────┘
                             │ trigger se soglia / ciclo
┌────────────────────────────▼─────────────────────────────────┐
│  Tier 1 — Deterministic engines (JSON schemas)                │
│  analyze-process-pressure │ garbage-hotspots │ health-audit   │
│  fs-integrity │ privacy-scan (read-only)                      │
└────────────────────────────┬─────────────────────────────────┘
                             │ bundle → OptimizationContext.v1
┌────────────────────────────▼─────────────────────────────────┐
│  Tier 2 — Ollama advisory (opzionale, timeout 20s, keep_alive=0) │
│  llm-advise.ps1 → OptimizationAdvisory.v1                         │
│  Modelli: 0.5B (Tier B) / 1.5B (Tier A); **Off su Tier C**        │
└────────────────────────────┬─────────────────────────────────┘
                             │ rank + rationale (no OS mutate)
┌────────────────────────────▼─────────────────────────────────┐
│  Tier 3 — Apply gate                                          │
│  Auto: Safe throttle, cleanup Safe, PKG Safe                  │
│  HITL: Defender, Moderate+, wbadmin, servizi Keep             │
└────────────────────────────┬─────────────────────────────────┘
                             │
┌────────────────────────────▼─────────────────────────────────┐
│  Tier 4 — KB loop                                             │
│  journal │ catalog diff (human approve) │ host playbook       │
└──────────────────────────────────────────────────────────────┘
```

## Schema JSON proposto — `OptimizationContext.v1`

Input unificato per LLM (max ~8KB token budget):

```json
{
  "SchemaVersion": "OptimizationContext.v1",
  "GeneratedAt": "2026-08-29T11:00:00",
  "Host": { "LogicalProcessors": 8, "TotalRamGb": 16 },
  "Signals": {
    "ProcessPressure": "logs/process-pressure-latest.json",
    "HealthSummary": { "Critical": 0, "Important": 2 },
    "MonitorLastViolations": [],
    "DiskFreePercent": { "C": 22, "D": 41 },
    "OrchestratorHeartbeat": "logs/hub-orchestrator-heartbeat.json"
  },
  "CatalogExcerpt": ["MsMpEng", "chrome", "OneDrive"],
  "RecentJournalHeadlines": ["Bug 30 wbadmin", "PPI v3.5"]
}
```

Output — `OptimizationAdvisory.v1`:

```json
{
  "SchemaVersion": "OptimizationAdvisory.v1",
  "Model": "qwen2.5:3b",
  "TopActions": [
    { "Priority": 1, "ActionId": "ppi-safe-throttle", "Confidence": 0.82, "Rationale": "...", "RequiresHitl": false },
    { "Priority": 2, "ActionId": "garbage-quick-clean", "Confidence": 0.71, "Rationale": "...", "RequiresHitl": false }
  ],
  "DoNotDo": ["defender-disable without tier eval"],
  "KbDraft": "One-line lesson for journal"
}
```

### Modelli Ollama consigliati (host consumer)

> **Budget RAM:** vedi [`KB/continuous-optimization-resource-budget.md`](continuous-optimization-resource-budget.md) — su Tier C (≤16GB, es. Inspiron 7577) **LLM disabilitato by default**.

| Ruolo | Modello | RAM inferenza | Tier |
|-------|---------|---------------|------|
| — | — | 0 | C feather |
| Router | `qwen2.5:0.5b-instruct` | ~400–600 MB | B light |
| Synthesizer | `qwen2.5:1.5b-instruct` | ~900 MB | A standard |

**Mai** 3B+ su laptop 16GB. `keep_alive: 0` sempre.

## Piano operativo — 4 fasi (production-grade)

### Fase 0 — Foundation (1–2 settimane, no LLM)

| # | Task | Output |
|---|------|--------|
| 0.1 | Registrare `hub-orchestrator` + `monitor` come scheduled task | Always-on Tier 0 |
| 0.2 | `OptimizationContext` builder script | `logs/optimization-context-latest.json` |
| 0.3 | Orchestrator: ogni N cicli → `analyze-process-pressure` + garbage Quick | JSON fresh |
| 0.4 | `ProcessPressure.AutoApplySafeActions=true` solo throttle | Closed loop Safe |
| 0.5 | Smoke + metriche baseline 24h | `logs/regression-health.json` |

**Gate:** 24h senza regressioni; rollback testato.

### Fase 1 — Ollama advisory read-only (2–3 settimane)

| # | Task | Output |
|---|------|--------|
| 1.1 | `scripts/llm-advise.ps1` — POST `http://127.0.0.1:11434/api/generate` | Advisory JSON |
| 1.2 | Prompt template vincolato (JSON-only, actionId whitelist) | No hallucinated commands |
| 1.3 | Timeout 30s, fallback "deterministic-only" | Resilienza |
| 1.4 | GUI Diagnostics: pannello "AI Advisory" (read-only) | UX basso carico |
| 1.5 | Config `LlmAdvisory` in sys-maintenance.json | Feature flag |

**Gate:** advisory non propone mai azioni fuori whitelist; smoke con Ollama mock/offline.

### Fase 2 — Semantic KB loop (3–4 settimane)

| # | Task | Output |
|---|------|--------|
| 2.1 | Index `KB/journal.md` + playbooks con nomic-embed | SQLite locale |
| 2.2 | RAG: top-3 lezioni passate per segnale simile | Context enrichment |
| 2.3 | `llm-propose-catalog-patch.ps1` → diff JSON catalogo | Human approve → merge |
| 2.4 | Host-specific playbook auto (`KB/hosts/<hostname>.md`) | Memoria macchina |

### Fase 3 — Elite closed loop (4+ settimane)

| # | Task | Output |
|---|------|--------|
| 3.1 | Unified `optimization-controller.ps1` | Single entry orchestration |
| 3.2 | Phase 4 roadmap: startup audit, driver drift | Nuovi sensori |
| 3.3 | Linux parity controller | Cross-platform |
| 3.4 | CI: schema validation + prompt regression tests | Production gate |

## Whitelist actionId (LLM può solo referenziare)

| actionId | Engine | Auto? |
|----------|--------|-------|
| `ppi-safe-throttle` | apply-process-pressure-safe | Sì |
| `garbage-quick-clean` | quick-cleanup-safe | HITL GUI |
| `health-safe-apply` | apply-safe-fixes Safe | Sì (Safe-first) |
| `defender-tune-exclusions` | apply-defender Tier1 | HITL |
| `defender-extreme-review` | evaluate-defender | HITL wizard |
| `observe-only` | — | Sì |

## Guardrail non negoziabili

1. **Keep priority** — LLM output ignorato se contraddice `Priority=Keep`
2. **No raw shell from LLM** — solo actionId → script esistente
3. **Rollback JSON** obbligatorio prima di ogni apply
4. **Rate limit LLM** — max 1 advisory / 15 min unless user triggered
5. **Offline mode** — hub funziona identico senza Ollama

## Metriche successo (SLO host singolo)

| Metrica | Target |
|---------|--------|
| CPU sustained >70% (5 min) | Riduzione 50% vs baseline 7d |
| RAM pressure events | <3/giorno dopo tuning |
| Disk free C: | sempre >15% |
| Time-to-advisory | <45s (incluso PPI 6s) |
| False-positive throttle | 0 su vitali (smoke + catalog) |

## Skill / competenze necessarie

| Skill | Owner agente | Artefact |
|-------|--------------|----------|
| PowerShell orchestration + scheduled tasks | Automation Engineer | controller scripts |
| PPI / deterministic scoring | Windows Optimization Guardian | process-pressure-core |
| Ollama API + prompt JSON schema | Lead AI Engineer | llm-advise.ps1 |
| RAG/embeddings locali | Lead AI Engineer | kb-index.ps1 |
| Security/HITL gates | Security Reviewer | ADR-0005 |
| Smoke/regression | Automation Engineer | test-hub-smoke extension |
| KB curation | KB Curator | journal + host playbooks |

## NBD (Next Best Decision)

**Completato (v3.6.0):** `resource-budget.ps1` + `build-optimization-context.ps1` + orchestrator feather cadence + config Tier C defaults.

**Prossimo:** baseline feather 48h → poi `llm-advise.ps1` solo Tier B+ con `keep_alive=0`.

## Riferimenti interni

- ADR-0004 PPI — deterministic core
- ADR-0005 (draft) — LLM advisory layer
- `KB/process-pressure-intelligence.md`
- `docs/product/ROADMAP.md` Phase 4
