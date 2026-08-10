#!/usr/bin/env bash
#
# devices.sh — one-time-ish setup: detect connected ADB device(s) and
# save serial+model under a label you choose into devices.tsv. Both
# debloat.sh and migrate_apps.sh accept that label anywhere they'd
# normally take a raw serial, so you stop needing to `adb devices` and
# copy-paste serials by hand, and "more than one device/emulator"
# ambiguity goes away.
#
# Usage:
#   ./devices.sh init            Detect + label connected device(s)
#   ./devices.sh list            Show saved devices
#   ./devices.sh forget <label>  Remove a saved device
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVICES_FILE="$SCRIPT_DIR/devices.tsv"
source "$SCRIPT_DIR/lib/resolve_device.sh"

usage() {
    cat <<EOF
Usage: $0 <command>

Commands:
  init            Detect connected ADB device(s), prompt for a label
                   each, save serial+model into devices.tsv.
  list            Show saved devices.
  forget <label>  Remove a saved device by label.
EOF
}

cmd_init() {
    command -v adb >/dev/null 2>&1 || { echo "adb not found in PATH."; exit 1; }
    [[ -f "$DEVICES_FILE" ]] || printf "label\tserial\tmodel\tnote\n" > "$DEVICES_FILE"

    local connected
    connected="$(list_connected)"
    if [[ -z "$connected" ]]; then
        echo "No authorized ADB devices connected."
        echo "Plug one in, accept the USB debugging prompt on the phone, and re-run."
        exit 1
    fi

    # Use an array + for-loop rather than `while read <<<`, since the
    # latter binds stdin to the device list for the loop's duration —
    # which then gets consumed by the interactive `read -p` below
    # instead of the terminal, silently corrupting both. (Same class of
    # bug as `adb shell` swallowing a stdin-fed command list elsewhere
    # in this project.)
    local serials=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && serials+=("$line")
    done <<< "$connected"

    for serial in "${serials[@]}"; do
        if awk -F'\t' -v s="$serial" 'NR>1 && $2==s{f=1} END{exit !f}' "$DEVICES_FILE"; then
            existing_label="$(label_for_serial "$serial")"
            echo "Already known: $serial -> '$existing_label' (run 'forget $existing_label' first to relabel)"
            continue
        fi

        model="$(adb -s "$serial" shell getprop ro.product.model < /dev/null | tr -d '\r\n')"
        default_label="$(echo "$model" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-')"
        [[ -z "$default_label" ]] && default_label="device"

        echo "Found device $serial ($model)"
        read -r -p "Label for this device [$default_label]: " label
        label="${label:-$default_label}"

        # avoid duplicate labels
        if awk -F'\t' -v l="$label" 'NR>1 && $1==l{f=1} END{exit !f}' "$DEVICES_FILE"; then
            echo "Label '$label' is already used by another serial — pick another, run again."
            continue
        fi

        printf "%s\t%s\t%s\t%s\n" "$label" "$serial" "$model" "" >> "$DEVICES_FILE"
        echo "Saved: $label -> $serial"
    done

    echo
    cmd_list
}

cmd_list() {
    if [[ ! -f "$DEVICES_FILE" ]] || [[ "$(wc -l < "$DEVICES_FILE")" -le 1 ]]; then
        echo "No devices saved yet. Run: $0 init"
        return
    fi
    printf "%-15s %-22s %s\n" "LABEL" "SERIAL" "MODEL"
    awk -F'\t' 'NR>1{printf "%-15s %-22s %s\n",$1,$2,$3}' "$DEVICES_FILE"
}

cmd_forget() {
    local label="${1:-}"
    [[ -z "$label" ]] && { echo "Usage: $0 forget <label>"; exit 1; }
    [[ -f "$DEVICES_FILE" ]] || { echo "No devices saved yet."; exit 1; }
    tmp="$(mktemp)"
    awk -F'\t' -v l="$label" 'NR==1 || $1!=l' "$DEVICES_FILE" > "$tmp" && mv "$tmp" "$DEVICES_FILE"
    echo "Forgot '$label' (if it existed)."
}

CMD="${1:-}"
shift || true
case "$CMD" in
    init) cmd_init "$@" ;;
    list) cmd_list "$@" ;;
    forget) cmd_forget "$@" ;;
    *) usage; exit 1 ;;
esac
