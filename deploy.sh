#!/usr/bin/env bash
# ========================================================
# deploy.sh - the one command you run on the PC.
# Linux (bash); README.md also shows every step by hand.
# Settings: bifrost.conf.
#
#   ./deploy.sh              main router, every AP, then the addons in use
#   ./deploy.sh ap <name>    one AP, including a factory-fresh one
#
# Bare, the same command configures a freshly reset network
# and maintains it after upgrades. Every device is safe to
# re-run, and reboots only when something changed.
#
# The only argument is an AP name, for the case the network
# cannot reveal: a factory-reset AP sits at 192.168.1.1, the
# same address as the main router, so it must be plugged into
# your PC alone and named.
# ========================================================
set -euo pipefail
cd "$(dirname "$0")"

CONF=bifrost.conf
FACTORY_IP=192.168.1.1

# What each device gets from bifrost.conf. Everything else stays on the PC.
NET_VARS="SSID WPA_PSK COUNTRY MOBILITY_DOMAIN BW24 BW5 TXPOWER_24 MAIN_HOSTNAME GW_IP NETMASK
          WAN_DEVICE PPPOE_USER PPPOE_PASS MAIN_CH24 MAIN_CH5 DNS_LIST DHCP_DNS_OPTION UPNP APS
          ROOT_PASSWORD ZONENAME TIMEZONE NTP_SERVER"
WATCH_VARS="BOT_TOKEN CHAT_ID PEOPLE PEOPLE_MAC AP_IPS POLL_INTERVAL MISSES_TO_LEAVE
            CONFIRM_ROUNDS CONFIRM_GAP ARPING_TRIES INITIAL_SETTLE AP_FAIL_GRACE"
WG_VARS="WG_PORT VPN_SUBNET CLIENT_DNS VPN_LAN_ACCESS DUCKDNS_DOMAIN DUCKDNS_TOKEN"

say()  { printf '\n>>> %s\n' "$*"; }
warn() { printf 'deploy: %s\n' "$*" >&2; }
die()  { printf 'deploy: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
deploy.sh - the one command you run on the PC

  ./deploy.sh              configure or maintain everything: main router,
                           every AP, then the addons in use
  ./deploy.sh ap <name>    one AP, including a factory-fresh one at 192.168.1.1

Every device is safe to re-run, and reboots only when something changed.
Settings: bifrost.conf.
EOF
    exit 1
}
case "${1:-}" in
    "")  ;;
    ap)  [ "$#" -eq 2 ] || usage ;;
    *)   usage ;;
esac

# ---- config ---------------------------------------------------------

[ -f "$CONF" ] || die "$CONF is missing: cp -n $CONF.example $CONF, then fill it in"
set +u
# shellcheck source=/dev/null  # the user's file, not in this repo
. "./$CONF"
set -u
: "${APS:=}" "${BOT_TOKEN:=}" "${WG_PORT:=}" "${ROOT_PASSWORD:=}"
[ "$(stat -c %a "$CONF")" = 600 ] \
    || warn "chmod 600 $CONF (it holds every password)"
