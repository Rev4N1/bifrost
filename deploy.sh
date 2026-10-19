#!/usr/bin/env bash
# ========================================================
# deploy.sh - the one command you run on the PC.
# Linux (bash). On Windows it runs in Git Bash, except
# "sdcard" (see pi/README.md).
#
#   ./deploy.sh routers               main router, every AP, then the addons
#   ./deploy.sh main                  main router only
#   ./deploy.sh ap <hostname> [--fresh]   one dumb AP (--fresh: still at factory 192.168.1.1)
#   ./deploy.sh wifi-watch            Telegram addon
#   ./deploy.sh pi-gateway [user@pi]  router side of the Pi (with user@pi: records its MACs first)
#
#   ./deploy.sh sdcard                turn on USB gadget mode on a freshly flashed Pi card
#   ./deploy.sh pi user@host [step]   run pi/setup.sh on the Pi (network|system|...|all)
#   ./deploy.sh pi user@host client add NAME [IP] | revoke NAME | list
#
# Every target is safe to re-run.
# ========================================================
set -euo pipefail
cd "$(dirname "$0")"

NET=router/setup/network.conf
GATEWAY_CONF=router/addon-pi-gateway/pi-gateway.conf
WATCH_CONF=router/addon-wifi-watch/wifi-watch.conf
PI_CONF=pi/pi.conf
FACTORY_IP=192.168.1.1

say() { printf '\n>>> %s\n' "$*"; }
die() { printf 'deploy: %s\n' "$*" >&2; exit 1; }

# Routers get a new host key on every flash, so their key isn't pinned
# (LAN only). On Linux, one SSH connection per host is reused for a
# minute, so each password is typed once.
SSH_COMMON=(-o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3)
if [ "$(uname -s)" = Linux ]; then
    mkdir -p ~/.ssh
    SSH_COMMON+=(-o ControlMaster=auto -o "ControlPath=$HOME/.ssh/bifrost-%r@%h:%p" -o ControlPersist=60)
