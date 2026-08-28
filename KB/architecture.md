# Architecture - Windows Optimizer Hub

## Scope
Workspace operativo globale su C, D e sistema operativo, con profilo centralizzato nel clone Git (path portabile; es. `D:/SystemOptimizerHub/active`).

## Componenti principali

### Runtime condiviso
- `scripts/hub-common.ps1` — hub root, config JSON, event log health, `Test-HubAdmin` / `Assert-HubAdmin`.
- `scripts/hub-orchestrator.ps1` — heartbeat, log rotation, trigger WHEA/fs-integrity.
- `config/sys-maintenance.json` — Monitor, Cleanup, Whea, Orchestrator, FsIntegrity, **ProcessPressure**, **Gui**, **Privacy**.
- `config/locale/{en,it}.json` + `config/command-catalog.json` — i18n e help comandi GUI.

### Monitor e storage
- `scripts/monitor-resources.ps1` — monitor processi CPU/RAM + priorita.
- `scripts/fs-integrity.ps1` — scan-only integrita filesystem (non ripara con `-Execute`).
- `scripts/cleanup-storage-safe.ps1` — Safe/Radical + AuditDepth/AuditLevel.
- `scripts/quick-cleanup-safe.ps1` — target sicuri, retention breve.
- `scripts/analyze-garbage-hotspots.ps1` — ranking cartelle reclaim-prone.
- `scripts/analyze-compute-resources.ps1` — legacy wrapper compute score.
- `scripts/analyze-process-pressure.ps1` — Process Pressure Intelligence (`ProcessPressureReport.v1`).
- `scripts/apply-process-pressure-safe.ps1` — safe apply + rollback JSON.
- `scripts/lib/process-pressure-core.ps1` + `config/process-intelligence.json` — catalog scoring/classification.
- `scripts/linux/analyze-process-pressure.sh` + `scripts/package-linux-suite.ps1` → `dist/LinuxOptimizer`.

### Salute e remediation
- `scripts/system-health-audit.ps1` — findings JSON (`AlreadyOptimized` = **array di stringhe**).
- `scripts/apply-safe-fixes.ps1` — **una** soluzione per finding ≤ MaxLevel.
- `scripts/repair-office-m365-channel.ps1` / `scripts/repair-wsl-config.ps1` — fix mirati con rollback JSON.

### Privacy
- `scripts/privacy-scan-secrets.ps1` — read-only, report redatti `PrivacyScanReport.v1`.

### GUI v3.1.3
- `scripts/system-optimizer-gui.ps1` — shell WinForms (layout, worker wiring, tabs).
- `scripts/gui/theme.ps1` — palette Obsidian, font, `New-Btn`, `Format-AlreadyOptimizedLog`.
- `scripts/gui/worker-helpers.ps1` — Wait-ForOutputFile, exit/err tail.
- `scripts/gui/i18n.ps1` / `command-help.ps1` — lingua + pannello "Cosa fa".
- `scripts/gui/keep-service-wizard.ps1` — HITL wizard KEEP extreme apply (Defender).

### Install / package / gate
- `scripts/install-*-task.ps1`, `ensure-powershell-core.ps1`, `activate-hub-profile.ps1`.
- `scripts/package-suite.ps1` → `dist/WindowsOptimizer` (subset + BOM).
- `scripts/test-hub-smoke.ps1` — gate health + garbage + privacy + process-pressure + moduli gui.

### Lab / campagne (spesso fuori dist)
- NVMe writeoffload, WHEA monitor/KPI, kernel/bloatware/eventlog tuners, DD-WRT scripts.

## Flussi
1. Osservazione: analyzer produce ranking con score e recommendation (High/Medium/Low).
2. Decisione: utente seleziona criteri (Depth, FileLevel/BitLevel, CleanupMode) o avvia analisi compute.
3. Audit: cleanup in modalita audit senza cancellazione.
4. Esecuzione: cleanup in modalita execute con policy selezionata o quick cleanup safe.
5. Validazione: confronto metriche pre/post e log persistente + output JSON deterministico worker->UI.
6. Salute: audit JSON → review in GUI → apply selettivo (mai auto-apply dai CTA primari).
7. Privacy: scan read-only → findings redatti (vault = Fase 2).

## Explorer Intelligence
Per ogni cartella candidata:
- Category: Temp, Cache, Log, Recycle, Browser, SystemUpdate, Virtualization, Downloads, Other.
- Provenance: Windows, UserProfile, Browser, IIS, Virtualization, Application.
- DominantType: Transient, Archive, InstallerBinary, VirtualDisk, Media, Mixed.
- Score: peso categoria + rapporto stale + rapporto file transient + reclaim stimato.

