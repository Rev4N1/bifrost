#!/bin/sh
# ========================================================
# wifi-watch installer
#
# Runs ON the main router; from the PC:  ./deploy.sh
#
# This is an ADDON. It never touches wireless, network, dhcp
# or firewall config - the router/ scripts own those. The only
# change it makes to the dumb APs is appending one public key
# to /etc/dropbear/authorized_keys, so they can be asked
# which stations are associated.
#
# Idempotent: re-run it after every flash, or after editing
# bifrost.conf (deploy.sh writes wifi-watch.conf from it).
#
#   install.sh              install / upgrade
#   install.sh --check      diagnose an existing install
#   install.sh --uninstall  remove (leaves the SSH key)
# ========================================================

BIN_DIR="/usr/bin"
LIB_DIR="/usr/lib/wifi-watch"
CONF_PATH="/etc/wifi-watch.conf"
INIT_PATH="/etc/init.d/wifi-watch"
FILES="wifi-watch.sh wifi-where.sh wifi-watch-lib.sh wifi-watch.init wifi-watch.conf"

SRC_DIR=$(cd "$(dirname "$0")" && pwd)

RC=0
say()  { printf '%s\n' "$*"; }
ok()   { printf '  [ ok ] %s\n' "$*"; }
warn() { printf '  [warn] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; RC=1; }
hdr()  { printf '\n== %s\n' "$*"; }

# Install mode reads the lib and config from this directory (they are
# what is about to be installed); --check reads the installed ones.
if [ "$1" = "--check" ] || [ "$1" = "--uninstall" ]; then
    LIB="$LIB_DIR/lib.sh"
    [ -r "$LIB" ] || LIB="$SRC_DIR/wifi-watch-lib.sh"
else
    LIB="$SRC_DIR/wifi-watch-lib.sh"
    WIFI_WATCH_CONF="$SRC_DIR/wifi-watch.conf"
fi
[ -r "$LIB" ] || { echo "cannot read $LIB"; exit 1; }
# shellcheck disable=SC1090  # loaded from the staged directory or /usr/lib
. "$LIB"
ww_load_conf 2>/dev/null || [ "$1" = "--uninstall" ] || {
    echo "cannot read $WIFI_WATCH_CONF - run this through ./deploy.sh"
    exit 1
}
if [ -z "$1" ] && grep -qE "=[\"']CHANGE_ME[\"']" "$WIFI_WATCH_CONF"; then
    echo "$WIFI_WATCH_CONF still has CHANGE_ME placeholders"
    exit 1
fi
ww_detect_timeout

# key_works <host> - can we run a command non-interactively?
key_works() {
    ww_answered "$(ww_ap_run "$1" 'echo __WIFIWATCH_OK__')"
}

pubkey() { dropbearkey -y -f "$SSH_KEY" </dev/null 2>/dev/null | grep '^ssh-'; }

# ---- steps ---------------------------------------------------------

check_host() {
    hdr "Host"
    if [ ! -f /etc/openwrt_release ]; then
        fail "this does not look like OpenWrt"
        return
    fi
    . /etc/openwrt_release
    case "${DISTRIB_RELEASE:-}" in
        25.*) ;;
        *) fail "this addon targets OpenWrt 25.12 (apk); found ${DISTRIB_RELEASE:-unknown}"; return ;;
    esac
    command -v apk >/dev/null 2>&1 || { fail "apk not found - not an apk-based 25.12 image"; return; }
    ok "$(uname -n) - $(sed -n "s/^DISTRIB_DESCRIPTION='\(.*\)'/\1/p" /etc/openwrt_release)"

    # A dumb AP has an empty /etc/config/dhcp. Check the config rather than
    # a lease file: a fresh main router may have no clients yet, and the
    # notifier still works from association alone until the first lease.
    uci -q get dhcp.@dnsmasq[0] >/dev/null \
        || fail "no dnsmasq config - run this on the MAIN router, not a dumb AP"
    if [ ! -f "$LEASES" ]; then
        warn "$LEASES missing - ARP starts after the first DHCP lease; association still works"
    else
        ok "dnsmasq leases present ($(wc -l < "$LEASES") entries)"
    fi
}

check_files() {
    hdr "Source"
    for F in $FILES; do
        [ -f "$SRC_DIR/$F" ] || fail "$F not found in $SRC_DIR"
    done
    [ "$RC" -eq 0 ] && ok "all files present in $SRC_DIR"
}

