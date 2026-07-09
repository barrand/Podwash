#!/bin/sh
# Tests for scripts/check-test-isolation.sh (no Xcode).
#
# Usage: scripts/test-check-test-isolation.sh

set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CHECK="$REPO_ROOT/scripts/check-test-isolation.sh"

PASS=0
FAIL=0

assert_exit() {
    want=$1
    shift
    set +e
    out=$(PODWASH_REPO_ROOT="$WORK" "$@" 2>&1)
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

WORK=$(mktemp -d "${TMPDIR:-/tmp}/check-test-isolation.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

cd "$WORK"
git init -q
git config user.email "test@example.com"
git config user.name "Test"
# Avoid depending on global defaultBranch.
git checkout -q -b main

mkdir -p PodWash/PodWash PodWash/PodWashTests docs
echo "app" > PodWash/PodWash/App.swift
echo "test" > PodWash/PodWashTests/AppTests.swift
echo "doc" > docs/note.md
git add .
git commit -q -m "seed"

# Mixed commit must fail.
echo "app2" > PodWash/PodWash/App.swift
echo "test2" > PodWash/PodWashTests/AppTests.swift
git add .
git commit -q -m "mixed bad"
assert_exit 1 "$CHECK" HEAD

# Reset to seed and make app-only commit — must pass.
git reset -q --hard HEAD~1
echo "app3" > PodWash/PodWash/App.swift
git add PodWash/PodWash/App.swift
git commit -q -m "app only"
assert_exit 0 "$CHECK" HEAD

# Test-only commit — must pass.
echo "test3" > PodWash/PodWashTests/AppTests.swift
git add PodWash/PodWashTests/AppTests.swift
git commit -q -m "test only"
assert_exit 0 "$CHECK" HEAD

# Docs + app — must pass (docs are neutral).
echo "doc2" > docs/note.md
echo "app4" > PodWash/PodWash/App.swift
git add docs/note.md PodWash/PodWash/App.swift
git commit -q -m "docs and app"
assert_exit 0 "$CHECK" HEAD

# Range with a mixed commit — must fail.
echo "app5" > PodWash/PodWash/App.swift
echo "test5" > PodWash/PodWashTests/AppTests.swift
git add .
git commit -q -m "mixed in range"
BASE=$(git rev-parse HEAD~3)
assert_exit 1 "$CHECK" "${BASE}..HEAD"

# Staged mixed — must fail.
git reset -q --hard HEAD~1
echo "app6" > PodWash/PodWash/App.swift
echo "test6" > PodWash/PodWashTests/AppTests.swift
git add .
assert_exit 1 "$CHECK" --staged

echo ""
echo "check-test-isolation tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
