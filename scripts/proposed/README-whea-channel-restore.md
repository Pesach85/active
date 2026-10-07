# Proposed — ripristino canale Kernel-WHEA/Errors (HITL)

**Stato:** SOLO PROPOSTA. Nessuno di questi script è stato eseguito in FASE 1b.  
**Prerequisito:** conferma esplicita utente + PowerShell **Amministratore**.  
**Sintassi verificata su questo host (2026-10-07):** `wevtutil sl /?`, `wevtutil cl /?`, `wevtutil epl /?` salvati in  
`artifacts/whea-dualchannel-20261007/raw/events/wevtutil_*_help.txt`.

## Ordine obbligatorio

1. `Export-KernelWheaErrorsChannel.ps1` — export `.evtx` con timestamp (nessuna modifica canale).
2. Verifica file export (size > 0, `wevtutil gli` / apri in Event Viewer).
3. `Restore-KernelWheaErrorsChannel.ps1` — clear con `/bu`, poi `sl` retention circolare + maxsize.
4. Gate **misura valida** (vedi report `01b_*`) — solo se PASS → soak/A/B.
5. Se qualcosa va storto: `Rollback-KernelWheaErrorsChannel.ps1`.

## Parametri consigliati (da help locale)

| Azione | Comando (da help) |
|--------|-------------------|
| Export | `wevtutil epl <NOME_REGISTRO> <FILEDEST>` |
| Clear + backup | `wevtutil cl <NOME_REGISTRO> /bu:<file.evtx>` |
| Retention circolare | `wevtutil sl <NOME> /rt:false` (`retention:false` ⇒ overwrite oldest) |
| Max size | `wevtutil sl <NOME> /ms:<bytes>` (min 1048576; multipli 64 KB) |

**Default proposto:** `/rt:false` + `/ms:67108864` (64 MiB). Canale attuale: `/rt:true` + `/ms:8388608` (cieco).