# need <command> <package> <why-if-missing> - install a package if its
# command is missing. Packages are lost on every flash, hence re-checked.
need() {
    if command -v "$1" >/dev/null 2>&1; then
        ok "$1 present"
        return 0
    fi
    $PKG_ADD "$2" >/dev/null 2>&1
    if command -v "$1" >/dev/null 2>&1; then
        ok "$1 installed ($2)"
        return 0
    fi
    warn "$1 unavailable - $3"
    return 1
}

install_deps() {
    hdr "Dependencies"
    PKG_ADD="apk add"; apk update >/dev/null 2>&1

    # Not in the default image: without it no notification is ever sent.
    need curl curl "notifications will queue until it is installed"
    [ -f /etc/ssl/certs/ca-certificates.crt ] || $PKG_ADD ca-bundle >/dev/null 2>&1

    # Broadcast ARP probing. ICMP alone is unreliable against a phone in doze.
    need arping iputils-arping "ARP signal degrades to ICMP"

    # Hard cap per AP query. wifi-watch also ping-gates each AP, so this
    # is belt-and-braces rather than required.
    need timeout coreutils-timeout "relying on the ping pre-check to bound AP queries"
    ww_detect_timeout

    ww_detect_ssh && ok "ssh client: $SSH_BIN" \
        || fail "no dbclient (dropbear) - dumb APs cannot be queried"
}

make_key() {
    hdr "SSH key"
    mkdir -p /root/.ssh && chmod 700 /root/.ssh
    if [ -f "$SSH_KEY" ] && [ -n "$(pubkey)" ]; then
        chmod 600 "$SSH_KEY"
        ok "reusing $SSH_KEY"
        return
    fi
    rm -f "$SSH_KEY"
    dropbearkey -t ed25519 -f "$SSH_KEY" >/dev/null 2>&1
    if [ -f "$SSH_KEY" ]; then
        chmod 600 "$SSH_KEY"
        ok "generated $SSH_KEY"
    else
        fail "could not generate a key"
    fi
}

# Append our public key to one AP. Uses key auth if it already works,
# otherwise AP_PASSWORD (deploy.sh passes ROOT_PASSWORD for this run
# only, never written to disk), otherwise asks for it.
push_key() {
    _h="$1"
    if key_works "$_h"; then
        ok "$_h - key already authorized"
        return 0
    fi
    if ! ping -c1 -W2 "$_h" >/dev/null 2>&1; then
        warn "$_h - not reachable, skipped"
        return 1
    fi

    _pub=$(pubkey)
    if [ -z "$_pub" ]; then
        fail "$_h - no public key to push"
        return 1
    fi

    _append='mkdir -p /etc/dropbear && chmod 700 /etc/dropbear &&
         cat >> /etc/dropbear/authorized_keys &&
         sort -u /etc/dropbear/authorized_keys -o /etc/dropbear/authorized_keys &&
         chmod 600 /etc/dropbear/authorized_keys'

    if [ -n "${AP_PASSWORD:-}" ]; then
        # dbclient takes the password from the environment.
        say "  $_h - authorizing"
        printf '%s\n' "$_pub" | DROPBEAR_PASSWORD="$AP_PASSWORD" \
            "$SSH_BIN" $SSH_ASK "root@$_h" "$_append" >/dev/null 2>&1
    else
        say "  $_h - authorizing (enter the AP's root password)"
        printf '%s\n' "$_pub" | "$SSH_BIN" $SSH_ASK "root@$_h" "$_append" >/dev/null 2>&1
    fi

    if key_works "$_h"; then
        ok "$_h - authorized"
        return 0
    fi
    warn "$_h - could not authorize; wifi-watch will fall back to ARP-only for this AP"
    return 1
}

authorize_aps() {
    hdr "Dumb APs"
    [ -n "$SSH_BIN" ] || { warn "no ssh client, skipping"; return; }
    [ -n "$AP_IPS" ] || { ok "AP_IPS empty, nothing to authorize"; return; }
    for H in $AP_IPS; do
        push_key "$H"
    done
}

