#!/bin/bash
# ========================================================
# pi/setup.sh - Raspberry Pi Zero 2 W as a portable
# Tailscale exit node and subnet router: on the main
# router's USB at home, on any Wi-Fi elsewhere. Runs as
# root on the Pi; deploy.sh copies it over with pi.conf
# (its part of bifrost.conf), runs it, and deletes both.
#
#   setup.sh network            usb0 as plain DHCP client + pinned MACs
#                               (first, while on the PC's USB)
#   setup.sh                    everything, network included (on the router)
#   setup.sh system|wifi|tailscale|firewall    one step
#   setup.sh wifi add SSID [PASSWORD] | forget SSID | list
#   setup.sh poweroff           shut down (before moving the cable)
#
# Every step converges: re-running it changes only what
# differs, and keeps the Tailscale login and pinned MACs.
# ========================================================
set -eu

DIR=$(cd "$(dirname "$0")" && pwd)
ok()   { printf '  [ ok ] %s\n' "$*"; }
warn() { printf '  [warn] %s\n' "$*"; }
hdr()  { printf '\n== %s\n' "$*"; }
die()  { printf '  [FAIL] %s\n' "$*"; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root (sudo)"
[ -r "$DIR/pi.conf" ] || die "pi.conf not found next to $0 - run this through ./deploy.sh pi"
. "$DIR/pi.conf"

TS_SUBNET=100.64.0.0/10            # Tailscale's addresses
NEED_REBOOT=0
CFG=/boot/firmware/config.txt

# ---- network: usb0 as a plain DHCP client with fixed MACs ----------
# rpi-usb-gadget's auto-switcher (rpi-usb-gadget-ics) is what brings
# usb0 up at boot: NetworkManager leaves USB-gadget interfaces alone
# unless something activates them. It must stay ENABLED. On a router it
# picks the "shared" profile (it only recognizes a PC's connection
# sharing), so that profile is turned into a plain DHCP client here;
# as shipped it would be an authoritative DHCP server on the bridged
# LAN. g_ether picks random MACs every boot, and the router's static
# lease needs a fixed one, so they get pinned.
phase_network() {
    hdr "USB network"
    nmcli -t -f NAME connection show | grep -qx 'USB Gadget (shared)' \
        || die "no 'USB Gadget (shared)' profile - is USB gadget mode on? (deploy.sh sdcard)"

    systemctl enable rpi-usb-gadget-ics.service >/dev/null 2>&1 \
        || die "can't enable rpi-usb-gadget-ics.service - it's what brings usb0 up at boot"
    want="yes:auto:link-local"
    have=$(nmcli -g connection.autoconnect,ipv4.method,ipv6.method connection show "USB Gadget (shared)" | paste -sd:)
    if [ "$have" != "$want" ]; then
        nmcli connection modify "USB Gadget (shared)" connection.autoconnect yes \
            ipv4.method auto ipv4.addresses "" ipv6.method link-local
        NEED_REBOOT=1
    fi
    nmcli connection modify "USB Gadget (client)" connection.autoconnect no 2>/dev/null || true
    ok "DHCP client, IPv6 link-local, switcher on (it brings usb0 up at boot)"

    conf=/etc/modprobe.d/usb-gadget.conf
    cur_dev=$(sed -n 's/.*dev_addr=\([^ ]*\).*/\1/p' "$conf" 2>/dev/null || true)
    cur_host=$(sed -n 's/.*host_addr=\([^ ]*\).*/\1/p' "$conf" 2>/dev/null || true)
    dev=${PI_MAC:-${cur_dev:-$(dmesg | awk '/: MAC/ {print $NF}' | tail -n1)}}
    host=${HOST_MAC:-${cur_host:-$(dmesg | awk '/: HOST MAC/ {print $NF}' | tail -n1)}}
    [ -n "$dev" ] && [ -n "$host" ] || die "no g_ether MACs found - reboot and re-run"
    line="options g_ether host_addr=$host dev_addr=$dev"
    if [ "$(cat "$conf" 2>/dev/null)" != "$line" ]; then
        echo "$line" > "$conf"
        NEED_REBOOT=1
    fi
    ok "pinned MACs: PI_MAC=$dev HOST_MAC=$host"
}

# ---- system: update, then strip it down ---------------------------
phase_system() {
    hdr "Packages"
    export DEBIAN_FRONTEND=noninteractive
    apt-get -qq update
    apt-get -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade
    apt-get -qq install unattended-upgrades nftables curl
    apt-get -qq autoremove
    printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' \
        > /etc/apt/apt.conf.d/20auto-upgrades
    [ -e /run/reboot-required ] && NEED_REBOOT=1
    ok "up to date; security updates install themselves"

    hdr "SD card"
    # Logs in RAM only (lost on reboot). Trixie has no rsyslog, so this
    # covers all logging and log2ram isn't needed.
    mkdir -p /etc/systemd/journald.conf.d
    printf '[Journal]\nStorage=volatile\nRuntimeMaxUse=20M\n' > /etc/systemd/journald.conf.d/volatile.conf
    systemctl restart systemd-journald
    if dpkg -s log2ram >/dev/null 2>&1; then
        systemctl stop log2ram || true
        apt-get -qq purge log2ram
    fi
    rm -f /etc/apt/sources.list.d/azlux.list /usr/share/keyrings/azlux-archive-keyring.gpg
    # Swap in compressed RAM only (the default also writes to /var/swap).
    mkdir -p /etc/rpi/swap.conf.d
    if [ "$(cat /etc/rpi/swap.conf.d/50-zram-only.conf 2>/dev/null)" != "$(printf '[Main]\nMechanism=zram')" ]; then
        printf '[Main]\nMechanism=zram\n' > /etc/rpi/swap.conf.d/50-zram-only.conf
        NEED_REBOOT=1
    fi
    systemctl disable --now man-db.timer >/dev/null 2>&1 || true
    findmnt -no OPTIONS / | grep -q noatime || warn "/ is not mounted noatime"
    ok "logs and swap in RAM, no daily man-db rebuild"

    hdr "Unused hardware"
    systemctl disable --now bluetooth.service >/dev/null 2>&1 || true
    # Wi-Fi is the uplink away from home: NetworkManager needs wpa_supplicant.
    systemctl unmask wpa_supplicant.service >/dev/null 2>&1 || true
    systemctl disable --now getty@tty1.service serial-getty@ttyAMA0.service >/dev/null 2>&1 || true
    before=$(md5sum < "$CFG")
    # No display, camera or audio: drop the KMS driver, give the GPU the
    # minimum RAM. Bluetooth and the activity LED off; Wi-Fi stays on.
    sed -i -e 's/^dtoverlay=vc4-kms-v3d/#&/' \
           -e '/^dtoverlay=disable-wifi$/d' \
           -e 's/^dtparam=audio=on$/dtparam=audio=off/' \
           -e 's/^camera_auto_detect=1$/camera_auto_detect=0/' \
           -e 's/^display_auto_detect=1$/display_auto_detect=0/' "$CFG"
    [ -z "$(tail -c1 "$CFG")" ] || echo >> "$CFG"
    [ "$(awk '/^\[/ {s=$0} END {print s}' "$CFG")" = "[all]" ] || echo "[all]" >> "$CFG"
    for l in dtoverlay=disable-bt \
             dtparam=act_led_trigger=none dtparam=act_led_activelow=on; do
        grep -qxF "$l" "$CFG" || echo "$l" >> "$CFG"
    done
    # gpu_mem=16 makes the firmware boot start_cd.elf: only if it's there.
    if [ -f /boot/firmware/start_cd.elf ]; then
        grep -qxF gpu_mem=16 "$CFG" || echo gpu_mem=16 >> "$CFG"
    fi
    [ "$(md5sum < "$CFG")" = "$before" ] || NEED_REBOOT=1
    ok "Bluetooth, LED, display, audio, consoles off"
}

# ---- wifi: the uplink away from home -------------------------------
# At home the Pi is online through usb0 (NetworkManager prefers wired);
# elsewhere it joins any Wi-Fi saved with "wifi add". Saving one works
# out of range too, e.g. from a laptop on the Pi's USB before a trip.
phase_wifi() {
    hdr "Wi-Fi"
    # Country on the kernel command line: it applies at boot, before
    # wlan0 exists (on the first run it only appears after the reboot).
    cmd=/boot/firmware/cmdline.txt
    if ! grep -qw "cfg80211.ieee80211_regdom=$COUNTRY" "$cmd"; then
        sed -i -e 's/ *cfg80211\.ieee80211_regdom=[^ ]*//' -e "1s/\$/ cfg80211.ieee80211_regdom=$COUNTRY/" "$cmd"
        NEED_REBOOT=1
    fi
    rfkill unblock wifi 2>/dev/null || true
    nmcli radio wifi on
    # Power saving makes brcmfmac add up to ~100 ms of latency.
    mkdir -p /etc/NetworkManager/conf.d
    want=$(printf '[connection]\nwifi.powersave = 2')
    if [ "$(cat /etc/NetworkManager/conf.d/wifi-powersave.conf 2>/dev/null)" != "$want" ]; then
        printf '%s\n' "$want" > /etc/NetworkManager/conf.d/wifi-powersave.conf
        nmcli general reload conf >/dev/null 2>&1 || true
    fi
    ok "on, country $COUNTRY, power saving off, $(wifi_saved | wc -l) network(s) saved"
}

wifi_saved() { nmcli -t -f NAME,TYPE connection show | sed -n 's/:802-11-wireless$//p'; }

wifi_add() {
    ssid=$1; pass=${2:-}
    [ -n "$ssid" ] || die "usage: setup.sh wifi add SSID [PASSWORD]"
    nmcli connection delete id "$ssid" >/dev/null 2>&1 || true
    nmcli connection add type wifi ifname wlan0 con-name "$ssid" ssid "$ssid" \
        connection.autoconnect yes >/dev/null
    if [ -n "$pass" ]; then
        nmcli connection modify "$ssid" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$pass"
    fi
    nmcli connection up "$ssid" >/dev/null 2>&1 \
        && ok "$ssid saved and connected" \
        || ok "$ssid saved (not in range now; it joins by itself when it is)"
}

wifi_forget() {
    [ -n "${1:-}" ] || die "usage: setup.sh wifi forget SSID"
    nmcli connection delete id "$1" >/dev/null 2>&1 || die "no saved Wi-Fi $1"
    ok "$1 forgotten"
}

wifi_list() {
    wifi_saved | sed 's/^/  /'
    nmcli -t -f DEVICE,STATE,CONNECTION device | awk -F: '$1 == "wlan0" || $1 == "usb0" {print "  now: " $1 " " $2 " " $3}'
}

# ---- tailscale: exit node + the VPN_LAN_ACCESS hosts ---------------
# Replaces the old DuckDNS + WireGuard server (removed here if present):
# Tailscale needs no port forward and works behind any NAT, so the Pi
# works from wherever it's plugged in.
phase_tailscale() {
    hdr "Old WireGuard server"
    if [ -e /etc/wireguard/wg0.conf ] || [ -e /opt/duckdns ]; then
        systemctl disable --now wg-quick@wg0 duckdns.timer >/dev/null 2>&1 || true
        rm -rf /etc/wireguard /opt/duckdns /etc/systemd/system/duckdns.service /etc/systemd/system/duckdns.timer
        systemctl daemon-reload
        DEBIAN_FRONTEND=noninteractive apt-get -qq purge wireguard wireguard-tools qrencode >/dev/null 2>&1 || true
        rm -f /etc/sysctl.d/99-wireguard-forward.conf
        ok "removed (keys, peers, DuckDNS)"
    else
        ok "none"
    fi

    hdr "Tailscale"
    if ! command -v tailscale >/dev/null; then
        . /etc/os-release
        curl -fsSL "https://pkgs.tailscale.com/stable/debian/$VERSION_CODENAME.noarmor.gpg" \
            -o /usr/share/keyrings/tailscale-archive-keyring.gpg
        curl -fsSL "https://pkgs.tailscale.com/stable/debian/$VERSION_CODENAME.tailscale-keyring.list" \
            -o /etc/apt/sources.list.d/tailscale.list
        apt-get -qq update
        DEBIAN_FRONTEND=noninteractive apt-get -qq install tailscale
    fi
    systemctl enable --now tailscaled >/dev/null 2>&1

    # Exit node and subnet router both need forwarding.
    printf 'net.ipv4.ip_forward=1\nnet.ipv6.conf.all.forwarding=1\n' > /etc/sysctl.d/99-tailscale.conf
    sysctl -q --system

    routes=""
    for e in $VPN_LAN_ACCESS; do
        ip=${e%%:*}
        case " ${routes//,/ } " in *" $ip/32 "*) ;; *) routes="${routes:+$routes,}$ip/32" ;; esac
    done
    flags="--hostname=$PI_NAME --advertise-exit-node --advertise-routes=$routes --accept-dns=false"
    if tailscale status >/dev/null 2>&1; then
        # Logged in: "set" changes just these, without touching the login.
        # shellcheck disable=SC2086
        tailscale set $flags || die "tailscale set failed"
    else
        # First login: with TS_AUTHKEY, or it prints a link to open.
        # shellcheck disable=SC2086
        tailscale up $flags ${TS_AUTHKEY:+--auth-key="$TS_AUTHKEY"} || die "tailscale up failed"
    fi
    tailscale set --auto-update=true >/dev/null 2>&1 || warn "couldn't turn on Tailscale auto-updates"
    ok "$(tailscale ip -4) as $PI_NAME: exit node, routes ${routes:-none}"
    say "         approve both in the admin console (Machines > $PI_NAME > Edit route settings),"
    say "         and turn off its key expiry there"
}

