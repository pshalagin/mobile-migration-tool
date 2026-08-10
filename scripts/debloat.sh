#!/usr/bin/env bash
#
# scripts/debloat.sh — declarative, idempotent ADB debloat reconciler.
# Run via ./run.sh debloat <command> — see run.sh at the repo root.
#
# Each device gets its own catalog (package <TAB> desired state <TAB>
# category <TAB> note), seeded from a templates/*.tsv template at
# init time and stored at state/catalogs/<label>.tsv — editable
# independently per device from then on. Desired states:
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
#   keep      -> must stay present & enabled. `status` only reports
#                drift (dry run, no changes). `apply` actively tries
#                to restore it: `pm enable` if it's just disabled,
#                `pm install-existing` if it's missing entirely. If
#                install-existing fails, the package is gone from the
#                system partition and can't be auto-restored — that
#                still gets flagged as a warning instead of silently
#                failing.
#   optional  -> present by default, no action taken. These are
#                feature-dependent apps where there's no universally
#                right answer — edit the catalog yourself and flip
#                the state to `absent` for anything you don't use.
#
# Run against real device state every time — safe to re-run as often
# as you want; already-satisfied rows are no-ops.
#
# Usage:
#   debloat.sh status [serial-or-label]   Compare catalog vs device, no changes
#   debloat.sh apply  [serial-or-label]   Reconcile device to match its catalog
#   debloat.sh list   [state]             Print the catalog (optionally filtered), no device needed
#
# The device arg is optional if exactly one ADB device is connected.
# Run ./run.sh devices init once to label devices and pick their
# catalog template — see lib/resolve_device.sh.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/resolve_device.sh"

DEFAULT_TEMPLATE="$REPO_ROOT/templates/redmi15c.tsv"
DB_FILE=""   # resolved per-invocation in resolve_catalog()

usage() {
    cat <<EOF
Usage: ./run.sh debloat <command> [args]

Commands:
  status [serial-or-label]   Dry-run: compare the device's catalog
                    against the device, report drift, change nothing.
                    Device arg optional if only one is connected.
  apply  [serial-or-label]   Reconcile the device to match its catalog.
                    Idempotent — safe to re-run any time.
  list   [state]    Print the resolved catalog. Optionally filter by
                    state (absent|disabled|keep|optional). No device
                    needed if DEBLOAT_DB is set or only one device is
                    registered/connected.

Env:
  DEBLOAT_DB   Force a specific catalog file, skipping device-based lookup.

Catalog resolution order: \$DEBLOAT_DB env override -> the catalog
registered for this device in state/devices.tsv (set via ./run.sh devices init)
-> $DEFAULT_TEMPLATE as a last-resort default.
EOF
}

require_adb() {
    command -v adb >/dev/null 2>&1 || { echo "adb not found in PATH."; exit 1; }
}

# Sets global DB_FILE for the given resolved serial (may be empty if
# called from a device-less context — falls back to default template).
resolve_catalog() {
    local serial="${1:-}"

    if [[ -n "${DEBLOAT_DB:-}" ]]; then
        DB_FILE="$DEBLOAT_DB"
    elif [[ -n "$serial" ]]; then
        local cat
        cat="$(catalog_for_serial "$serial")"
        if [[ -n "$cat" && -f "$REPO_ROOT/$cat" ]]; then
            DB_FILE="$REPO_ROOT/$cat"
        else
            DB_FILE="$DEFAULT_TEMPLATE"
            echo "No catalog registered for this device — using default template ($DB_FILE)." >&2
            echo "Run ./run.sh devices init to set up a proper per-device catalog." >&2
        fi
    else
        DB_FILE="$DEFAULT_TEMPLATE"
    fi

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
    resolve_catalog ""
    local filter="${1:-}"
    echo "Catalog: $DB_FILE" >&2
    awk -F'\t' -v filter="$filter" '
        NR==1 { next }
        filter=="" || $2==filter {
            printf "%-9s %-50s %-22s %s\n", $2, $1, $3, $4
        }
    ' "$DB_FILE"
}

cmd_status() {
    require_adb
    local serial
    serial="$(resolve_device "${1:-}")" || exit 1
    resolve_catalog "$serial"

    echo "Device: $serial"
    echo "Catalog: $DB_FILE"
    echo "Snapshotting device..."
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
    [[ "$drift" -gt 0 ]] && echo "Run './run.sh debloat apply $serial' to reconcile."
}

cmd_apply() {
    require_adb
    local serial
    serial="$(resolve_device "${1:-}")" || exit 1
    resolve_catalog "$serial"

    echo "Device: $serial"
    echo "Catalog: $DB_FILE"
    echo "Snapshotting device..."
    snapshot_device "$serial"
    echo

    local removed=0 disabled=0 already_ok=0 fallback=0 restored=0 warned=0 failed=0

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
                elif pkg_installed "$pkg" && pkg_disabled "$pkg"; then
                    printf "Restoring (enable) %-50s ... " "$pkg"
                    out="$(adb -s "$serial" shell pm enable --user 0 "$pkg" 2>&1 < /dev/null)"
                    if echo "$out" | grep -qiE "new state: enabled"; then
                        echo "OK"; ((restored++))
                    else
                        echo "FAILED (${out}) — $note"
                        ((warned++))
                    fi
                else
                    printf "Restoring (install-existing) %-50s ... " "$pkg"
                    out="$(adb -s "$serial" shell pm install-existing --user 0 "$pkg" 2>&1 < /dev/null)"
                    if echo "$out" | grep -qi "installed for user"; then
                        echo "OK"; ((restored++))
                    else
                        echo "FAILED (not on system partition, can't auto-restore: ${out}) — $note"
                        ((warned++))
                    fi
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
    echo "Restored this run:       $restored  (keep-state packages that were missing/disabled)"
    echo "Already in desired state: $already_ok"
    echo "Critical package warnings: $warned  (keep-state, couldn't auto-restore — see FAILED lines above)"
    echo "Genuine failures:         $failed"
    echo
    echo "Packages warned above are usually gone from the system partition entirely"
    echo "(pm install-existing can only restore what's still there) — reinstalling"
    echo "those needs a real APK or a factory-image extraction."
}

CMD="${1:-}"
shift || true
case "$CMD" in
    status) cmd_status "$@" ;;
    apply) cmd_apply "$@" ;;
    list) cmd_list "$@" ;;
    *) usage; exit 1 ;;
esac
