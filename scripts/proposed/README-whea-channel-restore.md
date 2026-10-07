# Proposed — ripristino canale Kernel-WHEA/Errors (HITL)

**Stato:** SOLO PROPOSTA finché non lanci tu `-Execute`. L’agente non esegue la catena mutate.

## Script consigliato (HITL 2026-10-07)

**`Restore-KernelWheaErrors-HITL.ps1`** — export → gate bloccante → clear → circular → stampa orario ripristino.

```powershell
# Simulazione (default)
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts\proposed\Restore-KernelWheaErrors-HITL.ps1

# Esecuzione reale (TU, admin)
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts\proposed\Restore-KernelWheaErrors-HITL.ps1 -Execute
```

### Gate bloccante pre-`cl`

1. `.evtx` esiste  
2. Size > 0  
3. Leggibile con `Get-WinEvent -FilterHashtable @{ Path=...; Id=20 }`  
4. Count ID20 == `ExpectedId20` (default **3456**)  
Se fallisce → **`cl` non parte**.

Backup default: `D:\whea-backup\` (fuori dal canale) + check spazio ≥ 1 GB.  
Nota misurata 2026-10-07: `C:` aveva ~564 MB liberi → insufficiente per il gate 1 GB; non usare `C:\whea-backup` finché non liberi spazio.

Orario stampato a fine run = **inizio finestra soak** (`restore-time-<ts>.txt`).

## Gate soak (dopo restore)

```powershell
pwsh -File scripts\proposed\Validate-SoakGate.ps1 `
  -HwinfoCsvDir 'D:\Work\repos\active\artifacts\whea-dualchannel-20261007\raw\hwinfo' `
  -RestoreTimeFile 'C:\whea-backup\restore-time-<TS>.txt'
```

PASS solo se: **Circular** verificato **e** HWiNFO CSV attivo (mtime recente). Altrimenti soak non parte.

## Altri script

| File | Ruolo |
|------|--------|
| `Export-KernelWheaErrorsChannel.ps1` | export solo (legacy helper) |
| `Restore-KernelWheaErrorsChannel.ps1` | variante precedente con `/bu` su cl — preferire HITL.ps1 |
| `Rollback-KernelWheaErrorsChannel.ps1` | ripristino config retain 8 MiB |
| `Validate-KernelWheaErrorsWritable.ps1` | gate legacy new-event |
| `Validate-SoakGate.ps1` | **gate soak ufficiale** Circular + HWiNFO |
| `HWiNFO-WHEA-CSV-logging.md` | procedura CSV |

## Sintassi wevtutil (verificata su host)

Vedi `artifacts/whea-dualchannel-20261007/raw/events/wevtutil_*_help.txt`.
