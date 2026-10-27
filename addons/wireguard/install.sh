#!/bin/sh
# ========================================================
# wireguard addon installer - a WireGuard or AmneziaWG VPN
# server on the main router, managed in LuCI. Runs ON the main
# router; from the PC:  ./deploy.sh   (or ./addons/wireguard/client.sh
#              for one peer at a time)
#
# VPN in bifrost.conf picks the kind: wireguard (interface wg0)
# or amneziawg (interface awg0: WireGuard with obfuscated
# packets, from the Slava-Shchipunov/awg-openwrt feed). One at a time:
# switching moves the old interface, its clients and zone to the new one.
#
# bifrost.conf seeds it, LuCI owns it. The first run creates
# each piece from wireguard.conf (written by deploy.sh); after
# that, a piece that exists is never touched again, so what
# you change in LuCI stays. The exception is the LAN service
# rules (firewall.wgvpn_lan*): they always follow VPN_LAN_ACCESS. Re-runs (e.g. after every flash)
# reinstall the packages and bring the interface back up.
#
#   - interface wg0/awg0 with its key  (network.wg0 / network.awg0)
#   - the "vpn" zone: VPN -> internet, VPN -> the services in
#     VPN_LAN_ACCESS, nothing else     (firewall.wgvpn*)
#   - WAN udp/VPN_PORT open            (firewall.wgvpn_in)
#   - DuckDNS                          (ddns.duckdns)
#
#   install.sh                         install / repair
#   install.sh --check                 show state
#   install.sh --uninstall             remove all of it, keys and peers too
#   install.sh client add NAME [IP] | show NAME | revoke NAME | list
# ========================================================

SRC_DIR=$(cd "$(dirname "$0")" && pwd)
CONF="$SRC_DIR/wireguard.conf"
DDNS_PKGS="ddns-scripts ddns-scripts-services luci-app-ddns ca-bundle"

say()  { printf '%s\n' "$*"; }
ok()   { printf '  [ ok ] %s\n' "$*"; }
warn() { printf '  [warn] %s\n' "$*"; }
hdr()  { printf '\n== %s\n' "$*"; }
die()  { printf '  [FAIL] %s\n' "$*"; exit 1; }

[ -r "$CONF" ] || die "cannot read $CONF - run this through ./deploy.sh"
# shellcheck disable=SC1090  # staged config written by deploy.sh
. "$CONF"
if [ "$1" != "--uninstall" ] && grep -qE "=[\"']CHANGE_ME[\"']" "$CONF"; then
    die "$CONF still has CHANGE_ME placeholders"
fi

# IFACE: the interface; TOOL: its wg-style CLI; PEER: the uci type of its
# peers. The two kinds never run together (same subnet, same zone): OTHER
# is the other kind's interface, which a switch migrates into IFACE.
case "${VPN:-wireguard}" in
    wireguard)
        IFACE=wg0; OTHER=awg0; PROTO=wireguard; OTHER_PROTO=amneziawg; TOOL=wg
        PKGS="kmod-wireguard wireguard-tools luci-proto-wireguard qrencode" ;;
    amneziawg)
        IFACE=awg0; OTHER=wg0; PROTO=amneziawg; OTHER_PROTO=wireguard; TOOL=awg
        PKGS="kmod-amneziawg amneziawg-tools luci-proto-amneziawg qrencode" ;;
    *)
        [ "$1" = "--uninstall" ] || die "VPN must be wireguard or amneziawg, not '$VPN'"
        IFACE=wg0; OTHER=awg0; PROTO=wireguard; OTHER_PROTO=amneziawg; TOOL=wg; PKGS="" ;;
esac
PEER="${PROTO}_$IFACE"

# The Slava-Shchipunov/awg-openwrt feed: one per exact OpenWrt release and target,
# because kmod-amneziawg must match the kernel. Its signing key ships with
# bifrost (awg-openwrt-feed.pem) rather than being fetched at install time,
# so a swapped key on the feed's site can't slip in.
AWG_FEED_ROOT="https://slava-shchipunov.github.io/awg-openwrt"
AWG_FEED_LIST="/etc/apk/repositories.d/bifrost-amneziawg.list"
AWG_FEED_KEY="/etc/apk/keys/awg-openwrt-feed.pem"

