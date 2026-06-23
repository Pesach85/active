# Bugs Fixed

## 2026-06-23 - WSL bloccato: comandi wsl.exe in hang con 100+ processi zombie

### Bug 23
- **Sintomo**: `wsl --status`, `wsl -l -v` e qualsiasi invocazione `wsl.exe` restavano appesi a tempo indefinito; si accumulavano decine/centinaia di processi `wsl.exe` zombie (rilevati 110+).
- **Causa radice deterministica**: `HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss\DefaultDistribution` puntava al GUID `{c2e180ed-6669-4deb-8bdb-df1bf5db2188}` (kali-linux) con metadati completi in HKCU, ma la stessa chiave distro era **assente** in `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Lxss`. `WslService` enumera le distro da HKLM → IPC bloccata → ogni client `wsl.exe` resta in attesa.
- **Fattore aggravante**: tentativi di `Restart-Service WslService` con client appesi lasciavano il servizio in `STOP_PENDING`; recovery corretto = terminare `wslservice.exe` + `sc start WslService` (mai `Restart-Service` con client zombie attivi).
- **Fix applicato**:
	- aggiunto `scripts/repair-wsl-config.ps1` con assessment JSON, apply safe (mirror HKCU→HKLM, cleanup zombie, recovery servizio), backup/rollback `-RestoreLatest`, probe con timeout;
	- esteso `scripts/system-health-audit.ps1` con finding `WSL-CONFIG-001`;
	- aggiornato `scripts/package-suite.ps1` per distribuire il nuovo script in `dist/WindowsOptimizer/scripts`.
- **Check anti-regressione**:
	- pre-fix: `wsl -l -v` timeout >30s, 110 processi `wsl.exe`, GUID default assente in HKLM;
	- post-fix manuale+script: `Status=Ready`, `HklmDistroExists=true`, `ZombieWslCount=0`, `wsl -l -v` exit 0 in <2s, distro `kali-linux` visibile;
	- apply idempotente: nessuna modifica distruttiva (no unregister, no hypervisor/bcdedit).
- **Criteri riusabili**:
	- se `wsl.exe` hang + molti processi `wsl` in Task Manager, verificare prima desync HKCU/HKLM prima di reinstallare WSL;
	- non usare `Restart-Service WslService` con client zombie: kill `wsl`/`wslservice` + `sc start`;
	- validazione health con probe bounded (`wsl -l -v`), launch test (`-ValidateLaunch`) solo opzionale post-reboot;
	- non disinstallare distro store come prima mossa.
- **Esito**: WSL torna responsivo per listing/comandi base; rollback in `logs/diagnostics/wsl-config-backup-latest.json`. NB: il fix registry sblocca il listing ma NON l'avvio della distro — vedi Bug 24 per la causa del boot bloccato.

## 2026-06-23 - WSL2: listing OK ma boot distro (`wsl -d`) in hang infinito

### Bug 24
- **Sintomo**: dopo il fix registry (Bug 23) `wsl -l -v` rispondeva in <2s, ma `wsl -d kali-linux -- echo` e `wsl --status` restavano appesi a tempo indefinito (timeout 30-60s ripetuti), lasciando `vmwp` attivo. La GUI Health Audit andava in stall.
- **Causa radice deterministica**: `bcdedit /enum {current}` → `hypervisorlaunchtype = Off`. WSL2 richiede l'**hypervisor Hyper-V avviato al boot** per la sua utility VM. Con `Off`:
	- `wsl -l -v` funziona (legge solo registry via WslService);
	- `wsl -d <distro>` (che deve avviare la VM WSL2) si blocca all'infinito perché l'hypervisor non è caricato.
	- Aggravante: settare `Auto` senza riavvio mette WSL in stato half-broken (anche il listing va in timeout) finché non si riavvia.
