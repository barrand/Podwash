#!/usr/bin/env bash
# Build a macOS CLI that runs the shipped HeuristicContentSegmenter.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${ROOT}/build/segmenter-cli"
mkdir -p "${ROOT}/build"
swiftc -O -parse-as-library \
  -module-name SegmenterCLI \
  -o "${OUT}" \
  "${ROOT}/PodWash/PodWash/TimedWord.swift" \
  "${ROOT}/PodWash/PodWash/ContentSegmenting.swift" \
  "${ROOT}/PodWash/PodWash/HeuristicContentSegmenter.swift" \
  "${ROOT}/Tools/SegmenterCLI/main.swift"
echo "Built ${OUT}"
