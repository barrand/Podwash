#!/bin/sh
# Unified Forge entry (Sequel 1.5b scaffold).
#
# MVP: aliases to task-loop (tasks only). When PODWASH_FORGE_UNIFIED=1, runs
# forge_loop.py which can dispatch slices too (slice monopolize).
set -eu
REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$REPO_ROOT"

if [ "${PODWASH_FORGE_UNIFIED:-0}" = "1" ]; then
  export PODWASH_FORGE_LOOP=forge_loop
  exec "$REPO_ROOT/scripts/slice-loop.sh" "$@"
fi

exec "$REPO_ROOT/scripts/task-loop.sh" "$@"
