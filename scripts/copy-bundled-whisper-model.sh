#!/bin/sh
# Copy the PLATFORM-selected WhisperKit Core ML model into a stable bundle folder
# (ADR-024). Invoked from the PodWash app target Run Script phase.
#
# Prerequisite: scripts/setup-asr-models.sh (idempotent) so both
#   Models/whisperkit-coreml/openai_whisper-{tiny,base}.en/
# have AudioEncoder/TextDecoder/MelSpectrogram.mlmodelc.
#
# Selection:
#   PLATFORM_NAME=iphoneos     → openai_whisper-base.en
#   otherwise (simulator/etc.) → openai_whisper-tiny.en
#
# Installs into:
#   $UNLOCALIZED_RESOURCES_FOLDER_PATH/openai_whisper-bundled/
#   $UNLOCALIZED_RESOURCES_FOLDER_PATH/asr-model-pin.txt  (one line = logical id)
#
# Usage (Xcode): SRCROOT / TARGET_BUILD_DIR / UNLOCALIZED_RESOURCES_FOLDER_PATH /
#   PLATFORM_NAME set by xcodebuild.
# Manual:
#   SRCROOT=PodWash TARGET_BUILD_DIR=/tmp/out UNLOCALIZED_RESOURCES_FOLDER_PATH=. \
#     PLATFORM_NAME=iphonesimulator scripts/copy-bundled-whisper-model.sh

set -eu

BUNDLED_FOLDER="openai_whisper-bundled"
PIN_FILE="asr-model-pin.txt"

case "${PLATFORM_NAME:-}" in
    iphoneos)
        SOURCE_MODEL="openai_whisper-base.en"
        ;;
    *)
        SOURCE_MODEL="openai_whisper-tiny.en"
        ;;
esac

SRC="${SRCROOT}/../Models/whisperkit-coreml/${SOURCE_MODEL}"
DEST_ROOT="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
DEST="${DEST_ROOT}/${BUNDLED_FOLDER}"
PIN_PATH="${DEST_ROOT}/${PIN_FILE}"
SETUP_MSG="Run scripts/setup-asr-models.sh and ensure the app target copies the PLATFORM-selected model into ${BUNDLED_FOLDER} per ADR-024. Expected source: ${SRC}"

for m in AudioEncoder.mlmodelc TextDecoder.mlmodelc MelSpectrogram.mlmodelc; do
    if [ ! -d "${SRC}/${m}" ]; then
        echo "error: Missing ${SOURCE_MODEL}/${m}. ${SETUP_MSG}" >&2
        exit 1
    fi
done

# Absolute paths: iOS Simulator XCTest PATH points at RuntimeRoot bins that
# lack cp/rm/mkdir (bare names → exit 127). Host Xcode build phases also OK.
/bin/rm -rf "${DEST}"
/bin/mkdir -p "${DEST}"
/bin/cp -R "${SRC}/AudioEncoder.mlmodelc" "${DEST}/"
/bin/cp -R "${SRC}/TextDecoder.mlmodelc" "${DEST}/"
/bin/cp -R "${SRC}/MelSpectrogram.mlmodelc" "${DEST}/"
/bin/cp "${SRC}/config.json" "${DEST}/"
/bin/cp "${SRC}/generation_config.json" "${DEST}/"

printf '%s\n' "${SOURCE_MODEL}" > "${PIN_PATH}"

echo "copy-bundled-whisper-model.sh: PLATFORM_NAME=${PLATFORM_NAME:-} → ${SOURCE_MODEL} → ${DEST} (pin ${PIN_PATH})"
