#!/usr/bin/env bash
# ========================================================
# deploy.sh - the one command you run on the PC.
# Linux (bash); README.md also shows every step by hand.
# Settings: bifrost.conf.
#
#   ./deploy.sh              main router, every AP, then the addons in use
#   ./deploy.sh ap <name>    one AP; a factory-fresh one is moved to its
#                            final address and rebooted (run bare next)
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

# The PC side of a deploy. Routers have their own tools; this is what
# deploy.sh itself needs to reach them.
for _c in ssh scp mktemp timeout stat sed; do
    command -v "$_c" >/dev/null 2>&1 \
        || { printf 'deploy.sh: install %s on this PC\n' "$_c" >&2; exit 1; }
done
unset _c

FACTORY_IP=192.168.1.1

# What each device gets from bifrost.conf. Everything else stays on the PC.
# An AP needs the shared Wi-Fi/clock settings and the APS list; it does not
# need the PPPoE login, the main router's WAN device or channels, the DNS
# list, or UPnP, so those never reach it.
SHARED_VARS="SSID WPA_PSK COUNTRY MOBILITY_DOMAIN BW24 BW5 TXPOWER_24 GW_IP NETMASK
             ROOT_PASSWORD ZONENAME TIMEZONE NTP_SERVER"
AP_VARS="$SHARED_VARS APS"
MAIN_VARS="$SHARED_VARS WAN_DEVICE PPPOE_USER PPPOE_PASS MAIN_HOSTNAME MAIN_CH24 MAIN_CH5
           DNS_LIST DHCP_DNS_OPTION UPNP"
WATCH_VARS="BOT_TOKEN CHAT_ID PEOPLE PEOPLE_MAC AP_IPS POLL_INTERVAL MISSES_TO_LEAVE
            CONFIRM_ROUNDS CONFIRM_GAP ARPING_TRIES INITIAL_SETTLE AP_FAIL_GRACE"
WG_VARS="WG_PORT VPN_SUBNET CLIENT_DNS VPN_LAN_ACCESS DUCKDNS_DOMAIN DUCKDNS_TOKEN"