fi
SSH_ROUTER=("${SSH_COMMON[@]}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
SSH_PI=("${SSH_COMMON[@]}" -o StrictHostKeyChecking=accept-new)

need_conf() {
    [ -f "$1" ] || die "$1 is missing: cp $1.example $1, then fill it in"
    ! grep -q '"CHANGE_ME"' "$1" || die "$1 still has CHANGE_ME values"
}
load_net() { need_conf "$NET"; set +u; . "$NET"; set -u; }

port_open() { timeout 3 bash -c "</dev/tcp/$1/22" 2>/dev/null; }

# wait_reboot <ip it had> <ip it comes back on>
wait_reboot() {
    say "waiting for $2 to come back"
    for _ in $(seq 45); do port_open "$1" || break; sleep 2; done
    for _ in $(seq 150); do
        if port_open "$2"; then sleep 5; echo "    $2 is up"; return; fi
        sleep 2
    done
    die "$2 didn't come back within 5 minutes"
}

# router_run <ip> <local dir> <remote command>: copy dir to /tmp, run.
router_run() {
    scp -O -q -r "${SSH_ROUTER[@]}" "$2" "root@$1:/tmp/"
    ssh -t "${SSH_ROUTER[@]}" "root@$1" "$3"
}

ap_ip() {
    local e
    for e in $APS; do
        [ "${e%%,*}" = "$1" ] && { e=${e#*,}; echo "${e%%,*}"; return; }
    done
    die "no AP named '$1' in APS (have: $(for e in $APS; do printf '%s ' "${e%%,*}"; done))"
}

cmd_main() {
    load_net
    say "main router $GW_IP"
    router_run "$GW_IP" router/setup "sh /tmp/setup/main-router.sh" || true   # it reboots
    wait_reboot "$GW_IP" "$GW_IP"
}

cmd_ap() {
    load_net
    local name=${1:-} ip target
    [ -n "$name" ] || die "usage: deploy.sh ap <hostname> [--fresh]"
    ip=$(ap_ip "$name"); target=$ip
    if [ "${2:-}" = --fresh ]; then
        target=$FACTORY_IP
        say "$name is factory-fresh: only your PC should be plugged into it."
        echo "    It moves to $ip mid-run (the session freezes, that's fine). When it"
        echo "    says it's waiting for internet, plug it into the main LAN."
    fi
    say "dumb AP $name ($ip)"
    router_run "$target" router/setup "sh /tmp/setup/dumb-ap.sh $name" || true   # it reboots
    wait_reboot "$target" "$ip"
}

cmd_wifi_watch() {
    load_net; need_conf "$WATCH_CONF"
    say "wifi-watch addon on $GW_IP"
    router_run "$GW_IP" router/addon-wifi-watch "sh /tmp/addon-wifi-watch/install.sh"
}

# Record the Pi's pinned MACs in pi-gateway.conf (and pi.conf, so a
# reflashed Pi can be given the same ones).
record_pi_macs() {
    local pinned pi_mac host_mac f
    pinned=$(ssh "${SSH_PI[@]}" "$1" cat /etc/modprobe.d/usb-gadget.conf)
    pi_mac=$(sed -n 's/.*dev_addr=\([^ ]*\).*/\1/p' <<<"$pinned")
    host_mac=$(sed -n 's/.*host_addr=\([^ ]*\).*/\1/p' <<<"$pinned")
    [ -n "$pi_mac" ] && [ -n "$host_mac" ] || die "no pinned MACs on the Pi - run: deploy.sh pi $1 network"
    [ -f "$GATEWAY_CONF" ] || cp "$GATEWAY_CONF.example" "$GATEWAY_CONF"
    [ -f "$PI_CONF" ] || cp "$PI_CONF.example" "$PI_CONF"
    for f in "$GATEWAY_CONF" "$PI_CONF"; do
        sed -i -e "s/^PI_MAC=\"[^\"]*\"/PI_MAC=\"$pi_mac\"/" \
               -e "s/^HOST_MAC=\"[^\"]*\"/HOST_MAC=\"$host_mac\"/" "$f"
    done
    echo "    PI_MAC=$pi_mac HOST_MAC=$host_mac recorded"
}

cmd_pi_gateway() {
    load_net
    [ -n "${1:-}" ] && { say "reading the Pi's MACs"; record_pi_macs "$1"; }
    need_conf "$GATEWAY_CONF"
    say "pi-gateway addon on $GW_IP"
    router_run "$GW_IP" router/addon-pi-gateway "sh /tmp/addon-pi-gateway/install.sh"
}

cmd_routers() {
    load_net
    local e
    cmd_main
    for e in $APS; do cmd_ap "${e%%,*}"; done
    if [ -f "$WATCH_CONF" ]; then cmd_wifi_watch; else echo "(no $WATCH_CONF - skipping wifi-watch)"; fi
    if [ -f "$GATEWAY_CONF" ]; then cmd_pi_gateway; else echo "(no $GATEWAY_CONF - skipping pi-gateway)"; fi
    say "all routers done"
}

# Add enable_usb_gadget: true under rpi: in the card's cloud-init
# user-data (YAML: one rpi: key, consistent indentation).
cmd_sdcard() {
    command -v findmnt >/dev/null || die "sdcard needs Linux; on Windows edit user-data by hand (pi/README.md)"
    local boot f
    boot=$(findmnt -nro TARGET --source LABEL=bootfs | head -n1)
    [ -n "$boot" ] || die "bootfs isn't mounted - open the SD card in your file manager first"
    f="$boot/user-data"
    [ -f "$f" ] || die "$f not found - flash the card with Raspberry Pi Imager first"
    sed -i 's/\r$//' "$f"
    if ! grep -q 'enable_usb_gadget' "$f"; then
        if grep -q '^rpi:' "$f"; then
            awk '
                add { ind = match($0, /^[ \t]+[^ \t]/) ? substr($0, 1, RLENGTH - 1) : "  "
                      print ind "enable_usb_gadget: true"; add = 0 }
                { print }
                /^rpi:[ \t]*$/ { add = 1 }
                END { if (add) print "  enable_usb_gadget: true" }
            ' "$f" > "$f.new" && mv "$f.new" "$f"
        else
            [ -z "$(tail -c1 "$f")" ] || echo >> "$f"
            printf 'rpi:\n  enable_usb_gadget: true\n' >> "$f"
        fi
    fi
    sync
    grep -A3 '^rpi:' "$f"
    say "USB gadget mode on. Eject the card and boot the Pi from it."
}

# Run pi/setup.sh on the Pi. Script and pi.conf travel inside the SSH
# command (one connection: one password, plus sudo) and are deleted after.
cmd_pi() {
    local target=${1:-}; shift || true
    [ -n "$target" ] || die "usage: deploy.sh pi user@host [step | client ...]"
    [ -f "$PI_CONF" ] || die "$PI_CONF is missing: cp $PI_CONF.example $PI_CONF, then fill it in"
    local s c args
    s=$(base64 -w0 pi/setup.sh); c=$(base64 -w0 "$PI_CONF")
    args=$(printf '%q ' "$@")
    say "pi/setup.sh ${*:-all} on $target"
    ssh -t "${SSH_PI[@]}" "$target" "
        d=\$(mktemp -d) && chmod 700 \"\$d\" &&
        echo $s | base64 -d > \"\$d/setup.sh\" && echo $c | base64 -d > \"\$d/pi.conf\" &&
        sudo bash \"\$d/setup.sh\" $args; rc=\$?; rm -rf \"\$d\"; exit \$rc" || true

    if [ "${1:-}" = client ] && [ "${2:-}" = add ] && [ -n "${3:-}" ]; then
        local name=$3
        scp -q "${SSH_PI[@]}" "$target:wg-$name.conf" ~/ \
            && ssh "${SSH_PI[@]}" "$target" "rm -f wg-$name.conf" \
            && say "client config saved to ~/wg-$name.conf (has the private key)" \
            && echo "    Fedora: sudo nmcli connection import type wireguard file ~/wg-$name.conf" \
            && echo "    Other:  import it in the WireGuard app, then delete the file"
    fi
}

case "${1:-}" in
    routers)    cmd_routers ;;
    main)       cmd_main ;;
    ap)         shift; cmd_ap "$@" ;;
    wifi-watch) cmd_wifi_watch ;;
    pi-gateway) shift; cmd_pi_gateway "$@" ;;
    sdcard)     cmd_sdcard ;;
    pi)         shift; cmd_pi "$@" ;;
    *)          sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
