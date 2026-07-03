# Repository Notes

Multi-platform maintenance hub: Windows (PowerShell), DD-WRT (bash), docs/agents (any OS).

## Clone anywhere

No fixed install path. Clone to any directory and run scripts from repo root.
See [`docs/automation/cross-platform-setup.md`](docs/automation/cross-platform-setup.md).

## Sensitive data policy

- Runtime logs are ignored (`logs/*.log`, `logs/*rollback*.json`, `logs/*-live.json`).
- Router credentials: `ddwrtkey/` (ignored).
- Generated CSV reports are ignored.
- KB runtime journal is ignored (`KB/journal.md`).
- Built EXE binaries are ignored.

## Before publishing to a remote

1. Review `git status` — no runtime logs or rollback JSON.
2. Run pre-push cleanup: `pwsh -File scripts/repo-cleanup-before-push.ps1 -Apply`
3. Confirm no personal paths, credentials, tokens, or host-specific data in staged files.
4. `git config core.hooksPath .githooks` on each clone.
