# Decision — addyosmani/agent-skills subset (2026-09-07)

Source: https://github.com/addyosmani/agent-skills

## Why not all 25

Full pack as always-on context wastes tokens and fights existing hub skills (prompt-gate, hub-orchestrate, legal-gate). Cursor setup for this pack: sync selected skills into `.cursor/skills/`, one thin routing rule.

## Installed here

- `using-agent-skills`
- `git-workflow-and-versioning`
- `debugging-and-error-recovery`
- `documentation-and-adrs`
- `code-review-and-quality`

## Not installed (on purpose)

interview-me, idea-refine, spec-driven-development, constraint-driven-development, doubt-driven-development, source-driven-development, deprecation-and-migration, code-simplification — overlap with prompt-gate / hub-orchestrate or not this stack.

## Legal

No change to legal-path. Skills are engineering workflows, not a new money rail.
