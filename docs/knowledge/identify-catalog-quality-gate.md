# Quality gate — catena Identify → Catalog → Trust (T1)

Usare **prima** di modificare script in:
`identify-unknown-process.ps1`, `process-catalog-merge.ps1`, `serve-transparency-dashboard.ps1`, `build-transparency-report.ps1`, `web/transparency/app.js`.

## Checklist pre-modifica

1. **Mappa catena operativa**
   - Web/GUI POST → `Invoke-HubProcessScriptViaRequest` → `identify-unknown-process.ps1`
   - Cache KB → `Invoke-PostIdentifyCatalogPipeline` → `process-intelligence.json`
   - Report → `build-transparency-report.ps1` → Trust in tabella RAM

2. **PowerShell pitfalls (pattern ripetibili)**
   | Errore | Causa | Fix |
   |--------|-------|-----|
   | `Cannot overwrite variable PID` | `$pid` = automatica read-only | Usare `$targetProcessId` |
   | `parameter name 'HubRoot'` | Script chiamato con param non dichiarato | Aggiungere `HubRoot` opzionale al callee **oppure** omettere e usare `-WorkingDirectory` |
   | `null-valued expression` su `.Trim()` | stderr/file vuoto | Test `$null -ne $raw` prima di `.Trim()` |
   | `ContentEncoding` null | POST JSON senza charset | Fallback UTF-8 in `Read-RequestBodyJson` |
   | ParseException PS 5.1 / EXE GUI | Unicode em-dash, ellipsis, bullet in `scripts/gui/*.ps1` | Run `sanitize-ps-ascii.ps1`; smoke `test-gui-parse-ps51.ps1` |

3. **HITL gate**
   - Merge catalogo solo con password verificata (`RequireAuthForCatalogMerge`)
   - Rollback JSON in `logs/process-intelligence-rollback-*.json` prima di ogni write catalogo

4. **Anti-regressione**
   - Non degradare entry catalogo esistenti (descrizioni più ricche, priority Keep)
   - Non auto-merge processi vital/security

## Checklist post-modifica (obbligatoria)

```powershell
powershell -File scripts/test-hub-smoke.ps1
powershell -File scripts/test-identify-chain-e2e.ps1
dotnet test src/SystemOptimizerHub.sln
powershell -File scripts/test-core-parity.ps1
```

Se toccato dashboard web:
```powershell
powershell -File scripts/restart-transparency-web.ps1
powershell -File scripts/test-advisory-api.ps1
```

## Output atteso operatore (identify con password)

- Messaggio: `Catalog updated (T1 trust) and transparency report refreshed.`
- Trust tabella RAM: `T1_Delegated` / motivo `Process intelligence catalog`
- Evento JSONL: `CatalogMergeFromIdentify`

## KB

Registrare in `KB/journal.md`: root cause, fix, pattern da evitare.
