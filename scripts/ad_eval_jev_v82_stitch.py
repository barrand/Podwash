#!/usr/bin/env python3
"""Run V8.2B by stitching saved V8.2A slices across a scout boundary."""

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
from ad_eval_jev_v8 import MAX_REQUEST_TOKENS, covered_seconds, load_episode, paid_spans, parse_probability, union_intervals
from ad_eval_jev_v81_boundary import POSITIVE_THRESHOLD, v81_scout_payload
from ad_eval_jev_v82_localize_smoke import (
    CASES as V82A_CASES,
    EXPERIMENT as V82A_EXPERIMENT,
    SLICE_SECONDS,
    SLICE_STRIDE_SECONDS,
    ParentCase,
    build_slices,
)


EXPERIMENT = "jev-v8.2b-boundary-stitch"
OUTPUT_NAME = "jev-v8.2b-boundary-stitch"
SOURCE_OUTPUT_NAME = "jev-v8.2a-localize-smoke"
MAX_BRIDGE_SECONDS = 15.0
MAX_SPEND_USD = 0.005
NEIGHBOR = ParentCase("99-percent-invisible", 29, 1680.0, 1800.0, True)
SLUGS = tuple(dict.fromkeys(case.slug for case in (*V82A_CASES, NEIGHBOR)))


@dataclass(frozen=True)
class ScoreRegion:
    id: str
    slug: str
    start: float
    end: float
    expected_paid: bool


REGIONS = (
    ScoreRegion("economics-paid", "economics-of-everyday-things", 540.0, 660.0, True),
    ScoreRegion("99pi-stitched-paid", "99-percent-invisible", 1620.0, 1800.0, True),
    ScoreRegion("bill-paid", "bill-simmons-kawhi", 2940.0, 3060.0, True),
    ScoreRegion("darknet-paid", "darknet-diaries", 2040.0, 2160.0, True),
    ScoreRegion("darknet-promo", "darknet-diaries", 4080.0, 4186.65, False),
)


def region_spans(episode: dict[str, Any], region: ScoreRegion) -> list[dict[str, Any]]:
    result = []
    for span in paid_spans(episode):
        start = max(region.start, float(span["start"]))
        end = min(region.end, float(span["end"]))
        if end > start:
            result.append({"id": str(span.get("id") or ""), "start": start, "end": end})
    return result


def bridge_intervals(intervals: list[tuple[float, float]]) -> list[tuple[float, float]]:
    merged = union_intervals(intervals)
    if not merged:
        return []
    bridged = [merged[0]]
    for start, end in merged[1:]:
        previous_start, previous_end = bridged[-1]
        if start - previous_end <= MAX_BRIDGE_SECONDS:
            bridged[-1] = (previous_start, max(previous_end, end))
        else:
            bridged.append((start, end))
    return bridged


def validate_source(
    source: Path, corpus: Path, episodes: dict[str, dict[str, Any]]
) -> tuple[dict[str, Any], dict[str, Any]]:
    report_path, manifest_path = source / "report.json", source / "manifest.json"
    report = json.loads(report_path.read_text(encoding="utf-8"))
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if report.get("experiment") != V82A_EXPERIMENT or report.get("model") != MODEL:
        raise ValueError("source report is not the frozen V8.2A run")
    parameters = report.get("parameters") or {}
    if (
        float(parameters.get("positiveThreshold", -1)) != POSITIVE_THRESHOLD
        or float(parameters.get("sliceSeconds", -1)) != SLICE_SECONDS
        or float(parameters.get("sliceStrideSeconds", -1)) != SLICE_STRIDE_SECONDS
    ):
        raise ValueError("source report does not use the frozen refinement policy")
    slices = report.get("slices")
    if not isinstance(slices, list) or len(slices) != 59:
        raise ValueError("source report must contain the 59 frozen V8.2A slices")
    for slug in SLUGS:
        if (manifest.get("transcriptSha256") or {}).get(slug) != episodes[slug]["transcriptSha256"]:
            raise ValueError(f"{slug}: source transcript hash changed")
        expected_golden = sha256(corpus / "goldens" / f"{slug}.json")
        if (manifest.get("goldenSha256") or {}).get(slug) != expected_golden:
            raise ValueError(f"{slug}: source golden hash changed")
    return report, manifest


