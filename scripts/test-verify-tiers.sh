#!/usr/bin/env bash
# Unit tests for verify.sh tier interface (VERIFY_DRY_RUN — no xcodebuild).
set -euo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VERIFY="$ROOT/scripts/verify.sh"
FAIL=0

assert_contains() {
    haystack=$1
    needle=$2
    label=$3
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        echo "ok — $label"
    else
        echo "FAIL — $label (missing: $needle)" >&2
        echo "$haystack" >&2
        FAIL=1
    fi
}

assert_not_contains() {
    haystack=$1
    needle=$2
    label=$3
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        echo "FAIL — $label (unexpected: $needle)" >&2
        echo "$haystack" >&2
        FAIL=1
    else
        echo "ok — $label"
    fi
}

out=$(VERIFY_DRY_RUN=1 VERIFY_TIER=0 "$VERIFY" 2>&1)
assert_contains "$out" "action=build-for-testing" "tier 0 uses build-for-testing"
assert_contains "$out" "derivedDataPath build/dd" "tier 0 shares derived data"
assert_contains "$out" "tier=0" "tier 0 VERIFY RESULT"

out=$(VERIFY_DRY_RUN=1 VERIFY_TIER=1 \
    VERIFY_FAILED_TESTS='PodWashTests/Foo/testA() PodWashTests/Bar/testB()' \
    "$VERIFY" 2>&1)
assert_contains "$out" "action=test-without-building" "tier 1 uses test-without-building"
assert_contains "$out" "-only-testing:PodWashTests/Foo/testA()" "tier 1 first failed test"
assert_contains "$out" "-only-testing:PodWashTests/Bar/testB()" "tier 1 second failed test"
assert_contains "$out" "filtered=1" "tier 1 filtered"
assert_contains "$out" "tier=1" "tier 1 VERIFY RESULT"

# Tier 1 without VERIFY_FAILED_TESTS must fail
if VERIFY_DRY_RUN=1 VERIFY_TIER=1 "$VERIFY" >/dev/null 2>&1; then
    echo "FAIL — tier 1 should require VERIFY_FAILED_TESTS" >&2
    FAIL=1
else
    echo "ok — tier 1 rejects missing VERIFY_FAILED_TESTS"
fi

out=$(VERIFY_DRY_RUN=1 VERIFY_TIER=2 \
    VERIFY_SLICE_TESTS='PodWashUITests/AnalysisProgressUITests/testProgress()' \
    "$VERIFY" 2>&1)
assert_contains "$out" "-only-testing:PodWashUITests/AnalysisProgressUITests/testProgress()" \
    "tier 2 slice filter"
assert_contains "$out" "tier=2" "tier 2 VERIFY RESULT"

out=$(VERIFY_DRY_RUN=1 VERIFY_TIER=3 "$VERIFY" 2>&1)
assert_contains "$out" "action=test" "tier 3 uses test"
assert_contains "$out" "filtered=0" "tier 3 unfiltered"
assert_contains "$out" "tier=3" "tier 3 VERIFY RESULT"
assert_not_contains "$out" "-only-testing:" "tier 3 has no only-testing from env"

# Default (no VERIFY_TIER) is tier 3
out=$(VERIFY_DRY_RUN=1 "$VERIFY" 2>&1)
assert_contains "$out" "tier=3" "default tier is 3"

if [ "$FAIL" -ne 0 ]; then
    echo "test-verify-tiers.sh: FAILED" >&2
    exit 1
fi
echo "test-verify-tiers.sh: all ok"
