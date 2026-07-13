#!/bin/sh
# Forge task-loop — serial rapid tasks via Medic supervisor → task_loop.py.
#
# Usage:
#   scripts/task-loop.sh
#   scripts/task-loop.sh --dry-run
#   scripts/task-loop.sh --max 3
#   scripts/task-loop.sh --skip-batch-gate
#   scripts/task-loop.sh --no-self-heal
#
# Auth: export CURSOR_API_KEY=cursor_...

set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$REPO_ROOT"

export PODWASH_FORGE_LOOP=task_loop

# Reuse slice-loop venv + supervisor
exec "$REPO_ROOT/scripts/slice-loop.sh" "$@"
