#!/usr/bin/env python3
"""Run the frozen V8.3 two-episode held-out Jev localization evaluation."""

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
from ad_eval_jev_v8 import MAX_REQUEST_TOKENS, ScoutWindow, covered_seconds, load_episode, overlap_seconds, paid_spans, parse_probability, union_intervals
from ad_eval_jev_v81 import PROTECTED_CATEGORIES, STAGE2_EXPERIMENT
from ad_eval_jev_v81_boundary import POSITIVE_THRESHOLD, v81_scout_payload
from ad_eval_jev_v82_localize_smoke import SLICE_SECONDS, SLICE_STRIDE_SECONDS
from ad_eval_jev_v82_stitch import MAX_BRIDGE_SECONDS, bridge_intervals


EXPERIMENT = "jev-v8.3-heldout-localization"
OUTPUT_NAME = "jev-v8.3-heldout-localization"
SOURCE_OUTPUT_NAME = "jev-chunk-scout-v8.1-stage2"
SLUGS = ("stage2-this-american-life", "cougar-sports-2026-07-17-hour4")
MAX_SPEND_USD = 0.030


@dataclass(frozen=True)
class Region:
    slug: str
    number: int
    start: float
    end: float

    @property
    def id(self) -> str:
        return f"{self.slug}-r{self.number:02d}"


def protected_spans(episode: dict[str, Any]) -> list[dict[str, Any]]:
    return [span for span in episode["golden"].get("spans") or [] if span.get("category") in PROTECTED_CATEGORIES]


def build_regions(report: dict[str, Any], slug: str) -> list[Region]:
    positive = [(float(row["start"]), float(row["end"])) for row in report["windows"] if row.get("slug") == slug and row.get("positive")]
    merged = union_intervals(positive)
    if not merged:
        raise ValueError(f"{slug}: frozen scout has no positive candidate regions")
    return [Region(slug, index, start, end) for index, (start, end) in enumerate(merged, 1)]


def build_slices(episode: dict[str, Any], region: Region) -> list[ScoutWindow]:
    slices: list[ScoutWindow] = []
    anchor, number = region.start, 1
    while anchor < region.end:
        end = min(region.end, anchor + SLICE_SECONDS)
        targets = tuple(i for i, row in enumerate(episode["rows"]) if float(row.end) > anchor and float(row.start) < end)
        if targets:
            slices.append(ScoutWindow(region.id, number, anchor, end, targets, max(0, targets[0] - 2), min(len(episode["rows"]), targets[-1] + 3)))
            number += 1
        anchor += SLICE_STRIDE_SECONDS
    return slices


def validate_source(source: Path, corpus: Path, episodes: dict[str, dict[str, Any]]) -> tuple[dict[str, Any], dict[str, Any]]:
    report = json.loads((source / "report.json").read_text(encoding="utf-8"))
    manifest = json.loads((source / "manifest.json").read_text(encoding="utf-8"))
    if report.get("experiment") != STAGE2_EXPERIMENT or report.get("model") != MODEL:
        raise ValueError("source is not the frozen V8.1 Stage 2 scout report")
    if float((report.get("parameters") or {}).get("positiveThreshold", -1)) != POSITIVE_THRESHOLD:
        raise ValueError("source scout threshold differs from frozen V8.1")
    source_windows = [row for row in report.get("windows") or [] if row.get("slug") in SLUGS]
    if not source_windows or any(not isinstance(row.get("positive"), bool) for row in source_windows):
        raise ValueError("source report has invalid held-out scout observations")
    for slug, episode in episodes.items():
        if (manifest.get("transcriptSha256") or {}).get(slug) != episode["transcriptSha256"]:
            raise ValueError(f"{slug}: frozen scout transcript hash changed")
        if (manifest.get("goldenSha256") or {}).get(slug) != sha256(corpus / "goldens" / f"{slug}.json"):
            raise ValueError(f"{slug}: frozen scout golden hash changed")
    return report, manifest


def overlaps(interval: tuple[float, float], spans: list[dict[str, Any]]) -> bool:
    return any(overlap_seconds(interval, (float(span["start"]), float(span["end"]))) > 0 for span in spans)


