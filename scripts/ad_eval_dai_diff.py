#!/usr/bin/env python3
"""One-extra-copy DAI differential gate: pinned ASR, windowed alignment, scoring."""

from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
import math
import re
import statistics
import subprocess
import time
import html
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

from ad_eval_corpus_score import DEFAULT_CORPUS, DEFAULT_WORKDIR, load_corpus
from ad_eval_score import boundary_errors, match_pairs, time_weighted
from ad_golden_transcribe import atomic_json, audio_duration, flatten_words, model_revision, validate_words

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_GATE = DEFAULT_CORPUS / "dai-differential-gate.json"
DEFAULT_MODEL = "mlx-community/whisper-large-v3-mlx"


@dataclass(frozen=True)
class Parameters:
    window_words: int = 1200
    overlap_words: int = 120
    search_padding_words: int = 900
    anchor_words: int = 8
    min_seconds: float = 5.0
    merge_gap_seconds: float = 3.0


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def initial_prompt(meta: dict[str, Any]) -> str:
    return ". ".join(part for part in (str(meta.get("showName") or "").strip(), str(meta.get("episodeTitle") or "").strip()) if part)


def asr_contract(meta: dict[str, Any], original_source: dict[str, Any]) -> dict[str, Any]:
    if not original_source.get("engine"):
        return {
            "engine": "mlx-whisper",
            "engineVersion": importlib.metadata.version("mlx-whisper"),
            "model": DEFAULT_MODEL,
            "modelRevision": model_revision(DEFAULT_MODEL),
            "language": "en",
            "wordTimestamps": True,
            "conditionOnPreviousText": False,
            "temperatureFallback": [0.0, 0.2, 0.4],
            "initialPrompt": initial_prompt(meta),
            "hallucinationSilenceThreshold": 2.0,
        }
    return {
        "engine": original_source["engine"],
        "engineVersion": original_source["engineVersion"],
        "model": original_source["model"],
        "modelRevision": original_source["modelRevision"],
        "language": original_source.get("language", "en"),
        "wordTimestamps": True,
        "conditionOnPreviousText": original_source.get("conditionOnPreviousText", False),
        "temperatureFallback": original_source.get("temperatureFallback", [0.0, 0.2, 0.4]),
        "initialPrompt": initial_prompt(meta),
        "hallucinationSilenceThreshold": 2.0,
    }


def validate_provenance(original: dict[str, Any], alternate: dict[str, Any], expected_prompt: str) -> None:
    for key in ("engine", "engineVersion", "model", "modelRevision", "language", "wordTimestamps", "conditionOnPreviousText", "temperatureFallback"):
        if alternate.get(key) != original.get(key):
            raise ValueError(f"ASR provenance mismatch for {key}")
    if alternate.get("initialPrompt") != expected_prompt:
        raise ValueError("ASR provenance mismatch for initialPrompt")
    validation = alternate.get("validation") or {}
    if float(validation.get("audioCoverage", 0)) < 0.95:
        raise ValueError("alternate transcript has incomplete audio coverage")


def transcribe_copy(workdir: Path, slug: str, copy: str) -> Path:
    directory = workdir / slug
    meta_path = directory / "meta.json"
    original_source_path = directory / "transcript_source.json"
    meta = json.loads(meta_path.read_text())
    if copy == "original":
        audio = workdir / str(meta["audioPath"])
        output_stem = "dai-original"
    else:
        audio = directory / f"audio-dai-{copy}.bin"
        output_stem = f"dai-{copy}"
    if not audio.exists():
        raise FileNotFoundError(audio)
    original_source = json.loads(original_source_path.read_text())
    contract = asr_contract(meta, original_source)
    if contract["engine"] != "mlx-whisper":
        raise ValueError(f"unsupported approved engine {contract['engine']}")
    import mlx_whisper

    started = time.monotonic()
    result = mlx_whisper.transcribe(
        str(audio), path_or_hf_repo=contract["model"], language=contract["language"],
        task="transcribe", word_timestamps=True,
        temperature=tuple(contract["temperatureFallback"]),
        condition_on_previous_text=contract["conditionOnPreviousText"],
        initial_prompt=contract["initialPrompt"] or None,
        hallucination_silence_threshold=contract["hallucinationSilenceThreshold"],
        verbose=False,
    )
    elapsed = time.monotonic() - started
    words = flatten_words(result)
    duration = audio_duration(audio)
    validation = validate_words(words, duration)
    transcript = directory / f"transcript-{output_stem}.json"
    transcript_hash = atomic_json(transcript, words)
    source = {
        "schemaVersion": 1, **contract, "audioFile": audio.name,
        "audioSha256": sha256(audio), "metadataSha256": sha256(meta_path),
        "audioDuration": round(duration, 6), "transcriptSha256": transcript_hash,
        "transcriptionSeconds": round(elapsed, 3), "validation": validation,
    }
    atomic_json(directory / f"transcript-{output_stem}_source.json", source)
    return transcript


