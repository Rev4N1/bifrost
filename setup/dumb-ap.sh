#!/bin/ash
# ========================================================
# Dumb AP setup for OpenWrt 25.12: bridge only, no DHCP,
# DNS or firewall. Its IP and channels come from the APS
# list in bifrost.conf (as network.conf, written by deploy.sh).
#
#   ./deploy.sh ap <hostname>  (from the PC; or, on the AP:)
#   sh /tmp/bifrost-setup/dumb-ap.sh <hostname>
#
# A factory-fresh AP is still at 192.168.1.1. The first run moves
# it to its final IP and reboots; the next run at that address
# installs packages and configures Wi-Fi. Re-running an AP that
# already has its final IP is safe after every flash.
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
uci set network.lan.ipv6='0'
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
# Stop dnsmasq *before* emptying /etc/config/dhcp: its stop handler is
# what points /tmp/resolv.conf at netifd's interface DNS (network.lan.dns
# above). With an empty config it finds no dnsmasq section and leaves
# /tmp/resolv.conf on the now-dead 127.0.0.1, so the AP could not resolve
# the package repo below.
for S in firewall dnsmasq odhcpd; do
    /etc/init.d/$S stop    >/dev/null 2>&1
    /etc/init.d/$S disable >/dev/null 2>&1
done
: > /etc/config/dhcp
# Belt and braces: netifd writes this file from the interface's DNS.
ln -sf /tmp/resolv.conf.d/resolv.conf.auto /tmp/resolv.conf
ok "firewall, dnsmasq, odhcpd disabled"

# The IP change below drops the SSH session. Keep stdout/stderr on a file
# from here on, so later commands don't write to a dead pipe.
[ "$AP_IP" = "$_OLD_LAN" ] || exec >/tmp/dumb-ap.log 2>&1
/etc/init.d/network reload >/dev/null 2>&1 || /etc/init.d/network restart
if [ "$AP_IP" != "$_OLD_LAN" ]; then
    # The address changed, so this is a factory AP (or one being moved).
    # Stop here and reboot: the SSH session is gone, and the PC cannot
    # tell whether the AP is still working or already back up. The next
    # run at the final address installs packages and configures Wi-Fi.
    say "  moved from $_OLD_LAN to $AP_IP"
    say "  plug it into the main LAN, then run ./deploy.sh again"
    reboot_now 0
fi
sleep 5

if wait_for_internet; then
    sync_time
    install_full_wpad
    install_usteer
fi

setup_wireless "$AP_HOSTNAME" "$CH24" "$BW24" "$CH5" "$BW5"

finish
