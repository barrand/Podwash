#!/usr/bin/env python3
"""Score Swift segmenters against the tracked human-approved ad corpus."""

from __future__ import annotations

import argparse
import hashlib
import html
import json
import subprocess
from collections import defaultdict
from pathlib import Path
from typing import Any

from ad_eval_score import boundary_errors, excerpt, failure_modes, match_pairs, time_weighted

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CORPUS = ROOT / "eval" / "ad-detection"
DEFAULT_WORKDIR = ROOT / "tmp" / "ad-eval"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_corpus(corpus: Path, workdir: Path) -> tuple[dict[str, str], dict[str, dict[str, Any]]]:
    manifest = json.loads((corpus / "corpus-manifest.json").read_text())
    if manifest.get("schemaVersion") != 1:
        raise ValueError("unsupported corpus manifest schema")
    split: dict[str, str] = {}
    for name in ("development", "holdout"):
        for slug in manifest.get(name, []):
            if slug in split:
                raise ValueError(f"duplicate corpus slug: {slug}")
            split[slug] = name
    goldens: dict[str, dict[str, Any]] = {}
    for path in sorted((corpus / "goldens").glob("*.json")):
        data = json.loads(path.read_text())
        slug = path.stem
        if data.get("schemaVersion") != 1 or data.get("status") != "human-approved":
            raise ValueError(f"{path}: not a schema-v1 human-approved golden")
        if data.get("showSlug") != slug or slug not in split:
            raise ValueError(f"{path}: invalid slug or absent from manifest")
        transcript = workdir / slug / "transcript.json"
        if not transcript.exists():
            raise ValueError(f"{slug}: missing local transcript {transcript}")
        if data.get("transcriptSha256") != sha256(transcript):
            raise ValueError(f"{slug}: transcript hash does not match approved golden")
        words = json.loads(transcript.read_text())
        last_end = -1.0
        for span in data.get("spans", []):
            start_word, end_word = span.get("startWord"), span.get("endWord")
            if not isinstance(start_word, int) or not isinstance(end_word, int) or not (0 <= start_word < end_word <= len(words)):
                raise ValueError(f"{slug}: invalid word range {span.get('id')}")
            if float(span["start"]) < last_end or float(span["end"]) <= float(span["start"]):
                raise ValueError(f"{slug}: unordered or empty span {span.get('id')}")
            if abs(float(span["start"]) - float(words[start_word]["start"])) > 0.06:
                raise ValueError(f"{slug}: start timestamp does not match word boundary")
            if abs(float(span["end"]) - float(words[end_word - 1]["end"])) > 0.06:
                raise ValueError(f"{slug}: end timestamp does not match word boundary")
            last_end = float(span["end"])
        goldens[slug] = data
    if set(split) != set(goldens):
        raise ValueError("manifest and tracked goldens do not name exactly the same episodes")
    return split, goldens


def run_cli(binary: Path, approach: str, transcript: Path) -> tuple[str, list[tuple[float, float]]]:
    result = subprocess.run([str(binary), "--approach", approach, str(transcript)], text=True, capture_output=True, check=True)
    payload = json.loads(result.stdout)
    return str(payload["approach"]), [(float(s["start"]), float(s["end"])) for s in payload["segments"]]


def overlap(a: tuple[float, float], b: tuple[float, float]) -> float:
    return max(0.0, min(a[1], b[1]) - max(a[0], b[0]))


def grouped_coverage(predictions: list[tuple[float, float]], spans: list[dict[str, Any]], key: str) -> dict[str, dict[str, float]]:
    out: dict[str, dict[str, float]] = {}
    groups: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for span in spans:
        groups[str(span.get(key, "unknown"))].append(span)
    for value, members in sorted(groups.items()):
        seconds = sum(float(s["end"]) - float(s["start"]) for s in members)
        covered = sum(min(float(s["end"]) - float(s["start"]), sum(overlap(p, (float(s["start"]), float(s["end"]))) for p in predictions)) for s in members)
        out[value] = {"goldenSeconds": round(seconds, 3), "coveredSeconds": round(covered, 3), "coverage": round(covered / seconds, 4) if seconds else 1.0}
    return out


def score_episode(slug: str, split: str, golden: dict[str, Any], workdir: Path, binary: Path, approach: str) -> dict[str, Any]:
    transcript = workdir / slug / "transcript.json"
    words = json.loads(transcript.read_text())
    actual_approach, predictions = run_cli(binary, approach, transcript)
    spans = list(golden["spans"])
    gold = [(float(s["start"]), float(s["end"])) for s in spans]
    seg, matches = match_pairs(predictions, gold)
    tw = time_weighted(predictions, gold)
    duration = float(words[-1]["end"]) if words else 0.0
    harm = tw["falsePositiveSeconds"] / duration * 3600 if duration else 0.0
    missed = tw["falseNegativeSeconds"] / duration * 3600 if duration else 0.0
    return {
        "slug": slug, "split": split, "approach": actual_approach, "durationSeconds": round(duration, 3),
        "precision": round(seg.precision, 4), "recall": round(seg.recall, 4),
        "truePositives": seg.true_positives, "falsePositives": seg.false_positives, "falseNegatives": seg.false_negatives,
        "timeWeighted": tw, "contentLossSecondsPerListeningHour": round(harm, 3),
        "missedAdSecondsPerListeningHour": round(missed, 3), "boundary": boundary_errors(predictions, gold, matches),
        "failureModes": failure_modes(predictions, gold, matches),
        "predictions": [{"start": p[0], "end": p[1], "excerpt": excerpt(words, *p)} for p in predictions],
        "breakdowns": {key: grouped_coverage(predictions, spans, key) for key in ("label", "delivery", "readStyle")},
    }