def normalize(raw: str) -> str:
    return re.sub(r"[^a-z0-9']+", "", raw.lower())


def merge(spans: list[tuple[float, float]], gap: float) -> list[tuple[float, float]]:
    if not spans:
        return []
    out = [list(sorted(spans)[0])]
    for start, end in sorted(spans)[1:]:
        if start <= out[-1][1] + gap:
            out[-1][1] = max(out[-1][1], end)
        else:
            out.append([start, end])
    return [(float(start), float(end)) for start, end in out]


def has_repetitive_asr_hallucination(tokens: list[str], words: list[dict]) -> bool:
    """Reject low-information loops that Whisper can extend differently per pass."""
    if len(tokens) < 16:
        return False
    nonempty = [token for token in tokens if token]
    if not nonempty:
        return True
    unique_ratio = len(set(nonempty)) / len(nonempty)
    zero_duration_ratio = sum(float(word["end"]) <= float(word["start"]) for word in words) / len(words)
    fourgrams = [tuple(nonempty[i:i + 4]) for i in range(len(nonempty) - 3)]
    max_fourgram_repeats = max((fourgrams.count(gram) for gram in set(fourgrams)), default=0)
    return unique_ratio < 0.2 and (max_fourgram_repeats >= 4 or zero_duration_ratio >= 0.1)


def stable_blocks(a: list[str], b: list[str], p: Parameters) -> list[tuple[int, int, int]]:
    """Return monotonic stable matches found in bounded overlapping windows."""
    import difflib

    blocks: list[tuple[int, int, int]] = []
    ai = 0
    expected_b = 0
    step = max(1, p.window_words - p.overlap_words)
    while ai < len(a):
        ae = min(len(a), ai + p.window_words)
        bs = max(0, expected_b - p.search_padding_words)
        be = min(len(b), expected_b + (ae - ai) + p.search_padding_words)
        matcher = difflib.SequenceMatcher(a=a[ai:ae], b=b[bs:be], autojunk=False)
        candidates = [(ai + m.a, bs + m.b, m.size) for m in matcher.get_matching_blocks() if m.size >= p.anchor_words]
        for block in candidates:
            if blocks and (block[0] < blocks[-1][0] + blocks[-1][2] or block[1] < blocks[-1][1] + blocks[-1][2]):
                continue
            blocks.append(block)
        if candidates:
            last = candidates[-1]
            expected_b = last[1] + last[2]
        else:
            expected_b = min(len(b), expected_b + step)
        ai += step
    return blocks


def divergent_original_spans(original: list[dict], alternate: list[dict], p: Parameters = Parameters()) -> list[tuple[float, float]]:
    a = [normalize(word["word"]) for word in original]
    b = [normalize(word["word"]) for word in alternate]
    blocks = stable_blocks(a, b, p)
    anchors = [(0, 0, 0), *blocks, (len(a), len(b), 0)]
    spans: list[tuple[float, float]] = []
    for left, right in zip(anchors, anchors[1:]):
        i1, j1 = left[0] + left[2], left[1] + left[2]
        i2, j2 = right[0], right[1]
        if i2 <= i1:
            continue
        # Equal normalized text between anchors is alignment drift, not media divergence.
        if a[i1:i2] == b[j1:j2]:
            continue
        # Repeated speech/music can make Whisper hallucinate a long token loop on
        # one pass. It is not a reliable media-difference observation.
        if has_repetitive_asr_hallucination(a[i1:i2], original[i1:i2]) or has_repetitive_asr_hallucination(b[j1:j2], alternate[j1:j2]):
            continue
        start, end = float(original[i1]["start"]), float(original[i2 - 1]["end"])
        if end - start >= p.min_seconds:
            spans.append((start, end))
    return [span for span in merge(spans, p.merge_gap_seconds) if span[1] - span[0] >= p.min_seconds]


