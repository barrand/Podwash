#!/usr/bin/env python3
"""Create a high-quality word-timed transcript for ad-golden review."""

from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
import math
import os
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_WORKDIR = ROOT / "tmp" / "ad-eval"
DEFAULT_MODEL = "mlx-community/whisper-large-v3-mlx"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def audio_duration(path: Path) -> float:
    result = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "default=noprint_wrappers=1:nokey=1",
            str(path),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return float(result.stdout.strip())


def atomic_json(path: Path, payload: Any) -> str:
    encoded = (json.dumps(payload, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_name, path)
    except BaseException:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass
        raise
    return hashlib.sha256(encoded).hexdigest()


def flatten_words(result: dict[str, Any]) -> list[dict[str, Any]]:
    words: list[dict[str, Any]] = []
    for segment in result.get("segments") or []:
        for raw in segment.get("words") or []:
            token = str(raw.get("word") or "").strip()
            if not token:
                continue
            words.append(
                {
                    "word": token,
                    "start": round(float(raw["start"]), 3),
                    "end": round(float(raw["end"]), 3),
                }
            )
    return words


def validate_words(words: list[dict[str, Any]], duration: float) -> dict[str, Any]:
    if not words:
        raise ValueError("transcription returned no timed words")

    previous_start = -1.0
    invalid_ranges = 0
    backwards = 0
    overlaps = 0
    max_gap = 0.0
    max_gap_after = 0.0
    previous_end = 0.0

    for index, word in enumerate(words):
        start = float(word["start"])
        end = float(word["end"])
        if not math.isfinite(start) or not math.isfinite(end) or start < 0 or end < start:
            invalid_ranges += 1
        if start < previous_start:
            backwards += 1
        if index and start < previous_end:
            overlaps += 1
        gap = start - previous_end
        if gap > max_gap:
            max_gap = gap
            max_gap_after = previous_end
        previous_start = start
        previous_end = max(previous_end, end)

    if invalid_ranges:
        raise ValueError(f"transcript contains {invalid_ranges} invalid word ranges")
    if backwards:
        raise ValueError(f"transcript contains {backwards} backwards word starts")
    if previous_end > duration + 5.0:
        raise ValueError(
            f"last word ends at {previous_end:.2f}s, beyond audio duration {duration:.2f}s"
        )

    coverage = previous_end / duration if duration else 0.0
    if coverage < 0.95:
        raise ValueError(
            f"transcript ends too early: {previous_end:.2f}s of {duration:.2f}s "
            f"({coverage:.1%})"
        )

    return {
        "wordCount": len(words),
        "firstWordStart": words[0]["start"],
        "lastWordEnd": words[-1]["end"],
        "audioCoverage": round(coverage, 6),
        "overlappingWordStarts": overlaps,
        "maxSilenceGap": round(max_gap, 3),
        "maxSilenceGapAfter": round(max_gap_after, 3),
    }


def model_revision(model: str) -> str:
    try:
        from huggingface_hub import HfApi

        return str(HfApi().model_info(model).sha or "unknown")
    except Exception:
        return "unknown"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--show", required=True)
    parser.add_argument("--workdir", type=Path, default=DEFAULT_WORKDIR)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--model", default=DEFAULT_MODEL)
    args = parser.parse_args()

    source_dir = args.workdir.resolve() / args.show
    output_dir = args.output_dir.resolve() if args.output_dir else source_dir
    audio_path = source_dir / "audio.mp3"
    meta_path = source_dir / "meta.json"
    if not audio_path.exists() or not meta_path.exists():
        raise FileNotFoundError(f"missing Cougar source input under {source_dir}")

    meta = json.loads(meta_path.read_text(encoding="utf-8"))
    prompt_parts = [
        str(meta.get("showName") or "").strip(),
        str(meta.get("episodeTitle") or "").strip(),
    ]
    initial_prompt = ". ".join(part for part in prompt_parts if part)

    import mlx_whisper

    result = mlx_whisper.transcribe(
        str(audio_path),
        path_or_hf_repo=args.model,
        language="en",
        task="transcribe",
        word_timestamps=True,
        temperature=(0.0, 0.2, 0.4),
        condition_on_previous_text=False,
        initial_prompt=initial_prompt or None,
        hallucination_silence_threshold=2.0,
        verbose=False,
    )
    words = flatten_words(result)
    duration = audio_duration(audio_path)
    validation = validate_words(words, duration)

    transcript_path = output_dir / "transcript.json"
    transcript_hash = atomic_json(transcript_path, words)
    source = {
        "schemaVersion": 1,
        "engine": "mlx-whisper",
        "engineVersion": importlib.metadata.version("mlx-whisper"),
        "model": args.model,
        "modelRevision": model_revision(args.model),
        "language": "en",
        "wordTimestamps": True,
        "conditionOnPreviousText": False,
        "temperatureFallback": [0.0, 0.2, 0.4],
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "audioFile": "audio.mp3",
        "audioSha256": sha256_file(audio_path),
        "metadataSha256": sha256_file(meta_path),
        "audioDuration": round(duration, 6),
        "transcriptSha256": transcript_hash,
        "validation": validation,
    }
    atomic_json(output_dir / "transcript_source.json", source)

    print(
        f"[{args.show}] wrote {validation['wordCount']} words to {transcript_path} "
        f"(coverage {validation['audioCoverage']:.1%})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
