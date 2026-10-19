#!/bin/sh
# ========================================================
# addon-pi-gateway installer - the router side of the Pi
# WireGuard gateway (pi/PI_ZERO_SETUP.md).
#
# Run this ON ax6000-main, from a copy of this directory:
#
#   scp -O -r router/addon-pi-gateway root@192.168.1.1:/tmp/
#   ssh root@192.168.1.1 'sh /tmp/addon-pi-gateway/install.sh'
#
# What it owns on the router, and nothing else:
#   - USB-ethernet drivers so the Pi shows up as $PI_PORT
#   - $PI_PORT as a br-lan port
#   - the Pi's static DHCP lease (section pigw_<PI_NAME>)
#   - the WAN -> Pi WireGuard port forward (section pigw_wireguard)
#
# Idempotent: re-run after every flash or after editing
# pi-gateway.conf. Any other lease for the same MAC/IP, or other
# port forward of the same WAN port (e.g. one made by hand in
# LuCI), is replaced so there is exactly one of each.
#
#   install.sh              install / update
#   install.sh --check      show state, test reachability
#   install.sh --uninstall  remove leases, port forward, bridge port
# ========================================================

SRC_DIR=$(cd "$(dirname "$0")" && pwd)
CONF="$SRC_DIR/pi-gateway.conf"
PKGS="kmod-usb-net-cdc-ether kmod-usb-net-rndis"
FWD_SEC="pigw_wireguard"

RC=0
say()  { printf '%s\n' "$*"; }
ok()   { printf '  [ ok ] %s\n' "$*"; }
warn() { printf '  [warn] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; RC=1; }
hdr()  { printf '\n== %s\n' "$*"; }

[ -r "$CONF" ] || { echo "cannot read $CONF (cp pi-gateway.conf.example pi-gateway.conf, then fill it in)"; exit 1; }
. "$CONF"
if [ "$1" != "--uninstall" ] && grep -q 'CHANGE_ME' "$CONF"; then
    echo "$CONF still has CHANGE_ME placeholders"
    exit 1
fi

lc() { echo "$1" | tr 'A-F' 'a-f'; }

# sections <config> <type> - real section names (cfgXXXX for anonymous ones)
sections() { uci -X show "$1" 2>/dev/null | sed -n "s/^$1\.\([^.=]*\)=$2\$/\1/p"; }

# lease section name for a host name
lease_sec() { echo "pigw_$(echo "$1" | tr -c 'a-zA-Z0-9\n' '_')"; }

# "name,mac,ip" of every lease this addon owns (just the Pi)
all_leases() {
    echo "$PI_NAME,$(lc "$PI_MAC"),$PI_IP"
}

br_lan_section() {
    uci show network | sed -n "s/^network\.\([^.]*\)\.name='br-lan'$/\1/p" | head -n1
}

pkg_installed() {
    if command -v apk >/dev/null 2>&1; then
        apk list --installed 2>/dev/null | grep -q "^$1-[0-9]"
    else
        opkg list-installed 2>/dev/null | grep -q "^$1 "
    fi
}

# ---- steps ---------------------------------------------------------

check_host() {
    hdr "Host"
    [ -f /etc/openwrt_release ] || { fail "this does not look like OpenWrt"; return; }
    [ -f /tmp/dhcp.leases ] || { fail "no dnsmasq leases - run this on the MAIN router"; return; }
    ok "$(uname -n)"
}

install_pkgs() {
    hdr "USB-ethernet drivers"
    _missing=""
    for P in $PKGS; do pkg_installed "$P" || _missing="$_missing $P"; done
    if [ -z "$_missing" ]; then
        ok "already installed"
        return
    fi
    if command -v apk >/dev/null 2>&1; then
        apk update >/dev/null 2>&1; apk add $_missing >/dev/null 2>&1
    else
        opkg update >/dev/null 2>&1; opkg install $_missing >/dev/null 2>&1
    fi
    for P in $_missing; do
        pkg_installed "$P" && ok "$P installed" || fail "$P failed to install (no internet?)"
    done
}

setup_bridge() {
    hdr "Bridge"
    _sec=$(br_lan_section)
    [ -n "$_sec" ] || { fail "br-lan device section not found"; return; }
    if uci -q get "network.$_sec.ports" | grep -qw "$PI_PORT"; then
        ok "$PI_PORT already in br-lan"
    else
        uci add_list "network.$_sec.ports=$PI_PORT"
        ok "$PI_PORT added to br-lan"
    fi
}

setup_leases() {
    hdr "Static leases"
    _want=""
    for L in $(all_leases); do
        _name=${L%%,*}; _r=${L#*,}; _mac=${_r%%,*}; _ip=${_r#*,}
        _sec=$(lease_sec "$_name")
        _want="$_want $_sec"

        # Drop any other lease claiming the same MAC or IP.
        for S in $(sections dhcp host); do
            [ "$S" = "$_sec" ] && continue
            _m=$(lc "$(uci -q get "dhcp.$S.mac")")
            _i=$(uci -q get "dhcp.$S.ip")
            if echo " $_m " | grep -q " $_mac " || [ "$_i" = "$_ip" ]; then
                uci delete "dhcp.$S"
                ok "replaced existing lease $S ($_m -> $_i)"
            fi
        done

        uci set "dhcp.$_sec=host"
        uci set "dhcp.$_sec.name=$_name"
        uci -q delete "dhcp.$_sec.mac"
        uci add_list "dhcp.$_sec.mac=$_mac"
        uci set "dhcp.$_sec.ip=$_ip"
        ok "$_name  $_mac  $_ip"
    done

    # Any other pigw_* lease (e.g. after renaming PI_NAME) is stale.
    for S in $(sections dhcp host); do
        case "$S" in pigw_*) ;; *) continue ;; esac
        echo " $_want " | grep -q " $S " && continue
        uci delete "dhcp.$S"
        ok "removed stale lease $S"
    done
}

