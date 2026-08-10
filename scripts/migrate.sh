#!/usr/bin/env bash
#
# scripts/migrate.sh — multipass app migration toolkit. Old and new
# devices never need to be connected at the same time: each step
# reads/writes plain-text state files under state/migration/, and
# you get a hand-editable config file between planning and pulling so
# you control exactly what gets ported.
#
# Run via ./run.sh migrate <command> — see run.sh at the repo root.
#
# Workflow:
#   1. migrate.sh scan-old <old_serial>     (old phone connected)
#   2. migrate.sh scan-new <new_serial>     (new phone connected, any time)
#   3. migrate.sh plan                       (no phone needed)
#        -> writes state/migration/migration_config.txt
#   4. migrate.sh enrich                     (no phone needed, needs internet)
#        -> looks up each package's real app name from public store
#           listings and rewrites the config file's notes with it
#        -> EDIT THIS FILE BY HAND: change PORT/SKIP per line
#   5. migrate.sh pull <old_serial>          (old phone connected again)
#   6. migrate.sh install <new_serial>       (new phone connected, any time after)
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/resolve_device.sh"

STATE_DIR="${MIGRATION_STATE_DIR:-$REPO_ROOT/state/migration}"
APK_DIR="$STATE_DIR/apk_transfer"
OLD_FILE="$STATE_DIR/old_packages.tsv"
NEW_FILE="$STATE_DIR/new_packages.txt"
CONFIG_FILE="$STATE_DIR/migration_config.txt"

mkdir -p "$STATE_DIR"

usage() {
    cat <<EOF
Usage: ./run.sh migrate <command> [args]

Commands:
  scan-old <serial>    Snapshot installed third-party packages + installer
                        source from the OLD device. Writes $OLD_FILE
  scan-new <serial>    Snapshot installed third-party packages from the
                        NEW device. Writes $NEW_FILE
  plan                 Diff old vs new, write an editable
                        $CONFIG_FILE (no device needed)
  enrich                Look up each package's real app name/description
                        from public store listings (Google Play, then
                        RuStore as fallback) and annotate the config
                        file's notes with it. No device needed, needs
                        internet. Safe to re-run.
  pull <serial>        Pull APKs for every PORT line in the config file
                        from the device at <serial> (must be the OLD device)
  install <serial>     Push+install pulled APKs onto the device at
                        <serial> (must be the NEW device)
  status                Show current state of all files/counts

All <serial> args also accept a saved label (see ./run.sh devices init).
If you've tagged devices with roles via 'devices init' or
'devices set-role <label> old|new', these commands need no arg at
all — they auto-pick whichever connected device is registered for
that role. Otherwise they fall back to auto-picking when only one
device is connected.

Env:
  MIGRATION_STATE_DIR   Override the state directory (default: state/migration)
EOF
}

require_adb() {
    command -v adb >/dev/null 2>&1 || { echo "adb not found in PATH."; exit 1; }
}

cmd_scan_old() {
    require_adb
    local serial
    serial="$(resolve_device_for_role "${1:-}" old)" || exit 1

    echo "Scanning OLD device ($serial)..."
    adb -s "$serial" shell pm list packages -3 -i < /dev/null | tr -d '\r' > "$OLD_FILE"
    local count
    count=$(wc -l < "$OLD_FILE" | tr -d ' ')
    echo "Saved $count packages to $OLD_FILE"
}

cmd_scan_new() {
    require_adb
    local serial
    serial="$(resolve_device_for_role "${1:-}" new)" || exit 1

    echo "Scanning NEW device ($serial)..."
    adb -s "$serial" shell pm list packages -3 < /dev/null | sed 's/^package://' | tr -d '\r' | sort -u > "$NEW_FILE"
    local count
    count=$(wc -l < "$NEW_FILE" | tr -d ' ')
    echo "Saved $count packages to $NEW_FILE"
}

