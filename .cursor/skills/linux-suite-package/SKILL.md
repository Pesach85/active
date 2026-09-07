---
name: linux-suite-package
description: >-
  Package Linux Optimizer suite (scripts, config, self-contained hub CLI).
  Use when user asks package Linux, Linux suite, dist/LinuxOptimizer, or
  publish hub for linux-x64/linux-arm64.
---

# Linux suite package

## Quando usare

- Packaging `dist/LinuxOptimizer` dopo change Linux scripts/config/CLI
- Utente chiede package Linux / suite Linux / publish hub Linux

## Sequenza

Dalla root repo (`active/`):

```powershell
powershell -NoProfile -File scripts/package-linux-suite.ps1
```

Runtime ARM:

```powershell
powershell -NoProfile -File scripts/package-linux-suite.ps1 -Runtime linux-arm64
```

## Verifica

- Messaggio `Linux package ready at:` + path
- Presenti: `dist/LinuxOptimizer/bin/hub`, `scripts/linux/*`, `config/*`, `README.txt`
- Install on-device (solo se host Linux/WSL e richiesto):

```bash
chmod +x scripts/linux/install-linux-suite.sh
./scripts/linux/install-linux-suite.sh
hub version
```

## Hard don'ts

- Non eseguire install Linux su Windows host nativo senza WSL/target remoto.
- Non dichiarare package OK se `dotnet publish` fallisce.
- Non mutare systemd timers senza richiesta esplicita.
