#!/bin/sh
# Unified Forge entry — one serial runner for tasks + slices.
#
# scripts/forge.sh → forge_loop.py (via Medic supervisor).
# Legacy aliases: task-loop.sh / slice-loop.sh still work but prefer this.
set -eu
REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$REPO_ROOT"

export PODWASH_FORGE_LOOP=forge_loop
export PODWASH_FORGE_UNIFIED=1
exec "$REPO_ROOT/scripts/slice-loop.sh" "$@"
