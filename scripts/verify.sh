#!/bin/sh
# PodWash verification script — the single sanctioned way to run the test suite.
#
# Usage:
#   scripts/verify.sh                                   # FULL suite (tier 3 — required for Done)
#   scripts/verify.sh -only-testing:PodWashTests/FooTests   # fast slice loop (NOT sufficient for Done)
#
# Extra arguments are passed through to xcodebuild verbatim, so any number of
# -only-testing: filters may be given. A filtered run is for the fast inner
# loop only; a slice may be marked Done ONLY on a full-suite (unfiltered) green
# run of this script (VERIFY_TIER=3 / default).
#
# Environment overrides:
#   PODWASH_SIM=<simulator name>   force a specific simulator (default: first available iPhone)
#   VERIFY_ALLOW_SKIPS=1           tolerate skipped tests (nightly @slow job only; never for slice Done)
#   VERIFY_TIER=0|1|2|3            verification tier (default 3 = full Done gate)
#     0  build-for-testing only (-derivedDataPath build/dd)
#     1  test-without-building + VERIFY_FAILED_TESTS → -only-testing: (failed-tests-first)
#     2  filtered slice tests (args and/or VERIFY_SLICE_TESTS) + shared derived data
#     3  full unfiltered suite (Done gate); VERIFY RESULT line contract unchanged
#   VERIFY_FAILED_TESTS="A/b() C/d()"   space-separated test ids for tier 1
#   VERIFY_SLICE_TESTS="A/b() C/d()"    space-separated test ids for tier 2 (plus CLI args)
#   VERIFY_DERIVED_DATA=build/dd        shared derived data path (default build/dd)
#   VERIFY_DRY_RUN=1                    print resolved xcodebuild argv and exit 0 (unit tests)
#
# Behavior:
#   - Resolves an available iPhone simulator dynamically (no hardcoded device names).
#   - Writes a timestamped .xcresult bundle under build/test-results/ (gitignored).
#   - Retries flaky failures once (-retry-tests-on-failure -test-iterations 2) for tiers 1–3.
#   - Serializes concurrent runs with a lockfile (build/.verify.lock).
#   - Prints executed/passed/failed/skipped counts and a copy-pastable
#     "VERIFY RESULT" line for the slice file's verification record.
#   - Exits nonzero on any test failure, and on skipped tests unless
#     VERIFY_ALLOW_SKIPS=1.

set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$REPO_ROOT"

PROJECT="PodWash/PodWash.xcodeproj"
# Default scheme is the full app+fast-tests scheme (the slice Done gate). The nightly slow
# ASR benchmark job overrides this with PODWASH_SCHEME=PodWashSlowTests to run the
# otherwise-scheme-disabled slow target (a skipped="YES" TestableReference cannot be forced
# to run via -only-testing:, so the slow target has its own dedicated scheme).
SCHEME=${PODWASH_SCHEME:-PodWash}
BUILD_DIR="build"
RESULTS_DIR="$BUILD_DIR/test-results"
LOCK_DIR="$BUILD_DIR/.verify.lock"
DERIVED_DATA=${VERIFY_DERIVED_DATA:-$BUILD_DIR/dd}
VERIFY_TIER=${VERIFY_TIER:-3}

# ---------------------------------------------------------------- simulator --
SIM_NAME=${PODWASH_SIM:-}
if [ -z "$SIM_NAME" ]; then
    SIM_NAME=$(xcrun simctl list devices available \
        | sed -n 's/^[[:space:]]*\(iPhone[^(]*\)(.*/\1/p' \
        | sed 's/[[:space:]]*$//' \
        | head -n 1)
fi
if [ -z "$SIM_NAME" ]; then
    if [ "${VERIFY_DRY_RUN:-0}" = "1" ]; then
        SIM_NAME="iPhone 16"
    else
        echo "verify.sh: no available iPhone simulator found (xcrun simctl list devices available)" >&2
        exit 1
    fi
fi

