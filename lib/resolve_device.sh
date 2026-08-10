#!/usr/bin/env bash
#
# lib/resolve_device.sh — shared device registry, sourced by debloat.sh
# and migrate_apps.sh. Turns a saved label (from devices.tsv, set up
# via ./devices.sh init) or a raw ADB serial into a validated, currently
# connected serial. If no arg is given and exactly one device is
# connected, that device is used automatically — no config needed for
# the single-device case.
#
DEVICES_FILE="${DEVICES_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/devices.tsv}"

list_connected() {
    adb devices | awk 'NR>1 && $2=="device" {print $1}'
}

lookup_label() {
    local label="$1"
    [[ -f "$DEVICES_FILE" ]] || return 1
    awk -F'\t' -v l="$label" 'NR>1 && $1==l {print $2; found=1} END{exit !found}' "$DEVICES_FILE"
}

label_for_serial() {
    local serial="$1"
    [[ -f "$DEVICES_FILE" ]] || return 0
    awk -F'\t' -v s="$serial" 'NR>1 && $2==s {print $1}' "$DEVICES_FILE"
}

# Prints a resolved, connected serial on stdout; errors (with guidance)
# on stderr and returns non-zero if it can't unambiguously resolve one.
resolve_device() {
    local arg="${1:-}"
    local connected
    connected="$(list_connected)"

    if [[ -n "$arg" ]]; then
        local by_label
        if by_label="$(lookup_label "$arg")"; then
            if echo "$connected" | grep -qx "$by_label"; then
                echo "$by_label"; return 0
            else
                echo "Device labeled '$arg' ($by_label) is not currently connected." >&2
                echo "Connected: $(echo "$connected" | tr '\n' ' ')" >&2
                return 1
            fi
        fi
        if echo "$connected" | grep -qx "$arg"; then
            echo "$arg"; return 0
        fi
        echo "'$arg' isn't a known label or a connected device serial." >&2
        echo "Connected serials: $(echo "$connected" | tr '\n' ' ')" >&2
        if [[ -f "$DEVICES_FILE" ]] && [[ "$(wc -l < "$DEVICES_FILE")" -gt 1 ]]; then
            echo "Known labels:" >&2
            awk -F'\t' 'NR>1{print " - "$1" -> "$2}' "$DEVICES_FILE" >&2
        fi
        return 1
    fi

    local count
    count="$(echo "$connected" | grep -c . || true)"
    if [[ "$count" -eq 1 ]]; then
        echo "$connected"; return 0
    elif [[ "$count" -eq 0 ]]; then
        echo "No authorized ADB devices connected." >&2
        return 1
    else
        echo "Multiple devices connected — specify a label or serial:" >&2
        while IFS= read -r s; do
            local lbl
            lbl="$(label_for_serial "$s")"
            echo " - $s${lbl:+ ($lbl)}" >&2
        done <<< "$connected"
        echo "Tip: run ./devices.sh init once to label these, then just pass the label." >&2
        return 1
    fi
}