def unbounded_sequence_matcher_spans(original: list[dict], alternate: list[dict], p: Parameters = Parameters()) -> list[tuple[float, float]]:
    import difflib

    a = [normalize(word["word"]) for word in original]
    b = [normalize(word["word"]) for word in alternate]
    spans: list[tuple[float, float]] = []
    for tag, i1, i2, _j1, _j2 in difflib.SequenceMatcher(a=a, b=b, autojunk=False).get_opcodes():
        if tag not in {"delete", "replace"} or i2 <= i1:
            continue
        start, end = float(original[i1]["start"]), float(original[i2 - 1]["end"])
        if end - start >= p.min_seconds:
            spans.append((start, end))
    return [span for span in merge(spans, p.merge_gap_seconds) if span[1] - span[0] >= p.min_seconds]


def score_predictions(predictions: list[tuple[float, float]], golden_data: dict[str, Any], duration: float) -> dict[str, Any]:
    all_gold = [(float(s["start"]), float(s["end"])) for s in golden_data["spans"]]
    dynamic_gold = [(float(s["start"]), float(s["end"])) for s in golden_data["spans"] if s.get("delivery") == "dynamic" or s.get("label") == "paid_dai"]
    all_metrics = time_weighted(predictions, all_gold)
    dynamic_metrics = time_weighted(predictions, dynamic_gold)
    seg, matches = match_pairs(predictions, all_gold)
    return {
        "allRemovable": all_metrics, "dynamic": dynamic_metrics,
        "contentLossSecondsPerListeningHour": round(all_metrics["falsePositiveSeconds"] / duration * 3600, 3) if duration else 0.0,
        "spanPrecision": round(seg.precision, 4), "spanRecall": round(seg.recall, 4),
        "boundary": boundary_errors(predictions, all_gold, matches),
    }


def evaluate_episode(workdir: Path, corpus: Path, slug: str, copy: str, p: Parameters, reference: str = "approved", algorithm: str = "windowed") -> dict[str, Any]:
    _split, goldens = load_corpus(corpus, workdir)
    directory = workdir / slug
    reference_prefix = "transcript" if reference == "approved" else "transcript-dai-original"
    original_source = json.loads((directory / f"{reference_prefix}_source.json").read_text())
    alternate_source = json.loads((directory / f"transcript-dai-{copy}_source.json").read_text())
    meta = json.loads((directory / "meta.json").read_text())
    validate_provenance(original_source, alternate_source, initial_prompt(meta))
    original = json.loads((directory / f"{reference_prefix}.json").read_text())
    alternate = json.loads((directory / f"transcript-dai-{copy}.json").read_text())
    started = time.monotonic()
    predictions = unbounded_sequence_matcher_spans(original, alternate, p) if algorithm == "unbounded" else divergent_original_spans(original, alternate, p)
    alignment_seconds = time.monotonic() - started
    duration = float(original[-1]["end"]) if original else 0.0
    return {
        "slug": slug, "copy": copy, "reference": reference, "algorithm": algorithm, "parameters": asdict(p), "durationSeconds": round(duration, 3),
        "predictedSpans": [{"start": round(s, 3), "end": round(e, 3)} for s, e in predictions],
        "metrics": score_predictions(predictions, goldens[slug], duration),
        "resources": {
            "alternateAudioBytes": (directory / f"audio-dai-{copy}.bin").stat().st_size,
            "alternateTranscriptBytes": (directory / f"transcript-dai-{copy}.json").stat().st_size,
            "temporaryWorkingSetBytes": (directory / f"audio-dai-{copy}.bin").stat().st_size + (directory / f"transcript-dai-{copy}.json").stat().st_size,
            "transcriptionSeconds": alternate_source.get("transcriptionSeconds"),
            "alignmentSeconds": round(alignment_seconds, 3),
        },
    }


