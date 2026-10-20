#!/bin/bash
# ========================================================
# pi/setup.sh - Raspberry Pi Zero 2 W as a USB-gadget
# WireGuard gateway. Runs as root on the Pi; deploy.sh
# copies it over with pi.conf (its part of bifrost.conf),
# runs it, and deletes both.
#
#   setup.sh network            usb0 as plain DHCP client + pinned MACs
#                               (first, while on the PC's USB)
#   setup.sh                    everything, network included (on the router)
#   setup.sh system|duckdns|wireguard|firewall    one step
#   setup.sh client add NAME [IP] | revoke NAME | list
#
# Every step converges: re-running it changes only what
# differs, and keeps keys, peers and pinned MACs.
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

VPN_BASE=${VPN_SUBNET%.*}          # 10.7.0.0/24 -> 10.7.0
VPN_PREFIX=${VPN_SUBNET#*/}
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
    apt-get -qq install unattended-upgrades nftables wireguard qrencode curl
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
    systemctl mask --now wpa_supplicant.service >/dev/null 2>&1 || true
    systemctl disable --now getty@tty1.service serial-getty@ttyAMA0.service >/dev/null 2>&1 || true
    before=$(md5sum < "$CFG")
    # No display, camera or audio: drop the KMS driver, give the GPU the
    # minimum RAM. Bluetooth, Wi-Fi and the activity LED off.
    sed -i -e 's/^dtoverlay=vc4-kms-v3d/#&/' \
           -e 's/^dtparam=audio=on$/dtparam=audio=off/' \
           -e 's/^camera_auto_detect=1$/camera_auto_detect=0/' \
           -e 's/^display_auto_detect=1$/display_auto_detect=0/' "$CFG"
    [ -z "$(tail -c1 "$CFG")" ] || echo >> "$CFG"
    [ "$(awk '/^\[/ {s=$0} END {print s}' "$CFG")" = "[all]" ] || echo "[all]" >> "$CFG"
    for l in dtoverlay=disable-bt dtoverlay=disable-wifi \
             dtparam=act_led_trigger=none dtparam=act_led_activelow=on; do
        grep -qxF "$l" "$CFG" || echo "$l" >> "$CFG"
    done
    # gpu_mem=16 makes the firmware boot start_cd.elf: only if it's there.
    if [ -f /boot/firmware/start_cd.elf ]; then
        grep -qxF gpu_mem=16 "$CFG" || echo gpu_mem=16 >> "$CFG"
    fi
    [ "$(md5sum < "$CFG")" = "$before" ] || NEED_REBOOT=1
    ok "Bluetooth, Wi-Fi, LED, display, audio, consoles off"
}

# ---- duckdns: keep <subdomain>.duckdns.org pointing home -----------
phase_duckdns() {
    hdr "DuckDNS"
    env=/opt/duckdns/duckdns.env
    mkdir -p /opt/duckdns
    cur_d=""; cur_t=""
    [ -f "$env" ] && { cur_d=$(. "$env"; echo "${DUCKDNS_DOMAIN:-}"); cur_t=$(. "$env"; echo "${DUCKDNS_TOKEN:-}"); }
    d=$DUCKDNS_DOMAIN; [ "$d" = CHANGE_ME ] && d=""
    d=${d:-$cur_d}; t=${DUCKDNS_TOKEN:-$cur_t}
    [ -n "$d" ] && [ -n "$t" ] || die "set DUCKDNS_DOMAIN and DUCKDNS_TOKEN in bifrost.conf"
    ( umask 077; printf 'DUCKDNS_DOMAIN=%s\nDUCKDNS_TOKEN=%s\n' "$d" "$t" > "$env" )

    cat > /opt/duckdns/duck.sh <<'EOF'
#!/bin/sh
set -eu
. /opt/duckdns/duckdns.env
resp=$(curl -fsS "https://www.duckdns.org/update?domains=${DUCKDNS_DOMAIN}&token=${DUCKDNS_TOKEN}&ip=")
echo "duckdns: $resp"
[ "$resp" = "OK" ]
EOF
    chmod 750 /opt/duckdns/duck.sh
    cat > /etc/systemd/system/duckdns.service <<'EOF'
[Unit]
Description=DuckDNS IP update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/duckdns/duck.sh
EOF
    cat > /etc/systemd/system/duckdns.timer <<'EOF'
[Unit]
Description=Run DuckDNS update every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now duckdns.timer >/dev/null 2>&1
    if systemctl start duckdns.service; then
        ok "$d.duckdns.org updated"
    else
        warn "update failed: journalctl -u duckdns.service"
    fi
}