VPN_BASE=${VPN_SUBNET%.*}          # 10.7.0.0/24 -> 10.7.0
VPN_PREFIX=${VPN_SUBNET#*/}

# The PC validates this too, but install.sh is also usable by hand.
is_ipv4() {
    _ipv4_v=$1
    case "$_ipv4_v" in '' | *[!0-9.]* | *.) return 1 ;; esac
    _ipv4_n=0
    _ipv4_ifs=$IFS; IFS=.
    for _ipv4_o in $_ipv4_v; do
        [ -n "$_ipv4_o" ] || { IFS=$_ipv4_ifs; return 1; }
        # Reject leading zeros: ash arithmetic reads 010 as octal.
        [ "${#_ipv4_o}" -le 3 ] || { IFS=$_ipv4_ifs; return 1; }
        [ "$_ipv4_o" = 0 ] || [ "${_ipv4_o#0}" = "$_ipv4_o" ] \
            || { IFS=$_ipv4_ifs; return 1; }
        [ "$_ipv4_o" -le 255 ] || { IFS=$_ipv4_ifs; return 1; }
        _ipv4_n=$((_ipv4_n + 1))
    done
    IFS=$_ipv4_ifs
    [ "$_ipv4_n" -eq 4 ]
}

if [ "$1" != "--uninstall" ]; then
    case "$VPN_SUBNET" in
        *.0/24) is_ipv4 "${VPN_SUBNET%/*}" || die "VPN_SUBNET has no IPv4 address" ;;
        *)      die "VPN_SUBNET must be a /24 starting at .0 (e.g. 10.7.0.0/24)" ;;
    esac
    case "$VPN_PORT" in '' | *[!0-9]*) die "VPN_PORT must be 1-65535" ;; esac
    [ "$VPN_PORT" -ge 1 ] && [ "$VPN_PORT" -le 65535 ] || die "VPN_PORT must be 1-65535"
fi

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

# firewall zone that holds $IFACE, wherever it came from (us or LuCI)
wg_zone() {
    for S in $(sections firewall zone); do
        uci -q get "firewall.$S.network" | grep -qw "$IFACE" && { echo "$S"; return; }
    done
}

server_pub() { uci -q get network.$IFACE.private_key | $TOOL pubkey; }

# vpn_lan_hosts - the LAN addresses the vpn zone may reach: dest_ip of
# every enabled ACCEPT rule from vpn to lan, as they are now on the router
# (seeded from VPN_LAN_ACCESS, then whatever LuCI changed).
vpn_lan_hosts() {
    _vz=$(uci -q get "firewall.$(wg_zone).name")
    [ -n "$_vz" ] || return 0
    for S in $(sections firewall rule); do
        [ "$(uci -q get "firewall.$S.src")" = "$_vz" ] || continue
        [ "$(uci -q get "firewall.$S.dest")" = lan ] || continue
        [ "$(uci -q get "firewall.$S.target")" = ACCEPT ] || continue
        [ "$(uci -q get "firewall.$S.enabled")" != 0 ] || continue
        uci -q get "firewall.$S.dest_ip"
    done | tr ' ' '\n' | grep . | sort -u
}

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
    . /etc/openwrt_release
    case "${DISTRIB_RELEASE:-}" in
        25.*) ;;
        *) die "this addon targets OpenWrt 25.12 (apk); found ${DISTRIB_RELEASE:-unknown}" ;;
    esac
    command -v apk >/dev/null 2>&1 || die "apk not found - not an apk-based 25.12 image"
    # A dumb AP has an empty /etc/config/dhcp. Checking the config, not a
    # lease file, keeps a fresh main router with no clients from failing.
    uci -q get dhcp.@dnsmasq[0] >/dev/null \
        || die "no dnsmasq config - run this on the MAIN router"
    ok "$(uname -n)"
}

