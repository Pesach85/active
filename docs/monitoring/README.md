# Monitoraggio

KPI, soglie, trend e alert.

## Script Windows

- `scripts/monitor-resources.ps1` — CPU/RAM processi
- `scripts/monitor-whea-rate.ps1` — errori WHEA
- `scripts/monitor-nvme-kpi-7day.ps1` — KPI NVMe
- `scripts/analyze-resource-pressure-startup.ps1` — pressione risorse boot

## Log trend (runtime, gitignored)

- `logs/whea-trend-history.json`
- `logs/*-live.json`

## Router

- `scripts/watchdog_wifi.sh` — watchdog link WiFi STA