setup_forward() {
    hdr "Port forward"
    for S in $(sections firewall redirect); do
        [ "$S" = "$FWD_SEC" ] && continue
        [ "$(uci -q get "firewall.$S.src_dport")" = "$WG_PORT" ] || continue
        uci delete "firewall.$S"
        ok "replaced existing port forward $S"
    done
    uci set "firewall.$FWD_SEC=redirect"
    uci set "firewall.$FWD_SEC.name=pi-wireguard"
    uci set "firewall.$FWD_SEC.target=DNAT"
    uci set "firewall.$FWD_SEC.family=ipv4"
    uci set "firewall.$FWD_SEC.proto=udp"
    uci set "firewall.$FWD_SEC.src=wan"
    uci set "firewall.$FWD_SEC.src_dport=$WG_PORT"
    uci set "firewall.$FWD_SEC.dest=lan"
    uci set "firewall.$FWD_SEC.dest_ip=$PI_IP"
    uci set "firewall.$FWD_SEC.dest_port=$WG_PORT"
    ok "wan udp/$WG_PORT -> $PI_IP:$WG_PORT"
}

apply() {
    hdr "Apply"
    uci commit network
    uci commit dhcp
    uci commit firewall
    service network reload >/dev/null 2>&1
    /etc/init.d/dnsmasq restart >/dev/null 2>&1
    /etc/init.d/firewall reload >/dev/null 2>&1
    ok "network, dnsmasq, firewall reloaded"
}

check() {
    hdr "Check"
    for P in $PKGS; do
        pkg_installed "$P" && ok "$P installed" || warn "$P missing"
    done

    uci -q get "network.$(br_lan_section).ports" | grep -qw "$PI_PORT" \
        && ok "$PI_PORT is a br-lan port" || warn "$PI_PORT not in br-lan"
    if ip link show "$PI_PORT" >/dev/null 2>&1; then
        ok "$PI_PORT present ($(cat "/sys/class/net/$PI_PORT/operstate" 2>/dev/null))"
    else
        warn "$PI_PORT not present - Pi unplugged, or drivers missing"
    fi

    for L in $(all_leases); do
        _name=${L%%,*}; _r=${L#*,}; _mac=${_r%%,*}; _ip=${_r#*,}
        _sec=$(lease_sec "$_name")
        if [ "$(uci -q get "dhcp.$_sec.ip")" = "$_ip" ]; then
            ok "lease $_name -> $_ip configured"
        else
            warn "lease $_name not configured"
        fi
        _live=$(awk -v m="$_mac" 'tolower($2) == m { print $3 }' /tmp/dhcp.leases)
        [ -n "$_live" ] && say "         live lease: $_live"
    done

    _d=$(uci -q get "firewall.$FWD_SEC.dest_ip")
    [ "$_d" = "$PI_IP" ] && ok "port forward udp/$WG_PORT -> $_d" || warn "port forward missing"

    ping -c1 -W2 "$PI_IP" >/dev/null 2>&1 && ok "Pi answers at $PI_IP" || warn "Pi not answering at $PI_IP"

    # Inbound WireGuard only works with a real public WAN address.
    _wan=$(ifstatus wan 2>/dev/null | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
    case "$_wan" in
        "")                                   warn "no WAN IPv4 address" ;;
        10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*)
                                              warn "WAN $_wan is private - inbound WireGuard can't work" ;;
        100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*)
                                              warn "WAN $_wan is CGNAT - inbound WireGuard can't work" ;;
        *)                                    ok "WAN address is public" ;;
    esac
}

uninstall() {
    hdr "Uninstall"
    for S in $(sections dhcp host); do
        case "$S" in pigw_*) uci delete "dhcp.$S"; ok "removed lease $S" ;; esac
    done
    uci -q delete "firewall.$FWD_SEC" && ok "removed port forward"
    uci -q del_list "network.$(br_lan_section).ports=$PI_PORT" && ok "removed $PI_PORT from br-lan"
    apply
    say ""
    say "Left in place: $PKGS (harmless)"
}

# ---- main ----------------------------------------------------------

case "$1" in
    "")
        check_host
        [ "$RC" -eq 0 ] || exit 1
        install_pkgs
        setup_bridge
        setup_leases
        setup_forward
        apply
        sleep 3
        check
        ;;
    --check)
        check_host
        check
        ;;
    --uninstall)
        uninstall
        ;;
    *)
        say "usage: $0 [--check|--uninstall]"
        exit 1
        ;;
esac

say ""
exit "$RC"
