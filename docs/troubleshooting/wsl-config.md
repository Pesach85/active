# Troubleshooting — WSL Configuration

Sintomi, cause e fix per `WSL-CONFIG-001`. Dettaglio completo: [`../../KB/bugs-fixed.md`](../../KB/bugs-fixed.md) (Bug 23–24).

## Sintomi

| Sintomo | Causa probabile |
|---------|-----------------|
| `wsl -l -v` hang + molti processi `wsl.exe` | Desync HKCU/HKLM registry |
| Listing OK ma `wsl -d` hang | `hypervisorlaunchtype=Off` |
| Health Audit stall su WSL | Probe senza timeout / hypervisor off |

## Fix rapido

```powershell
pwsh -File scripts/repair-wsl-config.ps1
pwsh -File scripts/repair-wsl-config.ps1 -Apply
# Se PendingReboot: riavviare, poi:
pwsh -File scripts/repair-wsl-config.ps1 -Apply -ValidateLaunch
```

## Validazione

Finding `WSL-CONFIG-001` in `system-health-audit.ps1` deve risultare Ready post-reboot.

## Rollback

```powershell
pwsh -File scripts/repair-wsl-config.ps1 -RestoreLatest
```
