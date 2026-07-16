#!/bin/sh
# DEPRECATED — thin alias → scripts/forge.sh
#
# The product runner is Forge Floor (Start Forge) or scripts/forge.sh.
# This wrapper remains so old docs/muscle memory keep working.
# Prefer: scripts/forge-floor.sh  or  scripts/forge.sh
#
# The legacy slice-only Python loop (slice_loop.py) is no longer the default;
# forge.sh always runs the unified forge_loop unless PODWASH_FORGE_LOOP is set.

set -eu
REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$REPO_ROOT"

echo "slice-loop.sh: deprecated — use scripts/forge.sh or Forge Floor → Start Forge" >&2
exec "$REPO_ROOT/scripts/forge.sh" "$@"
