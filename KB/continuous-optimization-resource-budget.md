# Resource Budget — Continuous Optimization (ultra-light)

## Host di riferimento (questo PC)

| Risorsa | Valore | Implicazione |
|---------|--------|--------------|
| Modello | Dell Inspiron 7577 | Laptop, termica/ RAM limitata |
| CPU | i7-7700HQ, 4C/8T @ 2.8GHz | PPI ok; evitare loop aggressivi |
| RAM | 16 GB, **single channel** | ~15.9 GB usable; Ollama 3B ≈ 25% RAM totale |
| OS disk C: | NVMe 256GB | Spesso sotto pressione (snapshot: **1.7% free**) |
| Data D: | HDD 2TB | I/O random lento — evitare scan profondi frequenti |

**Conclusione:** su questo host un copilota LLM **residente** è un controsenso. Budget target hub always-on: **< 80 MB RAM** totali (monitor + orchestrator), picchi audit **< 150 MB** ephemeral.

---

## Budget RAM per componente (misurato / stimato)

| Componente | Modalità | RAM tipica | CPU | Note |
|------------|----------|------------|-----|------|
| `monitor-resources.ps1` | loop 20s, Get-Process all | 40–80 MB | spike ogni 20s | **Più pesante del necessario** |
| `monitor-resources.ps1` | loop **60s**, feather | 35–55 MB | basso | Profile consigliato 7577 |
| `hub-orchestrator.ps1` | ciclo 300s | 30–50 MB peak | burst ogni 5m | fs-integrity/WHEA costosi |
| `hub-orchestrator.ps1` | ciclo **600s**, feather | raro peak | minimo | Consigliato |
| `analyze-process-pressure` | 4s, Top 5 | +50–100 MB **solo durante run** | 2–5s | Processo figlio, poi exit |
| `build-optimization-context` | read JSON only | **< 15 MB** | <1s | NBD core |
| `llm-advise` (0.5B, keep_alive=0) | on-demand 20s | **+400–700 MB** durante inferenza | burst | **Solo se RAM libera ≥ 6 GB** |
| `llm-advise` (3B) | on-demand | +2.5–4 GB | ❌ | **Vietato su Tier C (≤16GB)** |
| GUI EXE | aperta | 50–90 MB | — | Opzionale; non always-on |
| Ollama daemon | idle no model | ~200–400 MB | — | Accettabile solo se non carica modello |

---

## Tier host automatico (portable)

`Get-HostResourceTier` in `scripts/lib/resource-budget.ps1`:

| Tier | Condizione | Profile default | LLM |
|------|------------|-----------------|-----|
| **C — Feather** | RAM ≤ 16 GB **or** free RAM < 4 GB **or** C: free < 10% | feather | **Off** |
| **B — Light** | RAM 17–24 GB, free ≥ 4 GB | light | 0.5B on-demand, keep_alive=0 |
| **A — Standard** | RAM ≥ 24 GB, free ≥ 6 GB | standard | 1.5B–3B on-demand, gated |

Questo PC → **Tier C / feather** sempre, salvo RAM libera eccezionale (>6 GB) + CPU idle.

---

## Profile config (`ContinuousOptimization.Profiles`)

### feather (default Tier C — 7577)

```json
{
  "MonitorLoopIntervalSec": 60,
  "OrchestratorIntervalSec": 600,
  "PpiEveryOrchestratorCycles": 12,
  "PpiDurationSec": 3,
  "PpiTop": 5,
  "RunFsIntegrityEveryNCycles": 6,
  "RunWheaEveryNCycles": 2,
  "AutoApplySafeThrottle": false
}
```

- PPI ~ ogni **12 × 10 min = 2 ore** (non ogni heartbeat)
- Monitor ogni **60s** (non 20s)
- Nessun LLM in automatico

### light (Tier B)

- Monitor 45s, orchestrator 300s, PPI ogni 6 cicli, LLM 0.5B solo manuale/GUI

### standard (Tier A workstation)

- Monitor 30s, orchestrator 300s, PPI ogni 3 cicli, LLM 1.5B gated

---

## Ollama — impostazioni minime assolute

### Variabili ambiente (sistema o user)

```text
OLLAMA_NUM_PARALLEL=1
OLLAMA_MAX_LOADED_MODELS=1
OLLAMA_KEEP_ALIVE=0
```

### API request (llm-advise.ps1)

```json
{
  "model": "qwen2.5:0.5b-instruct",
  "keep_alive": 0,
  "options": {
    "num_ctx": 2048,
    "num_predict": 256,
    "temperature": 0.1
  }
}
```

### Modelli per tier (quantized Q4_K_M)

| Tier | Modello | RAM inferenza | Uso |
|------|---------|---------------|-----|
| C | — | 0 | Deterministico only |
| B | `qwen2.5:0.5b-instruct` | ~400–600 MB | 1 advisory / richiesta |
| A | `qwen2.5:1.5b-instruct` | ~900 MB–1.2 GB | Advisory + KB draft |

**Mai** caricare 7B su laptop ≤16 GB.

### Gate pre-inferenza (obbligatori)

1. `Get-CimInstance Win32_OperatingSystem`.FreePhysicalMemory ≥ `MinFreeRamMbForLlm` (default 6144)
2. CPU media ultimi 60s < `IdleCpuThreshold` (default 45%)
3. Nessun processo PPI Top con Score ≥ 70 MemoryHeavy
4. `LlmAdvisory.Enabled = true` (default **false**)
5. Utente ha cliccato "AI Advisory" **or** orchestrator flag `LlmOnIdleOnly` + night window

---

## Anti-pattern (vietati)

| Pattern | Perché |
|---------|--------|
| Ollama always-on con 3B+ | Ruba 15–25% RAM su 16GB |
| `keep_alive: 5m` default | Modello resta in RAM |
| PPI ogni 5 min | 2× Get-Process/minuto = I/O + CPU |
| Health audit + apply in loop | wbadmin-style hang (Bug 30) |
| LLM genera comandi shell | Non production-grade |
| GUI + monitor + ollama + IDE | Contention RAM — priorità workload utente |

---

## SLO risorse hub (always-on)

| Metrica | Target feather |
|---------|----------------|
| RAM residente hub (no GUI, no Ollama model) | ≤ 80 MB |
| CPU media hub background | ≤ 2% |
| Disk write/ora (logs) | ≤ 10 MB |
| Picco RAM audit PPI | ≤ 150 MB, ≤ 8s |
| Picco RAM LLM (se usato) | ≤ 700 MB, ≤ 30s, poi unload |

---

## NBD dopo questo studio

1. **`resource-budget.ps1`** — tier + profile resolver  
2. **`build-optimization-context.ps1`** — aggregazione JSON <15 MB  
3. **Config** `ContinuousOptimization` + `LlmAdvisory` (disabled, feather defaults)  
4. **Orchestrator** — PPI subprocess raro, cycle counter  
5. **Smoke** — context builder, no Ollama required  

LLM (`llm-advise.ps1`) = **Fase 1b**, solo dopo baseline feather stabile 48h.

## Riferimenti

- `KB/continuous-optimization-ollama-plan.md`
- ADR-0005
- `logs/regression-health.json` (HardwareProfile 7577)
