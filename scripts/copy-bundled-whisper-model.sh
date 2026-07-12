#!/bin/sh
# Copy pinned WhisperKit tiny.en Core ML bundles into the app resource bundle (ADR-020).
# Invoked from the PodWash app target Run Script phase.
#
# Prerequisite: scripts/setup-asr-models.sh (idempotent) so
#   Models/whisperkit-coreml/openai_whisper-tiny.en/{AudioEncoder,TextDecoder,MelSpectrogram}.mlmodelc
# exist. Fails the build loudly if any required directory is missing.
#
# Usage (Xcode): SRCROOT / TARGET_BUILD_DIR / UNLOCALIZED_RESOURCES_FOLDER_PATH set by xcodebuild.
# Manual:
#   SRCROOT=PodWash TARGET_BUILD_DIR=/tmp/out UNLOCALIZED_RESOURCES_FOLDER_PATH=. \
#     scripts/copy-bundled-whisper-model.sh

set -eu

MODEL_NAME="openai_whisper-tiny.en"
SRC="${SRCROOT}/../Models/whisperkit-coreml/${MODEL_NAME}"
DEST="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/${MODEL_NAME}"
SETUP_MSG="Run scripts/setup-asr-models.sh and ensure the app target copies ${MODEL_NAME} per ADR-020. Expected source: ${SRC}"

for m in AudioEncoder.mlmodelc TextDecoder.mlmodelc MelSpectrogram.mlmodelc; do
    if [ ! -d "${SRC}/${m}" ]; then
        echo "error: Missing ${MODEL_NAME}/${m}. ${SETUP_MSG}" >&2
        exit 1
    fi
done

rm -rf "${DEST}"
mkdir -p "${DEST}"
cp -R "${SRC}/AudioEncoder.mlmodelc" "${DEST}/"
cp -R "${SRC}/TextDecoder.mlmodelc" "${DEST}/"
cp -R "${SRC}/MelSpectrogram.mlmodelc" "${DEST}/"
cp "${SRC}/config.json" "${DEST}/"
cp "${SRC}/generation_config.json" "${DEST}/"

echo "copy-bundled-whisper-model.sh: installed ${MODEL_NAME} → ${DEST}"
