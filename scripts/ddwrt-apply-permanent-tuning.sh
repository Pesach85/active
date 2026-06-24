#!/bin/sh
# DD-WRT permanent tuning - hotspot client WAN -> LAN switch (TL-WR740N v4)
# Safe: does NOT set wl0_radio=0 (would kill STA client on single-radio)
set -e

BACKUP="/tmp/nvram-ddwrt-opt-backup-$(date +%Y%m%d-%H%M%S).txt"
nvram show | grep -E '^wl|^wan_|^lan_|^dhcp|^dns|^cron|^sshd|^telnet|^remote|^info_|^rc_' > "$BACKUP" 2>/dev/null || true
echo "BACKUP=$BACKUP"

nvram set wan_dns="1.1.1.1 8.8.8.8"
nvram set dhcp_dns="1.1.1.1 8.8.8.8"
nvram set dnsmasq_enable=1
nvram set dnsmasq_no_dns_rebind=1
nvram set dnsmasq_strict=1
nvram set dnsmasq_options="strict-order"
nvram set dnsmasq_cachesize=1500
nvram set wan_mtu=1492
nvram set wan_ttlfix=1

nvram set wl0_bss_enabled=0
nvram set wl0_closed=1
nvram set wl0_ssid=
nvram set wl0_ap_isolate=0

nvram set wlan0_channelbw=20
nvram set wlan0_net_mode=ng-only
nvram set wlan0_intmit=1
nvram set wlan0_wmm=1
nvram set wlan0_bgscan_mode=simple

nvram set telnetd_enable=0
nvram set remote_management=0
nvram set sshd_enable=1
nvram set sshd_passwd_auth=1
nvram set sshd_port=22
nvram set sshd_forwarding=1

CRON="$(nvram get cron_jobs 2>/dev/null)"
echo "$CRON" | grep -q '1.1.1.1' || CRON="${CRON}*/5 * * * * root ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1
"
nvram set cron_enable=1
nvram set cron_jobs="$CRON"

RC_STARTUP='#!/bin/sh
# DD-WRT permanent TCP/NAT tuning (active repo)
[ -d /proc/sys/net/ipv4 ] || exit 0
echo 1 > /proc/sys/net/ipv4/tcp_window_scaling 2>/dev/null
echo 1 > /proc/sys/net/ipv4/tcp_timestamps 2>/dev/null
echo 1 > /proc/sys/net/ipv4/tcp_sack 2>/dev/null
echo 262144 > /proc/sys/net/core/rmem_max 2>/dev/null
echo 262144 > /proc/sys/net/core/wmem_max 2>/dev/null
echo "4096 87380 262144" > /proc/sys/net/ipv4/tcp_rmem 2>/dev/null
echo "4096 65536 262144" > /proc/sys/net/ipv4/tcp_wmem 2>/dev/null
echo 1 > /proc/sys/net/ipv4/tcp_tw_reuse 2>/dev/null
'
nvram set rc_startup="$RC_STARTUP"

nvram commit

killall -HUP dnsmasq 2>/dev/null || true
printf '%s' "$RC_STARTUP" > /tmp/apply-sysctl.sh
sh /tmp/apply-sysctl.sh 2>/dev/null || true
stopservice wl 2>/dev/null || true
startservice wl 2>/dev/null || true
sleep 4

echo '=== VERIFY ==='
nvram get wan_dns
nvram get wan_mtu
nvram get wl0_bss_enabled
nvram get wlan0_mode
nvram get telnetd_enable
nvram get remote_management
nvram get cron_jobs
ifconfig wlan0 | head -3
ping -c 2 -W 4 1.1.1.1
echo DONE
