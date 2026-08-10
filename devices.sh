#!/usr/bin/env bash
#
# devices.sh — one-time-ish setup: detect connected ADB device(s),
# save serial+model under a label you choose, and pick a debloat
# package-catalog template to seed that device's live catalog.
#
# devices.tsv columns: label, serial, model, catalog
# `catalog` is a repo-root-relative path (e.g. catalogs/redmi15c.tsv),
# a per-device COPY of a templates/*.tsv file — editable independently
# per device without touching the template it came from.
#
# Usage:
#   ./devices.sh init              Detect + label + pick catalog template
#   ./devices.sh list              Show saved devices
#   ./devices.sh forget <label>    Remove a saved device
#   ./devices.sh templates         List available catalog templates
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVICES_FILE="$SCRIPT_DIR/devices.tsv"
TEMPLATES_DIR="$SCRIPT_DIR/templates"
CATALOGS_DIR="$SCRIPT_DIR/catalogs"
source "$SCRIPT_DIR/lib/resolve_device.sh"

usage() {
    cat <<EOF
Usage: $0 <command>

Commands:
  init              Detect connected ADB device(s), prompt for a label
                     and a catalog template each, save to devices.tsv.
  list              Show saved devices.
  forget <label>    Remove a saved device by label.
  templates         List available catalog templates ($TEMPLATES_DIR).
EOF
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
    # Prints the chosen template's repo-root-relative catalogs/ path on
    # stdout (empty if skipped). Everything else goes to stderr so it
    # doesn't get captured by the caller's command substitution.
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

cmd_init() {
    command -v adb >/dev/null 2>&1 || { echo "adb not found in PATH."; exit 1; }
    [[ -f "$DEVICES_FILE" ]] || printf "label\tserial\tmodel\tcatalog\n" > "$DEVICES_FILE"
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

        if awk -F'\t' -v l="$label" 'NR>1 && $1==l{f=1} END{exit !f}' "$DEVICES_FILE"; then
            echo "Label '$label' is already used by another serial — pick another, run again."
            continue
        fi

        local template catalog=""
        template="$(pick_template)"
        if [[ -n "$template" ]]; then
            catalog="catalogs/${label}.tsv"
            cp "$TEMPLATES_DIR/${template}.tsv" "$CATALOGS_DIR/${label}.tsv"
            echo "Seeded $catalog from template '$template' — edit it freely, it's this device's own copy."
        fi

        printf "%s\t%s\t%s\t%s\n" "$label" "$serial" "$model" "$catalog" >> "$DEVICES_FILE"
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
    printf "%-15s %-22s %-16s %s\n" "LABEL" "SERIAL" "MODEL" "CATALOG"
    awk -F'\t' 'NR>1{printf "%-15s %-22s %-16s %s\n",$1,$2,$3,$4}' "$DEVICES_FILE"
}

cmd_forget() {
    local label="${1:-}"
    [[ -z "$label" ]] && { echo "Usage: $0 forget <label>"; exit 1; }
    [[ -f "$DEVICES_FILE" ]] || { echo "No devices saved yet."; exit 1; }
    tmp="$(mktemp)"
    awk -F'\t' -v l="$label" 'NR==1 || $1!=l' "$DEVICES_FILE" > "$tmp" && mv "$tmp" "$DEVICES_FILE"
    echo "Forgot '$label' (if it existed). Its catalogs/$label.tsv, if any, was left in place — delete manually if you don't want it."
}

CMD="${1:-}"
shift || true
case "$CMD" in
    init) cmd_init "$@" ;;
    list) cmd_list "$@" ;;
    forget) cmd_forget "$@" ;;
    templates) cmd_templates "$@" ;;
    *) usage; exit 1 ;;
esac
