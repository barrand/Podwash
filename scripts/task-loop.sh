#!/bin/sh
# Thin alias → unified forge loop (kept for scripts/docs that still say task-loop).
set -eu
REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$REPO_ROOT"
exec "$REPO_ROOT/scripts/forge.sh" "$@"
