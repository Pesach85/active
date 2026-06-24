# Playbook DD-WRT — Hotspot Client → LAN Switch (TL-WR740N v4)

## Obiettivo
Condividere la connessione **hotspot mobile** sulla rete LAN/switch via router DD-WRT, con tuning permanente, accesso SSH automatizzabile e pattern riusabili anti-regressione.

## Topologia validata
```
Telefono (hotspot SmartConnect-…)
    ↓ WiFi client (wlan0 mode=sta, wpa_supplicant)
DD-WRT TL-WR740N @ 192.168.1.250 (WAN IP carrier es. 10.60.134.x)
    ↓ NAT (lan2wan)
Switch Ethernet → PC @ 192.168.1.125
```

## Hardware / firmware
| Voce | Valore |
|------|--------|
| Modello | TP-Link TL-WR740N v4 |
| Firmware | DD-WRT v3.0-r63600 std |
| Radio | Single 2.4 GHz — **non** usare AP + client pesante sulla stessa radio |

---

## Pattern validati (problema → soluzione)

### Pattern 1 — Verificare routing hotspot→LAN senza login web
**Problema:** curl/web login fallisce (401/CSRF) ma serve capire se il routing funziona.

**Diagnosi:**
```powershell
curl.exe -s http://192.168.1.250/Info.live.htm
```
Cercare: `wan_ipaddr` (IP carrier), `dhcp_leases` (PC LAN), `active_wireless` (link client).

**Esito validato:** WAN `10.60.134.3`, PC `192.168.1.125`, segnale `-36 dBm`, link ~346 Mbit/s.

---

### Pattern 2 — Login web vs SSH (credenziali diverse)
**Problema:** `admin` + password funziona in browser ma curl/telnet fallisce.

**Soluzione validata:**
| Canale | Utente | Note |
|--------|--------|------|
| Web UI | `admin` | Password con punto: `PAS85.Tano76` |
| SSH shell | **`root`** | Stessa password; `admin` SSH → `Permission denied (publickey)` |
| Telnet | — | **Disabilitato** in produzione (`telnetd_enable=0`) |

**SSH key auth:** chiave privata locale `ddwrtkey/id_ed25519.ssh` (gitignored). Host key live fingerprint: `SHA256:ceUAjftyAXCoAkYgOfHlb/qsjhqZHMBCN+hCeOHuJjM`.

---

### Pattern 3 — Disabilitare AP `dd-wrt` senza killare client hotspot
**Problema:** Single-radio fa client verso telefono **e** AP `dd-wrt` → spreco banda.

**Diagnosi NVRAM:**
```
nvram get wlan0_mode   → sta
nvram get wl0_mode     → ap
nvram get wl0_ssid     → dd-wrt
```

**Fix permanente (safe):**
```
nvram set wl0_bss_enabled=0
nvram set wl0_closed=1
nvram set wl0_ssid=
nvram commit
stopservice wl; startservice wl
```
**Non usare** `wl0_radio=0` — spegne l'intera radio incluso il client STA.

**Verifica post:** `wlan0_mode=sta`, `ifconfig wlan0` ha IP carrier, `ping 1.1.1.1` OK.

---

### Pattern 4 — DNS stabili su LAN e WAN
**Problema:** `wan_dns` vuoto → solo DNS dell'hotspot (instabili).

**Fix permanente:**
```
nvram set wan_dns="1.1.1.1 8.8.8.8"
nvram set dhcp_dns="1.1.1.1 8.8.8.8"
nvram set dnsmasq_options="strict-order"
nvram set dnsmasq_no_dns_rebind=1
nvram commit
killall -HUP dnsmasq
```

**Verifica:** `nvram get wan_dns` → `1.1.1.1 8.8.8.8`.

---

### Pattern 5 — Hotspot mobile che va in sleep
**Problema:** Sessione WAN mobile scade dopo idle.

