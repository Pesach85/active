# Architecture - Windows Optimizer Hub

## Scope
Workspace operativo globale su C, D e sistema operativo, con profilo centralizzato in C:/SystemOptimizerHub/active.

## Componenti principali
- scripts/monitor-resources.ps1: monitor sempre attivo processi CPU/RAM + handling priorita.
- scripts/cleanup-storage-safe.ps1: cleanup con modalita Safe/Radical e criteri AuditDepth/AuditLevel.
- scripts/analyze-garbage-hotspots.ps1: ranking statistico cartelle garbage-prone con classificazione.
- scripts/system-optimizer-gui.ps1: dashboard UI con explorer evidenziato e controlli intelligenti.
- scripts/install-monitor-task.ps1: registrazione task monitor startup.
- scripts/install-cleanup-task.ps1: registrazione task cleanup giornaliero.
- scripts/ensure-powershell-core.ps1: bootstrap/validazione pwsh e applicazione task Core-only.
- scripts/activate-hub-profile.ps1: attivazione profilo centralizzato e rebinding percorsi task.

## Flussi
1. Osservazione: analyzer produce ranking con score e recommendation (High/Medium/Low).
2. Decisione: utente seleziona criteri (Depth, FileLevel/BitLevel, CleanupMode).
3. Audit: cleanup in modalita audit senza cancellazione.
4. Esecuzione: cleanup in modalita execute con policy selezionata.
5. Validazione: confronto metriche pre/post e log persistente.

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

## Packaging e distribuzione
- Dist principale: dist/WindowsOptimizer.
- GUI eseguibile: dist/WindowsOptimizer/WindowsOptimizer.exe.
- Installazione/rimozione: scripts/install-suite.ps1, scripts/uninstall-suite.ps1.
- Versioning locale sicuro: repo Git in C:/SystemOptimizerHub/active con .gitignore hardening.
