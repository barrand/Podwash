#!/bin/sh
# PodWash test-isolation check — anti-cheat gate for the dark factory.
#
# Fails if a commit (or the working tree) changes BOTH production app sources
# and test sources in the same change set. Agents must not bend tests while
# implementing, or implement while rewriting tests.
#
# Usage:
#   scripts/check-test-isolation.sh              # check HEAD commit
#   scripts/check-test-isolation.sh --staged      # check index (pre-commit)
#   scripts/check-test-isolation.sh --working     # check unstaged + staged + untracked
#   scripts/check-test-isolation.sh <sha>         # check one commit
#   scripts/check-test-isolation.sh <base>..<tip> # check every commit in range (CI)
#
# Neutral paths (docs, scripts, xcodeproj, rules) may appear with either side.
# Only PodWash/PodWash/ vs PodWash/{PodWashTests,PodWashUITests,PodWashSlowTests}/
# are mutually exclusive within one commit / change set.

set -eu

# Allow tests / alternate checkouts to override (default: repo containing this script).
if [ -n "${PODWASH_REPO_ROOT:-}" ]; then
    REPO_ROOT=$PODWASH_REPO_ROOT
else
    REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fi
cd "$REPO_ROOT"

is_app() {
    case "$1" in
        PodWash/PodWash/*) return 0 ;;
        *) return 1 ;;
    esac
}

is_test() {
    case "$1" in
        PodWash/PodWashTests/*|PodWash/PodWashUITests/*|PodWash/PodWashSlowTests/*) return 0 ;;
        *) return 1 ;;
    esac
}

fail_mixed() {
    label=$1
    echo "check-test-isolation: FAIL — $label touches BOTH app and tests" >&2
    echo "  App and tests must land in separate commits (slice-NN: test spec vs slice-NN: implement)." >&2
    echo "  This blocks the common cheat of editing tests to make implementation pass." >&2
    exit 1
}

check_paths() {
    label=$1
    paths=$2
    has_app=0
    has_test=0
    # Use a here-doc so the loop is not in a pipe subshell (flags must stick).
    while IFS= read -r path || [ -n "$path" ]; do
        [ -z "$path" ] && continue
        if is_app "$path"; then has_app=1; fi
        if is_test "$path"; then has_test=1; fi
    done <<EOF
$paths
EOF
    if [ "$has_app" -eq 1 ] && [ "$has_test" -eq 1 ]; then
        fail_mixed "$label"
    fi
    shown=
    [ "$has_app" -eq 1 ] && shown="${shown} app"
    [ "$has_test" -eq 1 ] && shown="${shown} test"
    echo "check-test-isolation: OK — $label (classes:${shown:- none})"
}

MODE=${1:-HEAD}

case "$MODE" in
    --staged)
        PATHS=$(git diff --cached --name-only --diff-filter=ACDMR)
        check_paths "staged changes" "$PATHS"
        ;;
    --working)
        PATHS=$(
            {
                git diff --name-only --diff-filter=ACDMR
                git diff --cached --name-only --diff-filter=ACDMR
                git ls-files --others --exclude-standard
            } | sort -u
        )
        check_paths "working tree" "$PATHS"
        ;;
    *..*)
        # Range: check each commit individually (merge commits skipped if empty tree diff)
        BASE=${MODE%%..*}
        TIP=${MODE#*..}
        [ -z "$BASE" ] && BASE=HEAD
        [ -z "$TIP" ] && TIP=HEAD
        COMMITS=$(git rev-list --reverse "${BASE}..${TIP}")
        if [ -z "$COMMITS" ]; then
            echo "check-test-isolation: OK — empty range ${BASE}..${TIP}"
            exit 0
        fi
        # No pipe: a failing check_paths must exit this script (set -e).
        for sha in $COMMITS; do
            PATHS=$(git diff-tree --no-commit-id --name-only -r "$sha")
            SHORT=$(git rev-parse --short "$sha")
            SUBJ=$(git log -1 --format=%s "$sha")
            check_paths "commit $SHORT ($SUBJ)" "$PATHS"
        done
        ;;
    *)
        # Single ref (default HEAD) or explicit SHA
        REF=$MODE
        if [ "$REF" = "HEAD" ] || git rev-parse --verify "$REF" >/dev/null 2>&1; then
            PATHS=$(git diff-tree --no-commit-id --name-only -r "$REF")
            SHORT=$(git rev-parse --short "$REF")
            SUBJ=$(git log -1 --format=%s "$REF")
            check_paths "commit $SHORT ($SUBJ)" "$PATHS"
        else
            echo "check-test-isolation: unknown mode or ref: $MODE" >&2
            echo "Usage: $0 [--staged|--working|HEAD|<sha>|<base>..<tip>]" >&2
            exit 2
        fi
        ;;
esac
