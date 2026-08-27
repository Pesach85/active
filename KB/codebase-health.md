# Codebase Health — Snapshot 2026-08-27

Valutazione strutturale del repo **SystemOptimizerHub/active** dopo audit elite + allineamento KB.

## Scala sintetica

| Area | Voto | Note |
|------|------|------|
| Motori storage/health | B+ | Contract JSON stabile; backlog efficacia P1 aperto |
| GUI UX v3 | B | IA corretta; monolite layout ancora grande |
| Modularizzazione GUI | B- | theme + worker-helpers + i18n + help estratti (v3.1.3) |
| Packaging dist | B | Allowlist chiara; drift Tier2 possibile |
| Knowledge (docs+KB) | A- | Sync 2026-08-27; journal da mantenere |
| Test/CI | C+ | Smoke CLI presente; no CI GitHub ancora |
| Coverage “ogni bottleneck OS” | C | Forte su path instrumentati; Fase 4 per gap |

## Inventario (ordine di grandezza)

- `scripts/` ≈ 60 entrypoint, ~14k LOC prodotto (escluso vendor ps2exe)
- God file residuo: `system-optimizer-gui.ps1` (~4.1k linee layout/worker wiring)
- Motori critici: `system-health-audit.ps1`, `apply-safe-fixes.ps1`, `analyze-garbage-hotspots.ps1`, `privacy-scan-secrets.ps1`
- Campagne lab (non dist): NVMe writeoffload, WHEA, kernel tuners, DD-WRT

## Contratti da non rompere

1. Health JSON: `Findings[]`, `AlreadyOptimized` (**string[]**), `Summary`
2. Apply JSON: una soluzione per finding ≤ MaxLevel
3. Privacy: `SchemaVersion=PrivacyScanReport.v1`, valori redatti
4. Garbage CSV: colonne Score/Path/ReclaimGB (+ intelligence fields)
5. Worker handshake: Start-Process → file out → Wait-ForOutputFile → parse

## Debito prioritizzato

Vedi [`docs/product/REFACTORING-PLAN-ELITE.md`](../docs/product/REFACTORING-PLAN-ELITE.md).

P0: async-worker unico; config via hub-common.  
P1: efficacia STARTUP/PKG/WSL; report helpers.  
P2: split tab; CI; package profiles.

## Come leggere questo file

Aggiornare la data e i voti **dopo ogni onda di refactor** o release GUI (minor bump).  
Non sostituisce `architecture.md` (pattern) né `bugs-fixed.md` (incident).
