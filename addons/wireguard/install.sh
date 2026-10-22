#!/bin/sh
# ========================================================
# wireguard addon installer - a WireGuard VPN server on the
# main router, managed in LuCI. Runs ON the main router;
# from the PC:  ./deploy.sh   (or ./addons/wireguard/client.sh
#              for one peer at a time)
#
# bifrost.conf seeds it, LuCI owns it. The first run creates
# each piece from wireguard.conf (written by deploy.sh); after
# that, a piece that exists is never touched again, so what
# you change in LuCI stays. Re-runs (e.g. after every flash)
# reinstall the packages and bring wg0 back up.
#
#   - interface wg0 with its key       (network.wg0)
#   - the "vpn" zone: VPN -> internet, VPN -> the services in
#     VPN_LAN_ACCESS, nothing else     (firewall.wgvpn*)
#   - WAN udp/WG_PORT open             (firewall.wgvpn_in)
#   - DuckDNS                          (ddns.duckdns)
#
#   install.sh                         install / repair
#   install.sh --check                 show state
#   install.sh --uninstall             remove all of it, keys and peers too
#   install.sh client add NAME [IP] | revoke NAME | list
# ========================================================

SRC_DIR=$(cd "$(dirname "$0")" && pwd)
CONF="$SRC_DIR/wireguard.conf"
PKGS="kmod-wireguard wireguard-tools luci-proto-wireguard qrencode"
DDNS_PKGS="ddns-scripts ddns-scripts-services luci-app-ddns ca-bundle"

