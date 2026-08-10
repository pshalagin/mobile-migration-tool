#!/usr/bin/env bash
#
# scripts/devices.sh — one-time-ish setup: detect connected ADB
# device(s), pick a debloat package-catalog template to seed that
# device's live catalog, and optionally tag it as the "old" or "new"
# device for migrate.sh so scan-old/scan-new/pull/install never need a
# device arg again. The ADB serial IS the device's identity — nothing
# to name or remember.
#
# Run via ./run.sh devices <command> — see run.sh at the repo root.
#
# state/devices.tsv columns: label, serial, model, catalog, role
# (`label` is always just the serial, kept as its own column so this
# file's schema matches the resolution logic in lib/resolve_device.sh,
# which accepts either a label or a raw serial — with label==serial
# those are the same thing here.)
# `catalog` is a repo-root-relative path (e.g. state/catalogs/x.tsv),
# a per-device COPY of a templates/*.tsv file — editable independently
# per device without touching the template it came from.
# `role` is "old", "new", or empty. At most one device holds each role
# at a time — assigning it to a new device clears it from the old one.
#
# Usage:
#   devices.sh init                     Detect + pick catalog template + role
#   devices.sh list                     Show saved devices
#   devices.sh forget <serial>          Remove a saved device
#   devices.sh templates                List available catalog templates
#   devices.sh set-role <serial> <old|new|none>
#                                        Assign/change a device's migration
#                                        role without re-running init
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEVICES_FILE="$REPO_ROOT/state/devices.tsv"
TEMPLATES_DIR="$REPO_ROOT/templates"
CATALOGS_DIR="$REPO_ROOT/state/catalogs"
source "$SCRIPT_DIR/lib/resolve_device.sh"

usage() {
    cat <<EOF
Usage: ./run.sh devices <command>

Commands:
  init                          Detect connected ADB device(s), prompt
                                 for a catalog template and migration
                                 role (old/new/none) each. Devices are
                                 identified by ADB serial, nothing to name.
  list                          Show saved devices.
  forget <serial>                Remove a saved device.
  templates                     List available catalog templates ($TEMPLATES_DIR).
  set-role <serial> <old|new|none>
                                 Assign/change a device's migration role
                                 after the fact, no re-init needed.
EOF
}

# Upgrades an existing devices.tsv from the older 4-column schema
# (before "role" existed) in place, and creates a fresh 5-column file
# if none exists yet. Safe to call from every command.
ensure_devices_schema() {
    if [[ ! -f "$DEVICES_FILE" ]]; then
        printf "label\tserial\tmodel\tcatalog\trole\n" > "$DEVICES_FILE"
        return
    fi
    local header
    header="$(head -1 "$DEVICES_FILE")"
    if [[ "$header" != *$'\t'role ]]; then
        local tmp
        tmp="$(mktemp)"
        awk -F'\t' 'BEGIN{OFS="\t"} NR==1{print $0,"role"; next} {print $0,""}' "$DEVICES_FILE" > "$tmp"
        mv "$tmp" "$DEVICES_FILE"
        echo "(upgraded devices.tsv to add the 'role' column — existing devices have no role set yet)" >&2
    fi
}