# awg_feed - point apk at the AmneziaWG feed for this exact release and
# target. Checked every run: a flash to a new release needs that release's
# feed (and its matching kmod), and a flash may drop /etc/apk.
awg_feed() {
    _rel=$(sed -n "s/^DISTRIB_RELEASE=['\"]\{0,1\}\([^'\"]*\)['\"]\{0,1\}$/\1/p" /etc/openwrt_release)
    _tgt=$(sed -n "s/^DISTRIB_TARGET=['\"]\{0,1\}\([^'\"]*\)['\"]\{0,1\}$/\1/p" /etc/openwrt_release)
    case "$_rel/$_tgt" in
        */*/*/* | /* | */ | *//* | *[!0-9A-Za-z._/-]*)
            die "cannot tell the OpenWrt release/target ('$_rel/$_tgt')" ;;
    esac
    _url="$AWG_FEED_ROOT/$_rel/$_tgt/packages.adb"
    mkdir -p "${AWG_FEED_KEY%/*}" "${AWG_FEED_LIST%/*}"
    cp "$SRC_DIR/awg-openwrt-feed.pem" "$AWG_FEED_KEY" || die "cannot install the feed key"
    [ "$(cat "$AWG_FEED_LIST" 2>/dev/null)" = "$_url" ] || echo "$_url" > "$AWG_FEED_LIST"
    # pkg_add only updates the index when something is missing; a stale
    # index from another release's feed must not be trusted either way.
    apk update >/dev/null 2>&1 \
        || die "no AmneziaWG feed for OpenWrt $_rel $_tgt ($_url) - wait for it, or set VPN=wireguard"
    ok "AmneziaWG feed for $_rel $_tgt"
}

install_pkgs() {
    hdr "Packages"
    [ "$PROTO" = amneziawg ] && awg_feed
    pkg_add $PKGS
    [ -n "$DUCKDNS_DOMAIN" ] && pkg_add $DDNS_PKGS
    pkg_installed "kmod-$PROTO" && pkg_installed "$PROTO-tools" \
        || die "$PROTO packages missing (no internet?) - re-run later"
    # LuCI only offers the protocol after rpcd reloads it.
    /etc/init.d/rpcd restart >/dev/null 2>&1
    ok "$PROTO, LuCI support${DUCKDNS_DOMAIN:+, DDNS}"
}

# migrate - VPN switched kinds: move the other kind's interface into this
# one. The server key, the address, every peer (keys, IPs, names), the vpn
# zone and the LAN rules all carry over, so a client keeps its address and
# LAN access; it only needs a new config (other app, port and, for
# AmneziaWG, the obfuscation settings): client.sh show NAME. The listen
# port and the WAN rule follow VPN_PORT. One kind at a time: both would
# want the same subnet and the same zone.
migrate() {
    uci -q get "network.$OTHER" >/dev/null || return 0
    hdr "Switch $OTHER -> $IFACE"
    uci -q get "network.$IFACE" >/dev/null \
        && die "both $OTHER and $IFACE exist - remove one in LuCI (Network > Interfaces), then re-run"
    uci set "network.$IFACE=interface"
    uci set "network.$IFACE.proto=$PROTO"
    for O in private_key mtu; do
        _v=$(uci -q get "network.$OTHER.$O") && uci set "network.$IFACE.$O=$_v"
    done
    for A in $(uci -q get "network.$OTHER.addresses"); do
        uci add_list "network.$IFACE.addresses=$A"
    done
    uci set "network.$IFACE.listen_port=$VPN_PORT"
    [ "$PROTO" = amneziawg ] && awg_params
    _n=0
    for S in $(sections network "${OTHER_PROTO}_$OTHER"); do
        _sec=$(uci add network "$PEER")
        for O in description public_key private_key preshared_key persistent_keepalive \
                 route_allowed_ips endpoint_host endpoint_port disabled; do
            _v=$(uci -q get "network.$S.$O") && uci set "network.$_sec.$O=$_v"
        done
        for A in $(uci -q get "network.$S.allowed_ips"); do
            uci add_list "network.$_sec.allowed_ips=$A"
        done
        uci delete "network.$S"
        _n=$((_n + 1))
    done
    uci delete "network.$OTHER"
    ok "$IFACE: same key and address, $_n client(s) moved, udp/$VPN_PORT"

    for S in $(sections firewall zone); do
        uci -q get "firewall.$S.network" | grep -qw "$OTHER" || continue
        uci del_list "firewall.$S.network=$OTHER"
        uci add_list "firewall.$S.network=$IFACE"
        ok "zone $(uci -q get "firewall.$S.name") now holds $IFACE (its LAN rules are unchanged)"
    done
    if uci -q get firewall.wgvpn_in >/dev/null; then
        uci set "firewall.wgvpn_in.dest_port=$VPN_PORT"
        ok "WAN rule: udp/$VPN_PORT"
    fi
    uci commit network
    uci commit firewall
    say "         every client needs a new config: ./addons/wireguard/client.sh show NAME"
}

# rand <min> <max> - a random integer from the kernel's generator
rand() {
    _r=$(hexdump -n 4 -e '1/4 "%u"' /dev/urandom 2>/dev/null) \
        || _r=$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')
    echo $(( $1 + _r % ($2 - $1 + 1) ))
}

