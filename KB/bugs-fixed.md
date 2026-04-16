# Bugs Fixed

## 2026-04-16 - EXE Runtime Stabilization

### Bug 1
- Sintomo: errore all'avvio EXE "Impossibile associare l'argomento al parametro 'Path' perche e nullo".
- Causa: in EXE, `$MyInvocation.MyCommand.Path` puo risultare nullo; la GUI usava `Split-Path` senza fallback.
- Fix applicato: introdotto `Resolve-BaseDirectory` con fallback ordinati (`$PSScriptRoot`, `$MyInvocation`, `AppDomain.BaseDirectory`, `Get-Location`).
- Esito: percorsi `scriptRoot` e `hubRoot` sempre determinati sia in script mode sia in exe mode.

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

### Verifica finale
- GUI script lint: nessun errore.
- EXE rigenerato: `C:/SystemOptimizerHub/active/dist/WindowsOptimizer/WindowsOptimizer.exe`.
- Build metadata: size 49152, timestamp 2026-04-16 17:30:07.