- **Contesto/no-regressione**: `Microsoft-Windows-Subsystem-Linux=Disabled` (OK, è WSL Store 2.6.3.0 che usa solo `VirtualMachinePlatform=Enabled`); VMware Workstation **17.0.2** supporta Windows Hypervisor Platform (WHP) → coesiste con Hyper-V abilitato senza regressioni; Secure Boot **False** → `bcdedit /set` consentito (il vecchio blocco Secure Boot per `truncatememory` non si applica qui).
- **Fix applicato**:
	- esteso `scripts/repair-wsl-config.ps1`: rileva `hypervisorlaunchtype`, in `-Apply` esegue `bcdedit /set hypervisorlaunchtype Auto` con backup del valore precedente per `-RestoreLatest`;
	- marker reboot deterministico (`logs/diagnostics/wsl-hypervisor-reboot-pending.json`) basato su boot time in **ticks Int64** (immune a coercizione data di `ConvertFrom-Json` e culture it-IT); lo stato passa a `PendingReboot` finché non si riavvia;
	- probe `wsl` gated: saltate quando hypervisor `Off` o reboot pending → l'assessment resta **<2s** e non va mai in hang;
	- finding `WSL-CONFIG-001` aggiornato per coprire la causa hypervisor.
- **Bug minore risolto**: il marker iniziale salvava il boot time come stringa ISO; `ConvertFrom-Json` la convertiva in `[datetime]` e il re-parse in cultura it-IT falliva (`06/23/2026` → mese 23 invalido), facendo fallire silenziosamente il rilevamento reboot. Risolto salvando `BootTimeTicks` (Int64).
- **Check anti-regressione**:
	- pre-fix: `hypervisorlaunchtype=Off`, `wsl -d` timeout, audit stall ~320s;
	- assessment hypervisor `Off`: `Status=Broken` in ~2s (no hang), issue chiara;
	- apply: `bcdedit hypervisorlaunchtype Off -> Auto`, marker scritto, `Status=PendingReboot`, `RebootRecommended=True` in ~2.4s;
	- assessment idempotente post-apply: `PendingReboot` in ~1.7s; subprocess Health Audit WSL in **0.9s** (stall eliminato);
	- VMware 17.0.2 + WHP: nessuna regressione attesa (coesistenza supportata).
- **Criteri riusabili**:
	- se `wsl -l -v` funziona ma `wsl -d`/`--status` si bloccano → controllare SEMPRE `bcdedit /enum {current}` per `hypervisorlaunchtype`; se `Off`, WSL2 non può bootare la VM;
	- `hypervisorlaunchtype` è un setting di boot: la modifica richiede **riavvio obbligatorio** (non attivabile a caldo);
	- prima di abilitare l'hypervisor su un PC con VMware, verificare la versione: VMware ≥15.5.5/17 usa WHP e coesiste; versioni vecchie no;
	- non usare `Get-CimInstance Win32_ComputerSystem` per rilevare l'hypervisor in script (può andare in hang su sistemi degradati): usare il marker boot-time in ticks;
	- nei marker JSON persistenti evitare stringhe data ISO (coercizione `ConvertFrom-Json` + culture): usare ticks Int64 o numeri.
- **Esito**: causa deterministica del boot bloccato risolta; `hypervisorlaunchtype=Auto` applicato con rollback disponibile.
- **Validazione post-reboot (2026-06-23)**:
	- `hypervisorlaunchtype=Auto` attivo dopo reboot;
	- `repair-wsl-config.ps1 -ValidateLaunch`: `Status=Ready`, `ListProbe exit=0`, `LaunchProbe exit=0` output `WSL_OK`, `ZombieWslCount=0`, `HypervisorRebootPending=false`;
	- tempo assessment completo: ~7.6s (listing + boot distro kali-linux WSL2);
	- report: `logs/diagnostics/wsl-post-reboot-validation.json`.

## 2026-04-20 - Office bloccato da canale perpetuo incompatibile

