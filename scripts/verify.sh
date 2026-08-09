#!/bin/sh
# PodWash verification script — the single sanctioned way to run the test suite.
#
# Usage:
#   scripts/verify.sh                                   # FULL suite (tier 3 — ship-gate Done)
#   scripts/verify.sh -only-testing:PodWashTests/FooTests   # fast loop → Implemented (NOT Done)
#
# Extra arguments are passed through to xcodebuild verbatim, so any number of
# -only-testing: filters may be given. A filtered/tier-2 run marks **Implemented**;
# ship-gate **Done** requires a full-suite (unfiltered) green run (VERIFY_TIER=3).
#
# Environment overrides:
#   PODWASH_SIM=<simulator name>   force a specific simulator (default: first available iPhone)
#   VERIFY_ALLOW_SKIPS=1           tolerate skipped tests (nightly @slow job only; never for ship Done)
#   VERIFY_TIER=0|1|2|3|3a|3b       verification tier (default 3 = full ship gate)
#     0  build-for-testing only (-derivedDataPath build/dd)
#     1  test-without-building + VERIFY_FAILED_TESTS → -only-testing: (failed-tests-first)
#     2  filtered slice/task tests (args and/or VERIFY_SLICE_TESTS) + shared derived data
#     3  full unfiltered suite (ship gate); PodWashTests + PodWashUITests
#     3a unit-only fast pass (-only-testing:PodWashTests) — early red signal
#     3b UI-only pass (-only-testing:PodWashUITests) — serial UITests
#   VERIFY_FAILED_TESTS="A/b() C/d()"   space-separated test ids for tier 1
#   VERIFY_SLICE_TESTS="A/b() C/d()"    space-separated test ids for tier 2 (plus CLI args)
#   VERIFY_DERIVED_DATA=build/dd        shared derived data path (default build/dd)
#   VERIFY_DRY_RUN=1                    print resolved xcodebuild argv and exit 0 (unit tests)
#   VERIFY_NO_RETRY=1                   omit -retry-tests-on-failure (default: retry unit-only)
#
# Behavior:
#   - Resolves an available iPhone simulator dynamically (no hardcoded device names).
#   - Writes a self-contained timestamped run directory under build/test-results/
#     (raw Xcode log, live status, .xcresult and final report).
#   - Retries flaky unit-test failures once (-retry-tests-on-failure -test-iterations 2)
#     when the run is unit-only (no PodWashUITests in args). Full tier-3 includes UITests
#     in the suite but not in argv, so retries historically applied — set VERIFY_NO_RETRY=1
#     or use split 3a/3b to avoid doubling wall time on flakes. UITest filters never retry.
#   - Serializes concurrent runs with a lockfile (build/.verify.lock).
#   - Prints executed/passed/failed/skipped counts, phase timings, and a copy-pastable
#     "VERIFY RESULT" line for the verification record.
#   - Exits nonzero on any test failure, and on skipped tests unless
#     VERIFY_ALLOW_SKIPS=1.
#   - Ship-gate Done requires tier=3 (or sequential 3a+3b green) with filtered=0.

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

# Tier display label (3a/3b keep string form on VERIFY RESULT).
TIER_LABEL="$VERIFY_TIER"
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
    3a)
        XCODE_ACTION="test"
        FILTERED=1
        ENV_ONLY_TESTING="PodWashTests"
        TIER_LABEL=3a
        ;;
    3b)
        XCODE_ACTION="test"
        FILTERED=1
        ENV_ONLY_TESTING="PodWashUITests"
        TIER_LABEL=3b
        ;;
    3|*)
        XCODE_ACTION="test"
        VERIFY_TIER=3
        TIER_LABEL=3
        ENV_ONLY_TESTING=""
        ;;
esac