# ---- wireguard: server (never regenerated once it exists) ----------
phase_wireguard() {
    hdr "WireGuard"
    mkdir -p /etc/wireguard/clients
    chmod 700 /etc/wireguard /etc/wireguard/clients
    if [ -e /etc/wireguard/wg0.conf ]; then
        ok "server exists - keys and peers left untouched"
    else
        ( umask 077; cd /etc/wireguard
          wg genkey | tee server.key | wg pubkey > server.pub
          cat > wg0.conf <<EOF
[Interface]
Address = $VPN_BASE.1/$VPN_PREFIX
ListenPort = $WG_PORT
PrivateKey = $(cat server.key)
# nftables (setup.sh firewall) handles forwarding and NAT.
EOF
        )
        ok "server created"
    fi
    systemctl enable --now wg-quick@wg0 >/dev/null 2>&1
    ok "wg0 up, $(wg show wg0 peers | wc -l) peer(s)"
}

# ---- firewall: nftables + forwarding, applied with rollback --------
phase_firewall() {
    hdr "Firewall"
    printf 'net.ipv4.ip_forward=1\n' > /etc/sysctl.d/99-wireguard-forward.conf
    sysctl -q --system
    mkdir -p /etc/nftables.d

    lan_rules=""
    for e in $VPN_LAN_ACCESS; do
        ip=${e%%:*}; r=${e#*:}; proto=${r%%:*}; port=${r#*:}
        case "$proto:$port" in
            tcp:[0-9]*|udp:[0-9]*) ;;
            *) die "bad VPN_LAN_ACCESS entry '$e' (want ip:tcp|udp:port)" ;;
        esac
        lan_rules="$lan_rules        iifname \"wg0\" ip saddr $VPN_SUBNET ip daddr $ip $proto dport $port accept
"
    done

    new=$(mktemp)
    cat > "$new" <<EOF
#!/usr/sbin/nft -f
# Generated by pi/setup.sh from bifrost.conf - re-running it overwrites this.
# Rules for other services on the Pi go in /etc/nftables.d/*.nft.

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;

        iifname "lo" accept
        # IPv6 neighbour discovery, ahead of the invalid check (not tracked)
        icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert, nd-router-solicit, nd-router-advert } accept
        ct state established,related accept
        ct state invalid drop

        # LAN -> Pi (SSH, management)
        iifname "usb0" ip saddr $LAN_SUBNET ip daddr $PI_IP accept
        # USB-to-PC recovery: SSH over IPv6 link-local, mDNS for <hostname>.local
        iifname "usb0" ip6 saddr fe80::/10 tcp dport 22 accept
        iifname "usb0" udp dport 5353 accept
        # WireGuard handshakes
        iifname "usb0" udp dport $WG_PORT accept
        # VPN peers -> Pi itself
        iifname "wg0" ip saddr $VPN_SUBNET accept
    }

    chain output {
        type filter hook output priority 0; policy drop;

        # Never act as a DHCP server on the LAN
        oifname "usb0" udp sport 67 drop

        oifname "lo" accept
        ct state established,related accept
        oifname "usb0" accept
        oifname "wg0" ip daddr $VPN_SUBNET accept
    }

    chain forward {
        type filter hook forward priority 0; policy drop;

        ct state established,related accept
        ct state invalid drop

        # VPN -> the LAN services in VPN_LAN_ACCESS, nothing else on the LAN
$lan_rules
        # VPN -> internet
        iifname "wg0" ip saddr $VPN_SUBNET ip daddr != $LAN_SUBNET oifname "usb0" accept
    }
}

table ip nat {
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
        ip saddr $VPN_SUBNET oifname "usb0" masquerade
    }
}

include "/etc/nftables.d/*.nft"
EOF
    nft -c -f "$new" || { rm -f "$new"; die "generated ruleset doesn't parse"; }

    if cmp -s "$new" /etc/nftables.conf && systemctl -q is-active nftables; then
        rm -f "$new"
        ok "rules unchanged and active"
        return
    fi

    # New rules: load them with a 2-minute safety net, and keep them only
    # if a fresh SSH login still works. The rollback runs from a systemd
    # timer, so it happens even if this session (and script) dies: it
    # puts the previous rules back, or with none, opens the firewall.
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
            mv -f /etc/nftables.conf /etc/nftables.conf.rejected; nft flush ruleset
        fi'
    nft -f /etc/nftables.conf

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

