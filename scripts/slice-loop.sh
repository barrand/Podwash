#!/bin/sh
# PodWash slice loop wrapper — Phase 2 of the slice runner.
#
# Sets up an isolated venv with the Cursor SDK, then runs scripts/slice_loop.py.
# All arguments are passed through to the Python driver.
#
# Usage:
#   scripts/slice-loop.sh                 # run the queue until it stops
#   scripts/slice-loop.sh --dry-run       # show the next decision; spawns no agent
#   scripts/slice-loop.sh --max 3         # run at most 3 slices this session
#   scripts/slice-loop.sh --model auto    # let the server pick the coordinator model
#
# Auth (non-dry-run): export CURSOR_API_KEY=cursor_...
#
# The venv lives under build/ (gitignored). --dry-run needs neither the SDK nor
# a network connection, so it skips the venv entirely.

set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$REPO_ROOT"

LOOP_PY="$REPO_ROOT/scripts/slice_loop.py"
REQS="$REPO_ROOT/scripts/slice-loop-requirements.txt"
VENV="$REPO_ROOT/build/.slice-loop-venv"

# --dry-run imports no SDK — run it directly with system python3 for speed.
for arg in "$@"; do
    if [ "$arg" = "--dry-run" ]; then
        exec python3 "$LOOP_PY" "$@"
    fi
done

if [ ! -d "$VENV" ]; then
    echo "slice-loop.sh: creating venv at $VENV"
    python3 -m venv "$VENV"
fi

# Install/refresh deps (quiet; fast when already satisfied).
"$VENV/bin/pip" install -q --disable-pip-version-check -r "$REQS"

exec "$VENV/bin/python" "$LOOP_PY" "$@"