# ---------------------------------------------------------------------- run --
STAMP=$(date +%Y%m%d-%H%M%S)
RUN_ID="verify-$STAMP-$$"
RUN_DIR="$RESULTS_DIR/$RUN_ID"
RESULT_BUNDLE="$RUN_DIR/result.xcresult"
RAW_LOG="$RUN_DIR/xcodebuild.log"
STATUS_JSON="$RUN_DIR/status.json"
STATUS_MD="$RUN_DIR/status.md"
LATEST_JSON="$RESULTS_DIR/latest.json"
LATEST_MD="$RESULTS_DIR/latest.md"
mkdir -p "$RUN_DIR"
DESTINATION="platform=iOS Simulator,name=$SIM_NAME"
VERIFY_T0=$(date +%s)

write_status() {
    _phase=$1
    _detail=${2:-}
    _elapsed=$(( $(date +%s) - VERIFY_T0 ))
    /usr/bin/python3 -c '
import json, sys
path, latest, run_id, phase, detail, elapsed, bundle, log = sys.argv[1:]
payload = {"run_id": run_id, "phase": phase, "detail": detail,
           "elapsed_s": int(elapsed), "result_bundle": bundle,
           "raw_log": log, "complete": phase in ("passed", "failed")}
for target in (path, latest):
    with open(target, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2)
        fh.write("\\n")
' "$STATUS_JSON" "$LATEST_JSON" "$RUN_ID" "$_phase" "$_detail" "$_elapsed" "$RESULT_BUNDLE" "$RAW_LOG"
    {
        echo "# PodWash verification status"
        echo
        echo "- Run: \`$RUN_ID\`"
        echo "- Phase: **$_phase**"
        echo "- Elapsed: ${_elapsed}s"
        [ -n "$_detail" ] && echo "- Detail: $_detail"
        echo "- Raw log: \`$RAW_LOG\`"
        echo "- Result bundle: \`$RESULT_BUNDLE\`"
    } > "$STATUS_MD"
    cp "$STATUS_MD" "$LATEST_MD"
}

write_status "starting" "resolving simulator and test selection"

# Expand env test ids into -only-testing: flags (word-split on whitespace).
ONLY_FLAGS=""
if [ -n "$ENV_ONLY_TESTING" ]; then
    # shellcheck disable=SC2086
    for _tid in $ENV_ONLY_TESTING; do
        [ -n "$_tid" ] || continue
        ONLY_FLAGS="$ONLY_FLAGS -only-testing:$_tid"
    done
fi

echo "verify.sh: RUN $RUN_ID"
echo "verify.sh: artifacts: $RUN_DIR"
echo "verify.sh: scheme=$SCHEME simulator=\"$SIM_NAME\" tier=$TIER_LABEL action=$XCODE_ACTION filtered=$FILTERED"
echo "verify.sh: derivedData=$DERIVED_DATA"
if [ "$XCODE_ACTION" != "build-for-testing" ]; then
    echo "verify.sh: result bundle: $RESULT_BUNDLE"
fi

if [ "${VERIFY_VISIBLE_UI:-0}" = "1" ]; then
    echo "verify.sh: visible UI diagnostics requested; foregrounding Simulator."
    open -a Simulator >/dev/null 2>&1 || true
fi

# Retry flaky unit failures once. UITest filters never retry. Full tier-3 used
# to retry (UITests not in argv) which can nearly double wall time — default
# now: retry only when the run is explicitly unit-scoped (tier 1/2/3a or
# -only-testing without PodWashUITests). Opt out with VERIFY_NO_RETRY=1.
RETRY_FLAGS=""
_ALL_TEST_ARGS="$ONLY_FLAGS $*"
if [ "${VERIFY_NO_RETRY:-0}" = "1" ]; then
    RETRY_FLAGS=""
elif [ "$TIER_LABEL" = "3" ] || [ "$TIER_LABEL" = "3b" ]; then
    # Full suite / UI pass: no retry (one definition of green; stress-run UI fixes).
    RETRY_FLAGS=""
else
    case "$_ALL_TEST_ARGS" in
        *PodWashUITests*)
            RETRY_FLAGS=""
            ;;
        *)
            RETRY_FLAGS="-retry-tests-on-failure -test-iterations 2"
            ;;
    esac
fi
echo "verify.sh: retry_flags=${RETRY_FLAGS:-none}"