def summarize(rows: list[dict[str, Any]]) -> dict[str, Any]:
    if not rows:
        return {}
    total_duration = sum(r["durationSeconds"] for r in rows)
    total_fp = sum(r["timeWeighted"]["falsePositiveSeconds"] for r in rows)
    total_fn = sum(r["timeWeighted"]["falseNegativeSeconds"] for r in rows)
    total_tp = sum(r["timeWeighted"]["truePositiveSeconds"] for r in rows)
    total_pred = sum(r["timeWeighted"]["predictedAdSeconds"] for r in rows)
    total_gold = sum(r["timeWeighted"]["goldenAdSeconds"] for r in rows)
    return {
        "episodeCount": len(rows),
        "macroTimeWeightedPrecision": round(sum(r["timeWeighted"]["precision"] for r in rows) / len(rows), 4),
        "macroTimeWeightedRecall": round(sum(r["timeWeighted"]["recall"] for r in rows) / len(rows), 4),
        "durationWeightedPrecision": round(total_tp / total_pred, 4) if total_pred else 0.0,
        "durationWeightedRecall": round(total_tp / total_gold, 4) if total_gold else 1.0,
        "contentLossSeconds": round(total_fp, 3), "missedAdSeconds": round(total_fn, 3),
        "contentLossSecondsPerListeningHour": round(total_fp / total_duration * 3600, 3) if total_duration else 0.0,
        "missedAdSecondsPerListeningHour": round(total_fn / total_duration * 3600, 3) if total_duration else 0.0,
        "worstEpisodeTimeWeightedPrecision": min(r["timeWeighted"]["precision"] for r in rows),
        "worstEpisodeContentLossSecondsPerListeningHour": max(r["contentLossSecondsPerListeningHour"] for r in rows),
    }


def write_failure_packet(rows: list[dict[str, Any]], path: Path) -> None:
    failures: list[dict[str, Any]] = []
    for row in rows:
        for failure in row["failureModes"]:
            if failure["mode"] in {"false-positive", "miss"}:
                failures.append({"slug": row["slug"], **failure})
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(failures, indent=2) + "\n")
    html_path = path.with_suffix(".html")
    items = "\n".join(f"<li><b>{html.escape(f['slug'])}</b>: {html.escape(f['mode'])} — {html.escape(json.dumps(f))}</li>" for f in failures[:100])
    html_path.write_text(f"<!doctype html><meta charset=utf-8><title>Ad-eval failures</title><h1>Largest reviewable failures</h1><ol>{items}</ol>\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--workdir", type=Path, default=DEFAULT_WORKDIR)
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    parser.add_argument("--swift-cli", type=Path, required=True)
    parser.add_argument("--approach", choices=["v6.1", "viterbi"], required=True)
    parser.add_argument("--output", type=Path, default=None)
    args = parser.parse_args()
    split, goldens = load_corpus(args.corpus.resolve(), args.workdir.resolve())
    rows = [score_episode(slug, split[slug], goldens[slug], args.workdir.resolve(), args.swift_cli.resolve(), args.approach) for slug in sorted(goldens)]
    by_split = {name: summarize([r for r in rows if r["split"] == name]) for name in ("development", "holdout", "all")}
    if not by_split["all"]:
        by_split["all"] = summarize(rows)
    detailed = {"schemaVersion": 1, "approachRequested": args.approach, "episodes": rows}
    detail_path = args.workdir.resolve() / f"corpus-score-{args.approach}.json"
    detail_path.write_text(json.dumps(detailed, indent=2) + "\n")
    compact_rows = []
    for row in rows:
        compact_rows.append({key: value for key, value in row.items() if key not in {"predictions", "failureModes"}})
    report = {"schemaVersion": 1, "corpusManifest": "corpus-manifest.json", "approachRequested": args.approach, "summaries": by_split, "episodes": compact_rows}
    output = args.output or (args.corpus.resolve() / f"benchmark-{args.approach}.json")
    output.write_text(json.dumps(report, indent=2) + "\n")
    write_failure_packet(rows, args.workdir.resolve() / "failure-packets" / f"{args.approach}.json")
    print(f"Wrote {output}")


if __name__ == "__main__":
    main()
