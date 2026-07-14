#!/usr/bin/env python3
"""Score ad detectors vs approved goldens (IoU >= 0.5 + boundary error)."""

from __future__ import annotations

import argparse
import json
import statistics
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from ad_eval_common import DEFAULT_WORKDIR, SHOWS, fmt_time, show_dir


@dataclass
class SegmentationScore:
    true_positives: int
    false_positives: int
    false_negatives: int

    @property
    def precision(self) -> float:
        d = self.true_positives + self.false_positives
        return self.true_positives / d if d else 0.0

    @property
    def recall(self) -> float:
        d = self.true_positives + self.false_negatives
        return self.true_positives / d if d else 0.0


def iou(a: tuple[float, float], b: tuple[float, float]) -> float:
    inter = max(0.0, min(a[1], b[1]) - max(a[0], b[0]))
    union = (a[1] - a[0]) + (b[1] - b[0]) - inter
    return inter / union if union > 0 else 0.0


def match_pairs(
    predictions: list[tuple[float, float]],
    goldens: list[tuple[float, float]],
    threshold: float = 0.5,
) -> tuple[SegmentationScore, list[tuple[int, int, float]]]:
    pairs: list[tuple[int, int, float]] = []
    for pi, p in enumerate(predictions):
        for gi, g in enumerate(goldens):
            score = iou(p, g)
            # Also accept high coverage of a short golden by a longer pod prediction.
            g_dur = max(g[1] - g[0], 1e-6)
            coverage = max(0.0, min(p[1], g[1]) - max(p[0], g[0])) / g_dur
            if score >= threshold or coverage >= 0.55:
                pairs.append((pi, gi, max(score, coverage)))
    pairs.sort(key=lambda x: x[2], reverse=True)

    matched_p: set[int] = set()
    matched_g: set[int] = set()
    kept: list[tuple[int, int, float]] = []
    for pi, gi, s in pairs:
        if pi in matched_p or gi in matched_g:
            continue
        matched_p.add(pi)
        matched_g.add(gi)
        kept.append((pi, gi, s))

    # Multi-golden coverage: one long prediction may cover several goldens.
    # Re-run allowing one prediction to match multiple goldens for recall.
    covered_g: set[int] = set()
    used_p: set[int] = set()
    multi: list[tuple[int, int, float]] = []
    for pi, p in enumerate(predictions):
        for gi, g in enumerate(goldens):
            if gi in covered_g:
                continue
            g_dur = max(g[1] - g[0], 1e-6)
            coverage = max(0.0, min(p[1], g[1]) - max(p[0], g[0])) / g_dur
            score = iou(p, g)
            if score >= threshold or coverage >= 0.55:
                covered_g.add(gi)
                used_p.add(pi)
                multi.append((pi, gi, max(score, coverage)))

    score = SegmentationScore(
        true_positives=len(covered_g),
        false_positives=len(predictions) - len(used_p),
        false_negatives=len(goldens) - len(covered_g),
    )
    return score, multi


def boundary_errors(
    predictions: list[tuple[float, float]],
    goldens: list[tuple[float, float]],
    matches: list[tuple[int, int, float]],
) -> dict[str, Any]:
    d_starts = [abs(predictions[pi][0] - goldens[gi][0]) for pi, gi, _ in matches]
    d_ends = [abs(predictions[pi][1] - goldens[gi][1]) for pi, gi, _ in matches]
    if not d_starts:
        return {
            "matched": 0,
            "medianAbsDeltaStart": None,
            "medianAbsDeltaEnd": None,
            "maxAbsDeltaStart": None,
            "maxAbsDeltaEnd": None,
            "within3sBoth": 0,
        }
    within = sum(
        1
        for ds, de in zip(d_starts, d_ends)
        if ds <= 3.0 and de <= 3.0
    )
    return {
        "matched": len(d_starts),
        "medianAbsDeltaStart": round(statistics.median(d_starts), 3),
        "medianAbsDeltaEnd": round(statistics.median(d_ends), 3),
        "maxAbsDeltaStart": round(max(d_starts), 3),
        "maxAbsDeltaEnd": round(max(d_ends), 3),
        "within3sBoth": within,
    }


def load_words(path: Path) -> list[dict]:
    return json.loads(path.read_text(encoding="utf-8"))


def load_goldens(out_dir: Path) -> list[dict[str, Any]]:
    golden_path = out_dir / "golden.json"
    proposed_path = out_dir / "llm_proposed.json"
    if golden_path.exists():
        data = json.loads(golden_path.read_text(encoding="utf-8"))
        return data.get("spans", data if isinstance(data, list) else [])
    if proposed_path.exists():
        data = json.loads(proposed_path.read_text(encoding="utf-8"))
        return data.get("spans", [])
    return []


def excerpt(words: list[dict], start: float, end: float, width: int = 160) -> str:
    text = " ".join(w["word"] for w in words if w["end"] > start and w["start"] < end)
    return text[:width] + ("…" if len(text) > width else "")


