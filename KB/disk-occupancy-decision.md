# Disk occupancy GUI controls — 2026-09-04

## Cosa fanno i controlli (dopo fix)

| Controllo UI | Valori | Cosa controlla | Usato da |
|--------------|--------|----------------|----------|
| **UNITÀ** | C/D/F… | Volume da scansionare | Scan Storage (`analyze-disk-occupancy`) |
| **PROFONDITÀ** (ex PROF.) | Quick / Standard / Deep | Budget file campionati (8k / 25k / 80k) + root children | Scan Storage + Storage Audit/Clean |
| **DETTAGLIO** | FileLevel / BitLevel | Logico vs cluster+magic+LCN | Scan Storage + Storage Audit/Clean |
| **TOP** | 5–100 | Quante righe in explorer | Scan Storage |
| **PULIZIA** (ex MODALITÀ) | Safe / Radical | Retention aggressiva + target extra | Solo **Storage Audit/Clean** in Altri strumenti — **non** Scan Storage |
| **FIX MAX** | Safe / Moderate / Aggressive | Livello max delle soluzioni health | Solo tab **Salute** (`cmbDeepFixLevel`) — **non** storage |

## Bug trovati e corretti

1. **FIX MAX sulla Home** — sembrava legato allo scan disco ma guidava solo Health Apply; rimosso dalla riga scan. Health Apply ora legge FIX MAX della tab Salute.
2. **MODALITÀ sulla riga scan** — non influenzava Scan Storage; spostata in Altri strumenti accanto a Storage Audit/Clean, etichetta **PULIZIA**.
3. **PROF.** abbreviazione opaca → label **PROFONDITÀ** / **DEPTH**.
4. **CSV not found** — `analyze-disk-occupancy.ps1` scriveva CSV solo se `Explorer` non vuoto; GUI andava in timeout. Ora CSV sempre emesso + fallback JSON in GUI.
5. **Colonna Risk** → **Class** (SafeDelete / SystemBound / AppBound / PersonalHitl).

## C: focus / D: intoccabile da operatore

- Default drive = **C**.
- Non eseguire `-ExecuteSafeDelete` su D salvo richiesta esplicita.