# awg_params - the obfuscation settings, random per router so no two
# bifrost servers look alike. Clients must use the same values; client add
# copies them into every config. Only the AmneziaWG 1.x set (Jc, Jmin,
# Jmax, S1, S2, H1-H4), which every AmneziaWG client understands. Newer
# ones (S3, S4, I1-I5, ...) can be added in LuCI; then re-create the
# client configs.
awg_params() {
    uci set "network.$IFACE.awg_jc=$(rand 3 6)"
    uci set "network.$IFACE.awg_jmin=$(rand 40 60)"
    uci set "network.$IFACE.awg_jmax=$(rand 70 120)"
    _s1=$(rand 15 150)
    _s2=$(rand 15 150)
    # S1 + 56 = S2 would make the handshake's two packets the same size.
    [ $((_s1 + 56)) -ne "$_s2" ] || _s2=$((_s2 + 1))
    uci set "network.$IFACE.awg_s1=$_s1"
    uci set "network.$IFACE.awg_s2=$_s2"
    # H1-H4 replace WireGuard's message types 1-4: distinct, and above 4.
    _hs=" "
    for _h in 1 2 3 4; do
        _v=$(rand 5 2147483647)
        while case "$_hs" in *" $_v "*) true ;; *) false ;; esac; do
            _v=$(rand 5 2147483647)
        done
        _hs="$_hs$_v "
        uci set "network.$IFACE.awg_h$_h=$_v"
    done
}

seed_interface() {
    hdr "Interface $IFACE"
    if uci -q get network.$IFACE >/dev/null; then
        ok "exists - left as it is (edit it in LuCI: Network > Interfaces > $IFACE)"
        return
    fi
    uci set network.$IFACE=interface
    uci set network.$IFACE.proto="$PROTO"
    uci set network.$IFACE.private_key="$($TOOL genkey)"
    uci set network.$IFACE.listen_port="$VPN_PORT"
    uci add_list network.$IFACE.addresses="$VPN_BASE.1/$VPN_PREFIX"
    [ "$PROTO" = amneziawg ] && awg_params
    uci commit network
    ok "created: $VPN_BASE.1/$VPN_PREFIX, udp/$VPN_PORT"
}

# sync_lan_rules - make the wgvpn_lan<N> rules match VPN_LAN_ACCESS exactly.
# Unlike the rest of the addon these are owned by bifrost.conf: an entry
# removed there is removed from the router on the next deploy. Rules made
# in LuCI are anonymous sections (cfgXXXX), so they are never touched.
sync_lan_rules() {
    _vz=$(uci -q get "firewall.$(wg_zone).name"); _vz=${_vz:-vpn}
    _want=""
    for E in $VPN_LAN_ACCESS; do
        _ip=${E%%:*}; _r=${E#*:}; _proto=${_r%%:*}; _port=${_r#*:}
        is_ipv4 "$_ip" || die "bad VPN_LAN_ACCESS IP '$_ip' (want ip:tcp|udp:port)"
        case "$_proto" in
            tcp | udp) ;;
            *) die "bad VPN_LAN_ACCESS protocol '$_proto' (want tcp or udp)" ;;
        esac
        case "$_port" in
            '' | *[!0-9]*) die "bad VPN_LAN_ACCESS port '$_port'" ;;
        esac
        [ "$_port" -ge 1 ] && [ "$_port" -le 65535 ] \
            || die "VPN_LAN_ACCESS port $_port must be 1-65535"
        _want="$_want $_vz:$_ip:$_proto:$_port"
    done
    _have=""; _old=""
    for S in $(sections firewall rule); do
        case "$S" in wgvpn_lan[0-9]*) ;; *) continue ;; esac
        _old="$_old $S"
        _have="$_have $(uci -q get "firewall.$S.src"):$(uci -q get "firewall.$S.dest_ip"):$(uci -q get "firewall.$S.proto"):$(uci -q get "firewall.$S.dest_port")"
    done
    if [ "$_have" = "$_want" ]; then
        ok "LAN services match VPN_LAN_ACCESS ($(echo "$_want" | wc -w))"
        return
    fi
    # Rebuild rather than patch, so the numbering always follows the list.
    for S in $_old; do uci delete "firewall.$S"; done
    _n=0
    for E in $_want; do
        _ip=${E#*:}; _ip=${_ip%%:*}; _r=${E#*:*:}; _proto=${_r%%:*}; _port=${_r#*:}
        _n=$((_n + 1))
        uci set "firewall.wgvpn_lan$_n=rule"
        uci set "firewall.wgvpn_lan$_n.name=vpn-$_ip-$_proto-$_port"
        uci set "firewall.wgvpn_lan$_n.src=$_vz"
        uci set "firewall.wgvpn_lan$_n.dest=lan"
        uci set "firewall.wgvpn_lan$_n.dest_ip=$_ip"
        uci set "firewall.wgvpn_lan$_n.proto=$_proto"
        uci set "firewall.wgvpn_lan$_n.dest_port=$_port"
        uci set "firewall.wgvpn_lan$_n.target=ACCEPT"
    done
    ok "LAN services synced to VPN_LAN_ACCESS: $(echo "$_old" | wc -w) old rule(s) replaced by $_n"
}