cmd_plan() {
    [[ -f "$OLD_FILE" ]] || { echo "Missing $OLD_FILE — run 'scan-old' first."; exit 1; }
    [[ -f "$NEW_FILE" ]] || { echo "Missing $NEW_FILE — run 'scan-new' first."; exit 1; }

    {
        echo "# Migration plan — edit freely before running 'pull'."
        echo "# First column: PORT (will be pulled/installed) or SKIP (ignored)."
        echo "# You can also just delete a line entirely to ignore it."
        echo "# SOURCE is informational: RuStore/PlayStore apps might be easier to"
        echo "# just reinstall from within that store on the new device instead of"
        echo "# sideloading — your call, this tool will honor whatever you set here."
        echo "#"
        printf "#%-9s %-45s %-12s %s\n" "ACTION" "PACKAGE" "SOURCE" "NOTE"
    } > "$CONFIG_FILE"

    local total=0 ported=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        pkg="$(echo "$line" | sed -E 's/^package:([^ ]+).*/\1/')"
        installer="$(echo "$line" | sed -E 's/.*installer=([^ ]*).*/\1/')"
        [[ "$line" == "$installer" ]] && installer=""

        # already on new device? skip entirely, don't even list it
        if grep -qx "$pkg" "$NEW_FILE"; then
            continue
        fi

        ((total++))

        case "$installer" in
            ru.vk.store)      src="RuStore";    action="SKIP"; note="reinstall from RuStore instead (same account)" ;;
            com.android.vending) src="PlayStore"; action="SKIP"; note="reinstall from Play Store instead (if kept & signed in)" ;;
            "")                src="unknown";    action="PORT"; note="sideload candidate, no known installer" ;;
            *)                 src="$installer"; action="PORT"; note="sideload candidate" ;;
        esac

        [[ "$action" == "PORT" ]] && ((ported++))
        printf "%-10s %-45s %-12s %s\n" "$action" "$pkg" "$src" "$note" >> "$CONFIG_FILE"
    done < "$OLD_FILE"

    echo "Plan written to $CONFIG_FILE"
    echo "$total apps missing on new device, $ported defaulted to PORT (sideload)."
    echo "Edit the file now, then run: ./run.sh migrate pull <old_serial>"
}

extract_og_title() {
    # Attribute order in the <meta> tag isn't guaranteed, so first
    # isolate the whole tag containing property="og:title", then pull
    # content="..." out of that isolated tag — order-independent.
    grep -o '<meta[^>]*property="og:title"[^>]*>' \
        | head -1 \
        | grep -o 'content="[^"]*"' \
        | sed -E 's/content="([^"]*)"/\1/'
}

fetch_app_name() {
    local pkg="$1"
    local name=""

    # Try Google Play's public web listing first — widest catalog,
    # works even for apps unavailable in your region (page still
    # renders a title in most cases).
    name="$(curl -s -L --max-time 8 -A "Mozilla/5.0" \
        "https://play.google.com/store/apps/details?id=${pkg}&hl=en" \
        | extract_og_title)"

    # Fallback: RuStore's public catalog page
    if [[ -z "$name" ]]; then
        name="$(curl -s -L --max-time 8 -A "Mozilla/5.0" \
            "https://www.rustore.ru/catalog/app/${pkg}" \
            | extract_og_title)"
    fi

    # Fallback: F-Droid API (JSON), covers FOSS apps not on either
    # store. Real shape is {"localized":{"en-US":{"name": "..."}}}, so
    # this needs a real JSON parser rather than a regex — use python3
    # (ships with macOS) if available, otherwise skip this fallback.
    if [[ -z "$name" ]] && command -v python3 >/dev/null 2>&1; then
        name="$(curl -s -L --max-time 8 "https://f-droid.org/api/v1/packages/${pkg}" \
            | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    loc = d.get("localized", {})
    en = loc.get("en-US") or next(iter(loc.values()), {})
    print(en.get("name", ""))
