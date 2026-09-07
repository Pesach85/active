# Project environment awareness — SystemOptimizerHub

Decisioni stabili per evitare errori ricorrenti su questo host (Inspiron 7577, Windows 10/11).

## PowerShell Core (pwsh)

| Sintomo | Causa | Azione corretta |
|---------|-------|-----------------|
| `pwsh` non riconosciuto in CMD/PowerShell | pwsh installato ma **non in PATH** sessione corrente | Usare `Get-HubPwshExecutable` / path completo `%ProgramFiles%\PowerShell\7\pwsh.exe` |
| `pwsh -File scripts/run-transparency-web.bat` fallisce | `.bat` non è script PowerShell | Eseguire `scripts\run-transparency-web.bat` (CMD) **oppure** `powershell -File scripts/run-transparency-web.ps1 -OpenBrowser` |
| Winget dice già installato ma pwsh assente in PATH | PATH utente/macchina non aggiornato | `scripts/ensure-powershell-core.ps1 -UpdateMachinePath` oppure riavviare terminale |

**Regola hub:** tutti gli script che avviano subprocessi devono chiamare `Get-HubPwshExecutable` da `hub-common.ps1`, mai assumere `pwsh` in PATH.

## Transparency web dashboard (:8765)

| Sintomo | Causa | Azione corretta |
|---------|-------|-----------------|
| `ERR_CONNECTION_REFUSED` su `http://127.0.0.1:8765/` | Dashboard **on-demand**, non è un servizio Windows permanente | Avviare con GUI **Web Dashboard**, `run-transparency-web.bat`, o `ensure-transparency-web.ps1` |
| Porta occupata ma health fail | Processo stale su 8765 | `ensure-transparency-web.ps1` ripulisce PID stale (`logs/transparency-web.pid`) |

**Regola:** aprire il browser **solo dopo** health OK su `/api/health`.

## GUI WinForms — scope event handler

| Sintomo | Causa | Fix applicato |
|---------|-------|---------------|
| `Invoke-BuildReport` non riconosciuto | Funzioni nested **non visibili** negli handler `Add_Click` | Stato in `$tab.Tag` + scriptblock (`BuildReport`, `ShowReport`, `StartWeb`) |
| `$reportPath` non impostata | Stessa limitazione scope | Path in `$tab.Tag.ReportPath` |

**Regola:** in tab GUI, **mai** chiamare funzioni nested da handler; usare scriptblock su hashtable `$tab.Tag`.

## Process intelligence / forensics

- Pipeline: catalog → cache → metadata → KB → forensics (PE/modules/memory strings) → web/LLM
- Forensics: read-only, bounded (`config/process-forensics.json`)
- Identify/Resolve: password Windows obbligatoria; KB cache only, no auto-merge catalogo

## Smoke gate obbligatorio

Prima di commit/push su feature transparency/process:

```powershell
powershell -File scripts/test-hub-smoke.ps1
```

Include: `transparency-web-ensure`, `process-forensics`, `process-resolution-*`, `process-identify-manual`.

## Launcher rapidi

```cmd
scripts\run-transparency-web.bat
```

```powershell
powershell -File scripts/run-transparency-web.ps1 -OpenBrowser
```
