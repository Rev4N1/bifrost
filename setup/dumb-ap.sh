#!/bin/ash
# ========================================================
# Dumb AP setup for OpenWrt 25.12: bridge only, no DHCP,
# DNS or firewall. Its IP and channels come from the APS
# list in bifrost.conf (as network.conf, written by deploy.sh).
#
#   ./deploy.sh ap <hostname>  (from the PC; or, on the AP:)
#   sh /tmp/bifrost-setup/dumb-ap.sh <hostname>
#
# A factory-fresh AP is still at 192.168.1.1 and moves to
# its final IP mid-run, so the SSH session freezes; the
# script keeps going and reboots on its own. Safe to re-run
# after every flash (it reboots only when something changed).
# ========================================================

. "$(dirname "$0")/common.sh"

AP_HOSTNAME=""
for E in $APS; do
    [ "${E%%,*}" = "$1" ] || continue
    IFS=, read -r AP_HOSTNAME AP_IP CH24 CH5 <<EOF
$E
EOF
done
[ -n "$AP_HOSTNAME" ] || die "usage: $0 <hostname>  (one of: $(for E in $APS; do printf '%s ' "${E%%,*}"; done))"

setup_system "$AP_HOSTNAME"

# ---- Network: WAN port joins the LAN bridge, static LAN, no IPv6 --
hdr "Network"

# Read the WAN port name before the wan interface is deleted. On a
# re-run it is already gone, and the port is already in the bridge.
WAN_PORT=$(uci -q get network.wan.device)
uci -q delete network.wan
uci -q delete network.wan6

[ -n "$WAN_PORT" ] && br_add_port "$WAN_PORT"

uci set network.lan.proto='static'
_OLD_LAN=$(uci -q get network.lan.ipaddr)
uci set network.lan.ipaddr="$AP_IP"
uci set network.lan.netmask="$NETMASK"
uci set network.lan.gateway="$GW_IP"
uci -q delete network.lan.dns
uci add_list network.lan.dns="$GW_IP"
uci -q delete network.lan.ip6assign
uci set network.lan.delegate='0'
uci -q delete network.globals.ula_prefix
setup_packet_steering
uci commit network
ok "LAN $AP_IP, gateway/DNS $GW_IP"

# ---- No DHCP, RA, DNS or firewall: the main router does all that --
hdr "Services"
: > /etc/config/dhcp
for S in firewall dnsmasq odhcpd; do
    /etc/init.d/$S stop    >/dev/null 2>&1
    /etc/init.d/$S disable >/dev/null 2>&1
done
ok "firewall, dnsmasq, odhcpd disabled"

# The IP change below drops the SSH session. Keep stdout/stderr on a file
# from here on, so later commands don't write to a dead pipe.
[ "$AP_IP" = "$_OLD_LAN" ] || exec >/tmp/dumb-ap.log 2>&1
/etc/init.d/network reload >/dev/null 2>&1 || /etc/init.d/network restart
sleep 5

if wait_for_internet; then
    sync_time
    install_full_wpad
    install_usteer
fi

setup_wireless "$AP_HOSTNAME" "$CH24" "$BW24" "$CH5" "$BW5"

finish
