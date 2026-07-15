#!/bin/sh
# PodWash ASR model setup — pinned download of WhisperKit Core ML models used by
# simulator (`tiny.en`) and device (`base.en`) builds (ADR-024). Models land in the
# gitignored Models/ directory (never committed; see .gitignore). Re-running is
# idempotent; early-exit requires BOTH model trees to be complete.
#
# Usage:
#   scripts/setup-asr-models.sh
#
# Pinned model (edit here to bump; keep in sync with ADR-003 / ADR-024):
ASR_ENGINE="WhisperKit"
ASR_ENGINE_VERSION="1.0.0"                                   # SPM exactVersion pin
HF_REPO_ID="argmaxinc/whisperkit-coreml"
HF_REVISION="97a5bf9bbc74c7d9c12c755d04dea59e672e3808"       # EXACT model revision pin
# Dual-SDK models (both fetched; copy script selects one per PLATFORM_NAME).
MODELS="openai_whisper-tiny.en openai_whisper-base.en"
HF_HUB_VERSION="0.25.2"                                      # downloader pin

set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$REPO_ROOT"

MODELS_DIR="$REPO_ROOT/Models/whisperkit-coreml"
VENV="$REPO_ROOT/build/asr-venv"

echo "setup-asr-models.sh: engine=$ASR_ENGINE $ASR_ENGINE_VERSION"
echo "setup-asr-models.sh: repo=$HF_REPO_ID @ $HF_REVISION"
echo "setup-asr-models.sh: models=$MODELS"

model_complete() {
    model="$1"
    [ -d "$MODELS_DIR/$model/AudioEncoder.mlmodelc" ] \
        && [ -d "$MODELS_DIR/$model/TextDecoder.mlmodelc" ] \
        && [ -d "$MODELS_DIR/$model/MelSpectrogram.mlmodelc" ]
}

# Fast path: both models already present and complete.
all_complete=1
for MODEL_NAME in $MODELS; do
    if ! model_complete "$MODEL_NAME"; then
        all_complete=0
        break
    fi
done
if [ "$all_complete" -eq 1 ]; then
    echo "setup-asr-models.sh: both models already installed under $MODELS_DIR"
    exit 0
fi

# Isolated downloader venv (gitignored under build/).
if [ ! -x "$VENV/bin/python" ]; then
    echo "setup-asr-models.sh: creating downloader venv at $VENV"
    python3 -m venv "$VENV"
fi
"$VENV/bin/pip" install --quiet --disable-pip-version-check "huggingface_hub==$HF_HUB_VERSION"

for MODEL_NAME in $MODELS; do
    if model_complete "$MODEL_NAME"; then
        echo "setup-asr-models.sh: $MODEL_NAME already complete — skip download"
        continue
    fi

    echo "setup-asr-models.sh: downloading $MODEL_NAME (pinned revision)..."
    HF_REPO_ID="$HF_REPO_ID" HF_REVISION="$HF_REVISION" MODEL_NAME="$MODEL_NAME" MODELS_DIR="$MODELS_DIR" \
    "$VENV/bin/python" - <<'PY'
import os
from huggingface_hub import snapshot_download
snapshot_download(
    repo_id=os.environ["HF_REPO_ID"],
    revision=os.environ["HF_REVISION"],
    allow_patterns=[os.environ["MODEL_NAME"] + "/*"],
    local_dir=os.environ["MODELS_DIR"],
)
print("download complete")
PY

    for m in AudioEncoder.mlmodelc TextDecoder.mlmodelc MelSpectrogram.mlmodelc; do
        if [ ! -d "$MODELS_DIR/$MODEL_NAME/$m" ]; then
            echo "setup-asr-models.sh: FAIL: missing $MODEL_NAME/$m after download" >&2
            exit 1
        fi
    done
    echo "setup-asr-models.sh: model installed at $MODELS_DIR/$MODEL_NAME"
done

echo "setup-asr-models.sh: both models ready under $MODELS_DIR"
