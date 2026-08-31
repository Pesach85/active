# Quality gate — Migration NBD (scored)

Usare **prima** di ogni sprint di migrazione PS → C# Core (ADR-0007).

## Comando

```powershell
powershell -File scripts/evaluate-migration-nbd.ps1
powershell -File scripts/evaluate-migration-nbd.ps1 -Apply -QuickGates   # dotnet + parity (~1 min)
powershell -File scripts/evaluate-migration-nbd.ps1 -Apply               # + hub smoke (~3 min)
```

Output: `logs/migration-nbd-latest.json`

## Gate obbligatori (GO / NO-GO)

| Gate | Comando | Fail = |
|------|---------|--------|
| `dotnet_test` | `dotnet test src/SystemOptimizerHub.sln` | Core rotto |
| `core_parity` | `scripts/test-core-parity.ps1` | Drift PS vs C# catalog |
| `hub_smoke` | `scripts/test-hub-smoke.ps1` | Regressione PS production |

Se **un gate fallisce** → NBD = `stabilize-gates` (fix prima di migrare).

## Scoring deterministico

Config: [`config/migration-nbd.json`](../../config/migration-nbd.json)

```
TotalScore = Σ (dimension × weight)

Weights:
  ParityFeasibility     25%  — quanto è realistico match JSON 1:1
  RegressionRiskInverse 25%  — sicurezza (100 = rischio basso)
  UserValue             20%  — impatto operatore
  GateReadiness         20%  — prerequisiti Phase 0/N-1 soddisfatti
  EffortInverse         10%  — scope piccolo = punteggio alto
```

Solo candidati con `Status: ready` entrano in competizione.  
`blocked` esclusi finché `BlockedBy` non è `done`.  
`done` esclusi.

**PassThreshold:** 70 — sotto soglia il candidato vince ma con flag `BelowThreshold`.

## NBD atteso (Phase 0 completata)

Vincitore deterministico attuale: **`phase1-resolution-advisory`**

Motivo: massimo score tra `ready`, riusa Core già portato, read-only, minimo rischio HITL.

## Dopo ogni implementazione

1. Eseguire gate `-Apply`
2. Aggiornare `Status` candidato in `migration-nbd.json` → `done`
3. Sbloccare candidati con `BlockedBy` soddisfatto
4. Entry `KB/journal.md`
5. `test-core-parity.ps1` esteso al nuovo dominio

## Anti-pattern

- Saltare Phase 1 read-only e andare a mutating (Phase 2)
- Big-bang rewrite senza parity golden JSON
- Abilitare `HUB_USE_CORE=1` senza gate ALL PASSED
