# Bugs Fixed

## 2026-04-16 - EXE Runtime Stabilization

### Bug 1
- Sintomo: errore all'avvio EXE "Impossibile associare l'argomento al parametro 'Path' perche e nullo".
- Causa: in EXE, `$MyInvocation.MyCommand.Path` puo risultare nullo; la GUI usava `Split-Path` senza fallback.
- Fix applicato: introdotto `Resolve-BaseDirectory` con fallback ordinati (`$PSScriptRoot`, `$MyInvocation`, `AppDomain.BaseDirectory`, `Get-Location`).
- Esito: percorsi `scriptRoot` e `hubRoot` sempre determinati sia in script mode sia in exe mode.

## 2026-04-17 - Improvement Pack: Compute Analyzer + Quick Cleaner

### Improvement 1
- **Obiettivo**: introdurre un analizzatore intelligente delle risorse computazionali spese (CPU/RAM/IO) e un pulitore rapido a basso rischio.
- **Implementazione**:
	- nuovo `scripts/analyze-compute-resources.ps1` con scoring, `DominantPressure` e `Recommendation`.
	- nuovo `scripts/quick-cleanup-safe.ps1` con target safe, retention breve e output JSON.
	- integrazione GUI con pulsanti `Analyze Compute` e `Quick Clean`, esecuzione async, cancel unificato e soft-timeout.
- **Anti-regressione**: single-flight globale tra tutte le operazioni (garbage analysis, cleanup, compute analysis, quick cleanup).
- **Esito**: nuove capability operative disponibili senza blocchi UI e con packaging dist allineato.

### Bug 13
- **Sintomo**: in GUI alcuni run riportavano `output JSON was not found` e, in casi intermittenti, `process exit code 1` senza causa diagnostica utile.
- **Causa radice**: hand-off worker->UI troppo immediato (race su disponibilita file output) e assenza di cattura strutturata stderr/stdout nei processi background.
- **Fix applicato**:
	- attesa deterministica output con retry (`Wait-ForOutputFile`) su analyzer/cleanup/compute/quick-clean,
	- redirect standard output/error a file dedicati per ogni worker,
	- messaggio status arricchito con tail stderr quando `ExitCode != 0`.
- **Esito**: ridotte race-condition su output JSON e diagnosi immediata quando un worker fallisce.

### Improvement 2
- **Obiettivo**: velocizzare diagnosi operativa post-failure e ridurre accumulo log.
- **Implementazione**:
	- aggiunto pulsante `Open Diagnostics` in dashboard,
	- snapshot diagnostico (`logs/diagnostics/diagnostics-<timestamp>.txt`) con status recente + tail log worker,
	- retention automatica log testuali configurabile (`Gui.DiagnosticRetentionDays`).
- **Esito**: troubleshooting one-click e footprint log più controllato nel tempo.

### Bug 14
- **Sintomo**: `Analyzer process ended with exit code ...` con errore `A positional parameter cannot be found that accepts argument 'D'` e cleanup con `exit code` vuoto in status.
- **Causa radice**:
	- invocazione CLI di `-Drives C D` tramite `Start-Process` non garantiva binding array corretto nello script target,
	- lettura `ExitCode` non sempre valorizzata al momento del log.
- **Fix applicato**:
	- passaggio drives come token singolo `-Drives C,D` + normalizzazione robusta in `analyze-garbage-hotspots.ps1` (split comma/spazi/semicolon),
	- introdotta funzione `Get-ProcessExitCodeSafe` per reporting deterministico (fallback `-1`).
- **Esito**: analyzer avvia correttamente con output CSV creato e log exit code sempre valorizzato.

### Bug 2
- Sintomo: errori multipli durante azioni dashboard (analyze/cleanup/install) in ambienti con runtime non risolto.
- Causa: invocazioni dirette `& powershell ...` senza resolver centralizzato e senza gestione errori uniforme.
- Fix applicato: introdotto `Invoke-ChildPowerShell` con risoluzione runtime (`pwsh` preferito, fallback `powershell`) e blocchi try/catch nelle azioni principali GUI.
- Esito: errori non bloccanti visualizzati nello status panel, niente crash immediato della UI.

### Bug 3
- Sintomo: in modalita EXE, analisi garbage non affidabile su drive list.
- Causa: parametro `-Drives` passato come stringa unica in arg array.
- Fix applicato: passaggio argomenti separati (`-Drives C D`).
- Esito: analyzer riceve correttamente array drive.

