#!/bin/sh
# ========================================================
# wifi-where.sh - show which AP each device is associated to
#
# Run by hand on the main router. Read-only, sends nothing.
# Uses the same SSH plumbing and the same MAC->person map
# as wifi-watch.sh, so what it prints is exactly what the
# notifier is deciding on.
#
#   wifi-where.sh          # known people only
#   wifi-where.sh -a       # every associated station
# ========================================================

. /usr/lib/wifi-watch/lib.sh
ww_load_conf || exit 1
ww_detect_timeout
ww_detect_ssh

SHOW_ALL=0
[ "$1" = "-a" ] && SHOW_ALL=1

person_for_mac() {
    _m=$(echo "$1" | tr 'A-F' 'a-f')
    _p=$(awk -v m="$_m" '$1 == m { print $2; exit }' "$MACMAP" 2>/dev/null)
    [ -n "$_p" ] && { echo "$_p"; return; }
    # Fall back to a live lease lookup if the map has not learned it yet.
    awk -v m="$_m" 'tolower($2) == m { print $4; exit }' "$LEASES" 2>/dev/null
}

report_ap() {
    _label="$1"
    _out="$2"

    if ! ww_answered "$_out"; then
        printf '%s\n  UNREACHABLE\n\n' "$_label"
        return
    fi

    printf '%s\n' "$_label"
    _rows=$(printf '%s\n' "$_out" | grep -E "^$MAC_RE ")
    if [ -z "$_rows" ]; then
        printf '  (no stations)\n\n'
        return
    fi

    printf '%s\n' "$_rows" | while read -r MAC IFACE CH SIG; do
        WHO=$(person_for_mac "$MAC")
        if [ -z "$WHO" ] || [ "$WHO" = "*" ]; then
            [ "$SHOW_ALL" -eq 1 ] || continue
            WHO="-"
        fi
        printf '  %-18s %-17s %-10s ch %-4s %s dBm\n' "$WHO" "$MAC" "$IFACE" "${CH:-?}" "${SIG:-?}"
    done
    printf '\n'
}

echo
report_ap "$(uname -n) (local)" "$(eval "$WHERE_CMD" 2>/dev/null)"

for H in $AP_HOSTS; do
    report_ap "$H" "$(ww_ap_run "$H" "$WHERE_CMD")"
done

ww_print_state
echo
