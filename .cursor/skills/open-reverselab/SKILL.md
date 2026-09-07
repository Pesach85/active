---
name: open-reverselab
description: >-
  Point at the hub vendor clone of LING71671/open-reverselab (APK/PE lab) when
  reversing a founder-owned Android or Windows binary. Use on allowlisted
  android/windows repos or the hub lab. Never run CTF/Web attack boards against
  third-party sites. Not for Arduino, plant-pending, or forks. Pair with
  reverse-owned and legal-gate.
---

# Open ReverseLab (owned APK/PE only)

Upstream lab: https://github.com/LING71671/open-reverselab (GPL-3.0). Directory listing: https://skillsllm.com/skill/open-reverselab

This is a **separate lab workspace**, not a skill to paste into every repo. Hub clone (gitignored): `vendor/open-reverselab`.

## Real effort

| Piece | Effort | We do |
|-------|--------|--------|
| Thin Cursor skill + board map | S | yes, this file |
| Vendor clone on hub | M | yes, gitignored |
| `install_tools.ps1 -CTF/-Android/-Windows` + 100 MCP | L | **no** by default |
| Copy 180 KB attack articles into each project | L + licence + plant risk | **no** |

## When this skill applies

Allowlist + board: hub `config/open_reverselab_scope.json`. Requires `reverse-owned` (founder owns or write-auth).

| Board | Repos |
|-------|--------|
| android | `app_android_thermo`, `thermoApp`, `active` (has `mobile/`) |
| windows | `active`, `HelloWinforms_CSV_ELABS`, `UpsCommunicationProject` |
| lab | `ollama-kb-market-engine`, `project-intelligence-hub` (pointer only) |

Arduino, tiny utilities, Python thermostats, plant/customer pending, forks: **out**. Use `knowledge-analysis` / `reverse-owned` instead.

## Allowed ACT

Only on **this** repo's APK/PE/build, or a sample the founder owns and dropped in the lab `samples/` (never commit malware to git). Workflow: copy sample → work in `vendor/open-reverselab` → keep reports out of plant public dumps.

## Forbidden

- `boards/ctf-website` against a URL you do not own (SQLi/SSRF/jwt_tool/sqlmap).
- Game cheat / anti-cheat (EAC/BE/Vanguard) modules.
- Windows privilege-escalation / process-injection KB as a playbook against anything but an owned test VM.
- 24h unattended CTF loops (`.claude/workflows/ctf-24h-*`).
- Wiring `reverse_lab_tools` MCP into this hub's `.cursor/mcp.json` without an explicit ask.
- Rsync of `kb/` into Ferraro/Comete/Presse.

## Knowledge without ACT

Reading how PE/APK loading works, citing public docs → `knowledge-analysis`. ReverseLab articles stay in the vendor tree.

Canonical: `docs/knowledge/decisions/2026-09-07_open-reverselab.md`
