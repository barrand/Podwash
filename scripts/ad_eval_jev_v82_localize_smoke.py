#!/usr/bin/env python3
"""Run the small V8.2A 15-second Jev refinement smoke test."""

from __future__ import annotations

import argparse
import json
import os
import statistics
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from ad_eval_corpus_score import DEFAULT_CORPUS, DEFAULT_WORKDIR, sha256
from ad_eval_jev import MODEL, PRICE_CARD, estimated_cost, estimated_tokens, request_sha256
from ad_eval_jev_v7 import run_request, save_json
from ad_eval_jev_v8 import (
    MAX_REQUEST_TOKENS,
    ScoutWindow,
    build_windows,
    covered_seconds,
    load_episode,
    overlap_seconds,
    paid_spans,
    parse_probability,
    union_intervals,
)
from ad_eval_jev_v81_boundary import POSITIVE_THRESHOLD, v81_scout_payload


EXPERIMENT = "jev-v8.2a-15-second-refinement-smoke"
OUTPUT_NAME = "jev-v8.2a-localize-smoke"
SLICE_SECONDS = 15.0
SLICE_STRIDE_SECONDS = 10.0
MAX_SPEND_USD = 0.010


@dataclass(frozen=True)
class ParentCase:
    slug: str
    window_number: int
    start: float
    end: float
    expected_paid: bool

    @property
    def id(self) -> str:
        return f"{self.slug}-w{self.window_number:04d}"


CASES = (
    ParentCase("economics-of-everyday-things", 10, 540.0, 660.0, True),
    ParentCase("99-percent-invisible", 28, 1620.0, 1740.0, True),
    ParentCase("bill-simmons-kawhi", 50, 2940.0, 3060.0, True),
    ParentCase("darknet-diaries", 35, 2040.0, 2160.0, True),
    ParentCase("darknet-diaries", 69, 4080.0, 4186.65, False),
)
SLUGS = tuple(dict.fromkeys(case.slug for case in CASES))


def parent_paid_spans(episode: dict[str, Any], case: ParentCase) -> list[dict[str, Any]]:
    spans = []
    for span in paid_spans(episode):
        start = max(case.start, float(span["start"]))
        end = min(case.end, float(span["end"]))
        if end > start:
            spans.append({"id": str(span.get("id") or ""), "start": start, "end": end})
    return spans


def build_slices(episode: dict[str, Any], case: ParentCase) -> list[ScoutWindow]:
    rows = episode["rows"]
    windows: list[ScoutWindow] = []
    anchor, number = case.start, 1
    while anchor < case.end:
        end = min(case.end, anchor + SLICE_SECONDS)
        targets = tuple(index for index, row in enumerate(rows) if float(row.end) > anchor and float(row.start) < end)
        if targets:
            windows.append(
                ScoutWindow(
                    slug=case.id,
                    number=number,
                    start=anchor,
                    end=end,
                    target_indices=targets,
                    context_start=max(0, targets[0] - 2),
                    context_end=min(len(rows), targets[-1] + 3),
                )
            )
            number += 1
        anchor += SLICE_STRIDE_SECONDS
    return windows


def select_cases(episodes: dict[str, dict[str, Any]]) -> list[tuple[ParentCase, ScoutWindow, dict[str, Any]]]:
    selected: list[tuple[ParentCase, ScoutWindow, dict[str, Any]]] = []
    for case in CASES:
        episode = episodes[case.slug]
        parent_windows = {window.number: window for window in build_windows(case.slug, episode["rows"], episode["duration"])}
        parent = parent_windows.get(case.window_number)
        if parent is None or (parent.start, parent.end) != (case.start, case.end):
            raise ValueError(f"{case.id}: frozen parent-window geometry no longer matches")
        matches = parent_paid_spans(episode, case)
        if bool(matches) != case.expected_paid:
            raise ValueError(f"{case.id}: approved paid-span expectation no longer matches")
        for window in build_slices(episode, case):
            payload = v81_scout_payload(episode, window)
            selected.append((case, window, payload))
    return selected


