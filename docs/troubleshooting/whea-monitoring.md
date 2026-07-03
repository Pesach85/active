# Troubleshooting — WHEA Monitoring

## Sintomo: Get-WinEvent RPC error

**Causa:** servizi `EventLog` o `RpcSs` non running, oppure canale WHEA non accessibile via API.

**Fix:**

1. Verificare servizi: `Get-Service EventLog, RpcSs`
2. Abilitare fallback in config: `Whea.UseWevtutilFallback=true`
3. Eseguire manualmente: `pwsh -File scripts/monitor-whea-rate.ps1`

## Soglie decisionali

Configurabili in `sys-maintenance.json` → `Whea.GoThreshold` (default 300) e `HoldThreshold` (600).

## Output

`logs/whea-monitoring-continuous.json`

## GUI

`scripts/analyze-whea-gui.ps1` legge il path da config (portabile).
