# Checklist validazione deterministica — Hub Quality Gate

Usare **in ordine** prima di ogni release o validazione completa. Ogni riga ha criterio PASS oggettivo.

**Hub Core target:** `hub version` → `"hubCore": "0.7.1"` (o versione corrente in `HubVersion.cs`)

---

## 0. Prerequisiti ambiente

| # | Check | Comando / azione | PASS se |
|---|-------|------------------|---------|
| 0.1 | Repo pulito (gate riproducibili) | `git status` | Nessun conflitto; modifiche intenzionali note |
| 0.2 | .NET SDK | `dotnet --version` | ≥ 9.0 |
| 0.3 | PowerShell | `pwsh -Version` | Disponibile |
| 0.4 | Admin (solo per apply live Defender) | GUI / `Test-HubAdmin` | Admin solo se esegui tier live — **dry-run no admin** |
| 0.5 | Hub root | `cd D:\SystemOptimizerHub\active` | Path corretto |

---

## 1. Gate automatici obbligatori (GO / NO-GO)

Eseguire **tutti**; un solo FAIL = NO-GO.

| # | Gate | Comando | PASS se |
|---|------|---------|---------|
| 1.1 | Unit test Core | `dotnet test src/SystemOptimizerHub.sln -v q --nologo` | `Superato!` — **≥ 27 test** (contare totale) |
| 1.2 | Core parity PS↔C# | `powershell -File scripts/test-core-parity.ps1` | Ultima riga: `[PARITY] ALL PASSED` |
| 1.3 | Hub smoke | `powershell -File scripts/test-hub-smoke.ps1` | Ultima riga: `[SMOKE] ALL PASSED` |
| 1.4 | Identify chain E2E | `powershell -File scripts/test-identify-chain-e2e.ps1` | `ALL PASSED` |
| 1.5 | NBD scorer (opzionale report) | `powershell -File scripts/evaluate-migration-nbd.ps1 -Apply` | `logs/migration-nbd-latest.json` — gate obbligatori PASS |

**Tempo stimato:** ~5–8 min (smoke dominante).

---

## 2. Verifica CLI Hub (dati completi)

Pre-build una volta: `dotnet build src/SystemOptimizerHub.Cli/SystemOptimizerHub.Cli.csproj`

| # | Comando | PASS se (JSON / exit) |
|---|---------|------------------------|
| 2.1 | `dotnet run --project src/SystemOptimizerHub.Cli --no-build -- version` | `hubCore` = versione attesa |
| 2.2 | `... catalog classify --name MsMpEng` | `Priority`: `Keep` |
| 2.3 | `... resolve plan --name MsMpEng --action ThrottleBelowNormal --skip-auth --dry-run` | `Outcome`: `ActionBlocked` |
| 2.4 | `... resolve plan --name PID1234 --pid 1234 --action ThrottleBelowNormal --dry-run --not-running` | `Outcome`: `ProcessNotRunning` |
| 2.5 | `... defender evaluate --input logs/parity-ppi-measure.json` (se esiste) | `SchemaVersion` contiene `DefenderExtremeNecessityEvaluation` |
| 2.6 | `... auth session-start --skip-auth` | `ok`: true, `sessionToken` non vuoto |
| 2.7 | `... defender apply --evaluation config/fixtures/defender-eval-apply-dryrun.json --tier TuneExclusions --exclusion-path logs --dry-run --understand-risk --skip-auth` | `SchemaVersion`: `DefenderExtremeApplyResult.v1`, `DryRun`: true, `RollbackPath` file esiste |

---

## 3. Session HITL (UX operatore)

| # | Scenario | PASS se |
|---|----------|---------|
| 3.1 | GUI Control → **HITL Paths...** → Sblocca sessione | Label sessione attiva con scadenza |
| 3.2 | Resolve senza sessione | Prompt sblocco (no password per singola azione) |
| 3.3 | Dopo sblocco: Throttle/Osserva/Identify | Azione completa senza re-prompt password |
| 3.4 | Web dashboard → Sblocca sessione → wizard azione | `sessionStorage.hubHitlSessionToken` impostato |
| 3.5 | Termina sessione | Azioni mutanti richiedono di nuovo sblocco |

---

## 4. Pannello 3 path (use case)

| Path | Dove | PASS se |
|------|------|---------|
| 1 Process action | HITL Paths → Apri Resolve | Wizard advisory; Keep blocca throttle |
| 2 Defender extreme | HITL Paths → Defender Review | Eval tier; composite ≥ 85 per prompt |
| 3 Hub Core routing | Checkbox `HUB_USE_CORE=1` | `$env:HUB_USE_CORE` = `1` in sessione GUI |