AP_IPS=""
for _e in $APS; do _r=${_e#*,}; AP_IPS="${AP_IPS:+$AP_IPS }${_r%%,*}"; done

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

# Passwords only. With sshpass installed, ROOT_PASSWORD is typed for
# you; without it, ssh asks (a factory-fresh router has none). Host keys
# aren't pinned: every flash makes new ones (LAN only). On Linux, one
# connection per host is reused for a minute, so a step asks once.
SSH_OPTS=(-o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3
          -o PubkeyAuthentication=no -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR)
if [ "$(uname -s)" = Linux ]; then
    mkdir -p ~/.ssh && chmod 700 ~/.ssh
    SSH_OPTS=(-o ControlMaster=auto -o ControlPath="$HOME/.ssh/cm-%r@%h:%p" -o ControlPersist=60 "${SSH_OPTS[@]}")
fi

# pw <ssh|scp> <args...> - run it, typing ROOT_PASSWORD when sshpass is there
pw() {
    if [ -n "$ROOT_PASSWORD" ] && command -v sshpass >/dev/null; then
        SSHPASS=$ROOT_PASSWORD sshpass -e "$@"
    else
        "$@"
    fi
}

port_open() { timeout 3 bash -c "</dev/tcp/$1/22" 2>/dev/null; }

# hostname_at <ip> - the router's uci hostname, empty if nothing answers
hostname_at() {
    port_open "$1" || return 0
    pw ssh "${SSH_OPTS[@]}" "root@$1" "uci -q get system.@system[0].hostname" 2>/dev/null || true
}

# wait_up <ip> - poll until SSH answers again (5 minutes at most)
wait_up() {
    local _i
    for _i in $(seq 150); do
        if port_open "$1"; then sleep 5; printf '    %s is up\n' "$1"; return 0; fi
        sleep 2
    done
    die "$1 didn't come back within 5 minutes"
}

# wait_reboot <ip it had> <ip it comes back on>
# Only called when a reboot is certain: wait for it to go down (it may
# already be), then for it to come back.
wait_reboot() {
    say "waiting for $2 to come back"
    # A reboot leaves a dead control socket behind; drop it so the next
    # connection doesn't try to reuse a master that is gone.
    [ -n "${HOME:-}" ] && rm -f "$HOME/.ssh/cm-root@$1:22" "$HOME/.ssh/cm-root@$2:22" 2>/dev/null || true
    for _ in $(seq 45); do port_open "$1" || break; sleep 2; done
    wait_up "$2"
}

# router_run <ip> <local dir> <remote command>: copy dir to /tmp, run.
# The copy logs in first, so a wrong password or an unreachable router
# stops here (exit 2), before anything runs or is mistaken for a reboot.
router_run() {
    # /tmp survives until a reboot. scp -r into an existing /tmp/setup
    # nests a second copy and leaves the old script in place, so clear the
    # name first. Failure is fine: the scp below reports it.
    pw ssh "${SSH_OPTS[@]}" "root@$1" "rm -rf /tmp/${2##*/}" >/dev/null 2>&1 || true
    pw scp -O -q -r "${SSH_OPTS[@]}" "$2" "root@$1:/tmp/" \
        || { warn "couldn't copy to $1 - wrong ROOT_PASSWORD, or not reachable?"; return 2; }
    pw ssh -t "${SSH_OPTS[@]}" "root@$1" "$3"
}

# run_step <ip> <local dir> <remote command> <ip after>
# The setup scripts exit 0 when nothing changed, and 100 when they are
# about to reboot. A dropped session (255) is a dumb AP moving to its
# own IP mid-run; it then finishes and reboots by itself. Anything else
# is a real failure: stop there.
run_step() {
    local rc=0
    router_run "$1" "$2" "$3" || rc=$?
    case "$rc" in
        0)       say "  no config change - no reboot" ;;
        100)     wait_reboot "$1" "$4" ;;
        255)     # The IP moved mid-run. The script keeps going (it ignores
                 # HUP/PIPE), but its new SSH port answers before it has
                 # finished; remember it so the addons don't race it.
                 MOVED=1
                 wait_reboot "$1" "$4" ;;
        *)       die "setup failed on $1 (exit $rc)" ;;
    esac
}

