# Workspace Agents Policy

## Default operating mode
Use the custom agent `windows-optimization-guardian` for system-management and optimization tasks in this workspace.

## Required quality gate
For every optimization request:
1. Provide best next decision.
2. Include anti-regression checks and fallback.
3. Keep actions aligned to continuous Windows optimization purpose.
4. Record objective, task, changes, decisions, and outcome in KB.

## Operational guardrails
- Prefer PowerShell Core when available, otherwise fallback to Windows PowerShell.
- Start with observation/audit mode before destructive actions.
- Use low-overhead automation and measurable outcomes.