# ---- firewall: nftables, applied with rollback ---------------------
# Its own tables only (no "flush ruleset"): tailscaled keeps its rules
# in tables of its own, and nftables lets a packet through only when
# every table accepts it.
phase_firewall() {
    hdr "Firewall"
    mkdir -p /etc/nftables.d

    lan_rules=""
    for e in $VPN_LAN_ACCESS; do
        ip=${e%%:*}; r=${e#*:}; proto=${r%%:*}; port=${r#*:}
        case "$proto:$port" in
            tcp:[0-9]*|udp:[0-9]*) ;;
            *) die "bad VPN_LAN_ACCESS entry '$e' (want ip:tcp|udp:port)" ;;
        esac
        lan_rules="$lan_rules        iifname \"tailscale0\" oifname \"usb0\" ip daddr $ip $proto dport $port accept
"
    done

    new=$(mktemp)
    cat > "$new" <<EOF
#!/usr/sbin/nft -f
# Generated by pi/setup.sh from bifrost.conf - re-running it overwrites this.
# Rules for other services on the Pi go in /etc/nftables.d/*.nft.

table inet bifrost
delete table inet bifrost
table ip bifrost_nat
delete table ip bifrost_nat

table inet bifrost {
    set private4 {
        type ipv4_addr; flags interval
        elements = { 10.0.0.0/8, 100.64.0.0/10, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16 }
    }

    chain input {
        type filter hook input priority 0; policy drop;

        iifname "lo" accept
        # IPv6 neighbour discovery, ahead of the invalid check (not tracked)
        icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert, nd-router-solicit, nd-router-advert } accept
        ct state established,related accept
        ct state invalid drop

        # usb0 is a cable: the home LAN, or your laptop (SSH, mDNS for <hostname>.local)
        iifname "usb0" accept
        # Tailscale peers -> Pi (SSH from anywhere)
        iifname "tailscale0" ip saddr $TS_SUBNET accept
        # Tailscale direct connections; Wi-Fi gets nothing else
        udp dport 41641 accept
        icmp type echo-request accept
    }

    chain output {
        type filter hook output priority 0; policy accept;

        # Never act as a DHCP server on the LAN
        oifname "usb0" udp sport 67 drop
    }

    chain forward {
        type filter hook forward priority 0; policy drop;

        ct state established,related accept
        ct state invalid drop

        # Tailscale -> the home LAN services in VPN_LAN_ACCESS, nothing else on the LAN
$lan_rules
        # Exit node: Tailscale -> internet, never into whatever network the Pi is on
        iifname "tailscale0" ip saddr $TS_SUBNET ip daddr != @private4 accept
    }
}

