---
name: hub-kb-commit-push
description: >-
  Commit relevant changes, update KB/ADR, cleanup runtime artifacts, and push
  to origin. Use when user asks commit, push, KB update, or "commit push e KB".
---

# Hub KB + commit + push

## Quando usare

Utente chiede esplicitamente commit / push / aggiornamento KB (anche insieme).

## Sequenza

1. **Cleanup** (prima dello stage):

```powershell
powershell -NoProfile -File scripts/repo-cleanup-before-push.ps1 -Apply
```

2. **Stage solo file rilevanti** — codice, scripts, KB, ADR, skills/rules.  
   **Non** stageare: `logs/*` runtime, `dist/*/logs/*`, pid, screenshot ad-hoc, cache KB rumore se non richiesto.

3. **Commit** — messaggio 1–2 frasi sul *perché* (stile repo: `feat|fix|docs(...)`).  
   Su PowerShell Windows usare here-string, non HEREDOC bash:

```powershell
git commit -m @"
tipo(scope): titolo

Perché / esito in una riga.
"@
```

4. **Push** `git push origin <branch>` (di solito `master`). Il hook pre-push rilancia cleanup.

5. **KB** — aggiornare il decision log pertinente (`KB/*.md`) e ADR se cambia architettura. Una lezione = un update mirato; non duplicare.

## Verifica

`git status` pulito (o solo untracked irrilevanti). Riportare hash commit + branch remoto.
