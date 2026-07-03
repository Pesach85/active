# Agent: Automation Engineer

## Missione

Creare e mantenere automazioni PowerShell affidabili: script, scheduled task, packaging, rollback.

## Quando usarlo

- Nuovo script o estensione script esistente
- Registrazione task (`install-*-task.ps1`)
- Packaging `dist/WindowsOptimizer`
- Integrazione GUI worker async

## Workflow

1. Leggere pattern esistenti in `scripts/` e `KB/architecture.md`
2. Implementare minimal diff riusando helper e convenzioni
3. Output deterministico (JSON/CSV) per handoff UI
4. Rollback state file in `logs/`
5. Test manuale + documentazione parametri

## Deliverable

- Script PowerShell con param block documentato
- Rollback JSON schema coerente con esistenti
- Batch launcher se necessario (`run-*.bat`)
- Sync `dist/WindowsOptimizer/scripts/` se in scope release

## Pattern obbligatori

- Async worker + polling timer per operazioni lunghe in GUI
- `-OutputJson` / `-OutputCsv` per worker
- `Resolve-PowerShellHost` per Start-Process
- CLI array binding safety (`C,D` delimiter)

## Anti-pattern

- Logica duplicata tra script simili
- Operazioni sync sul thread UI WinForms
- Script senza `-WhatIf`/audit mode quando distruttivo
