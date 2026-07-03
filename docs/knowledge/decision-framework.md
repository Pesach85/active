# Framework Decisionale — Routing Task

Valutare **prima** di ogni attività. Obiettivo: risolvere nel modo più semplice che funziona, delegando complessità solo quando serve.

## Albero decisionale

```
Task ricevuto
    │
    ├─ Richiede solo script/diagnostica locale?
    │       └─ SÌ → Risolvi direttamente (Lead o singolo agente)
    │
    ├─ Composto da sottoproblemi con competenze diverse?
    │       └─ SÌ → Decomposizione multi-agente (vedi roster)
    │
    ├─ Richiede interazione web (portale, login, dashboard, download)?
    │       ├─ API disponibile? → Usa API
    │       └─ No → Browser MCP (vedi browser-automation.md)
    │
    └─ Produce conoscenza nuova?
            └─ SÌ → Aggiorna docs/ + KB journal + runbook se ripetibile
```

## Matrice rapida

| Segnale | Azione | Esempio |
|---------|--------|---------|
| 1 competenza, scope chiaro | Diretto | Fix typo script, tweak soglia JSON |
| Analisi + implementazione + test | Multi-agente | Nuova feature GUI con audit |
| Solo documentazione | KB Curator | ADR, runbook, lessons learned |
| Event Log / WMI / registry | Diagnostics Agent | WHEA, servizi, memoria |
| Hardware / firmware / driver | Hardware Health Agent | NVMe, bad pages, CPU MCE |
| Script + task + rollback | Automation Engineer | Nuovo script con scheduled task |
| PR / secrets / permessi | Security Reviewer | Pre-push, credenziali |
| Sito con Cloudflare / login | Stealth Browser MCP | Portale vendor, dashboard cloud |
| Test UI semplice | cursor-ide-browser | Verifica pagina locale |

## Criteri multi-agente (ispirati ad Agency Agents)

Attivare decomposizione quando il task coinvolge **≥2** di:

- analisi / ricerca root cause
- implementazione codice
- testing / validazione post-reboot
- sicurezza / rollback review
- documentazione / KB
- review qualità

**Non** usare multi-agente per task lineari anche se "grandi" (es. eseguire script esistente + verificare log).

## Output obbligatori per task non banali

1. Modifica codice/script (se applicabile)
2. Entry `KB/journal.md` via `kb-add-entry.ps1`
3. Runbook se procedura ripetibile
4. ADR se decisione architetturale
5. Lessons learned se incident non banale

## Flusso operativo

```
Analisi → Piano → Implementazione → Test → Documentazione → KB → Runbook → ADR → Suggerimenti
```
