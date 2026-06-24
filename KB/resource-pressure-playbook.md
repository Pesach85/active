# Playbook Risorse e Startup (Safe, Anti-Regressione)

## Obiettivo
Identificare processi che saturano CPU/RAM/I/O, classificare necessita/priorita e applicare tuning minimo senza introdurre regressioni.

## Metriche pre/post
- Top processi per score multi-risorsa: CPU%, WorkingSetMB, IoMBps.
- Segnali startup: BrowserAutoStartCount, RemoteToolAutoStartCount, UpdaterAutoStartCount.
- Storage profile: presenza HDD meccanici + stato salute.
- Accesso log boot diagnostics: Available vs DeniedOrMissing.

## Script riusabili
1. scripts/analyze-resource-pressure-startup.ps1
- Modalita: osservazionale (non modifica nulla).
- Output: JSON strutturato con ranking processi, inventory startup, dischi, azioni safe.

Esempio:
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\analyze-resource-pressure-startup.ps1 -DurationSec 12 -Top 20 -StartupLookbackDays 14 -OutputJson .\logs\resource-pressure-live.json
```

2. scripts/apply-startup-io-safe-tuning.ps1
- Modalita default: AUDIT.
- Modalita EXECUTE: disabilita solo autostart browser non critici (EdgeAutoLaunch, Opera Stable) con backup JSON.

Audit:
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\apply-startup-io-safe-tuning.ps1 -OutputJson .\logs\startup-safe-tuning-live.json
```

Apply:
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\apply-startup-io-safe-tuning.ps1 -Execute -OutputJson .\logs\startup-safe-tuning-live.json
```

## Decision gates
- Keep: processi core Windows e security (no disable/kill).
- Tune: processi user-space ad alto impatto (ridurre autostart/background, eventuale priority tune osservato).
- Review: updater/tool opzionali (abilitare solo se necessari al workflow).

## Check anti-regressione
1. Eseguire baseline analyzer.
2. Applicare solo tuning minimo non critico.
3. Rilanciare analyzer post-change.
4. Confermare riduzione segnali startup e assenza errori sistema.
5. Conservare backup startup per rollback puntuale.

## Rollback rapido
- Ripristino startup entries dal backup JSON (`startup-safe-tuning-backup.json`) con `New-ItemProperty` sui path originali.
- In caso di servizio modificato manualmente, riportare startup type a precedente valore.

## Note operative
- Se i log Diagnostics-Performance non sono accessibili, usare inferenza da startup inventory + processi top e marcare confidenza media.
- In sistemi con HDD meccanico, evitare prelaunch browser e scansioni concorrenti subito dopo logon.
