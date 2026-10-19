#!/bin/sh
# ========================================================
# wifi-watch.sh - Telegram home/away notifier
#
# Runs ONLY on ax6000-main. All logic is centralized here;
# the dumb APs run no agent, they are only queried.
#
# ---- Detection model -----------------------------------
# A person is PRESENT if EITHER of two independent signals
# says so. A false "left" therefore requires both to fail
# simultaneously.
#
#   1. ASSOCIATION (authoritative). Who is actually on a
#      radio right now, from hostapd:
#        - this router's own radios, locally over ubus
#          (no SSH, no key, cannot fail)
#        - each dumb AP, over SSH with a key
#      Immune to power-save: the AP knows a phone is there
#      whether or not the phone feels like answering packets.
#
#   2. ARP REACHABILITY (corroborating). Broadcast ARP to
#      every IP the person holds a DHCP lease on.
#      Broadcast, so it floods every bridge port and finds
#      the phone on whichever AP it landed on - unicast ICMP
#      is blackholed for up to the 300s bridge FDB ageing
#      timer after a roam off this router's own radio.
#      Wi-Fi chipsets answer ARP in firmware (ARP offload)
#      while the host CPU sleeps, so this survives doze.
#
# ---- Why not key state by MAC --------------------------
# Phones may hand out a fresh randomized MAC on reassociation.
# A MAC-keyed state machine reads that as "new device arrived"
# + "old device left" and floods duplicates. State is keyed by
# PERSON; hostapd's MAC-only view is translated through a
# persistent MAC->person map learned from the DHCP leases.
#
# ---- Why an unreachable AP blocks departures -----------
# If an AP cannot be queried we are down to one signal. Rather
# than risk announcing a departure on degraded data we hold
# state and retry. Bounded by AP_FAIL_GRACE so an AP that is
# genuinely unplugged cannot wedge the notifier forever.
# ========================================================

. /usr/lib/wifi-watch/lib.sh
ww_load_conf || exit 1

LAN_IF="${LAN_IF:-br-lan}"
CANDIDATES="$STATE_DIR/.candidates"
ASSOC="$STATE_DIR/.assoc"
PERSONS="$STATE_DIR/.persons"
OUTBOX="$STATE_DIR/.outbox"
MACMAP_MAX=200          # cap growth from randomized MACs

log() { ww_log "$1"; }

# Telegram. A message that can't be sent (WAN down, PPPoE
# reconnecting) is queued and retried every poll rather than lost.
send_telegram() {
    curl -sf -m 15 -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        --data-urlencode chat_id="$CHAT_ID" \
        --data-urlencode text="$1" >/dev/null 2>&1
}

notify() {
    flush_outbox
    if [ ! -s "$OUTBOX" ] && send_telegram "$1"; then
        return 0
    fi
    echo "$1 ($(date +%H:%M))" >> "$OUTBOX"
    log "WARN: telegram unreachable, queued: $1"
}

flush_outbox() {
    [ -s "$OUTBOX" ] || return 0
    while IFS= read -r _msg; do
        send_telegram "$_msg" || return 1
        sed -i '1d' "$OUTBOX"
    done < "$OUTBOX"
}

# ---- capability detection ------------------------------------------

ARPING=$(command -v arping 2>/dev/null)
[ -n "$ARPING" ] || log "WARN: arping not found, ARP signal degraded to ICMP. Install with: apk add iputils-arping"

ip link show "$LAN_IF" >/dev/null 2>&1 || {
    log "WARN: interface $LAN_IF not found, probing without an explicit interface"
    LAN_IF=""
}

command -v curl >/dev/null 2>&1 || log "WARN: curl not found, notifications will queue forever. Re-run install.sh"

ww_detect_timeout
if [ -n "$AP_HOSTS" ]; then
    if [ ! -r "$SSH_KEY" ]; then
        log "WARN: $SSH_KEY unreadable, association signal limited to local radios. Re-run install.sh"
        AP_HOSTS=""
    elif ! ww_detect_ssh; then
        log "WARN: no ssh client found, association signal limited to local radios. Re-run install.sh"
        AP_HOSTS=""
    fi
fi

# ---- signal 1: association -----------------------------------------

local_assoc() {
    for O in $(ubus list 2>/dev/null | grep '^hostapd\.'); do
        ubus call "$O" get_clients 2>/dev/null
    done
    for I in $(iw dev 2>/dev/null | sed -n 's/^[[:space:]]*Interface //p'); do
        iw dev "$I" station dump 2>/dev/null
    done
}

