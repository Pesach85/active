# Process Knowledge — classificazione assistita (deterministic + incremental)

## Pipeline (ordine di priorità)

| Tier | Fonte | RAM/CPU | Affidabilità |
|------|-------|---------|--------------|
| 1 | `process-intelligence.json` | 0 | 100% |
| 2 | `KB/process-knowledge-cache.json` | ~0 | Alta (TTL 30d) |
| 3 | File metadata (ProductName, Company, Description) | Basso | Alta |
| 4 | KB grep (`KB/`, `docs/`) | Basso | Media |
| 5 | Wikipedia REST (solo se web OK, max 2/run) | Basso | Media |
| 6 | Ollama 0.5B (solo Tier B+, `LlmAdvisory.Enabled`) | Burst | T2_Review |

## Output

`ProcessKnowledgeHint.v1` in PPI / TransparencyReport → `ClassificationHints[]`

Campi chiave: `WhatItIs`, `WhatItDoes`, `SuggestedCategory`, `SuggestedPriority`, `SuggestedCatalogEntry`, `Confidence`, `RequiresHumanApproval=true`

## Comandi

```powershell
pwsh -File scripts/enrich-process-classification.ps1 -ProcessNames mysqld,vmware-vmx -Offline
pwsh -File scripts/analyze-process-pressure.ps1 -IncludeClassificationHints -OfflineHints -Top 8
```

## Incremental learning

- Cache aggiornata quando `PersistLearnings=true` e confidence ≥ 0.65
- **Mai** scrittura automatica su `process-intelligence.json` — solo draft per operatore
- LLM e web marcati T2_Review nel transparency contract

## Smoke

`test-hub-smoke.ps1` → step `process-knowledge`, `process-pressure-hints`
