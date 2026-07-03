# Browser Automation — Quando e Quale MCP

Concetti assimilati da [stealth-browser-mcp](https://github.com/vibheksoni/stealth-browser-mcp).

## Regola d'oro

**Non usare browser automation se una API o uno script locale è sufficiente.**

PowerShell + WMI + Event Log + registry coprono la maggior parte della manutenzione Windows.

## Quando serve il browser

| Scenario | Strumento consigliato |
|----------|----------------------|
| Verifica UI locale / dev | cursor-ide-browser (già in Cursor) |
| Portale vendor con login | stealth-browser-mcp |
| Cloudflare / anti-bot | stealth-browser-mcp |
| Download da dashboard web | stealth-browser-mcp o API se disponibile |
| Monitoraggio stock/prezzi online | stealth-browser-mcp + hook rete |
| Scraping documentazione pubblica | Fetch HTTP o stealth-browser |

## cursor-ide-browser vs stealth-browser-mcp

| Aspetto | cursor-ide-browser | stealth-browser-mcp |
|---------|-------------------|---------------------|
| Setup | Integrato Cursor | Install Python + venv separato |
| Anti-bot | Limitato | nodriver + CDP, bypass Cloudflare |
| Tool count | ~15 snapshot/click | 97 modulabili (20 minimal) |
| Uso tipico SOH | Test GUI web | Portali cloud, vendor, M365 admin |

## Workflow stealth-browser (se installato)

1. `spawn_browser()` → crea istanza
2. `navigate()` → URL target
3. Interazione (`click_element`, `type_text`, `paste_text`)
4. Verifica stato (`get_instance_state`, screenshot)
5. `close_instance()` → cleanup obbligatorio

Modalità minimal per ridurre rumore tool:

```powershell
python src/server.py --minimal
```

## Setup opzionale (non incluso nel repo)

```powershell
git clone https://github.com/vibheksoni/stealth-browser-mcp.git
cd stealth-browser-mcp
python -m venv venv
.\venv\Scripts\activate
pip install -r requirements.txt
```

Configurazione Cursor MCP in `%APPDATA%\Cursor\User\globalStorage\...` o settings MCP — path assoluti al venv Python.

## Guardrail

- Non esporre HTTP transport senza `STEALTH_BROWSER_MCP_AUTH_TOKEN`
- `BROWSER_FILE_UPLOAD_ALLOWED_DIRS` per limitare upload
- Chiudere istanze browser dopo ogni sessione
- Credenziali mai in repo — usform env vars

## Riferimenti

- [decision-framework.md](decision-framework.md)
- Skill upstream: `skills/stealth-browser-mcp/SKILL.md` nel repo stealth-browser
