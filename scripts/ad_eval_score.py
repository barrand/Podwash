#!/usr/bin/env python3
"""Score ad detectors vs approved goldens (segment IoU + time-weighted metrics)."""

from __future__ import annotations

import argparse
import json
import statistics
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from ad_eval_common import DEFAULT_WORKDIR, DOGFOOD_SLUG, fmt_time, select_shows, show_dir


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
    within = sum(1 for ds, de in zip(d_starts, d_ends) if ds <= 3.0 and de <= 3.0)
    return {
        "matched": len(d_starts),
        "medianAbsDeltaStart": round(statistics.median(d_starts), 3),
        "medianAbsDeltaEnd": round(statistics.median(d_ends), 3),
        "maxAbsDeltaStart": round(max(d_starts), 3),
        "maxAbsDeltaEnd": round(max(d_ends), 3),
        "within3sBoth": within,
    }


def _merge_spans(spans: list[tuple[float, float]]) -> list[tuple[float, float]]:
    if not spans:
        return []
    ordered = sorted(spans)
    out = [list(ordered[0])]
    for s, e in ordered[1:]:
        if s <= out[-1][1]:
            out[-1][1] = max(out[-1][1], e)
        else:
            out.append([s, e])
    return [(a, b) for a, b in out]


def time_weighted(
    predictions: list[tuple[float, float]],
    goldens: list[tuple[float, float]],
) -> dict[str, float]:
    """Fraction of timeline seconds correctly labeled as ad vs non-ad."""
    pred = _merge_spans(predictions)
    gold = _merge_spans(goldens)

    def duration(spans: list[tuple[float, float]]) -> float:
        return sum(e - s for s, e in spans)

    def intersect(a: list[tuple[float, float]], b: list[tuple[float, float]]) -> float:
        total = 0.0
        for as_, ae in a:
            for bs, be in b:
                total += max(0.0, min(ae, be) - max(as_, bs))
        return total

    tp = intersect(pred, gold)
    pred_dur = duration(pred)
    gold_dur = duration(gold)
    fp = max(0.0, pred_dur - tp)
    fn = max(0.0, gold_dur - tp)
    precision = tp / pred_dur if pred_dur > 0 else (1.0 if gold_dur == 0 else 0.0)
    recall = tp / gold_dur if gold_dur > 0 else (1.0 if pred_dur == 0 else 0.0)
    return {
        "truePositiveSeconds": round(tp, 3),
        "falsePositiveSeconds": round(fp, 3),
        "falseNegativeSeconds": round(fn, 3),
        "precision": round(precision, 4),
        "recall": round(recall, 4),
        "predictedAdSeconds": round(pred_dur, 3),
        "goldenAdSeconds": round(gold_dur, 3),
    }


def failure_modes(
    predictions: list[tuple[float, float]],
    goldens: list[tuple[float, float]],
    matches: list[tuple[int, int, float]],
) -> list[dict[str, Any]]:
    """Tag late-start / early-stop / end-bleed / miss / false-positive."""
    matched_g = {gi for _, gi, _ in matches}
    matched_p = {pi for pi, _, _ in matches}
    tags: list[dict[str, Any]] = []

    for pi, gi, _ in matches:
        p, g = predictions[pi], goldens[gi]
        start_delta = p[0] - g[0]
        end_delta = p[1] - g[1]
        mode = "ok"
        if start_delta > 3.0:
            mode = "late-start"
        elif start_delta < -3.0:
            mode = "early-start"
        if end_delta > 3.0:
            mode = "end-bleed" if mode == "ok" else f"{mode}+end-bleed"
        elif end_delta < -3.0:
            mode = "early-stop" if mode == "ok" else f"{mode}+early-stop"
        if mode != "ok":
            tags.append(
                {
                    "mode": mode,
                    "pred": {"start": p[0], "end": p[1]},
                    "gold": {"start": g[0], "end": g[1]},
                    "deltaStart": round(start_delta, 3),
                    "deltaEnd": round(end_delta, 3),
                }
            )

    for gi, g in enumerate(goldens):
        if gi not in matched_g:
            tags.append(
                {
                    "mode": "miss",
                    "gold": {"start": g[0], "end": g[1]},
                }
            )
    for pi, p in enumerate(predictions):
        if pi not in matched_p:
            tags.append(
                {
                    "mode": "false-positive",
                    "pred": {"start": p[0], "end": p[1]},
                }
            )
    return tags


def load_words(path: Path) -> list[dict]:
    return json.loads(path.read_text(encoding="utf-8"))


def load_goldens(out_dir: Path) -> tuple[list[dict[str, Any]], str]:
    for name in ("golden.json", "diff_golden.json", "llm_proposed.json"):
        path = out_dir / name
        if path.exists():
            data = json.loads(path.read_text(encoding="utf-8"))
            spans = data.get("spans", data if isinstance(data, list) else [])
            return list(spans), name
    return [], "none"


def excerpt(words: list[dict], start: float, end: float, width: int = 160) -> str:
    text = " ".join(w["word"] for w in words if w["end"] > start and w["start"] < end)
    return text[:width] + ("…" if len(text) > width else "")


def run_swift_cli(words_path: Path, cli_bin: Path) -> list[tuple[float, float]]:
    result = subprocess.run(
        [str(cli_bin), str(words_path)],
        capture_output=True,
        text=True,
        check=True,
    )
    data = json.loads(result.stdout)
    segs = data.get("segments", data if isinstance(data, list) else [])
    return [(float(s["start"]), float(s["end"])) for s in segs]