def score(episodes: dict[str, dict[str, Any]], regions: list[Region], observations: list[dict[str, Any]]) -> dict[str, Any]:
    paid_results, details = [], []
    paid_total = paid_covered = eligible = positive_coverage = 0.0
    protected_only_positive = protected_only_count = 0
    for region in regions:
        rows = [row for row in observations if row["regionId"] == region.id]
        coverage = bridge_intervals([(row["start"], row["end"]) for row in rows if row["positive"]])
        eligible += region.end - region.start
        positive_coverage += sum(end - start for start, end in coverage)
        episode = episodes[region.slug]
        for span in paid_spans(episode):
            interval = (max(region.start, float(span["start"])), min(region.end, float(span["end"])))
            if interval[1] > interval[0]:
                duration = interval[1] - interval[0]
                covered = min(duration, covered_seconds(interval, coverage))
                paid_total += duration; paid_covered += covered
                paid_results.append({"slug": region.slug, "id": str(span.get("id") or ""), "start": round(interval[0], 3), "end": round(interval[1], 3), "hit": covered > 0, "coveredSeconds": round(covered, 3), "coverageRecall": round(covered / duration, 6)})
        for row in rows:
            interval = (float(row["start"]), float(row["end"]))
            if overlaps(interval, protected_spans(episode)) and not overlaps(interval, paid_spans(episode)):
                protected_only_count += 1; protected_only_positive += int(row["positive"])
        details.append({"id": region.id, "slug": region.slug, "start": region.start, "end": region.end, "sliceCount": len(rows), "positiveSliceCount": sum(row["positive"] for row in rows), "stitchedCoverage": [[round(a, 3), round(b, 3)] for a, b in coverage]})
    recall = paid_covered / paid_total if paid_total else 1.0
    fraction = positive_coverage / eligible if eligible else 0.0
    gates = {"everyPaidSpanHit": all(row["hit"] for row in paid_results), "paidSecondsCoverageAtLeast99Percent": recall >= .99, "protectedOnlySlicesAllNegative": protected_only_positive == 0, "positiveCoverageAtMost50Percent": fraction <= .50}
    return {"passed": all(gates.values()), "gates": gates, "aggregate": {"paidSpanCount": len(paid_results), "paidSpanHitCount": sum(row["hit"] for row in paid_results), "paidSeconds": round(paid_total, 3), "paidSecondsCovered": round(paid_covered, 3), "paidSecondsCoverageRecall": round(recall, 6), "candidateSeconds": round(eligible, 3), "positiveCoverageSeconds": round(positive_coverage, 3), "positiveCoverageFraction": round(fraction, 6), "protectedOnlySliceCount": protected_only_count, "protectedOnlyPositiveSliceCount": protected_only_positive}, "paidSpans": paid_results, "regions": details}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS); parser.add_argument("--workdir", type=Path, default=DEFAULT_WORKDIR)
    parser.add_argument("--source", type=Path); parser.add_argument("--output", type=Path); parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--spend-cap-usd", type=float, default=MAX_SPEND_USD)
    args = parser.parse_args()
    if not 0 < args.spend_cap_usd <= MAX_SPEND_USD: raise SystemExit(f"--spend-cap-usd must be in 0...{MAX_SPEND_USD:.3f}")
    corpus, workdir = args.corpus.resolve(), args.workdir.resolve(); source = (args.source or workdir / SOURCE_OUTPUT_NAME).resolve(); output = (args.output or workdir / OUTPUT_NAME).resolve()
    try:
        episodes = {slug: load_episode(corpus, workdir, slug) for slug in SLUGS}; report, source_manifest = validate_source(source, corpus, episodes)
        regions = [region for slug in SLUGS for region in build_regions(report, slug)]
        requests = [(region, window, v81_scout_payload(episodes[region.slug], window)) for region in regions for window in build_slices(episodes[region.slug], region)]
    except (OSError, ValueError, json.JSONDecodeError) as error: raise SystemExit(str(error)) from error
    if any(estimated_tokens(payload) > MAX_REQUEST_TOKENS for _, _, payload in requests): raise SystemExit("request estimate exceeds token cap")
    projected = sum(estimated_cost(payload) for _, _, payload in requests)
    if projected > args.spend_cap_usd: raise SystemExit(f"projected cost ${projected:.6f} exceeds cap ${args.spend_cap_usd:.3f}")
    if args.dry_run:
        print(f"V8.3 dry run: {len(regions)} merged scout regions, {len(requests)} refinement slices across {len(SLUGS)} held-out episodes")
        print(f"Candidate duration: {sum(r.end-r.start for r in regions):.1f}s; projected cost <= ${projected:.6f}; hard cap ${args.spend_cap_usd:.3f}")
        return
    key = os.environ.get("TYPESAFE_API_KEY", "")
    if not key: raise SystemExit("TYPESAFE_API_KEY is required unless --dry-run is used")
    output.mkdir(parents=True, exist_ok=True)
    manifest = {"schemaVersion": 1, "experiment": EXPERIMENT, "model": MODEL, "positiveThreshold": POSITIVE_THRESHOLD, "sliceSeconds": SLICE_SECONDS, "sliceStrideSeconds": SLICE_STRIDE_SECONDS, "maxBridgeSeconds": MAX_BRIDGE_SECONDS, "sourceReportSha256": sha256(source / "report.json"), "sourceManifestSha256": sha256(source / "manifest.json"), "transcriptSha256": {s: episodes[s]["transcriptSha256"] for s in SLUGS}, "goldenSha256": {s: sha256(corpus / "goldens" / f"{s}.json") for s in SLUGS}, "requestHashes": [request_sha256(p) for _, _, p in requests]}
    save_json(output / "manifest.json", manifest); save_json(output / "price-card.json", PRICE_CARD)
    observations, spent, latencies = [], 0.0, []
    for index, (region, window, payload) in enumerate(requests, 1):
        sample_id = f"{region.id}-s{window.number:03d}"; print(f"[refine {index}/{len(requests)} {sample_id}]", flush=True)
        response, cost, latency = run_request(key, output, "refine", sample_id, payload, spent, args.spend_cap_usd); spent += cost; latencies.append(latency)
        probability = parse_probability(response); observations.append({"id": sample_id, "regionId": region.id, "slug": region.slug, "start": round(window.start, 3), "end": round(window.end, 3), "probability": probability, "positive": probability >= POSITIVE_THRESHOLD})
    result = score(episodes, regions, observations)
    report = {"schemaVersion": 1, "experiment": EXPERIMENT, "status": "passed" if result["passed"] else "rejected", "model": MODEL, "completedAt": datetime.now(timezone.utc).isoformat(), "parameters": {"positiveThreshold": POSITIVE_THRESHOLD, "sliceSeconds": SLICE_SECONDS, "sliceStrideSeconds": SLICE_STRIDE_SECONDS, "maxBridgeSeconds": MAX_BRIDGE_SECONDS}, "totalCostUsd": round(spent, 8), "latencyMs": {"median": round(statistics.median(latencies), 1), "max": round(max(latencies), 1)}, **result, "slices": observations}
    save_json(output / "report.json", report); print(f"Wrote {output / 'report.json'}\nStatus: {report['status']}; cost ${spent:.6f}")


if __name__ == "__main__": main()
