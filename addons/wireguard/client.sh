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

WG_VARS="WG_PORT VPN_SUBNET VPN_LAN_ACCESS DUCKDNS_DOMAIN DUCKDNS_TOKEN"

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
. lib/pc.sh

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

# ---- run ------------------------------------------------------------

check_wg

DIR=$(stage addons/wireguard wireguard.conf "$WG_VARS")

# wg_run <install.sh arguments> - run the router-side installer with them
wg_run() { router_run "$GW_IP" "$DIR" "sh @DIR@/install.sh $*"; }

case "$1" in
    add)
        name=$2; ip=${3:-}
        say "client $name on $GW_IP"
        if [ -n "$ip" ]; then
            wg_run client add "$(sq "$name")" "$(sq "$ip")"
        else
            wg_run client add "$(sq "$name")"
        fi

        # The router keeps only the public key, and deletes this file.
        pw "$GW_IP" scp -O -q "${SSH_OPTS[@]}" "root@$GW_IP:/tmp/wg-$name.conf" ~/ \
            || die "client added, but ~/wg-$name.conf could not be fetched"
        pw "$GW_IP" ssh "${SSH_OPTS[@]}" "root@$GW_IP" "rm -f /tmp/wg-$name.conf" || true
        say "saved ~/wg-$name.conf (has the private key)"
        echo "    Fedora: sudo nmcli connection import type wireguard file ~/wg-$name.conf"
        echo "    Other:  import it in the WireGuard app, then delete the file"
        ;;
    revoke)
        say "revoke client $2 on $GW_IP"
        wg_run client revoke "$(sq "$2")"
        ;;
    list)
        say "clients on $GW_IP"
        wg_run client list
        ;;
esac