# remote_assoc <host> -> prints MACs, exit 0 only if the AP really answered
remote_assoc() {
    _out=$(ww_ap_run "$1" "$ASSOC_CMD")
    ww_answered "$_out" || return 1
    printf '%s\n' "$_out" | grep -oE "$MAC_RE"
    return 0
}

ap_fail_file() { echo "$STATE_DIR/apfail_$(echo "$1" | tr -c 'a-zA-Z0-9' '_')"; }

ap_fail_count() {
    _f=$(ap_fail_file "$1")
    [ -f "$_f" ] && cat "$_f" || echo 0
}

# Refresh $ASSOC and set APS_DEGRADED=1 if any AP we still trust went silent.
collect_assoc() {
    APS_DEGRADED=0
    { local_assoc; } 2>/dev/null | grep -oE "$MAC_RE" > "$ASSOC.tmp"

    for H in $AP_HOSTS; do
        _f=$(ap_fail_file "$H")
        if remote_assoc "$H" >> "$ASSOC.tmp"; then
            [ "$(ap_fail_count "$H")" -gt 0 ] && log "AP $H reachable again"
            echo 0 > "$_f"
        else
            _n=$(( $(ap_fail_count "$H") + 1 ))
            echo "$_n" > "$_f"
            if [ "$_n" -le "$AP_FAIL_GRACE" ]; then
                APS_DEGRADED=1
                log "WARN: AP $H unreachable ($_n/$AP_FAIL_GRACE), holding departures"
            elif [ "$_n" -eq $((AP_FAIL_GRACE + 1)) ]; then
                log "WARN: AP $H down for $_n polls, treating as offline and resuming departures"
            fi
        fi
    done

    tr 'A-F' 'a-f' < "$ASSOC.tmp" | sort -u > "$ASSOC"
    rm -f "$ASSOC.tmp"
}

# ---- signal 2: ARP reachability ------------------------------------

probe_ip() {
    _ip="$1"
    _tries="${2:-$ARPING_TRIES}"

    if [ -n "$ARPING" ]; then
        if [ -n "$LAN_IF" ]; then
            "$ARPING" -f -q -c "$_tries" -w 3 -I "$LAN_IF" "$_ip" >/dev/null 2>&1 && return 0
        else
            "$ARPING" -f -q -c "$_tries" -w 3 "$_ip" >/dev/null 2>&1 && return 0
        fi
    fi

    ping -c 2 -W 2 "$_ip" >/dev/null 2>&1 && return 0

    # Last resort: a freshly-confirmed neighbour entry. Parsed with awk
    # keyed on $1 because busybox "ip neigh show <addr>" does NOT filter
    # by address - it dumps the whole table, so grepping it directly
    # matches unrelated hosts.
    ip neigh show 2>/dev/null | awk -v ip="$_ip" '
        $1 == ip {
            for (i = 2; i <= NF; i++)
                if ($i == "REACHABLE" || $i == "DELAY" || $i == "PROBE")
                    found = 1
        }
        END { exit found ? 0 : 1 }
    '
}

# ---- person-level presence -----------------------------------------

record_mac() {
    _mac=$(echo "$1" | tr 'A-F' 'a-f')
    grep -q "^$_mac " "$MACMAP" 2>/dev/null || echo "$_mac $2" >> "$MACMAP"
}

person_assoc() {
    [ -s "$ASSOC" ] || return 1
    [ -s "$MACMAP" ] || return 1
    awk -v p="$1" '
        NR == FNR { map[$1] = $2; next }
        ($1 in map) && map[$1] == p { found = 1 }
        END { exit found ? 0 : 1 }
    ' "$MACMAP" "$ASSOC"
}

person_present() {
    _person="$1"
    _tries="$2"

    person_assoc "$_person" && return 0

    while read -r _p _ip; do
        [ "$_p" = "$_person" ] || continue
        probe_ip "$_ip" "$_tries" && return 0
    done < "$CANDIDATES"

    return 1
}

# Before announcing a departure, re-query the APs and re-probe a few more
# times spaced out in time. A roam is seconds wide; this makes it
# essentially impossible for one to be mistaken for a departure.
confirm_absent() {
    _person="$1"
    _n=0
    while [ "$_n" -lt "$CONFIRM_ROUNDS" ]; do
        sleep "$CONFIRM_GAP"
        collect_assoc
        person_present "$_person" 5 && return 1
        [ "$APS_DEGRADED" -eq 1 ] && return 1
        _n=$((_n + 1))
    done
    return 0
}

# ---- main ----------------------------------------------------------

mkdir -p "$STATE_DIR"
: > "$CANDIDATES"
: > "$ASSOC"
[ -f "$MACMAP" ] || : > "$MACMAP"
APS_DEGRADED=0

