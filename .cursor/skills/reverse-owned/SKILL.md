---
name: reverse-owned
description: >-
  Enable reverse-engineering / debug / instrumentation ACT only on systems the
  founder owns or has explicit write/modify authorization for. Use when working
  on an allowlisted repo (config/reverse_owned_scope.json), the founder's own
  hardware, or after they name a written authorization. Never use against
  third-party live systems. Not a licence to load pwn/EDR-bypass/attack-chain
  playbooks onto customer plant.
---

# Reverse on owned systems only

You are not a lawyer. Founder exception (2026-09-07): [reverse-skill](https://github.com/zhaoxuya520/reverse-skill)-class **ACT** is allowed **only** when:

1. The founder is the **primary owner** of the system/repo/device, or
2. They have **explicit authorization to write/modify** it.

Allowlist: hub `config/reverse_owned_scope.json` (`founder_owned`). If the repo is in `pending_human_confirm`, **ask** before any ACT. If not in the file, ask.

Canonical: `docs/knowledge/decisions/2026-09-07_reverse-owned-scope.md`

## Check before ACT

```
1. Name the system in ordinary language (which repo, which device, which host).
2. Is it founder_owned in reverse_owned_scope.json? → ACT on THAT tree/device only.
3. pending_human_confirm → stop and ask.
4. Someone else's production / fork / random IP / customer plant without yes → STOP (legal-gate).
```

Naming a hostname in chat is still not authorization.

## What ACT may mean here

On an allowlisted **owned** codebase or device: debug, instrument, decompile **our** build, patch **our** firmware, test **our** app. Keep plant/customer IP out of public git.

## Still forbidden (even on a PC you own)

- Targeting a third-party service, someone else's phone, or a plant you do not own/are not authorized to modify.
- Shipping pwn-chain / EDR-bypass / attack-chain / CTF-sandbox modules into a repo (those playbooks are for attacking, not for owning your app).
- Publishing Ferraro/Comete/Presse dumps.

Hub vendor clone of reverse-skill (if present, gitignored) is **reference for owned-scope work only**, not a global pentest kit.

## Knowledge plane

Public techniques without touching a foreign system → `knowledge-analysis`. Do not refuse study; refuse off-scope ACT.