RC=0
say()  { printf '%s\n' "$*"; }
ok()   { printf '  [ ok ] %s\n' "$*"; }
warn() { printf '  [warn] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; RC=1; }
hdr()  { printf '\n== %s\n' "$*"; }
die()  { printf '  [FAIL] %s\n' "$*"; exit 1; }

[ -r "$CONF" ] || die "cannot read $CONF - run this through ./deploy.sh"
. "$CONF"
if [ "$1" != "--uninstall" ] && grep -qE "=[\"']CHANGE_ME[\"']" "$CONF"; then
    die "$CONF still has CHANGE_ME placeholders"
fi

VPN_BASE=${VPN_SUBNET%.*}          # 10.7.0.0/24 -> 10.7.0
VPN_PREFIX=${VPN_SUBNET#*/}

# sections <config> <type> - real section names (cfgXXXX for anonymous ones)
sections() { uci -X show "$1" 2>/dev/null | sed -n "s/^$1\.\([^.=]*\)=$2\$/\1/p"; }

pkg_installed() { apk list --installed 2>/dev/null | grep -q "^$1-[0-9]"; }

# pkg_add <pkg>... - install what's missing, report what failed
pkg_add() {
    _missing=""
    for P in "$@"; do pkg_installed "$P" || _missing="$_missing $P"; done
    [ -n "$_missing" ] || return 0
    apk update >/dev/null 2>&1
    for P in $_missing; do
        apk add "$P" >/dev/null 2>&1 && ok "$P installed" || warn "$P failed to install"
    done
}

# firewall zone that holds wg0, wherever it came from (us or LuCI)
wg_zone() {
    for S in $(sections firewall zone); do
        uci -q get "firewall.$S.network" | grep -qw wg0 && { echo "$S"; return; }
    done
}

server_pub() { uci -q get network.wg0.private_key | wg pubkey; }

endpoint_host() {
    if [ -n "$DUCKDNS_DOMAIN" ]; then
        echo "$DUCKDNS_DOMAIN.duckdns.org"
    else
        ifstatus wan 2>/dev/null | jsonfilter -e '@["ipv4-address"][0].address'
    fi
}

# ---- steps ---------------------------------------------------------

check_host() {
    hdr "Host"
    [ -f /etc/openwrt_release ] || die "this does not look like OpenWrt"
    [ -f /tmp/dhcp.leases ] || die "no dnsmasq leases - run this on the MAIN router"
    ok "$(uname -n)"
}

install_pkgs() {
    hdr "Packages"
    pkg_add $PKGS
    [ -n "$DUCKDNS_DOMAIN" ] && pkg_add $DDNS_PKGS
    pkg_installed kmod-wireguard && pkg_installed wireguard-tools \
        || die "WireGuard packages missing (no internet?) - re-run later"
    # LuCI only offers the WireGuard protocol after rpcd reloads it.
    /etc/init.d/rpcd restart >/dev/null 2>&1
    ok "WireGuard, LuCI support${DUCKDNS_DOMAIN:+, DDNS}"
}

seed_interface() {
    hdr "Interface wg0"
    if uci -q get network.wg0 >/dev/null; then
        ok "exists - left as it is (edit it in LuCI: Network > Interfaces > wg0)"
        return
    fi
    uci set network.wg0=interface
    uci set network.wg0.proto='wireguard'
    uci set network.wg0.private_key="$(wg genkey)"
    uci set network.wg0.listen_port="$WG_PORT"
    uci add_list network.wg0.addresses="$VPN_BASE.1/$VPN_PREFIX"
    uci commit network
    ok "created: $VPN_BASE.1/$VPN_PREFIX, udp/$WG_PORT"
}

seed_firewall() {
    hdr "Firewall"
    _z=$(wg_zone)
    if [ -n "$_z" ]; then
        ok "zone $(uci -q get "firewall.$_z.name") holds wg0 - left as it is (edit it in LuCI: Network > Firewall)"
    else
        uci set firewall.wgvpn=zone
        uci set firewall.wgvpn.name='vpn'
        uci add_list firewall.wgvpn.network='wg0'
        uci set firewall.wgvpn.input='REJECT'
        uci set firewall.wgvpn.output='ACCEPT'
        uci set firewall.wgvpn.forward='REJECT'

        # VPN -> internet (the wan zone masquerades)
        uci set firewall.wgvpn_wan=forwarding
        uci set firewall.wgvpn_wan.src='vpn'
        uci set firewall.wgvpn_wan.dest='wan'

        uci set firewall.wgvpn_ping=rule
        uci set firewall.wgvpn_ping.name='vpn-ping-router'
        uci set firewall.wgvpn_ping.src='vpn'
        uci set firewall.wgvpn_ping.proto='icmp'
        uci add_list firewall.wgvpn_ping.icmp_type='echo-request'
        uci set firewall.wgvpn_ping.target='ACCEPT'

        # VPN -> the LAN services in VPN_LAN_ACCESS, nothing else on the LAN
        _n=0
        for E in $VPN_LAN_ACCESS; do
            _ip=${E%%:*}; _r=${E#*:}; _proto=${_r%%:*}; _port=${_r#*:}
            case "$_proto:$_port" in
                tcp:[0-9]*|udp:[0-9]*) ;;
                *) die "bad VPN_LAN_ACCESS entry '$E' (want ip:tcp|udp:port)" ;;
            esac
            _n=$((_n + 1))
            uci set "firewall.wgvpn_lan$_n=rule"
            uci set "firewall.wgvpn_lan$_n.name=vpn-$_ip-$_proto-$_port"
            uci set "firewall.wgvpn_lan$_n.src=vpn"
            uci set "firewall.wgvpn_lan$_n.dest=lan"
            uci set "firewall.wgvpn_lan$_n.dest_ip=$_ip"
            uci set "firewall.wgvpn_lan$_n.proto=$_proto"
            uci set "firewall.wgvpn_lan$_n.dest_port=$_port"
            uci set "firewall.wgvpn_lan$_n.target=ACCEPT"
        done
        ok "zone vpn created: internet, ping, and $_n LAN service(s)"
    fi

    if uci -q get firewall.wgvpn_in >/dev/null; then
        ok "WAN rule exists - left as it is"
    else
        uci set firewall.wgvpn_in=rule
        uci set firewall.wgvpn_in.name='wireguard-in'
        uci set firewall.wgvpn_in.src='wan'
        uci set firewall.wgvpn_in.proto='udp'
        uci set firewall.wgvpn_in.dest_port="$WG_PORT"
        uci set firewall.wgvpn_in.target='ACCEPT'
        ok "WAN udp/$WG_PORT open"
    fi
    uci commit firewall
}

seed_ddns() {
    hdr "DuckDNS"
    if [ -z "$DUCKDNS_DOMAIN" ]; then
        ok "off (DUCKDNS_DOMAIN empty) - clients get the WAN IP as endpoint"
        return
    fi
    [ -x /etc/init.d/ddns ] || { warn "ddns-scripts missing - re-run later"; return; }
    if uci -q get ddns.duckdns >/dev/null; then
        ok "exists - left as it is (edit it in LuCI: Services > Dynamic DNS)"
    else
        [ -n "$DUCKDNS_TOKEN" ] || die "set DUCKDNS_TOKEN in bifrost.conf"
        uci set ddns.duckdns=service
        uci set ddns.duckdns.enabled='1'
        uci set ddns.duckdns.service_name='duckdns.org'
        uci set ddns.duckdns.lookup_host="$DUCKDNS_DOMAIN.duckdns.org"
        uci set ddns.duckdns.domain="$DUCKDNS_DOMAIN.duckdns.org"
        uci set ddns.duckdns.username='NA'
        uci set ddns.duckdns.password="$DUCKDNS_TOKEN"
        uci set ddns.duckdns.interface='wan'
        uci set ddns.duckdns.ip_source='network'
        uci set ddns.duckdns.ip_network='wan'
        uci set ddns.duckdns.use_https='1'
        uci set ddns.duckdns.cacert='/etc/ssl/certs'
        uci commit ddns
        ok "$DUCKDNS_DOMAIN.duckdns.org follows the WAN address"
    fi
    /etc/init.d/ddns enable >/dev/null 2>&1
    /etc/init.d/ddns restart >/dev/null 2>&1
}

apply() {
    hdr "Apply"
    service network reload >/dev/null 2>&1
    /etc/init.d/firewall reload >/dev/null 2>&1
    sleep 3
    ifup wg0 >/dev/null 2>&1
    ok "network and firewall reloaded"
}

check() {
    hdr "Check"
    for P in $PKGS; do
        pkg_installed "$P" && ok "$P installed" || warn "$P missing"
    done
    if wg show wg0 >/dev/null 2>&1; then
        ok "wg0 up on udp/$(wg show wg0 listen-port), $(wg show wg0 peers | wc -l) peer(s)"
        say "         server public key: $(wg show wg0 public-key)"
    else
        warn "wg0 is not up (ifup wg0; logread -e wireguard)"
    fi
    _z=$(wg_zone)
    [ -n "$_z" ] && ok "wg0 is in zone $(uci -q get "firewall.$_z.name")" || warn "wg0 is in no firewall zone"
    [ "$(uci -q get firewall.wgvpn_in.dest_port)" = "$(uci -q get network.wg0.listen_port)" ] \
        && ok "WAN rule matches the listen port" || warn "WAN rule and wg0 listen port differ"

    # Inbound WireGuard only works with a real public WAN address.
    _wan=$(ifstatus wan 2>/dev/null | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
    case "$_wan" in
        "")                                   warn "no WAN IPv4 address" ;;
        10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*)
                                              warn "WAN $_wan is private - inbound WireGuard can't work" ;;
        100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*)
                                              warn "WAN $_wan is CGNAT - inbound WireGuard can't work" ;;
        *)                                    ok "WAN address $_wan is public" ;;
    esac
    if [ -n "$DUCKDNS_DOMAIN" ] && [ -n "$_wan" ]; then
        _dns=$(nslookup "$DUCKDNS_DOMAIN.duckdns.org" 9.9.9.9 2>/dev/null | awk '/^Address/ && !/#/ {print $NF}' | tail -n1)
        [ "$_dns" = "$_wan" ] && ok "$DUCKDNS_DOMAIN.duckdns.org -> $_wan" \
            || warn "$DUCKDNS_DOMAIN.duckdns.org -> ${_dns:-nothing}, WAN is $_wan (it updates within minutes)"
    fi
}

