#!/usr/bin/env bash
# Build a macOS CLI that runs TopicLLMSegmenter (Foundation Models when available).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${ROOT}/build/labeler-cli"
mkdir -p "${ROOT}/build"
swiftc -O -parse-as-library \
  -module-name LabelerCLI \
  -framework FoundationModels \
  -o "${OUT}" \
  "${ROOT}/PodWash/PodWash/TimedWord.swift" \
  "${ROOT}/PodWash/PodWash/ContentSegmenting.swift" \
  "${ROOT}/PodWash/PodWash/HeuristicContentSegmenter.swift" \
  "${ROOT}/PodWash/PodWash/SegmentationContext.swift" \
  "${ROOT}/PodWash/PodWash/TranscriptWindowChunker.swift" \
  "${ROOT}/PodWash/PodWash/AdSpanStitcher.swift" \
  "${ROOT}/PodWash/PodWash/TopicLLMPrompts.swift" \
  "${ROOT}/PodWash/PodWash/TopicLLMSegmenter.swift" \
  "${ROOT}/Tools/LabelerCLI/main.swift"
echo "Built ${OUT}"
