# Roadmap — Active / SystemOptimizerHub v3

Stato aggiornato: **2026-08-27**

## Fase 0 — Allineamento (completata base)

| Item | Stato | Note |
|------|-------|------|
| Repo portable (`Get-HubRoot`) | ✅ | ADR-0002 |
| GUI Obsidian v2.1 | ✅ | Tema dark, deep scan tab |
| Package `dist/WindowsOptimizer` | ✅ | `package-suite.ps1` |
| Orchestrator + fs-integrity | ✅ | `sys-maintenance.json` |

## Fase 1 — Console v3 + Privacy Scanner (completata prodotto)

**Obiettivo:** UX ordinata + privacy scan audit-first, zero regressioni engine esistenti.

| # | Deliverable | Effort | DoD | Stato |
|---|-------------|--------|-----|-------|
| 1.1 | `docs/product/VISION.md` + ADR-0003 | S | Documenti approvati | ✅ |
| 1.2 | `privacy-scan-secrets.ps1` | M | JSON schema + runbook | ✅ |
| 1.3 | Tab **Privacy** in GUI | M | Run/Cancel/ListView findings | ✅ |
| 1.4 | Home IA: 4 CTA + "More tools" collapsible | M | ≤4 pulsanti primari visibili | ✅ |
| 1.5 | `scripts/gui/theme.ps1` estratto | S | Dot-source da GUI | ✅ v3.1.3 |
| 1.6 | Config `Privacy` in sys-maintenance.json | S | Path scan, exclude, max file size | ✅ |
| 1.7 | package-suite include privacy script | S | dist aggiornato | ✅ |
| 1.8 | Smoke `test-hub-smoke.ps1` | S | health+garbage+privacy | ✅ |

**Post-Fase 1 (continuo):** vedi [`REFACTORING-PLAN-ELITE.md`](REFACTORING-PLAN-ELITE.md) e Fase 1.5 in ACTION-PLAN.

**Smoke check:**

```powershell
cd D:\SystemOptimizerHub\active
pwsh -NoProfile -File scripts/test-hub-smoke.ps1
pwsh -NoProfile -File scripts/package-suite.ps1
```

## Fase 2 — Secret Vault locale + OAuth2

**Obiettivo:** Custodia sicura; reveal solo dopo autenticazione.

| # | Deliverable | Effort |
|---|-------------|--------|
| 2.1 | ADR vault: DPAPI master + SQLite | M |
| 2.2 | `vault-store.ps1` — CRUD cifrato | L |
| 2.3 | MSAL OAuth2 (Microsoft account / Entra opzionale) | L |
| 2.4 | GUI: "Unlock vault" + migrate from finding | M |
| 2.5 | Windows service o scheduled lock idle | M |

**Stack proposto:** .NET/PowerShell + `Microsoft.Data.Sqlite` + DPAPI `ProtectedData` + `MSAL.PS` per token OAuth2.

## Fase 3 — EXE production hardening

| # | Deliverable | Effort |
|---|-------------|--------|
| 3.1 | Launcher stub exe + scripts folder (no ps2exe monolite) | M |
| 3.2 | Code signing (cert) | S |
| 3.3 | Installer MSI/Inno con prereq pwsh 7 | M |
| 3.4 | CI GitHub Actions: build + smoke | M |

## Fase 4 — Utility manutenzione extra

| Modulo | Descrizione | Priorità |
|--------|-------------|----------|
| Startup audit | Programmi avvio + impact score | P2 |
| Driver drift | Confronto driver vs baseline | P3 |
| Update health | Windows Update / pending reboot | P2 |
| Network hygiene | DNS, proxy, cert store quick scan | P3 |
| Backup verify | Test restore ultimo shadow/copy | P3 |

---

## Matrice rischio / rollback

| Cambiamento | Rischio regressioni | Rollback |
|-------------|----------------------|----------|
| Nuovo script privacy | Basso (read-only) | Rimuovi script + tab |
| GUI layout | Medio | Git revert GUI file |
| Vault write | Alto | Feature flag `Vault.Enabled=false` |
| Engine cleanup/health | Alto | Non modificare schema JSON esistente |

---

## Metriche successo v3

- Tempo onboarding GUI: utente trova azione primaria in **< 10 secondi**
- Privacy scan: **100% read-only** (verificabile: no `Set-Content`/`Remove-Item` nello script)
- Exe: avvio da `D:\`, `C:\Users\*\Desktop\`, path con spazi
- Test regression health + garbage: stesso schema JSON v2.1
