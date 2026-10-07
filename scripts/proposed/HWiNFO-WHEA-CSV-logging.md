# Proposed — HWiNFO CSV logging (fonte indipendente dal Event Log)

**Stato:** procedura manuale / HITL. Nessuna modifica BCD.  
**Scopo:** mentre Kernel-WHEA/Errors è cieco (o appena ripristinato), avere una serie temporale **indipendente** per WHEA correctable e MSR bank (fenomeno L1 CMCE storico).

## 1. Setup HWiNFO (GUI — NON MISURATO finché non eseguito)

1. Aprire **HWiNFO64** (stessa build usata in campagna L1 se nota; altrimenti registrare versione).
2. Sensors → **Logging** / Start Logging.
3. Formato: **CSV**.
4. Directory consigliata (repo-aligned):  
   `artifacts/whea-dualchannel-20261007/raw/hwinfo/`  
   Nome file: `hwinfo_whea_{yyyyMMdd-HHmmss}.csv`
5. Intervallo di campionamento: **2 secondi** (default proposto).  
   - 2 s ⇒ 300 campioni / 10 min → allineabile alle finestre campagna.  
   - Se CPU logging troppo pesante: **5 s** (120 campioni / 10 min) — annotare la scelta nel report.

## 2. Contatori da includere (nomi tipici — verificare in UI)

Selezionare esplicitamente (nomi possono variare per versione; copiare i nomi **esatti** dalla UI nel report):

| Gruppo | Contatore (cercare) | Nota |
|--------|---------------------|------|
| WHEA | Total Error Count / Corrected / MCE related | Fonte OS-side parallela |
| CPU | Machine Check / CMCE / MCA bank * | Fenomeno 2 (L1) storico |
| Memory | DIMM temps se presenti | Correlazione termica H3′ |
| Bus | DRAM frequency / IMC se esposto | Conferma 2400 dual |

Se un contatore non esiste in questa build: scrivere **NON MISURATO** e non inventarlo.

## 3. Correlazione alle finestre da 10 minuti

1. Allineare orologio OS (già locale).
2. Per ogni finestra `[T, T+10min)`:
   - `delta = last(counter) - first(counter)` nella finestra (se contatore monotono crescente).
   - Se il CSV ha rate già in unità/s: media × 600.
3. Esportare tabella: `WindowStart, HWiNFO_WHEA_delta, HWiNFO_CMCE_delta, EventLog_ID20_count`.
4. Finché Event Log è STRUMENTO CIECO: colonna EventLog = `BLIND`; usare solo HWiNFO per trend.
5. Dopo ripristino canale + gate PASS: entrambe le colonne obbligatorie; divergenza forte = anomalia strumentale da investigare prima della decisione badmemorylist.

## 4. Durata minima prima del soak A/B

- Config-only gate: almeno **1 h** HWiNFO + canale circolare OK.
- Soak formale 24 h ON/OFF: HWiNFO logging continuo (o segmenti concatenati senza gap > 1 campione perso oltre tolleranza 3× interval).

## 5. Cosa NON fare

- Non usare solo Kernel-WHEA/Operational ID 42 come proxy storm.
- Non dichiarare “WHEA=0” da Event Log finché `wevtutil gl` mostra `retention: true` a 8 MiB pieni / senza new write proof.
