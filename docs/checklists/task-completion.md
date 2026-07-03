# Checklist — Completamento Task

Usare alla fine di ogni task non banale.

## Implementazione

- [ ] Scope minimale — nessuna modifica non richiesta
- [ ] Pattern esistenti rispettati
- [ ] Rollback JSON se apply distruttivo
- [ ] Test eseguito (manuale o script)

## Documentazione

- [ ] KB journal aggiornato (`kb-add-entry.ps1`)
- [ ] Runbook creato/aggiornato se procedura ripetibile
- [ ] ADR creato se decisione architetturale
- [ ] Troubleshooting page se bug risolto
- [ ] Lessons learned se incident significativo

## Sicurezza

- [ ] Nessun secret in commit
- [ ] Path assoluti host-specific non committati
- [ ] Pre-push cleanup eseguito se push

## Continuous improvement

- [ ] Cosa può essere automatizzato?
- [ ] Cosa può essere delegato ad agenti?
- [ ] Cosa può diventare scheduled task?

## Handoff

- [ ] Task board aggiornato
- [ ] Suggerimenti futuri documentati