def aggregate(rows: list[dict[str, Any]]) -> dict[str, Any]:
    if not rows:
        return {}
    tp = sum(r["metrics"]["allRemovable"]["truePositiveSeconds"] for r in rows)
    pred = sum(r["metrics"]["allRemovable"]["predictedAdSeconds"] for r in rows)
    dyn_tp = sum(r["metrics"]["dynamic"]["truePositiveSeconds"] for r in rows)
    dyn_gold = sum(r["metrics"]["dynamic"]["goldenAdSeconds"] for r in rows)
    total_gold = sum(r["metrics"]["allRemovable"]["goldenAdSeconds"] for r in rows)
    total_fp = sum(r["metrics"]["allRemovable"]["falsePositiveSeconds"] for r in rows)
    duration = sum(r["durationSeconds"] for r in rows)
    return {
        "allRemovablePrecision": round(tp / pred, 4) if pred else 1.0,
        "allRemovableRecall": round(tp / total_gold, 4) if total_gold else 1.0,
        "dynamicRecall": round(dyn_tp / dyn_gold, 4) if dyn_gold else 1.0,
        "contentLossSecondsPerListeningHour": round(total_fp / duration * 3600, 3) if duration else 0.0,
        "maximumEpisodeContentLossSecondsPerHour": max(r["metrics"]["contentLossSecondsPerListeningHour"] for r in rows),
    }


def parameter_grid() -> list[Parameters]:
    return [Parameters(window_words=w, anchor_words=a, min_seconds=m, merge_gap_seconds=g) for w in (800, 1200) for a in (6, 10) for m in (3.0, 5.0, 8.0) for g in (1.0, 3.0)]


def tune(
    workdir: Path,
    corpus: Path,
    slugs: list[str],
    references: dict[str, str] | None = None,
) -> tuple[Parameters, list[dict[str, Any]], list[dict[str, Any]]]:
    references = references or {}
    candidates: list[tuple[tuple[float, float, float], Parameters, list[dict[str, Any]]]] = []
    for p in parameter_grid():
        rows = [evaluate_episode(workdir, corpus, slug, "a", p, references.get(slug, "approved")) for slug in slugs]
        total_fp = sum(r["metrics"]["allRemovable"]["falsePositiveSeconds"] for r in rows)
        dyn_tp = sum(r["metrics"]["dynamic"]["truePositiveSeconds"] for r in rows)
        deltas = [value for r in rows for key in ("medianAbsDeltaStart", "medianAbsDeltaEnd") if (value := r["metrics"]["boundary"].get(key)) is not None]
        candidates.append(((total_fp, -dyn_tp, statistics.median(deltas) if deltas else math.inf), p, rows))
    candidates.sort(key=lambda item: item[0])
    search = [
        {
            "parameters": asdict(parameters),
            "selection": {
                "contentLossSeconds": round(key[0], 3),
                "dynamicCoveredSeconds": round(-key[1], 3),
                "medianBoundaryErrorSeconds": None if math.isinf(key[2]) else round(key[2], 3),
            },
            "aggregate": aggregate(rows),
        }
        for key, parameters, rows in candidates
    ]
    return candidates[0][1], candidates[0][2], search


def swift_predictions(binary: Path, transcript: Path) -> list[tuple[float, float]]:
    result = subprocess.run([str(binary), "--approach", "v6.1", str(transcript)], capture_output=True, text=True, check=True)
    return [(float(s["start"]), float(s["end"])) for s in json.loads(result.stdout)["segments"]]


def hybrid_row(workdir: Path, corpus: Path, row: dict[str, Any], binary: Path) -> tuple[dict[str, Any], dict[str, Any]]:
    _split, goldens = load_corpus(corpus, workdir)
    slug = row["slug"]
    transcript = json.loads((workdir / slug / "transcript.json").read_text())
    duration = float(transcript[-1]["end"]) if transcript else 0.0
    dai = [(float(s["start"]), float(s["end"])) for s in row["predictedSpans"]]
    v6 = swift_predictions(binary, workdir / slug / "transcript.json")
    hybrid = merge(dai + v6, 0.0)
    base = {"slug": slug, "durationSeconds": duration, "predictedSpans": [{"start": s, "end": e} for s, e in v6], "metrics": score_predictions(v6, goldens[slug], duration)}
    combined = {"slug": slug, "durationSeconds": duration, "predictedSpans": [{"start": s, "end": e} for s, e in hybrid], "metrics": score_predictions(hybrid, goldens[slug], duration)}
    return base, combined


