#!/usr/bin/env python3
"""Run the locked Jev V8.1 six-episode paid-ad scout regression."""

from __future__ import annotations

import argparse
import json
import os
import statistics
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from ad_eval_corpus_score import DEFAULT_CORPUS, DEFAULT_WORKDIR
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


EXPERIMENT = "two-minute-paid-ad-scout-v8.1-regression"
OUTPUT_NAME = "jev-chunk-scout-v8.1"
SLUGS = (
    "bill-simmons-kawhi",
    "economics-of-everyday-things",
    "darknet-diaries",
    "99-percent-invisible",
    "unexplainable",
    "ai-news-strategy-daily",
)
CONTROL_SLUG = "ai-news-strategy-daily"
PROTECTED_CATEGORIES = {"network_promo", "membership_cta"}
MAX_SPEND_USD = 0.060


def protected_spans(episode: dict[str, Any]) -> list[dict[str, Any]]:
    return [span for span in episode["golden"].get("spans") or [] if span.get("category") in PROTECTED_CATEGORIES]


def window_overlap(window: ScoutWindow, spans: list[dict[str, Any]]) -> float:
    return sum(
        overlap_seconds((window.start, window.end), (float(span["start"]), float(span["end"])))
        for span in spans
    )


def score_results(episodes: dict[str, dict[str, Any]], observations: list[dict[str, Any]]) -> dict[str, Any]:
    episode_summaries: list[dict[str, Any]] = []
    all_paid_results: list[dict[str, Any]] = []
    total_duration = total_positive_coverage = total_paid = total_paid_covered = 0.0
    control_positives = promo_only_positives = promo_only_windows = 0
    for slug in SLUGS:
        episode = episodes[slug]
        episode_observations = [row for row in observations if row["slug"] == slug]
        selected = [row for row in episode_observations if row["positive"]]
        coverage = union_intervals([(row["start"], row["end"]) for row in selected])
        coverage_seconds = sum(end - start for start, end in coverage)
        paid_results: list[dict[str, Any]] = []
        for span in paid_spans(episode):
            interval = (float(span["start"]), float(span["end"]))
            duration = interval[1] - interval[0]
            covered = min(duration, covered_seconds(interval, coverage))
            result = {
                "id": str(span.get("id") or ""),
                "start": interval[0],
                "end": interval[1],
                "hit": covered > 0,
                "coveredSeconds": round(covered, 3),
                "coverageRecall": round(covered / duration, 6) if duration else 1.0,
            }
            paid_results.append(result)
            all_paid_results.append(result)
            total_paid += duration
            total_paid_covered += covered
        episode_promo_only = [row for row in episode_observations if row["promoOnly"]]
        promo_only_windows += len(episode_promo_only)
        promo_only_positives += sum(row["positive"] for row in episode_promo_only)
        if slug == CONTROL_SLUG:
            control_positives = len(selected)
        total_duration += episode["duration"]
        total_positive_coverage += coverage_seconds
        episode_summaries.append(
            {
                "slug": slug,
                "durationSeconds": round(episode["duration"], 3),
                "windowCount": len(episode_observations),
                "positiveWindowCount": len(selected),
                "positiveCoverageSeconds": round(coverage_seconds, 3),
                "positiveCoverageFraction": round(coverage_seconds / episode["duration"], 6),
                "promoOnlyWindowCount": len(episode_promo_only),
                "promoOnlyPositiveWindowCount": sum(row["positive"] for row in episode_promo_only),
                "paidSpans": paid_results,
            }
        )
    paid_recall = total_paid_covered / total_paid if total_paid else 1.0
    positive_fraction = total_positive_coverage / total_duration if total_duration else 0.0
    gates = {
        "everyPaidSpanHit": all(result["hit"] for result in all_paid_results),
        "paidSecondsCoverageAtLeast99Percent": paid_recall >= 0.99,
        "controlHasZeroPositiveWindows": control_positives == 0,
        "promoOnlyWindowsAllNegative": promo_only_positives == 0,
        "positiveCoverageAtMost40Percent": positive_fraction <= 0.40,
    }
    return {
        "passed": all(gates.values()),
        "gates": gates,
        "aggregate": {
            "paidSpanCount": len(all_paid_results),
            "paidSpanHitCount": sum(result["hit"] for result in all_paid_results),
            "paidSeconds": round(total_paid, 3),
            "paidSecondsCovered": round(total_paid_covered, 3),
            "paidSecondsCoverageRecall": round(paid_recall, 6),
            "positiveCoverageSeconds": round(total_positive_coverage, 3),
            "listeningSeconds": round(total_duration, 3),
            "positiveCoverageFraction": round(positive_fraction, 6),
            "controlPositiveWindowCount": control_positives,
            "promoOnlyWindowCount": promo_only_windows,
            "promoOnlyPositiveWindowCount": promo_only_positives,
        },
        "episodes": episode_summaries,
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
    except (OSError, ValueError, json.JSONDecodeError) as error:
        raise SystemExit(str(error)) from error
    windows = [window for slug in SLUGS for window in build_windows(slug, episodes[slug]["rows"], episodes[slug]["duration"])]
    requests = [(window, v81_scout_payload(episodes[window.slug], window)) for window in windows]
    for window, payload in requests:
        if estimated_tokens(payload) > MAX_REQUEST_TOKENS:
            raise SystemExit(f"{window.id}: request estimate exceeds {MAX_REQUEST_TOKENS:,} tokens")
    projected = sum(estimated_cost(payload) for _, payload in requests)
    if projected > args.spend_cap_usd:
        raise SystemExit(f"projected cost ${projected:.6f} exceeds cap ${args.spend_cap_usd:.3f}")
    if args.dry_run:
        largest_window, largest_payload = max(requests, key=lambda item: estimated_tokens(item[1]))
        print(f"V8.1 Stage 1 dry run: {len(requests)} two-minute windows across {len(SLUGS)} locked episodes")
        print(f"Largest request: {largest_window.id} ({estimated_tokens(largest_payload):,} conservative tokens)")
        print(f"Projected cost <= ${projected:.6f}; hard cap ${args.spend_cap_usd:.3f}")
        return
    api_key = os.environ.get("TYPESAFE_API_KEY", "")
    if not api_key:
        raise SystemExit("TYPESAFE_API_KEY is required unless --dry-run is used")
    output.mkdir(parents=True, exist_ok=True)
    save_json(output / "price-card.json", PRICE_CARD)
    observations: list[dict[str, Any]] = []
    spent = 0.0
    latencies: list[float] = []
    for number, (window, payload) in enumerate(requests, 1):
        print(f"[scout {number}/{len(requests)} {window.id}]", flush=True)
        response, cost, latency = run_request(api_key, output, "scout", window.id, payload, spent, args.spend_cap_usd)
        spent += cost
        latencies.append(latency)
        episode = episodes[window.slug]
        paid_overlap = window_overlap(window, paid_spans(episode))
        protected_overlap = window_overlap(window, protected_spans(episode))
        probability = parse_probability(response)
        observations.append(
            {
                "id": window.id,
                "slug": window.slug,
                "start": round(window.start, 3),
                "end": round(window.end, 3),
                "probability": probability,
                "positive": probability >= POSITIVE_THRESHOLD,
                "goldenPaidOverlapSeconds": round(paid_overlap, 3),
                "goldenProtectedOverlapSeconds": round(protected_overlap, 3),
                "promoOnly": protected_overlap > 0 and paid_overlap == 0,
            }
        )
    score = score_results(episodes, observations)
    report = {
        "schemaVersion": 1,
        "experiment": EXPERIMENT,
        "status": "passed" if score["passed"] else "rejected",
        "model": MODEL,
        "completedAt": datetime.now(timezone.utc).isoformat(),
        "parameters": {
            "windowSeconds": 120.0,
            "strideSeconds": 60.0,
            "contextSentences": 2,
            "positiveThreshold": POSITIVE_THRESHOLD,
            "protectedCategories": sorted(PROTECTED_CATEGORIES),
        },
        "totalCostUsd": round(spent, 8),
        "latencyMs": {"median": round(statistics.median(latencies), 1), "max": round(max(latencies), 1)},
        **score,
        "windows": observations,
    }
    save_json(output / "report.json", report)
    save_json(
        output / "manifest.json",
        {
            "schemaVersion": 1,
            "experiment": EXPERIMENT,
            "model": MODEL,
            "slugs": list(SLUGS),
            "transcriptSha256": {slug: episodes[slug]["transcriptSha256"] for slug in SLUGS},
            "windowCount": len(windows),
            "requestHashes": [request_sha256(payload) for _, payload in requests],
        },
    )
    print(f"Wrote {output / 'report.json'}")
    print(f"Status: {report['status']}; actual cost ${spent:.6f}")


if __name__ == "__main__":
    main()
