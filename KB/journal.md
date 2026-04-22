# Journal Decisionale

## 2026-04-22 12:35:00
### Obiettivo
Valutare untracked locali e imporre all'agent la chiusura task con repository locale pulito.

### Task
Classificati gli untracked tra push e ignore, aggiornati gitignore e istruzioni always-on per hygiene obbligatoria.

### Modifiche
- Aggiornato `.gitignore` con `/logs/*-live.json` e `/logs/diagnostics/` per evitare staging di artifact runtime locali.
- Aggiornato `.github/instructions/windows-optimization.instructions.md` con sezione `Igiene repository locale (obbligatoria)` e comando gate `./scripts/repo-cleanup-before-push.ps1 -Apply`.

### Decisioni
- `scripts/analyze-nvme-readonly-plan.ps1` e modifiche GUI restano candidati al push (sorgente).
- Backup diagnostici Office e report live NVMe non vanno pushati: sono runtime/local diagnostics.

### Esito
Completato

## 2026-04-22 00:00:00
### Obiettivo
Introdurre un advisory dedicato per NVMe usurato con decisione operativa immediata e piano di write-offload, integrato in GUI senza regressioni.

### Task
Creato script di analisi read-only per rischio NVMe e aggiunto flusso GUI completo (run, polling, stop, timer, log source) con ordine funzioni logico.

### Modifiche
- Creato `scripts/analyze-nvme-readonly-plan.ps1` con output JSON: BestNextDecision, TechnicalRationale, ImmediateOperationalSteps, AntiRegressionChecks e WriteOffloadPlan.
- Aggiornato `scripts/system-optimizer-gui.ps1` con nuovo comando `NVMe Plan`, stato processo dedicato, funzioni `Update/Stop/Poll/Run-NvmeAdvisor`, timer dedicato e integrazione log.
- Eseguiti gate anti-regressione obbligatori: parser check GUI/script (`0` errori), rebuild EXE completato, smoke test GUI `AliveAfter6s=True`.

### Decisioni
- Approccio observation-first: lo script NVMe non applica modifiche sistema, genera solo advisory e piano operativo con rollback indicato per ogni fase.
- Integrazione incrementale nella dashboard esistente per minimizzare rischio layout/event regressions su WinForms.
- Nessuna terminazione aggressiva automatica: stop solo manuale via pulsante Cancel.

### Esito
Completato

## 2026-04-20 11:20:00
### Obiettivo
Rendere la GUI piu immediata e leggibile con un ordinamento UX senior orientato al flusso operativo reale.

### Task
Riorganizzata la dashboard in azioni quotidiane vs controlli avanzati, aggiunto shortcut a Deep Scan e riordinati i tab in sequenza piu logica.

### Modifiche
- Aggiornato `scripts/system-optimizer-gui.ps1` con action panel a due livelli: `Daily Flow` in alto e `Advanced` sotto.
- Portato `Deep Scan` nel flusso principale con pulsante dedicato dalla dashboard e tab order `Dashboard -> Deep Scan -> Automation -> Logs -> Settings`.
- Rinominati i tab `Tasks -> Automation` e `Config -> Settings` per maggiore chiarezza operativa.
- Validazione GUI completata: parser `0`, rebuild EXE riuscito, smoke test `AliveAfter6s=True` dopo 6 secondi.

### Decisioni
- Nessuna nuova finestra o layout complesso: mantenuto il design corrente, ma con information architecture piu netta tra azioni frequenti e controlli esperti.
- Deep Scan reso raggiungibile dalla dashboard invece di duplicarne i controlli, per ridurre frizione senza introdurre nuova logica di stato.

### Esito
Completato

## 2026-04-20 11:05:00
### Obiettivo
Sbloccare installazione/aggiornamento Office su questo sistema riallineando il canale a una configurazione supportata da Microsoft 365 Business Standard e portando il fix dentro l'applicazione.

### Task
Rilevato mismatch canale Office, aggiunto fix riusabile al motore Health Audit/package ed eseguito apply sul sistema con backup e verifica post-fix.

### Modifiche
- Creato `scripts/repair-office-m365-channel.ps1` per assessment, apply e rollback del branch Office.
- Esteso `scripts/system-health-audit.ps1` con rilevamento policy perpetua/LTSC incompatibile e finding `OFFICE-CHANNEL-001`.
- Aggiornato `scripts/package-suite.ps1` e rigenerato `dist/WindowsOptimizer` per includere il nuovo script.
- Applicato fix locale: `UpdateBranch` da `PerpetualVL2021` a `MonthlyEnterprise` con backup in `logs/diagnostics/office-channel-backup-20260420-110147.json`.

