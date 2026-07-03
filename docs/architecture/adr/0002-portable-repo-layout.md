# ADR-0002: Layout Repository Portabile Multi-Piattaforma

**Stato:** Accettato  
**Data:** 2026-07-03  
**Autore:** Lead AI Engineer

## Contesto

Il repository originava come workspace Windows fisso in `C:\SystemOptimizerHub\active`. Remote ha già integrato automazioni DD-WRT (bash) e playbook router. Serve operare da clone Git su path arbitrari e da macchine dev non-Windows per documentazione/agenti.

## Decisione

1. **Root README.md** come entry point unico multi-piattaforma
2. **Script path-agnostic** — default `-HubRoot` / `-KbRoot` risolti da `$PSScriptRoot/../`
3. **docs/automation/cross-platform-setup.md** — bootstrap su macchine nuove
4. **Documentazione** usa path relativi al repo, non path host-specific
5. **Runtime logs** restano gitignored (`logs/*rollback*.json`, journal, ddwrt session)

## Conseguenze

### Positive

- Clone su qualsiasi path Windows
- Dev macOS/Linux possono contribuire a docs/KB
- Coerenza con script DD-WRT già presenti

### Negative

- Script legacy con default hardcoded (`C:\SystemOptimizerHub\...`) vanno migrati progressivamente
- `KB/architecture.md` mantiene riferimenti storici al path originale

## Migrazione progressiva

Priorità fix default path:

1. `scripts/kb-add-entry.ps1` ✅
2. `scripts/activate-hub-profile.ps1` ✅
3. Script con `-OutputCsv` / `-LogFile` hardcoded (backlog)

## Rollback

Ripristinare default path assoluti negli script modificati.

## Riferimenti

- ADR-0001 intelligent maintenance platform
- `docs/automation/cross-platform-setup.md`