def run_detector(name: str, words: list[dict]) -> list[tuple[float, float]]:
    if name == "span-grow":
        from ad_eval_detector import segment_timed_words

        return [(s.start, s.end) for s in segment_timed_words(words)]
    if name == "legacy":
        from ad_eval_heuristic import segment, timed_words_to_tokens

        preds, _, _ = segment(timed_words_to_tokens(words))
        return [(p.start, p.end) for p in preds]
    raise ValueError(f"Unknown detector: {name}")


def score_show(workdir: Path, slug: str, detector: str) -> dict[str, Any]:
    out_dir = show_dir(workdir, slug)
    words = load_words(out_dir / "transcript.json")
    goldens = load_goldens(out_dir)

    pred_tuples = run_detector(detector, words)
    gold_tuples = [(g["start"], g["end"]) for g in goldens]
    seg_score, matches = match_pairs(pred_tuples, gold_tuples)
    bounds = boundary_errors(pred_tuples, gold_tuples, matches)

    matched_g = {gi for _, gi, _ in matches}
    matched_p = {pi for pi, _, _ in matches}

    pred_records = [
        {"start": s, "end": e, "excerpt": excerpt(words, s, e)} for s, e in pred_tuples
    ]
    out_name = "heuristic.json" if detector == "legacy" else f"{detector}.json"
    (out_dir / out_name).write_text(
        json.dumps({"detector": detector, "segments": pred_records}, indent=2) + "\n",
        encoding="utf-8",
    )

    false_positives = [
        {
            "start": pred_tuples[i][0],
            "end": pred_tuples[i][1],
            "excerpt": excerpt(words, pred_tuples[i][0], pred_tuples[i][1]),
        }
        for i in range(len(pred_tuples))
        if i not in matched_p
    ]
    false_negatives = [
        {
            "start": gold_tuples[i][0],
            "end": gold_tuples[i][1],
            "kind": goldens[i].get("kind"),
            "rationale": goldens[i].get("rationale"),
            "excerpt": excerpt(words, gold_tuples[i][0], gold_tuples[i][1]),
        }
        for i in range(len(gold_tuples))
        if i not in matched_g
    ]

    metrics = {
        "slug": slug,
        "detector": detector,
        "precision": round(seg_score.precision, 3),
        "recall": round(seg_score.recall, 3),
        "truePositives": seg_score.true_positives,
        "falsePositives": seg_score.false_positives,
        "falseNegatives": seg_score.false_negatives,
        "predictionCount": len(pred_tuples),
        "goldenCount": len(gold_tuples),
        "boundary": bounds,
        "falsePositivesDetail": false_positives,
        "falseNegativesDetail": false_negatives,
        "goldenSource": "golden.json"
        if (out_dir / "golden.json").exists()
        else "llm_proposed.json",
    }
    metrics_name = "metrics.json" if detector == "legacy" else f"metrics-{detector}.json"
    (out_dir / metrics_name).write_text(json.dumps(metrics, indent=2) + "\n", encoding="utf-8")
    return metrics


def main() -> None:
    parser = argparse.ArgumentParser(description="Score ad detectors vs goldens")
    parser.add_argument("--workdir", type=Path, default=DEFAULT_WORKDIR)
    parser.add_argument("--show", action="append")
    parser.add_argument(
        "--detector",
        choices=["span-grow", "legacy", "both"],
        default="span-grow",
    )
    args = parser.parse_args()

    sys.path.insert(0, str(Path(__file__).resolve().parent))

    workdir = args.workdir.resolve()
    selected = SHOWS
    if args.show:
        wanted = set(args.show)
        selected = [(s, _) for s, _ in SHOWS if s in wanted]

    detectors = ["span-grow", "legacy"] if args.detector == "both" else [args.detector]
    all_metrics: list[dict] = []
    for det in detectors:
        print(f"\n=== detector: {det} ===")
        for slug, _ in selected:
            m = score_show(workdir, slug, det)
            all_metrics.append(m)
            b = m["boundary"]
            med_s = b.get("medianAbsDeltaStart")
            med_e = b.get("medianAbsDeltaEnd")
            print(
                f"[{slug}] P={m['precision']:.3f} R={m['recall']:.3f} "
                f"TP={m['truePositives']} FP={m['falsePositives']} FN={m['falseNegatives']} "
                f"Δstart_med={med_s} Δend_med={med_e}"
            )

    by_det: dict[str, list[dict]] = {}
    for m in all_metrics:
        by_det.setdefault(m["detector"], []).append(m)
    summary: dict[str, Any] = {"detectors": {}}
    for det, rows in by_det.items():
        summary["detectors"][det] = {
            "episodes": rows,
            "macroPrecision": round(
                sum(m["precision"] for m in rows) / max(1, len(rows)), 3
            ),
            "macroRecall": round(sum(m["recall"] for m in rows) / max(1, len(rows)), 3),
            "totalTP": sum(m["truePositives"] for m in rows),
            "totalFP": sum(m["falsePositives"] for m in rows),
            "totalFN": sum(m["falseNegatives"] for m in rows),
        }
    (workdir / "metrics_summary.json").write_text(
        json.dumps(summary, indent=2) + "\n", encoding="utf-8"
    )
    print(f"\nWrote {workdir / 'metrics_summary.json'}")


if __name__ == "__main__":
    main()
