#!/usr/bin/env python3
"""Test whether V7.1 coherent-block classification rescues V8.3's miss."""
from __future__ import annotations
import argparse, json, os, statistics
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from ad_eval_corpus_score import DEFAULT_CORPUS, DEFAULT_WORKDIR, sha256
from ad_eval_jev import MODEL, PRICE_CARD, estimated_cost, estimated_tokens, request_sha256
from ad_eval_jev_v7 import run_request, save_json
from ad_eval_jev_v8 import load_episode
from ad_eval_jev_v71 import Block, parse_tier, tier_payload

EXPERIMENT = "jev-v8.4-coherent-block-rescue"
OUTPUT_NAME = "jev-v8.4-coherent-block-rescue"
SLUG = "cougar-sports-2026-07-17-hour4"
MAX_SPEND_USD = 0.005

@dataclass(frozen=True)
class Case:
    id: str
    first_sentence: int
    last_sentence: int
    start: float
    end: float
    expected_tier: str

CASES = (
    Case("shopify-testimonial", 10, 17, 27.60, 88.78, "skip_obvious"),
    Case("station-show-promo", 18, 22, 89.22, 113.40, "skip_more_only"),
    Case("atrium-sponsor", 30, 39, 141.80, 189.32, "skip_obvious"),
)

def block_for_case(episode: dict, case: Case) -> Block:
    rows = episode["rows"]
    by_id = {row.id: i for i, row in enumerate(rows)}
    if case.first_sentence not in by_id or case.last_sentence not in by_id:
        raise ValueError(f"{case.id}: frozen sentence IDs are missing")
    block = Block(SLUG, by_id[case.first_sentence], by_id[case.last_sentence] + 1)
    first, last = rows[block.start_index], rows[block.end_index - 1]
    if abs(float(first.start) - case.start) > .001 or abs(float(last.end) - case.end) > .001:
        raise ValueError(f"{case.id}: frozen sentence geometry changed")
    return block

def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS); p.add_argument("--workdir", type=Path, default=DEFAULT_WORKDIR)
    p.add_argument("--output", type=Path); p.add_argument("--dry-run", action="store_true"); p.add_argument("--spend-cap-usd", type=float, default=MAX_SPEND_USD)
    args = p.parse_args()
    if not 0 < args.spend_cap_usd <= MAX_SPEND_USD: raise SystemExit(f"--spend-cap-usd must be in 0...{MAX_SPEND_USD:.3f}")
    corpus, workdir = args.corpus.resolve(), args.workdir.resolve(); output = (args.output or workdir / OUTPUT_NAME).resolve()
    try:
        episode = load_episode(corpus, workdir, SLUG)
        payloads = [(case, block, tier_payload(episode, block)) for case in CASES for block in [block_for_case(episode, case)]]
    except (OSError, ValueError, json.JSONDecodeError) as error: raise SystemExit(str(error)) from error
    if any(estimated_tokens(payload) > 20_000 for _, _, payload in payloads): raise SystemExit("request estimate exceeds token cap")
    projected = sum(estimated_cost(payload) for _, _, payload in payloads)
    if projected > args.spend_cap_usd: raise SystemExit(f"projected cost ${projected:.6f} exceeds cap ${args.spend_cap_usd:.3f}")
    if args.dry_run:
        largest = max(payloads, key=lambda x: estimated_tokens(x[2]))
        print(f"V8.4 dry run: {len(payloads)} frozen coherent blocks")
        print(f"Largest request: {largest[0].id} ({estimated_tokens(largest[2]):,} conservative tokens)")
        print(f"Projected cost <= ${projected:.6f}; hard cap ${args.spend_cap_usd:.3f}")
        return
    key = os.environ.get("TYPESAFE_API_KEY", "")
    if not key: raise SystemExit("TYPESAFE_API_KEY is required unless --dry-run is used")
    output.mkdir(parents=True, exist_ok=True)
    save_json(output / "manifest.json", {"schemaVersion": 1, "experiment": EXPERIMENT, "model": MODEL, "transcriptSha256": episode["transcriptSha256"], "goldenSha256": sha256(corpus / "goldens" / f"{SLUG}.json"), "cases": [case.__dict__ for case in CASES], "requestHashes": [request_sha256(payload) for _, _, payload in payloads]})
    save_json(output / "price-card.json", PRICE_CARD)
    results, spent, latencies = [], 0.0, []
    for case, block, payload in payloads:
        print(f"[block {case.id}]", flush=True)
        response, cost, latency = run_request(key, output, "block", case.id, payload, spent, args.spend_cap_usd)
        spent += cost; latencies.append(latency); decision = parse_tier(response, block.id(episode["rows"]))
        results.append({"id": case.id, "start": case.start, "end": case.end, "expectedTier": case.expected_tier, "actualTier": decision["tier"], "passed": decision["tier"] == case.expected_tier, **decision})
    passed = all(row["passed"] for row in results)
    report = {"schemaVersion": 1, "experiment": EXPERIMENT, "status": "passed" if passed else "rejected", "model": MODEL, "completedAt": datetime.now(timezone.utc).isoformat(), "passed": passed, "totalCostUsd": round(spent, 8), "latencyMs": {"median": round(statistics.median(latencies), 1), "max": round(max(latencies), 1)}, "cases": results}
    save_json(output / "report.json", report)
    print(f"Wrote {output / 'report.json'}\nStatus: {report['status']}; cost ${spent:.6f}")

if __name__ == "__main__": main()