install_files() {
    hdr "Files"
    [ -x "$INIT_PATH" ] && "$INIT_PATH" stop >/dev/null 2>&1

    # Copy with CRs stripped: a file saved with Windows line endings
    # would otherwise fail on the router with baffling errors.
    put() { tr -d '\r' < "$SRC_DIR/$1" > "$2" && chmod "$3" "$2"; }

    mkdir -p "$LIB_DIR"
    put wifi-watch.sh     "$BIN_DIR/wifi-watch.sh" 755
    put wifi-where.sh     "$BIN_DIR/wifi-where.sh" 755
    put wifi-watch-lib.sh "$LIB_DIR/lib.sh"        644
    put wifi-watch.init   "$INIT_PATH"             755
    put wifi-watch.conf   "$CONF_PATH"             600
    ok "installed to $BIN_DIR, $LIB_DIR, $CONF_PATH, $INIT_PATH"

    # Keep the config and the AP key across sysupgrade (keep settings),
    # so a flash doesn't force re-authorizing the APs.
    for P in "$CONF_PATH" "$SSH_KEY"; do
        [ -e "$P" ] || continue
        grep -qxF "$P" /etc/sysupgrade.conf 2>/dev/null || echo "$P" >> /etc/sysupgrade.conf
    done
    ok "config and key listed in /etc/sysupgrade.conf"
}

start_service() {
    hdr "Service"
    "$INIT_PATH" enable  >/dev/null 2>&1 && ok "enabled at boot" || warn "could not enable"
    "$INIT_PATH" restart >/dev/null 2>&1 && ok "started"         || fail "could not start"
}

self_test() {
    hdr "Self-test"

    if [ -x "$INIT_PATH" ] && "$INIT_PATH" running >/dev/null 2>&1; then
        ok "service running"
    else
        warn "service not running"
    fi

    command -v curl >/dev/null 2>&1 && ok "telegram: curl available" \
        || warn "telegram: curl missing, nothing will be sent"
    [ -s "$STATE_DIR/.outbox" ] && \
        warn "telegram: $(wc -l < "$STATE_DIR/.outbox") queued message(s) not delivered yet"

    if command -v arping >/dev/null 2>&1; then
        ok "signal 2 (ARP): arping available"
    else
        warn "signal 2 (ARP): falling back to ICMP"
    fi

    _n=$(ubus list 2>/dev/null | grep -c '^hostapd\.')
    if [ "$_n" -gt 0 ]; then
        ok "signal 1 (association), local: $_n hostapd interface(s)"
    else
        warn "signal 1 (association), local: no hostapd on ubus - is wifi up?"
    fi

    ww_detect_ssh
    for H in $AP_IPS; do
        _out=$(ww_ap_run "$H" "$ASSOC_CMD")
        if ww_answered "$_out"; then
            _c=$(printf '%s' "$_out" | grep -oE "$MAC_RE" | tr 'A-F' 'a-f' | sort -u | wc -l)
            ok "signal 1, $H: reachable, $_c station(s)"
        else
            warn "signal 1, $H: unreachable - ARP-only for this AP (re-run install.sh?)"
        fi
    done

    # Only meaningful once the watcher has run a poll.
    if [ -s "$MACMAP" ]; then
        ok "MAC->person map: $(wc -l < "$MACMAP") entr(ies)"
    else
        say "  [info] MAC->person map still empty; it fills on the first poll"
    fi
}

uninstall() {
    hdr "Uninstall"
    if [ -x "$INIT_PATH" ]; then
        "$INIT_PATH" stop    >/dev/null 2>&1
        "$INIT_PATH" disable >/dev/null 2>&1
        ok "service stopped and disabled"
    fi
    rm -f "$INIT_PATH" "$BIN_DIR/wifi-watch.sh" "$BIN_DIR/wifi-where.sh" "$CONF_PATH"
    rm -rf "$LIB_DIR" "$STATE_DIR"
    sed -i "\#^$CONF_PATH\$#d" /etc/sysupgrade.conf 2>/dev/null
    ok "files removed"
    say ""
    say "Left in place (harmless, and needed if you reinstall):"
    say "  $SSH_KEY on this router (still listed in /etc/sysupgrade.conf)"
    say "  the authorized_keys line on the dumb APs"
}

# ---- main ----------------------------------------------------------

case "$1" in
    --uninstall)
        uninstall
        ;;
    --check)
        check_host
        self_test
        say ""
        ww_print_state
        ;;
    "")
        check_host
        check_files
        [ "$RC" -eq 0 ] || { say ""; say "Aborting: fix the errors above."; exit 1; }
        install_deps
        make_key
        authorize_aps
        install_files
        [ "$RC" -eq 0 ] || { say ""; say "Aborting: fix the errors above."; exit 1; }
        start_service
        sleep 2
        self_test
        say ""
        say "Done. Verify with:"
        say "  logread -e wifi-watch"
        say "  wifi-where.sh"
        ;;
    *)
        say "usage: $0 [--check|--uninstall]"
        exit 1
        ;;
esac

say ""
exit "$RC"
