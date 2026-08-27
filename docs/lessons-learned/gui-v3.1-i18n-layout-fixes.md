# GUI v3.1 — i18n, command help, layout fixes

**Data:** 2026-08-12  
**Versione app:** 3.1.1

## Problemi risolti

### 1. `Add_Focus` su Button WinForms

- **Errore:** `Method invocation failed because [System.Windows.Forms.Button] does not contain a method named 'Add_Focus'`
- **Causa:** in WinForms PowerShell gli eventi si registrano con `Add_GotFocus` / `Add_Click`, non `Add_Focus`.
- **Fix:** `scripts/gui/command-help.ps1` — `MouseEnter` + `Click` per Button, `GotFocus` per altri controlli.
- **Anti-regressione:** avviare GUI e passare mouse su tutti i pulsanti primari; zero errori in console.

### 2. Combo sovrapposti (PROF / DETTAGLIO / MODALITÀ)

- **Sintomo:** testo troncato (`leLevel`, `afe`) — label e combo sulla stessa riga dei pulsanti con coordinate assolute in conflitto.
- **Causa:** pannello unico `pnlActions` (152px) con bottoni y=28 e opzioni y=96 ma overlap orizzontale con Cancel @ x=660 e opzioni @ x=340+.
- **Fix:** separato `pnlScanOptions` (58px, Dock Top) sotto i pulsanti; griglia allineata da x=12 con spacing 120px.
- **Pattern:** vedi `KB/powershell-winforms-patterns.md` Pattern 1 (dock z-order).

### 3. `package-suite.ps1` — path `gui\*` not found

- **Errore:** `Copy-Item (Join-Path $sourceGui '*')` falliva; duplicazione cartella `dist/.../gui/gui/`.
- **Fix:** un solo blocco copy con `Copy-Item -LiteralPath $sourceGui -Destination $guiTarget -Recurse`; rimozione target prima del copy; BOM UTF-8 ricorsivo su `scripts/**/*.ps1`.
- **Smoke:** `pwsh -File scripts/package-suite.ps1` exit 0; verificare `dist/WindowsOptimizer/scripts/gui/i18n.ps1` esiste.

## File toccati

| File | Modifica |
|------|----------|
| `scripts/gui/command-help.ps1` | Eventi help corretti |
| `scripts/gui/i18n.ps1` | (invariato) |
| `scripts/system-optimizer-gui.ps1` | v3.1.1, `pnlScanOptions` |
| `scripts/package-suite.ps1` | Copy gui/locale robusto |
| `config/locale/*.json` | IT/EN |
| `config/command-catalog.json` | Suggerimenti comandi |

## Smoke check post-fix

```powershell
cd D:\SystemOptimizerHub\active
pwsh -NoProfile -File scripts/package-suite.ps1
pwsh -NoProfile -File scripts/system-optimizer-gui.ps1
# Passare mouse su: Scansione Salute, Analizza Spazio, Altri strumenti
# Verificare pannello "Cosa fa" si popola senza errori console
```

## Riferimenti

- `docs/product/EFFICACY-AUDIT-2026-08-12.md`
- `docs/product/ACTION-PLAN-PHASE1-3.md`
- ADR-0003
