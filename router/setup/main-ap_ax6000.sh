#!/bin/ash
# ========================================================
# Main router setup for OpenWrt (AX6000 / 25.12.x)
# Factory-defaults expected.
#
#   scp -O -r router/setup root@192.168.1.1:/tmp/
#   ssh root@192.168.1.1 'sh /tmp/setup/main-ap_ax6000.sh'
#
# Safe to re-run after every flash. Reboots at the end.
# ========================================================
AP_HOSTNAME="ax6000-main"
DNS_LIST="9.9.9.11 149.112.112.11"
DHCP_DNS_OPTION="6,192.168.1.1,8.8.8.8"

# WAN (PPPoE; login is in network.conf). eth1 = the port labelled
# WAN on the TUF-AX6000 (LAN ports are lan1-lan5).
WAN_DEVICE="eth1"

# Channels
CH24="1";     BW24="20"
CH5="36";     BW5="80"# ========================================================

. "$(dirname "$0")/common.sh"

setup_system "$AP_HOSTNAME"

# ========================================================
# Network: WAN PPPoE + static LAN, no IPv6
hdr "Network"
uci -q delete network.wan6

uci set network.wan=interface
uci set network.wan.device="$WAN_DEVICE"
uci set network.wan.proto='pppoe'
uci set network.wan.username="$PPPOE_USER"
uci set network.wan.password="$PPPOE_PASS"

uci set network.lan.proto='static'
uci set network.lan.ipaddr="$GW_IP"
uci set network.lan.netmask="$NETMASK"
uci -q delete network.lan.ip6assign
uci set network.lan.delegate='0'
uci -q delete network.globals.ula_prefix
br_dedupe_ports
# The WAN port must never also be a LAN bridge port.
uci -q del_list "network.$(br_lan_section).ports=$WAN_DEVICE"
setup_packet_steering
uci commit network
ok "WAN pppoe on $WAN_DEVICE, LAN $GW_IP"

# ========================================================
# DNS/DHCP: dnsmasq serves DHCPv4 + DNS, no IPv6 RA/DHCPv6
hdr "DHCP/DNS"
uci set dhcp.@dnsmasq[0].edns0='1'
uci -q delete dhcp.@dnsmasq[0].server
for D in $DNS_LIST; do uci add_list dhcp.@dnsmasq[0].server="$D"; done
uci -q delete dhcp.lan.ra
uci -q delete dhcp.lan.dhcpv6
uci -q delete dhcp.lan.ndp
# DNS servers handed to clients (DHCP option 6)
uci -q delete dhcp.lan.dhcp_option
uci add_list dhcp.lan.dhcp_option="$DHCP_DNS_OPTION"
uci commit dhcp
ok "upstream DNS: $DNS_LIST; clients get $DHCP_DNS_OPTION"

# ========================================================
# NAT offload: established flows bypass the CPU, in hardware where the
# SoC supports it (fw4 falls back to software otherwise).
hdr "Firewall"
uci set firewall.@defaults[0].flow_offloading='1'
uci set firewall.@defaults[0].flow_offloading_hw='1'
uci commit firewall
/etc/init.d/firewall restart >/dev/null 2>&1
ok "flow offloading (hw) enabled"

service network reload >/dev/null 2>&1 || /etc/init.d/network restart
/etc/init.d/dnsmasq restart >/dev/null 2>&1
sleep 5

# ========================================================
if wait_for_internet; then
    sync_time
    install_full_wpad
    install_usteer
fi

setup_wireless "$AP_HOSTNAME" "$CH24" "$BW24" "$CH5" "$BW5"

finish
