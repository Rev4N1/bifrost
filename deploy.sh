#!/usr/bin/env bash
# ========================================================
# deploy.sh - the one command you run on the PC.
# Linux (bash). On Windows it runs in Git Bash, except
# "sdcard" (see pi/README.md). Settings: bifrost.conf.
#
#   ./deploy.sh routers               main router, every AP, then the addons in use
#   ./deploy.sh main                  main router only
#   ./deploy.sh ap <hostname> [--fresh]   one dumb AP (--fresh: still at factory 192.168.1.1)
#   ./deploy.sh wifi-watch            Telegram addon
#   ./deploy.sh wireguard             WireGuard VPN server on the main router
#   ./deploy.sh wireguard client add NAME [IP] | revoke NAME | list
#   ./deploy.sh pi-gateway [--usb]    router side of the Pi (records its MACs if needed)
#
#   ./deploy.sh sdcard                turn on USB gadget mode on a freshly flashed Pi card
#   ./deploy.sh pi [--usb] [step]     run pi/setup.sh on the Pi (all|network|system|wifi|
#                                     tailscale|firewall|poweroff; default: all)
#   ./deploy.sh pi [--usb] wifi add SSID [PASSWORD] | forget SSID | list
#
#   --usb: the Pi is plugged into this PC, not the router.
# Every target is safe to re-run.
# ========================================================
set -euo pipefail
cd "$(dirname "$0")"

CONF=bifrost.conf
FACTORY_IP=192.168.1.1
PI_USB_IP=10.12.194.1
KEY="$HOME/.ssh/bifrost_ed25519"

# What each device gets from bifrost.conf. Everything else stays on the PC.
NET_VARS="SSID WPA_PSK COUNTRY MOBILITY_DOMAIN BW24 BW5 TXPOWER_24 MAIN_HOSTNAME GW_IP NETMASK
          WAN_DEVICE PPPOE_USER PPPOE_PASS MAIN_CH24 MAIN_CH5 DNS_LIST DHCP_DNS_OPTION UPNP APS
          ROOT_PASSWORD ZONENAME TIMEZONE NTP_SERVER"
WATCH_VARS="BOT_TOKEN CHAT_ID PEOPLE PEOPLE_MAC AP_HOSTS POLL_INTERVAL MISSES_TO_LEAVE
            CONFIRM_ROUNDS CONFIRM_GAP ARPING_TRIES INITIAL_SETTLE AP_FAIL_GRACE"
WG_VARS="WG_PORT VPN_SUBNET CLIENT_DNS VPN_LAN_ACCESS DUCKDNS_DOMAIN DUCKDNS_TOKEN"
GATEWAY_VARS="PI_NAME PI_MAC PI_IP PI_PORT"
PI_VARS="PI_NAME COUNTRY TS_AUTHKEY VPN_LAN_ACCESS PI_MAC HOST_MAC"

say() { printf '\n>>> %s\n' "$*"; }
die() { printf 'deploy: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '3,21p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
case "${1:-}" in
    routers|main|ap|wifi-watch|wireguard|pi-gateway|pi|sdcard) ;;
    *) usage ;;
esac

# ---- config ---------------------------------------------------------

