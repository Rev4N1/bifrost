#!/bin/ash
# ========================================================
# Main router setup for OpenWrt 25.12: PPPoE gateway, DHCP,
# DNS, Wi-Fi. Every value comes from bifrost.conf (as
# network.conf, written by deploy.sh).
#
#   ./deploy.sh               (from the PC; or, on the router:)
#   sh /tmp/bifrost-setup/main-router.sh
#
# Safe to re-run after every flash. Reboots at the end only if
# something actually changed. If GW_IP differs from the router's
# current LAN address, the first run moves it and reboots; run
# again at the new address to finish.
# ========================================================

. "$(dirname "$0")/common.sh"

# WAN_DEVICE must be this box's WAN port. On the first run the factory
# config still names it, and a wrong name here leaves the router without
# internet, so stop before changing anything.
_WAN_DEV=$(uci -q get network.wan.device)
_WAN_PROTO=$(uci -q get network.wan.proto)
if [ "$_WAN_PROTO" != pppoe ] && [ -n "$_WAN_DEV" ] && [ "$_WAN_DEV" != "$WAN_DEVICE" ]; then
    die "factory WAN is '$_WAN_DEV', but WAN_DEVICE is '$WAN_DEVICE' - fix WAN_DEVICE in bifrost.conf"
fi
[ -e "/sys/class/net/$WAN_DEVICE" ] \
    || die "WAN_DEVICE '$WAN_DEVICE' is not a device on this router (have: $(ls /sys/class/net | tr '\n' ' '))"

setup_system "$MAIN_HOSTNAME"

# ---- Network: WAN PPPoE + static LAN, no IPv6 ---------------------
hdr "Network"
uci -q delete network.wan6

uci set network.wan=interface
uci set network.wan.device="$WAN_DEVICE"
uci set network.wan.proto='pppoe'
uci set network.wan.username="$PPPOE_USER"
uci set network.wan.password="$PPPOE_PASS"
# IPv4 only. Deleting wan6 alone does not stop PPPoE from negotiating
# IPv6; ipv6=0 does (a ppp option). The LAN side is off on br-lan below.
uci set network.wan.ipv6='0'

uci set network.lan.proto='static'
_OLD_LAN=$(uci -q get network.lan.ipaddr)
uci set network.lan.ipaddr="$GW_IP"
uci set network.lan.netmask="$NETMASK"
uci -q delete network.lan.ip6assign
uci set network.lan.delegate='0'
uci -q delete network.globals.ula_prefix
# The WAN port must never also be a LAN bridge port.
_BR=$(br_lan_section)
[ -n "$_BR" ] || die "no br-lan device found - refusing to leave $WAN_DEVICE in the LAN bridge"
uci -q del_list "network.$_BR.ports=$WAN_DEVICE" || true
br_no_ipv6
setup_packet_steering
uci commit network
ok "WAN pppoe on $WAN_DEVICE, LAN $GW_IP"

# ---- DNS/DHCP: dnsmasq serves DHCPv4 + DNS, no IPv6 RA/DHCPv6 -----
hdr "DHCP/DNS"
uci set dhcp.@dnsmasq[0].edns0='1'
uci -q delete dhcp.@dnsmasq[0].server
if [ -n "$DNS_LIST" ]; then
    # The list is the whole upstream policy, not a fallback added to the
    # ISP resolvers: noresolv stops dnsmasq reading the WAN's resolv.conf.
    for D in $DNS_LIST; do uci add_list dhcp.@dnsmasq[0].server="$D"; done
    uci set dhcp.@dnsmasq[0].noresolv='1'
else
    uci -q delete dhcp.@dnsmasq[0].noresolv
fi
uci -q delete dhcp.lan.ra
uci -q delete dhcp.lan.dhcpv6
uci -q delete dhcp.lan.ndp
uci -q delete dhcp.lan.dhcp_option
[ -n "$DHCP_DNS_OPTION" ] && uci add_list dhcp.lan.dhcp_option="$DHCP_DNS_OPTION"
uci commit dhcp
if [ -n "$DNS_LIST" ]; then
    ok "upstream DNS: $DNS_LIST (only these)"
else
    ok "upstream DNS: the WAN DNS"
fi
ok "clients get ${DHCP_DNS_OPTION:-the router}"

# ---- NAT offload: established flows bypass the CPU ----------------
# In hardware where the SoC supports it; fw4 falls back to software.
hdr "Firewall"
uci set firewall.@defaults[0].flow_offloading='1'
uci set firewall.@defaults[0].flow_offloading_hw='1'
uci commit firewall
/etc/init.d/firewall restart >/dev/null 2>&1
ok "flow offloading (hw) enabled"

# The LAN IP change below drops the SSH session. Keep stdout/stderr on a
# file from here on, so later commands don't write to a dead pipe.
[ "$GW_IP" = "$_OLD_LAN" ] || exec >/tmp/main-router.log 2>&1
/etc/init.d/network reload >/dev/null 2>&1 || /etc/init.d/network restart
/etc/init.d/dnsmasq restart >/dev/null 2>&1
if [ "$GW_IP" != "$_OLD_LAN" ]; then
    # The address changed. Stop here and reboot; the next run at GW_IP
    # installs packages and configures Wi-Fi without racing this one.
    say "  moved from $_OLD_LAN to $GW_IP"
    say "  run ./deploy.sh again once it is back"
    reboot_now 0
fi
sleep 5

if wait_for_internet; then
    sync_time
    install_usteer
fi

# ---- UPnP / NAT-PMP (UPNP in bifrost.conf) ------------------------
# Its packages don't survive a flash, so they're reinstalled here. Its
# options (/etc/config/upnpd, kept by "keep settings", editable in
# LuCI) are left alone; only the on/off switch is set.
hdr "UPnP"
if [ "${UPNP:-0}" = 1 ]; then
    if [ ! -x /etc/init.d/miniupnpd ]; then
        apk update >/dev/null 2>&1
        apk add luci-app-upnp >/dev/null 2>&1
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