### Bug 4
- Sintomo: dopo rebuild EXE, parte delle funzioni risultava ancora incoerente in dist.
- Causa: `package-suite.ps1` usava sorgenti hardcoded da `C:\scripts` invece dell'hub attivo.
- Fix applicato: packaging reso hub-relative (`active/scripts`, `active/config`) con default output `C:/SystemOptimizerHub/active/dist/WindowsOptimizer`.
- Esito: script distribuiti allineati ai fix runtime dell'EXE.

### Bug 5
- Sintomo: da launcher/shortcut la GUI non partiva o partiva una versione non aggiornata.
- Causa: `run-gui.bat` e default di `build-gui-exe.ps1` puntavano ai vecchi path `C:\dist` / `C:\scripts`.
- Fix applicato: riallineati i default a `C:/SystemOptimizerHub/active/...` e mantenuta copia compatibile su `C:/dist/WindowsOptimizer`.
- Esito: avvio valido sia da path Active sia da path legacy.

### Bug 6
- Sintomo: rebuild EXE falliva con `Access denied` su `WindowsOptimizer.exe`.
- Causa: processo EXE ancora in esecuzione durante la compilazione (file lock).
- Fix applicato: procedura deterministica pre-build con stop process `WindowsOptimizer` prima della rigenerazione.
- Esito: build completata e binari aggiornati su entrambe le destinazioni.

### Verifica finale (2026-04-16)
- GUI script lint: nessun errore.
- EXE rigenerato: `C:/SystemOptimizerHub/active/dist/WindowsOptimizer/WindowsOptimizer.exe`.
- Build metadata: size 49152, timestamp 2026-04-16 18:07:20.

---

## 2026-04-17 - EXE avvia ma finestra non compare al doppio click

### Bug 7
- **Sintomo**: doppio click sull'EXE non produce nessuna finestra visibile, nessun messaggio di errore.
- **Causa radice**: nella versione precedente, `Run-GarbageAnalysis` veniva invocata **sincrona e prima** di `$form.ShowDialog()`. Quella funzione lancia un processo figlio `pwsh -File analyze-garbage-hotspots.ps1` che scansiona i drive e impiega decine di secondi; la finestra non veniva mai mostrata durante tutta quella durata (ShowDialog non era ancora stato chiamato).
- **Fix applicato**: rimosso il triplo blocco sincrono di avvio ed agganciato tramite evento `$form.Add_Shown({...})`. La sequenza corretta è ora: ShowDialog apre e renderizza la finestra → evento Shown si innesca → Refresh-Drives e Reload-Tasks (veloci) → Run-GarbageAnalysis (lenta ma la finestra è già visibile).
- **Codice prima**: `Refresh-Drives; Reload-Tasks; Run-GarbageAnalysis; [void]$form.ShowDialog()`
- **Codice dopo**: `$form.Add_Shown({ Refresh-Drives; Reload-Tasks; Run-GarbageAnalysis }); [void]$form.ShowDialog()`
- **Esito**: finestra appare immediatamente al doppio click; analisi garbage parte visibilmente con status "Analyzing..." nel panel.
- **EXE rigenerato**: size 49152, timestamp 2026-04-17 09:44:34.

### Cleanup legacy folders
- **Rimosso**: `C:\scripts` (fonti originali pre-hub, superate da `C:\SystemOptimizerHub\active\scripts`)
- **Rimosso**: `C:\dist` (pacchetto output pre-hub, superato da `C:\SystemOptimizerHub\active\dist`)
- **Rimosso**: `C:\SystemOptimizerHub\session-20260416-164154` (snapshot sessione originale, consolidato in `active`)

## 2026-04-17 - UI freeze prolungato in startup/dashboard

### Bug 8
- **Sintomo**: finestra apparentemente "stuck" per lungo tempo all'avvio e durante analisi garbage.
- **Causa radice**: `Run-GarbageAnalysis` eseguita in modo sincrono nel thread UI; la scansione dischi bloccava il message loop di WinForms.
- **Fix applicato**: analisi resa asincrona con processo background (`Start-Process` su `pwsh`) + polling tramite `System.Windows.Forms.Timer` (`Poll-GarbageAnalysis`).
- **Hardening anti-regressione**: lock di UI actions (`Analyze/Audit/Execute`) mentre l'analisi e in corso; prevenzione doppio avvio con check su processo attivo.
- **Esito**: finestra resta responsiva; apertura immediata, risultati caricati a completamento senza blocco interfaccia.
- **Build verificata**: `C:/SystemOptimizerHub/active/dist/WindowsOptimizer/WindowsOptimizer.exe`, size 51712, timestamp 2026-04-17 10:19:41.