if [ "${VERIFY_DRY_RUN:-0}" = "1" ]; then
    if [ "$XCODE_ACTION" = "build-for-testing" ]; then
        echo "verify.sh: DRY_RUN argv: xcodebuild $XCODE_ACTION -project $PROJECT -scheme $SCHEME -destination $DESTINATION -derivedDataPath $DERIVED_DATA -quiet $ONLY_FLAGS $*"
    else
        echo "verify.sh: DRY_RUN argv: xcodebuild $XCODE_ACTION -project $PROJECT -scheme $SCHEME -destination $DESTINATION -derivedDataPath $DERIVED_DATA -resultBundlePath $RESULT_BUNDLE $RETRY_FLAGS -quiet $ONLY_FLAGS $*"
    fi
    echo "VERIFY RESULT: exit=0 total=0 passed=0 failed=0 skipped=0 filtered=$FILTERED bundle=$RESULT_BUNDLE tier=$TIER_LABEL class=tests elapsed_s=0"
    /usr/bin/python3 -c "
import json, os
path = os.path.join('$RESULTS_DIR', 'verify-result.json')
os.makedirs('$RESULTS_DIR', exist_ok=True)
tier_raw = '$TIER_LABEL'
tier_val = int(tier_raw) if tier_raw.isdigit() else tier_raw
with open(path, 'w', encoding='utf-8') as fh:
    json.dump({
        'exit': 0, 'total': 0, 'passed': 0, 'failed': 0, 'skipped': 0,
        'filtered': int('$FILTERED') if str('$FILTERED').isdigit() else 0,
        'bundle': '$RESULT_BUNDLE' or None, 'tier': tier_val,
        'class': 'tests', 'elapsed_s': 0,
        'phases': {'boot_s': 0, 'xcodebuild_s': 0, 'parse_s': 0},
    }, fh, indent=2)
    fh.write('\n')
" 2>/dev/null || true
    exit 0
fi

# Best-effort sim readiness timing (helps diagnose cold-boot wall time).
VERIFY_BOOT_S=0
VERIFY_T_BOOT0=$(date +%s)
if [ "${VERIFY_SKIP_BOOT:-0}" != "1" ] && command -v xcrun >/dev/null 2>&1; then
    # Cap wait so a stuck sim does not inflate timings forever.
    ( xcrun simctl bootstatus booted -b >/dev/null 2>&1 ) &
    _boot_pid=$!
    _boot_wait=0
    while kill -0 "$_boot_pid" 2>/dev/null; do
        if [ "$_boot_wait" -ge 45 ]; then
            kill "$_boot_pid" 2>/dev/null || true
            break
        fi
        sleep 1
        _boot_wait=$((_boot_wait + 1))
    done
    wait "$_boot_pid" 2>/dev/null || true
fi
VERIFY_BOOT_S=$(( $(date +%s) - VERIFY_T_BOOT0 ))
echo "verify.sh: boot_s=$VERIFY_BOOT_S"
write_status "running" "simulator ready; xcodebuild starting"

VERIFY_T_XC0=$(date +%s)
set +e
# Keep full Xcode output in the artifact while the terminal remains readable.
# shellcheck disable=SC2086
if [ "$XCODE_ACTION" = "build-for-testing" ]; then
    xcodebuild "$XCODE_ACTION" \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -destination "$DESTINATION" \
        -derivedDataPath "$DERIVED_DATA" \
        $ONLY_FLAGS \
        "$@" >"$RAW_LOG" 2>&1 &
else
    xcodebuild "$XCODE_ACTION" \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -destination "$DESTINATION" \
        -derivedDataPath "$DERIVED_DATA" \
        -resultBundlePath "$RESULT_BUNDLE" \
        $RETRY_FLAGS \
        $ONLY_FLAGS \
        "$@" >"$RAW_LOG" 2>&1 &
