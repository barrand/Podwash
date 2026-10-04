#!/usr/bin/env python3
"""Compare Jev V7.1's decision path with the saved Gemini-v1 baseline.

The Gemini results in ``tmp/ad-eval/gemini-v1`` are historical artifacts. This
script never calls Gemini: it evaluates Jev on those five transcripts and
scores both providers against the tracked, human-approved ads-only goldens.
"""

from __future__ import annotations

import argparse
import json
import os
import statistics
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from ad_eval_corpus_score import DEFAULT_CORPUS, DEFAULT_WORKDIR, load_corpus, summarize
from ad_eval_gemini import clean_text, production_duration_capped_sentence_rows
from ad_eval_jev import MODEL, PRICE_CARD, estimated_cost, estimated_tokens, request_sha256
from ad_eval_jev_v7 import CANDIDATE_THRESHOLD, broad_payload, full_windows, json_hash, parse_broad, run_request, save_json
from ad_eval_jev_v71 import Block, TIER_REASONS, candidate_blocks, parse_tier, split_block, tier_payload
from ad_eval_score import boundary_errors, excerpt, failure_modes, match_pairs, time_weighted


EXPERIMENT = "jev-v7.1-tier-only-vs-gemini-v1"
OUTPUT_NAME = "jev-v71-gemini-v1"
SLUGS = ("99-percent-invisible", "cougar-sports", "darknet-diaries", "joe-rogan-mrbeast", "ai-news-strategy-daily")
MAX_REQUEST_TOKENS = 20_000


def load_episode(workdir: Path, slug: str) -> dict[str, Any]:
    directory = workdir / slug
    transcript = directory / "transcript.json"
    words = json.loads(transcript.read_text(encoding="utf-8"))
    meta = json.loads((directory / "meta.json").read_text(encoding="utf-8"))
    return {
        "slug": slug, "words": words, "rows": production_duration_capped_sentence_rows(words),
        "context": {"show": str(meta.get("showName") or slug), "episode": str(meta.get("episodeTitle") or ""),
                    "showDescription": clean_text(str(meta.get("showDescription") or ""), 900),
                    "episodeDescription": clean_text(str(meta.get("episodeDescription") or ""), 1600)},
        "transcriptSha256": json_hash(transcript),
    }


def tier_spans(episode: dict[str, Any], decisions: list[tuple[Block, dict[str, Any]]]) -> list[dict[str, Any]]:
    """Turn V7.1 block decisions into spans, merging only equal adjacent tiers."""
    rows, spans = episode["rows"], []
    for block, decision in sorted(decisions, key=lambda item: item[0].start_index):
        first, last = rows[block.start_index], rows[block.end_index - 1]
        span = {"startSentence": first.id, "endSentence": last.id, "startWord": first.start_word, "endWord": last.end_word,
                "start": round(float(first.start), 3), "end": round(float(last.end), 3), "tier": decision["tier"],
                "tierConfidence": decision["confidence"], "reasons": [], "primaryReason": "not-requested"}
        if spans and spans[-1]["tier"] == span["tier"] and spans[-1]["endSentence"] + 1 == span["startSentence"]:
            spans[-1].update({"endSentence": span["endSentence"], "endWord": span["endWord"], "end": span["end"]})
        else:
            spans.append(span)
    for index, span in enumerate(spans, 1):
        span["id"] = f"jev-v7.1-tier-only-{index}"
    return spans


def score_episode(slug: str, split: str, golden: dict[str, Any], words: list[dict[str, Any]], predictions: list[tuple[float, float]]) -> dict[str, Any]:
    gold = [(float(span["start"]), float(span["end"])) for span in golden["spans"]]
    segmented, matches = match_pairs(predictions, gold)
    weighted = time_weighted(predictions, gold)
    duration = float(words[-1]["end"]) if words else 0.0
    return {"slug": slug, "split": split, "durationSeconds": round(duration, 3), "precision": round(segmented.precision, 4),
            "recall": round(segmented.recall, 4), "truePositives": segmented.true_positives,
            "falsePositives": segmented.false_positives, "falseNegatives": segmented.false_negatives, "timeWeighted": weighted,
            "contentLossSecondsPerListeningHour": round(weighted["falsePositiveSeconds"] / duration * 3600, 3) if duration else 0.0,
            "missedAdSecondsPerListeningHour": round(weighted["falseNegativeSeconds"] / duration * 3600, 3) if duration else 0.0,
            "boundary": boundary_errors(predictions, gold, matches), "failureModes": failure_modes(predictions, gold, matches),
            "predictions": [{"start": start, "end": end, "excerpt": excerpt(words, start, end)} for start, end in predictions]}


