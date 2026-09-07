---
name: windows-dev-sync
description: >-
  Package dist, refresh Windows install via junction/mirror, optional GUI EXE
  rebuild. Use when user asks deploy Windows, dev-sync, refresh install,
  BuildGui, or sync production app from repo.
---

# Windows dev-sync / deploy

## Quando usare

- Dopo change a scripts/config/hub che devono arrivare all'app installata
- Utente chiede "deploy", "dev-sync", "aggiorna install", "BuildGui"

## Sequenza

Dalla root repo (`active/`):

```powershell
powershell -NoProfile -File scripts/dev-sync-production.ps1
```

Con rebuild GUI EXE:

```powershell
powershell -NoProfile -File scripts/dev-sync-production.ps1 -BuildGui
```

Con re-register task Core (raro):

```powershell
powershell -NoProfile -File scripts/dev-sync-production.ps1 -BuildGui -RegisterTasks
```

## Prerequisiti

- Install Windows già fatto (`install-windows-app.ps1`) con manifest; preferire DevSync junction.
- Se manca manifest: avvisare e fermarsi (non inventare path install).

## Verifica

- Output contiene `[DEV-SYNC] Done` e path app.
- Se DevSync: junction punta a `dist\WindowsOptimizer` (o path profilo).
- Smoke mirato se change non banale: `scripts/test-install-smoke.ps1` o skill `hub-quality-gate`.

## Hard don'ts

- Non usare `-RegisterTasks` senza richiesta esplicita.
- Non overwrite mirror su junction senza passare da `dev-sync-production.ps1`.
- Non dichiarare deploy OK senza output dello script.
