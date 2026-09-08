---
name: reverse-owned
description: >-
  Enable reverse-engineering / debug / instrumentation ACT only on systems the
  founder owns or has explicit write/modify authorization for. Static low-level
  analysis on owned offline files is in-bounds (EU 2009/24). Live process-attach
  / memory-injection stay founder-offline or refuse. Never use against
  third-party live systems. Not a licence to load pwn/EDR-bypass/attack-chain
  playbooks onto customer plant.
---

# Reverse on owned systems only

You are not a lawyer. Founder exception (2026-09-07): [reverse-skill](https://github.com/zhaoxuya520/reverse-skill)-class **runtime ACT** is allowed **only** when:

1. The founder is the **primary owner** of the system/repo/device, or
2. They have **explicit authorization to write/modify** it.

Allowlist: hub `config/reverse_owned_scope.json` (`founder_owned`). If the repo is in `pending_human_confirm`, **ask** before any **runtime** ACT. If not in the file, ask.

Flags: `static_knowledge_allowed` = true; `runtime_intervention_forbidden` for live attach/injection in Cursor.

Canonical: `docs/knowledge/decisions/2026-09-07_reverse-owned-scope.md`, `docs/knowledge/decisions/2026-09-08_eu-software-directive-cursor-scope.md`.

## Check before ACT

```
1. Name the system in ordinary language (which repo, which device, which host).
2. Is it founder_owned in reverse_owned_scope.json? → ACT on THAT tree/device only.
3. pending_human_confirm → stop and ask (runtime). Static offline parsers may still be OK if high_level_cursor_ok_while_pending or knowledge-only.
4. Someone else's production / fork / random IP / customer plant without yes → STOP (legal-gate).
5. Live process-attach / memory-injection → refuse in Cursor; offer static parser / mock-sandbox / ingress; founder offline OK.
```

Naming a hostname in chat is still not authorization.

## What ACT may mean here

On an allowlisted **owned** codebase or device:

- **Static (Cursor OK):** parse/analyze owned offline binaries, firmware dumps, L5X, packed structs, layout maps, decoding algorithms.
- **Owned product work:** debug, instrument, decompile **our** build, patch **our** firmware, test **our** app — without live third-party process attach scripts from Cursor.
- Keep plant/customer IP out of public git.

## Still forbidden (even on a PC you own)

- Targeting a third-party service, someone else's phone, or a plant you do not own/are not authorized to modify.
- Shipping pwn-chain / EDR-bypass / attack-chain / CTF-sandbox modules into a repo (those playbooks are for attacking, not for owning your app).
- Publishing Ferraro/Comete/Presse dumps.
- Cursor-generated **live** process-attach / memory-injection / network-active exploit scripts (use static substitute or founder offline).

Hub vendor clone of reverse-skill (if present, gitignored) is **reference for owned-scope work only**, not a global pentest kit.

Owned APK/PE lab: hub `vendor/open-reverselab` + skill `open-reverselab` if this repo is on `config/open_reverselab_scope.json`. Do not run CTF-website boards against URLs you do not own.

## Cursor agent scope vs founder offline (2026-09-08 refined)

| Cursor may implement | Cursor must refuse to generate |
|----------------------|--------------------------------|
| Architecture, Blazor UI, L5X/ASCII parsers, CIP via libs | Live memory scan / dump / injection / process-attach scripts |
| **Static** low-level byte/layout/decoding on owned offline files | Studio/process address-space instrumentation **PoCs that attach live** |
| Ingress API / file-drop for external dumps | Shipping plant IP or third-party process dumps into public git |
| Abstract byte-parser / mock-sandbox when runtime would be dangerous | Network-active exploit scripts |

Interop-oriented **static** study on the founder’s analysis PC is framed under EU Directive **2009/24/EC** — do not treat that study as a commercial STOP.

## Knowledge plane

Public techniques without touching a foreign live system → `knowledge-analysis`. Do not refuse **static** study; refuse off-scope ACT and refuse Cursor-side **live** memory-injection bodies (offer static parser / ingress stubs instead).