except Exception:
    pass
' 2>/dev/null)"
    fi

    echo "$name"
}

cmd_enrich() {
    [[ -f "$CONFIG_FILE" ]] || { echo "Missing $CONFIG_FILE — run 'plan' first."; exit 1; }
    command -v curl >/dev/null 2>&1 || { echo "curl not found in PATH — needed for enrich."; exit 1; }

    local tmp
    tmp="$(mktemp)"
    local looked_up=0 found=0

    while IFS= read -r line; do
        if [[ -z "$line" || "$line" == \#* ]]; then
            echo "$line" >> "$tmp"
            continue
        fi

        action="$(echo "$line" | awk '{print $1}')"
        pkg="$(echo "$line" | awk '{print $2}')"
        src="$(echo "$line" | awk '{print $3}')"
        # rebuild the trailing note text (fields 4+), collapsing the printf
        # column padding, then strip any previously-inserted "Name" — tag
        # so re-running enrich stays idempotent instead of stacking tags
        rest="$(echo "$line" | awk '{ out=""; for (i=4; i<=NF; i++) out = out $i " "; print out }' \
            | sed -E 's/^"[^"]*" — //')"

        printf "Looking up %-45s ... " "$pkg" >&2
        name="$(fetch_app_name "$pkg")"
        ((looked_up++))

        if [[ -n "$name" ]]; then
            echo "$name" >&2
            ((found++))
            printf "%-10s %-45s %-12s \"%s\" — %s\n" "$action" "$pkg" "$src" "$name" "$rest" >> "$tmp"
        else
            echo "(not found)" >&2
            printf "%-10s %-45s %-12s %s\n" "$action" "$pkg" "$src" "$rest" >> "$tmp"
        fi

        sleep 0.3   # be polite, avoid hammering either store
    done < "$CONFIG_FILE"

    mv "$tmp" "$CONFIG_FILE"
    echo
    echo "Looked up: $looked_up, names found: $found"
    echo "Updated $CONFIG_FILE — review the (\"App Name\") tags, then edit PORT/SKIP as needed."
}

cmd_pull() {
    [[ -f "$CONFIG_FILE" ]] || { echo "Missing $CONFIG_FILE — run 'plan' first."; exit 1; }
    require_adb
    local serial
    serial="$(resolve_device_for_role "${1:-}" old)" || exit 1

    mkdir -p "$APK_DIR"
    local pulled=0 failed=0

    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        action="$(echo "$line" | awk '{print $1}')"
        pkg="$(echo "$line" | awk '{print $2}')"
        [[ "$action" != "PORT" ]] && continue

        printf "Pulling %-50s ... " "$pkg"
        paths="$(adb -s "$serial" shell pm path "$pkg" < /dev/null | sed 's/^package://' | tr -d '\r')"
        if [[ -z "$paths" ]]; then
            echo "FAILED (no path — app missing or protected on old device)"
            ((failed++))
            continue
        fi

        pkg_dir="$APK_DIR/$pkg"
        mkdir -p "$pkg_dir"
        ok=true
        while IFS= read -r remote_path; do
            [[ -z "$remote_path" ]] && continue
            fname="$(basename "$remote_path")"
            adb -s "$serial" pull "$remote_path" "$pkg_dir/$fname" >/dev/null 2>&1 || ok=false
        done <<< "$paths"

        if $ok; then
            echo "OK"
            ((pulled++))
        else
            echo "FAILED (pull error)"
            ((failed++))
        fi
    done < "$CONFIG_FILE"

    echo
    echo "Pulled: $pulled, Failed: $failed"
    echo "APKs saved under $APK_DIR/<package>/"
    echo "Whenever the new device is connected, run: ./run.sh migrate install <new_serial>"
}

cmd_install() {
    [[ -f "$CONFIG_FILE" ]] || { echo "Missing $CONFIG_FILE — run 'plan' first."; exit 1; }
    [[ -d "$APK_DIR" ]] || { echo "Missing $APK_DIR — run 'pull' first."; exit 1; }
    require_adb
    local serial
    serial="$(resolve_device_for_role "${1:-}" new)" || exit 1

    # Snapshot what's already installed once up front, so re-running
    # after a batch that failed partway through doesn't re-push apps
    # that already made it onto the device — this makes `install` safe
    # to just re-run as many times as needed until everything's done.
    echo "Checking what's already installed on the device..."
    local already_installed_set
    already_installed_set="$(adb -s "$serial" shell pm list packages < /dev/null | sed 's/^package://' | tr -d '\r')"

    local installed=0 already_ok=0 failed=0 missing=0

    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        action="$(echo "$line" | awk '{print $1}')"
        pkg="$(echo "$line" | awk '{print $2}')"
        [[ "$action" != "PORT" ]] && continue

        if echo "$already_installed_set" | grep -qx "$pkg"; then
            echo "Skipping $pkg (already installed)"
            ((already_ok++))
            continue
        fi

        pkg_dir="$APK_DIR/$pkg"
        if [[ ! -d "$pkg_dir" ]] || [[ -z "$(ls -A "$pkg_dir" 2>/dev/null)" ]]; then
            echo "Skipping $pkg (no APK pulled — run 'pull' first or check earlier failures)"
            ((missing++))
            continue
        fi

        printf "Installing %-50s ... " "$pkg"
        apk_count=$(ls "$pkg_dir"/*.apk 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$apk_count" -gt 1 ]]; then
            out="$(adb -s "$serial" install-multiple "$pkg_dir"/*.apk 2>&1)"
        else
            out="$(adb -s "$serial" install "$pkg_dir"/*.apk 2>&1)"
        fi

        if echo "$out" | grep -qi "Success"; then
            echo "OK"
            ((installed++))
        else
            echo "FAILED (${out})"
            ((failed++))
        fi
    done < "$CONFIG_FILE"

    echo
    echo "Installed this run: $installed, Already installed: $already_ok, Failed: $failed, Skipped (no APK): $missing"
    echo "Note: apps that check their installer source (banking, some messengers)"
    echo "may still refuse to run or nag about reinstalling from an official store."
}

cmd_status() {
    echo "State dir: $STATE_DIR"
    echo
    [[ -f "$OLD_FILE" ]] && echo "old_packages.tsv: $(wc -l < "$OLD_FILE" | tr -d ' ') packages" || echo "old_packages.tsv: not yet scanned"
    [[ -f "$NEW_FILE" ]] && echo "new_packages.txt: $(wc -l < "$NEW_FILE" | tr -d ' ') packages" || echo "new_packages.txt: not yet scanned"
    if [[ -f "$CONFIG_FILE" ]]; then
        local port_count skip_count
        port_count=$(grep -c "^PORT" "$CONFIG_FILE" 2>/dev/null || echo 0)
        skip_count=$(grep -c "^SKIP" "$CONFIG_FILE" 2>/dev/null || echo 0)
        echo "migration_config.txt: $port_count marked PORT, $skip_count marked SKIP"
    else
        echo "migration_config.txt: not yet planned"
    fi
    if [[ -d "$APK_DIR" ]]; then
        echo "apk_transfer/: $(ls "$APK_DIR" 2>/dev/null | wc -l | tr -d ' ') package folders pulled"
    else
        echo "apk_transfer/: nothing pulled yet"
    fi
}

CMD="${1:-}"
shift || true
case "$CMD" in
    scan-old) cmd_scan_old "$@" ;;
    scan-new) cmd_scan_new "$@" ;;
    plan) cmd_plan "$@" ;;
    enrich) cmd_enrich "$@" ;;
    pull) cmd_pull "$@" ;;
    install) cmd_install "$@" ;;
    status) cmd_status "$@" ;;
    *) usage; exit 1 ;;
esac