# --------------------------------------------------------------------- lock --
mkdir -p "$BUILD_DIR"
cleanup() {
    rmdir "$LOCK_DIR" 2>/dev/null || true
}
if [ "${VERIFY_DRY_RUN:-0}" != "1" ]; then
    waited=0
    until mkdir "$LOCK_DIR" 2>/dev/null; do
        if [ "$waited" -eq 0 ]; then
            echo "verify.sh: another verify run holds the lock ($LOCK_DIR); waiting..."
        fi
        waited=$((waited + 2))
        if [ "$waited" -ge 1800 ]; then
            echo "verify.sh: timed out after 30 min waiting for lock" >&2
            exit 1
        fi
        sleep 2
    done
    trap cleanup EXIT INT TERM
fi

# --------------------------------------------------------------- tier setup --
FILTERED=0
XCODE_ACTION="test"
ENV_ONLY_TESTING=""

for arg in "$@"; do
    case "$arg" in
        -only-testing:*) FILTERED=1 ;;
    esac
done

# True when any Swift source under PodWash/ is newer than the built xctestrun.
# Tier 1/2 used to pick test-without-building whenever Products/ existed, which
# silently re-ran stale binaries after Engineer/QA edits (slice 12 death-run).
_sources_newer_than_products() {
    products="$DERIVED_DATA/Build/Products"
    [ -d "$products" ] || return 0
    xctestrun=$(find "$products" -maxdepth 1 -name '*.xctestrun' -print 2>/dev/null | head -n 1)
    if [ -z "$xctestrun" ] || [ ! -f "$xctestrun" ]; then
        return 0
    fi
    # Any .swift under the Xcode project trees newer than the xctestrun.
    newer=$(find PodWash/PodWash PodWash/PodWashTests PodWash/PodWashUITests PodWash/PodWashSlowTests \
        -type f -name '*.swift' -newer "$xctestrun" -print 2>/dev/null | head -n 1)
    [ -n "$newer" ]
}

_tier_action_with_staleness_check() {
    # Prefer test-without-building only when products exist AND sources are not newer.
    if [ -d "$DERIVED_DATA/Build/Products" ] && ! _sources_newer_than_products; then
        echo "test-without-building"
    else
        if [ -d "$DERIVED_DATA/Build/Products" ]; then
            echo "verify.sh: sources newer than xctestrun — rebuilding (action=test)" >&2
        fi
        echo "test"
    fi
}

case "$VERIFY_TIER" in
    0)
        XCODE_ACTION="build-for-testing"
        FILTERED=0
        ;;
    1)
        XCODE_ACTION=$(_tier_action_with_staleness_check)
        if [ -z "${VERIFY_FAILED_TESTS:-}" ]; then
            echo "verify.sh: VERIFY_TIER=1 requires VERIFY_FAILED_TESTS" >&2
            exit 1
        fi
        ENV_ONLY_TESTING=$VERIFY_FAILED_TESTS
        FILTERED=1
        ;;
    2)
        XCODE_ACTION=$(_tier_action_with_staleness_check)
        if [ -n "${VERIFY_SLICE_TESTS:-}" ]; then
            ENV_ONLY_TESTING=$VERIFY_SLICE_TESTS
            FILTERED=1
        fi
        if [ "$FILTERED" -eq 0 ]; then
            echo "verify.sh: VERIFY_TIER=2 requires -only-testing: args or VERIFY_SLICE_TESTS" >&2
            exit 1
        fi
        ;;
    3|*)
        XCODE_ACTION="test"
        VERIFY_TIER=3
        ENV_ONLY_TESTING=""
        ;;
esac

# ---------------------------------------------------------------------- run --
STAMP=$(date +%Y%m%d-%H%M%S)
RESULT_BUNDLE="$RESULTS_DIR/verify-$STAMP.xcresult"
mkdir -p "$RESULTS_DIR"
DESTINATION="platform=iOS Simulator,name=$SIM_NAME"

# Expand env test ids into -only-testing: flags (word-split on whitespace).
ONLY_FLAGS=""
if [ -n "$ENV_ONLY_TESTING" ]; then
    # shellcheck disable=SC2086
    for _tid in $ENV_ONLY_TESTING; do
        [ -n "$_tid" ] || continue
        ONLY_FLAGS="$ONLY_FLAGS -only-testing:$_tid"
    done
