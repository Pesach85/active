# Runbook — Relocation Hub su D:

**ID:** RB-HUB-001  
**Stato:** Active  
**Ultimo aggiornamento:** 2026-07-03  

## Scopo

Spostare SystemOptimizerHub da `C:\SystemOptimizerHub` a `D:\SystemOptimizerHub` per liberare spazio su disco di sistema.

## Prerequisiti

- [ ] Spazio su D: sufficiente (~10 MB repo + logs runtime)
- [ ] PowerShell 7+
- [ ] Privilegi amministratore (reinstall scheduled tasks)

## Procedura

### 1. Copia repository

```powershell
New-Item -ItemType Directory -Force -Path 'D:\SystemOptimizerHub'
robocopy 'C:\SystemOptimizerHub' 'D:\SystemOptimizerHub' /E /COPY:DAT /R:2 /W:2
```

### 2. Riattiva profilo da D:

```powershell
cd D:\SystemOptimizerHub\active
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts\activate-hub-profile.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts\install-suite.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts\audit-startup-integrity.ps1 -Apply
```

### 3. Rebuild GUI (post-move)

```powershell
pwsh -File scripts\package-suite.ps1
pwsh -File scripts\build-gui-exe.ps1
```

### 4. Apri workspace Cursor/IDE su `D:\SystemOptimizerHub\active`

### 5. Rimuovi copia C: (dopo chiusura IDE su C:)

```powershell
Remove-Item 'C:\SystemOptimizerHub' -Recurse -Force -ErrorAction SilentlyContinue
```

## Rollback

Ripetere robocopy da D: a C: e reinstallare task con `activate-hub-profile.ps1 -HubRoot C:\SystemOptimizerHub\active`.

## Troubleshooting

| Sintomo | Azione |
|---------|--------|
| Task schedulati puntano ancora a C: | `pwsh -File scripts\audit-startup-integrity.ps1 -Apply` (Admin). Health Scan finding `STARTUP-LEGACY-001`. |
| EXE non trova script | Rigenerare con `build-gui-exe.ps1` da D: |
| Git lock su C: | Chiudere IDE, copiare solo `.git` mancante |

## Riferimenti

- ADR-0002 portable repo layout
- `docs/automation/cross-platform-setup.md`