### Bug 22
- **Sintomo**: installazione Office bloccata da `Questo prodotto non puo essere installato con il canale di aggiornamento selezionato (Office 365)`.
- **Causa radice**: policy locale `HKLM\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate\UpdateBranch=PerpetualVL2021`, incompatibile con licenze Microsoft 365 Apps come Microsoft 365 Business Standard.
- **Fix applicato**:
	- aggiunto `scripts/repair-office-m365-channel.ps1` con assessment, apply safe, backup JSON e rollback `-RestoreLatest`;
	- esteso `scripts/system-health-audit.ps1` con finding `OFFICE-CHANNEL-001` e proposta fix compatibile con Microsoft 365 Apps;
	- aggiornato `scripts/package-suite.ps1` per distribuire il nuovo script anche in `dist/WindowsOptimizer/scripts`.
- **Check anti-regressione**:
	- parser/check errori: `0` su `repair-office-m365-channel.ps1`, `system-health-audit.ps1`, `package-suite.ps1`;
	- pre-fix assessment: `Status=Mismatch`, `ConfiguredBranches=PerpetualVL2021`, `ClickToRun=NotInstalled`;
	- post-fix assessment: `Status=Ready`, `HKLM/HKCU UpdateBranch=MonthlyEnterprise`;
	- post-fix Health Audit: findings totali `7 -> 6`, `AlreadyOptimized 7 -> 8`, con voce positiva `Office channel aligned for Microsoft 365 Apps (MonthlyEnterprise)`.
- **Criteri riusabili**:
	- per licenze Microsoft 365 Apps usare solo `Current`, `MonthlyEnterprise`, `SemiAnnualEnterprise`;
	- quando un blocco installativo deriva da policy Office, applicare prima un fix di branch con backup/rollback e solo dopo rilanciare setup/update;
	- integrare i fix di compatibilita software nel motore Health Audit invece di aggiungere UI dedicata, se la GUI gia renderizza findings/solutions generici.
- **Esito**: sistema riallineato a canale supportato per Microsoft 365 Business Standard con rollback disponibile in `logs/diagnostics/office-channel-backup-latest.json`.

## 2026-04-20 - Deep Scan parse failed: "Tipi di argomento non corrispondenti"

### Bug 21
- **Sintomo**: ogni Deep Scan completava il worker in background ma la GUI riportava `Deep Scan completed in ... but parse failed: Tipi di argomento non corrispondenti`.
- **Causa radice**: in `Get-DeepScanFilteredFindings` il return usava `return @($result)` dove `$result` era `System.Collections.Generic.List[object]`. In questo contesto WinForms/PowerShell il wrapping con `@()` generava errore runtime `Argument types do not match` (repro deterministico), interrompendo il blocco try di `Poll-DeepScan`.
- **Fix applicato**:
	- sostituito `return @($result)` con `return $result.ToArray()`;
	- aggiunto `[void]` su `$result.Add(...)` per evitare output impliciti nel pipeline di funzione.
	- fix applicato sia in `scripts/system-optimizer-gui.ps1` sia nella copia `dist/WindowsOptimizer/scripts/system-optimizer-gui.ps1`.
- **Check anti-regressione**:
	- parser GUI script: `parserErrors=0` su source e dist;
	- rebuild EXE: output generato in `dist/WindowsOptimizer/WindowsOptimizer.exe`;
	- smoke test post-build: GUI `AliveAfter6s=True`.
- **Criteri riusabili**:
	- nelle funzioni PowerShell che restituiscono collezioni per binding UI, evitare `@($genericList)` e preferire `ToArray()`;
	- sopprimere sempre il valore di ritorno di `.Add()` (`[void]` o `$null =`) nelle funzioni che devono restituire solo il payload finale;
	- per flussi parser+rendering, separare output dati da side-effects UI e mantenere return shape strettamente tipizzato.
- **Esito**: Deep Scan torna in stato parse-success con rendering findings/filtri senza regressioni sul ciclo build/distribuzione.

## 2026-04-17 - Packaging Health Audit scripts mancanti in dist