## Modalita criteri
- AuditDepth:
  - Quick: scansione rapida, limite file per target basso.
  - Standard: bilanciata.
  - Deep: alta copertura, overhead maggiore.
- AuditLevel:
  - FileLevel: stima su dimensione logica file.
  - BitLevel: stima su allocazione cluster (piu precisa su spazio fisico).
- CleanupMode:
  - Safe: retention conservativa, target a basso rischio.
  - Radical: retention piu stretta e target aggiuntivi controllati.

## Guardrail anti-regressione
- Audit-first prima di execute.
- Nessuna cancellazione fuori target noti senza whitelist esplicita.
- Logging obbligatorio su logs/storage-cleanup.log.
- Task always-on vincolati a runtime pwsh Core.
- Smoke gate: `scripts/test-hub-smoke.ps1` prima di package/push significativi.
- Piano refactor: [`docs/product/REFACTORING-PLAN-ELITE.md`](../docs/product/REFACTORING-PLAN-ELITE.md).

## Stability Patterns riusabili

### 1) UI Busy State Gate (riuso per ogni task lungo)
- Pattern: funzione unica di stato (`Set-AnalysisUiState`) che abilita/disabilita controlli in modo coerente.
- Obiettivo: evitare race condition tra Analyze/Audit/Execute e input utente durante operazioni lunghe.
- Regola: mai togglare pulsanti in punti sparsi; usare solo il gate centralizzato.

### 2) Async Worker + Polling Timer (non-blocking)
- Pattern: avvio task pesanti in processo background (`Start-Process`) + polling con `System.Windows.Forms.Timer`.
- Obiettivo: mantenere il message loop WinForms sempre responsivo.
- Regola: nessuna scansione dischi o cleanup costoso sul thread UI.
- Evoluzione: consolidare in `scripts/gui/async-worker.ps1` (Onda 1 del piano elite).

### 3) Soft Timeout Observability (no kill aggressivo)
- Pattern: timeout atteso per profilo (`Quick/Standard/Deep`) con warning informativo se superato.
- Obiettivo: segnalare anomalie senza introdurre regressioni da terminazioni forzate automatiche.
- Regola: superato il tempo atteso -> warning + opzione di cancel manuale.

### 4) Controlled Cancellation
- Pattern: `Stop-GarbageAnalysis` come unico punto di arresto, con reset completo stato (`process`, `timer`, `progress`, `flags`).
- Obiettivo: garantire rollback UI consistente dopo stop/cancel/error.
- Regola: mai fermare processi in modo diretto fuori dalla funzione di stop centralizzata.

### 5) Deterministic Result Hand-off
- Pattern: worker produce output file (`-OutputCsv`), UI importa risultati solo a task terminato.
- Obiettivo: separare chiaramente compute plane e UI plane.
- Regola: nessun binding diretto live a stream/pipe di processo pesante.

### 6) Single-flight Protection
- Pattern: prima di nuovo avvio, check su processo attivo e rifiuto esplicito doppia analisi.
- Obiettivo: prevenire sovrapposizione scansioni e contention su output/log.
- Regola: massimo 1 analisi garbage alla volta.

