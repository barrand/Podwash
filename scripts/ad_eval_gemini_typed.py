#!/usr/bin/env python3
"""Run a direct Gemini typed-interruption baseline on the Jev V7 pilot."""

from __future__ import annotations

import argparse
import json
import os
from dataclasses import asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from ad_eval_corpus_score import DEFAULT_WORKDIR
from ad_eval_gemini import (
    MAX_OUTPUT_TOKENS,
    MODEL,
    PRICE_CARD,
    call_gemini,
    estimated_request_cost,
    extract_response,
    sha256_json,
    usage_cost,
)
from ad_eval_jev_v7 import PILOT_SLUGS, REASONS, load_episode
from ad_eval_jev_v71 import REASON_LEVEL, TIER_LEVEL, interval_metrics, reference_intervals


EXPERIMENT = "gemini-typed-v7.2-comparison"
OUTPUT_NAME = "gemini-typed-v7.2"
TIERS = ("skip_obvious", "skip_more_only", "skip_most_only")

SYSTEM_PROMPT = """You identify removable interruption spans in complete podcast transcripts.

The listener has three nested presets. Assign each removable span the LEAST aggressive preset that should remove it:
- skip_obvious: paid ads and underwriting/sponsor acknowledgements.
- skip_more_only: other-show promos, publisher/current-show promotions, and membership/support appeals.
- skip_most_only: engagement requests, production credits, bare network/station/show IDs, and routine sign-offs.

Always keep substantive reporting, interviews, storytelling, ordinary conversation, feed drops, and episode previews or
recaps. A preview or promise of upcoming episode content is never a sign-off or publisher promo. Off-topic subject matter
alone never makes content removable. A historical or archival commercial discussed as editorial evidence must stay, but
sample dialogue or quoted clips enclosed inside an unmistakable inserted promotional wrapper remain part of that promo.

Return complete, sorted, non-overlapping sentence ranges. Include an interruption's opener, body, disclaimer, sample
clip, and CTA, while stopping before editorial content resumes. Split adjacent material when its minimum preset changes.
Reasons are diagnostic; minimumPreset is the product-critical result. Output only JSON matching the schema."""

RESPONSE_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "spans": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "startSentence": {"type": "integer"},
                    "endSentence": {"type": "integer"},
                    "minimumPreset": {"type": "string", "enum": list(TIERS)},
                    "reasons": {
                        "type": "array",
                        "items": {"type": "string", "enum": list(REASONS)},
                    },
                },
                "required": ["startSentence", "endSentence", "minimumPreset", "reasons"],
            },
        }
    },
    "required": ["spans"],
}


def build_prompt(episode: dict[str, Any]) -> str:
    context = episode["context"]
    header = [
        f"SHOW: {context['show']}",
        f"EPISODE: {context['episode'] or '(unknown)'}",
        f"SHOW DESCRIPTION: {context['showDescription'] or '(none)'}",
        f"EPISODE DESCRIPTION: {context['episodeDescription'] or '(none)'}",
        "",
        "REASON DEFINITIONS:",
        *(f"- {name}: {definition}" for name, definition in REASONS.items()),
        "",
        "TRANSCRIPT ROWS (ID | seconds | text):",
    ]
    rendered = [f"[{row.id}] | {row.start:.2f}-{row.end:.2f} | {row.text}" for row in episode["rows"]]
    return "\n".join([*header, *rendered])


def request_payload(prompt: str, thinking_level: str | None = None) -> dict[str, Any]:
    generation_config: dict[str, Any] = {
        "responseMimeType": "application/json",
        "responseJsonSchema": RESPONSE_SCHEMA,
        "maxOutputTokens": MAX_OUTPUT_TOKENS,
    }
    if thinking_level:
        generation_config["thinkingConfig"] = {"thinkingLevel": thinking_level}
    return {
        "systemInstruction": {"parts": [{"text": SYSTEM_PROMPT}]},
        "contents": [{"role": "user", "parts": [{"text": prompt}]}],
        "generationConfig": generation_config,
    }