### Decisioni
- Canale raccomandato fissato a `MonthlyEnterprise` come miglior compromesso tra stabilita e prevedibilita per Microsoft 365 Business Standard; restano supportati anche `Current` e `SemiAnnualEnterprise`.
- Nessuna nuova UI WinForms: il caso Office viene gestito dal flusso Health Audit esistente per ridurre rischio regressioni.
- Fallback esplicito mantenuto via `-RestoreLatest` sul backup JSON piu recente.

### Esito
Completato

## 2026-04-20 10:05:00
### Obiettivo
Consolidare evidenze di validazione post-fix Deep Scan e chiudere il rilascio in sicurezza.

### Task
Raccolti risultati tecnici post-fix e confermata stabilita operativa lato utente (Deep Scan ora funzionante).

### Modifiche
- Consolidate evidenze in KB: parser check source/dist OK, rebuild EXE completato, smoke test GUI > 5s positivo.
- Confermata corrispondenza tra fix in source e dist su `Get-DeepScanFilteredFindings`.

### Decisioni
- Commit/push selettivo solo su codice e KB, escludendo log runtime live per evitare rumore e regressioni nel repository.
- Mantenuto approccio osservazione-first: nessuna modifica aggiuntiva ai motori di audit/apply dopo conferma utente.

### Esito
Completato

## 2026-04-20 09:55:00
### Obiettivo
Rimuovere il parse-failure ricorrente del Deep Scan in GUI mantenendo regressione-zero su build e packaging.

### Task
Eseguito debug riproducibile del flusso Deep Scan, applicato fix minimale al return shape dei findings filtrati e completata validazione anti-regressione.

### Modifiche
- Aggiornato `Get-DeepScanFilteredFindings` in scripts/system-optimizer-gui.ps1: `return $result.ToArray()` al posto di `return @($result)`.
- Soppressa emissione implicita in pipeline con `[void]$result.Add(...)`.
- Allineata la stessa correzione in dist/WindowsOptimizer/scripts/system-optimizer-gui.ps1.
- Aggiornata KB/bugs-fixed.md con Bug 21 e criteri riusabili per funzioni PowerShell orientate UI.

### Decisioni
- Fix incrementale e idempotente: nessuna modifica ai motori di audit/apply, solo hardening del layer GUI parsing/rendering.
- Applicato gate anti-regressione obbligatorio post-edit WinForms: parser check, rebuild EXE, smoke test >= 5s.

### Esito
Completato

## 2026-04-16 00:00:00
### Obiettivo
Avviare framework di manutenzione sistemistica sempre attivo.

### Task
Creato framework base monitor risorse + task schedulato.

### Modifiche
- Creata struttura C:\scripts, C:\logs, C:\config.
- Creato file di configurazione C:\config\sys-maintenance.json.
- Creato monitor C:\scripts\monitor-resources.ps1.
- Creato installer task C:\scripts\install-monitor-task.ps1.

### Decisioni
- PowerShell Core (pwsh) come runtime principale.
- AutoTerminate disabilitato per sicurezza iniziale.
- Logging persistente su C:\logs.
- Monitoraggio storage esteso a C: e D:.

### Esito
Completato

## 2026-04-17 17:53:54
### Obiettivo
Rendere obbligatorio il cleanup repository ad ogni push con gate automatico e fallback manuale.

### Task
Implementato gate pre-push per cleanup runtime artifact e aggiornata KB operativa con setup e uso.

### Modifiche
- Aggiunto scripts/repo-cleanup-before-push.ps1 con modalita check/apply per ripristino file runtime tracciati e rimozione artifact runtime non sorgente.
- Aggiunto .githooks/pre-push che invoca automaticamente il cleanup gate prima del push.
- Aggiornato KB/README.md con regola repository, setup hook locale e comando fallback manuale.

### Decisioni
- Scelta enforcement pre-push non aggressiva: cleanup solo su target runtime noti (dist logs e json live/postreboot), evitando impatti su file sorgente.
- Configurato core.hooksPath=.githooks in locale per applicazione immediata del gate.

### Esito
Completato

## 2026-04-17 17:12:33
### Obiettivo
Eseguire le next best decision su Deep Scan: filtro rapido severita e export report operativo.

### Task
Implementati filtro Critical/Important+ e export report dalla tab Deep Scan con integrazione completa nel flusso UI.

### Modifiche
- Aggiornato scripts/system-optimizer-gui.ps1 con controlli Deep Scan aggiuntivi: filtro SHOW (All/Critical/Important+/Critical+Important) e bottone Export Report.
- Aggiunte funzioni Get-DeepScanFilteredFindings e Export-DeepScanReport, con mapping selezione robusto tramite Tag per evitare mismatch in vista filtrata.
- Integrata gestione stato busy/enable controls per prevenire apply/export durante run concorrenti.

