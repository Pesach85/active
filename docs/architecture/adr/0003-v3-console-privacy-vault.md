# ADR-0003: Console v3, Privacy Scanner e Secret Vault

**Stato:** Accettato — **Fase 1 prodotto completata** (2026-08-27); Fase 2 Vault / Fase 3 EXE aperte; modularizzazione worker GUI in corso (REFACTORING-PLAN-ELITE)  
**Data:** 2026-08-12 (status update 2026-08-27)  
**Autore:** Lead Engineer

## Contesto

Richiesta utente: GUI poco ordinata, exe fragile, utility manutenzione PC, **privacy scanner** per credenziali in chiaro, **vault** con DB sicuro e unlock **OAuth2**.

Stato al momento ADR:

- GUI monolitica `system-optimizer-gui.ps1` (~3.700 LOC), tema Obsidian v2.1
- 12+ pulsanti sulla dashboard → alto carico cognitivo
- Exe via ps2exe su script monolite → path/portabilità problematici
- Nessun modulo privacy; secrets policy solo in docs/security

**Stato 2026-08-27:** Privacy + IA 4 CTA + i18n + catalog shippati; GUI **v3.1.3** con `theme.ps1` / `worker-helpers.ps1`; smoke `test-hub-smoke.ps1`; layout ancora grande (~4k LOC shell).

## Decisione

### 1. Information Architecture GUI v3

| Tab | Contenuto | Ex-tab |
|-----|-----------|--------|
| **Home** | 4 CTA primarie + pannello "More tools" collassato | Overview |
| **Health & Fixes** | Deep scan findings + apply | Deep Scan |
| **Privacy** | Secret scan findings + (future) vault | *nuovo* |
| **Automation** | Scheduled tasks | Automation |
| **Diagnostics** | Log tail | Diagnostics |
| **Settings** | Config editor | Preferences |

**Primary actions (sempre visibili):**

1. Health Check  
2. Scan Storage  
3. Quick Clean  
4. Privacy Scan  

### 2. Privacy Scanner (Fase 1)

Script autonomo `privacy-scan-secrets.ps1`:

- **Solo lettura** — mai modificare file trovati
- Output JSON con schema `PrivacyScanReport v1`
- Valori **sempre redatti** (`****` + lunghezza); mai secret in chiaro in log/JSON/GUI
- Pattern: password assignments, connection strings, API keys (AWS/GitHub/generic), `.env`, `wp-config`, URL basic auth
- Exclude: `.git`, `node_modules`, `dist`, `ddwrtkey`, vault DB, file > configurable max size
- Integrazione GUI: worker async identico a health/deep scan (Start-Process + timer poll JSON)

### 3. Secret Vault (Fase 2 — design, non implementare in Fase 1)

```
┌──────────────────┐     OAuth2      ┌─────────────────┐
│  GUI / CLI       │ ───────────────►│  MSAL token     │
└────────┬─────────┘                 └────────┬────────┘
         │ unlock session                      │
         ▼                                     ▼
┌──────────────────┐   DPAPI wrap    ┌─────────────────┐
│  vault-service   │ ◄──────────────►│  SQLite (local) │
│  (user session)  │                 │  AES-256 values │
└──────────────────┘                 └─────────────────┘
```

- Master key: `ProtectedData` (CurrentUser scope)
- Session unlock: OAuth2 via MSAL (`Microsoft.Identity.Client`); token TTL configurabile
- Reveal: singolo secret per request con audit log (no bulk export default)
- Migrazione da privacy finding: copia in vault + opzione redazione file sorgente (Fase 3, con backup)

**Perché OAuth2 locale:** sblocco vault legato a identità verificata (es. Microsoft account) invece di password master debole memorizzata in chiaro.

### 4. EXE strategy (Fase 3)

**Decisione differita:** Fase 1 mantiene ps2exe; Fase 3 valuta launcher .NET minimal che invoca `pwsh -File scripts/system-optimizer-gui.ps1` con hub root relativo — evita compilare 3.700 LOC in un exe.

### 5. Modularizzazione codice

- Estrarre `scripts/gui/theme.ps1` (palette, font, `New-Btn`)
- **Non** spezzare worker logic in Fase 1 (rischio regressioni)
- Nuovi engine = script standalone + JSON contract

## Conseguenze

### Positive

- UX comprensibile per utente non-dev
- Privacy come cittadino di prima classe
- Percorso chiaro verso vault production-grade
- Engine esistenti intatti

### Negative

- GUI resta WinForms (debito tecnico fino a v4)
- Vault OAuth2 richiede app registration Azure/MSA (setup una tantum)
- Due fasi = feature vault non immediata

## Compatibilità / no regressioni

- Schema JSON `system-health-audit` invariato
- Schema JSON cleanup/garbage invariato  
- `package-suite.ps1` aggiunge file, non rimuove
- Tab rinominati; funzionalità deep scan preservata su tab Health & Fixes

## Rollback

1. Rimuovere tab Privacy e variabili `$script:privacy*` dalla GUI
2. Eliminare `privacy-scan-secrets.ps1` e config `Privacy` block
3. Ripristinare label tab originali

## Riferimenti

- [`docs/product/VISION.md`](../../product/VISION.md)
- [`docs/product/ROADMAP.md`](../../product/ROADMAP.md)
- [`docs/runbooks/privacy-scan.md`](../../runbooks/privacy-scan.md)
- ADR-0001, ADR-0002
