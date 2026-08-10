#!/usr/bin/env bash
#
# run.sh — the single entry point for this toolkit.
#
#   ./run.sh                       Guided interactive wizard (wizard.py)
#   ./run.sh devices <command>     Advanced: device label/role registry
#   ./run.sh debloat <command>     Advanced: declarative debloat reconciler
#   ./run.sh migrate <command>     Advanced: multipass app migration
#
# The wizard and the advanced commands drive the exact same scripts
# under scripts/ — pick whichever's convenient, and mix and match
# (e.g. run the wizard once, then `./run.sh debloat apply` by hand
# later). See README.md for the full advanced-usage reference.
#
# All scripts live under scripts/; all local/generated state (device
# registry, per-device catalogs, migration working files) lives under
# state/ — nothing is written anywhere else in the repo.
#
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<EOF
Usage: $0 [tool] [args]

  (no args)           Run the guided interactive wizard
  devices <command>   Device label/role registry (see: $0 devices)
  debloat <command>   Declarative debloat reconciler (see: $0 debloat)
  migrate <command>   Multipass app migration (see: $0 migrate)

Examples:
  $0
  $0 devices init
  $0 debloat status redmi15c
  $0 migrate scan-old old-pixel
EOF
}

TOOL="${1:-}"

case "$TOOL" in
    "")
        if ! command -v python3 >/dev/null 2>&1; then
            echo "python3 not found in PATH — required for the guided wizard."
            echo "You can still use the toolkit directly: $0 devices|debloat|migrate ..."
            echo "(see README.md for the advanced/scripted workflow)."
            exit 1
        fi
        exec python3 "$SCRIPT_DIR/scripts/wizard.py"
        ;;
    devices|debloat|migrate)
        shift
        exec "$SCRIPT_DIR/scripts/$TOOL.sh" "$@"
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage
        exit 1
        ;;
esac