def subtract(spans: list[tuple[float, float]], truth: list[tuple[float, float]]) -> list[tuple[float, float]]:
    remaining: list[tuple[float, float]] = []
    for start, end in spans:
        pieces = [(start, end)]
        for cut_start, cut_end in truth:
            next_pieces: list[tuple[float, float]] = []
            for piece_start, piece_end in pieces:
                if cut_end <= piece_start or cut_start >= piece_end:
                    next_pieces.append((piece_start, piece_end))
                else:
                    if piece_start < cut_start:
                        next_pieces.append((piece_start, cut_start))
                    if cut_end < piece_end:
                        next_pieces.append((cut_end, piece_end))
            pieces = next_pieces
        remaining.extend((s, e) for s, e in pieces if e > s)
    return remaining


def write_failure_packets(workdir: Path, corpus: Path, rows: list[dict[str, Any]]) -> None:
    _split, goldens = load_corpus(corpus, workdir)
    failures: list[dict[str, Any]] = []
    for row in rows:
        slug = row["slug"]
        predicted = [(float(s["start"]), float(s["end"])) for s in row["predictedSpans"]]
        truth = [(float(s["start"]), float(s["end"])) for s in goldens[slug]["spans"]]
        failures.extend({"slug": slug, "mode": "false-positive", "start": s, "end": e, "seconds": round(e - s, 3)} for s, e in subtract(predicted, truth))
        failures.extend({"slug": slug, "mode": "miss", "start": s, "end": e, "seconds": round(e - s, 3)} for s, e in subtract(truth, predicted))
    failures.sort(key=lambda item: (-item["seconds"], item["slug"], item["start"]))
    directory = workdir / "failure-packets"
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "dai-differential.json").write_text(json.dumps(failures, indent=2) + "\n")
    items = "".join(f"<li><b>{html.escape(item['slug'])}</b> {item['mode']} {item['start']:.2f}–{item['end']:.2f} ({item['seconds']:.2f}s)</li>" for item in failures)
    (directory / "dai-differential.html").write_text(f"<!doctype html><meta charset=utf-8><title>DAI differential failures</title><h1>DAI differential failures</h1><ol>{items}</ol>\n")


def repeatability(candidate: list[dict[str, Any]], diagnostic: list[dict[str, Any]]) -> dict[str, Any]:
    by_slug = {row["slug"]: row for row in diagnostic}
    rows: list[dict[str, Any]] = []
    for row in candidate:
        other = by_slug[row["slug"]]
        a = [(float(s["start"]), float(s["end"])) for s in row["predictedSpans"]]
        b = [(float(s["start"]), float(s["end"])) for s in other["predictedSpans"]]
        rows.append({"slug": row["slug"], "aAsReference": time_weighted(b, a), "bAsReference": time_weighted(a, b)})
    return {"episodes": rows}


def gate_run(workdir: Path, corpus: Path, gate_path: Path, output: Path, swift_cli: Path) -> dict[str, Any]:
    gate = json.loads(gate_path.read_text())
    references = gate.get("referenceOverrides", {})
    preflight_controls = [evaluate_episode(workdir, corpus, slug, "a", Parameters(), references.get(slug, "approved")) for slug in gate["negativeControls"]]
    if any(row["predictedSpans"] for row in preflight_controls):
        report = {"schemaVersion": 1, "status": "blocked-by-negative-control", "negativeControls": preflight_controls}
        output.write_text(json.dumps(report, indent=2) + "\n")
        return report
    sequence_matcher_baseline = [
        evaluate_episode(workdir, corpus, slug, "a", Parameters(), references.get(slug, "approved"), algorithm="unbounded")
        for slug in gate["development"]
    ]
    chosen, development, parameter_search = tune(workdir, corpus, gate["development"], references)
    controls = [evaluate_episode(workdir, corpus, slug, "a", chosen, references.get(slug, "approved")) for slug in gate["negativeControls"]]
    validation = [evaluate_episode(workdir, corpus, slug, "a", chosen, references.get(slug, "approved")) for slug in gate["validation"]]
    diagnostic = [evaluate_episode(workdir, corpus, slug, "b", chosen, references.get(slug, "approved")) for slug in gate["validation"]]
    summary = aggregate(validation)
    baseline_rows: list[dict[str, Any]] = []
    hybrid_rows: list[dict[str, Any]] = []
    for row in validation:
        baseline, hybrid = hybrid_row(workdir, corpus, row, swift_cli)
        baseline_rows.append(baseline)
        hybrid_rows.append(hybrid)
    baseline_summary, hybrid_summary = aggregate(baseline_rows), aggregate(hybrid_rows)
    thresholds = gate["gate"]
    controls_clear = not any(row["predictedSpans"] for row in controls)
    hybrid_added_loss = hybrid_summary["contentLossSecondsPerListeningHour"] - baseline_summary["contentLossSecondsPerListeningHour"]
    passed = (
        controls_clear
        and
        summary["allRemovablePrecision"] >= thresholds["minimumAllRemovablePrecision"]
        and summary["dynamicRecall"] >= thresholds["minimumDynamicRecall"]
        and summary["maximumEpisodeContentLossSecondsPerHour"] <= thresholds["maximumEpisodeContentLossSecondsPerHour"]
        and hybrid_summary["allRemovableRecall"] > baseline_summary["allRemovableRecall"]
        and hybrid_added_loss <= thresholds["maximumHybridAddedContentLossSecondsPerHour"]
    )
    report = {
        "schemaVersion": 1, "status": "pass" if passed else "fail",
        "selectedParameters": asdict(chosen), "summary": summary,
        "parameterSearch": parameter_search,
        "negativeControls": controls, "development": development,
        "sequenceMatcherDevelopmentBaseline": sequence_matcher_baseline,
        "validation": validation, "copyBDiagnostic": diagnostic,
        "copyRepeatability": repeatability(validation, diagnostic),
        "v6BaselineSummary": baseline_summary, "hybridSummary": hybrid_summary,
        "hybridAddedContentLossSecondsPerListeningHour": round(hybrid_added_loss, 3),
    }
    output.write_text(json.dumps(report, indent=2) + "\n")
    write_failure_packets(workdir, corpus, validation)
    return report


