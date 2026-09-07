# Piano operativo Elite — Refactoring & qualità 100%

**Data:** 2026-08-27  
**Stato codebase:** GUI **v3.1.3** (theme + worker-helpers estratti), Privacy scanner shippato, Fase 2 Vault non iniziata  
**Obiettivo:** bottlenecks OS rilevati in modo deterministico, fix senza regressioni, KB allineata al codice

---

## 0. Verità operativa (gap KB vs codice — chiusi in questa sessione)

| Prima (KB/docs) | Realtà codice | Azione |
|-----------------|---------------|--------|
| AutoAnalyzeOnStartup consigliato `true` | Default **`false`** (UX: no scan all'avvio) | KB Pattern 7 aggiornato |
| Task-board Done ferma a Config tab | Privacy, i18n, catalog, v3.1.x presenti | Task-board aggiornato |
| ROADMAP Fase 1 "in corso" | 1.2–1.4, 1.6–1.7 ✅; 1.5 theme ✅ (2026-08-27); 1.8 smoke ✅ | ROADMAP aggiornato |
| ADR-0003 "Fase 1 implementing" | Fase 1 prodotto completa; modularizzazione in corso | ADR status aggiornato |
| Bug 25 ultimo | Bug 26 AlreadyOptimized + Bug 27 modularizzazione | bugs-fixed |

---

## 1. Mappa umana del sistema

```
Utente / Lead AI
    │
    ├─ GUI WinForms (system-optimizer-gui.ps1 + scripts/gui/*)
    │      │ Start-Process + Timer poll
    │      ▼
    ├─ Motori (script standalone, JSON/CSV in logs/)
    │      health-audit → apply-safe-fixes
    │      garbage-hotspots → cleanup / quick-clean
    │      compute / nvme / partition / privacy / fs-integrity
    │
    ├─ Always-on: monitor-resources + hub-orchestrator (task)
    │
    └─ Knowledge: docs/ (permanente) + KB/ (operativa) + logs/ (evidenza)
```

**Source of truth:** `scripts/` + `config/`.  
**Dist:** `package-suite.ps1` → `dist/WindowsOptimizer` (subset + UTF-8 BOM).  
**Lab-only (non in dist):** NVMe writeoffload, WHEA campaign, kernel/bloatware tuners, DD-WRT.

---

## 2. Problemi per categoria

### A. Strutturali (HIGH)
1. **GUI monolite** ancora ~4k LOC di layout + 11 worker clone (theme/helpers ora fuori).
2. **Doppio path Health:** Home Health Scan + tab Salute Deep Scan → stesso engine, UX duplicata.
3. **Config GUI bypass** `hub-common` → rischio drift path/schema.
4. **dist config ≠ src** possibile (`Cleanup.Tier2.Enabled`).

### B. Duplicazione (HIGH)
1. **12× Poll-*/Start-*/Stop-*** quasi identici nella GUI.
2. **Admin check** misto `#Requires` vs `WindowsPrincipal` (mitigato: `Test-HubAdmin` in hub-common).
3. **JSON envelope** ripetuto senza builder condiviso.

### C. Performance (MEDIUM)
1. Garbage Deep su C:+D: I/O pesante se auto-start (ora disabilitato).
2. Health audit timeout/soft-timeout; WSL probe deve restare gated.
3. 12 timer a 1s → CPU UI trascurabile ma rumore di codice.
4. Privacy scan su Documents grandi → max file size / exclude già in config.

### D. Mantenibilità lungo termine (HIGH)
1. Stringhe runtime ancora EN in molti `Append-Status`.
2. Contratti JSON non versionati centralmente (solo campi ad hoc).
3. EFFICACY backlog aperto (STARTUP whitelist, PKG open-link vs install).
4. Nessun CI fino a Fase 3.

### E. Completezza diagnostica OS (GAP verso “100%”)
Il hub è forte su: storage reclaim, health findings tipici, WHEA/NVMe campagne, privacy plaintext.  
**Non** è ancora un detector universale: manca coverage sistematica di rete, update pending, driver drift, startup impact score (ROADMAP Fase 4).  
Target realistico: **100% sui path instrumentati** + piano per chiudere gap Fase 4, non “qualsiasi OS problem” senza moduli dedicati.

---

## 3. Strategia refactoring (onde validate)

### Onda 0 — Gate (ogni PR) ✅ iniziata
```powershell
pwsh -NoProfile -File scripts/test-hub-smoke.ps1
pwsh -NoProfile -File scripts/package-suite.ps1
```
DoD: exit 0; dist contiene `scripts/gui/theme.ps1` + `worker-helpers.ps1`.

### Onda 1 — GUI worker framework (P0, prossimo)
1. Introdurre `scripts/gui/async-worker.ps1` con descriptor:
   `{ Name, Script, Args, JsonOut, StdOut, StdErr, TimeoutSec, OnComplete, OnFail }`
2. Migrare **un** worker (privacy) → smoke + GUI manual click.
3. Migrare gli altri uno a uno (health, garbage, cleanup, …).
4. **Mai** migrare tutti in un solo commit.

### Onda 2 — Config unica (P0)
1. GUI `Load-GuiPreferences` / Save → `Get-MaintenanceConfig` / `Save-MaintenanceConfig`.
2. Documentare policy Tier2 src vs dist (env-specific).
3. package-suite: opzione `-Profile core|lab`.

### Onda 3 — Onestà motore (P1) — da ACTION-PLAN 1.5.6–1.5.8
1. Whitelist STARTUP-001.
2. PKG solution labels open-link vs install.
3. WSL doc/header allineati a bcdedit.

### Onda 4 — Report schema (P1)
`hub-report.ps1`: `New-AuditEnvelope`, severity summary; bump AuditVersion solo con ADR.

### Onda 5 — Split tab builders (P2)
`gui/tab-home.ps1`, `tab-health.ps1`, `tab-privacy.ps1` — solo dopo Onda 1 verde.

### Onda 6 — Vault + EXE (Fase 2–3 prodotto)
Come ACTION-PLAN; **non** mescolare con Onda 1.

---

## 4. Miglioramenti deterministici già applicati (2026-08-27)

| Cambio | Validazione |
|--------|-------------|
| `scripts/gui/theme.ps1` estratto | Dot-source + throw se mancante |
| `scripts/gui/worker-helpers.ps1` estratto | Wait-ForOutputFile / exit / err tail |
| `scripts/test-hub-smoke.ps1` | health + garbage + privacy + moduli |
| `Test-HubAdmin` / `Assert-HubAdmin` in hub-common | riusabile da script elevate |
| Default AutoAnalyze `false` (già v3.1.2) | config + codice |
| Format AlreadyOptimized stringhe (v3.1.2) | no `.Id` su string array |
| KB/architecture, task-board, bugs, roadmap sync | questa sessione |

---

## 5. Checklist anti-regressione (obbligatoria)

Dopo ogni onda:
- [ ] `test-hub-smoke.ps1` exit 0
- [ ] Health Scan GUI: log senza `parse failed`
- [ ] Avvio GUI: nessun scan automatico
- [ ] Altri strumenti: testo pulsanti non clip
- [ ] `package-suite.ps1` exit 0
- [ ] Entry `KB/journal.md` via `kb-add-entry.ps1`

---

## 6. Ordine esecuzione immediato (prossime sessioni)

1. Eseguire smoke su macchina host; fix eventuali fail.  
2. Onda 1 step privacy-only async-worker.  
3. Chiudere 1.5.6–1.5.8 efficacia.  
4. Solo dopo: Vault ADR-0004.

---

## Documenti correlati

- [`KB/architecture.md`](../../KB/architecture.md)
- [`KB/codebase-health.md`](../../KB/codebase-health.md)
- [`EFFICACY-AUDIT-2026-08-12.md`](EFFICACY-AUDIT-2026-08-12.md)
- [`ACTION-PLAN-PHASE1-3.md`](ACTION-PLAN-PHASE1-3.md)
- [`ROADMAP.md`](ROADMAP.md)