### Decisioni
- Scelta implementazione incrementale e idempotente: nessun cambio ai motori di audit/apply, solo orchestration GUI.
- Export su logs/diagnostics per mantenere tracciabilita e retention coerente con il framework.

### Esito
Completato

## 2026-04-17 17:08:55
### Obiettivo
Introdurre Deep Scan dedicato in GUI per analisi performance dettagliata con applicazione fix solo su consenso esplicito.

### Task
Estesa la GUI WinForms con nuova scheda Deep Scan, visualizzazione findings/soluzioni e flusso apply confermato dall'utente.

### Modifiche
- Aggiornato scripts/system-optimizer-gui.ps1 con nuova tab Deep Scan, stato processo dedicato, timer di polling e rendering dettagli finding/soluzioni.
- Aggiunto comando "Apply Selected Fix" con conferma preventiva (livello, rischio, rollback) e apply per singolo FindingId via apply-safe-fixes.ps1.
- Eseguiti controlli anti-regressione: parser PowerShell (Errors: 0), rebuild EXE, smoke test GUI >= 6s.

### Decisioni
- Mantenuto approccio osservazione-first: Deep Scan separato dalle azioni automatiche, nessuna applicazione fix senza consenso.
- Riutilizzato motore system-health-audit/apply-safe-fixes esistente per ridurre rischio regressioni e preservare idempotenza.

### Esito
Completato

## 2026-04-16 16:12:53
### Obiettivo
Introdurre quality gate decisionale permanente per ottimizzazione Windows

### Task
Creato prompt riusabile e istruzione always-on per filtrare richieste e prevenire regressioni

### Modifiche
- Aggiunto prompt .github/prompts/windows-optimization-quality-gate.prompt.md,Aggiunto file .github/instructions/windows-optimization.instructions.md

### Decisioni
- Applicato quality gate a tutte le richieste tramite applyTo globale,Rese obbligatorie best next decision e verifica anti-regressione

### Esito
Completato

## 2026-04-16 16:21:21
### Obiettivo
Attivare quality gate via custom agent e completare pulizia disco safe C/D

### Task
Creato custom agent, creati script cleanup, eseguito audit+execute e schedulato task giornaliero

### Modifiche
- Aggiunto .github/agents/windows-optimization-guardian.agent.md,Aggiunto .github/AGENTS.md,Creato scripts/cleanup-storage-safe.ps1 e scripts/install-cleanup-task.ps1,Aggiornato scripts/install-monitor-task.ps1 con fallback runtime

### Decisioni
- Pulizia in due fasi audit-first poi execute,Retention conservativa: temp 7 giorni, log 30 giorni,Nessuna terminazione aggressiva o target non sicuri

### Esito
Completato

## 2026-04-16 16:30:38
### Obiettivo
Automatizzare step successivo: Core-only runtime, audit D richiamabile, GUI e packaging trasferibile

### Task
Creati script bootstrap Core e audit hotspot, GUI taskbar, build EXE, install/uninstall e packaging

### Modifiche
- Aggiornati installer task con switch RequireCore,Creati scripts/ensure-powershell-core.ps1, scripts/audit-disk-hotspots.ps1, scripts/system-optimizer-gui.ps1,Creati scripts/build-gui-exe.ps1, scripts/package-suite.ps1, scripts/install-suite.ps1, scripts/uninstall-suite.ps1, wrapper .bat,Generato C:/dist/WindowsOptimizer/WindowsOptimizer.exe

### Decisioni
- Task always-on registrati in Core-only (pwsh 7.6.0),Pulizia e audit mantenuti in approccio safe e misurabile,Packaging orientato a trasferibilita e rimozione pulita

### Esito
Completato

## 2026-04-16 16:35:47
### Obiettivo
Rendere richiamabile step successivo e completare toolchain GUI/EXE installabile-rimovibile

### Task
Fix audit hotspot, enforced Core-only runtime, build EXE, launcher batch e package refresh

### Modifiche
- Fix scripts/audit-disk-hotspots.ps1 per strict mode,Aggiunti launcher scripts/run-gui.bat scripts/run-install-suite.bat scripts/run-uninstall-suite.bat,Rigenerato package con EXE in C:/dist/WindowsOptimizer

### Decisioni
- Standard runtime always-on fissato su pwsh 7.6.0,Audit D usato come base decisionale prima di cleanup tier-2,Packaging modulare con installer/uninstaller separati

### Esito
Completato

## 2026-04-16 16:38:50
### Obiettivo
Stabilizzare packaging trasferibile con GUI EXE e launcher

### Task
Corretto package-suite per includere launcher e gestire self-copy EXE senza errore

