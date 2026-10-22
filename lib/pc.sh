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
: "${GW_IP:=}" "${APS:=}" "${ROOT_PASSWORD:=}" "${BOT_TOKEN:=}" "${WG_PORT:=}"
[ "$(stat -c %a "$CONF")" = 600 ] || warn "chmod 600 $CONF (it holds every password)"

# require VAR... - each must be set and not CHANGE_ME
require() {
    local v
    for v in "$@"; do
        [ -n "${!v:-}" ] && [ "${!v}" != CHANGE_ME ] || die "set $v in $CONF"
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

# pw <ssh|scp> <args...> - run it, typing ROOT_PASSWORD when sshpass is there
pw() {
    if [ -n "$ROOT_PASSWORD" ] && command -v sshpass >/dev/null; then
        SSHPASS=$ROOT_PASSWORD sshpass -e "$@"
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
    pw ssh "${SSH_OPTS[@]}" "root@$1" "rm -rf $dir" >/dev/null 2>&1 || true
    pw scp -O -q -r "${SSH_OPTS[@]}" "$2" "root@$1:$dir" \
        || { warn "couldn't copy to $1 - wrong ROOT_PASSWORD, or not reachable?"; return 2; }
    pw ssh -t "${SSH_OPTS[@]}" "root@$1" "${3//@DIR@/$dir}"
}