### Bug 20
- **Sintomo**: dalla GUI distribuita compariva `Health audit script not found: C:\SystemOptimizerHub\active\dist\WindowsOptimizer\scripts\system-health-audit.ps1`.
- **Causa radice**: `scripts/package-suite.ps1` non includeva `system-health-audit.ps1` (e il companion `apply-safe-fixes.ps1`) nella lista artefatti copiati in `dist/WindowsOptimizer/scripts`.
- **Fix applicato**: aggiornato il packaging aggiungendo entrambi gli script health all'array `$items` e rigenerato il pacchetto in `C:\SystemOptimizerHub\active\dist\WindowsOptimizer`.
- **Check anti-regressione**:
	- pre-fix: `HealthAuditExists=False`, `ApplyFixesExists=False`, `TotalPs1=13`;
	- post-fix: `HealthAuditExists=True`, `ApplyFixesExists=True`, `TotalPs1=15`.
- **Esito**: flusso Health Audit/Apply ripristinato in ambiente distribuito senza modifiche invasive alla GUI.

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

---

## Improvement 3 — Complete UX Redesign (Dark Theme + Toasts + Animations)
**Date:** 2026-04-17
**File:** scripts/system-optimizer-gui.ps1

### Changes
- **Dark palette**: clrBg/clrSurface/clrRaised/clrBorder + semantic accent colors (blue, green, red, amber, purple, cyan)
- **Fonts**: Segoe UI 9.5 (body), 14 Bold (header title), 9 Bold (H2/buttons), Consolas 9 (terminals), Segoe UI 8 (small/labels)
- **Header bar**: 64px panel with app title + 2 drive mini-cards (C:, D:) with utilization ProgressBar; 3px blue accent bottom line
- **Flat action buttons**: 7 buttons with semantic color per group (Scan=blue, Compute=purple, Audit=cyan, Execute=red, Quick Clean=green, Diagnostics=amber, Cancel=muted/red when active)
- **Progress band**: hidden panel (shown only when busy) containing Marquee ProgressBar (6px height) + animated spinner label
- **Spinner animation**: dots pattern cycling on every Update-*Progress tick: "Scanning."→".."→"..."→etc.
- **Dark ListView**: SetWindowTheme strips visual styles; per-row colors (High=dark red bg + pink text, Medium=dark amber bg + yellow text, default=surface+text)
- **Dark TextBox feeds**: BackColor=clrBg, ForeColor=clrText, Consolas font
- **Owner-draw tabs**: dark tab strip with clrAccent bottom underline on selected tab
- **Status bar**: 28px bottom panel; left=last action preview, right=PSHost+time (updated on Refresh-Drives)
- **Show-Toast**: borderless Form 360×90 at screen bottom-right, left-color accent strip, auto-close timer 4.5s — called on all 4 completion paths (Scan, Cleanup, Compute, Quick Clean)
- **Removed**: old btnRefresh (Refresh Drive Status) — drive data shown in header cards on every Refresh-Drives call

### Outcome
EXE v1.8.0 compiled and smoke-tested (stays alive >5s).

### Bug 17 — Toast crash `op_Subtraction` dopo redesign
- **Sintomo**: al completamento operazione compariva popup errore: `Chiamata al metodo non riuscita. [System.Object[]] non contiene un metodo denominato 'op_Subtraction'`.
- **Impatto**: UX interrotta da errore runtime durante notifica toast (scan/cleanup/compute/quick clean), con rischio di regressione percezione stabilita.
- **Causa radice**: in `Show-Toast` alcune proprieta usate nelle sottrazioni (posizionamento/border drawing) potevano essere valutate come array in certi contesti runtime/multi-monitor/event binding, quindi l'operatore `-` su `Object[]` falliva.
- **Fix applicato (incrementale, low-risk)**:
	1. risoluzione area schermo con fallback robusto: `Screen.FromControl($form).WorkingArea` -> `PrimaryScreen.WorkingArea`.
	2. estrazione scalare esplicita prima delle operazioni aritmetiche: cast a `int` con first-element guard (`@(... ) | Select-Object -First 1`).
	3. calcolo coordinate clamp-safe con `Math::Max(0, ...)`.
	4. drawing bordo toast con `ClientSize` validata (`w/h > 1`) e cast scalar.
	5. `try/catch` locale in `Show-Toast` con degradazione controllata su `Append-Status` (nessun popup errore bloccante).