def saved_gemini_scores(workdir: Path) -> list[dict[str, Any]]:
    scores = []
    for slug in SLUGS:
        path = workdir / "gemini-v1" / slug / "result.json"
        if not path.exists():
            raise ValueError(f"missing saved Gemini-v1 result: {path}")
        result = json.loads(path.read_text(encoding="utf-8"))
        if result.get("model") != "gemini-3.6-flash" or result.get("slug") != slug or not isinstance(result.get("score"), dict):
            raise ValueError(f"{path}: unexpected saved Gemini-v1 artifact")
        scores.append(result["score"])
    return scores


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workdir", type=Path, default=DEFAULT_WORKDIR)
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--spend-cap-usd", type=float, default=0.30)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.spend_cap_usd <= 0:
        raise SystemExit("--spend-cap-usd must be positive")
    workdir, corpus = args.workdir.resolve(), args.corpus.resolve()
    output = (args.output or workdir / OUTPUT_NAME).resolve()
    try:
        split, goldens = load_corpus(corpus, workdir)
        episodes = {slug: load_episode(workdir, slug) for slug in SLUGS}
        gemini_scores = saved_gemini_scores(workdir)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        raise SystemExit(str(error)) from error
    if any(split[slug] != "holdout" for slug in SLUGS):
        raise SystemExit("historical Gemini-v1 episodes must remain frozen holdout episodes")
    broad_requests = [(window, broad_payload(episodes[slug], window)) for slug in SLUGS for window in full_windows(slug, episodes[slug]["rows"])]
    broad_cost = sum(estimated_cost(payload) for _, payload in broad_requests)
    if args.dry_run:
        largest = max(broad_requests, key=lambda item: estimated_tokens(item[1]))
        print(f"Jev V7.1 tier-only dry run: {len(broad_requests)} broad windows across {len(SLUGS)} historical Gemini-v1 episodes")
        print(f"Broad cost <= ${broad_cost:.5f}; tier recursion shares the ${args.spend_cap_usd:.2f} total cap")
        print(f"Largest broad request: {largest[0].id} ({estimated_tokens(largest[1]):,} conservative tokens)")
        print("Gemini is not called; its saved five-episode score is read after Jev completes.")
        return
    api_key = os.environ.get("TYPESAFE_API_KEY", "")
    if not api_key:
        raise SystemExit("TYPESAFE_API_KEY is required unless --dry-run is used")
    if broad_cost > args.spend_cap_usd:
        raise SystemExit(f"broad pass alone projects ${broad_cost:.4f}, above cap ${args.spend_cap_usd:.2f}")
    output.mkdir(parents=True, exist_ok=True)
    save_json(output / "price-card.json", PRICE_CARD)
    spent, latencies = 0.0, []
    observations: dict[str, list[dict[str, Any]]] = {slug: [] for slug in SLUGS}
    for number, (window, payload) in enumerate(broad_requests, 1):
        print(f"[broad {number}/{len(broad_requests)} {window.id}]", flush=True)
        response, cost, latency = run_request(api_key, output, "broad", window.id, payload, spent, args.spend_cap_usd)
        spent += cost
        latencies.append(latency)
        observations[window.slug].extend(parse_broad(response, episodes[window.slug], window))
    initial = [block for slug in SLUGS for block in candidate_blocks(slug, sorted(observations[slug], key=lambda row: row["sentence"]))]
    resolved: dict[str, list[tuple[Block, dict[str, Any]]]] = {slug: [] for slug in SLUGS}
    queue = list(initial)
    while queue:
        block = queue.pop(0)
        episode, block_id = episodes[block.slug], block.id(episodes[block.slug]["rows"])
        payload = tier_payload(episode, block)
        if estimated_tokens(payload) > MAX_REQUEST_TOKENS:
            decision = {"tier": "mixed_split", "confidence": 1.0, "probabilities": {}}
        else:
            print(f"[tier {block_id}]", flush=True)
            response, cost, latency = run_request(api_key, output, "tier", block_id, payload, spent, args.spend_cap_usd)
            spent += cost
            latencies.append(latency)
            decision = parse_tier(response, block_id)
        if decision["tier"] == "mixed_split" and block.end_index - block.start_index > 1:
            queue[0:0] = list(split_block(block))
        elif decision["tier"] in TIER_REASONS:
            resolved[block.slug].append((block, decision))
    jev_scores, episode_reports = [], []
    for slug in SLUGS:
        spans = tier_spans(episodes[slug], resolved[slug])
        predictions = [(span["start"], span["end"]) for span in spans if span["tier"] == "skip_obvious"]
        score = score_episode(slug, split[slug], goldens[slug], episodes[slug]["words"], predictions)
        jev_scores.append(score)
        episode_reports.append({"slug": slug, "transcriptSha256": episodes[slug]["transcriptSha256"],
                                "initialCandidateBlockCount": len(candidate_blocks(slug, observations[slug])), "typedSpans": spans,
                                "jevV71TierOnly": score, "historicalGeminiV1": next(row for row in gemini_scores if row["slug"] == slug)})
    report = {"schemaVersion": 1, "experiment": EXPERIMENT, "status": "evaluation-only", "model": MODEL,
              "completedAt": datetime.now(timezone.utc).isoformat(),
              "method": {"jev": "V7.1 broad candidate pass plus recursive block-level minimum-preset classification; reason-label calls are omitted because ads-only scoring uses skip_obvious.",
                         "gemini": "Previously saved Gemini-v1 artifacts; no Gemini request is made by this experiment.",
                         "caveat": "Both use the same five approved ads-only goldens, but Gemini-v1 used its historical prompt and sentence splitter. This is a historical-baseline comparison, not exact deployed-production parity."},
              "totalJevCostUsd": round(spent, 8),
              "latencyMs": {"median": round(statistics.median(latencies), 1), "max": round(max(latencies), 1)} if latencies else {},
              "summaries": {"jevV71TierOnly": summarize(jev_scores), "historicalGeminiV1": summarize(gemini_scores)}, "episodes": episode_reports,
              "policy": {"previewsAndRecapsAlwaysKept": True, "outputTier": "skip_obvious", "candidateThreshold": CANDIDATE_THRESHOLD}}
    save_json(output / "report.json", report)
    save_json(output / "manifest.json", {"schemaVersion": 1, "experiment": EXPERIMENT, "model": MODEL, "slugs": list(SLUGS),
                                           "requestHashes": [request_sha256(payload) for _, payload in broad_requests]})
    print(f"Wrote {output / 'report.json'}")
    print(f"Jev cost: ${spent:.5f}; Gemini cost: $0.00 (saved historical artifacts)")


if __name__ == "__main__":
    main()
