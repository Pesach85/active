# Setup Cross-Platform

Guida per clonare e operare il repository su **qualsiasi macchina**, indipendentemente dal path di installazione.

## Principio: repo-root relativo

**Non** assumere `C:\SystemOptimizerHub\active`. Tutti i comandi partono dalla root del clone Git.

```bash
# Unix / Git Bash / macOS / Linux dev
export REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"
```

```powershell
# Windows PowerShell — dalla root del repo
$RepoRoot = git rev-parse --show-toplevel
# oppure, se git non in PATH:
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)  # da scripts/
```

Gli script in `scripts/` risolvono la root automaticamente quando `-HubRoot` / `-KbRoot` non sono passati.

## Clone iniziale

```bash
git clone https://github.com/Pesach85/active.git
cd active
git config core.hooksPath .githooks
```

Path consigliati (esempi, non obbligatori):

| OS | Esempio path |
|----|--------------|
| Windows | `D:\dev\active` o `%USERPROFILE%\src\active` |
| macOS/Linux | `~/src/active` |
| WSL | `/home/user/src/active` (script Windows via `/mnt/...`) |

## Windows — bootstrap

```powershell
cd <repo-root>
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/ensure-powershell-core.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/activate-hub-profile.ps1
```

`activate-hub-profile.ps1` rileva la repo root dal percorso dello script se `-HubRoot` è omesso.

### GUI e suite

```powershell
pwsh -File scripts/run-gui.bat          # oppure scripts/system-optimizer-gui.ps1
pwsh -File scripts/install-suite.ps1    # task schedulati + monitor
```

### KB journal (path-agnostic)

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/kb-add-entry.ps1 `
  -Objective "..." -Task "..." `
  -Changes @("modifica1") -Decisions @("decisione1") `
  -Outcome "Completato"
# -KbRoot opzionale; default: <repo>/KB
```

## DD-WRT / router Linux

Script bash in `scripts/`:

| Script | Uso |
|--------|-----|
| `ddwrt-apply-permanent-tuning.sh` | Tuning NVRAM permanente |
| `watchdog_wifi.sh` | Watchdog WiFi client STA |

Playbook completo: [`KB/dd-wrt-hotspot-playbook.md`](../../KB/dd-wrt-hotspot-playbook.md)

**Credenziali:** cartella `ddwrtkey/` (gitignored). Non committare chiavi SSH o password.

Wrapper PowerShell (invoca SSH verso router):

```powershell
pwsh -File scripts/apply-ddwrt-permanent-tuning.ps1
```

## macOS / Linux — solo documentazione e agenti

Su macOS/Linux senza Windows:

- Leggere e aggiornare `docs/`, `KB/`, `.github/AGENTS.md`
- Eseguire script `.sh` verso router remoto
- Usare Cursor/Claude con agent roster da `docs/agents/`
- **Non** eseguire script `.ps1` senza PowerShell (`brew install powershell` se necessario)

## Pre-push (tutte le piattaforme)

Hook `.githooks/pre-push` esegue cleanup runtime:

```bash
git config core.hooksPath .githooks
# oppure manuale:
pwsh -File scripts/repo-cleanup-before-push.ps1 -Apply
```

## Browser MCP (opzionale)

Per automazione web anti-bot su qualsiasi dev machine:

1. Clonare [stealth-browser-mcp](https://github.com/vibheksoni/stealth-browser-mcp) separatamente
2. Configurare MCP client con path assoluti al venv Python locale
3. Vedi [`docs/knowledge/browser-automation.md`](../knowledge/browser-automation.md)

## Checklist nuova macchina

- [ ] Clone repo + `core.hooksPath`
- [ ] PowerShell 7+ (Windows) o `pwsh` installato
- [ ] `activate-hub-profile.ps1` eseguito
- [ ] `ddwrtkey/` creato localmente se serve DD-WRT (non in git)
- [ ] Journal KB locale (`KB/journal.md` — gitignored)

## Riferimenti

- [`docs/architecture/adr/0002-portable-repo-layout.md`](../architecture/adr/0002-portable-repo-layout.md)
- [`REPOSITORY-NOTES.md`](../../REPOSITORY-NOTES.md)