uninstall() {
    hdr "Uninstall"
    for S in $(sections network wireguard_wg0); do uci delete "network.$S"; done
    uci -q delete network.wg0 && ok "removed wg0, its key and peers"
    for S in $(sections firewall zone) $(sections firewall forwarding) $(sections firewall rule); do
        case "$S" in wgvpn*) uci delete "firewall.$S" ;; esac
    done
    ok "removed the vpn zone and its rules"
    uci -q delete ddns.duckdns && { uci commit ddns; ok "removed DuckDNS"; }
    uci commit network
    uci commit firewall
    apply
    say ""
    say "Left in place: the packages (harmless)"
}

# ---- clients -------------------------------------------------------

client_add() {
    _name=$1; _ip=$2
    [ -n "$_name" ] || die "usage: install.sh client add NAME [IP]"
    case "$_name" in ""|*[!A-Za-z0-9._-]*) die "client name: letters, digits, . _ - only" ;; esac
    [ "$VPN_PREFIX" = 24 ] || die "VPN_SUBNET must be a /24 for automatic client IPs"
    uci -q get network.wg0 >/dev/null || die "no wg0 - run the install first"
    _endpoint=$(endpoint_host)
    [ -n "$_endpoint" ] || die "no WAN IPv4 address or DuckDNS domain - the client endpoint would be empty"
    for S in $(sections network wireguard_wg0); do
        [ "$(uci -q get "network.$S.description")" = "$_name" ] && die "client $_name already exists"
    done
    _used=$(for S in $(sections network wireguard_wg0); do uci -q get "network.$S.allowed_ips"; done)
    if [ -z "$_ip" ]; then
        _last=$(echo "$_used" | tr ' ' '\n' | sed -n "s|^$VPN_BASE\.\([0-9]*\)/32$|\1|p" | sort -n | tail -n1)
        _ip=$VPN_BASE.$(( ${_last:-1} + 1 ))
    fi
    # The server is $VPN_BASE.1/24; anything else has no route back through
    # the tunnel, and the client would look connected but reach nothing.
    case "$_ip" in
        "$VPN_BASE".*) _host=${_ip#"$VPN_BASE".} ;;
        *) die "$_ip is outside $VPN_SUBNET" ;;
    esac
    case "$_host" in ''|*[!0-9]*) die "bad client IP $_ip" ;; esac
    [ "$_host" -ge 2 ] && [ "$_host" -le 254 ] || die "$_ip must be ${VPN_BASE}.2-254"
    echo "$_used" | tr ' ' '\n' | grep -qx "$_ip/32" && die "$_ip already used"

    _key=$(wg genkey); _psk=$(wg genpsk)
    # An anonymous peer section: a name-derived one could collide when two
    # client names differ only in . or - (both map to _).
    _sec=$(uci add network wireguard_wg0)
    uci set "network.$_sec.description=$_name"
    uci set "network.$_sec.public_key=$(echo "$_key" | wg pubkey)"
    uci set "network.$_sec.preshared_key=$_psk"
    uci add_list "network.$_sec.allowed_ips=$_ip/32"
    uci commit network
    ifup wg0 >/dev/null 2>&1

    # The router keeps only the public key; this file is the one copy of
    # the private key (client.sh fetches it, then deletes it).
    _conf="/tmp/wg-$_name.conf"
    ( umask 077; cat > "$_conf" <<EOF
[Interface]
PrivateKey = $_key
Address = $_ip/32
DNS = $CLIENT_DNS

[Peer]
PublicKey = $(server_pub)
PresharedKey = $_psk
Endpoint = $_endpoint:$(uci -q get network.wg0.listen_port)
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
    )
    qrencode -t ansiutf8 < "$_conf"
    ok "client $_name -> $_ip (scan the QR above; client.sh also saves wg-$_name.conf)"
}

