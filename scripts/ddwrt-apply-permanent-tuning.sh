#!/bin/sh
# DD-WRT permanent tuning - hotspot client WAN -> LAN switch (TL-WR740N v4)
# Safe: does NOT set wl0_radio=0 (would kill STA client on single-radio)
BACKUP="/tmp/nvram-ddwrt-opt-backup-$(date +%Y%m%d-%H%M%S).txt"
nvram show | grep -E '^wl|^wan_|^lan_|^dhcp|^dns|^cron|^sshd|^telnet|^remote|^info_|^rc_' > "$BACKUP" 2>/dev/null || true
echo "BACKUP=$BACKUP"

nvram set wan_dns="1.1.1.1 8.8.8.8"
nvram set dhcp_dns="1.1.1.1 8.8.8.8"
nvram set dnsmasq_enable=1
nvram set dnsmasq_no_dns_rebind=1
nvram set dnsmasq_strict=1
nvram set dnsmasq_options="strict-order"
nvram set dnsmasq_cachesize=150
nvram set wan_mtu=1500
nvram set wan_ttlfix=1

# 3. Configurazione Modalità di Rete Wireless (2.4GHz N-Only)
nvram set wlan0_net_mode="nonly"
nvram set ath0_net_mode="nonly"

# 3. Configurazione Wireless (Solo standard wlan0 per Atheros)
nvram set wlan0_mode="sta"
nvram set wlan0_ssid="SmartConnect-Fzcwkcxitg"
nvram set wlan0_security_mode="psk2"
nvram set wlan0_crypto="aes"

nvram set wlan0_wpa_psk="12345678"

nvram set wlan0_channelbw=20
nvram set wlan0_intmit=1
nvram set wlan0_wmm=1
nvram set wlan0_bgscan_mode="disable"
nvram set wlan0_akm=psk2             # Forza WPA2-PSK (comune per gli hotspot smartphone)
nvram set wlan0_wpa_gtk_rekey=0
nvram set wlan0_user_preamble=1

nvram set telnetd_enable=0
nvram set remote_management=0
nvram set sshd_enable=1
nvram set sshd_passwd_auth=1
nvram set sshd_port=22
nvram set sshd_forwarding=0

nvram set https_enable=0

# 2. Disattiva il demone dei log di sistema e i servizi di statistica sul traffico (ttraff)
nvram set syslog_enable=0
nvram set ttraff_enable=0

# Riduci i timeout delle connessioni TCP per liberare la RAM più velocemente
nvram set ip_conntrack_max=512
nvram set tcp_established_timeout=600
nvram set tcp_udp_timeout=30


# 6. Scrittura dello script RC_STARTUP (Parametri TCP + Generazione Watchdog)
RC_STARTUP='#!/bin/sh
[ -d /proc/sys/net/ipv4 ] || exit 0
echo 1 > /proc/sys/net/ipv4/tcp_window_scaling 2>/dev/null
echo 0 > /proc/sys/net/ipv4/tcp_timestamps 2>/dev/null
echo 1 > /proc/sys/net/ipv4/tcp_sack 2>/dev/null
echo 131072 > /proc/sys/net/core/rmem_max 2>/dev/null
echo 131072 > /proc/sys/net/core/wmem_max 2>/dev/null
echo "4096 87380 131072" > /proc/sys/net/ipv4/tcp_rmem 2>/dev/null
echo "4096 65536 131072" > /proc/sys/net/ipv4/tcp_wmem 2>/dev/null
echo 1 > /proc/sys/net/ipv4/tcp_tw_reuse 2>/dev/null

# Generazione dinamica del file watchdog in /tmp al boot
echo "#!/bin/sh" > /tmp/watchdog_wifi.sh
echo "log() { logger \"[WIFI-WD] \$1\"; }" >> /tmp/watchdog_wifi.sh
echo "if ping -c 2 -W 2 1.1.1.1 >/dev/null 2>&1 || ping -c 2 -W 2 8.8.8.8 >/dev/null 2>&1; then exit 0; fi" >> /tmp/watchdog_wifi.sh
echo "log \"No internet detected\"" >> /tmp/watchdog_wifi.sh
echo "if ! ifconfig wlan0 | grep -q \"inet addr\"; then" >> /tmp/watchdog_wifi.sh
echo "  log \"Reset wlan0 interface\"" >> /tmp/watchdog_wifi.sh
echo "  ifconfig wlan0 down && sleep 2 && ifconfig wlan0 up" >> /tmp/watchdog_wifi.sh
echo "  sleep 15" >> /tmp/watchdog_wifi.sh
echo "  if ping -c 2 -W 2 1.1.1.1 >/dev/null 2>&1; then log \"Recovered after interface reset\"; exit 0; fi" >> /tmp/watchdog_wifi.sh
echo "fi" >> /tmp/watchdog_wifi.sh
echo "log \"DHCP renew attempt\"" >> /tmp/watchdog_wifi.sh
echo "killall -SIGUSR1 udhcpc 2>/dev/null" >> /tmp/watchdog_wifi.sh
echo "sleep 10" >> /tmp/watchdog_wifi.sh
echo "if ping -c 2 -W 2 1.1.1.1 >/dev/null 2>&1; then exit 0; fi" >> /tmp/watchdog_wifi.sh
echo "log \"Full wireless restart fallback (No Reboot)\"" >> /tmp/watchdog_wifi.sh
echo "/sbin/stopservice wl && sleep 2 && /sbin/startservice wl" >> /tmp/watchdog_wifi.sh

chmod +x /tmp/watchdog_wifi.sh
'
nvram set rc_startup="$RC_STARTUP"

# 7. Configurazione del Cronjob attivo ogni 5 minuti
CRON_JOB="*/5 * * * * root /tmp/watchdog_wifi.sh"
nvram set cron_jobs="$CRON_JOB"
nvram set cron_enable=1

# 8. Salvataggio definitivo in NVRAM
nvram commit

echo "=== COMPLETATO ==="
echo "Il router si riavvierà in modo pulito tra 2 secondi..."

# Esegue il reboot disaccoppiando la sessione SSH per evitare l'errore 255
(sleep 2 && reboot) &
exit 0

echo DONE
