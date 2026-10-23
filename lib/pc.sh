# shellcheck shell=bash
# ========================================================
# lib/pc.sh - what deploy.sh and addons/wireguard/client.sh
# share on the PC: reading bifrost.conf, passwords-only SSH,
# and copying a folder to a router and running it there.
# Sourced from the repo root, never executed.
# ========================================================

CONF=bifrost.conf

say()  { printf '\n>>> %s\n' "$*"; }
warn() { printf '%s: %s\n' "${0##*/}" "$*" >&2; }
die()  { printf '%s: %s\n' "${0##*/}" "$*" >&2; exit 1; }

# ---- config ---------------------------------------------------------

[ -f "$CONF" ] || die "$CONF is missing: cp -n $CONF.example $CONF, then fill it in"
set +u
# shellcheck source=/dev/null  # the user's file, not in this repo
. "./$CONF"
set -u
: "${GW_IP:=}" "${APS:=}" "${ROOT_PASSWORD:=}" "${BOT_TOKEN:=}" "${WG_PORT:=}" \
  "${VPN_SUBNET:=}"
[ "$(stat -c %a "$CONF")" = 600 ] || warn "chmod 600 $CONF (it holds every password)"

# require VAR... - each must be set and not CHANGE_ME
require() {
    local v
    for v in "$@"; do
        [ -n "${!v:-}" ] && [ "${!v}" != CHANGE_ME ] || die "set $v in $CONF"
    done
}

# Small validators shared by deploy.sh and client.sh. They catch a typo
# before it reaches a router's networking or Wi-Fi config.
is_ipv4() {
    local IFS=. _o
    # A trailing dot splits into four fields; it is still not an address.
    case "$1" in *.) return 1 ;; esac
    # shellcheck disable=SC2086  # deliberate: split the address on IFS=.
    set -- $1
    [ "$#" -eq 4 ] || return 1
    for _o; do
        case "$_o" in '' | *[!0-9]*) return 1 ;; esac
        # Reject leading zeros: $((010)) is octal, and 010.0.0.1 would
        # silently become a different address in the subnet checks.
        [ "${#_o}" -le 3 ] || return 1
        [ "$_o" = 0 ] || [ "${_o#0}" = "$_o" ] || return 1
        [ "$_o" -le 255 ] || return 1
    done
}

is_hostname() {
    case "$1" in '' | -* | *- | *[!a-z0-9-]*) return 1 ;; esac
}

is_uint() { case "$1" in '' | *[!0-9]*) return 1 ;; esac; }

# A LAN mask must be contiguous: 255.255.255.0 is valid, 255.0.255.0 is
# not. /31 and /32 are point-to-point masks, not LAN masks.
is_netmask() {
    is_ipv4 "$1" || return 1
    local IFS=. _o _bits=0 _zero=0
    for _o in $1; do
        case "$_o" in
            255) [ "$_zero" = 0 ] || return 1; _bits=$((_bits + 8)) ;;
            254) [ "$_zero" = 0 ] || return 1; _bits=$((_bits + 7)); _zero=1 ;;
            252) [ "$_zero" = 0 ] || return 1; _bits=$((_bits + 6)); _zero=1 ;;
            248) [ "$_zero" = 0 ] || return 1; _bits=$((_bits + 5)); _zero=1 ;;
            240) [ "$_zero" = 0 ] || return 1; _bits=$((_bits + 4)); _zero=1 ;;
            224) [ "$_zero" = 0 ] || return 1; _bits=$((_bits + 3)); _zero=1 ;;
            192) [ "$_zero" = 0 ] || return 1; _bits=$((_bits + 2)); _zero=1 ;;
            128) [ "$_zero" = 0 ] || return 1; _bits=$((_bits + 1)); _zero=1 ;;
            0)   _zero=1 ;;
            *)   return 1 ;;
        esac
    done
    [ "$_bits" -ge 8 ] && [ "$_bits" -le 30 ]
}

# IPv4 address as one integer. Only called after is_ipv4.
ip_to_int() {
    local IFS=. _a _b _c _d
    read -r _a _b _c _d <<< "$1"
    printf '%s\n' "$(( (_a << 24) | (_b << 16) | (_c << 8) | _d ))"
}

# ip_in_subnet <ip> <gateway> <netmask>
ip_in_subnet() {
    local _m
    _m=$(ip_to_int "$3") || return 1
    [ "$(( $(ip_to_int "$1") & _m ))" -eq "$(( $(ip_to_int "$2") & _m ))" ]
}