client_revoke() {
    [ -n "$1" ] || die "usage: install.sh client revoke NAME"
    _found=0
    for S in $(sections network wireguard_wg0); do
        [ "$(uci -q get "network.$S.description")" = "$1" ] || continue
        uci delete "network.$S"; _found=1
    done
    [ "$_found" = 1 ] || die "no client $1"
    uci commit network
    ifup wg0 >/dev/null 2>&1
    ok "client $1 revoked"
}

client_list() {
    for S in $(sections network wireguard_wg0); do
        printf '  %s\t%s\n' "$(uci -q get "network.$S.description")" "$(uci -q get "network.$S.allowed_ips")"
    done
}

# ---- main ----------------------------------------------------------

case "$1" in
    "")
        check_host
        install_pkgs
        seed_interface
        seed_firewall
        seed_ddns
        apply
        check
        ;;
    --check)
        check_host
        check
        ;;
    --uninstall)
        uninstall
        ;;
    client)
        case "$2" in
            add)    client_add "$3" "$4" ;;
            revoke) client_revoke "$3" ;;
            list)   client_list ;;
            *)      die "usage: install.sh client add NAME [IP] | revoke NAME | list" ;;
        esac
        ;;
    *)
        say "usage: $0 [--check|--uninstall] | client ..."
        exit 1
        ;;
esac

say ""
exit "$RC"
