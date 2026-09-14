# Sessione 2026-09-14 — R.1 Throttle handle-stable, wiring CLI, GUI Home, policy EXE

Fatti verificati in sessione (non processo narrativo).

## Problema 1 — TOCTOU Throttle (H1)

- **Problema:** Core/PS ri-risolvevano per Pid tra recheck e mutate (handle non stabile).
- **Fix:** contratto handle-based su Core/Throttle — `GetLiveSnapshotWithHandleAsync`, `ThrottleBelowNormalAsync(Process, ProcessIdentity, ct)`, fail-closed su HasExited e identity unreadable/mismatch.
- **Commit:** `8e6c1e1` (R.1 Core); wiring CLI in `f3be49f`.
- **Test:** T1 (HasExited, identity mismatch) + T1c (IdentityFieldUnreadable); suite Core 43/43 sul tree R.1.
- **Limiti aperti:** Terminate ancora Pid-based; soft-skip DTO in `CrashSafeApplyContract.IdentityMatches`; Linux stub `ImagePath=""` → throttle Linux abortisce sempre su IdentityFieldUnreadable.

## Problema 2 — Gap wiring CLI

- **Problema:** `resolve apply` non passava `snapshots: platform.ProcessSnapshots` → Outcome `SnapshotRequired`, Throttle mai applicato in produzione su `8e6c1e1` solo.
- **Fix:** commit `f3be49f` (`fix/cli-resolve-snapshots`), mergiato ff-only in `master`.
- **Verifica:** smoke live `Throttled` + PriorityClass BelowNormal; kill-before → `ProcessNotRunning` (non `SnapshotRequired`). Deploy hub FDD da artefatto `r1-cli-fix-f3be49f-fdd-hub`.

## Problema 3 — WindowsOptimizer.exe (PS2EXE) stale

- **Problema:** l’EXE embedded non si aggiorna quando cambia `system-optimizer-gui.ps1`; shortcut/doppio-clic sull’EXE mostrava layout vecchio mentre lo script su junction era già aggiornato.
- **Procedura:** dopo ogni modifica a `scripts/system-optimizer-gui.ps1`, rigenerare con `scripts/build-gui-exe.ps1` (Invoke-PS2EXE, `-NoConsole`, Title/Description canonici). Nessun watch/build automatico oggi (follow-up possibile, non implementato).
- **Policy:** `WindowsOptimizer.exe` è **intenzionalmente gitignored** (`.gitignore`: `/dist/**/WindowsOptimizer.exe`, `*.exe`) — non va committato; va rigenerato localmente per ambiente. Hash verificato post-rebuild 2026-09-14: `9CA84E48135B276C…`.

## Problema 4 — UX Home select Safe/Radical

- **Problema:** select PULIZIA (Safe/Radical) mal posizionata/allineata nella riga STRUMENTI AVANZATI.
- **Fix:** riposizionata nella riga scan options (UNITÀ / PROFONDITÀ / DETTAGLIO / TOP / **PULIZIA**); bottoni ADVANCED riallineati; separazione visiva PRIMARY vs ADVANCED (`$clrSectionDivider` + `$clrAdvancedSurface`).
- **Commit:** `b6499ca` (script `scripts/` + mirror `dist/…/system-optimizer-gui.ps1`). Dist hub binari R.1+wiring: `9219fe3`.

## Nota merge / Program.cs dirty

Durante il merge `f3be49f`→`master`, modifiche dirty non committate a `Program.cs` sono state rimosse dal working tree per consentire il ff-only; **non** erano ridondanti: oltre al wiring già in `f3be49f`, contenevano Phase6 Network transparency nel comando `transparency report` + ExitCode per `PidIdentityMismatch`/`SnapshotRequired`. Recuperate su branch `wip/network-transparency-pre-20260914` (`03904b7`) e copia in `artifacts/wip-program-cs-pre-20260914/` — decisione merge WIP fuori scope.

## Riferimenti hash (master pushato)

| Commit | Ruolo |
|--------|--------|
| `8e6c1e1` | R.1 Core Throttle handle-stable |
| `f3be49f` | fix CLI snapshots wiring |
| `9219fe3` | dist/hub binari FDD |
| `b6499ca` | GUI Home script (PULIZIA + sezioni) |