if [ -n "$AP_HOSTS" ]; then
    log "starting: association via local ubus + SSH to [$AP_HOSTS], corroborated by ARP"
else
    log "starting: association via local ubus only, corroborated by ARP"
fi

# On a cold start (or after a reboot wiped /tmp) seed every person's state
# silently, so we don't announce the whole household on boot.
SEEDING=1
for F in "$STATE_DIR"/person_*; do
    [ -e "$F" ] && SEEDING=0
    break
done
[ "$SEEDING" -eq 1 ] && sleep "$INITIAL_SETTLE"

while true; do
    NOW=$(date +%s)
    flush_outbox
    : > "$CANDIDATES"

    if [ -f "$LEASES" ]; then
        while read -r EPOCH MAC IP HOSTNAME _CLIENTID; do
            [ -n "$MAC" ] || continue
            [ -n "$IP" ] || continue

            PERSON=$(match_person "$HOSTNAME")
            [ -n "$PERSON" ] || PERSON=$(match_person_mac "$(echo "$MAC" | tr 'A-F' 'a-f')")
            [ -n "$PERSON" ] || continue

            # Learn the MAC even from an expired lease - that mapping is
            # how hostapd's MAC-only view gets resolved to a person, and
            # it stays valid long after the lease is gone.
            record_mac "$MAC" "$PERSON"

            # But don't ARP-probe expired leases: the address may since
            # have been handed to someone else, which would read as a
            # false "home".
            case "$EPOCH" in
                ''|*[!0-9]*) : ;;
                0) : ;;
                *) [ "$EPOCH" -lt "$NOW" ] && continue ;;
            esac

            echo "$PERSON $IP" >> "$CANDIDATES"
        done < "$LEASES"
    fi

    # Keep the randomized-MAC map from growing without bound.
    if [ "$(wc -l < "$MACMAP")" -gt "$MACMAP_MAX" ]; then
        tail -n "$MACMAP_MAX" "$MACMAP" > "$MACMAP.tmp" && mv "$MACMAP.tmp" "$MACMAP"
    fi

    collect_assoc

    # Iterate the union of three sources:
    #   - persons holding a live lease
    #   - persons currently associated under a MAC we've already mapped
    #     (covers someone who is on a radio but whose lease has aged out
    #     or who hasn't finished DHCP after a MAC rotation)
    #   - persons we already hold state for (a person whose lease aged
    #     out entirely must still be able to transition to "away",
    #     otherwise they stick at "home" forever and their next real
    #     arrival is silent)
    {
        awk '{print $1}' "$CANDIDATES" 2>/dev/null
        awk 'NR == FNR { map[$1] = $2; next } ($1 in map) { print map[$1] }' \
            "$MACMAP" "$ASSOC" 2>/dev/null
        for F in "$STATE_DIR"/person_*; do
            [ -e "$F" ] || continue
            echo "${F##*/person_}"
        done
    } | sort -u > "$PERSONS"

    while read -r PERSON; do
        [ -n "$PERSON" ] || continue

        STATE_FILE="$STATE_DIR/person_$PERSON"
        [ -f "$STATE_FILE" ] || echo "away 0" > "$STATE_FILE"
        read -r PREV_STATE MISS_COUNT < "$STATE_FILE"
        case "$MISS_COUNT" in ''|*[!0-9]*) MISS_COUNT=0 ;; esac

        if person_present "$PERSON"; then
            if [ "$PREV_STATE" = "away" ] && [ "$SEEDING" -eq 0 ]; then
                log "HOME: $PERSON connected"
                notify "$PERSON is home 🏠"
            fi
            echo "home 0" > "$STATE_FILE"
        elif [ "$PREV_STATE" = "home" ]; then
            MISS_COUNT=$((MISS_COUNT + 1))
            if [ "$MISS_COUNT" -lt "$MISSES_TO_LEAVE" ]; then
                log "MISS: $PERSON ($MISS_COUNT/$MISSES_TO_LEAVE)"
                echo "home $MISS_COUNT" > "$STATE_FILE"
            elif [ "$APS_DEGRADED" -eq 1 ]; then
                log "HOLD: $PERSON at threshold but an AP is unreachable, not declaring left"
                echo "home $MISS_COUNT" > "$STATE_FILE"
            elif confirm_absent "$PERSON"; then
                log "LEFT: $PERSON disconnected"
                [ "$SEEDING" -eq 0 ] && notify "$PERSON left home 🚪"
                echo "away 0" > "$STATE_FILE"
            else
                log "RECOVERED: $PERSON answered during confirmation"
                echo "home 0" > "$STATE_FILE"
            fi
        fi
    done < "$PERSONS"

    SEEDING=0
    sleep "$POLL_INTERVAL"
done