def validate_prediction(prediction: dict[str, Any], row_count: int) -> list[dict[str, Any]]:
    if set(prediction) != {"spans"} or not isinstance(prediction["spans"], list):
        raise ValueError("response must contain only a spans array")
    result: list[dict[str, Any]] = []
    previous_end = 0
    for raw in prediction["spans"]:
        required = {"startSentence", "endSentence", "minimumPreset", "reasons"}
        if not isinstance(raw, dict) or set(raw) != required:
            raise ValueError("each span must contain exactly startSentence, endSentence, minimumPreset, and reasons")
        start, end = raw["startSentence"], raw["endSentence"]
        tier, reasons = raw["minimumPreset"], raw["reasons"]
        if isinstance(start, bool) or isinstance(end, bool) or not isinstance(start, int) or not isinstance(end, int):
            raise ValueError("sentence IDs must be integers")
        if not (1 <= start <= end <= row_count) or start <= previous_end:
            raise ValueError(f"invalid, overlapping, or unsorted sentence range {start}-{end}")
        if tier not in TIERS or not isinstance(reasons, list) or any(reason not in REASONS for reason in reasons):
            raise ValueError(f"invalid tier or reasons for sentence range {start}-{end}")
        expected_level = TIER_LEVEL[tier]
        reason_levels = [REASON_LEVEL[reason] for reason in reasons]
        # A coherent span may contain a lower-tier reason plus material that
        # requires the selected tier.  For example, a cross-show promo can end
        # with underwriting: Skip more is still the least preset that removes
        # the complete block.  A reason requiring a *higher* preset would make
        # the selected minimum preset unsafe and remains invalid.
        if not reason_levels or any(level > expected_level for level in reason_levels) or expected_level not in reason_levels:
            raise ValueError(f"reasons do not support minimum preset for sentence range {start}-{end}")
        result.append({
            "startSentence": start,
            "endSentence": end,
            "tier": tier,
            "reasons": sorted(set(reasons)),
        })
        previous_end = end
    return result


def materialize_spans(prediction: list[dict[str, Any]], episode: dict[str, Any]) -> list[dict[str, Any]]:
    rows = episode["rows"]
    spans: list[dict[str, Any]] = []
    for index, raw in enumerate(prediction, 1):
        first, last = rows[raw["startSentence"] - 1], rows[raw["endSentence"] - 1]
        spans.append({
            "id": f"gemini-typed-{index}",
            "startSentence": first.id,
            "endSentence": last.id,
            "startWord": first.start_word,
            "endWord": last.end_word,
            "start": round(float(first.start), 3),
            "end": round(float(last.end), 3),
            "tier": raw["tier"],
            "reasons": raw["reasons"],
        })
    return spans


def score_episode(episode: dict[str, Any], spans: list[dict[str, Any]]) -> tuple[dict[str, Any], dict[str, Any]]:
    by_preset: dict[str, Any] = {}
    for name, level in (("skip_obvious", 1), ("skip_more", 2), ("skip_most", 3)):
        predicted = [(span["start"], span["end"]) for span in spans if TIER_LEVEL[span["tier"]] <= level]
        by_preset[name] = interval_metrics(predicted, reference_intervals(episode, level))
    by_reason = {
        reason: interval_metrics(
            [(span["start"], span["end"]) for span in spans if reason in span["reasons"]],
            reference_intervals(episode, 3, reason),
        )
        for reason in REASONS
    }
    return by_preset, by_reason


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workdir", type=Path, default=DEFAULT_WORKDIR)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--rerun", action="store_true")
    parser.add_argument("--spend-cap-usd", type=float, default=1.0)
    return parser.parse_args()


def invalid_attempt_cost(path: Path) -> float:
    """Return billed provider cost from a saved malformed response, if known."""
    try:
        response = json.loads(path.read_text(encoding="utf-8"))
        return float(usage_cost(dict(response.get("usageMetadata") or {}))["totalCostUsd"])
    except (OSError, ValueError, TypeError, json.JSONDecodeError):
        return 0.0