### Bug 9
- **Sintomo**: UI non bloccata ma percezione di lentezza/stallo durante analisi lunga (assenza di feedback operativo continuo).
- **Causa radice**: mancavano stato progresso, timeout osservabile e controllo di cancellazione manuale.
- **Fix applicato**:
	- progress indicator con tempo trascorso vs target per Depth,
	- soft-timeout warning (senza kill forzato),
	- pulsante cancel con stop controllato,
	- gate centralizzato stato UI (`Set-AnalysisUiState`) e reset unico (`Stop-GarbageAnalysis`).
- **Esito**: UX deterministica e prevedibile; operatore vede sempre stato analisi e puo interrompere senza regressioni.

### Bug 10
- **Sintomo**: startup ancora percepito come pesante in alcuni scenari (analisi automatica con parametri non ottimizzati per il primo avvio).
- **Causa radice**: assenza di profilo startup configurabile separato dai parametri operativi standard.
- **Fix applicato**: introdotta configurazione GUI in `config/sys-maintenance.json` con chiavi:
	- `Gui.AutoAnalyzeOnStartup`
	- `Gui.DefaultAnalyzeDepth`
	- `Gui.DefaultAnalyzeTop`
	e lettura robusta in GUI con fallback sicuri (`true`, `Quick`, `15`).
- **Esito**: startup budget-aware, comportamento deterministico e modulabile senza cambiare codice.

### Bug 11
- **Sintomo**: durante `Audit Cleanup` la GUI diventava unresponsive.
- **Causa radice**: cleanup/audit eseguito in modo sincrono nel thread UI tramite invocazione diretta PowerShell.
- **Fix applicato**:
	- cleanup reso asincrono con processo background + polling timer,
	- progress/elapsed + soft-timeout warning (no stop automatico aggressivo),
	- cancel manuale unificato (`Cancel Operation`) anche per cleanup,
	- output deterministico su JSON (`-OutputJson`) per hand-off robusto worker->UI.
- **Esito**: UI resta responsiva durante audit/execute; nessun freeze del frontend.
- **Build verificata**: `C:/SystemOptimizerHub/active/dist/WindowsOptimizer/WindowsOptimizer.exe`, size 65024, timestamp 2026-04-17 10:34:59.

### Bug 12
- **Sintomo**: popup con errori parser multipli su `Poll-CleanupOperation` (token imprevisto, blocchi Try/Catch non chiusi).
- **Causa radice**: uso di continuazione riga non valida (`\`) in espressione PowerShell con operatore `-f` durante composizione messaggio status.
- **Fix applicato**: ristrutturata la formattazione in variabile intermedia (`$cleanupSummary`) + `Append-Status $cleanupSummary`, eliminando la continuazione non supportata.
- **Esito**: parsing clean, nessun errore di compilazione/esecuzione all'avvio GUI.

### Bug 15 — Exit code -1 su tutti i worker
- **Sintomo**: ogni operazione (Analyze Garbage, Cleanup, Compute, Quick Clean) riporta `exit code -1` nonostante script completati con output valido.
- **Causa radice (A — psHost shim)**: `Get-Command pwsh` risolveva al file 0-byte AppExecution alias (`AppData\Local\Microsoft\WindowsApps\pwsh.exe`). `Start-Process -PassThru` su questo shim non traccia il processo reale: `.ExitCode` non leggibile.
- **Causa radice (B — -f parser in @())**: nei worker Compute e QuickCleanup, l'operatore `-f` dentro array `@()` consumava gli elementi successivi (comma-separated) come argomenti format. Risultato: array collassato a stringa singola con `-Top`, `-OutputJson` persi.
- **Fix applicato**:
  1. `Resolve-PowerShellHost`: rileva shim 0-byte, cerca real `pwsh.exe` in `Program Files\PowerShell\*` e `Program Files\WindowsApps\Microsoft.PowerShell_*`.
  2. `Get-ProcessExitCodeSafe`: `HasExited` guard + `WaitForExit()` prima di leggere `ExitCode` (flush handle).
  3. Array compute/quick-cleanup: variabile intermedia (`$durationStr`, `$topStr`, `$retDaysStr`, `$maxFilesStr`) al posto di `"{0}" -f $var` inline.
- **Esito**: tutti e 4 i worker EXIT=0, output JSON/CSV presenti, shim aggirato deterministicamente.

### Bug 16 — Logs tab non funzionante
- **Sintomo**: tab Logs vuoto, nessun contenuto visualizzabile.
- **Causa radice**: il tab leggeva solo `storage-cleanup.log` (percorso che non esiste nel contesto dist/EXE). Nessuna visibilità sui log dei 4 worker.
- **Fix applicato**: sostituito con combo box multi-sorgente (10 log source: stdout/stderr di ogni worker + quick-cleanup.log + storage-cleanup.log) e bottone "Load Last 200 Lines".
- **Esito**: tab Logs funzionale con selezione sorgente e contenuto visibile.