usage() {
    cat <<'EOF'
deploy.sh - the one command you run on the PC

  ./deploy.sh              configure or maintain everything: main router,
                           every AP, then the addons in use
  ./deploy.sh ap <name>    one AP; a factory-fresh one at 192.168.1.1 is
                           moved to its final address and rebooted

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

. lib/pc.sh

AP_IPS=""
for _e in $APS; do _r=${_e#*,}; AP_IPS="${AP_IPS:+$AP_IPS }${_r%%,*}"; done

# hostname_at <ip> - the router's uci hostname, empty if nothing answers
hostname_at() {
    port_open "$1" || return 0
    pw "$1" ssh "${SSH_OPTS[@]}" "root@$1" "uci -q get system.@system[0].hostname" 2>/dev/null || true
}

# wait_up <ip> [stable seconds] - poll until SSH answers again (5 minutes)
wait_up() {
    local _stable=${2:-5} _deadline=$((SECONDS + 300))
    while [ "$SECONDS" -lt "$_deadline" ]; do
        if port_open "$1"; then
            # The port can answer during the last seconds before a reboot.
            # Require it to stay up, so a router that has just moved is not
            # mistaken for one that has finished rebooting.
            sleep "$_stable"
            if port_open "$1"; then
                printf '    %s is up\n' "$1"
                return 0
            fi
        fi
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
    local _i=0 _down=0
    while [ "$_i" -lt 45 ]; do
        if ! port_open "$1"; then _down=1; break; fi
        sleep 2
        _i=$((_i + 1))
    done
    # Same address and still answering means no reboot happened: the SSH
    # session failed for another reason, so don't pretend the step worked.
    if [ "$_down" = 0 ] && [ "$1" = "$2" ]; then
        die "$1 did not go down - the setup session failed (no reboot)"
    fi
    # A moved router is already answering on the new address while it shuts
    # down. Require a longer quiet period before believing it is back.
    if [ "$1" = "$2" ]; then
        wait_up "$2"
    else
        wait_up "$2" 10
    fi
}

# run_step <ip> <local dir> <remote command> <ip after>
# The setup scripts exit 0 when nothing changed, and 100 when they are
# about to reboot. A dropped session (255) is a router moving to its
# own IP mid-run; it then reboots by itself. Anything else is a real
# failure: stop there.
run_step() {
    local rc=0
    router_run "$1" "$2" "$3" || rc=$?
    # The setup may have just set ROOT_PASSWORD. Forget how we logged in,
    # so a later addon tries the configured password again.
    unset "PW_MODES[$1]" "PW_PASSES[$1]" "PW_MODES[$4]" "PW_PASSES[$4]" 2>/dev/null || true
    case "$rc" in
        0)       say "  no config change - no reboot" ;;
        100)     [ "$1" = "$4" ] || MOVED=1
                 wait_reboot "$1" "$4" ;;
        255)     # The IP moved mid-run; the router stops after the move
                 # and reboots. Remember it so the addons don't race it.
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
    require SSID WPA_PSK COUNTRY ROOT_PASSWORD ZONENAME TIMEZONE GW_IP NETMASK NTP_SERVER MAIN_HOSTNAME
    is_ipv4 "$GW_IP" || die "GW_IP must be an IPv4 address (got '$GW_IP')"
    is_netmask "$NETMASK" || die "NETMASK must be a contiguous IPv4 mask, /8 to /30 (got '$NETMASK')"
    is_hostname "$MAIN_HOSTNAME" || die "MAIN_HOSTNAME must be a-z, 0-9 and - (got '$MAIN_HOSTNAME')"
    case "$COUNTRY" in
        [A-Z][A-Z]) ;;
        *) die "COUNTRY must be a two-letter code (got '$COUNTRY')" ;;
    esac
    case "${MOBILITY_DOMAIN:-}" in
        [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) ;;
        *) die "MOBILITY_DOMAIN must be 4 hex digits (e.g. a1b2)" ;;
    esac
    [ "${#SSID}" -ge 1 ] && [ "${#SSID}" -le 32 ] || die "SSID must be 1-32 characters"
    [ "${#WPA_PSK}" -ge 8 ] && [ "${#WPA_PSK}" -le 63 ] || die "WPA_PSK must be 8-63 characters"
    case "${BW24:-}" in 20 | 40) ;; *) die "BW24 must be 20 or 40" ;; esac
    case "${BW5:-}" in 20 | 40 | 80 | 160) ;; *) die "BW5 must be 20, 40, 80 or 160" ;; esac
    [ -z "${TXPOWER_24:-}" ] || is_uint "$TXPOWER_24" || die "TXPOWER_24 must be a number or empty"
    case "${UPNP:-0}" in 0 | 1) ;; *) die "UPNP must be 0 or 1" ;; esac
    local _d _e _n _ip _ach24 _ach5 _names=" " _ips=" " _mask _hostbits _host
    _mask=$(ip_to_int "$NETMASK")
    _hostbits=$((0xFFFFFFFF ^ _mask))
    _host=$(( $(ip_to_int "$GW_IP") & _hostbits ))
    [ "$_host" -ne 0 ] && [ "$_host" -ne "$_hostbits" ] \
        || die "GW_IP '$GW_IP' is the network or broadcast address of $NETMASK"
    # Empty DNS_LIST is allowed: dnsmasq then follows the WAN's resolvers.
    for _d in ${DNS_LIST:-}; do
        is_ipv4 "$_d" || die "DNS_LIST entry '$_d' is not an IPv4 address"
    done

    # APS entries are name,ip,ch24,ch5. A typo here can move an AP off the
    # LAN or put two APs on one channel, so check it before touching a box.
    for _e in $APS; do
        IFS=, read -r _n _ip _ach24 _ach5 <<< "$_e"
        [ -n "$_n" ] && [ -n "$_ip" ] && [ -n "$_ach24" ] && [ -n "$_ach5" ] \
            || die "APS entry '$_e' must be name,ip,ch24,ch5"
        is_hostname "$_n" || die "APS hostname '$_n' must be a-z, 0-9 and -"
        [ "$_n" != "$MAIN_HOSTNAME" ] || die "APS hostname '$_n' is also MAIN_HOSTNAME"
        [ "$_n" != OpenWrt ] || die "APS hostname 'OpenWrt' is reserved"
        is_ipv4 "$_ip" || die "APS IP '$_ip' is not an IPv4 address"
        [ "$_ip" != "$GW_IP" ] || die "APS IP '$_ip' is GW_IP (the main router)"
        ip_in_subnet "$_ip" "$GW_IP" "$NETMASK" \
            || die "AP $_n: $_ip is not in GW_IP's $NETMASK subnet"
        _host=$(( $(ip_to_int "$_ip") & _hostbits ))
        [ "$_host" -ne 0 ] && [ "$_host" -ne "$_hostbits" ] \
            || die "AP $_n: $_ip is the network or broadcast address"
        is_uint "$_ach24" && [ "$_ach24" -ge 1 ] && [ "$_ach24" -le 14 ] \
            || die "AP $_n: ch24 must be 1-14"
        is_uint "$_ach5" && [ "$_ach5" -ge 32 ] && [ "$_ach5" -le 177 ] \
            || die "AP $_n: ch5 must be 32-177"
        case "$_names" in *" $_n "*) die "duplicate AP hostname '$_n'" ;; esac
        case "$_ips" in *" $_ip "*) die "duplicate AP IP '$_ip'" ;; esac
        _names="$_names$_n "
        _ips="$_ips$_ip "
    done
}

