#!/bin/sh
# PodWash verification script — the single sanctioned way to run the test suite.
#
# Usage:
#   scripts/verify.sh                                   # FULL suite (required for slice Done)
#   scripts/verify.sh -only-testing:PodWashTests/FooTests   # fast slice loop (NOT sufficient for Done)
#
# Extra arguments are passed through to xcodebuild verbatim, so any number of
# -only-testing: filters may be given. A filtered run is for the fast inner
# loop only; a slice may be marked Done ONLY on a full-suite (unfiltered) green
# run of this script.
#
# Environment overrides:
#   PODWASH_SIM=<simulator name>   force a specific simulator (default: first available iPhone)
#   VERIFY_ALLOW_SKIPS=1           tolerate skipped tests (nightly @slow job only; never for slice Done)
#
# Behavior:
#   - Resolves an available iPhone simulator dynamically (no hardcoded device names).
#   - Writes a timestamped .xcresult bundle under build/test-results/ (gitignored).
#   - Retries flaky failures once (-retry-tests-on-failure -test-iterations 2).
#   - Serializes concurrent runs with a lockfile (build/.verify.lock).
#   - Prints executed/passed/failed/skipped counts and a copy-pastable
#     "VERIFY RESULT" line for the slice file's verification record.
#   - Exits nonzero on any test failure, and on skipped tests unless
#     VERIFY_ALLOW_SKIPS=1.

set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$REPO_ROOT"

PROJECT="PodWash/PodWash.xcodeproj"
SCHEME="PodWash"
BUILD_DIR="build"
RESULTS_DIR="$BUILD_DIR/test-results"
LOCK_DIR="$BUILD_DIR/.verify.lock"

# ---------------------------------------------------------------- simulator --
SIM_NAME=${PODWASH_SIM:-}
if [ -z "$SIM_NAME" ]; then
    SIM_NAME=$(xcrun simctl list devices available \
        | sed -n 's/^[[:space:]]*\(iPhone[^(]*\)(.*/\1/p' \
        | sed 's/[[:space:]]*$//' \
        | head -n 1)
fi
if [ -z "$SIM_NAME" ]; then
    echo "verify.sh: no available iPhone simulator found (xcrun simctl list devices available)" >&2
    exit 1
fi

# --------------------------------------------------------------------- lock --
mkdir -p "$BUILD_DIR"
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
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM

# ---------------------------------------------------------------------- run --
STAMP=$(date +%Y%m%d-%H%M%S)
RESULT_BUNDLE="$RESULTS_DIR/verify-$STAMP.xcresult"
mkdir -p "$RESULTS_DIR"

FILTERED=0
for arg in "$@"; do
    case "$arg" in
        -only-testing:*) FILTERED=1 ;;
    esac
done

echo "verify.sh: scheme=$SCHEME simulator=\"$SIM_NAME\" filtered=$FILTERED"
echo "verify.sh: result bundle: $RESULT_BUNDLE"

set +e
xcodebuild test \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,name=$SIM_NAME" \
    -resultBundlePath "$RESULT_BUNDLE" \
    -retry-tests-on-failure \
    -test-iterations 2 \
    -quiet \
    "$@"
XC_EXIT=$?
set -e

# ------------------------------------------------------------------- counts --
TOTAL=""; PASSED=""; FAILED=""; SKIPPED=""
if [ -d "$RESULT_BUNDLE" ]; then
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
    echo "  (could not read counts from $RESULT_BUNDLE)"
fi
echo "  xcodebuild exit code: $XC_EXIT"
echo "  result bundle: $RESULT_BUNDLE"
if [ "$FILTERED" -eq 1 ]; then
    echo "  NOTE: filtered run — slice Done still requires the FULL suite green."
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

# Copy-pastable verification record for the slice file.
echo "VERIFY RESULT: exit=$FINAL_EXIT total=${TOTAL:-?} passed=${PASSED:-?} failed=${FAILED:-?} skipped=${SKIPPED:-?} filtered=$FILTERED bundle=$RESULT_BUNDLE"

exit "$FINAL_EXIT"
