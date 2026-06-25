WATCHDOG='#!/bin/sh

log() {
    logger "[WIFI-WATCHDOG] $1"
}

# Connessione OK?
if ping -c 2 -W 2 1.1.1.1 >/dev/null 2>&1 ||
   ping -c 2 -W 2 8.8.8.8 >/dev/null 2>&1; then
    exit 0
fi

log "Internet assente."

########################################
# Verifica associazione WiFi
########################################

CONNECTED=0

if command -v iw >/dev/null 2>&1; then

    if iw dev wlan0 link | grep -q "^Connected"; then
        CONNECTED=1
    fi

else

    if iwconfig wlan0 2>/dev/null | grep -q "Access Point: .*[^0]"; then
        CONNECTED=1
    fi

fi

########################################
# Tentativo 1
########################################

if [ "$CONNECTED" = "0" ]; then

    log "WiFi non associato -> reset interfaccia"

    ifconfig wlan0 down
    sleep 2
    ifconfig wlan0 up

    sleep 15

    if ping -c 2 -W 2 1.1.1.1 >/dev/null 2>&1; then
        log "Connessione ripristinata."
        exit 0
    fi

fi

########################################
# Tentativo 2
########################################

log "Riavvio servizio wireless"

stopservice wl
sleep 3
startservice wl

sleep 20

if ping -c 2 -W 2 1.1.1.1 >/dev/null 2>&1; then
    log "Wireless ripristinato."
    exit 0
fi

########################################
# Tentativo 3
########################################

log "Riavvio router"

reboot
'