table ip bifrost_nat {
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
        ip saddr $TS_SUBNET oifname { "usb0", "wlan0" } masquerade
    }
}

include "/etc/nftables.d/*.nft"
EOF
    nft -c -f "$new" || { rm -f "$new"; die "generated ruleset doesn't parse"; }

    if cmp -s "$new" /etc/nftables.conf && systemctl -q is-active nftables; then
        rm -f "$new"
        ok "rules unchanged"
        return
    fi

    # The WireGuard-era ruleset began with "flush ruleset" and owned
    # "ip nat"; clear it all once, then let tailscaled rebuild its rules.
    migrate=0
    grep -q '^flush ruleset' /etc/nftables.conf 2>/dev/null && migrate=1

    # New rules: load them with a 2-minute safety net, and keep them only
    # if a fresh SSH login still works. The rollback runs from a systemd
    # timer, so it happens even if this session (and script) dies: it
    # puts the previous rules back, or with none, drops ours.
    rm -f /etc/nftables.conf.prev
    [ -f /etc/nftables.conf ] && cp -f /etc/nftables.conf /etc/nftables.conf.prev
    install -m 755 "$new" /etc/nftables.conf
    rm -f "$new"
    systemctl stop nft-rollback.timer nft-rollback.service >/dev/null 2>&1 || true
    systemctl reset-failed nft-rollback.timer nft-rollback.service >/dev/null 2>&1 || true
    systemd-run --quiet --on-active=120 --unit=nft-rollback /bin/sh -c '
        if [ -f /etc/nftables.conf.prev ]; then
            mv -f /etc/nftables.conf.prev /etc/nftables.conf && nft -f /etc/nftables.conf
        else
            mv -f /etc/nftables.conf /etc/nftables.conf.rejected
            nft delete table inet bifrost; nft delete table ip bifrost_nat
        fi
        systemctl restart tailscaled'
    if [ "$migrate" = 1 ]; then
        nft flush ruleset
        nft -f /etc/nftables.conf
        systemctl restart tailscaled
    else
        nft -f /etc/nftables.conf
    fi

    ans=""
    if [ -t 0 ]; then
        echo "  New rules loaded. Within 2 minutes, open a NEW ssh session to the Pi."
        read -r -t 110 -p "  Did it connect? Type yes to keep them: " ans || true
    fi
    if [ "$ans" = yes ]; then
        systemctl stop nft-rollback.timer
        rm -f /etc/nftables.conf.prev
        systemctl enable nftables >/dev/null 2>&1
        ok "rules kept and enabled at boot"
    else
        die "not confirmed - the previous rules come back within 2 minutes"
    fi
}

