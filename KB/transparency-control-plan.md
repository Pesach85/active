# Transparency & Control — Piano operativo e analisi cybersecurity

## Obiettivo operatore

Garantire che **ogni attività** sui dispositivi aziendali sia:

1. **Visibile** — elencata, classificata, con audit trail
2. **Controllabile** — pausa/disabilitazione agenti delegati
3. **Condivisa** — stesso contratto per operatore umano e AI
4. **Legale** — nessuna mutazione nascosta; HITL per azioni sensibili

Filosofia: l'AI tutela sé stessa e le risorse hardware **solo** entro regole esplicite che l'operatore approva.

---

## Analisi cybersecurity — software

### Superficie attuale (7577 / Windows)

| Area | Rischio | Mitigazione hub |
|------|---------|-----------------|
| Task schedulati SYSTEM | Attività non visibile in GUI | Registry agenti + tab Controllo + Automation |
| `monitor-resources.ps1` throttle | Mutazione priorità processo | Eventi JSONL + log + T1_Delegated |
| `AutoTerminate` (default off) | Terminazione processi | T2_Review events; posture penalty se on |
| Orchestrator subprocess | PPI/fs-integrity in background | Heartbeat JSON + TransparencyReport |
| GUI async workers | Script arbitrari | T0_Observed; command-catalog whitelist |
| Ollama / LLM | Egress + RAM + advisory errata | Disabled Tier C; T2_Review; ADR-0005 |
| Privacy scan | Lettura file sensibili | Read-only, redazione valori |
| Logs in repo | Leak segreti | Security Reviewer pre-push; logs gitignored |

### Gap residui (backlog)

| # | Gap | Priorità | Azione |
|---|-----|----------|--------|
| 1 | Connessioni rete per processo | Alta | Fase 2: sensor `Get-NetTCPConnection` snapshot |
| 2 | Servizi non hub con RAM alta | Media | Estendere catalogo PPI + host playbook |
| 3 | USB / peripheral anomaly | Bassa | Hardware Health Agent |
| 4 | Firmware/UEFI | Bassa | Fuori scope software-only |

### Posture score (TransparencyReport.v1)

100 punti base, penalità:

- RAM libera < 2 GB: −25; < 4 GB: −10
- C: < 10%: −15
- Agenti hub mancanti: −5 ciascuno
- Processi T3 high-RAM: −8 ciascuno (max −30)
- AutoTerminate on: −10
- LLM on su Tier C: −15

---

## Analisi cybersecurity — hardware

| Componente | Nota 7577 | Controllo |
|------------|-----------|-----------|
| RAM 16GB single-channel | Pressione frequente | Tier C feather; PPI raro |
| NVMe C: 256GB | Spesso <10% libero | Alert posture; garbage Safe |
| HDD D: | I/O lento | Scan profondi ridotti |
| i7-7700HQ | Termica laptop | Throttle Safe only |
| WHEA / memoria | Storia bad pages | monitor-whea + fs-integrity |

**Hardware non controllabile via software** (bootkit, DMA) → fuori scope; raccomandazione: BitLocker + Secure Boot verificati in health audit.

---

## Contratto condiviso operatore ↔ AI

Documentato in `DelegationManifest` (report JSON):

### Principi

- Nessuna mutazione OS senza script whitelist + audit
- Operatore può disabilitare qualsiasi agente delegato
- T3 unknown high-RAM → classificare prima di auto-azione
- LLM advisory non auto-applica
- Rollback JSON obbligatorio per write

### Solo operatore umano (default)

- Defender / KEEP services
- Fix Moderate+ / wbadmin / registry
- Terminazione processi fuori policy monitor
- Abilitazione LLM o cloud egress

### Delegato all'AI (quando abilitato in config)

- Orchestrator: context + PPI audit (no auto-apply se `AutoApplySafeActions=false`)
- Monitor: throttle BelowNormal (no terminate se AutoTerminate=false)
- LLM: solo JSON advisory (Fase 1b, Tier B+)

---

## Pannelli UX

### EXE — Tab **Controllo** (v3.7.0)

- Posture score / grade
- Agenti registrati (task state)
- Top RAM con trust T0–T3
- Contratto delega + azioni recenti
- Pulsanti: Refresh, Full Audit, Web Dashboard

### Web — `http://127.0.0.1:8765/`

- Stesso report JSON, layout cognitivamente semplice
- Auto-refresh 30s
- Read-only, localhost only

Avvio:

```powershell
pwsh -File scripts/serve-transparency-dashboard.ps1 -OpenBrowser
```

### Troubleshooting — ERR_CONNECTION_REFUSED (8765)

| Causa | Check rapido | Fix |
|-------|--------------|-----|
| Server non avviato | `Get-NetTCPConnection -LocalPort 8765 -State Listen` | Avvia da GUI tab Controllo → **Web Dashboard** o comando sopra |
| Browser aperto troppo presto (v3.7.0) | `logs/transparency-web.log` | **v3.7.1+** attende porta 25s; aggiorna hub |
| Porta occupata / crash bind | `Get-Content logs/transparency-web.log -Tail 20` | Riavvia; verifica `web/transparency` esiste |
| Health API | `curl http://127.0.0.1:8765/api/health` | Deve restituire `{"status":"ok"}` |

---

## Piano operativo — fasi

### Fase 1 — Completata (v3.7.0)

- [x] TransparencyPolicy.v1 + agent registry
- [x] TransparencyReport.v1 builder
- [x] JSONL events da monitor
- [x] Tab GUI + web dashboard
- [x] Orchestrator integration
- [x] Smoke + ADR-0006

### Fase 2 — Network & service visibility (in corso v3.7.1)

- [x] Snapshot TCP Established/Listen → `Network` in TransparencyReport
- [x] Processi piccoli/nascosti con egress (RAM < 120MB + T3)
- [x] Fix web dashboard ERR_CONNECTION_REFUSED (listener prima del browser)
- [ ] Servizi Windows RAM-heavy nel report
- [ ] Alert desktop opzionale (HITL)

### Fase 3 — Catalog loop

- T3 unknown → proposta entry PPI → approve umano
- Host playbook auto `KB/hosts/<hostname>.md`

### Fase 4 — Enterprise

- Export report firmato
- Integrazione SIEM (JSONL forward)

---

## NBD (Next Best Decision)

1. **Classificare** ogni processo T3 high-RAM visibile nel tab Controllo (aggiungere a `process-intelligence.json`)
2. Installare task orchestrator: `install-orchestrator-task.ps1`
3. Baseline posture 48h; target score ≥ 85 su host lavoro
4. Fase 2 network sensor solo se T3 persistenti non spiegati

---

## Riferimenti

- ADR-0006 Transparency Control Plane
- ADR-0004 PPI
- ADR-0005 LLM advisory
- `KB/continuous-optimization-resource-budget.md`
- `docs/agents/transparency-guardian.md`
