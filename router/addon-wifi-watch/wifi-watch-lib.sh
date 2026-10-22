#!/bin/sh
# ========================================================
# wifi-watch-lib.sh - shared code for wifi-watch.sh,
# wifi-where.sh and install.sh. Installed to
# /usr/lib/wifi-watch/lib.sh. Sourced, never executed.
#
# One copy of the config loading, SSH plumbing and the
# association query, so the installer's self-test and the
# diagnostic run exactly what the notifier runs.
# ========================================================

WIFI_WATCH_CONF="${WIFI_WATCH_CONF:-/etc/wifi-watch.conf}"
SSH_KEY="/root/.ssh/wifi-watch"     # private key; public half goes in each AP's authorized_keys
SSH_TIMEOUT=8                       # hard cap per AP query, seconds
STATE_DIR="/tmp/wifi-watch"
LEASES="/tmp/dhcp.leases"
MACMAP="$STATE_DIR/macmap"
MAC_RE='([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}'

ww_log() { logger -t wifi-watch "$1"; }

# ---- config --------------------------------------------------------

ww_load_conf() {
    if [ ! -r "$WIFI_WATCH_CONF" ]; then
        echo "wifi-watch: $WIFI_WATCH_CONF not readable" >&2
        return 1
    fi
    . "$WIFI_WATCH_CONF"
}

# hostname -> person, from PEOPLE="substring=name ..."
match_person() {
    [ -n "$1" ] && [ "$1" != "*" ] || return 0
    for _pair in $PEOPLE; do
        case "$1" in
            *"${_pair%%=*}"*) echo "${_pair#*=}"; return 0 ;;
        esac
    done
}

# lowercase mac -> person, from PEOPLE_MAC="mac=name ..."
match_person_mac() {
    for _pair in $PEOPLE_MAC; do
        [ "$1" = "$(echo "${_pair%%=*}" | tr 'A-F' 'a-f')" ] && { echo "${_pair#*=}"; return 0; }
    done
}

# ---- ssh plumbing --------------------------------------------------

# Without a working timeout, ww_ap_run's ping gate still bounds dead APs.
ww_detect_timeout() {
    if timeout 1 true >/dev/null 2>&1; then
        TIMEOUT_PREFIX="timeout $SSH_TIMEOUT"
    else
        TIMEOUT_PREFIX=""
    fi
}

# Sets SSH_BIN, SSH_KIND (dropbear|openssh), SSH_BATCH (never prompts)
# and SSH_ASK (may prompt for a password). dbclient is preferred: it is
# what OpenWrt ships, and the key is generated in its format to match.
ww_detect_ssh() {
    SSH_BIN=""; SSH_KIND=""; SSH_BATCH=""; SSH_ASK=""
    if command -v dbclient >/dev/null 2>&1; then
        SSH_BIN=$(command -v dbclient); SSH_KIND=dropbear
    elif command -v ssh >/dev/null 2>&1; then
        SSH_BIN=$(command -v ssh)
        if ssh -V 2>&1 | grep -qi dropbear; then SSH_KIND=dropbear; else SSH_KIND=openssh; fi
    else
        return 1
    fi
    if [ "$SSH_KIND" = dropbear ]; then
        SSH_BATCH="-T -y -y -I 10"
        SSH_ASK="-T -y -y"
    else
        SSH_BATCH="-T -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5"
        SSH_ASK="-T -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
    fi
}

# ww_ap_run <host> <command> -> command output on stdout.
# Cheap ping gate first: without a `timeout` binary, an AP that is
# powered off would otherwise stall the caller for the full TCP
# connect timeout. A dead AP fails here in 2s.
ww_ap_run() {
    [ -n "$SSH_BIN" ] || return 1
    ping -c1 -W2 "$1" >/dev/null 2>&1 || return 1
    # dbclient has no BatchMode: if the key is rejected it falls back to
    # a password prompt (and a typed password would fake success). A
    # bogus DROPBEAR_PASSWORD makes that fallback fail instead.
    # shellcheck disable=SC2086
    DROPBEAR_PASSWORD="__wifiwatch_key_only__" \
        $TIMEOUT_PREFIX "$SSH_BIN" $SSH_BATCH -i "$SSH_KEY" "root@$1" "$2" </dev/null 2>/dev/null
}

# ---- queries -------------------------------------------------------

# Every associated station MAC, then a sentinel proving the command
# actually ran. Without the sentinel an SSH failure and an AP with no
# clients are indistinguishable - and that difference is the whole
# point of wifi-watch's degraded-mode logic.
ASSOC_CMD='for o in $(ubus list 2>/dev/null | grep "^hostapd\."); do ubus call "$o" get_clients 2>/dev/null; done; for i in $(iw dev 2>/dev/null | sed -n "s/^[[:space:]]*Interface //p"); do iw dev "$i" station dump 2>/dev/null; done; echo __WIFIWATCH_OK__'

# Per station: "<mac> <iface> <channel> <signal>", for wifi-where.sh.
WHERE_CMD='for i in $(iw dev 2>/dev/null | sed -n "s/^[[:space:]]*Interface //p"); do
  b=$(iw dev "$i" info 2>/dev/null | sed -n "s/^[[:space:]]*channel \([0-9]*\).*/\1/p")
  iw dev "$i" station dump 2>/dev/null | awk -v ifc="$i" -v ch="$b" "
    /^Station/ { mac = \$2 }
    /signal:/  { if (mac != \"\") { print mac, ifc, ch, \$2; mac = \"\" } }
  "
done; echo __WIFIWATCH_OK__'

ww_answered() {
    case "$1" in *__WIFIWATCH_OK__*) return 0 ;; *) return 1 ;; esac
}

# ---- state ---------------------------------------------------------

ww_print_state() {
    if [ -f "$STATE_DIR/.persons" ]; then
        echo "notifier state:"
        while read -r _p; do
            [ -n "$_p" ] || continue
            printf '  %-18s %s\n' "$_p" "$(cat "$STATE_DIR/person_$_p" 2>/dev/null)"
        done < "$STATE_DIR/.persons"
    else
        echo "no notifier state yet - is the service running? (logread -e wifi-watch)"
    fi
}