fi

echo "verify.sh: scheme=$SCHEME simulator=\"$SIM_NAME\" tier=$VERIFY_TIER action=$XCODE_ACTION filtered=$FILTERED"
echo "verify.sh: derivedData=$DERIVED_DATA"
if [ "$XCODE_ACTION" != "build-for-testing" ]; then
    echo "verify.sh: result bundle: $RESULT_BUNDLE"
fi

if [ "${VERIFY_DRY_RUN:-0}" = "1" ]; then
    if [ "$XCODE_ACTION" = "build-for-testing" ]; then
        echo "verify.sh: DRY_RUN argv: xcodebuild $XCODE_ACTION -project $PROJECT -scheme $SCHEME -destination $DESTINATION -derivedDataPath $DERIVED_DATA -quiet $ONLY_FLAGS $*"
    else
        echo "verify.sh: DRY_RUN argv: xcodebuild $XCODE_ACTION -project $PROJECT -scheme $SCHEME -destination $DESTINATION -derivedDataPath $DERIVED_DATA -resultBundlePath $RESULT_BUNDLE -retry-tests-on-failure -test-iterations 2 -quiet $ONLY_FLAGS $*"
    fi
    echo "VERIFY RESULT: exit=0 total=0 passed=0 failed=0 skipped=0 filtered=$FILTERED bundle=$RESULT_BUNDLE tier=$VERIFY_TIER class=tests"
    /usr/bin/python3 -c "
import json, os
path = os.path.join('$RESULTS_DIR', 'verify-result.json')
os.makedirs('$RESULTS_DIR', exist_ok=True)
with open(path, 'w', encoding='utf-8') as fh:
    json.dump({
        'exit': 0, 'total': 0, 'passed': 0, 'failed': 0, 'skipped': 0,
        'filtered': int('$FILTERED') if str('$FILTERED').isdigit() else 0,
        'bundle': '$RESULT_BUNDLE' or None, 'tier': int('$VERIFY_TIER') if str('$VERIFY_TIER').isdigit() else 3,
        'class': 'tests',
    }, fh, indent=2)
    fh.write('\n')
" 2>/dev/null || true
    exit 0
fi

set +e
# shellcheck disable=SC2086
if [ "$XCODE_ACTION" = "build-for-testing" ]; then
    xcodebuild "$XCODE_ACTION" \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -destination "$DESTINATION" \
        -derivedDataPath "$DERIVED_DATA" \
        -quiet \
        $ONLY_FLAGS \
        "$@"
else
    xcodebuild "$XCODE_ACTION" \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -destination "$DESTINATION" \
        -derivedDataPath "$DERIVED_DATA" \
        -resultBundlePath "$RESULT_BUNDLE" \
        -retry-tests-on-failure \
        -test-iterations 2 \
        -quiet \
        $ONLY_FLAGS \
        "$@"
fi
XC_EXIT=$?
set -e

# ------------------------------------------------------------------- counts --
TOTAL=""; PASSED=""; FAILED=""; SKIPPED=""
if [ "$XCODE_ACTION" = "build-for-testing" ]; then
    TOTAL=0; PASSED=0; FAILED=0; SKIPPED=0
    RESULT_BUNDLE=""
