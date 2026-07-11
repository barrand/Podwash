#!/bin/sh
# PodWash slice loop wrapper — Phase 2 of the slice runner.
#
# Sets up an isolated venv with the Cursor SDK, then runs the Forge supervisor
# (Medic self-heal on by default) → scripts/slice_loop.py.
# All arguments are passed through (supervisor strips its own flags).
#
# Usage:
#   scripts/slice-loop.sh                 # run the queue (Medic on by default)
#   scripts/slice-loop.sh --dry-run       # show the next decision; spawns no agent
#   scripts/slice-loop.sh --max 3         # run at most 3 slices this session
#   scripts/slice-loop.sh --verbose       # also stream full coordinator text
#   scripts/slice-loop.sh --heartbeat 60  # idle ping every 60s (0 to disable)
#   scripts/slice-loop.sh --stream-timeout 0  # disable bridge stream idle cap (default)
#   scripts/slice-loop.sh --max-red-verifies 2  # halt after N red verifies (default 2)
#   scripts/slice-loop.sh --no-self-heal  # plain slice_loop — no Medic on halt
#   scripts/slice-loop.sh --medic-no-push # Medic commits heal locally, skips push
#
# Auth (non-dry-run): export CURSOR_API_KEY=cursor_...
#
# Requires Python 3.10+ for cursor-sdk (macOS /usr/bin/python3 is often 3.9).
# Override: PODWASH_PYTHON=python3.12 scripts/slice-loop.sh
#
# The venv lives under build/ (gitignored). --dry-run needs neither the SDK nor
# a network connection, so it skips the venv entirely.

set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$REPO_ROOT"

SUPERVISOR_PY="$REPO_ROOT/scripts/forge_supervisor.py"
REQS="$REPO_ROOT/scripts/slice-loop-requirements.txt"
VENV="$REPO_ROOT/build/.slice-loop-venv"

# Pick a Python >= 3.10 (cursor-sdk has no wheels for 3.9).
find_python310() {
    if [ -n "${PODWASH_PYTHON:-}" ]; then
        if "$PODWASH_PYTHON" -c 'import sys; exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null; then
            printf '%s' "$PODWASH_PYTHON"
            return 0
        fi
        echo "slice-loop.sh: PODWASH_PYTHON=$PODWASH_PYTHON is not Python 3.10+" >&2
        return 1
    fi
    for candidate in python3.13 python3.12 python3.11 python3.10 python3; do
        if command -v "$candidate" >/dev/null 2>&1 \
            && "$candidate" -c 'import sys; exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    echo "slice-loop.sh: cursor-sdk requires Python 3.10+." >&2
    echo "  macOS /usr/bin/python3 is often 3.9 — install Python 3.12+ (brew install python@3.12)" >&2
    echo "  or set PODWASH_PYTHON=python3.12" >&2
    return 1
}

# --dry-run imports no SDK — any python3 is fine (still via supervisor).
for arg in "$@"; do
    if [ "$arg" = "--dry-run" ]; then
        exec python3 "$SUPERVISOR_PY" "$@"
    fi
done

PYTHON=$(find_python310) || exit 1

venv_ok() {
    [ -x "$VENV/bin/python" ] \
        && "$VENV/bin/python" -c 'import sys; exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null \
        && "$VENV/bin/python" -c 'import cursor_sdk' 2>/dev/null
}

if ! venv_ok; then
    if [ -d "$VENV" ]; then
        echo "slice-loop.sh: recreating venv ($PYTHON required; old venv unusable)"
        rm -rf "$VENV"
    else
        echo "slice-loop.sh: creating venv at $VENV ($PYTHON)"
    fi
    "$PYTHON" -m venv "$VENV"
    "$VENV/bin/pip" install -q --disable-pip-version-check --upgrade pip
    "$VENV/bin/pip" install -q --disable-pip-version-check -r "$REQS"
fi

exec "$VENV/bin/python" "$SUPERVISOR_PY" "$@"