- **Check anti-regressione**:
	- parser PowerShell script: `SYNTAX OK`.
	- rebuild EXE: `dist/WindowsOptimizer/WindowsOptimizer.exe` versione `1.8.1` generata con successo.
	- smoke test: processo GUI vivo oltre 6s (`ALIVE PID=6464`) senza crash all'avvio.
- **Esito**: eliminato errore `op_Subtraction`, toasts resi resilienti anche in configurazioni monitor/runtime non standard.

### Bug 18 — Toast timer crash `null-valued expression`
- **Sintomo**: al completamento di un'operazione compariva popup errore: `Impossibile chiamare un metodo su un'espressione con valore null`. Due finestre di dialogo sovrapposte (toast dietro, errore davanti).
- **Impatto**: ogni operazione completata con successo generava un errore bloccante; toast inutilizzabile.
- **Causa radice**: nel timer `.Add_Tick({ $tRef.Close(); $ttimer.Stop(); ... })` i riferimenti `$tRef` e `$ttimer` erano variabili locali della funzione `Show-Toast`. In PowerShell, i `.Add_Tick` / `.Add_Click` scriptblock **non** creano vere closure sulle variabili locali della funzione chiamante. Quando il timer scattava 4.5s dopo, la funzione era già uscita e le variabili risolvevano a `$null`.
- **Pattern violato**: *PowerShell .NET event handler scoping* — gli scriptblock usati come handler di eventi .NET NON catturano le variabili locali della funzione genitore.
- **Fix applicato**:
	1. Riferimenti passati tramite proprietà `.Tag` degli oggetti .NET: `$ttimer.Tag = $toast` e `$toast.Tag = $ttimer`.
	2. Handler riscritto con `param($sender, $eArgs)`: usa `$sender` (il timer) per raggiungere `$sender.Tag` (il toast).
	3. Guard `if ($toastRef -and -not $toastRef.IsDisposed)` prima di `.Close()`.
	4. `$sender.Dispose()` alla fine per pulizia deterministica.
- **Check anti-regressione**:
	- Parser: SYNTAX OK.
	- Rebuild EXE v1.8.2 OK.
	- Smoke test 8s: ALIVE.

### Bug 19 — Tab strip nascosta dietro header (pulsanti "sotto l'intestazione")
- **Sintomo**: la barra dei tab (Dashboard / Tasks / Logs / Config) non era visibile; il contenuto della tab appariva immediatamente sotto la riga accent blue dell'header, con i pulsanti azione quasi sovrapposti.
- **Impatto**: navigazione tra tab impossibile senza scorciatoie; layout percepito come broken.
- **Causa radice**: in WinForms il dock layout processa i controlli figli dall'indice più alto al più basso. L'ordine originale era:
	- `form.Controls.Add(pnlHeader)` → index 0
	- `form.Controls.Add(pnlStatusBar)` → index 1
	- `form.Controls.Add(tabs)` → index 2

	Il layout processava `tabs` (index 2, Dock=Fill) per primo, assegnandogli l'intera area client. Poi `pnlStatusBar` e `pnlHeader` si sovrapponevano, ma il TabControl aveva già il suo tab strip a Y=0, nascosto sotto il pannello header.
- **Pattern violato**: *WinForms Dock z-order* — il controllo Dock=Fill deve avere l'indice PIÙ BASSO (aggiunto per PRIMO) così viene processato per ultimo e riceve lo spazio residuo.
- **Fix applicato**:
	1. Wrapping in `$form.SuspendLayout()` / `$form.ResumeLayout($false)` per un singolo pass di layout.
	2. Ordine invertito: `Add(tabs)` → `Add(pnlStatusBar)` → `Add(pnlHeader)`.
	3. Edge-docked controls (Top/Bottom) hanno ora indici più alti e vengono processati per primi, riservando spazio. Fill (tabs, index 0) riceve il residuo.
- **Check anti-regressione**:
	- Parser: SYNTAX OK.
	- Rebuild EXE v1.8.2 OK.
	- Smoke test 8s: ALIVE.
	- Tab strip ora visibile con owner-draw corretto.
- **Esito**: tab strip visibile, layout deterministico, nessun overlap header/contenuto.
