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
assert_contains "$out" "class=tests" "tier 0 class=tests (dry-run green)"

out=$(VERIFY_DRY_RUN=1 VERIFY_TIER=1 \
    VERIFY_FAILED_TESTS='PodWashTests/Foo/testA() PodWashTests/Bar/testB()' \
    "$VERIFY" 2>&1)
# Tier 1 may rebuild (action=test) when sources are newer than the xctestrun.
assert_contains "$out" "action=" "tier 1 prints action"
if printf '%s' "$out" | grep -qF 'action=test-without-building'; then
    echo "ok — tier 1 uses test-without-building (products fresh)"
elif printf '%s' "$out" | grep -qF 'action=test'; then
    echo "ok — tier 1 uses test (sources newer than xctestrun — rebuild)"
else
    echo "FAIL — tier 1 unexpected action" >&2
    echo "$out" >&2
    FAIL=1
fi
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

# Staleness: when sources are newer than a fake xctestrun, tier 2 must rebuild.
STALE_TMP=$(mktemp -d)
mkdir -p "$STALE_TMP/Build/Products"
# Old xctestrun (epoch)
touch -t 202001010000 "$STALE_TMP/Build/Products/fake.xctestrun"
# Touch a real source so it is newer than the fake xctestrun
touch PodWash/PodWashTests/PlaybackRateTests.swift
out=$(VERIFY_DRY_RUN=1 VERIFY_TIER=2 VERIFY_DERIVED_DATA="$STALE_TMP" \
    VERIFY_SLICE_TESTS='PodWashTests/PlaybackRateTests/testSupportedRatesMatchAVPlayer()' \
    "$VERIFY" 2>&1)
assert_contains "$out" "action=test" "tier 2 rebuilds when sources newer than xctestrun"
assert_contains "$out" "sources newer than xctestrun" "tier 2 logs rebuild reason"
rm -rf "$STALE_TMP"

# Fresh products: xctestrun newer than sources → test-without-building
FRESH_TMP=$(mktemp -d)
mkdir -p "$FRESH_TMP/Build/Products"
# Future-dated xctestrun so it is newer than all sources
touch -t 209901010000 "$FRESH_TMP/Build/Products/fake.xctestrun"
out=$(VERIFY_DRY_RUN=1 VERIFY_TIER=2 VERIFY_DERIVED_DATA="$FRESH_TMP" \
    VERIFY_SLICE_TESTS='PodWashTests/PlaybackRateTests/testSupportedRatesMatchAVPlayer()' \
    "$VERIFY" 2>&1)
assert_contains "$out" "action=test-without-building" \
    "tier 2 uses test-without-building when xctestrun is fresher"
rm -rf "$FRESH_TMP"

out=$(VERIFY_DRY_RUN=1 VERIFY_TIER=3 "$VERIFY" 2>&1)
assert_contains "$out" "action=test" "tier 3 uses test"
assert_contains "$out" "filtered=0" "tier 3 unfiltered"
assert_contains "$out" "tier=3" "tier 3 VERIFY RESULT"
assert_not_contains "$out" "-retry-tests-on-failure" "tier 3 omits retries (UI suite wall-time)"
assert_not_contains "$out" "-only-testing:" "tier 3 has no only-testing from env"

out=$(VERIFY_DRY_RUN=1 VERIFY_TIER=3a "$VERIFY" 2>&1)
assert_contains "$out" "tier=3a" "tier 3a label"
assert_contains "$out" "-only-testing:PodWashTests" "tier 3a filters units"
assert_contains "$out" "-retry-tests-on-failure" "tier 3a retries unit flakes"

out=$(VERIFY_DRY_RUN=1 VERIFY_TIER=3b "$VERIFY" 2>&1)
assert_contains "$out" "tier=3b" "tier 3b label"
assert_contains "$out" "-only-testing:PodWashUITests" "tier 3b filters UI"
assert_not_contains "$out" "-retry-tests-on-failure" "tier 3b omits retries"

# Default (no VERIFY_TIER) is tier 3
out=$(VERIFY_DRY_RUN=1 "$VERIFY" 2>&1)
assert_contains "$out" "tier=3" "default tier is 3"

if [ "$FAIL" -ne 0 ]; then
    echo "test-verify-tiers.sh: FAILED" >&2
    exit 1
fi
echo "test-verify-tiers.sh: all ok"
