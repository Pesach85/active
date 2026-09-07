# Privacy Scan — read-only secret detection

## Quando usare

- Prima di condividere un PC o fare backup su cloud
- Dopo import config da altri progetti
- Periodicamente (mensile) come hygiene check

## Comando

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/privacy-scan-secrets.ps1 `
  -OutputJson logs/privacy-scan-latest.json
```

## Output

Schema `PrivacyScanReport.v1` in `logs/privacy-scan-latest.json`:

- `Summary`: conteggi per severità, file scansionati
- `Findings[]`: percorso, riga, preview **redatta**, raccomandazione

**Mai** contiene segreti in chiaro.

## Configurazione

Blocco `Privacy` in `config/sys-maintenance.json`:

```json
"Privacy": {
  "MaxFileSizeKb": 512,
  "MaxFindings": 500,
  "ScanPaths": ["%USERPROFILE%\\Documents", "config", "scripts"],
  "ExcludeDirNames": [".git", "node_modules", "ddwrtkey"]
}
```

## GUI

Tab **Privacy** → Run Scan → review findings → (Fase 2) Migrate to Vault.

## Rollback

N/A — script read-only. Nessuna modifica ai file scansionati.

## Limitazioni

- Non sostituisce antivirus o DLP enterprise
- Pattern euristici: possibili falsi positivi su file di esempio
- Non scansiona registry / Credential Manager (Fase 2+)

## Riferimenti

- ADR-0003
- `scripts/privacy-scan-secrets.ps1`