elif [ -d "$RESULT_BUNDLE" ]; then
    COUNTS=$(xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE" 2>/dev/null \
        | /usr/bin/python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
print(d.get("totalTestCount", 0), d.get("passedTests", 0),
      d.get("failedTests", 0), d.get("skippedTests", 0))
' || true)
    if [ -n "$COUNTS" ]; then
        TOTAL=$(echo "$COUNTS" | awk '{print $1}')
        PASSED=$(echo "$COUNTS" | awk '{print $2}')
        FAILED=$(echo "$COUNTS" | awk '{print $3}')
        SKIPPED=$(echo "$COUNTS" | awk '{print $4}')
    fi
fi

echo ""
echo "================ VERIFY SUMMARY ================"
if [ -n "$TOTAL" ]; then
    echo "  executed: $TOTAL   passed: $PASSED   failed: $FAILED   SKIPPED: $SKIPPED"
else
    echo "  (could not read counts from ${RESULT_BUNDLE:-none})"
fi
echo "  tier: $VERIFY_TIER   action: $XCODE_ACTION"
echo "  xcodebuild exit code: $XC_EXIT"
if [ -n "${RESULT_BUNDLE:-}" ]; then
    echo "  result bundle: $RESULT_BUNDLE"
fi
if [ "$FILTERED" -eq 1 ]; then
    echo "  NOTE: filtered run — slice Done still requires the FULL suite green (tier 3)."
fi
echo "================================================"

FINAL_EXIT=$XC_EXIT
if [ -n "$SKIPPED" ] && [ "$SKIPPED" -gt 0 ]; then
    if [ "${VERIFY_ALLOW_SKIPS:-0}" = "1" ]; then
        echo "verify.sh: WARNING: $SKIPPED test(s) skipped (allowed by VERIFY_ALLOW_SKIPS=1)"
    else
        echo "verify.sh: FAIL: $SKIPPED test(s) skipped — mapped tests must run, not skip (XCTSkip is not allowed on core ACs)" >&2
        [ "$FINAL_EXIT" -eq 0 ] && FINAL_EXIT=1
    fi
fi

# Classify: build (exit!=0, 0 tests ran) vs tests (assertions / executed failures).
VERIFY_CLASS="tests"
if [ "$FINAL_EXIT" -ne 0 ]; then
    TOTAL_N="${TOTAL:-0}"
    FAILED_N="${FAILED:-0}"
    case "$TOTAL_N" in
        ""|"?") TOTAL_N=0 ;;
    esac
    case "$FAILED_N" in
        ""|"?") FAILED_N=0 ;;
    esac
    if [ "$TOTAL_N" -eq 0 ] && [ "$FAILED_N" -eq 0 ]; then
        VERIFY_CLASS="build"
    fi
fi

if [ -n "${RESULT_BUNDLE:-}" ]; then
    echo "VERIFY RESULT: exit=$FINAL_EXIT total=${TOTAL:-?} passed=${PASSED:-?} failed=${FAILED:-?} skipped=${SKIPPED:-?} filtered=$FILTERED bundle=$RESULT_BUNDLE tier=$VERIFY_TIER class=$VERIFY_CLASS"
else
    echo "VERIFY RESULT: exit=$FINAL_EXIT total=${TOTAL:-?} passed=${PASSED:-?} failed=${FAILED:-?} skipped=${SKIPPED:-?} filtered=$FILTERED tier=$VERIFY_TIER class=$VERIFY_CLASS"
fi

# Machine-readable contract for the factory (classifiers must prefer this over stdout sniffing).
/usr/bin/python3 -c "
import json, os, sys
path = os.path.join('$RESULTS_DIR', 'verify-result.json')
payload = {
    'exit': int('$FINAL_EXIT') if str('$FINAL_EXIT').lstrip('-').isdigit() else '$FINAL_EXIT',
    'total': '$TOTAL' if '$TOTAL' != '' else None,
    'passed': '$PASSED' if '$PASSED' != '' else None,
    'failed': '$FAILED' if '$FAILED' != '' else None,
    'skipped': '$SKIPPED' if '$SKIPPED' != '' else None,
    'filtered': int('$FILTERED') if str('$FILTERED').isdigit() else '$FILTERED',
    'bundle': '''$RESULT_BUNDLE''' or None,
    'tier': int('$VERIFY_TIER') if str('$VERIFY_TIER').isdigit() else '$VERIFY_TIER',
    'class': '$VERIFY_CLASS',
}
# Normalize empty bundle
if not payload['bundle']:
    payload['bundle'] = None
with open(path, 'w', encoding='utf-8') as fh:
    json.dump(payload, fh, indent=2)
    fh.write('\n')
" 2>/dev/null || true

exit "$FINAL_EXIT"
