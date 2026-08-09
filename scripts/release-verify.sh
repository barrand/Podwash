#!/bin/sh
# PodWash release gate: fresh build followed by complete unit and UI suites.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

echo "release-verify: phase 1/3 — fresh build-for-testing"
VERIFY_TIER=0 VERIFY_NO_RETRY=1 scripts/verify.sh
echo "release-verify: phase 2/3 — complete unit suite"
VERIFY_TIER=3a VERIFY_NO_RETRY=1 scripts/verify.sh
echo "release-verify: phase 3/3 — complete UI suite"
VERIFY_TIER=3b VERIFY_NO_RETRY=1 scripts/verify.sh
echo "release-verify: PASS — tests are green. Create and validate the distribution archive in Xcode Organizer."
