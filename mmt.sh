#!/usr/bin/env bash
#
# mmt.sh — single entry point for the toolkit. Every script also runs
# standalone (./debloat.sh, ./migrate.sh, ./devices.sh) if you prefer
# that directly; this just saves remembering which file does what.
#
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<EOF
Usage: $0 <tool> [args]

Tools:
  devices   Manage saved device labels + catalog templates
  debloat   Declarative debloat reconciler
  migrate   Multipass app migration between devices

Examples:
  $0 devices init
  $0 debloat status redmi15c
  $0 debloat apply redmi15c
  $0 migrate scan-old old-pixel
  $0 migrate scan-new redmi15c
  $0 migrate plan

Run '$0 <tool>' with no further args to see that tool's own usage.
EOF
}

TOOL="${1:-}"
shift || true

case "$TOOL" in
    devices) exec "$SCRIPT_DIR/devices.sh" "$@" ;;
    debloat) exec "$SCRIPT_DIR/debloat.sh" "$@" ;;
    migrate) exec "$SCRIPT_DIR/migrate.sh" "$@" ;;
    *) usage; exit 1 ;;
esac
