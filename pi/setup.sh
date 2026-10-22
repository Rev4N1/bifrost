#!/bin/bash
# ========================================================
# pi/setup.sh - Raspberry Pi Zero 2 W as a portable
# Tailscale exit node and subnet router for whatever LAN
# it's on: the main router's USB at home, any Wi-Fi
# elsewhere. Runs as root on the Pi; deploy.sh copies it
# over with pi.conf (its part of bifrost.conf), runs it,
# and deletes both.
#
#   setup.sh network            usb0 as plain DHCP client + pinned MACs
#                               (first, while on the PC's USB)
#   setup.sh                    everything, network included (on the router)
#   setup.sh system|wifi|tailscale    one step
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
    apt-get -qq install unattended-upgrades curl
    apt-get -qq autoremove
    printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' \
        > /etc/apt/apt.conf.d/20auto-upgrades
    [ -e /run/reboot-required ] && NEED_REBOOT=1
    ok "up to date; security updates install themselves"

    hdr "SD card"
    # Logs in RAM only (lost on reboot). Trixie has no rsyslog, so this
    # covers all logging.
    mkdir -p /etc/systemd/journald.conf.d
    printf '[Journal]\nStorage=volatile\nRuntimeMaxUse=20M\n' > /etc/systemd/journald.conf.d/volatile.conf
    systemctl restart systemd-journald
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
    systemctl disable --now getty@tty1.service serial-getty@ttyAMA0.service >/dev/null 2>&1 || true
    before=$(md5sum < "$CFG")
    # No display, camera or audio: drop the KMS driver, give the GPU the
    # minimum RAM. Bluetooth and the activity LED off; Wi-Fi stays on.
    sed -i -e 's/^dtoverlay=vc4-kms-v3d/#&/' \
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
# At home the Pi is online through usb0 (NetworkManager prefers wired).
# Elsewhere it joins a Wi-Fi saved with nmcli (pi/README.md).
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
    ok "on, country $COUNTRY, power saving off"
}

# ---- tailscale: exit node + whatever LAN the Pi is on --------------
# Tailscale needs no port forward and works behind any NAT, so the Pi
# works from wherever it's plugged in. A NetworkManager hook advertises
# the networks it's on right now (the home LAN through usb0, a hotel
# Wi-Fi...), so Tailscale clients reach the whole LAN, wherever it is.
phase_tailscale() {
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

    flags="--hostname=$PI_NAME --advertise-exit-node --accept-dns=false"
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

    hook=/etc/NetworkManager/dispatcher.d/90-tailscale-routes
    cat > "$hook" <<'EOF'
#!/bin/sh
# Written by pi/setup.sh. Advertises the networks the Pi is on right
# now (usb0, wlan0) as Tailscale subnet routes.
case "$2" in up|down|dhcp4-change) ;; *) exit 0 ;; esac
routes=$(ip -4 route show proto kernel scope link \
    | awk '$2 == "dev" && ($3 == "usb0" || $3 == "wlan0") {print $1}' | sort -u | paste -sd, -)
# The exit node flag again, or "set" would drop it along with the old routes.
tailscale set --advertise-exit-node --advertise-routes="$routes"
EOF
    chmod 755 "$hook"
    "$hook" usb0 up || warn "couldn't advertise the current networks yet - they follow on the next network change"
    ok "$(tailscale ip -4) as $PI_NAME: exit node + $(ip -4 route show proto kernel scope link | awk '$3 == "usb0" || $3 == "wlan0" {printf "%s ", $1}')"
}

# ---- main ----------------------------------------------------------
case "${1:-all}" in
    network)   phase_network ;;
    system)    phase_system ;;
    wifi)      phase_wifi ;;
    tailscale) phase_tailscale ;;
    poweroff)  hdr "Shutting down - wait for the activity to stop, then unplug"; systemctl poweroff; exit 0 ;;
    all)
        phase_network
        phase_system
        phase_wifi
        phase_tailscale
        ;;
    *) die "usage: setup.sh [network|system|wifi|tailscale|all|poweroff]" ;;
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
