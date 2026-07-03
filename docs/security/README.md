# Sicurezza

Policy dati sensibili e review pre-push.

## Gitignored (mai committare)

- `ddwrtkey/` — credenziali router
- `KB/journal.md` — journal operativo locale
- `logs/ddwrt-*`, `logs/ssh-*` — sessioni router
- `logs/*rollback*.json` — stato macchina-specifico

## Pre-push

```powershell
git config core.hooksPath .githooks
pwsh -File scripts/repo-cleanup-before-push.ps1 -Apply
```

## Agente

[`../agents/security-reviewer.md`](../agents/security-reviewer.md)

Vedi anche [`REPOSITORY-NOTES.md`](../../REPOSITORY-NOTES.md).