### 7) Startup Budget Profile (config-driven)
- Pattern: profilo startup configurabile (`Gui.AutoAnalyzeOnStartup`, `Gui.DefaultAnalyzeDepth`, `Gui.DefaultAnalyzeTop`) caricato da `config/sys-maintenance.json`.
- Obiettivo: UI pronta subito; scan solo su richiesta (o opt-in Settings).
- **Default prodotto (v3.1.2+): `AutoAnalyzeOnStartup=false`**, `Depth=Quick`, `Top=15`.
- Se abilitato: avvio scan **ritardato** (~600ms) dopo `Shown`, non durante costruzione form.
- Fallback codice se config assente: Quick/15/**auto-off**.

### 8) Async Cleanup Worker (UI-safe)
- Pattern: cleanup/audit sempre in worker process + polling timer UI, mai sincrono sul thread grafico.
- Obiettivo: evitare unresponsive durante operazioni I/O intensive.
- Hand-off risultati: file JSON (`-OutputJson`) letto solo a completamento processo.
- Guardrail: single-flight, cancel controllato, soft-timeout osservabile, nessuna terminazione automatica aggressiva.

### 9) PowerShell Formatting Safety (anti-parser)
- Pattern: evitare continuazioni riga con `\` in espressioni PowerShell complesse (specialmente con `-f`).
- Obiettivo: prevenire errori parser a cascata in blocchi `try/catch`.
- Regola: costruire stringhe complesse in variabile intermedia e poi invocare output (`Append-Status $msg`).

### 10) Intelligent Compute Scoring
- Pattern: score processo combinando CPU delta campionata, working set e throughput IO in una finestra temporale breve.
- Obiettivo: identificare in modo stabile i processi che consumano risorse in modo non sostenibile.
- Regola: esporre sempre `DominantPressure` e `Recommendation` (ThrottlePriority/InvestigateMemory/CheckDiskContention/Observe/Normal).

### 11) Quick Cleaner Safe Envelope
- Pattern: quick cleanup confinato a target sicuri (temp/cache/log) con retention breve e limiti file per target.
- Obiettivo: recupero rapido spazio e reattivita senza introdurre rischio di regressione operativa.
- Regola: supportare audit/execute, output JSON deterministico e stop manuale lato GUI.

### 12) Worker Output Handshake + Diagnostics
- Pattern: ogni worker background deve produrre output file deterministico e stream di diagnostica separati (stdout/stderr).
- Helper: `scripts/gui/worker-helpers.ps1` (`Wait-ForOutputFile`, `Get-WorkerErrorTail`, `Get-ProcessExitCodeSafe`).
- Regola:
  - attesa output con retry a timeout breve,
  - su exit code != 0 riportare tail stderr in UI,
  - cleanup pre-run dei file output/err precedenti.

### 13) One-click Diagnostic Bundle + Log Retention
- Pattern: pulsante UI dedicato che genera snapshot testuale con stato corrente + tail log worker e apre cartella diagnostica.
- Obiettivo: ridurre MTTR nelle analisi incident senza ricerca manuale file.
- Regola: retention automatica dei log testuali (`.log`, `.txt`) con finestra configurabile (`Gui.DiagnosticRetentionDays`) all'avvio GUI.

### 14) CLI Array-Binding Safety for Start-Process
- Pattern: per parametri array passati a script via `Start-Process`, preferire token singolo delimitato (`C,D`) e normalizzare lato script.
- Obiettivo: prevenire errori di binding posizionale (`argument 'D'`) dovuti a parsing command-line ambiguo.
- Regola: introdurre normalizzazione input all'inizio script e non assumere che `-Param A B` venga sempre bindato come array.

### 15) PowerShell Host Resolution — Shim Detection
- Pattern: `Resolve-PowerShellHost` verifica che `Get-Command pwsh` non punti a 0-byte AppExecution alias in `WindowsApps`.
- Obiettivo: garantire che `Start-Process -PassThru` tracci il processo reale con exit code leggibile.
- Regola: se candidato è 0 byte, cercare `pwsh.exe` in `Program Files\PowerShell\*` e `Program Files\WindowsApps\Microsoft.PowerShell_*`, ordinati per data.

### 16) Format Operator `-f` — Mai dentro array literal @()
- Pattern: `"{0}" -f $var` dentro `@(...)` è un bug: `-f` consuma tutti gli elementi comma-separated come argomenti format, collassando l'array.
- Obiettivo: preservare integrità degli array argomento per `Start-Process`.
- Regola: estrarre sempre la conversione in variabile intermedia (`$str = "$($var)"`) prima dell'array literal.

### 17) Logs Tab Multi-Source
- Pattern: combo box con elenco fisso di log source (stdout/stderr per worker + log file) + bottone Load Last N.
- Obiettivo: rendere visibile e ispezionabile ogni output dei worker senza accesso file system manuale.
- Regola: aggiornare la mappa `$logMap` quando si aggiungono nuovi worker.

### 18) Modular GUI theme (v3.1.3+)
- Pattern: palette/font/`New-Btn` in `scripts/gui/theme.ps1` dot-sourced all'avvio.
- Obiettivo: ridurre monolite e allineare ROADMAP 1.5.
- Regola: se `theme.ps1` manca, GUI fallisce early con messaggio chiaro (no silent fallback spezzato).

## Packaging e distribuzione
- Dist principale: `dist/WindowsOptimizer` (generato da `package-suite.ps1`, **non** editare a mano).
- Source of truth: `scripts/` + `config/` sul clone portabile (es. `D:/SystemOptimizerHub/active`).
- GUI eseguibile opzionale: `WindowsOptimizer.exe` (ps2exe); Fase 3 prevede launcher stub.
- Installazione/rimozione: `scripts/install-suite.ps1`, `scripts/uninstall-suite.ps1`.
- Piano refactor elite: [`docs/product/REFACTORING-PLAN-ELITE.md`](../docs/product/REFACTORING-PLAN-ELITE.md).
- Snapshot salute codice: [`KB/codebase-health.md`](codebase-health.md).