# check_wg - part 6 of bifrost.conf, before it reaches the router
check_wg() {
    require GW_IP NETMASK ROOT_PASSWORD WG_PORT VPN_SUBNET
    is_ipv4 "$GW_IP" || die "GW_IP must be an IPv4 address"
    is_netmask "$NETMASK" || die "NETMASK must be a contiguous IPv4 mask, /8 to /30"
    is_uint "$WG_PORT" && [ "$WG_PORT" -ge 1 ] && [ "$WG_PORT" -le 65535 ] \
        || die "WG_PORT must be 1-65535"
    case "$VPN_SUBNET" in
        *.0/24) is_ipv4 "${VPN_SUBNET%/*}" || die "VPN_SUBNET has no IPv4 address" ;;
        *) die "VPN_SUBNET must be a /24 starting at .0 (e.g. 10.7.0.0/24)" ;;
    esac
    # A VPN subnet that overlaps the LAN would steal LAN routes: clients
    # would reach the tunnel for addresses that are actually local. Check
    # both directions: a /24 VPN can cover a LAN that is a smaller subnet.
    if ip_in_subnet "${VPN_SUBNET%/*}" "$GW_IP" "$NETMASK" \
        || ip_in_subnet "$GW_IP" "${VPN_SUBNET%/*}" 255.255.255.0; then
        die "VPN_SUBNET $VPN_SUBNET overlaps the LAN ($GW_IP/$NETMASK)"
    fi
    if [ -n "${DUCKDNS_DOMAIN:-}" ]; then
        require DUCKDNS_TOKEN
        case "$DUCKDNS_DOMAIN" in
            -* | *- | *[!A-Za-z0-9-]*) die "DUCKDNS_DOMAIN must be one subdomain (letters, digits, -)" ;;
        esac
    fi
    local _e _ip _rest _proto _port
    for _e in ${VPN_LAN_ACCESS:-}; do
        case "$_e" in
            *:*:*) ;;
            *) die "VPN_LAN_ACCESS entry '$_e' must be ip:tcp|udp:port" ;;
        esac
        _ip=${_e%%:*}; _rest=${_e#*:}; _proto=${_rest%%:*}; _port=${_rest#*:}
        is_ipv4 "$_ip" || die "VPN_LAN_ACCESS IP '$_ip' is not an IPv4 address"
        case "$_proto" in
            tcp | udp) ;;
            *) die "VPN_LAN_ACCESS protocol '$_proto' must be tcp or udp" ;;
        esac
        is_uint "$_port" && [ "$_port" -ge 1 ] && [ "$_port" -le 65535 ] \
            || die "VPN_LAN_ACCESS port '$_port' must be 1-65535"
    done
}

# sq <value> - single-quoted for any POSIX shell (the routers run ash)
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# emit VAR... - shell assignments a router script can source
emit() {
    local v
    for v in "$@"; do printf '%s=%s\n' "$v" "$(sq "${!v-}")"; done
}

# stage <dir> <config file name> <vars> - a temp copy of dir with its
# config written in, deleted when the script exits. Prints its path.
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

# pw_select <host> - decide once per host how to authenticate.
# A router's password is either ROOT_PASSWORD (set up) or empty (a
# factory image, which OpenWrt's dropbear accepts until a root password
# is set). Probe both with sshpass; otherwise let ssh ask.
declare -A PW_MODES=() PW_PASSES=()
PW_MODE=""
PW_PASS=""
pw_select() {
    local _h=$1 _p
    if [ -n "${PW_MODES[$_h]:-}" ]; then
        PW_MODE=${PW_MODES[$_h]}
        PW_PASS=${PW_PASSES[$_h]:-}
        return 0
    fi
    PW_MODE=prompt
    PW_PASS=""
    if command -v sshpass >/dev/null 2>&1; then
        if [ -n "$ROOT_PASSWORD" ] \
            && SSHPASS=$ROOT_PASSWORD sshpass -e ssh "${SSH_OPTS[@]}" "root@$_h" true 2>/dev/null; then
            PW_MODE=sshpass
            PW_PASS=$ROOT_PASSWORD
        elif [ "$PW_MODE" = prompt ] \
            && SSHPASS='' sshpass -e ssh "${SSH_OPTS[@]}" "root@$_h" true 2>/dev/null; then
            PW_MODE=sshpass
            PW_PASS=""
        fi
    fi
    PW_MODES[$_h]=$PW_MODE
    PW_PASSES[$_h]=$PW_PASS
}

# pw <host> <ssh|scp> <args...> - run it with the password that works
pw() {
    local _h=$1
    shift
    pw_select "$_h"
    if [ "$PW_MODE" = sshpass ]; then
        SSHPASS=$PW_PASS sshpass -e "$@"
    else
        "$@"
    fi
}

port_open() { timeout 3 bash -c "</dev/tcp/$1/22" 2>/dev/null; }

# router_run <ip> <local dir> <remote command with @DIR@>
# Copies the folder to /tmp/bifrost-<name> on the router (never a name a
# router program uses itself, like wifi-watch's /tmp/wifi-watch state)
# and runs the command there, @DIR@ being that path. A leftover copy is
# removed first, or scp would nest the new one inside it. The copy logs
# in first, so a wrong password or an unreachable router stops here
# (exit 2), before anything runs or is mistaken for a reboot.
router_run() {
    local dir="/tmp/bifrost-${2##*/}"
    pw "$1" ssh "${SSH_OPTS[@]}" "root@$1" "rm -rf $dir" >/dev/null 2>&1 \
        || { warn "couldn't clear $dir on $1 - not running a stale copy"; return 2; }
    pw "$1" scp -O -q -r "${SSH_OPTS[@]}" "$2" "root@$1:$dir" \
        || { warn "couldn't copy to $1 - wrong ROOT_PASSWORD, or not reachable?"; return 2; }
    pw "$1" ssh -t "${SSH_OPTS[@]}" "root@$1" "${3//@DIR@/$dir}"
}