if [ "$1" != sdcard ]; then
    [ -f "$CONF" ] || die "$CONF is missing: cp -n $CONF.example $CONF, then fill it in"
    set +u; . "./$CONF"; set -u
    : "${APS:=}" "${BOT_TOKEN:=}" "${WG_PORT:=}" "${PI_NAME:=}" "${PI_MAC:=}" "${HOST_MAC:=}" "${PI_USER:=}" "${PI_PASSWORD:=}" "${ROOT_PASSWORD:=}"
    PI_PORT=usb0
    AP_HOSTS=""
    for _e in $APS; do _r=${_e#*,}; AP_HOSTS="${AP_HOSTS:+$AP_HOSTS }${_r%%,*}"; done
fi

# require VAR... - each must be set and not CHANGE_ME
require() {
    local v
    for v in "$@"; do
        [ -n "${!v:-}" ] && [ "${!v}" != CHANGE_ME ] || die "set $v in $CONF"
    done
}

# sq <value> - single-quoted for any POSIX shell (the routers run ash)
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# emit VAR... - shell assignments a device script can source
emit() {
    local v
    for v in "$@"; do printf '%s=%s\n' "$v" "$(sq "${!v-}")"; done
}

# stage <dir> <config file name> <vars> - a temp copy of dir with its
# config written in, deleted when deploy.sh exits. Prints the copy's path.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
stage() {
    rm -rf "${STAGE:?}/${1##*/}"
    cp -r "$1" "$STAGE/"
    # shellcheck disable=SC2086
    emit $3 > "$STAGE/${1##*/}/$2"
    chmod 600 "$STAGE/${1##*/}/$2"
    echo "$STAGE/${1##*/}"
}

# ---- ssh ------------------------------------------------------------

# deploy.sh logs in with its own key, installed once per device (with
# the password from bifrost.conf) and kept by a "keep settings" flash.
# Host keys aren't pinned: every flash makes new ones (LAN only). On
# Linux, one connection per host is reused for a minute.
mkdir -p ~/.ssh && chmod 700 ~/.ssh
[ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N '' -C bifrost-deploy -f "$KEY"
SSH_OPTS=(-i "$KEY" -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
if [ "$(uname -s)" = Linux ]; then
    SSH_OPTS+=(-o ControlMaster=auto -o "ControlPath=$HOME/.ssh/bifrost-%r@%h:%p" -o ControlPersist=60)
fi

# trust <user@host> <authorized_keys path on it> <password or empty>
# Installs the deploy key unless it already works. Factory OpenWrt has no
# root password, so a fresh router needs none.
trust() {
    # ssh keeps the FIRST value of each option: these must come before SSH_OPTS
    ssh -o ControlPath=none -o BatchMode=yes "${SSH_OPTS[@]}" "$1" true 2>/dev/null && return 0
    local add="f=$2; umask 077; mkdir -p \"\${f%/*}\"; touch \"\$f\"; k=\$(cat);
               grep -qxF \"\$k\" \"\$f\" || echo \"\$k\" >> \"\$f\"; chmod 600 \"\$f\""
    if [ -n "$3" ] && command -v sshpass >/dev/null; then
        SSHPASS=$3 sshpass -e ssh -o ControlPath=none -o PreferredAuthentications=password,keyboard-interactive \
            "${SSH_OPTS[@]}" "$1" "$add" < "$KEY.pub" || true
    else
        say "authorizing deploy.sh's key on $1 - its password is asked this once"
        [ -n "$3" ] && echo "    (install sshpass and it'll use the password from $CONF instead)"
        ssh -o ControlPath=none "${SSH_OPTS[@]}" "$1" "$add" < "$KEY.pub" || true
    fi
    ssh -o ControlPath=none -o BatchMode=yes "${SSH_OPTS[@]}" "$1" true 2>/dev/null \
        || die "couldn't log in to $1 with the deploy key"
}

port_open() { timeout 3 bash -c "</dev/tcp/$1/22" 2>/dev/null; }

# wait_reboot <ip it had> <ip it comes back on>
wait_reboot() {
    say "waiting for $2 to come back"
    for _ in $(seq 45); do port_open "$1" || break; sleep 2; done
    for _ in $(seq 150); do
        if port_open "$2"; then sleep 5; echo "    $2 is up"; return; fi
        sleep 2
    done
    die "$2 didn't come back within 5 minutes"
}

# router_run <ip> <local dir> <remote command>: copy dir to /tmp, run.
router_run() {
    trust "root@$1" /etc/dropbear/authorized_keys "$ROOT_PASSWORD"
    scp -O -q -r "${SSH_OPTS[@]}" "$2" "root@$1:/tmp/"
    ssh -t "${SSH_OPTS[@]}" "root@$1" "$3"
}

ap_ip() {
    local e
    for e in $APS; do
        [ "${e%%,*}" = "$1" ] && { e=${e#*,}; echo "${e%%,*}"; return; }
    done
    die "no AP named '$1' in APS (have: $(for e in $APS; do printf '%s ' "${e%%,*}"; done))"
}

# pi_login [--usb] - user@address of the Pi, with the deploy key trusted.
# On USB it's at PI_USB_IP until "setup.sh network" makes usb0 a DHCP
# client; after that, a PC finds it by name over IPv6 link-local.
pi_login() {
    require PI_USER PI_IP
    local addr=$PI_IP
    if [ "${1:-}" = --usb ]; then
        addr=$PI_USB_IP
        port_open "$addr" || addr=$PI_NAME.local
    fi
    trust "$PI_USER@$addr" '$HOME/.ssh/authorized_keys' "$PI_PASSWORD" >&2
    echo "$PI_USER@$addr"
}

# ---- targets --------------------------------------------------------

require_net() { require SSID WPA_PSK COUNTRY ROOT_PASSWORD ZONENAME TIMEZONE GW_IP NETMASK; }

cmd_main() {
    require_net; require MAIN_HOSTNAME WAN_DEVICE PPPOE_USER PPPOE_PASS MAIN_CH24 MAIN_CH5
    say "main router $GW_IP"
    router_run "$GW_IP" "$(stage router/setup network.conf "$NET_VARS")" \
        "sh /tmp/setup/main-router.sh" || true   # it reboots
    wait_reboot "$GW_IP" "$GW_IP"
}

cmd_ap() {
    require_net
    local name=${1:-} ip target
    [ -n "$name" ] || die "usage: deploy.sh ap <hostname> [--fresh]"
    ip=$(ap_ip "$name"); target=$ip
    if [ "${2:-}" = --fresh ]; then
        target=$FACTORY_IP
        # Same address as the main router: never reuse a connection to it.
        SSH_OPTS=(-o ControlPath=none "${SSH_OPTS[@]}")
        say "$name is factory-fresh: only your PC should be plugged into it."
        echo "    It moves to $ip mid-run (the session freezes, that's fine). When it"
        echo "    says it's waiting for internet, plug it into the main LAN."
    fi
    say "dumb AP $name ($ip)"
    router_run "$target" "$(stage router/setup network.conf "$NET_VARS")" \
        "sh /tmp/setup/dumb-ap.sh $name" || true   # it reboots
    wait_reboot "$target" "$ip"
}

cmd_wifi_watch() {
    require BOT_TOKEN CHAT_ID PEOPLE
    say "wifi-watch addon on $GW_IP"
    # AP_PASSWORD lets it authorize its own key on the APs without asking.
    router_run "$GW_IP" "$(stage router/addon-wifi-watch wifi-watch.conf "$WATCH_VARS")" \
        "AP_PASSWORD=$(sq "$ROOT_PASSWORD") sh /tmp/addon-wifi-watch/install.sh"
}

cmd_wireguard() {
    require WG_PORT VPN_SUBNET CLIENT_DNS
    local dir
    dir=$(stage router/addon-wireguard wireguard.conf "$WG_VARS")
    if [ "${1:-}" = client ]; then
        router_run "$GW_IP" "$dir" "sh /tmp/addon-wireguard/install.sh $(printf '%q ' "$@")"
        if [ "${2:-}" = add ] && [ -n "${3:-}" ]; then
            scp -O -q "${SSH_OPTS[@]}" "root@$GW_IP:/tmp/wg-$3.conf" ~/                 && ssh "${SSH_OPTS[@]}" "root@$GW_IP" "rm -f /tmp/wg-$3.conf"                 && say "client config saved to ~/wg-$3.conf (has the private key)"                 && echo "    Fedora: sudo nmcli connection import type wireguard file ~/wg-$3.conf"                 && echo "    Other:  import it in the WireGuard app, then delete the file"
        fi
        return
    fi
    say "wireguard addon on $GW_IP"
    router_run "$GW_IP" "$dir" "sh /tmp/addon-wireguard/install.sh"
}

# Record the Pi's pinned MACs in bifrost.conf (PI_MAC for the router's
# lease, both for giving a reflashed Pi the same ones).
record_pi_macs() {
    local login pinned
    login=$(pi_login "$@")
    pinned=$(ssh "${SSH_OPTS[@]}" "$login" cat /etc/modprobe.d/usb-gadget.conf)
    PI_MAC=$(sed -n 's/.*dev_addr=\([^ ]*\).*/\1/p' <<<"$pinned")
    HOST_MAC=$(sed -n 's/.*host_addr=\([^ ]*\).*/\1/p' <<<"$pinned")
    [ -n "$PI_MAC" ] && [ -n "$HOST_MAC" ] || die "no pinned MACs on the Pi - run: deploy.sh pi ${1:-} network"
    sed -i -e "s/^PI_MAC=\"[^\"]*\"/PI_MAC=\"$PI_MAC\"/" \
           -e "s/^HOST_MAC=\"[^\"]*\"/HOST_MAC=\"$HOST_MAC\"/" "$CONF"
    echo "    PI_MAC=$PI_MAC HOST_MAC=$HOST_MAC recorded in $CONF"
}

cmd_pi_gateway() {
    if [ "${1:-}" = --usb ] || [ -z "$PI_MAC" ]; then
        say "reading the Pi's MACs"; record_pi_macs "$@"
    fi
    require PI_MAC PI_IP
    say "pi-gateway addon on $GW_IP"
    router_run "$GW_IP" "$(stage router/addon-pi-gateway pi-gateway.conf "$GATEWAY_VARS")" \
        "sh /tmp/addon-pi-gateway/install.sh"
}

cmd_routers() {
    local e
    cmd_main
    for e in $APS; do cmd_ap "${e%%,*}"; done
    if [ -n "$BOT_TOKEN" ]; then cmd_wifi_watch; else echo "(BOT_TOKEN empty - skipping wifi-watch)"; fi
    if [ -n "$WG_PORT" ]; then cmd_wireguard; else echo "(WG_PORT empty - skipping wireguard)"; fi
    if [ -n "$PI_MAC" ]; then cmd_pi_gateway; else echo "(PI_MAC empty - skipping pi-gateway)"; fi
    say "all routers done"
}

# Add enable_usb_gadget: true under rpi: in the card's cloud-init
# user-data (YAML: one rpi: key, consistent indentation).
cmd_sdcard() {
    command -v findmnt >/dev/null || die "sdcard needs Linux; on Windows edit user-data by hand (pi/README.md)"
    local boot f
    boot=$(findmnt -nro TARGET --source LABEL=bootfs | head -n1)
    [ -n "$boot" ] || die "bootfs isn't mounted - open the SD card in your file manager first"
    f="$boot/user-data"
    [ -f "$f" ] || die "$f not found - flash the card with Raspberry Pi Imager first"
    sed -i 's/\r$//' "$f"
    if ! grep -q 'enable_usb_gadget' "$f"; then
        if grep -q '^rpi:' "$f"; then
            awk '
                add { ind = match($0, /^[ \t]+[^ \t]/) ? substr($0, 1, RLENGTH - 1) : "  "
                      print ind "enable_usb_gadget: true"; add = 0 }
                { print }
                /^rpi:[ \t]*$/ { add = 1 }
                END { if (add) print "  enable_usb_gadget: true" }
            ' "$f" > "$f.new" && mv "$f.new" "$f"
        else
            [ -z "$(tail -c1 "$f")" ] || echo >> "$f"
            printf 'rpi:\n  enable_usb_gadget: true\n' >> "$f"
        fi
    fi
    sync
    grep -A3 '^rpi:' "$f"
    say "USB gadget mode on. Eject the card and boot the Pi from it."
}

# Run pi/setup.sh on the Pi. Script and config travel inside the SSH
# command and are deleted after. With PI_PASSWORD set, sudo is answered
# from it; otherwise sudo asks.
cmd_pi() {
    local where=""
    [ "${1:-}" = --usb ] && { where=--usb; shift; }
    local login s c args unlock=""
    login=$(pi_login $where)
    # shellcheck disable=SC2086
    s=$(base64 -w0 pi/setup.sh); c=$(emit $PI_VARS | base64 -w0)
    [ -n "$PI_PASSWORD" ] && \
        unlock="{ echo $(printf '%s\n' "$PI_PASSWORD" | base64 -w0) | base64 -d | sudo -S -p '' -v 2>/dev/null || true; } &&"
    args=$(printf '%q ' "$@")
    say "pi/setup.sh ${*:-all} on $login"
    ssh -t "${SSH_OPTS[@]}" "$login" "
        d=\$(mktemp -d) && chmod 700 \"\$d\" &&
        echo $s | base64 -d > \"\$d/setup.sh\" && echo $c | base64 -d > \"\$d/pi.conf\" &&
        $unlock sudo bash \"\$d/setup.sh\" $args; rc=\$?; rm -rf \"\$d\"; exit \$rc" || true
}

case "$1" in
    routers)    cmd_routers ;;
    main)       cmd_main ;;
    ap)         shift; cmd_ap "$@" ;;
    wifi-watch) cmd_wifi_watch ;;
    wireguard)  shift; cmd_wireguard "$@" ;;
    pi-gateway) shift; cmd_pi_gateway "$@" ;;
    sdcard)     cmd_sdcard ;;
    pi)         shift; cmd_pi "$@" ;;
esac
