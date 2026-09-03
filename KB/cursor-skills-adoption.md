# Cursor skills — adozione (2026-09-04)

## Fonti analizzate

| Fonte | Cosa offre | Decisione Hub |
|-------|------------|---------------|
| [fable-orchestration/SKILL.md](https://github.com/per-simmons/fable-orchestration/blob/master/SKILL.md) | Architect/delegate, effort caps, paste-in prompt kit, verify loops, anti-overplan | **Adottato** il prompt kit comportamentale (act / no tidy / ground claims / boundaries / autonomous / memory). **Non** adopted: wiring Claude Fable/Opus, `/effort`, plugin Codex — fuori stack Cursor Hub |
| [chrisboden/cursor-skills](https://github.com/chrisboden/cursor-skills) | Orchestrator vs Pair Programmer, skills MCP (`list`/`invoke`/`import`), skill-creator, document skills | **Adottato** dual-role + anatomia `SKILL.md` + skill-creator Hub-scoped. **Non** adopted: MCP Python `skills_mcp.py` (Cursor ha discovery nativa in `.cursor/skills/`); docx/pdf/artifacts (fuori prodotto) |

## Cosa è stato installato nel repo

```
.cursor/rules/hub-orchestration.mdc          # alwaysApply — routing + prompt kit
.cursor/skills/hub-quality-gate/SKILL.md
.cursor/skills/android-on-device-maintenance/SKILL.md
.cursor/skills/hub-kb-commit-push/SKILL.md
.cursor/skills/skill-creator/SKILL.md
.cursor/skills/hub-hitl-migration-decision/  # già presente
docs/skills/transparency-control/            # già presente
```

## Perché non MCP chrisboden

- Overhead (uv/Python MCP) per capability già coperte da Cursor Skills nativi
- Import community (docx/pdf) non necessari al Hub
- Possibile re-valutare se serve `import_skill` massivo da GitHub

## Mapping comportamenti Fable → Hub

| Kit Fable | Implementazione Hub |
|-----------|---------------------|
| Act don't overplan | `hub-orchestration.mdc` |
| No unrequested tidying | idem + user rules |
| Delegate subagents | Task/parallel tools Cursor |
| Ground progress | quality-gate + smoke skills |
| Boundaries assess vs fix | hub-orchestration |
| Memory one lesson/file | `hub-kb-commit-push` + KB updates |
| Effort cap / Fable routing | N/A (modello Cursor session) |

## Prossimi skill candidati (non creati ora)

- `linux-suite-package` — package/install Linux
- `windows-dev-sync` — junction + Inno
- Solo se i flussi diventano ricorrenti settimana per settimana
