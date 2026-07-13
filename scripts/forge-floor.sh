#!/bin/sh
# Launch Forge Floor mission control at http://127.0.0.1:7420
set -eu
REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$REPO_ROOT"
exec python3 "$REPO_ROOT/scripts/factory_floor/server.py" "$@"