---

## 5. Soglie composite Defender (deterministiche)

Config: `config/process-intelligence.json` → `extremeNecessityDefender.tiers`

| Tier | minComposite | PASS verifica |
|------|--------------|---------------|
| Observe | 0 (max 84) | composite &lt; 85 → tier Observe |
| TuneExclusions | **85** | 85 ≤ composite &lt; 90 |
| TemporaryRealtimeOff | **90** | 90 ≤ composite &lt; 95 |
| ExtremeServiceDisable | **95** | composite ≥ 95 |

Prompt GUI: `config/sys-maintenance.json` → `ProcessPressure.DefenderExtreme.MinCompositeScoreForPrompt` = **85**

---

## 6. Parity spot-check (campione golden)

Dopo parity script, verificare file in `logs/`:

| File | Campo | Valore atteso |
|------|-------|---------------|
| `parity-plan-keep-blocked-cs.json` | `Outcome` | `ActionBlocked` |
| `parity-defender-apply-cs.json` | `Tier` | `TuneExclusions` |
| `parity-defender-apply-cs.json` | `DryRun` | `true` |
| `parity-catalog-merge-direct.json` | `Ok` | `true` |

---

## 7. Apply live (solo lab — NON in gate CI)

⚠ Solo su VM/lab con rollback testato. **Non richiesto** per quality gate standard.

| # | Step | PASS se |
|---|------|---------|
| 7.1 | `hub auth session-start` (password reale) | Token ricevuto |
| 7.2 | `hub defender evaluate` → tier + blockers | `AllowedToProceed` true, Tamper off se tier ≥ 90 |
| 7.3 | `hub defender apply` **senza** `--dry-run` + `--session-token` | Rollback JSON + scheduled task (tier RT/Extreme) |
| 7.4 | `restore-defender-from-rollback.ps1 -RollbackJson ...` | Defender ripristinato |

---

## 8. Packaging deploy

| # | Comando | PASS se |
|---|---------|---------|
| 8.1 | `powershell -File scripts/package-suite.ps1` | `Package ready at: dist/WindowsOptimizer` |
| 8.2 | `dist/WindowsOptimizer/hub/hub.cmd version` | `hubCore` corretto |

---

## 9. Registro decisione (KB)

| # | Azione | PASS se |
|---|--------|---------|
| 9.1 | Entry `KB/journal.md` | Obiettivo, gate, esito |
| 9.2 | `config/migration-nbd.json` | Phase 3 `done`; Phase 4 `done`; Phase 5 network deep `next` |
| 9.3 | Decision log in `KB/hub-hitl-paths-decision.md` | Riga operatore se apply live approvato |

---

## 10. Decision effectiveness (auto — agent/NBD)

| # | File | PASS se |
|---|------|---------|
| 10.1 | `logs/hub-decision-log.jsonl` | Nuove righe dopo azioni HITL (session, resolve, identify) |
| 10.2 | `logs/hub-decision-effectiveness-latest.json` | `SchemaVersion`: `HubDecisionEffectiveness.v1` |
| 10.3 | `logs/migration-nbd-latest.json` | Campo `DecisionEffectiveness` presente; `NextBestDecision.EffectivenessReady` per Phase 4 |

```powershell
powershell -File scripts/evaluate-migration-nbd.ps1 -Apply -QuickGates
Get-Content logs/hub-decision-effectiveness-latest.json | ConvertFrom-Json | Select-Object EntryCount, OverallSuccessRatePercent, Signals
```

---

## Comando unico (quick gate ~2 min)

```powershell
dotnet test src/SystemOptimizerHub.sln -v q --nologo
powershell -File scripts/evaluate-migration-nbd.ps1 -Apply -QuickGates
```

QuickGates = dotnet + parity. Aggiungere smoke per gate completo.

---

## Comando unico (gate completo ~8 min)

```powershell
dotnet test src/SystemOptimizerHub.sln -v q --nologo
powershell -File scripts/test-core-parity.ps1
powershell -File scripts/test-hub-smoke.ps1
powershell -File scripts/test-identify-chain-e2e.ps1
powershell -File scripts/evaluate-migration-nbd.ps1 -Apply
powershell -File scripts/package-suite.ps1
```

**PASS globale:** tutte le sezioni 1.x + 8.x verdi; sezioni 3–6 validate manualmente in GUI prima di produzione.