# ---- main ----------------------------------------------------------
case "${1:-all}" in
    network)  phase_network ;;
    system)   phase_system ;;
    wifi)
        case "${2:-}" in
            "")     phase_wifi ;;
            add)    wifi_add "${3:-}" "${4:-}"; exit 0 ;;
            forget) wifi_forget "${3:-}"; exit 0 ;;
            list)   wifi_list; exit 0 ;;
            *)      die "usage: setup.sh wifi [add SSID [PASSWORD] | forget SSID | list]" ;;
        esac
        ;;
    tailscale) phase_tailscale ;;
    firewall) phase_firewall ;;
    poweroff) hdr "Shutting down - wait for the activity to stop, then unplug"; systemctl poweroff; exit 0 ;;
    all)
        phase_network
        phase_system
        phase_wifi
        phase_tailscale
        phase_firewall
        ;;
    *) die "usage: setup.sh [network|system|wifi|tailscale|firewall|all|poweroff] | wifi add|forget|list ..." ;;
esac

if [ "$NEED_REBOOT" = 1 ]; then
    if [ "${1:-all}" = network ]; then
        hdr "Done - changes apply at the next boot (when the Pi moves to the router)"
    else
        hdr "Done - rebooting in 5 s to apply changes"
        sleep 5
        systemctl reboot
    fi
else
    hdr "Done"
fi
