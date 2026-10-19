#!/bin/ash
# ========================================================
# Dumb AP setup for OpenWrt (AX4200 / 25.12.x)
#
#   sh dumb-ap_ax4200.sh ap1     # 192.168.1.2
#   sh dumb-ap_ax4200.sh ap2     # 192.168.1.3
#
#   scp -O -r router/setup root@<current ip>:/tmp/
#   ssh root@<current ip> 'sh /tmp/setup/dumb-ap_ax4200.sh ap1'
#
# On a factory-fresh AP the current IP is 192.168.1.1. The
# AP moves to its final IP mid-run, so the SSH session will
# freeze; that's expected, the script keeps going and
# reboots on its own. Safe to re-run after every flash.
# ========================================================

# Per-AP settings. Channels must not overlap the main router
# (2.4: 1, 5: 36 @ 80 MHz = 36-48) or each other. ap1 has the
# weakest clients, so it gets 100: under EU (ETSI) rules that band
# allows 27 dBm vs 20 dBm on 52-64.
case "$1" in
    ap1)
        AP_HOSTNAME="ax4200-ap1"; AP_IP="192.168.1.2"
        CH24="6";    BW24="20"
        CH5="100";   BW5="80"
        ;;
    ap2)
        AP_HOSTNAME="ax4200-ap2"; AP_IP="192.168.1.3"
        CH24="11";   BW24="20"
        CH5="52";    BW5="80"
        ;;
    *)
        echo "usage: $0 ap1|ap2"
        exit 1
        ;;
esac
# ========================================================

. "$(dirname "$0")/common.sh"

setup_system "$AP_HOSTNAME"

# ========================================================
# Network: WAN port joins the LAN bridge, static LAN, no IPv6
hdr "Network"

# Read the WAN port name before the wan interface is deleted. On a
# re-run it is already gone, and the port is already in the bridge.
WAN_PORT=$(uci -q get network.wan.device)
uci -q delete network.wan
uci -q delete network.wan6

br_dedupe_ports
[ -n "$WAN_PORT" ] && br_add_port "$WAN_PORT"

uci set network.lan.proto='static'
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

# ========================================================
# No DHCP, RA, DNS or firewall: the main router does all that
hdr "Services"
: > /etc/config/dhcp
for S in firewall dnsmasq odhcpd; do
    /etc/init.d/$S stop    >/dev/null 2>&1
    /etc/init.d/$S disable >/dev/null 2>&1
done
ok "firewall, dnsmasq, odhcpd disabled"

service network reload >/dev/null 2>&1 || /etc/init.d/network restart
sleep 5

# ========================================================
if wait_for_internet; then
    sync_time
    install_full_wpad
    install_usteer
fi

setup_wireless "$AP_HOSTNAME" "$CH24" "$BW24" "$CH5" "$BW5"

finish
