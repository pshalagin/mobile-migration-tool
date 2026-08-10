#!/usr/bin/env bash
#
# scripts/lib/resolve_device.sh — shared device registry, sourced by
# every tool script. Turns a saved label (from state/devices.tsv, set
# up via ./run.sh devices init) or a raw ADB serial into a validated,
# currently connected serial. If no arg is given and exactly one
# device is connected, that device is used automatically — no config
# needed for the single-device case.
#
# state/devices.tsv columns: label, serial, model, catalog, role
# `catalog` is a repo-root-relative path to that device's debloat
# packages.tsv (copied from a template at init time) — resolved via
# catalog_for_serial() below.
# `role` is "old", "new", or empty — set at init time (or later via
# `devices.sh set-role`) so migrate.sh's scan-old/scan-new/pull/install
# can auto-resolve which device to use with zero args, permanently,
# instead of asking for a label every single run.
#
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEVICES_FILE="${DEVICES_FILE:-$REPO_ROOT/state/devices.tsv}"

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

# Repo-root-relative catalog path registered for this serial at init
# time, or empty if none/not found. Caller decides the fallback.
catalog_for_serial() {
    local serial="$1"
    [[ -f "$DEVICES_FILE" ]] || return 0
    awk -F'\t' -v s="$serial" 'NR>1 && $2==s {print $4}' "$DEVICES_FILE"
}

role_for_serial() {
    local serial="$1"
    [[ -f "$DEVICES_FILE" ]] || return 0
    awk -F'\t' -v s="$serial" 'NR>1 && $2==s {print $5}' "$DEVICES_FILE"
}

serial_for_role() {
    local role="$1"
    [[ -f "$DEVICES_FILE" ]] || return 1
    awk -F'\t' -v r="$role" 'NR>1 && $5==r {print $2; found=1} END{exit !found}' "$DEVICES_FILE"
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
        echo "Tip: run ./run.sh devices init once to label these, then just pass the label." >&2
        return 1
    fi
}

# Like resolve_device(), but for commands tied to a migration role
# (old/new). If arg is given, behaves exactly like resolve_device().
# If not, prefers whichever connected device is registered with this
# role — set once via `devices.sh init` or `devices.sh set-role`, never
# asked again after that.
resolve_device_for_role() {
    local arg="${1:-}" role="$2"

    if [[ -n "$arg" ]]; then
        resolve_device "$arg"
        return $?
    fi

    local role_serial connected
    connected="$(list_connected)"
    if role_serial="$(serial_for_role "$role")" && [[ -n "$role_serial" ]]; then
        if echo "$connected" | grep -qx "$role_serial"; then
            echo "$role_serial"; return 0
        else
            local lbl
            lbl="$(label_for_serial "$role_serial")"
            echo "The device registered as '$role' (${lbl:-$role_serial}) is not currently connected." >&2
            echo "Connected: $(echo "$connected" | tr '\n' ' ')" >&2
            return 1
        fi
    fi

    # No device registered for this role — fall back to plain resolution
    resolve_device ""
}
