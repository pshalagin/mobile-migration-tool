#!/usr/bin/env bash
#
# run.sh — entry point for the guided wizard. Thin shim: the actual
# interactive logic lives in wizard.py (Python — the branching/retry
# logic here got complicated enough that bash stopped being the right
# tool). Everything the wizard does, it does by calling the same
# devices.sh / debloat.sh / migrate.sh scripts you'd run by hand — see
# README.md for both the guided and advanced/scripted ways to use this
# repo.
#
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 not found in PATH — required for the guided wizard."
    echo "You can still use the toolkit directly: ./devices.sh, ./debloat.sh, ./migrate.sh"
    echo "(see README.md for the advanced/scripted workflow)."
    exit 1
fi

exec python3 "$SCRIPT_DIR/wizard.py" "$@"
