#!/bin/sh
# Inject compile-time PodWashBuildStamp into the built app Info.plist (task-008).
# Invoked from the PodWash app target Run Script phase (after Process Info.plist).
#
# Format: YY.M.D.H.MM.SS in America/Denver (unpadded month/day/hour; MM/SS padded).
#
# Usage (Xcode): TARGET_BUILD_DIR / INFOPLIST_PATH set by xcodebuild.

set -eu

STAMP="$(TZ=America/Denver date '+%y.%-m.%-d.%-H.%M.%S')"
PLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"

if [ ! -f "${PLIST}" ]; then
    echo "error: Info.plist not found at ${PLIST}" >&2
    exit 1
fi

/usr/libexec/PlistBuddy -c "Delete :PodWashBuildStamp" "${PLIST}" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :PodWashBuildStamp string ${STAMP}" "${PLIST}"

echo "inject-build-stamp.sh: PodWashBuildStamp=${STAMP} → ${PLIST}"