fi
XC_PID=$!
HEARTBEAT=0
while kill -0 "$XC_PID" 2>/dev/null; do
    sleep 15
    HEARTBEAT=$((HEARTBEAT + 15))
    CURRENT=$(grep -E 'Test Case .+ (started|passed|failed)|Testing started|Testing failed|Testing completed' "$RAW_LOG" 2>/dev/null | tail -n 1 || true)
    [ -z "$CURRENT" ] && CURRENT="xcodebuild running"
    echo "verify.sh: heartbeat elapsed=$(( $(date +%s) - VERIFY_T0 ))s — $CURRENT"
    write_status "running" "$CURRENT"
    if [ "$HEARTBEAT" -eq 180 ]; then
        echo "verify.sh: ATTENTION — no completion after 3 minutes; inspect $RAW_LOG" >&2
    fi
done
wait "$XC_PID"
XC_EXIT=$?
set -e
VERIFY_T1=$(date +%s)
VERIFY_XCODEBUILD_S=$((VERIFY_T1 - VERIFY_T_XC0))
VERIFY_ELAPSED=$((VERIFY_T1 - VERIFY_T0))

# ------------------------------------------------------------------- counts --
VERIFY_T_PARSE0=$(date +%s)
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
VERIFY_PARSE_S=$(( $(date +%s) - VERIFY_T_PARSE0 ))

echo ""
echo "================ VERIFY SUMMARY ================"
if [ -n "$TOTAL" ]; then
    echo "  executed: $TOTAL   passed: $PASSED   failed: $FAILED   SKIPPED: $SKIPPED"
else
    echo "  (could not read counts from ${RESULT_BUNDLE:-none})"
fi
echo "  tier: $TIER_LABEL   action: $XCODE_ACTION   elapsed_s: $VERIFY_ELAPSED"
echo "  phases: boot_s=$VERIFY_BOOT_S xcodebuild_s=$VERIFY_XCODEBUILD_S parse_s=$VERIFY_PARSE_S"
echo "  xcodebuild exit code: $XC_EXIT"
if [ -n "${RESULT_BUNDLE:-}" ]; then
    echo "  result bundle: $RESULT_BUNDLE"
fi
if [ "$FILTERED" -eq 1 ] && [ "$TIER_LABEL" != "3a" ] && [ "$TIER_LABEL" != "3b" ]; then
    echo "  NOTE: filtered run — ship gate still requires FULL suite green (tier 3)."
fi
echo "================================================"
write_status "parsing" "extracting test summary"
# Persist phase timing for Floor / factory diagnostics.
echo "{\"tier\":\"$TIER_LABEL\",\"elapsed_s\":$VERIFY_ELAPSED,\"action\":\"$XCODE_ACTION\",\"filtered\":$FILTERED,\"exit\":$XC_EXIT,\"phases\":{\"boot_s\":$VERIFY_BOOT_S,\"xcodebuild_s\":$VERIFY_XCODEBUILD_S,\"parse_s\":$VERIFY_PARSE_S}}" \
    > "$RUN_DIR/timing.json" 2>/dev/null || true
cp "$RUN_DIR/timing.json" "$RESULTS_DIR/verify-timing-latest.json" 2>/dev/null || true

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
    echo "VERIFY RESULT: exit=$FINAL_EXIT total=${TOTAL:-?} passed=${PASSED:-?} failed=${FAILED:-?} skipped=${SKIPPED:-?} filtered=$FILTERED bundle=$RESULT_BUNDLE tier=$TIER_LABEL class=$VERIFY_CLASS elapsed_s=$VERIFY_ELAPSED"
else
    echo "VERIFY RESULT: exit=$FINAL_EXIT total=${TOTAL:-?} passed=${PASSED:-?} failed=${FAILED:-?} skipped=${SKIPPED:-?} filtered=$FILTERED tier=$TIER_LABEL class=$VERIFY_CLASS elapsed_s=$VERIFY_ELAPSED"
fi

# Machine-readable contract for the factory (classifiers must prefer this over stdout sniffing).
/usr/bin/python3 -c "
import json, os, sys
path = os.path.join('$RESULTS_DIR', 'verify-result.json')
tier_raw = '$TIER_LABEL'
try:
    tier_val = int(tier_raw) if tier_raw.isdigit() else tier_raw
except ValueError:
    tier_val = tier_raw