cmd_templates() {
    if [[ ! -d "$TEMPLATES_DIR" ]] || [[ -z "$(ls "$TEMPLATES_DIR"/*.tsv 2>/dev/null)" ]]; then
        echo "No templates found in $TEMPLATES_DIR"
        return
    fi
    echo "Available catalog templates:"
    for f in "$TEMPLATES_DIR"/*.tsv; do
        local name rows
        name="$(basename "$f" .tsv)"
        rows=$(($(wc -l < "$f") - 1))
        echo " - $name ($rows packages)"
    done
    echo
    echo "To add one: drop a new packages.tsv-formatted file at"
    echo "  $TEMPLATES_DIR/<name>.tsv"
    echo "and commit it — it'll show up here and in 'devices.sh init' automatically."
}

pick_template() {
    # Prints the chosen template name on stdout (empty if skipped).
    # Everything else goes to stderr so it doesn't get captured by the
    # caller's command substitution.
    local templates=()
    for f in "$TEMPLATES_DIR"/*.tsv; do
        [[ -f "$f" ]] && templates+=("$(basename "$f" .tsv)")
    done

    if [[ ${#templates[@]} -eq 0 ]]; then
        echo "No catalog templates found — skipping catalog setup for this device." >&2
        return
    fi

    echo "Catalog templates available:" >&2
    local i=1
    for t in "${templates[@]}"; do
        echo "  $i) $t" >&2
        ((i++))
    done
    echo "  0) none / skip for now" >&2

    local choice
    read -r -p "Pick a template [1]: " choice
    choice="${choice:-1}"

    if [[ "$choice" == "0" ]]; then
        return
    fi
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt ${#templates[@]} ]]; then
        echo "Not a valid choice, skipping catalog setup for this device." >&2
        return
    fi

    echo "${templates[$((choice - 1))]}"
}

pick_role() {
    # Prints "old", "new", or "" (skip) on stdout.
    echo "Is this the OLD (migration source) or NEW (migration destination) device?" >&2
    echo "This gets saved — migrate.sh scan-old/scan-new/pull/install will then" >&2
    echo "auto-pick this device by role and never ask again." >&2
    echo "  1) old" >&2
    echo "  2) new" >&2
    echo "  0) neither / skip" >&2

    local choice
    read -r -p "Choice [0]: " choice
    choice="${choice:-0}"
    case "$choice" in
        1) echo "old" ;;
        2) echo "new" ;;
        *) echo "" ;;
    esac
}

# Sets $label's role to $role (possibly empty = clear), clearing that
# same role from any other device first since only one device can hold
# a given role at a time.
assign_role() {
    local label="$1" role="$2"

    if [[ -n "$role" ]]; then
        local existing
        existing="$(awk -F'\t' -v r="$role" -v l="$label" 'NR>1 && $5==r && $1!=l {print $1}' "$DEVICES_FILE")"
        [[ -n "$existing" ]] && echo "Role '$role' was assigned to '$existing' — reassigning to '$label'."
    fi

    local tmp
    tmp="$(mktemp)"
    awk -F'\t' -v OFS='\t' -v l="$label" -v r="$role" '
        NR==1 { print; next }
        $1==l         { $5=r }
        $5==r && r!="" && $1!=l { $5="" }
        { print }
    ' "$DEVICES_FILE" > "$tmp"
    mv "$tmp" "$DEVICES_FILE"
}

cmd_init() {
    command -v adb >/dev/null 2>&1 || { echo "adb not found in PATH."; exit 1; }
    ensure_devices_schema
    mkdir -p "$CATALOGS_DIR"

    local connected
    connected="$(list_connected)"
    if [[ -z "$connected" ]]; then
        echo "No authorized ADB devices connected."
        echo "Plug one in, accept the USB debugging prompt on the phone, and re-run."
        exit 1
    fi

    # Array + for-loop, not `while read <<<`: the latter binds stdin to
    # the device list for the loop's duration, which then gets consumed
    # by the interactive `read -p` calls below instead of the terminal.
    local serials=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && serials+=("$line")
    done <<< "$connected"

    for serial in "${serials[@]}"; do
        if awk -F'\t' -v s="$serial" 'NR>1 && $2==s{f=1} END{exit !f}' "$DEVICES_FILE"; then
            echo "Already known: $serial (run 'forget $serial' first to reset it, or 'set-role' to change its role)"
            continue
        fi

        model="$(adb -s "$serial" shell getprop ro.product.model < /dev/null | tr -d '\r\n')"
        echo "Found device $serial ($model)"

        # The ADB serial IS the device's identity — no separate label
        # to invent or remember.
        local label="$serial"

        local template catalog=""
        template="$(pick_template)"
        if [[ -n "$template" ]]; then
            catalog="state/catalogs/${label}.tsv"
            cp "$TEMPLATES_DIR/${template}.tsv" "$CATALOGS_DIR/${label}.tsv"
            echo "Seeded $catalog from template '$template' — edit it freely, it's this device's own copy."
        fi

        local role
        role="$(pick_role)"

        printf "%s\t%s\t%s\t%s\t%s\n" "$label" "$serial" "$model" "$catalog" "$role" >> "$DEVICES_FILE"
        [[ -n "$role" ]] && assign_role "$label" "$role"   # clears the role from any other device
        echo "Saved: $serial${role:+ (role: $role)}"
    done

    echo
    cmd_list
}

cmd_list() {
    ensure_devices_schema
    if [[ "$(wc -l < "$DEVICES_FILE")" -le 1 ]]; then
        echo "No devices saved yet. Run: ./run.sh devices init"
        return
    fi
    printf "%-15s %-22s %-16s %-22s %s\n" "LABEL" "SERIAL" "MODEL" "CATALOG" "ROLE"
    awk -F'\t' 'NR>1{printf "%-15s %-22s %-16s %-22s %s\n",$1,$2,$3,$4,$5}' "$DEVICES_FILE"
}

cmd_forget() {
    local label="${1:-}"
    [[ -z "$label" ]] && { echo "Usage: ./run.sh devices forget <serial>"; exit 1; }
    ensure_devices_schema
    tmp="$(mktemp)"
    awk -F'\t' -v l="$label" 'NR==1 || $1!=l' "$DEVICES_FILE" > "$tmp" && mv "$tmp" "$DEVICES_FILE"
    echo "Forgot '$label' (if it existed). Its state/catalogs/$label.tsv, if any, was left in place — delete manually if you don't want it."
}

cmd_set_role() {
    local label="${1:-}" role="${2:-}"
    if [[ -z "$label" || -z "$role" ]]; then
        echo "Usage: ./run.sh devices set-role <serial> <old|new|none>"
        exit 1
    fi
    ensure_devices_schema

    if ! awk -F'\t' -v l="$label" 'NR>1 && $1==l{f=1} END{exit !f}' "$DEVICES_FILE"; then
        echo "No device known with serial '$label'. Run './run.sh devices list' to see saved devices."
        exit 1
    fi

    case "$role" in
        old|new) : ;;
        none) role="" ;;
        *) echo "Role must be 'old', 'new', or 'none'."; exit 1 ;;
    esac

    assign_role "$label" "$role"
    echo "Set role for '$label': ${role:-none}"
    cmd_list
}

CMD="${1:-}"
shift || true
case "$CMD" in
    init) cmd_init "$@" ;;
    list) cmd_list "$@" ;;
    forget) cmd_forget "$@" ;;
    templates) cmd_templates "$@" ;;
    set-role) cmd_set_role "$@" ;;
    *) usage; exit 1 ;;
esac