def main() -> None:
    args = parse_args()
    workdir = args.workdir.resolve()
    output = (args.output or workdir / OUTPUT_NAME).resolve()
    try:
        episodes = {slug: load_episode(workdir, slug) for slug in PILOT_SLUGS}
    except (OSError, ValueError, json.JSONDecodeError) as error:
        raise SystemExit(str(error)) from error
    jobs = [(slug, build_prompt(episodes[slug])) for slug in PILOT_SLUGS]
    if args.dry_run:
        for slug, prompt in jobs:
            print(f"[{slug}] {len(episodes[slug]['rows'])} rows, {len(prompt):,} prompt characters, projected <= ${estimated_request_cost(prompt):.4f}")
        print(f"Projected total <= ${sum(estimated_request_cost(prompt) for _, prompt in jobs):.4f}")
        return
    api_key = os.environ.get("GEMINI_API_KEY", "")
    if not api_key:
        raise SystemExit("GEMINI_API_KEY is required unless --dry-run is used")
    output.mkdir(parents=True, exist_ok=True)
    (output / "price-card.json").write_text(json.dumps(PRICE_CARD, indent=2) + "\n", encoding="utf-8")
    spent = 0.0
    reports: list[dict[str, Any]] = []
    for slug, prompt in jobs:
        episode = episodes[slug]
        episode_dir = output / slug
        result_path = episode_dir / "result.json"
        invalid_path = episode_dir / "invalid-response.json"
        prior_invalid_cost = 0.0
        request = request_payload(prompt)
        request_hash = sha256_json(request)
        if result_path.exists() and not args.rerun:
            saved = json.loads(result_path.read_text(encoding="utf-8"))
            if saved.get("requestSha256") != request_hash or saved.get("transcriptSha256") != episode["transcriptSha256"]:
                raise SystemExit(f"{slug}: cached result is stale; use --rerun deliberately")
            reports.append(saved["episodeReport"])
            spent += float(saved["cost"]["totalCostUsd"])
            print(f"[{slug}] reuse {result_path}")
            continue
        if invalid_path.exists() and not args.rerun:
            # The only saved invalid typed response was truncated at the shared
            # output/thinking limit. Retry that one episode with low thinking,
            # preserving already-valid episode results and their original
            # request hashes.
            request = request_payload(prompt, thinking_level="LOW")
            request_hash = sha256_json(request)
            prior_invalid_cost = invalid_attempt_cost(invalid_path)
            projected = spent + prior_invalid_cost + estimated_request_cost(prompt)
            if projected > args.spend_cap_usd:
                raise SystemExit(f"{slug}: projected spend ${projected:.4f} exceeds cap ${args.spend_cap_usd:.2f}")
            print(f"[{slug}] retrying malformed response with LOW thinking; prior malformed attempt cost=${prior_invalid_cost:.5f}; projected cumulative cost <= ${projected:.4f}", flush=True)
            response = call_gemini(api_key, request, MODEL)
        else:
            projected = spent + estimated_request_cost(prompt)
            if projected > args.spend_cap_usd:
                raise SystemExit(f"{slug}: projected spend ${projected:.4f} exceeds cap ${args.spend_cap_usd:.2f}")
            print(f"[{slug}] sending {len(episode['rows'])} rows; projected cumulative cost <= ${projected:.4f}", flush=True)
            response = call_gemini(api_key, request, MODEL)
        try:
            prediction, response_text, usage = extract_response(response)
            validated = validate_prediction(prediction, len(episode["rows"]))
        except ValueError:
            episode_dir.mkdir(parents=True, exist_ok=True)
            invalid_path.write_text(json.dumps(response, indent=2) + "\n", encoding="utf-8")
            raise
        spans = materialize_spans(validated, episode)
        by_preset, by_reason = score_episode(episode, spans)
        episode_report = {
            "slug": slug,
            "transcriptSha256": episode["transcriptSha256"],
            "durationSeconds": round(float(episode["rows"][-1].end), 3),
            "typedSpans": spans,
            "metricsByPreset": by_preset,
            "metricsByReason": by_reason,
        }
        cost = usage_cost(usage)
        if prior_invalid_cost:
            cost["priorMalformedAttemptCostUsd"] = round(prior_invalid_cost, 8)
            cost["totalCostUsd"] = round(float(cost["totalCostUsd"]) + prior_invalid_cost, 8)
        spent += float(cost["totalCostUsd"])
        episode_dir.mkdir(parents=True, exist_ok=True)
        result_path.write_text(json.dumps({
            "schemaVersion": 1,
            "experiment": EXPERIMENT,
            "model": MODEL,
            "createdAt": datetime.now(timezone.utc).isoformat(),
            "transcriptSha256": episode["transcriptSha256"],
            "requestSha256": request_hash,
            "sentenceRows": [asdict(row) for row in episode["rows"]],
            "prediction": prediction,
            "rawResponseText": response_text,
            "usageMetadata": usage,
            "cost": cost,
            "episodeReport": episode_report,
        }, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        reports.append(episode_report)
        print(f"[{slug}] obvious P={by_preset['skip_obvious']['precision']:.3f} R={by_preset['skip_obvious']['recall']:.3f} cost=${cost['totalCostUsd']:.5f}")
    duration = sum(item["durationSeconds"] for item in reports)
    report = {
        "schemaVersion": 1,
        "experiment": EXPERIMENT,
        "status": "evaluation-only",
        "model": MODEL,
        "completedAt": datetime.now(timezone.utc).isoformat(),
        "priceCard": PRICE_CARD,
        "totalCostUsd": round(spent, 8),
        "costPerListeningHourUsd": round(spent / duration * 3600, 8) if duration else 0.0,
        "episodes": reports,
        "policy": {
            "sameTypedGoldensAsJevV7": True,
            "previewsAndRecapsAlwaysKept": True,
            "quotedClipsInsidePromosRemainRemovable": True,
            "classificationUnit": "complete transcript, direct typed spans",
        },
    }
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote {output / 'report.json'}")


if __name__ == "__main__":
    main()