def prepare_gate(workdir: Path, manifest_path: Path) -> None:
    gate = json.loads(manifest_path.read_text())
    jobs: list[tuple[str, str]] = []
    jobs.extend((slug, "original") for slug, reference in gate.get("referenceOverrides", {}).items() if reference == "matched-rerun")
    jobs.extend((slug, "a") for slug in gate["negativeControls"])
    jobs.extend((slug, "a") for slug in gate["development"])
    jobs.extend((slug, "a") for slug in gate["validation"])
    jobs.extend((slug, "b") for slug in gate["validation"])
    for slug, copy in jobs:
        stem = "dai-original" if copy == "original" else f"dai-{copy}"
        transcript = workdir / slug / f"transcript-{stem}.json"
        source = workdir / slug / f"transcript-{stem}_source.json"
        if transcript.exists() and source.exists():
            print(f"[{slug}:{copy}] prepared, skipping")
            continue
        print(f"[{slug}:{copy}] transcribing")
        transcribe_copy(workdir, slug, copy)


def main() -> None:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    transcribe = sub.add_parser("transcribe")
    transcribe.add_argument("--show", required=True)
    transcribe.add_argument("--copy", choices=["original", "a", "b"], default="a")
    evaluate = sub.add_parser("evaluate")
    evaluate.add_argument("--show", required=True)
    evaluate.add_argument("--copy", choices=["a", "b"], default="a")
    evaluate.add_argument("--reference", choices=["approved", "matched-rerun"], default="approved")
    run = sub.add_parser("gate")
    run.add_argument("--manifest", type=Path, default=DEFAULT_GATE)
    run.add_argument("--output", type=Path, default=DEFAULT_WORKDIR / "dai-differential-gate-results.json")
    run.add_argument("--swift-cli", type=Path, required=True)
    prepare = sub.add_parser("prepare")
    prepare.add_argument("--manifest", type=Path, default=DEFAULT_GATE)
    for command in (transcribe, evaluate, run, prepare):
        command.add_argument("--workdir", type=Path, default=DEFAULT_WORKDIR)
        command.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    args = parser.parse_args()
    if args.command == "transcribe":
        print(transcribe_copy(args.workdir.resolve(), args.show, args.copy))
    elif args.command == "evaluate":
        print(json.dumps(evaluate_episode(args.workdir.resolve(), args.corpus.resolve(), args.show, args.copy, Parameters(), args.reference), indent=2))
    elif args.command == "prepare":
        prepare_gate(args.workdir.resolve(), args.manifest.resolve())
    else:
        print(json.dumps(gate_run(args.workdir.resolve(), args.corpus.resolve(), args.manifest.resolve(), args.output.resolve(), args.swift_cli.resolve()), indent=2))


if __name__ == "__main__":
    main()
