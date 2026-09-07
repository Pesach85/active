# Cursor skills — adozione (aggiornato 2026-09-07)

## Fonti analizzate

| Fonte | Cosa offre | Decisione Hub |
|-------|------------|---------------|
| [fable-orchestration/SKILL.md](https://github.com/per-simmons/fable-orchestration/blob/master/SKILL.md) | Architect/delegate, effort caps, paste-in prompt kit, verify loops, anti-overplan | **Adottato** il prompt kit comportamentale (act / no tidy / ground claims / boundaries / autonomous / memory). **Non** adopted: wiring Claude Fable/Opus, `/effort`, plugin Codex — fuori stack Cursor Hub |
| [chrisboden/cursor-skills](https://github.com/chrisboden/cursor-skills) | Orchestrator vs Pair Programmer, skills MCP (`list`/`invoke`/`import`), skill-creator, document skills | **Adottato** dual-role + anatomia `SKILL.md` + skill-creator Hub-scoped. **Non** adopted: MCP Python `skills_mcp.py` (Cursor ha discovery nativa in `.cursor/skills/`); docx/pdf/artifacts generici (fuori prodotto) |
| Cursor skills-cursor (canvas, babysit, loop, create-hook, review-*) | Artefatti UI, PR babysit, loop ricorrenti, hooks, review | **Adottato via routing** in `hub-orchestration.mdc` (non duplicare SKILL.md nel repo) |

## Catalogo installato nel repo

```
.cursor/rules/hub-orchestration.mdc          # alwaysApply — routing + prompt kit
.cursor/skills/hub-quality-gate/SKILL.md
.cursor/skills/android-on-device-maintenance/SKILL.md
.cursor/skills/hub-kb-commit-push/SKILL.md
.cursor/skills/skill-creator/SKILL.md
.cursor/skills/hub-hitl-migration-decision/
.cursor/skills/windows-dev-sync/SKILL.md     # 2026-09-07
.cursor/skills/linux-suite-package/SKILL.md  # 2026-09-07
docs/skills/transparency-control/
```

## Matrice deterministica: skill → scopo Hub → efficienza / no-regressione

Criteri: **A** = allinea scopo prodotto (opt Windows/Linux/Android, HITL, transparency); **E** = riduce turni/rilavoro; **V** = impone verifica/evidenza; **R** = riduce rischio regressione/mutazione unsafe.

| Skill | A | E | V | R | Meccanismo |
|-------|---|---|---|---|------------|
| `hub-quality-gate` | sì | alto | alto | alto | Sequenza fissa test+smoke+cleanup; PASS solo con output |
| `hub-hitl-migration-decision` | sì | medio | alto | critico | Blocca mute senza NBD/HITL |
| `android-on-device-maintenance` | sì | alto | alto | alto | Build/install/smoke ADB; no WebView fallacy |
| `hub-kb-commit-push` | sì | alto | medio | medio | Cleanup → stage mirato → push → KB una lezione |
| `windows-dev-sync` | sì | alto | medio | medio | Deploy ripetibile via `dev-sync-production.ps1` |
| `linux-suite-package` | sì | alto | medio | medio | Package CLI Linux deterministico |
| `transparency-control` | sì | medio | alto | medio | T0–T3 + dashboard :8765 |
| `skill-creator` | sì | medio | basso | basso | Standardizza skill future Hub |
| `canvas` (Cursor) | sì* | alto | medio | basso | Artefatti analitici revisitabili (NBD, smoke, occupancy) |
| `babysit` (Cursor) | sì* | alto | alto | alto | CI+commenti fino a merge-ready |
| `loop` (Cursor) | sì* | alto | alto | medio | Riesegue quality-gate/monitor senza prompt manuale |
| `review-bugbot` / `review-security` | sì* | medio | alto | alto | Review strutturata su diff prima dello ship |
| `create-hook` (Cursor) | sì* | medio | alto | alto | Gate shell/agent su eventi (opzionale; non ancora wired) |
| Cloudflare / PLC / SEO / docx | no | — | — | — | Fuori scope prodotto Hub |

\*Amplificatore di processo agente, non feature runtime Hub.

## Perché non MCP chrisboden / document-skills

- Overhead (uv/Python MCP) per capability già coperte da Cursor Skills nativi
- Import community (docx/pdf) non necessari al Hub
- `artifacts-builder` community ≈ `canvas` Cursor: usare canvas, non fork

## Mapping comportamenti Fable → Hub

| Kit Fable | Implementazione Hub |
|-----------|---------------------|
| Act don't overplan | `hub-orchestration.mdc` |
| No unrequested tidying | idem + user rules |
| Delegate subagents | Task/parallel tools Cursor |
| Ground progress | `hub-quality-gate` + smoke skills |
| Boundaries assess vs fix | hub-orchestration |
| Memory one lesson/file | `hub-kb-commit-push` + KB updates |
| Effort cap / Fable routing | N/A (modello Cursor session) |

## Decisioni 2026-09-07 (attuabili subito)

1. **Creati** `windows-dev-sync` e `linux-suite-package` (candidati KB 2026-09-04, ora flussi ricorrenti + richiesta deploy).
2. **Esteso** routing in `hub-orchestration.mdc` con amplificatori Cursor (canvas/babysit/loop/review/hook) e hard exclude out-of-scope.
3. **Non** creato hook progetto ancora: valore alto solo dopo matcher mirato (es. `beforeShellExecution` su apply/defender); evitare rumore sessionStart.
4. **Non** wrappare Cloudflare/PLC/SEO nel catalogo Hub.

## Prossimi candidati (solo se ricorrenti)

- Hook progetto `beforeShellExecution` per comandi mutanti HITL (deny/ask)
- Skill `hub-parity-smoke` se parity CS/PS diventa settimanale