def score_results(
    episodes: dict[str, dict[str, Any]], observations: list[dict[str, Any]]
) -> dict[str, Any]:
    by_case = {case.id: [row for row in observations if row["parentId"] == case.id] for case in CASES}
    paid_results: list[dict[str, Any]] = []
    paid_parent_seconds = positive_coverage_seconds = 0.0
    promo_positive_count = 0
    for case in CASES:
        rows = by_case[case.id]
        coverage = union_intervals([(row["start"], row["end"]) for row in rows if row["positive"]])
        if case.expected_paid:
            paid_parent_seconds += case.end - case.start
            positive_coverage_seconds += sum(end - start for start, end in coverage)
            for span in parent_paid_spans(episodes[case.slug], case):
                interval = (span["start"], span["end"])
                duration = interval[1] - interval[0]
                covered = min(duration, covered_seconds(interval, coverage))
                paid_results.append(
                    {
                        "parentId": case.id,
                        "id": span["id"],
                        "start": round(interval[0], 3),
                        "end": round(interval[1], 3),
                        "hit": covered > 0,
                        "coverageRecall": round(covered / duration, 6),
                    }
                )
        else:
            promo_positive_count += sum(row["positive"] for row in rows)
    paid_recall = (
        sum((result["end"] - result["start"]) * result["coverageRecall"] for result in paid_results)
        / sum(result["end"] - result["start"] for result in paid_results)
        if paid_results
        else 1.0
    )
    coverage_fraction = positive_coverage_seconds / paid_parent_seconds if paid_parent_seconds else 0.0
    gates = {
        "everyClippedPaidSpanHit": all(result["hit"] for result in paid_results),
        "paidSecondsCoverageAtLeast99Percent": paid_recall >= 0.99,
        "promoOnlySlicesAllNegative": promo_positive_count == 0,
        "positiveCoverageAtMost50Percent": coverage_fraction <= 0.50,
    }
    return {
        "passed": all(gates.values()),
        "gates": gates,
        "aggregate": {
            "paidSpanCount": len(paid_results),
            "paidSpanHitCount": sum(result["hit"] for result in paid_results),
            "paidSecondsCoverageRecall": round(paid_recall, 6),
            "positiveCoverageSeconds": round(positive_coverage_seconds, 3),
            "paidParentSeconds": round(paid_parent_seconds, 3),
            "positiveCoverageFraction": round(coverage_fraction, 6),
            "promoOnlyPositiveSliceCount": promo_positive_count,
        },
        "paidSpans": paid_results,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    parser.add_argument("--workdir", type=Path, default=DEFAULT_WORKDIR)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--spend-cap-usd", type=float, default=MAX_SPEND_USD)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if not 0 < args.spend_cap_usd <= MAX_SPEND_USD:
        raise SystemExit(f"--spend-cap-usd must be greater than zero and no more than {MAX_SPEND_USD:.3f}")
    corpus, workdir = args.corpus.resolve(), args.workdir.resolve()
    output = (args.output or workdir / OUTPUT_NAME).resolve()
    try:
        episodes = {slug: load_episode(corpus, workdir, slug) for slug in SLUGS}
        requests = select_cases(episodes)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        raise SystemExit(str(error)) from error
    for case, window, payload in requests:
        if estimated_tokens(payload) > MAX_REQUEST_TOKENS:
            raise SystemExit(f"{case.id}/{window.number}: request estimate exceeds {MAX_REQUEST_TOKENS:,} tokens")
    projected = sum(estimated_cost(payload) for _, _, payload in requests)
    if projected > args.spend_cap_usd:
        raise SystemExit(f"projected cost ${projected:.6f} exceeds cap ${args.spend_cap_usd:.3f}")
    if args.dry_run:
        _, largest, payload = max(requests, key=lambda item: estimated_tokens(item[2]))
        print(f"V8.2A dry run: {len(requests)} 15-second refinement windows across {len(CASES)} parent cases")
        print(f"Largest request: {largest.id} ({estimated_tokens(payload):,} conservative tokens)")
        print(f"Projected cost <= ${projected:.6f}; hard cap ${args.spend_cap_usd:.3f}")
        return
    api_key = os.environ.get("TYPESAFE_API_KEY", "")
    if not api_key:
        raise SystemExit("TYPESAFE_API_KEY is required unless --dry-run is used")
    manifest = {
        "schemaVersion": 1,
        "experiment": EXPERIMENT,
        "model": MODEL,
        "positiveThreshold": POSITIVE_THRESHOLD,
        "sliceSeconds": SLICE_SECONDS,
        "sliceStrideSeconds": SLICE_STRIDE_SECONDS,
        "cases": [case.id for case in CASES],
        "transcriptSha256": {slug: episodes[slug]["transcriptSha256"] for slug in SLUGS},
        "goldenSha256": {slug: sha256(corpus / "goldens" / f"{slug}.json") for slug in SLUGS},
        "requestHashes": [request_sha256(payload) for _, _, payload in requests],
    }
    output.mkdir(parents=True, exist_ok=True)
    save_json(output / "manifest.json", manifest)
    save_json(output / "price-card.json", PRICE_CARD)
    observations: list[dict[str, Any]] = []
    spent = 0.0
    latencies: list[float] = []
    for index, (case, window, payload) in enumerate(requests, 1):
        print(f"[refine {index}/{len(requests)} {case.id}/s{window.number:02d}]", flush=True)
        response, cost, latency = run_request(api_key, output, "refine", f"{case.id}-s{window.number:02d}", payload, spent, args.spend_cap_usd)
        spent += cost
        latencies.append(latency)
        probability = parse_probability(response)
        observations.append({
            "id": f"{case.id}-s{window.number:02d}", "parentId": case.id, "slug": case.slug,
            "start": round(window.start, 3), "end": round(window.end, 3),
            "probability": probability, "positive": probability >= POSITIVE_THRESHOLD,
        })
    score = score_results(episodes, observations)
    report = {
        "schemaVersion": 1, "experiment": EXPERIMENT,
        "status": "passed" if score["passed"] else "rejected", "model": MODEL,
        "completedAt": datetime.now(timezone.utc).isoformat(),
        "parameters": {"positiveThreshold": POSITIVE_THRESHOLD, "sliceSeconds": SLICE_SECONDS, "sliceStrideSeconds": SLICE_STRIDE_SECONDS},
        "totalCostUsd": round(spent, 8),
        "latencyMs": {"median": round(statistics.median(latencies), 1), "max": round(max(latencies), 1)},
        **score, "slices": observations,
    }
    save_json(output / "report.json", report)
    print(f"Wrote {output / 'report.json'}")
    print(f"Status: {report['status']}; actual cost ${spent:.6f}")


if __name__ == "__main__":
    main()