# ---- clients -------------------------------------------------------
client_add() {
    name=$1; ip=${2:-}
    [ -n "$name" ] || die "usage: setup.sh client add NAME [IP]"
    cd /etc/wireguard
    grep -qx "# $name" wg0.conf && die "client $name already exists"
    if [ -z "$ip" ]; then
        last=$(sed -n "s/^AllowedIPs = $VPN_BASE\.\([0-9]*\)\/32$/\1/p" wg0.conf | sort -n | tail -n1)
        ip=$VPN_BASE.$(( ${last:-1} + 1 ))
    fi
    grep -q "AllowedIPs = $ip/32" wg0.conf && die "$ip already used"
    . /opt/duckdns/duckdns.env 2>/dev/null || die "no DuckDNS config - run setup.sh duckdns first"

    umask 077
    wg genkey | tee "clients/$name.key" | wg pubkey > "clients/$name.pub"
    wg genpsk > "clients/$name.psk"
    cat >> wg0.conf <<EOF

[Peer]
# $name
PublicKey = $(cat "clients/$name.pub")
PresharedKey = $(cat "clients/$name.psk")
AllowedIPs = $ip/32
EOF
    cat > "clients/$name.conf" <<EOF
[Interface]
PrivateKey = $(cat "clients/$name.key")
Address = $ip/32
DNS = $CLIENT_DNS

[Peer]
PublicKey = $(cat server.pub)
PresharedKey = $(cat "clients/$name.psk")
Endpoint = $DUCKDNS_DOMAIN.duckdns.org:$WG_PORT
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
    wg syncconf wg0 <(wg-quick strip wg0)
    qrencode -t ansiutf8 < "clients/$name.conf"
    # A copy the calling user can fetch (deploy.sh does, then deletes it).
    if [ -n "${SUDO_USER:-}" ]; then
        install -m 600 -o "$SUDO_USER" "clients/$name.conf" "$(getent passwd "$SUDO_USER" | cut -d: -f6)/wg-$name.conf"
    fi
    # The Pi doesn't need the client's private key.
    rm -f "clients/$name.key" "clients/$name.conf"
    ok "client $name -> $ip (scan the QR above, or import wg-$name.conf)"
}

client_revoke() {
    name=$1
    [ -n "$name" ] || die "usage: setup.sh client revoke NAME"
    cd /etc/wireguard
    grep -qx "# $name" wg0.conf || die "no client $name"
    awk -v n="# $name" '
        /^\[Peer\]/ { if (blk != "" && !drop) printf "%s", blk; blk = $0 "\n"; drop = 0; inpeer = 1; next }
        inpeer      { blk = blk $0 "\n"; if ($0 == n) drop = 1; next }
                    { print }
        END         { if (blk != "" && !drop) printf "%s", blk }
    ' wg0.conf > wg0.conf.new
    mv wg0.conf.new wg0.conf && chmod 600 wg0.conf
    rm -f clients/"$name".*
    wg syncconf wg0 <(wg-quick strip wg0)
    ok "client $name revoked"
}

client_list() {
    awk '/^# / {n=substr($0,3)} /^AllowedIPs/ {print "  " n "\t" $3}' /etc/wireguard/wg0.conf
}

# ---- main ----------------------------------------------------------
case "${1:-all}" in
    network)  phase_network ;;
    system)   phase_system ;;
    duckdns)  phase_duckdns ;;
    wireguard) phase_wireguard ;;
    firewall) phase_firewall ;;
    all)
        phase_network
        phase_system
        phase_duckdns
        phase_wireguard
        phase_firewall
        ;;
    client)
        case "${2:-}" in
            add)    client_add "${3:-}" "${4:-}" ;;
            revoke) client_revoke "${3:-}" ;;
            list)   client_list ;;
            *)      die "usage: setup.sh client add NAME [IP] | revoke NAME | list" ;;
        esac
        exit 0
        ;;
    *) die "usage: setup.sh [network|system|duckdns|wireguard|firewall|all] | client ..." ;;
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
