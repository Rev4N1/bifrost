#!/bin/ash
# ========================================================
# Shared provisioning steps, sourced by main-router.sh
# and dumb-ap.sh. Every step is safe to re-run: it
# sets values rather than appending them, so running a
# setup script on an already-provisioned router (e.g. after
# every firmware flash) converges to the same config.
# ========================================================

SETUP_DIR=$(cd "$(dirname "$0")" && pwd)

# A dumb AP changes its own IP mid-run, which kills the SSH
# session we were started from. Don't let that kill us too:
# HUP is the session hangup, PIPE is the next write to its
# closed stdout/stderr.
trap '' HUP PIPE
# Nothing here reads the terminal; a gone session must not
# block a read either.
exec </dev/null
# This folder holds network.conf, with ROOT_PASSWORD and the
# PPPoE login: delete the copy in /tmp once the run is over.
case "$SETUP_DIR" in /tmp/*) trap 'rm -rf "$SETUP_DIR"' EXIT ;; esac

say()  { printf '%s\n' "$*"; }
ok()   { printf '  [ ok ] %s\n' "$*"; }
warn() { printf '  [warn] %s\n' "$*"; }
hdr()  { printf '\n== %s\n' "$*"; }
die()  { printf '  [FAIL] %s\n' "$*"; exit 1; }

# network.conf is written by deploy.sh from bifrost.conf on the PC.
[ -f "$SETUP_DIR/network.conf" ] || die "network.conf not found next to $0 - run this through ./deploy.sh"
. "$SETUP_DIR/network.conf"
grep -qE "=[\"']CHANGE_ME[\"']" "$SETUP_DIR/network.conf" && die "network.conf still has CHANGE_ME values (fix bifrost.conf)"

[ -f /etc/openwrt_release ] || die "this does not look like OpenWrt"

# What uci looked like before this run. finish() reboots only when it
# differs, so re-running a setup script does not drop Wi-Fi for nothing.
_BEFORE=$(uci export 2>/dev/null | md5sum)

# ---- system --------------------------------------------------------

# setup_system <hostname>
setup_system() {
    hdr "System"
    uci set system.@system[0].hostname="$1"
    uci set system.@system[0].zonename="$ZONENAME"
    uci set system.@system[0].timezone="$TIMEZONE"
    # Keep the router's own clock on the configured server, not only the
    # one-shot sync below. The default OpenWrt pool works, but a single
    # NTP_SERVER in bifrost.conf should actually be used.
    if uci -q get system.ntp >/dev/null; then
        uci -q delete system.ntp.server
        uci add_list system.ntp.server="$NTP_SERVER"
        uci set system.ntp.enabled='1'
        uci set system.ntp.enable_server='0'
    fi
    uci commit system
    ( echo "$ROOT_PASSWORD"; sleep 1; echo "$ROOT_PASSWORD" ) | passwd root >/dev/null 2>&1 \
        && ok "hostname $1, root password set" \
        || warn "could not set root password"
}

# ---- connectivity --------------------------------------------------

# Wait until the package repo resolves. A freshly flashed dumb AP has no
# uplink until it is plugged into the main LAN, so give the user time.
wait_for_internet() {
    hdr "Internet"
    _i=0
    while [ "$_i" -lt 120 ]; do
        if nslookup downloads.openwrt.org >/dev/null 2>&1; then
            ok "reachable"
            return 0
        fi
        [ "$_i" -eq 0 ] && say "  waiting up to 120s (plug this router into the main LAN if it isn't)"
        sleep 5
        _i=$((_i + 5))
    done
    warn "no internet - skipping package and NTP steps; re-run this script once connected"
    return 1
}

# busybox `ntpd -q` never exits if no server answers, so bound it.
sync_time() {
    ntpd -n -q -p "$NTP_SERVER" >/dev/null 2>&1 &
    _pid=$!
    _i=0
    while kill -0 "$_pid" 2>/dev/null && [ "$_i" -lt 20 ]; do
        sleep 1
        _i=$((_i + 1))
    done
    if kill -0 "$_pid" 2>/dev/null; then
        kill "$_pid" 2>/dev/null
        wait "$_pid" 2>/dev/null
        warn "NTP sync timed out"
    elif wait "$_pid"; then
        ok "clock synced: $(date)"
    else
        warn "NTP sync failed"
    fi
}

# usteer: band/AP steering daemon. Every AP runs it; they find each
# other by broadcast on the LAN and nudge clients (via 802.11k/v) off a
# weak AP onto a better one. Complements 802.11r, which only makes the
# hop itself fast.
install_usteer() {
    hdr "usteer"
    if apk list --installed 2>/dev/null | grep -q '^usteer-[0-9]'; then
        # Installed by an earlier run, but that run may have stopped before
        # enabling it, or a reboot may have left it off. Converge.
        /etc/init.d/usteer enable >/dev/null 2>&1
        /etc/init.d/usteer running >/dev/null 2>&1 \
            || /etc/init.d/usteer start >/dev/null 2>&1
        ok "usteer already installed"
        return
    fi
    # A fresh router has no package index yet.
    apk update >/dev/null 2>&1
    apk add usteer >/dev/null 2>&1 || { warn "usteer install failed"; return; }
    /etc/init.d/usteer enable >/dev/null 2>&1
    # Start it now: nothing else in this run will (the config may be
    # unchanged, in which case finish() does not reboot).
    /etc/init.d/usteer restart >/dev/null 2>&1 || true
    ok "usteer installed and enabled"
}

# ---- bridge --------------------------------------------------------

# uci section of the br-lan device, e.g. "@device[0]"
br_lan_section() {
    uci show network | sed -n "s/^network\.\([^.]*\)\.name='br-lan'$/\1/p" | head -n1
}

# br_add_port <port> - add to br-lan unless already there. The port
# doesn't need to exist yet: netifd adds it whenever it appears.
br_add_port() {
    _sec=$(br_lan_section)
    [ -n "$_sec" ] && [ -n "$1" ] || return 1
    if uci -q get "network.$_sec.ports" | grep -qw "$1"; then
        ok "$1 already in br-lan"
    else
        uci add_list "network.$_sec.ports=$1"
        ok "$1 added to br-lan"
    fi
}

# IPv4 only on the LAN. ipv6 is a device option (it turns IPv6 off in
# the kernel for br-lan); on a static interface it would do nothing.
br_no_ipv6() {
    _sec=$(br_lan_section)
    [ -n "$_sec" ] || die "no br-lan device found"
    uci set "network.$_sec.ipv6=0"
}

# Spread packet processing across all CPU cores.
setup_packet_steering() {
    uci set network.globals.packet_steering='1'
    uci commit network
}

# ---- wireless ------------------------------------------------------

# setup_wireless <hostname> <ch24> <bw24> <ch5> <bw5>
# Radios are matched by band, not by name, so radio0/radio1 ordering
# differences between models don't matter.
setup_wireless() {
    hdr "Wireless"
    _host="$1"
    for R in radio0 radio1 radio2; do
        uci -q get "wireless.$R" >/dev/null || continue
        case "$(uci -q get "wireless.$R.band")" in
            2g) _ch="$2"; _bw="$3"; _sfx=24; _txp="$TXPOWER_24" ;;
            5g) _ch="$4"; _bw="$5"; _sfx=5;  _txp="" ;;
            *)  warn "$R: not 2.4 or 5 GHz, left untouched"; continue ;;
        esac

        uci set "wireless.$R.disabled=0"
        uci set "wireless.$R.htmode=HE$_bw"
        uci set "wireless.$R.channel=$_ch"
        uci set "wireless.$R.country=$COUNTRY"
        if [ -n "$_txp" ]; then
            uci set "wireless.$R.txpower=$_txp"
        else
            uci -q delete "wireless.$R.txpower"     # regulatory max
        fi

        _if="default_$R"
        uci -q delete "wireless.$_if"
        uci set "wireless.$_if=wifi-iface"
        uci set "wireless.$_if.device=$R"
        uci set "wireless.$_if.mode=ap"
        uci set "wireless.$_if.network=lan"
        uci set "wireless.$_if.ssid=$SSID"
        uci set "wireless.$_if.encryption=psk2"
        uci set "wireless.$_if.key=$WPA_PSK"

        # 802.11r fast roaming. Over-the-air FT (ft_over_ds=0) is the
        # OpenWrt default and works with more clients than over-DS.
        uci set "wireless.$_if.ieee80211r=1"
        uci set "wireless.$_if.nasid=$_host-$_sfx"
        uci set "wireless.$_if.mobility_domain=$MOBILITY_DOMAIN"
        uci set "wireless.$_if.ft_over_ds=0"
        uci set "wireless.$_if.ft_psk_generate_local=1"

        # 802.11k/v: neighbour reports and BSS transition, so clients
        # roam to the nearest AP instead of clinging to a far one. They
        # need the full wpad-mbedtls, which 25.12 ships by default.
        uci set "wireless.$_if.ieee80211k=1"
        uci set "wireless.$_if.bss_transition=1"

        # 802.11w protected management frames, optional so older
        # clients without PMF still join. Stops spoofed deauths.
        uci set "wireless.$_if.ieee80211w=1"

        ok "$R ($_sfx GHz): ch $_ch, HE$_bw, txpower ${_txp:-max}"
    done
    uci commit wireless
}

finish() {
    hdr "Done"
    _after=$(uci export 2>/dev/null | md5sum)
    if [ "$_after" = "$_BEFORE" ]; then
        say "  no config change - not rebooting"
        exit 0
    fi
    reboot_now
}

# Reboot in the background and exit 100, so deploy.sh knows for sure a
# reboot is coming: a plain `reboot` returns at once, and the SSH session
# would often end with 0, as if nothing had changed. HUP is ignored (top
# of this file), so the session closing can't stop it. Pass 0 when the
# session is already gone (an IP move): there is no exit code to deliver,
# and rebooting at once leaves less time for the new address to look up.
reboot_now() {
    _delay=${1:-3}
    if [ "$_delay" = 0 ]; then
        say "  rebooting now"
    else
        say "  rebooting in ${_delay}s"
    fi
    sync
    ( sleep "$_delay"; reboot ) </dev/null >/dev/null 2>&1 &
    exit 100
}
