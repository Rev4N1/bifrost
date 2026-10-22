#!/usr/bin/env bash
# ========================================================
# client.sh - add, list or revoke WireGuard clients on the
# main router, from the PC.
#
#   ./addons/wireguard/client.sh add <name> [ip]
#   ./addons/wireguard/client.sh revoke <name>
#   ./addons/wireguard/client.sh list
#
# This is an operational tool, not part of deploy.sh: deploy
# configures and maintains, this changes one peer at a time.
#
# Settings: bifrost.conf. Run ./deploy.sh once first, so the
# addon is installed on the router.
# ========================================================
set -euo pipefail
cd "$(dirname "$0")/../.."

CONF=bifrost.conf
WG_VARS="WG_PORT VPN_SUBNET CLIENT_DNS VPN_LAN_ACCESS DUCKDNS_DOMAIN DUCKDNS_TOKEN"

say()  { printf '\n>>> %s\n' "$*"; }
warn() { printf 'client: %s\n' "$*" >&2; }
die()  { printf 'client: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
client.sh - WireGuard clients on the main router

  ./addons/wireguard/client.sh add <name> [ip]
  ./addons/wireguard/client.sh revoke <name>
  ./addons/wireguard/client.sh list

Without an IP, add picks the next free one in VPN_SUBNET.
Settings: bifrost.conf. Run ./deploy.sh once first.
EOF
    exit 1
}

[ "$#" -ge 1 ] || usage
case "$1" in
    add)    [ "$#" -ge 2 ] && [ "$#" -le 3 ] || usage
            case "$2" in
                ""|*[!A-Za-z0-9._-]*) die "client name: letters, digits, . _ - only" ;;
            esac
            ;;
    revoke) [ "$#" -eq 2 ] || usage ;;
    list)   [ "$#" -eq 1 ] || usage ;;
    *)      usage ;;
esac

# ---- config ---------------------------------------------------------

[ -f "$CONF" ] || die "$CONF is missing: cp -n $CONF.example $CONF, then fill it in"
set +u
# shellcheck source=/dev/null  # the user's file, not in this repo
. "./$CONF"
set -u
: "${GW_IP:=}" "${ROOT_PASSWORD:=}" "${WG_PORT:=}" "${VPN_SUBNET:=}" "${CLIENT_DNS:=}"

require() {
    local v
    for v in "$@"; do
        [ -n "${!v:-}" ] && [ "${!v}" != CHANGE_ME ] || die "set $v in $CONF"
    done
}

sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

emit() {
    local v
    for v in "$@"; do printf '%s=%s\n' "$v" "$(sq "${!v-}")"; done
}

# ---- ssh ------------------------------------------------------------

SSH_OPTS=(-o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3
          -o PubkeyAuthentication=no -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR)
if [ "$(uname -s)" = Linux ]; then
    mkdir -p ~/.ssh && chmod 700 ~/.ssh
    SSH_OPTS=(-o ControlMaster=auto -o ControlPath="$HOME/.ssh/cm-%r@%h:%p" -o ControlPersist=60 "${SSH_OPTS[@]}")
fi

pw() {
    if [ -n "$ROOT_PASSWORD" ] && command -v sshpass >/dev/null; then
        SSHPASS=$ROOT_PASSWORD sshpass -e "$@"
    else
        "$@"
    fi
}

# ---- run ------------------------------------------------------------

require GW_IP ROOT_PASSWORD WG_PORT VPN_SUBNET CLIENT_DNS

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -r addons/wireguard "$STAGE/"
# shellcheck disable=SC2086
emit $WG_VARS > "$STAGE/wireguard/wireguard.conf"
chmod 600 "$STAGE/wireguard/wireguard.conf"

# router_run <remote command>: copy the addon to /tmp, run it there.
router_run() {
    pw scp -O -q -r "${SSH_OPTS[@]}" "$STAGE/wireguard" "root@$GW_IP:/tmp/"
    pw ssh -t "${SSH_OPTS[@]}" "root@$GW_IP" "$1"
}

case "$1" in
    add)
        name=$2; ip=${3:-}
        say "client $name on $GW_IP"
        if [ -n "$ip" ]; then
            router_run "sh /tmp/wireguard/install.sh client add $(sq "$name") $(sq "$ip")"
        else
            router_run "sh /tmp/wireguard/install.sh client add $(sq "$name")"
        fi

        # The router keeps only the public key, and deletes this file.
        pw scp -O -q "${SSH_OPTS[@]}" "root@$GW_IP:/tmp/wg-$name.conf" ~/ \
            || die "client added, but ~/wg-$name.conf could not be fetched"
        pw ssh "${SSH_OPTS[@]}" "root@$GW_IP" "rm -f /tmp/wg-$name.conf" || true
        say "saved ~/wg-$name.conf (has the private key)"
        echo "    Fedora: sudo nmcli connection import type wireguard file ~/wg-$name.conf"
        echo "    Other:  import it in the WireGuard app, then delete the file"
        ;;
    revoke)
        say "revoke client $2 on $GW_IP"
        router_run "sh /tmp/wireguard/install.sh client revoke $(sq "$2")"
        ;;
    list)
        say "clients on $GW_IP"
        router_run "sh /tmp/wireguard/install.sh client list"
        ;;
esac
