#!/bin/sh
# PodWash ASR model setup — one-time, pinned download of the WhisperKit Core ML model
# used by the Slice 05 ASR benchmark. Models land in the gitignored Models/ directory
# (never committed; see .gitignore). Re-running is idempotent.
#
# Usage:
#   scripts/setup-asr-models.sh
#
# What/why:
#   - ASR stack (ADR-003): WhisperKit (Core ML). Apple's SpeechAnalyzer/SpeechTranscriber
#     models are NOT provisioned on the iOS Simulator (supportedLocales is empty), so it
#     cannot run in the simulator-only dark-factory pipeline. WhisperKit runs on the
#     simulator and is therefore the verifiable stack. iOS floor stays at 26.1.
#   - The model is pinned by an EXACT HuggingFace repo revision (AC3), so every machine
#     and CI run downloads byte-identical Core ML weights.
#
# Pinned model (edit here to bump; keep in sync with the fixture README + ADR-003):
ASR_ENGINE="WhisperKit"
ASR_ENGINE_VERSION="1.0.0"                                   # SPM exactVersion pin
HF_REPO_ID="argmaxinc/whisperkit-coreml"
HF_REVISION="97a5bf9bbc74c7d9c12c755d04dea59e672e3808"       # EXACT model revision pin
MODEL_NAME="openai_whisper-tiny.en"
HF_HUB_VERSION="0.25.2"                                      # downloader pin

set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$REPO_ROOT"

MODELS_DIR="$REPO_ROOT/Models/whisperkit-coreml"
MODEL_DIR="$MODELS_DIR/$MODEL_NAME"
VENV="$REPO_ROOT/build/asr-venv"

echo "setup-asr-models.sh: engine=$ASR_ENGINE $ASR_ENGINE_VERSION"
echo "setup-asr-models.sh: model=$HF_REPO_ID/$MODEL_NAME @ $HF_REVISION"

# Fast path: already present and complete.
if [ -d "$MODEL_DIR/AudioEncoder.mlmodelc" ] && [ -d "$MODEL_DIR/TextDecoder.mlmodelc" ] \
   && [ -d "$MODEL_DIR/MelSpectrogram.mlmodelc" ]; then
    echo "setup-asr-models.sh: model already installed at $MODEL_DIR"
    exit 0
fi

# Isolated downloader venv (gitignored under build/).
if [ ! -x "$VENV/bin/python" ]; then
    echo "setup-asr-models.sh: creating downloader venv at $VENV"
    python3 -m venv "$VENV"
fi
"$VENV/bin/pip" install --quiet --disable-pip-version-check "huggingface_hub==$HF_HUB_VERSION"

echo "setup-asr-models.sh: downloading (pinned revision)..."
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

# Integrity check — the three compiled Core ML models must be present.
for m in AudioEncoder.mlmodelc TextDecoder.mlmodelc MelSpectrogram.mlmodelc; do
    if [ ! -d "$MODEL_DIR/$m" ]; then
        echo "setup-asr-models.sh: FAIL: missing $MODEL_NAME/$m after download" >&2
        exit 1
    fi
done

echo "setup-asr-models.sh: model installed at $MODEL_DIR"
