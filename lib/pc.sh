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
: "${GW_IP:=}" "${APS:=}" "${ROOT_PASSWORD:=}" "${ROOT_PASSWORD_CURRENT:=}" \
  "${BOT_TOKEN:=}" "${WG_PORT:=}"
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
    set -- $1
    [ "$#" -eq 4 ] || return 1
    for _o; do
        case "$_o" in '' | *[!0-9]*) return 1 ;; esac
        [ "$_o" -le 255 ] || return 1
    done
}

is_hostname() {
    case "$1" in '' | -* | *- | *[!a-z0-9-]*) return 1 ;; esac
}

is_uint() { case "$1" in '' | *[!0-9]*) return 1 ;; esac; }

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
# ROOT_PASSWORD is the password to SET on the routers. On a factory image
# the current password is empty, so using the target one for the first
# login would fail. Probe with ROOT_PASSWORD_CURRENT (if set), then with
# ROOT_PASSWORD, then with an empty password (a factory image, which
# OpenWrt's dropbear accepts until a root password is set), and
# otherwise let ssh ask.
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
        for _p in "$ROOT_PASSWORD_CURRENT" "$ROOT_PASSWORD"; do
            [ -n "$_p" ] || continue
            if SSHPASS=$_p sshpass -e ssh "${SSH_OPTS[@]}" "root@$_h" true 2>/dev/null; then
                PW_MODE=sshpass
                PW_PASS=$_p
                break
            fi
        done
        # A factory image has no root password at all, and dropbear allows
        # an empty one until passwd runs. Try that before asking.
        if [ "$PW_MODE" = prompt ] \
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
    pw "$1" ssh "${SSH_OPTS[@]}" "root@$1" "rm -rf $dir" >/dev/null 2>&1 || true
    pw "$1" scp -O -q -r "${SSH_OPTS[@]}" "$2" "root@$1:$dir" \
        || { warn "couldn't copy to $1 - wrong ROOT_PASSWORD, or not reachable?"; return 2; }
    pw "$1" ssh -t "${SSH_OPTS[@]}" "root@$1" "${3//@DIR@/$dir}"
}
