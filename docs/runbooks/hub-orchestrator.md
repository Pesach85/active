# Runbook — Hub Orchestrator

**ID:** RB-ORCH-001  
**Stato:** Active  
**Ultimo aggiornamento:** 2026-07-03  

## Scopo

Ciclo unico di manutenzione leggera: heartbeat JSON, rotazione log testuali, trigger opzionali WHEA e fs-integrity.

## Configurazione

`config/sys-maintenance.json` → sezione `Orchestrator`:

| Chiave | Default | Descrizione |
|--------|---------|-------------|
| Enabled | true | Abilita orchestratore |
| HeartbeatIntervalSeconds | 300 | Intervallo loop |
| LogRotationDays | 7 | Retention file `.log`/`.txt` in `logs/` |
| RunWheaMonitor | true | Invoca `monitor-whea-rate.ps1 -Quiet` |
| RunFsIntegrityScan | true | Invoca `fs-integrity.ps1` |

## Esecuzione manuale

```powershell
cd <repo-root>
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/hub-orchestrator.ps1 -Once
```

## Scheduled task (consigliato)

```powershell
$hub = (git rev-parse --show-toplevel)
$script = Join-Path $hub 'scripts\hub-orchestrator.ps1'
$action = New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$script`" -Once"
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration ([TimeSpan]::MaxValue)
Register-ScheduledTask -TaskName 'SystemOptimizerHub-Orchestrator' -Action $action -Trigger $trigger -RunLevel Highest -Force
```

## Verifica

- Heartbeat: `logs/hub-orchestrator-heartbeat.json`
- WHEA: `logs/whea-monitoring-continuous.json`
- FS integrity: `logs/fs-integrity-latest.json`

## Rollback

Impostare `Orchestrator.Enabled=false` in config e rimuovere il task schedulato.
