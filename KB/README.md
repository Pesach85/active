# KB Operativa - System Optimization

Questa Knowledge Base tiene traccia di:
- Obiettivi
- Task eseguiti
- Modifiche applicate
- Decisioni prese

## File principali
- journal.md: storico cronologico completo.
- task-board.md: stato task correnti (ToDo/In Progress/Done).
- architecture.md: architettura aggiornata di moduli, flussi e decisioni tecniche.
- templates/entry-template.md: template manuale per nuove registrazioni.

## Regola operativa
Per ogni attivita, registra SEMPRE una entry nel journal con:
1. Obiettivo
2. Task
3. Modifiche
4. Decisioni
5. Esito

## Registrazione rapida (consigliata)
Usa lo script:

pwsh -NoProfile -ExecutionPolicy Bypass -File C:\SystemOptimizerHub\active\scripts\kb-add-entry.ps1 \
  -Objective "Ridurre consumo RAM processi browser" \
  -Task "Applicato throttle priorita per processi oltre soglia" \
  -Changes "Aggiornata soglia RAM nel JSON","Aggiornato monitor-resources.ps1" \
  -Decisions "AutoTerminate resta false in fase iniziale" \
  -Outcome "Completato" \
  -KbRoot "C:\SystemOptimizerHub\active\KB"