seed_firewall() {
    hdr "Firewall"
    _z=$(wg_zone)
    if [ -n "$_z" ]; then
        ok "zone $(uci -q get "firewall.$_z.name") holds $IFACE - left as it is (edit it in LuCI: Network > Firewall)"
    else
        uci set firewall.wgvpn=zone
        uci set firewall.wgvpn.name='vpn'
        uci add_list firewall.wgvpn.network="$IFACE"
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

        ok "zone vpn created: internet and ping"
    fi
    sync_lan_rules

    if uci -q get firewall.wgvpn_in >/dev/null; then
        ok "WAN rule exists - left as it is"
    else
        uci set firewall.wgvpn_in=rule
        uci set firewall.wgvpn_in.name='wireguard-in'
        uci set firewall.wgvpn_in.src='wan'
        uci set firewall.wgvpn_in.proto='udp'
        uci set firewall.wgvpn_in.dest_port="$VPN_PORT"
        uci set firewall.wgvpn_in.target='ACCEPT'
        ok "WAN udp/$VPN_PORT open"
    fi
    uci commit firewall
}

seed_ddns() {
    hdr "DuckDNS"
    if [ -z "$DUCKDNS_DOMAIN" ]; then
        ok "off (DUCKDNS_DOMAIN empty) - clients get the WAN IP as endpoint"
        return
    fi
    case "$DUCKDNS_DOMAIN" in
        -* | *- | *[!A-Za-z0-9-]*)
            die "bad DUCKDNS_DOMAIN '$DUCKDNS_DOMAIN' (one subdomain: letters, digits, -)" ;;
    esac
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
        uci set ddns.duckdns.cacert='/etc/ssl/certs/ca-certificates.crt'
        uci commit ddns
        ok "$DUCKDNS_DOMAIN.duckdns.org follows the WAN address"
    fi
    /etc/init.d/ddns enable >/dev/null 2>&1
    /etc/init.d/ddns restart >/dev/null 2>&1
}

apply() {
    hdr "Apply"
    # netifd learns protocol handlers only when it starts: right after
    # the kmod and tools are installed (first run, or after a flash) it
    # doesn't know "$PROTO", and a reload leaves $IFACE with no protocol
    # and no device. Restart it then (a few seconds' outage, no reboot);
    # otherwise a reload is enough.
    # Run over the VPN itself, the restart cuts this SSH session; nohup
    # keeps the hangup from killing it halfway (network stopped, not yet
    # started again).
    trap '' HUP
    if ubus call network get_proto_handlers 2>/dev/null | grep -q "\"$PROTO\""; then
        nohup /etc/init.d/network reload >/dev/null 2>&1
        ok "network reloaded"
    else
        nohup /etc/init.d/network restart >/dev/null 2>&1
        ok "network restarted (netifd had to learn the $PROTO protocol)"
    fi
    /etc/init.d/firewall reload >/dev/null 2>&1
    sleep 3
    ifup "$IFACE" >/dev/null 2>&1
    ok "firewall reloaded"
}

