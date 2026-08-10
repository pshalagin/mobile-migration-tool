#!/usr/bin/env bash
#
# debloat.sh — declarative, idempotent ADB debloat reconciler.
#
# packages.tsv is the single source of truth: package <TAB> desired
# state <TAB> category <TAB> note. Desired states:
#   absent    -> should not be present. Reconciler tries `pm uninstall`;
#                if that fails with the known "protected app" pattern
#                (Failure [-1000] / DELETE_FAILED_INTERNAL_ERROR), it
#                automatically falls back to `pm disable-user` instead
#                of just failing — no need to hand-maintain a separate
#                list of "apps that can't actually be removed".
#   disabled  -> should always be disable-user'd, regardless of
#                whether uninstall would work. Use this for apps you
#                want off but explicitly want kept recoverable (e.g.
#                a feature you might want back later).
#   keep      -> must stay present & enabled. No action taken, but
#                `status`/`apply` will WARN you if one of these is
#                found missing on the device — drift detection for
#                things you can't afford to lose.
#   optional  -> present by default, no action taken. These are
#                feature-dependent apps where there's no universally
#                right answer — edit packages.tsv yourself and flip
#                the state to `absent` for anything you don't use.
#
# Run against real device state every time — safe to re-run as often
# as you want; already-satisfied rows are no-ops.
#
# Usage:
#   ./debloat.sh status [serial-or-label]   Compare packages.tsv vs device, no changes
#   ./debloat.sh apply  [serial-or-label]   Reconcile device to match packages.tsv
#   ./debloat.sh list   [state]             Print the catalog (optionally filtered), no device needed
#
# The device arg is optional if exactly one ADB device is connected.
# For labels instead of typing raw serials, run ./devices.sh init once
# from the repo root (see lib/resolve_device.sh).
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB_FILE="${DEBLOAT_DB:-$SCRIPT_DIR/packages.tsv}"
source "$SCRIPT_DIR/../lib/resolve_device.sh"

usage() {
    cat <<EOF
Usage: $0 <command> [args]

Commands:
  status [serial-or-label]   Dry-run: compare packages.tsv against the
                    device, report drift per package, change nothing.
                    Device arg optional if only one is connected.
  apply  [serial-or-label]   Reconcile the device to match packages.tsv.
                    Idempotent — safe to re-run any time.
  list   [state]    Print the catalog. Optionally filter by state
                    (absent|disabled|keep|optional). No device needed.

Env:
  DEBLOAT_DB   Override the catalog file (default: $DB_FILE)

Tip: run ../devices.sh init once to label your device(s), then pass
the label instead of hunting down the serial each time.
EOF
}

require_adb() {
    command -v adb >/dev/null 2>&1 || { echo "adb not found in PATH."; exit 1; }
}

require_db() {
    [[ -f "$DB_FILE" ]] || { echo "Catalog not found: $DB_FILE"; exit 1; }
}

# Snapshot device state once per run: installed (any state) + explicitly disabled
snapshot_device() {
    local serial="$1"
    INSTALLED_ALL="$(adb -s "$serial" shell pm list packages < /dev/null | sed 's/^package://' | tr -d '\r')"
    DISABLED_SET="$(adb -s "$serial" shell pm list packages -d < /dev/null | sed 's/^package://' | tr -d '\r')"
}

pkg_installed() {
    echo "$INSTALLED_ALL" | grep -qx "$1"
}

pkg_disabled() {
    echo "$DISABLED_SET" | grep -qx "$1"
}

cmd_list() {
    require_db
    local filter="${1:-}"
    awk -F'\t' -v filter="$filter" '
        NR==1 { next }
        filter=="" || $2==filter {
            printf "%-9s %-50s %-22s %s\n", $2, $1, $3, $4
        }
    ' "$DB_FILE"
}

