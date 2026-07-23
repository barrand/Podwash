#!/usr/bin/env python3
"""Offline DAI word-diff prototype for one original/copy-B transcript pair."""

from __future__ import annotations

import argparse
import difflib
import json
import re
from pathlib import Path
from typing import Any

from ad_eval_corpus_score import DEFAULT_CORPUS, DEFAULT_WORKDIR, load_corpus
from ad_eval_score import time_weighted
from ad_eval_transcribe import transcribe_faster_whisper
from ad_golden_transcribe import flatten_words


def normalize(raw: str) -> str:
    return re.sub(r"[^a-z0-9']+", "", raw.lower())


def merge(spans: list[tuple[float, float]], gap: float = 3.0) -> list[tuple[float, float]]:
    if not spans:
        return []
    out = [list(sorted(spans)[0])]
    for start, end in sorted(spans)[1:]:
        if start <= out[-1][1] + gap:
            out[-1][1] = max(out[-1][1], end)
        else:
            out.append([start, end])
    return [(float(start), float(end)) for start, end in out]


def divergent_original_spans(original: list[dict], alternate: list[dict], min_seconds: float = 5.0) -> list[tuple[float, float]]:
    """Return original-copy regions replaced or removed in the alternate copy.

    Insertions exist only in the alternate copy and have no original timestamp;
    they deliberately do not become a prediction for this original-copy eval.
    """
    a = [normalize(word["word"]) for word in original]
    b = [normalize(word["word"]) for word in alternate]
    matcher = difflib.SequenceMatcher(a=a, b=b, autojunk=False)
    spans: list[tuple[float, float]] = []
    for tag, i1, i2, _j1, _j2 in matcher.get_opcodes():
        if tag not in {"delete", "replace"} or i2 <= i1:
            continue
        start, end = float(original[i1]["start"]), float(original[i2 - 1]["end"])
        if end - start >= min_seconds:
            spans.append((start, end))
    return [span for span in merge(spans) if span[1] - span[0] >= min_seconds]


def transcribe_mlx(audio: Path, model: str) -> list[dict]:
    import mlx_whisper

    result = mlx_whisper.transcribe(
        str(audio), path_or_hf_repo=model, language="en", task="transcribe",
        word_timestamps=True, temperature=(0.0, 0.2, 0.4),
        condition_on_previous_text=False, hallucination_silence_threshold=2.0,
        verbose=False,
    )
    return flatten_words(result)


def run_show(workdir: Path, corpus: Path, slug: str, model: str, engine: str, transcribe: bool) -> dict[str, Any]:
    _split, goldens = load_corpus(corpus, workdir)
    if slug not in goldens:
        raise ValueError(f"{slug} is not in the tracked corpus")
    directory = workdir / slug
    alternate_path = directory / "audio-dai-a.bin"
    alternate_transcript = directory / "transcript-dai-a.json"
    if transcribe:
        if not alternate_path.exists():
            raise FileNotFoundError(alternate_path)
        alternate = transcribe_mlx(alternate_path, model) if engine == "mlx" else transcribe_faster_whisper(alternate_path, model)
        alternate_transcript.write_text(json.dumps(alternate, indent=2) + "\n")
    elif alternate_transcript.exists():
        alternate = json.loads(alternate_transcript.read_text())
    else:
        raise FileNotFoundError(f"missing {alternate_transcript}; pass --transcribe")
    original = json.loads((directory / "transcript.json").read_text())
    predictions = divergent_original_spans(original, alternate)
    golden = [(float(s["start"]), float(s["end"])) for s in goldens[slug]["spans"]]
    metrics = time_weighted(predictions, golden)
    payload: dict[str, Any] = {
        "schemaVersion": 1,
        "slug": slug,
        "model": model, "engine": engine,
        "originalWordCount": len(original),
        "alternateWordCount": len(alternate),
        "predictedSpans": [{"start": round(s, 3), "end": round(e, 3)} for s, e in predictions],
        "timeWeighted": metrics,
    }
    (directory / "dai-diff-a.json").write_text(json.dumps(payload, indent=2) + "\n")
    return payload


def main() -> None:
    parser = argparse.ArgumentParser(description="Score copy-A DAI word diff against the original-copy golden")
    parser.add_argument("--show", required=True)
    parser.add_argument("--workdir", type=Path, default=DEFAULT_WORKDIR)
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    parser.add_argument("--engine", choices=["mlx", "faster-whisper"], default="mlx")
    parser.add_argument("--model", default="mlx-community/whisper-large-v3-mlx")
    parser.add_argument("--transcribe", action="store_true")
    args = parser.parse_args()
    payload = run_show(args.workdir.resolve(), args.corpus.resolve(), args.show, args.model, args.engine, args.transcribe)
    print(json.dumps(payload, indent=2))


if __name__ == "__main__":
    main()