ap_ip() {
    local e
    for e in $APS; do
        [ "${e%%,*}" = "$1" ] && { e=${e#*,}; echo "${e%%,*}"; return; }
    done
    die "no AP named '$1' in APS (have: $(for e in $APS; do printf '%s ' "${e%%,*}"; done))"
}

# ---- targets --------------------------------------------------------

require_net() {
    require SSID WPA_PSK COUNTRY ROOT_PASSWORD ZONENAME TIMEZONE GW_IP NETMASK
    case "${MOBILITY_DOMAIN:-}" in
        [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) ;;
        *) die "MOBILITY_DOMAIN must be 4 hex digits (e.g. a1b2)" ;;
    esac
}

cmd_main() {
    require_net; require MAIN_HOSTNAME WAN_DEVICE PPPOE_USER PPPOE_PASS MAIN_CH24 MAIN_CH5
    local h
    if port_open "$GW_IP"; then
        h=$(hostname_at "$GW_IP")
        # A configured dumb AP at the main address is the one mix-up that
        # would flatten the network; refuse it by name.
        for _e in $APS; do
            [ -n "$h" ] && [ "$h" = "${_e%%,*}" ] \
                && die "$GW_IP answered as AP ${_e%%,*} - use ./deploy.sh ap ${_e%%,*}, not the main deploy"
        done
        say "main router $GW_IP"
        run_step "$GW_IP" "$(stage setup network.conf "$NET_VARS")" \
            "sh /tmp/setup/main-router.sh" "$GW_IP"
        return 0
    fi
    # A factory-reset main router still sits at 192.168.1.1. Don't reuse a
    # pooled connection here: it could be an AP from an earlier run.
    if [ "$GW_IP" != "$FACTORY_IP" ]; then
        local saved_opts=("${SSH_OPTS[@]}")
        SSH_OPTS=(-o ControlPath=none "${SSH_OPTS[@]}")
        h=$(hostname_at "$FACTORY_IP")
        if [ "$h" = OpenWrt ]; then
            say "main router is factory-fresh at $FACTORY_IP"
            run_step "$FACTORY_IP" "$(stage setup network.conf "$NET_VARS")" \
                "sh /tmp/setup/main-router.sh" "$GW_IP"
            SSH_OPTS=("${saved_opts[@]}")
            return 0
        fi
        SSH_OPTS=("${saved_opts[@]}")
    fi
    die "main router not reachable at $GW_IP"
}

cmd_ap() {
    require_net
    local name=${1:-} ip h
    [ -n "$name" ] || die "usage: deploy.sh ap <hostname>"
    ip=$(ap_ip "$name")

    if port_open "$ip"; then
        say "AP $name ($ip)"
        run_step "$ip" "$(stage setup network.conf "$NET_VARS")" \
            "sh /tmp/setup/dumb-ap.sh $name" "$ip"
        return 0
    fi

    # Not at its address yet: a factory AP is at 192.168.1.1. The main
    # router may live there too, so never reuse a pooled connection and
    # never touch anything that does not call itself OpenWrt. Disable the
    # control master for this whole run: a pooled 192.168.1.1 socket could
    # be the main router, and restore it for the next AP afterwards.
    local saved_opts=("${SSH_OPTS[@]}")
    SSH_OPTS=(-o ControlPath=none "${SSH_OPTS[@]}")
    h=$(hostname_at "$FACTORY_IP")
    if [ "$h" = OpenWrt ] || [ "$h" = "$name" ]; then
        say "AP $name is at $FACTORY_IP (factory-fresh or mid-setup)"
        echo "    Only your PC should be plugged into it. It moves to $ip mid-run"
        echo "    (the session freezes, that's fine). When it says it's waiting for"
        echo "    internet, plug it into the main LAN."
        run_step "$FACTORY_IP" "$(stage setup network.conf "$NET_VARS")" \
            "sh /tmp/setup/dumb-ap.sh $name" "$ip"
        SSH_OPTS=("${saved_opts[@]}")
        return 0
    fi
    SSH_OPTS=("${saved_opts[@]}")
    if [ "$h" = "${MAIN_HOSTNAME:-}" ]; then
        warn "AP $name is not reachable at $ip (192.168.1.1 is the main router)"
    elif [ -n "$h" ]; then
        warn "$FACTORY_IP answered as '$h', not a factory device - left untouched"
    else
        warn "AP $name is not reachable at $ip"
    fi
    return 1
}

cmd_wifi_watch() {
    require BOT_TOKEN CHAT_ID PEOPLE
    say "wifi-watch addon on $GW_IP"
    # AP_PASSWORD lets it authorize its own key on the APs without asking.
    router_run "$GW_IP" "$(stage addons/wifi-watch wifi-watch.conf "$WATCH_VARS")" \
        "AP_PASSWORD=$(sq "$ROOT_PASSWORD") sh /tmp/wifi-watch/install.sh" \
        || die "wifi-watch failed on $GW_IP"
}

cmd_wireguard() {
    require WG_PORT VPN_SUBNET CLIENT_DNS
    say "wireguard addon on $GW_IP"
    router_run "$GW_IP" "$(stage addons/wireguard wireguard.conf "$WG_VARS")" \
        "sh /tmp/wireguard/install.sh" \
        || die "wireguard failed on $GW_IP"
}

# No arguments: configure or maintain the whole network. An AP that is
# not reachable (and is not a factory device) is skipped with a warning.
# The addons need the whole network, so if any AP is missing they wait for
# the next run.
cmd_all() {
    local e rc=0
    MOVED=0
    cmd_main
    for e in $APS; do cmd_ap "${e%%,*}" || rc=1; done
    if [ "$rc" != 0 ]; then
        warn "some APs were skipped - addons not touched"
        warn "run ./deploy.sh ap <name> with only that AP plugged in, then ./deploy.sh again"
        exit 1
    fi
    # A router that changed IP mid-run is still finishing and about to
    # reboot, even though its new SSH port answers. Don't let the addons
    # race it; the next run is the normal one for addons after a first
    # configuration.
    if [ "$MOVED" = 1 ]; then
        warn "a router moved IP mid-run - addons wait for the next run"
        warn "run ./deploy.sh again once it is back"
        return 0
    fi
    if [ -n "$BOT_TOKEN" ]; then cmd_wifi_watch; else echo "(BOT_TOKEN empty - skipping wifi-watch)"; fi
    if [ -n "$WG_PORT" ]; then cmd_wireguard; else echo "(WG_PORT empty - skipping wireguard)"; fi
    say "done"
}

case "${1:-}" in
    "")  cmd_all ;;
    ap)  shift; cmd_ap "$@" ;;
esac
