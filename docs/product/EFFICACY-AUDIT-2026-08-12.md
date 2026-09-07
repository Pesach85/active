# Audit efficacia routine — SystemOptimizerHub Active

**Data:** 2026-08-12  
**Metodo:** revisione codice + mapping GUI→script + smoke test  
**Scale:** Efficacia = quanto ottiene ciò che promette (0–100). Impatto/effort = beneficio utente vs complessità/rischio (0–100).

---

## Verdetto executive

| Area | Giudizio |
|------|----------|
| **Onestà etichette GUI (pre v3.1)** | Insufficiente — Health Check auto-applicava fix |
| **Onestà etichette GUI (v3.1)** | Migliorata — scan/apply separati, Storage Audit/Clean, catalogo comandi |
| **Motori storage** | Utili ma limitati — niente WinSxS/DISM, cap file per target |
| **Motore salute** | Buon inventario, fix euristici variabili |
| **Privacy** | Read-only solido; vault assente (Fase 2) |
| **EXE** | Funzionale ma fragile (ps2exe monolite) — Fase 3 |

---

## Tabella routine (rating)

| Routine | Promette | Fa davvero | Efficacia | Impatto/effort | Rischio | GUI |
|---------|----------|------------|-----------|--------------|---------|-----|
| `analyze-garbage-hotspots` | Trova spazio recuperabile | Campiona path, score CSV (**fix sort v3.1**) | 40→45 | 32 | Basso | Scan Storage |
| `quick-cleanup-safe` | Pulizia rapida sicura | Cancella temp/cache/log vecchi | 55 | 62 | Basso | Quick Clean |
| `cleanup-storage-safe` | Cleanup/audit storage | Retention su path fissi; Radical più aggressivo | 52 | 48 | Medio | Storage Audit/Clean |
| `system-health-audit` | Audit salute sistema | WMI + euristiche JSON | 58 | 52 | Basso (solo scan) | Health Scan |
| `apply-safe-fixes` | Applica fix da audit | **v3.1:** 1 soluzione/finding (max ≤ livello) | 42→55 | 38 | Alto se bulk | Scan + Apply |
| `privacy-scan-secrets` | Trova segreti in chiaro | Regex read-only, redacted | 46 | 44 | Basso | Privacy Scan |
| `analyze-compute-resources` | Analisi carico CPU/RAM | 2 snapshot ~8s, advisory | 34 | 38 | Basso | Compute Load |
| `analyze-nvme-readonly-plan` | Piano usura NVMe | Counter + checklist testo | 44 | 50 | Basso | NVMe Advisor |
| `analyze-recovery-partition-legacy` | Reclaim partizione recovery | Audit ok; apply distruttivo su layout default | 15–75* | 28 | **Alto** apply | Partition Plan |
| `monitor-resources` | Monitor risorse | Loop infinito; throttle/kill opzionale | 41 | 36 | Medio | Task background |
| `hub-orchestrator` | Orchestrazione hub | Rotation log + fs-integrity + WHEA | 50 | 40 | Basso | No |
| `fs-integrity` | Integrità filesystem | Scan eventi/volumi; **-Execute non ripara** | 35 | 30 | Basso | No |
| `build-gui-exe` | Build EXE | ps2exe su GUI monolite | 80 | 25 | Basso | No |
| `package-suite` | Package distribuibile | Copy script + config + i18n | 85 | 20 | Basso | No |
| `ensure-powershell-core` + task install | Core + task | pwsh + task SYSTEM monitor/cleanup | 65 | 45 | Medio | Install Core |

\*Partition Plan: efficacia alta solo se layout disco = default script (raro).

---

## Top mismatch risolti in v3.1

1. **Health Check → Health Scan** — solo audit; apply spostato in **Scan + Apply** (advanced).
2. **Audit/Execute → Storage Audit / Storage Clean** — chiarisce che non è health audit.
3. **`apply-safe-fixes`** — una soluzione per finding invece di tutte ≤ livello.
4. **`analyze-garbage-hotspots`** — sort Score + ReclaimGB corretto.
5. **`fs-integrity -Execute`** — warning esplicito: nessuna riparazione automatica.
6. **Pannello "Cosa fa"** + tooltip + `command-catalog.json` con rating per comando.

---

## Mismatch ancora aperti (backlog pre-Fase 2)

| # | Problema | Priorità |
|---|----------|----------|
| 1 | Deep Scan tab = stesso script di Health Scan (UX ok se etichettato; motore unico) | P2 |
| 2 | PKG fix: molte soluzioni Safe = apri browser, non install | P1 |
| 3 | STARTUP-001: rimuove tutti Run key senza whitelist | P1 |
| 4 | `repair-wsl-config`: header dice no hypervisor, apply può `bcdedit` | P1 |
| 5 | Task cleanup SYSTEM: non pulisce temp utente come GUI | P2 |
| 6 | Privacy scan: `%USERPROFILE%` recurse lento + falsi positivi | P2 |
| 7 | Compute: raccomandazioni non eseguite | P3 |
| 8 | Orchestrator/fs-integrity invisibili in GUI | P2 |

---

## Workflow raccomandato (efficacia massima)

1. **Home → Scan Storage** → identifica dove c'è spazio  
2. **Quick Clean** o **Storage Audit** → poi **Storage Clean** se ok  
3. **Health Scan** (read-only) → tab Salute → **Apply Selected Fix** uno alla volta  
4. **Privacy Scan** → review → (Fase 2) migrate vault  
5. Evitare **Scan + Apply** e **Partition Plan apply** salvo necessità e backup  

---

## Riferimenti

- `config/command-catalog.json` — testi IT/EN + rating per comando GUI  
- `docs/product/ACTION-PLAN-PHASE1-3.md` — piano fino a Fase 2/3  
- ADR-0003
