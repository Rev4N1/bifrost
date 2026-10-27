#!/usr/bin/env bash
# ========================================================
# client.sh - add, list or revoke VPN clients (WireGuard or
# AmneziaWG, as VPN in bifrost.conf says) on the main router,
# from the PC.
#
#   ./addons/wireguard/client.sh add <name> [ip]
#   ./addons/wireguard/client.sh show <name>
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

WG_VARS="VPN VPN_PORT VPN_SUBNET CLIENT_DNS VPN_LAN_ACCESS DUCKDNS_DOMAIN DUCKDNS_TOKEN"

usage() {
    cat <<'EOF'
client.sh - VPN clients on the main router

  ./addons/wireguard/client.sh add <name> [ip]
  ./addons/wireguard/client.sh show <name>
  ./addons/wireguard/client.sh revoke <name>
  ./addons/wireguard/client.sh list

Without an IP, add picks the next free one in VPN_SUBNET. show makes an
existing client's config and QR again (after switching VPN kinds).
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
    show)   [ "$#" -eq 2 ] || usage
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

# fetch_conf <name> - copy the config install.sh left in /tmp to ~/, then
# delete it on the router
fetch_conf() {
    pw "$GW_IP" scp -O -q "${SSH_OPTS[@]}" "root@$GW_IP:/tmp/wg-$1.conf" ~/ \
        || die "wg-$1.conf could not be fetched to ~/"
    pw "$GW_IP" ssh "${SSH_OPTS[@]}" "root@$GW_IP" "rm -f /tmp/wg-$1.conf" || true
    say "saved ~/wg-$1.conf (has the private key)"
    if [ "$VPN" = amneziawg ]; then
        echo "    Import it in the AmneziaWG app (Android, iOS, Windows, macOS),"
        echo "    then delete the file. Plain WireGuard apps can't use it."
    else
        echo "    Fedora: sudo nmcli connection import type wireguard file ~/wg-$1.conf"
        echo "    Other:  import it in the WireGuard app, then delete the file"
    fi
}

case "$1" in
    add)
        name=$2; ip=${3:-}
        say "client $name on $GW_IP"
        if [ -n "$ip" ]; then
            wg_run client add "$(sq "$name")" "$(sq "$ip")"
        else
            wg_run client add "$(sq "$name")"
        fi
        fetch_conf "$name"
        ;;
    show)
        say "client $2 on $GW_IP"
        wg_run client show "$(sq "$2")"
        fetch_conf "$2"
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