def select_new_requests(
    episode: dict[str, Any], source_manifest: dict[str, Any]
) -> list[tuple[Any, dict[str, Any]]]:
    source_hashes = set(source_manifest.get("requestHashes") or [])
    slices = build_slices(episode, NEIGHBOR)
    selected = [(window, v81_scout_payload(episode, window)) for window in slices if window.start >= 1740.0]
    if len(selected) != 6 or any(request_sha256(payload) in source_hashes for _, payload in selected):
        raise ValueError("expected exactly six new neighbor requests")
    return selected


def score_results(episodes: dict[str, dict[str, Any]], observations: list[dict[str, Any]]) -> dict[str, Any]:
    paid_results: list[dict[str, Any]] = []
    paid_seconds = paid_covered = eligible_seconds = positive_coverage = 0.0
    promo_positive_count = 0
    region_results = []
    for region in REGIONS:
        rows = [
            row for row in observations
            if row["slug"] == region.slug and float(row["end"]) > region.start and float(row["start"]) < region.end
        ]
        raw_positive = [(max(region.start, float(row["start"])), min(region.end, float(row["end"]))) for row in rows if row["positive"]]
        coverage = bridge_intervals(raw_positive)
        spans = region_spans(episodes[region.slug], region)
        if bool(spans) != region.expected_paid:
            raise ValueError(f"{region.id}: approved paid-span expectation changed")
        if region.expected_paid:
            eligible_seconds += region.end - region.start
            positive_coverage += sum(end - start for start, end in coverage)
            for span in spans:
                interval = (span["start"], span["end"])
                duration = interval[1] - interval[0]
                covered = min(duration, covered_seconds(interval, coverage))
                paid_seconds += duration
                paid_covered += covered
                paid_results.append({
                    "regionId": region.id, "id": span["id"],
                    "start": round(interval[0], 3), "end": round(interval[1], 3),
                    "hit": covered > 0, "coveredSeconds": round(covered, 3),
                    "coverageRecall": round(covered / duration, 6),
                })
        else:
            promo_positive_count += sum(bool(row["positive"]) for row in rows)
        region_results.append({
            "id": region.id, "slug": region.slug, "start": region.start, "end": region.end,
            "sliceCount": len(rows), "positiveSliceCount": sum(bool(row["positive"]) for row in rows),
            "bridgedCoverage": [[round(start, 3), round(end, 3)] for start, end in coverage],
        })
    paid_recall = paid_covered / paid_seconds if paid_seconds else 1.0
    coverage_fraction = positive_coverage / eligible_seconds if eligible_seconds else 0.0
    gates = {
        "everyPaidSpanHit": all(result["hit"] for result in paid_results),
        "paidSecondsCoverageAtLeast99Percent": paid_recall >= 0.99,
        "promoOnlySlicesAllNegative": promo_positive_count == 0,
        "positiveCoverageAtMost50Percent": coverage_fraction <= 0.50,
    }
    return {
        "passed": all(gates.values()), "gates": gates,
        "aggregate": {
            "paidSpanCount": len(paid_results), "paidSpanHitCount": sum(result["hit"] for result in paid_results),
            "paidSeconds": round(paid_seconds, 3), "paidSecondsCovered": round(paid_covered, 3),
            "paidSecondsCoverageRecall": round(paid_recall, 6),
            "positiveCoverageSeconds": round(positive_coverage, 3), "eligibleRegionSeconds": round(eligible_seconds, 3),
            "positiveCoverageFraction": round(coverage_fraction, 6),
            "promoOnlyPositiveSliceCount": promo_positive_count,
        },
        "paidSpans": paid_results, "regions": region_results,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    parser.add_argument("--workdir", type=Path, default=DEFAULT_WORKDIR)
    parser.add_argument("--source", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--spend-cap-usd", type=float, default=MAX_SPEND_USD)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if not 0 < args.spend_cap_usd <= MAX_SPEND_USD:
        raise SystemExit(f"--spend-cap-usd must be greater than zero and no more than {MAX_SPEND_USD:.3f}")
    corpus, workdir = args.corpus.resolve(), args.workdir.resolve()
    source = (args.source or workdir / SOURCE_OUTPUT_NAME).resolve()
    output = (args.output or workdir / OUTPUT_NAME).resolve()
    try:
        episodes = {slug: load_episode(corpus, workdir, slug) for slug in SLUGS}
        source_report, source_manifest = validate_source(source, corpus, episodes)
        requests = select_new_requests(episodes[NEIGHBOR.slug], source_manifest)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        raise SystemExit(str(error)) from error
    for window, payload in requests:
        if estimated_tokens(payload) > MAX_REQUEST_TOKENS:
            raise SystemExit(f"{NEIGHBOR.id}/{window.number}: request estimate exceeds {MAX_REQUEST_TOKENS:,} tokens")
    projected = sum(estimated_cost(payload) for _, payload in requests)
    if projected > args.spend_cap_usd:
        raise SystemExit(f"projected cost ${projected:.6f} exceeds cap ${args.spend_cap_usd:.3f}")
    if args.dry_run:
        largest, payload = max(requests, key=lambda item: estimated_tokens(item[1]))
        print(f"V8.2B dry run: reuse 59 frozen slices and add {len(requests)} new slices")
        print(f"New range: {requests[0][0].start:.0f}-{requests[-1][0].end:.0f}s")
        print(f"Largest request: {largest.id} ({estimated_tokens(payload):,} conservative tokens)")
        print(f"Projected new cost <= ${projected:.6f}; hard cap ${args.spend_cap_usd:.3f}")
        return
    api_key = os.environ.get("TYPESAFE_API_KEY", "")
    if not api_key:
        raise SystemExit("TYPESAFE_API_KEY is required unless --dry-run is used")
    output.mkdir(parents=True, exist_ok=True)
    manifest = {
        "schemaVersion": 1, "experiment": EXPERIMENT, "model": MODEL,
        "positiveThreshold": POSITIVE_THRESHOLD, "sliceSeconds": SLICE_SECONDS,
        "sliceStrideSeconds": SLICE_STRIDE_SECONDS, "maxBridgeSeconds": MAX_BRIDGE_SECONDS,
        "sourceReport": str(source / "report.json"), "sourceReportSha256": sha256(source / "report.json"),
        "reusedSliceCount": 59, "newRequestHashes": [request_sha256(payload) for _, payload in requests],
    }
    save_json(output / "manifest.json", manifest)
    save_json(output / "price-card.json", PRICE_CARD)
    new_observations = []
    spent = 0.0
    latencies = []
    for index, (window, payload) in enumerate(requests, 1):
        sample_id = f"{NEIGHBOR.id}-s{window.number:02d}"
        print(f"[stitch {index}/{len(requests)} {sample_id}]", flush=True)
        response, cost, latency = run_request(api_key, output, "stitch", sample_id, payload, spent, args.spend_cap_usd)
        spent += cost
        latencies.append(latency)
        probability = parse_probability(response)
        new_observations.append({
            "id": sample_id, "parentId": NEIGHBOR.id, "slug": NEIGHBOR.slug,
            "start": round(window.start, 3), "end": round(window.end, 3),
            "probability": probability, "positive": probability >= POSITIVE_THRESHOLD,
        })
    observations = list(source_report["slices"]) + new_observations
    score = score_results(episodes, observations)
    report = {
        "schemaVersion": 1, "experiment": EXPERIMENT,
        "status": "passed" if score["passed"] else "rejected", "model": MODEL,
        "completedAt": datetime.now(timezone.utc).isoformat(),
        "parameters": {"positiveThreshold": POSITIVE_THRESHOLD, "sliceSeconds": SLICE_SECONDS,
                       "sliceStrideSeconds": SLICE_STRIDE_SECONDS, "maxBridgeSeconds": MAX_BRIDGE_SECONDS},
        "source": {"experiment": V82A_EXPERIMENT, "reusedSliceCount": 59},
        "newRequestCount": len(requests), "totalCostUsd": round(spent, 8),
        "latencyMs": {"median": round(statistics.median(latencies), 1), "max": round(max(latencies), 1)},
        **score, "newSlices": new_observations,
    }
    save_json(output / "report.json", report)
    print(f"Wrote {output / 'report.json'}")
    print(f"Status: {report['status']}; new cost ${spent:.6f}")


if __name__ == "__main__":
    main()