check() {
    hdr "Check"
    for P in $PKGS; do
        pkg_installed "$P" && ok "$P installed" || warn "$P missing"
    done
    if $TOOL show "$IFACE" >/dev/null 2>&1; then
        ok "$IFACE up on udp/$($TOOL show "$IFACE" listen-port), $($TOOL show "$IFACE" peers | wc -l) peer(s)"
        say "         server public key: $($TOOL show "$IFACE" public-key)"
    else
        warn "$IFACE is not up (ifup $IFACE; logread -e $PROTO)"
    fi
    _z=$(wg_zone)
    [ -n "$_z" ] && ok "$IFACE is in zone $(uci -q get "firewall.$_z.name")" || warn "$IFACE is in no firewall zone"
    _rp=$(uci -q get firewall.wgvpn_in.dest_port)
    [ -n "$_rp" ] && [ "$_rp" = "$(uci -q get network.$IFACE.listen_port)" ] \
        && ok "WAN rule matches the listen port" || warn "WAN rule and $IFACE listen port differ"

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
        # The router's own resolver (which already follows DNS_LIST), not a
        # hard-coded public resolver. Only IPv4 answers matter here.
        _dns=$(nslookup "$DUCKDNS_DOMAIN.duckdns.org" 2>/dev/null \
            | sed -n 's/^Address: \([0-9][0-9.]*\)$/\1/p' | tail -n1)
        [ "$_dns" = "$_wan" ] && ok "$DUCKDNS_DOMAIN.duckdns.org -> $_wan" \
            || warn "$DUCKDNS_DOMAIN.duckdns.org -> ${_dns:-nothing}, WAN is $_wan (it updates within minutes)"
    fi
}

uninstall() {
    hdr "Uninstall"
    # Both kinds, whatever VPN says now: this is also how you switch.
    for I in wg0 awg0; do
        for S in $(sections network "wireguard_$I") $(sections network "amneziawg_$I"); do
            uci delete "network.$S"
        done
        uci -q delete "network.$I" && ok "removed $I, its key and peers"
    done
    rm -f "$AWG_FEED_LIST"
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
    uci -q get network.$IFACE >/dev/null || die "no $IFACE - run the install first"
    _endpoint=$(endpoint_host)
    [ -n "$_endpoint" ] || die "no WAN IPv4 address or DuckDNS domain - the client endpoint would be empty"
    for S in $(sections network "$PEER"); do
        [ "$(uci -q get "network.$S.description")" = "$_name" ] && die "client $_name already exists"
    done
    _used=$(for S in $(sections network "$PEER"); do uci -q get "network.$S.allowed_ips"; done)
    if [ -z "$_ip" ]; then
        # First free host, not "highest used + 1": a revoked client's
        # address should be reusable even when a higher one is in use.
        _n=2
        while [ "$_n" -le 254 ]; do
            _cand="$VPN_BASE.$_n"
            echo "$_used" | tr ' ' '\n' | grep -Fqx "$_cand/32" \
                || { _ip=$_cand; break; }
            _n=$((_n + 1))
        done
        [ -n "$_ip" ] || die "no free client address left in $VPN_SUBNET"
    fi
    is_ipv4 "$_ip" || die "$_ip is not an IPv4 address"
    # The server is $VPN_BASE.1/24; anything else has no route back through
    # the tunnel, and the client would look connected but reach nothing.
    case "$_ip" in
        "$VPN_BASE".*) _host=${_ip#"$VPN_BASE".} ;;
        *) die "$_ip is outside $VPN_SUBNET" ;;
    esac
    case "$_host" in ''|*[!0-9]*) die "bad client IP $_ip" ;; esac
    [ "$_host" -ge 2 ] && [ "$_host" -le 254 ] || die "$_ip must be ${VPN_BASE}.2-254"
    echo "$_used" | tr ' ' '\n' | grep -Fqx "$_ip/32" && die "$_ip already used"

    _key=$($TOOL genkey); _psk=$($TOOL genpsk)
    # An anonymous peer section: a name-derived one could collide when two
    # client names differ only in . or - (both map to _). The private key
    # stays on the peer, like a peer made in LuCI, so LuCI can show its
    # config and QR code later (Network > Interfaces > $IFACE > Peers).
    _sec=$(uci add network "$PEER")
    uci set "network.$_sec.description=$_name"
    uci set "network.$_sec.private_key=$_key"
    uci set "network.$_sec.public_key=$(echo "$_key" | $TOOL pubkey)"
    uci set "network.$_sec.preshared_key=$_psk"
    uci add_list "network.$_sec.allowed_ips=$_ip/32"
    uci commit network
    ifup "$IFACE" >/dev/null 2>&1
    client_conf "$_name" "$_key" "$_psk" "$_ip" "$_endpoint"
}