def run_detector(
    name: str,
    words: list[dict],
    words_path: Path | None = None,
    swift_cli: Path | None = None,
) -> list[tuple[float, float]]:
    if name == "span-grow":
        from ad_eval_detector import segment_timed_words

        return [(s.start, s.end) for s in segment_timed_words(words)]
    if name == "legacy":
        from ad_eval_heuristic import segment, timed_words_to_tokens

        preds, _, _ = segment(timed_words_to_tokens(words))
        return [(p.start, p.end) for p in preds]
    if name == "swift-cli":
        if swift_cli is None or words_path is None:
            raise ValueError("swift-cli requires --swift-cli path and transcript.json")
        return run_swift_cli(words_path, swift_cli)
    raise ValueError(f"Unknown detector: {name}")


def score_show(
    workdir: Path,
    slug: str,
    detector: str,
    *,
    swift_cli: Path | None = None,
) -> dict[str, Any]:
    out_dir = show_dir(workdir, slug)
    words_path = out_dir / "transcript.json"
    words = load_words(words_path)
    goldens, golden_source = load_goldens(out_dir)

    pred_tuples = run_detector(detector, words, words_path, swift_cli)
    gold_tuples = [(float(g["start"]), float(g["end"])) for g in goldens]
    seg_score, matches = match_pairs(pred_tuples, gold_tuples)
    bounds = boundary_errors(pred_tuples, gold_tuples, matches)
    tw = time_weighted(pred_tuples, gold_tuples)
    modes = failure_modes(pred_tuples, gold_tuples, matches)

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
        "isDogfood": slug == DOGFOOD_SLUG,
        "precision": round(seg_score.precision, 3),
        "recall": round(seg_score.recall, 3),
        "truePositives": seg_score.true_positives,
        "falsePositives": seg_score.false_positives,
        "falseNegatives": seg_score.false_negatives,
        "predictionCount": len(pred_tuples),
        "goldenCount": len(gold_tuples),
        "boundary": bounds,
        "timeWeighted": tw,
        "failureModes": modes,
        "falsePositivesDetail": false_positives,
        "falseNegativesDetail": false_negatives,
        "goldenSource": golden_source,
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
        choices=["span-grow", "legacy", "swift-cli", "both"],
        default="span-grow",
    )
    parser.add_argument(
        "--swift-cli",
        type=Path,
        default=None,
        help="Path to segmenter CLI binary (for --detector swift-cli)",
    )
    parser.add_argument("--include-optional", action="store_true")
    args = parser.parse_args()

    sys.path.insert(0, str(Path(__file__).resolve().parent))

    workdir = args.workdir.resolve()
    wanted = set(args.show) if args.show else None
    selected = select_shows(wanted, include_optional=args.include_optional)

    if args.detector == "both":
        detectors = ["span-grow", "legacy"]
    else:
        detectors = [args.detector]

    all_metrics: list[dict] = []
    for det in detectors:
        print(f"\n=== detector: {det} ===")
        for slug, _ in selected:
            out_dir = show_dir(workdir, slug)
            if not (out_dir / "transcript.json").exists():
                print(f"[{slug}] skip — no transcript.json")
                continue
            goldens, gsrc = load_goldens(out_dir)
            if not goldens:
                print(f"[{slug}] skip — no golden ({gsrc})")
                continue
            m = score_show(workdir, slug, det, swift_cli=args.swift_cli)
            all_metrics.append(m)
            tw = m["timeWeighted"]
            b = m["boundary"]
            print(
                f"[{slug}] seg P={m['precision']:.3f} R={m['recall']:.3f} "
                f"time P={tw['precision']:.3f} R={tw['recall']:.3f} "
                f"modes={len(m['failureModes'])} "
                f"Δstart_med={b.get('medianAbsDeltaStart')} Δend_med={b.get('medianAbsDeltaEnd')}"
            )

    by_det: dict[str, list[dict]] = {}
    for m in all_metrics:
        by_det.setdefault(m["detector"], []).append(m)
    summary: dict[str, Any] = {"detectors": {}}
    for det, rows in by_det.items():
        worst_p = min((r["timeWeighted"]["precision"] for r in rows), default=0.0)
        worst_r = min((r["timeWeighted"]["recall"] for r in rows), default=0.0)
        primary = [r for r in rows if not r.get("isDogfood")]
        dogfood = [r for r in rows if r.get("isDogfood")]
        summary["detectors"][det] = {
            "episodes": rows,
            "macroPrecision": round(
                sum(m["precision"] for m in rows) / max(1, len(rows)), 3
            ),
            "macroRecall": round(sum(m["recall"] for m in rows) / max(1, len(rows)), 3),
            "macroTimeWeightedPrecision": round(
                sum(m["timeWeighted"]["precision"] for m in rows) / max(1, len(rows)), 4
            ),
            "macroTimeWeightedRecall": round(
                sum(m["timeWeighted"]["recall"] for m in rows) / max(1, len(rows)), 4
            ),
            "worstEpisodeTimeWeightedPrecision": round(worst_p, 4),
            "worstEpisodeTimeWeightedRecall": round(worst_r, 4),
            "primaryEpisodeCount": len(primary),
            "dogfoodEpisodeCount": len(dogfood),
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