**Fix permanente (cron DD-WRT):**
```
*/5 * * * * root ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1
```
`nvram set cron_enable=1` + `nvram commit`.

---

### Pattern 6 — MTU ottimale su WAN mobile
**Problema:** MTU 1500 può causare frammentazione su hotspot.

**Fix permanente:** `nvram set wan_mtu=1492` + `nvram commit`.

**Rollback:** `nvram set wan_mtu=1500` se siti/VPN smettono di funzionare.

---

### Pattern 7 — TCP/NAT sysctl persistenti al boot
**Problema:** Tuning Sysctl tab non sopravvive sempre al reboot su build MIPS.

**Fix permanente:** script in `rc_startup` NVRAM (vedi `scripts/ddwrt-apply-permanent-tuning.sh`).

Valori applicati: `tcp_window_scaling`, `tcp_sack`, `rmem_max/wmem_max=262144`, buffer TCP r/w mem.

---

### Pattern 8 — Hardening Administration
**Problema:** Telnet + Remote Web UI + Allow any Remote IP = superficie attacco.

**Fix permanente validato:**
| NVRAM | Valore |
|-------|--------|
| `telnetd_enable` | 0 |
| `remote_management` | 0 |
| `sshd_enable` | 1 |
| `sshd_passwd_auth` | 1 |
| `sshd_port` | 22 |

---

### Pattern 9 — Script shell Windows → DD-WRT (CRLF trap)
**Problema:** `scp` + `sh script.sh` fallisce: `set -e: illegal option -` (CRLF).

**Soluzione validata:** pipe LF-normalized via SSH:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\apply-ddwrt-permanent-tuning.ps1
```
Repo: `.gitattributes` forza `*.sh` → LF.

---

### Pattern 10 — NVMe Kingchungxing assente (DESKTOP-V1E32CE)
**Problema:** Disco NVMe M.2 non rilevato.

**Diagnosi validata:**
- Controller PCIe `AMD-RAID Bottom Device` (1987:5012) **OK**
- **Zero** dischi NVMe in `Get-Disk` / WMI — solo 3 SATA
- `stornvme` stopped (nessun device da bindare)
- Nessun errore PnP storage

**Conclusione:** esaurita diagnosi software → **hardware check** (reseating M.2, BIOS slot, test USB Linux live).

---

## Apply automatizzato (permanente)
```powershell
# Audit (read-only)
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\apply-ddwrt-permanent-tuning.ps1 -AuditOnly

# Apply + verify on router
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\apply-ddwrt-permanent-tuning.ps1
```

Backup NVRAM automatico sul router: `/tmp/nvram-ddwrt-opt-backup-*.txt`

## Check anti-regressione post-tuning
1. `nvram get wlan0_mode` = `sta`
2. `ifconfig wlan0` → IP carrier (10.x.x.x)
3. `ping -c 2 1.1.1.1` → 0% loss
4. PC LAN: gateway `192.168.1.250`, navigazione OK
5. `nvram get wl0_bss_enabled` = `0` (AP dd-wrt off)
6. `nvram get wan_dns` = `1.1.1.1 8.8.8.8`

## Rollback rapido
```sh
# Su router via SSH root — ripristino da backup
sh /tmp/nvram-ddwrt-opt-backup-YYYYMMDD-HHMMSS.txt  # manual nvram set lines
nvram commit
reboot
```

Oppure: **Administration → Backup → Restore** (se backup GUI esiste).

## Stato finale validato (2026-06-25)
| Parametro | Valore |
|-----------|--------|
| wan_dns | 1.1.1.1 8.8.8.8 |
| wan_mtu | 1492 |
| wlan0_mode | sta |
| wl0_bss_enabled | 0 |
| telnetd_enable | 0 |
| remote_management | 0 |
| sshd_enable | 1 |
| cron keepalive | ogni 5 min |
| rc_startup | TCP sysctl |

Log apply: `logs/ddwrt-permanent-tuning.out.txt`