cmd_main() {
    require_net; require WAN_DEVICE PPPOE_USER PPPOE_PASS MAIN_CH24 MAIN_CH5
    is_uint "$MAIN_CH24" && [ "$MAIN_CH24" -ge 1 ] && [ "$MAIN_CH24" -le 14 ] \
        || die "MAIN_CH24 must be 1-14"
    is_uint "$MAIN_CH5" && [ "$MAIN_CH5" -ge 32 ] && [ "$MAIN_CH5" -le 177 ] \
        || die "MAIN_CH5 must be 32-177"
    local h
    if port_open "$GW_IP"; then
        h=$(hostname_at "$GW_IP")
        [ -n "$h" ] || die "$GW_IP opened SSH but did not answer - wrong password, or not a router?"
        # A configured dumb AP at the main address is the one mix-up that
        # would flatten the network; refuse it by name.
        for _e in $APS; do
            [ "$h" = "${_e%%,*}" ] \
                && die "$GW_IP answered as AP ${_e%%,*} - use ./deploy.sh ap ${_e%%,*}, not the main deploy"
        done
        [ "$h" = "$MAIN_HOSTNAME" ] || [ "$h" = OpenWrt ] \
            || warn "$GW_IP answered as '$h', not $MAIN_HOSTNAME - continuing"
        say "main router $GW_IP"
        run_step "$GW_IP" "$(stage setup network.conf "$MAIN_VARS")" \
            "sh @DIR@/main-router.sh" "$GW_IP"
        return 0
    fi
    # A factory-reset main router still sits at 192.168.1.1. Don't reuse a
    # pooled connection here: it could be an AP from an earlier run.
    if [ "$GW_IP" != "$FACTORY_IP" ]; then
        local saved_opts=("${SSH_OPTS[@]}")
        SSH_OPTS=(-o ControlPath=none "${SSH_OPTS[@]}")
        h=$(hostname_at "$FACTORY_IP")
        if [ "$h" = OpenWrt ] || [ "$h" = "$MAIN_HOSTNAME" ]; then
            say "main router at $FACTORY_IP"
            warn "it moves to $GW_IP and reboots; this PC must be able to reach that subnet, then run ./deploy.sh again"
            run_step "$FACTORY_IP" "$(stage setup network.conf "$MAIN_VARS")" \
                "sh @DIR@/main-router.sh" "$GW_IP"
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
        h=$(hostname_at "$ip")
        [ -n "$h" ] || die "$ip opened SSH but did not answer - wrong password, or not a router?"
        [ "$h" = "$MAIN_HOSTNAME" ] \
            && die "$ip answered as the main router ($h) - refusing to configure it as AP $name"
        for _e in $APS; do
            [ "$h" = "${_e%%,*}" ] && [ "$h" != "$name" ] \
                && die "$ip answered as AP $h, not $name - refusing to configure it"
        done
        [ "$h" = "$name" ] || [ "$h" = OpenWrt ] \
            || warn "$ip answered as '$h', not $name - continuing"
        say "AP $name ($ip)"
        run_step "$ip" "$(stage setup network.conf "$AP_VARS")" \
            "sh @DIR@/dumb-ap.sh $name" "$ip"
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
        case "$ip" in
            192.168.1.*) ;;
            *) warn "a factory AP moves to $ip; a PC on 192.168.1.x will lose it - use a 192.168.1.x AP_IP for the first run" ;;
        esac
        echo "    Only your PC should be plugged into it. It moves to $ip,"
        echo "    reboots, and stops there; plug it into the main LAN and"
        echo "    run ./deploy.sh again to install packages and Wi-Fi."
        run_step "$FACTORY_IP" "$(stage setup network.conf "$AP_VARS")" \
            "sh @DIR@/dumb-ap.sh $name" "$ip"
        SSH_OPTS=("${saved_opts[@]}")
        [ "$ip" = "$FACTORY_IP" ] \
            || warn "AP $name is at $ip now - plug it into the main LAN, then run ./deploy.sh"
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
    require BOT_TOKEN CHAT_ID
    [ -n "${PEOPLE:-}" ] || [ -n "${PEOPLE_MAC:-}" ] \
        || die "set PEOPLE or PEOPLE_MAC in bifrost.conf"
    is_ipv4 "$GW_IP" || die "GW_IP must be an IPv4 address"
    say "wifi-watch addon on $GW_IP"
    # AP_PASSWORD lets it authorize its own key on the APs without asking.
    router_run "$GW_IP" "$(stage addons/wifi-watch wifi-watch.conf "$WATCH_VARS")" \
        "AP_PASSWORD=$(sq "$ROOT_PASSWORD") sh @DIR@/install.sh" \
        || die "wifi-watch failed on $GW_IP"
}

cmd_wireguard() {
    check_wg
    say "wireguard addon on $GW_IP"
    router_run "$GW_IP" "$(stage addons/wireguard wireguard.conf "$WG_VARS")" \
        "sh @DIR@/install.sh" \
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
    # A router that changed IP mid-run may still be finishing or rebooting.
    # Don't let the addons race it; the next run is the normal one for
    # addons after a first configuration.
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
