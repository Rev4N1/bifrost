#!/bin/sh
# ========================================================
# addon-pi-gateway installer - the router side of the Pi
# Tailscale node (pi/README.md). Runs ON the main router;
# from the PC:  ./deploy.sh pi-gateway [--usb]
#
# What it owns on the router, and nothing else:
#   - USB-ethernet drivers so the Pi shows up as $PI_PORT
#   - $PI_PORT as a br-lan port
#   - the Pi's static DHCP lease (section pigw_<PI_NAME>)
# Tailscale needs no port forward.
#
# Idempotent: re-run after every flash or after editing
# bifrost.conf (deploy.sh writes pi-gateway.conf from it). Any
# other lease for the same MAC/IP is replaced so there is
# exactly one.
#
#   install.sh              install / update
#   install.sh --check      show state, test reachability
#   install.sh --uninstall  remove lease, bridge port
# ========================================================

SRC_DIR=$(cd "$(dirname "$0")" && pwd)
CONF="$SRC_DIR/pi-gateway.conf"
PKGS="kmod-usb-net-cdc-ether kmod-usb-net-rndis"

RC=0
say()  { printf '%s\n' "$*"; }
ok()   { printf '  [ ok ] %s\n' "$*"; }
warn() { printf '  [warn] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; RC=1; }
hdr()  { printf '\n== %s\n' "$*"; }

[ -r "$CONF" ] || { echo "cannot read $CONF - run this through ./deploy.sh pi-gateway"; exit 1; }
. "$CONF"
if [ "$1" != "--uninstall" ] && grep -qE "=[\"']CHANGE_ME[\"']" "$CONF"; then
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

pkg_installed() { apk list --installed 2>/dev/null | grep -q "^$1-[0-9]"; }

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
    apk update >/dev/null 2>&1; apk add $_missing >/dev/null 2>&1
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

apply() {
    hdr "Apply"
    uci commit network
    uci commit dhcp
    service network reload >/dev/null 2>&1
    /etc/init.d/dnsmasq restart >/dev/null 2>&1
    ok "network, dnsmasq reloaded"
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

    ping -c1 -W2 "$PI_IP" >/dev/null 2>&1 && ok "Pi answers at $PI_IP" || warn "Pi not answering at $PI_IP"
}

uninstall() {
    hdr "Uninstall"
    for S in $(sections dhcp host); do
        case "$S" in pigw_*) uci delete "dhcp.$S"; ok "removed lease $S" ;; esac
    done
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
