#!/usr/bin/env bash
# ========================================================
# deploy.sh - the one command you run on the PC.
# Linux (bash), or Git Bash on Windows. Settings: bifrost.conf.
#
#   ./deploy.sh routers               main router, every AP, then the addons in use
#   ./deploy.sh main                  main router only
#   ./deploy.sh ap <hostname> [--fresh]   one dumb AP (--fresh: still at factory 192.168.1.1)
#   ./deploy.sh wifi-watch            Telegram addon
#   ./deploy.sh wireguard             WireGuard VPN server on the main router
#   ./deploy.sh wireguard client add NAME [IP] | revoke NAME | list
#
# Every target is safe to re-run.
# ========================================================
set -euo pipefail
cd "$(dirname "$0")"

CONF=bifrost.conf
FACTORY_IP=192.168.1.1
KEY="$HOME/.ssh/bifrost_ed25519"

# What each device gets from bifrost.conf. Everything else stays on the PC.
NET_VARS="SSID WPA_PSK COUNTRY MOBILITY_DOMAIN BW24 BW5 TXPOWER_24 MAIN_HOSTNAME GW_IP NETMASK
          WAN_DEVICE PPPOE_USER PPPOE_PASS MAIN_CH24 MAIN_CH5 DNS_LIST DHCP_DNS_OPTION UPNP APS
          ROOT_PASSWORD ZONENAME TIMEZONE NTP_SERVER"
WATCH_VARS="BOT_TOKEN CHAT_ID PEOPLE PEOPLE_MAC AP_HOSTS POLL_INTERVAL MISSES_TO_LEAVE
            CONFIRM_ROUNDS CONFIRM_GAP ARPING_TRIES INITIAL_SETTLE AP_FAIL_GRACE"
WG_VARS="WG_PORT VPN_SUBNET CLIENT_DNS VPN_LAN_ACCESS DUCKDNS_DOMAIN DUCKDNS_TOKEN"

say() { printf '\n>>> %s\n' "$*"; }
die() { printf 'deploy: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
case "${1:-}" in
    routers|main|ap|wifi-watch|wireguard) ;;
    *) usage ;;
esac

# ---- config ---------------------------------------------------------

[ -f "$CONF" ] || die "$CONF is missing: cp -n $CONF.example $CONF, then fill it in"
set +u; . "./$CONF"; set -u
: "${APS:=}" "${BOT_TOKEN:=}" "${WG_PORT:=}" "${ROOT_PASSWORD:=}"
AP_HOSTS=""
for _e in $APS; do _r=${_e#*,}; AP_HOSTS="${AP_HOSTS:+$AP_HOSTS }${_r%%,*}"; done

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

cmd_routers() {
    local e
    cmd_main
    for e in $APS; do cmd_ap "${e%%,*}"; done
    if [ -n "$BOT_TOKEN" ]; then cmd_wifi_watch; else echo "(BOT_TOKEN empty - skipping wifi-watch)"; fi
    if [ -n "$WG_PORT" ]; then cmd_wireguard; else echo "(WG_PORT empty - skipping wireguard)"; fi
    say "all routers done"
}

case "$1" in
    routers)    cmd_routers ;;
    main)       cmd_main ;;
    ap)         shift; cmd_ap "$@" ;;
    wifi-watch) cmd_wifi_watch ;;
    wireguard)  shift; cmd_wireguard "$@" ;;
esac