payload = {
    'exit': int('$FINAL_EXIT') if str('$FINAL_EXIT').lstrip('-').isdigit() else '$FINAL_EXIT',
    'total': '$TOTAL' if '$TOTAL' != '' else None,
    'passed': '$PASSED' if '$PASSED' != '' else None,
    'failed': '$FAILED' if '$FAILED' != '' else None,
    'skipped': '$SKIPPED' if '$SKIPPED' != '' else None,
    'filtered': int('$FILTERED') if str('$FILTERED').isdigit() else '$FILTERED',
    'bundle': '''$RESULT_BUNDLE''' or None,
    'tier': tier_val,
    'class': '$VERIFY_CLASS',
    'elapsed_s': int('$VERIFY_ELAPSED') if str('$VERIFY_ELAPSED').isdigit() else None,
    'phases': {
        'boot_s': int('$VERIFY_BOOT_S') if str('$VERIFY_BOOT_S').isdigit() else None,
        'xcodebuild_s': int('$VERIFY_XCODEBUILD_S') if str('$VERIFY_XCODEBUILD_S').isdigit() else None,
        'parse_s': int('$VERIFY_PARSE_S') if str('$VERIFY_PARSE_S').isdigit() else None,
    },
}
# Normalize empty bundle
if not payload['bundle']:
    payload['bundle'] = None
with open(path, 'w', encoding='utf-8') as fh:
    json.dump(payload, fh, indent=2)
    fh.write('\n')
" 2>/dev/null || true

if [ -d "$RESULT_BUNDLE" ]; then
    xcrun xcresulttool get test-results tests --path "$RESULT_BUNDLE" > "$RUN_DIR/tests.json" 2>/dev/null || true
    mkdir -p "$RUN_DIR/attachments"
    xcrun xcresulttool export attachments \
        --path "$RESULT_BUNDLE" \
        --output-path "$RUN_DIR/attachments" \
        --only-failures >/dev/null 2>&1 || true
    /usr/bin/python3 -c '
import json, pathlib, sys
source, dest = map(pathlib.Path, sys.argv[1:])
try:
    payload = json.loads(source.read_text())
except Exception:
    dest.write_text("No structured failure details available; inspect xcodebuild.log and result.xcresult.\n")
    raise SystemExit
failures = []
def failure_messages(node):
    messages = []
    for child in node.get("children", []):
        if not isinstance(child, dict):
            continue
        if child.get("nodeType") == "Failure Message" and child.get("name"):
            messages.append(str(child["name"]))
        messages.extend(failure_messages(child))
    return messages

def walk(value):
    if isinstance(value, list):
        for child in value:
            walk(child)
        return
    if not isinstance(value, dict):
        return
    if value.get("nodeType") == "Test Case" and str(value.get("result", "")).lower() == "failed":
        name = value.get("nodeIdentifier") or value.get("name") or "Unnamed failed test"
        failures.append((str(name), " | ".join(failure_messages(value))))
    walk(value.get("children", []))
walk(payload.get("testNodes", payload))
lines = ["# Verification failures", ""]
if failures:
    for name, message in failures:
        lines.append(f"- **{name}**" + (f": {message}" if message else ""))
else:
    lines.append("No individual failed test records were parsed. Inspect `tests.json` and `xcodebuild.log`.")
dest.write_text("\n".join(lines) + "\n")
' "$RUN_DIR/tests.json" "$RUN_DIR/failures.md" || true
fi

FINAL_PHASE="passed"
[ "$FINAL_EXIT" -ne 0 ] && FINAL_PHASE="failed"
write_status "$FINAL_PHASE" "exit=$FINAL_EXIT total=${TOTAL:-?} passed=${PASSED:-?} failed=${FAILED:-?} skipped=${SKIPPED:-?}"
{
    cat "$STATUS_MD"
    echo "- Failure digest: \`$RUN_DIR/failures.md\`"
    echo "- Rerun: \`VERIFY_TIER=$TIER_LABEL scripts/verify.sh $*\`"
} > "$RUN_DIR/report.md"
cp "$RUN_DIR/report.md" "$LATEST_MD"

exit "$FINAL_EXIT"
