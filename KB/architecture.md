# Architecture - Windows Optimizer Hub

## Scope
Workspace operativo globale su C, D e sistema operativo, con profilo centralizzato in C:/SystemOptimizerHub/active.

## Componenti principali
- scripts/monitor-resources.ps1: monitor sempre attivo processi CPU/RAM + handling priorita.
- scripts/cleanup-storage-safe.ps1: cleanup con modalita Safe/Radical e criteri AuditDepth/AuditLevel.
- scripts/quick-cleanup-safe.ps1: pulitore rapido a basso rischio con target sicuri e retention breve.
- scripts/analyze-garbage-hotspots.ps1: ranking statistico cartelle garbage-prone con classificazione.
- scripts/analyze-compute-resources.ps1: analizzatore intelligente di spesa computazionale per processo (CPU/RAM/IO) con score e raccomandazioni.
- scripts/system-optimizer-gui.ps1: dashboard UI con explorer evidenziato e controlli intelligenti.
- scripts/install-monitor-task.ps1: registrazione task monitor startup.
- scripts/install-cleanup-task.ps1: registrazione task cleanup giornaliero.
- scripts/ensure-powershell-core.ps1: bootstrap/validazione pwsh e applicazione task Core-only.
- scripts/activate-hub-profile.ps1: attivazione profilo centralizzato e rebinding percorsi task.

## Flussi
1. Osservazione: analyzer produce ranking con score e recommendation (High/Medium/Low).
2. Decisione: utente seleziona criteri (Depth, FileLevel/BitLevel, CleanupMode) o avvia analisi compute.
3. Audit: cleanup in modalita audit senza cancellazione.
4. Esecuzione: cleanup in modalita execute con policy selezionata o quick cleanup safe.
5. Validazione: confronto metriche pre/post e log persistente + output JSON deterministico worker->UI.

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

## Stability Patterns riusabili

### 1) UI Busy State Gate (riuso per ogni task lungo)
- Pattern: funzione unica di stato (`Set-AnalysisUiState`) che abilita/disabilita controlli in modo coerente.
- Obiettivo: evitare race condition tra Analyze/Audit/Execute e input utente durante operazioni lunghe.
- Regola: mai togglare pulsanti in punti sparsi; usare solo il gate centralizzato.

### 2) Async Worker + Polling Timer (non-blocking)
- Pattern: avvio task pesanti in processo background (`Start-Process`) + polling con `System.Windows.Forms.Timer`.
- Obiettivo: mantenere il message loop WinForms sempre responsivo.
- Regola: nessuna scansione dischi o cleanup costoso sul thread UI.

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
- Obiettivo: ridurre overhead iniziale mantenendo osservabilita e controllo.
- Default consigliato: `AutoAnalyzeOnStartup=true`, `Depth=Quick`, `Top=15`.
- Fallback: se config assente/non valida, usare default sicuri nel codice (Quick/15/auto-on).

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

## Packaging e distribuzione
- Dist principale: dist/WindowsOptimizer.
- GUI eseguibile: dist/WindowsOptimizer/WindowsOptimizer.exe.
- Installazione/rimozione: scripts/install-suite.ps1, scripts/uninstall-suite.ps1.
- Versioning locale sicuro: repo Git in C:/SystemOptimizerHub/active con .gitignore hardening.