### Modifiche
- Aggiornato scripts/package-suite.ps1 con inclusione .bat e normalizzazione path EXE,Validato contenuto C:/dist/WindowsOptimizer/scripts

### Decisioni
- Packaging mantiene struttura modulare scripts/config,Evitata regressione build introducendo confronto path normalizzato

### Esito
Completato

## 2026-04-16 17:04:25
### Obiettivo
Introdurre explorer garbage intelligence in dashboard con criteri audit/cleanup intelligenti

### Task
Creato analyzer statistico, esteso cleanup con depth/file-bit-level e cleanup mode, aggiornata GUI con explorer evidenziato

### Modifiche
- Aggiunto scripts/analyze-garbage-hotspots.ps1,Aggiornato scripts/cleanup-storage-safe.ps1 con AuditDepth/AuditLevel/CleanupMode,Aggiornato scripts/system-optimizer-gui.ps1 con explorer classificato e controlli avanzati,Aggiornata KB con architecture.md, README, task-board

### Decisioni
- Default resta Safe + audit-first per evitare regressioni,Bit-level disponibile come stima cluster-aware, non cancellazione raw sectors,Nessuna integrazione linux in runtime Windows locale: priorita stabilita e prevedibilita nativa

### Esito
Completato

## 2026-04-16 17:30:32
### Obiettivo
Stabilizzare esecuzione EXE GUI senza errori runtime da path null

### Task
Fix robusto risoluzione percorsi e invocazione runtime child per modalita EXE

### Modifiche
- Fix system-optimizer-gui.ps1: Resolve-BaseDirectory con fallback PSScriptRoot/MyInvocation/AppDomain/Get-Location,Fix invocazioni child PowerShell tramite runtime resolver dedicato,Fix passaggio parametro Drives come argomenti separati (C D),Rigenerato EXE WindowsOptimizer.exe (timestamp 17:30:07)

### Decisioni
- Priorita anti-regressione: mantenuti percorsi script-mode e aggiunti fallback exe-mode,Error handling in dashboard invece di crash runtime

### Esito
Completato

## 2026-04-16 17:34:00
### Obiettivo
Chiudere regressioni residue EXE con allineamento packaging

### Task
Corretto package-suite per usare sorgenti Hub Active e riallineato dist

### Modifiche
- Fix scripts/package-suite.ps1 con source hub-relative,Rigenerato package in C:/SystemOptimizerHub/active/dist/WindowsOptimizer,Aggiornata KB/bugs-fixed.md con Bug 4

### Decisioni
- Distribuzione deve derivare solo da Active per evitare drift tra sorgenti,Mantenuto approccio non distruttivo

### Esito
Completato

## 2026-04-16 18:07:52
### Obiettivo
Ripristinare avvio EXE e rimuovere regressioni launcher/path

### Task
Risolti path drift launcher/default build, gestito lock file in fase build, validate startup da active e legacy dist

### Modifiche
- Aggiornato scripts/system-optimizer-gui.ps1 con path/runtime fallback robusti,Aggiornato scripts/build-gui-exe.ps1 e scripts/run-gui.bat con default Hub Active,Aggiornato scripts/package-suite.ps1 hub-relative,Rigenerati EXE e package; smoke test ALIVE=True su entrambe le posizioni

### Decisioni
- Compatibilita mantenuta su C:/dist per shortcut preesistenti,Build deterministica con stop processo prima di compilare

### Esito
Completato

## 2026-04-17 17:57:51
### Obiettivo
Validazione end-of-day build GUI con fix Deep Scan

### Task
Verifica commit inclusi, parser check, rebuild EXE, smoke test 8s, cleanup artefatti runtime

### Modifiche
- Build EXE rigenerata (timestamp aggiornato)
- Confermata presenza commit fix GUI e gate pre-push

### Decisioni
- Confermata policy cleanup runtime artifacts prima di ogni push

### Esito
Completato

## 2026-04-17 18:04:12
### Obiettivo
Ripristinare il workflow Health Audit in GUI distribuita (dist) eliminando script not found.

### Task
Corretto packaging della suite includendo gli script health mancanti e rigenerato dist con verifica pre/post.

### Modifiche
- Aggiornato scripts/package-suite.ps1: aggiunti system-health-audit.ps1 e apply-safe-fixes.ps1 nell'elenco artefatti.
- Rigenerato pacchetto C:\SystemOptimizerHub\active\dist\WindowsOptimizer con script health presenti.

### Decisioni
- Scelto fix incrementale e idempotente sul packaging invece di workaround runtime in GUI.
- Incluso anche apply-safe-fixes.ps1 per prevenire regressione funzionale nel flusso audit->apply.

### Esito
Completato
