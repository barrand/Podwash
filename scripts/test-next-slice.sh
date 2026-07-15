#!/bin/sh
# Tests for scripts/next-slice.sh.
#
# Pure shell — no Xcode/simulator needed, so this runs anywhere (including CI).
# Uses synthetic fixture slice files in a temp dir (via PODWASH_SLICES_DIR) so
# cases are deterministic and independent of live repo state, plus one smoke
# test against the real docs/slices/.
#
# Usage: scripts/test-next-slice.sh   (exits nonzero if any case fails)

set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$REPO_ROOT"

NEXT="$REPO_ROOT/scripts/next-slice.sh"

PASS=0
FAIL=0

WORK=$(mktemp -d "${TMPDIR:-/tmp}/next-slice-tests.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

# make_slice <dir> <id> <status> <green:0|1> <title> <deps-bullet-text>
# Writes a minimal but format-faithful slice file.
make_slice() {
    _dir=$1; _id=$2; _status=$3; _green=$4; _title=$5; _deps=$6
    _pad=$(printf '%02d' "$_id")
    _file="$_dir/slice-${_pad}-fixture.md"
    {
        printf '# Slice %s — %s\n\n' "$_pad" "$_title"
        printf '| Field | Value |\n|-------|-------|\n'
        printf '| **ID** | %s |\n' "$_pad"
        printf '| **Title** | %s |\n' "$_title"
        printf '| **Status** | %s |\n\n' "$_status"
        printf '## Depends on\n\n'
        printf -- '- %s\n\n' "$_deps"
        printf '**Parallelizable:** Slices 98, 99 (note text — must NOT be parsed as deps)\n\n'
        printf '## Verification record\n\n'
        if [ "$_green" = "1" ]; then
            printf 'VERIFY RESULT: exit=0 total=5 passed=5 failed=0 skipped=0 filtered=0 bundle=build/x.xcresult\n'
        else
            printf 'VERIFY RESULT: (pending)\n'
        fi
    } > "$_file"
}

# assert_json <label> <slices-dir> <needle1> [needle2 ...]
assert_json() {
    _label=$1; _dir=$2; shift 2
    _out=$(PODWASH_SLICES_DIR="$_dir" "$NEXT" --json)
    _ok=1
    for _needle in "$@"; do
        case "$_out" in
            *"$_needle"*) : ;;
            *) _ok=0 ;;
        esac
    done
    if [ "$_ok" = 1 ]; then
        PASS=$((PASS + 1))
        printf 'PASS  %s\n' "$_label"
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL  %s\n      output: %s\n      wanted: %s\n' "$_label" "$_out" "$*"
    fi
}

# ---- case 1: start (lowest eligible) ---------------------------------------
D1="$WORK/case1"; mkdir -p "$D1"
make_slice "$D1" 1 Done  1 "Foundation" "None"
make_slice "$D1" 2 Draft 0 "Matching"   "Slice 01"
assert_json "start: 01 Done -> next is 02" "$D1" '"action":"start"' '"id":2'

# ---- case 2: sequencing (02 done unlocks 03) -------------------------------
D2="$WORK/case2"; mkdir -p "$D2"
make_slice "$D2" 1 Done  1 "Foundation" "None"
make_slice "$D2" 2 Draft 0 "Matching"   "Slice 01"
make_slice "$D2" 3 Draft 0 "Player"     "Slice 02"
assert_json "seq: before 02 done -> start 02" "$D2" '"action":"start"' '"id":2'
make_slice "$D2" 2 Done 1 "Matching" "Slice 01"
assert_json "seq: after 02 done -> start 03" "$D2" '"action":"start"' '"id":3'

# ---- case 3: wait (only a blocked slice exists) ----------------------------
D3="$WORK/case3"; mkdir -p "$D3"
make_slice "$D3" 7 Draft 0 "Pipeline" "Slices 05, 02"
assert_json "wait: 07 blocked by missing 05 and 02" "$D3" '"action":"wait"' '"id":7' '"blocked_by":[5,2]'

# ---- case 4: start (slice 15 gate resolved — deps met -> start) ------------
D4="$WORK/case4"; mkdir -p "$D4"
make_slice "$D4" 2  Done  1 "Matching" "Slice 01"
make_slice "$D4" 11 Done  1 "Queue"    "Slices 03, 06"
make_slice "$D4" 14 Done  1 "Background" "Slices 03, 11"
make_slice "$D4" 15 Draft 0 "CarPlay" "Slices 11, 14"
assert_json "start: slice 15 deps met (gate resolved)" "$D4" '"action":"start"' '"id":15'

# ---- case 4b: skip deferred (slice 17 post-MVP; next eligible is 16) --------
D4B="$WORK/case4b"; mkdir -p "$D4B"
make_slice "$D4B" 8  Done  1 "Playback" "Slice 07"
make_slice "$D4B" 13 Done  1 "Settings" "Slice 12"
make_slice "$D4B" 16 Draft 0 "Beep" "Slice 08"
{
    make_slice "$D4B" 17 Draft 0 "StoreKit" "Slice 13"
    # Override status to match deferred post-MVP slices in the real repo.
    sed -i '' 's/| \*\*Status\*\* | Draft |/| **Status** | Deferred — **post-MVP** |/' \
        "$D4B/slice-17-fixture.md"
} 2>/dev/null || {
    make_slice "$D4B" 17 Draft 0 "StoreKit" "Slice 13"
    sed -i 's/| \*\*Status\*\* | Draft |/| **Status** | Deferred — **post-MVP** |/' \
        "$D4B/slice-17-fixture.md"
}
assert_json "skip: deferred slice 17 -> start 16" "$D4B" '"action":"start"' '"id":16'

# ---- case 5: done (everything complete) ------------------------------------
D5="$WORK/case5"; mkdir -p "$D5"
make_slice "$D5" 1 Done 1 "Foundation" "None"
make_slice "$D5" 2 Done 1 "Matching"   "Slice 01"
assert_json "done: all slices Done" "$D5" '"action":"done"'

# ---- case 5b: done (only deferred slices remain) ----------------------------
# A deferred/post-MVP slice must not count as "lowest remaining" — that used to
# produce a perpetual {"action":"wait","blocked_by":[]} that spun the forge loop.
D5B="$WORK/case5b"; mkdir -p "$D5B"
make_slice "$D5B" 13 Done  1 "Settings" "None"
make_slice "$D5B" 17 "Deferred — **post-MVP**" 0 "StoreKit" "Slice 13"
assert_json "done: deferred-only remainder is done, not wait" "$D5B" '"action":"done"'

# ---- case 6: half-finished slice does NOT count as done --------------------
# Status Done but verification not green -> treated as not-done, so the queue
# surfaces slice 01 to finish rather than advancing to slice 02.
D6="$WORK/case6"; mkdir -p "$D6"
make_slice "$D6" 1 Done  0 "Foundation" "None"   # Done status but no green verify
make_slice "$D6" 2 Draft 0 "Matching"   "Slice 01"
assert_json "guard: Done-without-green does not advance to 02" "$D6" '"action":"start"' '"id":1'

# ---- case 7: smoke test against the real repo ------------------------------
# Live queue state moves, so only assert the script parses the real slices dir
# and emits a well-formed decision (any action) without erroring.
assert_json "smoke: real repo emits a decision" "$REPO_ROOT/docs/slices" '"action":"'

# ---- summary ---------------------------------------------------------------
echo ""
echo "================ next-slice tests ================"
printf '  passed: %d   failed: %d\n' "$PASS" "$FAIL"
echo "=================================================="
[ "$FAIL" -eq 0 ]
