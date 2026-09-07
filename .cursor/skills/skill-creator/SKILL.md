---
name: skill-creator
description: >-
  Create or update a Cursor skill (SKILL.md) for SystemOptimizerHub. Use when
  the user asks for a new skill, to capture a recurring workflow, or to package
  domain knowledge into .cursor/skills/.
---

# Skill creator (Hub)

## Anatomia

```
.cursor/skills/<skill-name>/
  SKILL.md          # required — YAML frontmatter + instructions
  scripts/          # optional helpers
  reference.md      # optional deep docs
```

Skills documentali legacy possono vivere in `docs/skills/<name>/SKILL.md` (es. transparency-control). Preferire `.cursor/skills/` per discovery Cursor nativa.

## Frontmatter

```yaml
---
name: short-kebab-name
description: >-
  What it does and WHEN to use it (third person). Include trigger phrases.
---
```

`description` decide quando l'agente carica la skill — essere specifici.

## Stile istruzioni

- Imperativo / infinito ("Eseguire X", "Leggere Y")
- Scope stretto; puntare a path reali del repo
- Includere comandi PowerShell copy-pasteabili
- Hard don'ts se il dominio ha rischi (HITL, mutazioni, WebView)

## Workflow

1. Chiedere (o inferire) scopo + trigger + gate
2. Creare directory + `SKILL.md`
3. Se workflow ricorrente, aggiungere riga in `.cursor/rules/hub-orchestration.mdc` tabella routing
4. Aggiornare `KB/cursor-skills-adoption.md` se cambia il catalogo

## Non creare skill per

- One-off trivial
- Cose già coperte da user rules o AGENTS.md
- Domini esterni (docx/pdf generici) non usati dal Hub
