#!/bin/ash
# ========================================================
# Main router setup for OpenWrt 25.12: PPPoE gateway, DHCP,
# DNS, Wi-Fi. Every value comes from bifrost.conf (as
# network.conf, written by deploy.sh).
#
#   ./deploy.sh main          (from the PC; or, on the router:)
#   sh /tmp/setup/main-router.sh
#
# Safe to re-run after every flash. Reboots at the end.
# ========================================================

. "$(dirname "$0")/common.sh"

setup_system "$MAIN_HOSTNAME"

# ---- Network: WAN PPPoE + static LAN, no IPv6 ---------------------
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
# The WAN port must never also be a LAN bridge port.
uci -q del_list "network.$(br_lan_section).ports=$WAN_DEVICE"
setup_packet_steering
uci commit network
ok "WAN pppoe on $WAN_DEVICE, LAN $GW_IP"

# ---- DNS/DHCP: dnsmasq serves DHCPv4 + DNS, no IPv6 RA/DHCPv6 -----
hdr "DHCP/DNS"
uci set dhcp.@dnsmasq[0].edns0='1'
uci -q delete dhcp.@dnsmasq[0].server
for D in $DNS_LIST; do uci add_list dhcp.@dnsmasq[0].server="$D"; done
uci -q delete dhcp.lan.ra
uci -q delete dhcp.lan.dhcpv6
uci -q delete dhcp.lan.ndp
uci -q delete dhcp.lan.dhcp_option
[ -n "$DHCP_DNS_OPTION" ] && uci add_list dhcp.lan.dhcp_option="$DHCP_DNS_OPTION"
uci commit dhcp
ok "upstream DNS: $DNS_LIST; clients get ${DHCP_DNS_OPTION:-the router}"

# ---- NAT offload: established flows bypass the CPU ----------------
# In hardware where the SoC supports it; fw4 falls back to software.
hdr "Firewall"
uci set firewall.@defaults[0].flow_offloading='1'
uci set firewall.@defaults[0].flow_offloading_hw='1'
uci commit firewall
/etc/init.d/firewall restart >/dev/null 2>&1
ok "flow offloading (hw) enabled"

service network reload >/dev/null 2>&1 || /etc/init.d/network restart
/etc/init.d/dnsmasq restart >/dev/null 2>&1
sleep 5

if wait_for_internet; then
    sync_time
    install_full_wpad
    install_usteer
fi

# ---- UPnP / NAT-PMP (UPNP in bifrost.conf) ------------------------
# Its packages don't survive a flash, so they're reinstalled here. Its
# options (/etc/config/upnpd, kept by "keep settings", editable in
# LuCI) are left alone; only the on/off switch is set.
hdr "UPnP"
if [ "${UPNP:-0}" = 1 ]; then
    if [ ! -x /etc/init.d/miniupnpd ]; then
        apk add luci-app-upnp >/dev/null 2>&1 || apk add miniupnpd-nftables >/dev/null 2>&1
    fi
    if [ -x /etc/init.d/miniupnpd ]; then
        uci -q get upnpd.config >/dev/null || uci set upnpd.config=upnpd
        uci set upnpd.config.enabled='1'
        uci commit upnpd
        /etc/init.d/miniupnpd enable >/dev/null 2>&1
        /etc/init.d/miniupnpd restart >/dev/null 2>&1
        ok "on"
    else
        warn "couldn't install UPnP (no internet?) - re-run this script later"
    fi
elif [ -x /etc/init.d/miniupnpd ]; then
    uci -q set upnpd.config.enabled='0' && uci commit upnpd
    /etc/init.d/miniupnpd stop >/dev/null 2>&1
    /etc/init.d/miniupnpd disable >/dev/null 2>&1
    ok "off"
else
    ok "off"
fi

setup_wireless "$MAIN_HOSTNAME" "$MAIN_CH24" "$BW24" "$MAIN_CH5" "$BW5"

finish