cmd_status() {
    require_db; require_adb
    local serial
    serial="$(resolve_device "${1:-}")" || exit 1

    echo "Snapshotting device ($serial)..."
    snapshot_device "$serial"
    echo

    printf "%-9s %-50s %-10s %s\n" "DESIRED" "PACKAGE" "ACTUAL" "STATUS"
    printf '%.0s-' {1..100}; echo

    local drift=0 ok=0
    while IFS=$'\t' read -r pkg state category note; do
        [[ "$pkg" == "package" ]] && continue   # header

        if pkg_installed "$pkg"; then
            if pkg_disabled "$pkg"; then actual="disabled"; else actual="enabled"; fi
        else
            actual="absent"
        fi

        case "$state" in
            absent)
                if [[ "$actual" == "absent" || "$actual" == "disabled" ]]; then
                    result="OK"; ((ok++))
                else
                    result="DRIFT (still installed & enabled)"; ((drift++))
                fi
                ;;
            disabled)
                if [[ "$actual" == "disabled" ]]; then
                    result="OK"; ((ok++))
                else
                    result="DRIFT (should be disabled)"; ((drift++))
                fi
                ;;
            keep)
                if [[ "$actual" == "enabled" ]]; then
                    result="OK"; ((ok++))
                else
                    result="DRIFT — CRITICAL PACKAGE MISSING/DISABLED ($note)"; ((drift++))
                fi
                ;;
            optional)
                result="(no action — your call)"
                ;;
        esac

        [[ "$state" == "optional" ]] || printf "%-9s %-50s %-10s %s\n" "$state" "$pkg" "$actual" "$result"
    done < "$DB_FILE"

    echo
    echo "In desired state: $ok, Drift: $drift"
    [[ "$drift" -gt 0 ]] && echo "Run '$0 apply $serial' to reconcile."
}

cmd_apply() {
    require_db; require_adb
    local serial
    serial="$(resolve_device "${1:-}")" || exit 1

    echo "Snapshotting device ($serial)..."
    snapshot_device "$serial"
    echo

    local removed=0 disabled=0 already_ok=0 fallback=0 warned=0 failed=0

    while IFS=$'\t' read -r pkg state category note; do
        [[ "$pkg" == "package" ]] && continue

        case "$state" in
            absent)
                if ! pkg_installed "$pkg"; then
                    ((already_ok++)); continue
                fi
                if pkg_disabled "$pkg"; then
                    ((already_ok++)); continue   # already neutralized, good enough
                fi

                printf "Removing %-50s ... " "$pkg"
                out="$(adb -s "$serial" shell pm uninstall -k --user 0 "$pkg" 2>&1 < /dev/null)"
                if echo "$out" | grep -qi "Success"; then
                    echo "OK"; ((removed++))
                elif echo "$out" | grep -qE "\-1000|DELETE_FAILED"; then
                    # known protected-app pattern -> auto fallback
                    fb_out="$(adb -s "$serial" shell pm disable-user --user 0 "$pkg" 2>&1 < /dev/null)"
                    if echo "$fb_out" | grep -qiE "new state: (disabled|hidden)"; then
                        echo "protected on this build, disabled instead"
                        ((fallback++))
                    else
                        echo "FAILED (uninstall: ${out} | disable fallback also failed: ${fb_out})"
                        ((failed++))
                    fi
                else
                    echo "FAILED (${out})"
                    ((failed++))
                fi
                ;;

            disabled)
                if pkg_disabled "$pkg" || ! pkg_installed "$pkg"; then
                    ((already_ok++)); continue
                fi
                printf "Disabling %-50s ... " "$pkg"
                out="$(adb -s "$serial" shell pm disable-user --user 0 "$pkg" 2>&1 < /dev/null)"
                if echo "$out" | grep -qiE "new state: (disabled|hidden)"; then
                    echo "OK"; ((disabled++))
                else
                    echo "FAILED (${out})"; ((failed++))
                fi
                ;;

            keep)
                if pkg_installed "$pkg" && ! pkg_disabled "$pkg"; then
                    ((already_ok++))
                else
                    echo "WARNING: critical package '$pkg' is missing/disabled — $note"
                    ((warned++))
                fi
                ;;

            optional)
                ;; # no action, ever, unless the file itself says otherwise
        esac
    done < "$DB_FILE"

    echo
    echo "==================== Summary ===================="
    echo "Removed this run:        $removed"
    echo "Disabled this run:       $disabled"
    echo "Fell back to disable:    $fallback  (uninstall blocked by OS, disabled instead)"
    echo "Already in desired state: $already_ok"
    echo "Critical package warnings: $warned"
    echo "Genuine failures:         $failed"
    echo
    echo "To restore anything: adb shell pm install-existing --user 0 <package>"
    echo "                  or: adb shell pm enable --user 0 <package>"
}

CMD="${1:-}"
shift || true
case "$CMD" in
    status) cmd_status "$@" ;;
    apply) cmd_apply "$@" ;;
    list) cmd_list "$@" ;;
    *) usage; exit 1 ;;
esac
