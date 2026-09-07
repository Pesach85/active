---
name: hub-hitl-migration-decision
description: >-
  Data-driven decision framework for Hub Phase 3 HITL paths: hub resolve apply,
  hub defender apply, and HUB_USE_CORE rollout. Use when the user asks whether
  to port mutating paths, enable HUB_USE_CORE, approve Defender disable, or
  choose the next migration NBD after Phase 2.
---

# Hub Phase 3 — Decisione HITL (data-driven)

## Quando usare questa skill

- L’utente chiede cosa fare tra **resolve apply**, **defender apply**, **HUB_USE_CORE**
- Serve una raccomandazione **deterministica** sul prossimo passo di migrazione PS → Core
- Prima di implementare path mutanti o abilitare flag in produzione

## Fonte di verità

Leggere e aggiornare: [`KB/hub-hitl-paths-decision.md`](../../../KB/hub-hitl-paths-decision.md)

Config NBD: `config/migration-nbd.json`  
Gate: `docs/knowledge/migration-nbd-quality-gate.md`

## I tre path (memoria rapida)

| Path | Mutazione | Stato Core 0.6.0 | Risk NBD |
|------|-----------|-------------------|----------|
| 1 `hub resolve apply` | Throttle / terminate processo | Solo `plan` | RegressionRisk **30** |
| 2 `hub defender apply` | Esclusioni / RT off / stop AV | Solo `evaluate` | RegressionRisk **15** |
| 3 `HUB_USE_CORE=1` | Instrada PS → hub CLI | **Non in script** | Dipende da dominio |

**Path 3 non è alternativo a 1/2** — è il meccanismo di rollout dopo che 1 o 2 sono portati e in parity.

## Workflow decisionale (obbligatorio)

### 1. Raccogliere evidenze (non opinare senza dati)

Eseguire in sequenza:

```powershell
dotnet test src/SystemOptimizerHub.sln
powershell -File scripts/test-core-parity.ps1
powershell -File scripts/test-hub-smoke.ps1
powershell -File scripts/evaluate-migration-nbd.ps1 -Apply
```

Leggere `logs/migration-nbd-latest.json` e gli score in `config/migration-nbd.json` per `phase3-*`.

### 2. Applicare matrice deterministica

Ordine fisso (non invertire senza motivo documentato):

1. **Resolve apply** portato + parity apply PASS?
2. Solo allora **HUB_USE_CORE** per dominio `resolve`
3. **Defender apply** portato + rollback test PASS?
4. Solo allora **HUB_USE_CORE** per dominio `defender`

Se un prerequisito fallisce → **STOP HITL**, proporre fix gate o scope ridotto.

### 3. Scope minimo (best effort)

Preferire sempre lo scope più piccolo che sblocca valore:

| Richiesta utente | Scope minimo consigliato |
|------------------|-------------------------|
| Azione su processo | Throttle only (no terminate) in Core |
| Defender emergenza | TuneExclusions only (no RT off / service stop) |
| Test Core in prod | Read-only: `plan`, `evaluate`, `classify` — **no flag mutanti** |

### 4. Gate HITL non negoziabili

Non implementare né abilitare flag senza:

- **Session HITL** (`Start-OperatorHitlSession` / `hub auth session-start`) — password once per ~45 min
- Catalog block (`Keep` → no throttle/terminate)
- Confirm phrase per terminate
- Rollback JSON per throttle e Defender
- Transparency events (`logs/transparency-events.jsonl`)
- **Decision effectiveness log** (`logs/hub-decision-log.jsonl` → snapshot `logs/hub-decision-effectiveness-latest.json`)
- Before Phase 4: read `migration-nbd-latest.json` → `DecisionEffectiveness.NbdRecommendations`
- Per Defender tier 2+: Tamper Protection gestito esplicitamente
- Composite tier ≥ **85** prima di qualsiasi path Defender mutante

### 5. Documentare decisione

Dopo ogni scelta operatore:

1. Riga in tabella **Decision log** in `KB/hub-hitl-paths-decision.md`
2. Entry `KB/journal.md` (Obiettivo, Task, Decisioni, Esito)
3. Se implementato: aggiornare `migration-nbd.json` Status

## Cosa NON fare

- Abilitare `HUB_USE_CORE=1` globale
- Portare defender apply prima di resolve apply (risk più alto, user value più basso per uso quotidiano)
- Saltare parity golden JSON per path mutanti
- Auto-apply Defender tier ≥ TemporaryRealtimeOff senza doppia conferma operatore
- Commit/push path HITL senza esplicita richiesta utente

## Risposta all’utente

Strutturare sempre:

1. **Cosa fa** il path (1 paragrafo)
2. **Come lavora** (flusso gate)
3. **Pro / contro** con numeri NBD dove disponibili
4. **Raccomandazione data-driven** (matrice + gate status attuale)
5. **Domanda chiusa** per decisione operatore (es. scope: throttle-only vs full apply)
