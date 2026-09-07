---
name: hub-quality-gate
description: >-
  Run SystemOptimizerHub quality gates before ship: install smoke, hub smoke,
  Android device smoke when ADB connected, dotnet test, NBD eval, repo cleanup.
  Use when user asks quality gate, smoke, pre-commit checks, ship readiness,
  or high quality gate.
---

# Hub quality gate

## Quando usare

- Prima di commit/push di feature non banali
- Dopo fix Android / install / Core
- Quando l'utente chiede "quality gate", "smoke", "verifica", "ship"

## Sequenza (ordine fisso)

Esegui dalla root repo (`active/`):

```powershell
dotnet test src/SystemOptimizerHub.sln --verbosity minimal
powershell -NoProfile -File scripts/test-install-smoke.ps1
powershell -NoProfile -File scripts/test-hub-smoke.ps1
```

Se ADB ha un device (`adb devices` → stato `device`):

```powershell
powershell -NoProfile -File scripts/test-android-device-smoke.ps1
```

Opzionale NBD (migrazione / phase gate):

```powershell
powershell -NoProfile -File scripts/evaluate-migration-nbd.ps1 -Apply
```

Pre-push cleanup:

```powershell
powershell -NoProfile -File scripts/repo-cleanup-before-push.ps1 -Apply
```

## Criteri PASS

| Gate | PASS se |
|------|---------|
| `dotnet test` | 0 failed |
| `test-install-smoke` | ALL PASSED |
| `test-hub-smoke` | exit 0 |
| `test-android-device-smoke` | ALL PASSED **oppure** skip documentato se nessun device |
| cleanup | Runtime artifact gate passed |

## Report

Elenca ogni gate con OK/FAIL + messaggio breve. Se FAIL: fix mirato, ri-run solo il gate fallito, poi full se necessario. Non dichiarare ship-ready con FAIL aperti.
