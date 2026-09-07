# Piano d'azione — da v3.1 a Fase 2 (Vault) e Fase 3 (EXE production)

**Aggiornato:** 2026-08-27  
**Stato attuale:** v3.1.3 — theme/worker-helpers estratti, smoke gate, KB/refactor plan sync; backlog efficacia 1.5.6+ ancora aperto

---

## Fase 1.5 — Onestà e qualità motore (completare prima di Vault/EXE)

**Obiettivo:** ogni comando fa esattamente ciò che dice; rating efficacia ≥ 70 su path principale.

| # | Task | Effort | DoD | Priorità |
|---|------|--------|-----|----------|
| 1.5.1 | ✅ Separare Health Scan vs Scan+Apply | S | Health Scan non chiama apply-safe-fixes | P0 |
| 1.5.2 | ✅ apply-safe-fixes: 1 soluzione/finding | S | Test JSON: un comando per finding | P0 |
| 1.5.3 | ✅ Fix sort garbage-hotspots | S | CSV ordinato Score then ReclaimGB | P0 |
| 1.5.4 | ✅ i18n IT/EN + pannello "Cosa fa" | M | Settings → Language; tooltip su pulsanti | P0 |
| 1.5.5 | ✅ command-catalog.json | S | Ogni CTA Home/Advanced documentata | P0 |
| 1.5.6 | ✅ Whitelist STARTUP-001 (no rimozione SecurityHealth/av) | M | Audit non propone blanket remove AV | P1 |
| 1.5.7 | ✅ PKG findings: distinguere "open link" vs "install" | M | Kind + label [OpenLink/Install] | P1 |
| 1.5.8 | ✅ repair-wsl-config: allinea header vs bcdedit | S | Doc hypervisor in synopsis | P1 |
| 1.5.9 | GUI: tab Salute mostra fs-integrity/orchestrator status | M | Link a log JSON | P2 |
| 1.5.10 | Privacy: profili scan Fast/Standard + exclude modules | M | Config presets | P2 |
| 1.5.11 | ✅ Test suite smoke `scripts/test-hub-smoke.ps1` | M | health+garbage+privacy exit 0 | P1 |
| 1.5.12 | Dialoghi conferma i18n completi (non solo health) | S | Tutti MessageBox da locale | P2 |

**Gate uscita 1.5:** EFFICACY-AUDIT item P0/P1 chiusi; smoke verde; nessun pulsante primario auto-apply.

---

## Fase 2 — Secret Vault + OAuth2 unlock

**Obiettivo:** custodia locale; reveal solo post-autenticazione; migrate da privacy finding.

| # | Task | Effort | DoD |
|---|------|--------|-----|
| 2.1 | ADR vault implementation (DPAPI + SQLite schema) | M | ADR-0004 approvato |
| 2.2 | `vault-service.ps1` — store/list (no reveal) | L | CRUD cifrato, audit log |
| 2.3 | MSAL OAuth2 unlock session (Microsoft account) | L | Token TTL; lock on idle |
| 2.4 | GUI: Unlock Vault + Migrate from finding | M | Privacy tab → vault |
| 2.5 | Optional: redact source file post-migrate (backup first) | M | Rollback JSON file backup |
| 2.6 | i18n vault strings en/it | S | locale keys |
| 2.7 | Security review + exclude vault DB from privacy scan | S | .gitignore + path exclude |

**Gate uscita Fase 2:** migrate test secret; reveal solo dopo OAuth; zero plaintext in logs.

**Dipendenze:** 1.5.11 smoke; privacy scanner stabile (1.5.10).

---

## Fase 3 — EXE production hardening

**Obiettivo:** distribuzione affidabile senza ps2exe monolite 4k LOC.

| # | Task | Effort | DoD |
|---|------|--------|-----|
| 3.1 | Launcher stub (.NET minimal o pwsh host exe) | M | Avvio da qualsiasi path; hub root relativo |
| 3.2 | Inno Setup / MSI installer + pwsh 7 prereq check | M | Install/uninstall pulito |
| 3.3 | Code signing certificate | S | SmartScreen ridotto |
| 3.4 | CI GitHub Actions: package + smoke + artifact | M | Release workflow |
| 3.5 | Deprecare ps2exe monolite (fallback opzionale) | S | README aggiornato |
| 3.6 | Auto-update channel (optional, post-MVP) | L | Check version JSON |

**Gate uscita Fase 3:** EXE firmato installato su macchina pulita; GUI v3.1 IT/EN; smoke pass.

---

## Timeline indicativa

```
2026-08  ████░░░░░░  Fase 1.5 (1–2 settimane)
2026-09  ░░░░████░░  Fase 2 Vault core
2026-10  ░░░░░░████  Fase 2 GUI migrate + hardening
2026-11  ░░░░░░░░██  Fase 3 EXE + installer
```

---

## Metriche di successo finali (post Fase 3)

| Metrica | Target |
|---------|--------|
| Onboarding: utente capisce CTA in < 10s | ✅ pannello help |
| Health path raccomandato (scan → review → apply 1) | ≥ 80% workflow doc |
| Privacy scan read-only | 100% |
| Vault reveal senza OAuth | 0 occorrenze |
| EXE avvio path portable | 100% smoke matrix |
| Regression engine JSON schema | 0 breaking changes |

---

## Ordine esecuzione consigliato

1. Chiudere **1.5.6–1.5.11** (motori onesti + smoke)  
2. **Fase 2.1–2.4** (vault MVP)  
3. **Fase 2.5–2.7** (migrate + security)  
4. **Fase 3.1–3.4** (launcher + installer + CI)  
5. **Fase 3.5–3.6** (polish)

---

## Documenti correlati

- [`VISION.md`](VISION.md)
- [`ROADMAP.md`](ROADMAP.md)
- [`EFFICACY-AUDIT-2026-08-12.md`](EFFICACY-AUDIT-2026-08-12.md)
- [`../architecture/adr/0003-v3-console-privacy-vault.md`](../architecture/adr/0003-v3-console-privacy-vault.md)