# client_show NAME - the config and QR of an existing client, again: after
# a switch of kinds, or a lost phone config. Works for any client whose
# private key the router keeps (client.sh add, or LuCI's own key pair).
client_show() {
    [ -n "$1" ] || die "usage: install.sh client show NAME"
    _endpoint=$(endpoint_host)
    [ -n "$_endpoint" ] || die "no WAN IPv4 address or DuckDNS domain - the client endpoint would be empty"
    for S in $(sections network "$PEER"); do
        [ "$(uci -q get "network.$S.description")" = "$1" ] || continue
        _key=$(uci -q get "network.$S.private_key") \
            || die "the router doesn't keep $1's private key - revoke it and add it again"
        _ip=$(uci -q get "network.$S.allowed_ips" | tr ' ' '\n' | grep -m1 '/32$')
        [ -n "$_ip" ] || die "$1 has no /32 address in its Allowed IPs"
        client_conf "$1" "$_key" "$(uci -q get "network.$S.preshared_key")" "${_ip%/32}" "$_endpoint"
        return
    done
    die "no client $1 (./addons/wireguard/client.sh list)"
}

# client_conf NAME KEY PSK IP ENDPOINT - write /tmp/wg-NAME.conf, show its QR
client_conf() {
    _name=$1; _key=$2; _psk=$3; _ip=$4; _endpoint=$5

    # Split tunnel: only the LAN hosts the vpn zone may reach go through the
    # tunnel, and the client keeps its own internet. With none opened, the
    # tunnel is only good for internet, so it carries everything (0.0.0.0/0).
    _allowed=""
    for H in $(vpn_lan_hosts); do
        case "$H" in */*) ;; *) H="$H/32" ;; esac
        case ", $_allowed, " in *", $H, "*) ;; *) _allowed="${_allowed:+$_allowed, }$H" ;; esac
    done
    [ -n "$_allowed" ] || _allowed=0.0.0.0/0

    # AmneziaWG: the client needs the server's obfuscation settings, as
    # they are on the router now (seeded, or changed in LuCI).
    _awg=""
    if [ "$PROTO" = amneziawg ]; then
        for O in jc:Jc jmin:Jmin jmax:Jmax s1:S1 s2:S2 s3:S3 s4:S4 \
                 h1:H1 h2:H2 h3:H3 h4:H4 i1:I1 i2:I2 i3:I3 i4:I4 i5:I5; do
            _v=$(uci -q get "network.$IFACE.awg_${O%%:*}") || continue
            _awg="$_awg${O#*:} = $_v
"
        done
    fi

    # client.sh fetches this file, then deletes it.
    _conf="/tmp/wg-$_name.conf"
    ( umask 077; cat > "$_conf" <<EOF
[Interface]
PrivateKey = $_key
Address = $_ip/32
${CLIENT_DNS:+DNS = $CLIENT_DNS
}$_awg
[Peer]
PublicKey = $(server_pub)
${_psk:+PresharedKey = $_psk
}Endpoint = $_endpoint:$(uci -q get network.$IFACE.listen_port)
AllowedIPs = $_allowed
PersistentKeepalive = 25
EOF
    )
    qrencode -t ansiutf8 < "$_conf"
    ok "client $_name -> $_ip (scan the QR above; client.sh also saves wg-$_name.conf)"
}

client_revoke() {
    [ -n "$1" ] || die "usage: install.sh client revoke NAME"
    _found=0
    for S in $(sections network "$PEER"); do
        [ "$(uci -q get "network.$S.description")" = "$1" ] || continue
        uci delete "network.$S"; _found=1
    done
    [ "$_found" = 1 ] || die "no client $1"
    uci commit network
    ifup "$IFACE" >/dev/null 2>&1
    ok "client $1 revoked"
}

client_list() {
    for S in $(sections network "$PEER"); do
        printf '  %s\t%s\n' "$(uci -q get "network.$S.description")" "$(uci -q get "network.$S.allowed_ips")"
    done
}

# ---- main ----------------------------------------------------------

case "$1" in
    "")
        check_host
        install_pkgs
        migrate
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
        check_host
        case "$2" in
            add)    client_add "$3" "$4" ;;
            show)   client_show "$3" ;;
            revoke) client_revoke "$3" ;;
            list)   client_list ;;
            *)      die "usage: install.sh client add NAME [IP] | show NAME | revoke NAME | list" ;;
        esac
        ;;
    *)
        say "usage: $0 [--check|--uninstall] | client ..."
        exit 1
        ;;
esac

say ""
