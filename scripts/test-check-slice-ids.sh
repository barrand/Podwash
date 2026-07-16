#!/bin/sh
# Tests for scripts/check-slice-ids.sh (no Xcode).
#
# Usage: scripts/test-check-slice-ids.sh

set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CHECK="$REPO_ROOT/scripts/check-slice-ids.sh"

PASS=0
FAIL=0

assert_exit() {
    want=$1
    shift
    set +e
    out=$(PODWASH_SLICES_DIR="$SLICES" PODWASH_REPO_ROOT="$WORK" "$CHECK" 2>&1)
    got=$?
    set -e
    if [ "$got" -eq "$want" ]; then
        PASS=$((PASS + 1))
        echo "PASS: $* → exit $got"
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $* → exit $got (want $want)" >&2
        echo "$out" >&2
    fi
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/check-slice-ids.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

SLICES="$WORK/slices"
mkdir -p "$SLICES"

cat > "$SLICES/slice-01-good.md" <<'EOF'
# Slice 01 — Good
| Field | Value |
|-------|-------|
| **ID** | 1 |
| **Status** | Ready |
EOF

assert_exit 0 "single valid slice"

cat > "$SLICES/slice-02-dup-a.md" <<'EOF'
# Slice 02 — A
| Field | Value |
|-------|-------|
| **ID** | 2 |
| **Status** | Ready |
EOF

cat > "$SLICES/slice-02-dup-b.md" <<'EOF'
# Slice 02 — B
| Field | Value |
|-------|-------|
| **ID** | 2 |
| **Status** | Draft |
EOF

assert_exit 1 "duplicate slice-02 prefix"

rm -f "$SLICES/slice-02-dup-b.md"

cat > "$SLICES/slice-03-mismatch.md" <<'EOF'
# Slice 03 — Mismatch
| Field | Value |
|-------|-------|
| **ID** | 99 |
| **Status** | Ready |
EOF

assert_exit 1 "filename vs metadata mismatch"

# Real repo must pass.
set +e
out=$(PODWASH_SLICES_DIR="$REPO_ROOT/docs/slices" "$CHECK" 2>&1)
got=$?
set -e
if [ "$got" -eq 0 ]; then
    PASS=$((PASS + 1))
    echo "PASS: production docs/slices → exit 0"
else
    FAIL=$((FAIL + 1))
    echo "FAIL: production docs/slices → exit $got" >&2
    echo "$out" >&2
fi

echo "check-slice-ids tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
