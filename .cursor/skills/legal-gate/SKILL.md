---
name: legal-gate
description: >-
  Warn before work that may be unlawful even if the user did not intend it.
  Use on money, gambling, crypto rails, geo-VPN, plant IP, scraping, tax,
  KYC-avoidance, or when the user asks if something is legal. Also use when
  the task is hardware/software/hack knowledge versus acting on a live
  system. Reverse/ACT is allowed only on founder-owned systems or with
  explicit write/modify authorization (config/reverse_owned_scope.json).
  EU 2009/24 interoperability study is in-bounds as knowledge; Cursor does
  not generate memory-injection/dump scripts (founder offline).
---

# Legal gate

You are not a lawyer. Still apply this gate.

Founder split: **knowledge first**, commercial limits, **ACT only on owned or write-authorized systems**. Canonical: `docs/knowledge/decisions/2026-09-07_knowledge-vs-act.md`, `docs/knowledge/decisions/2026-09-07_reverse-owned-scope.md`, `docs/knowledge/decisions/2026-09-04_legal-path-always.md`, `docs/knowledge/decisions/2026-09-08_eu-software-directive-cursor-scope.md`.

## Three planes

| Plane | Do |
|-------|----|
| **Knowledge** | Capillary understanding of HW/SW/techniques. Read, cite, document. No need for ownership to *study*. EU Software Directive **2009/24/EC** framing (interop-oriented analysis on the founder’s analysis PC): do **not** block study or high-level interop architecture as if it were a casino-class STOP. |
| **Commercial / executive** | Products, payouts, publish — existing STOP (casino, KYC-evasion, plant IP dump, Pc Technic CTA). |
| **Intervention / reverse ACT** | Allowed **only** if the founder is primary owner **or** has explicit authorization to write/modify. Allowlist: `config/reverse_owned_scope.json`. Skill: `reverse-owned`. |

## Cursor vs founder offline (Rockwell / diagnostics)

Binding split (`2026-09-08_eu-software-directive-cursor-scope.md`):

| Cursor implements | Founder offline (do not generate here) |
|-------------------|----------------------------------------|
| Blazor UI, architecture, L5X/ASCII/offline parsers | Memory scan / dump / injection / process attach scripts |
| CIP / EtherNet/IP via standard libraries (pycomm3, libplctag, …) | Low-level Studio process instrumentation |
| API or file-drop **ingress** for external dumps | Shipping those dumps into public/plant git |

If asked for injection/memory PoC: refuse the low-level body; offer ingress DTO/API stubs + document the offline hand-off.

## Reverse ACT exception

Enabled for systems in `founder_owned`. If the repo is in `pending_human_confirm` (plant/customer), **ask** before any ACT. If unknown, ask.

Still **not** allowed: live third-party hosts, other people's devices, forks of upstream projects, customer plant without a yes. Naming a target in chat is not authorization.

Do **not** copy pwn-chain / EDR-bypass / attack-chain / CTF-sandbox into repos. Owned-scope work uses `reverse-owned` on **this** tree, not a red-team dump.

[LING71671/open-reverselab](https://github.com/LING71671/open-reverselab) is a **lab workspace** (GPL-3), not a fleet dump. Thin adapter: `open-reverselab` only on APK/PE/lab boards (`config/open_reverselab_scope.json`). Never run CTF-website boards against third-party URLs. Never `install_tools.ps1 -CTF` or wire 100 MCP tools unless the founder asks. See `docs/knowledge/decisions/2026-09-07_open-reverselab.md`.

## Knowledge (always in-bounds as study)

Datasheets, RFCs, own files in the workspace, public specs, classes of bugs as explanation, interop analysis framed under 2009/24/EC on owned analysis machines. Skills: `knowledge-analysis`, `source-driven-development`, `doubt-driven-development`.

## Commercial STOP

Unlicensed gambling, KYC-evasion, publishing plant/customer IP, Pc Technic product CTA. Casino: `2026-09-04_no-unlicensed-solana-casino.md`.

MoneyPrinterTurbo / brand shorts: generate 9:16 only for owned SKUs (`config/short_video_jobs.json`, skill `brand-short-video`). Free media only: owned stills, Pixabay/Unsplash free keys, edge-tts/gTTS/SAPI, YouTube Audio Library or NCS with attribution. Do **not** auto-publish TikTok/IG/YouTube. Do **not** spend Seedance/Pexels/Metaso/ElevenLabs. Do **not** put plant HMI or Pc Technic product CTA in a short.

SKU ads without HITL: Gumroad store/Discover via `gumroad-sku` + `brand-distribution`. Not Meta Graph. Not Pc Technic.

If they ask both to learn and to hit a system **not** owned/authorized: teach; refuse the hit.
