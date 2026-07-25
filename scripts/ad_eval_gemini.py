#!/usr/bin/env python3
"""One-shot Gemini evaluation against the frozen ad-detection holdout.

This is deliberately an offline experiment.  It consumes the already-approved,
hash-pinned transcripts under ``tmp/ad-eval`` and writes all model artifacts back
under that ignored directory; it does not change app behavior or goldens.
"""

from __future__ import annotations

import argparse
import hashlib
import html
import json
import os
import re
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass, asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from ad_eval_corpus_score import DEFAULT_CORPUS, DEFAULT_WORKDIR, load_corpus, summarize
from ad_eval_score import boundary_errors, excerpt, failure_modes, match_pairs, time_weighted


MODEL = "gemini-3.6-flash"
PILOT_SLUGS = (
    "99-percent-invisible",
    "cougar-sports",
    "darknet-diaries",
    "joe-rogan-mrbeast",
    "ai-news-strategy-daily",
)
PRICE_CARD = {
    "model": MODEL,
    "currency": "USD",
    "source": "https://ai.google.dev/gemini-api/docs/pricing",
    "capturedAt": "2026-07-24",
    "inputUsdPerMillionTokens": 1.50,
    "outputAndThinkingUsdPerMillionTokens": 7.50,
    "contextCachingUsed": False,
}
# Gemini 3.6 counts hidden thinking against this allowance.  A 2k cap can cut
# off a tiny final JSON document after an otherwise useful reasoning pass.
MAX_OUTPUT_TOKENS = 8192
MAX_SENTENCE_SECONDS = 18.0
GAP_BOUNDARY_SECONDS = 0.60

SYSTEM_PROMPT = """You identify removable ad spans in a podcast transcript for a skip-ads feature.

Return every and only the transcript ranges that should be skipped:
- paid commercials, sponsor/live reads, dynamically inserted ads, network promos,
  and membership/subscription CTAs are ads;
- normal host talk, interviews, story/news content, show openings/closings, and a
  host saying welcome back without a sales pitch are content;
- a complete or substantial cross-post/feed-drop episode is content, even if it
  is another show's episode; separately inserted ads inside it remain ads.

The supplied rows are chronological, complete, and untruncated. Each row is one
sentence-like span. Return whole ad pods using the inclusive first and last row
IDs. Include the opener, body, disclaimer, and CTA; stop before the show resumes.
If a boundary is uncertain, prefer content rather than skipping show material.
Output only JSON matching the supplied schema. Do not explain your answer."""

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
                },
                "required": ["startSentence", "endSentence"],
            },
        }
    },
    "required": ["spans"],
}


@dataclass(frozen=True)
class SentenceRow:
    id: int
    start_word: int
    end_word: int
    start: float
    end: float
    text: str


def sha256_json(value: Any) -> str:
    encoded = json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def transcript_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def sentence_rows(words: list[dict[str, Any]]) -> list[SentenceRow]:
    """Mirror the shipped segmenter's sentence boundaries without truncating text."""
    rows: list[SentenceRow] = []
    start_word = 0
    current: list[str] = []

    for index, word in enumerate(words):
        current.append(str(word["word"]).strip())
        next_gap = (
            float(words[index + 1]["start"]) - float(word["end"])
            if index + 1 < len(words)
            else GAP_BOUNDARY_SECONDS
        )
        duration = float(word["end"]) - float(words[start_word]["start"])
        terminal = str(word["word"]).rstrip().endswith((".", "?", "!"))
        if not (terminal or next_gap >= GAP_BOUNDARY_SECONDS or duration >= MAX_SENTENCE_SECONDS or index + 1 == len(words)):
            continue
        rows.append(
            SentenceRow(
                id=len(rows) + 1,
                start_word=start_word,
                end_word=index + 1,
                start=float(words[start_word]["start"]),
                end=float(word["end"]),
                text=" ".join(part for part in current if part),
            )
        )
        start_word = index + 1
        current = []
    return rows


def clean_text(value: str, limit: int) -> str:
    value = re.sub(r"<[^>]*>", " ", value)
    value = re.sub(r"\s+", " ", value).strip()
    return value[:limit] + ("…" if len(value) > limit else "")


def load_context(workdir: Path, slug: str) -> dict[str, str]:
    path = workdir / slug / "meta.json"
    if not path.exists():
        return {"show": slug, "episode": "", "showDescription": ""}
    data = json.loads(path.read_text(encoding="utf-8"))
    return {
        "show": str(data.get("showName") or slug),
        "episode": str(data.get("episodeTitle") or ""),
        "showDescription": clean_text(str(data.get("showDescription") or ""), 900),
    }


def build_user_prompt(context: dict[str, str], rows: list[SentenceRow]) -> str:
    header = [
        f"SHOW: {context['show']}",
        f"EPISODE: {context['episode'] or '(unknown)'}",
        f"SHOW CONTEXT: {context['showDescription'] or '(none)'}",
        "",
        "TRANSCRIPT ROWS (ID | seconds | source word range | text):",
    ]
    rendered = [
        f"[{row.id}] | {row.start:.2f}-{row.end:.2f} | w{row.start_word}-w{row.end_word - 1} | {row.text}"
        for row in rows
    ]
    return "\n".join([*header, *rendered])


def request_payload(user_prompt: str) -> dict[str, Any]:
    return {
        "systemInstruction": {"parts": [{"text": SYSTEM_PROMPT}]},
        "contents": [{"role": "user", "parts": [{"text": user_prompt}]}],
        "generationConfig": {
            "responseMimeType": "application/json",
            "responseJsonSchema": RESPONSE_SCHEMA,
            "maxOutputTokens": MAX_OUTPUT_TOKENS,
        },
    }


def extract_response(response: dict[str, Any]) -> tuple[dict[str, Any], str, dict[str, Any]]:
    candidates = response.get("candidates") or []
    if not candidates:
        raise ValueError(f"Gemini returned no candidate: {response.get('promptFeedback') or response}")
    parts = candidates[0].get("content", {}).get("parts", [])
    # Gemini 3.6 can return one or more thought parts before its structured
    # response. Those parts are billable and retained in usage metadata, but
    # they are not part of the JSON contract we asked it to satisfy.
    text = "".join(
        str(part.get("text", ""))
        for part in parts
        if "text" in part and not part.get("thought", False)
    ).strip()
    if not text:
        raise ValueError("Gemini candidate did not contain JSON text")
    try:
        prediction = json.loads(text)
    except json.JSONDecodeError as error:
        raise ValueError(f"Gemini returned invalid JSON: {error}") from error
    usage = dict(response.get("usageMetadata") or {})
    return prediction, text, usage


def validate_prediction(prediction: dict[str, Any], rows: list[SentenceRow]) -> list[tuple[int, int]]:
    if set(prediction) != {"spans"} or not isinstance(prediction["spans"], list):
        raise ValueError("response must contain only a spans array")
    spans: list[tuple[int, int]] = []
    previous_end = 0
    for item in prediction["spans"]:
        if not isinstance(item, dict) or set(item) != {"startSentence", "endSentence"}:
            raise ValueError("each span must contain only startSentence and endSentence")
        start, end = item["startSentence"], item["endSentence"]
        if isinstance(start, bool) or isinstance(end, bool) or not isinstance(start, int) or not isinstance(end, int):
            raise ValueError("sentence IDs must be integers")
        if not (1 <= start <= end <= len(rows)):
            raise ValueError(f"invalid sentence range {start}-{end} for {len(rows)} rows")
        if start <= previous_end:
            raise ValueError("sentence ranges must be sorted and non-overlapping")
        spans.append((start, end))
        previous_end = end
    return spans


def sentence_spans_to_time(spans: list[tuple[int, int]], rows: list[SentenceRow]) -> list[tuple[float, float]]:
    return [(rows[start - 1].start, rows[end - 1].end) for start, end in spans]


def usage_cost(usage: dict[str, Any]) -> dict[str, float | int]:
    prompt = int(usage.get("promptTokenCount", 0))
    candidates = int(usage.get("candidatesTokenCount", 0))
    thoughts = int(usage.get("thoughtsTokenCount", 0))
    input_cost = prompt / 1_000_000 * PRICE_CARD["inputUsdPerMillionTokens"]
    output_cost = (candidates + thoughts) / 1_000_000 * PRICE_CARD["outputAndThinkingUsdPerMillionTokens"]
    return {
        "promptTokens": prompt,
        "candidateTokens": candidates,
        "thinkingTokens": thoughts,
        "totalTokens": int(usage.get("totalTokenCount", prompt + candidates + thoughts)),
        "inputCostUsd": round(input_cost, 8),
        "outputAndThinkingCostUsd": round(output_cost, 8),
        "totalCostUsd": round(input_cost + output_cost, 8),
    }


def estimated_request_cost(user_prompt: str) -> float:
    """Conservative preflight estimate; provider usage is authoritative after a call."""
    input_tokens = len(user_prompt) / 3
    output_tokens = 8_192  # covers output plus a generous hidden-thinking allowance
    return input_tokens / 1_000_000 * PRICE_CARD["inputUsdPerMillionTokens"] + output_tokens / 1_000_000 * PRICE_CARD["outputAndThinkingUsdPerMillionTokens"]


def call_gemini(api_key: str, payload: dict[str, Any], model: str) -> dict[str, Any]:
    url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
    request = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json", "x-goog-api-key": api_key},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=180) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Gemini HTTP {error.code}: {body[:1000]}") from error


def score_episode(
    slug: str,
    split: str,
    golden: dict[str, Any],
    words: list[dict[str, Any]],
    predictions: list[tuple[float, float]],
) -> dict[str, Any]:
    gold = [(float(span["start"]), float(span["end"])) for span in golden["spans"]]
    seg, matches = match_pairs(predictions, gold)
    weighted = time_weighted(predictions, gold)
    duration = float(words[-1]["end"]) if words else 0.0
    return {
        "slug": slug,
        "split": split,
        "durationSeconds": round(duration, 3),
        "precision": round(seg.precision, 4),
        "recall": round(seg.recall, 4),
        "truePositives": seg.true_positives,
        "falsePositives": seg.false_positives,
        "falseNegatives": seg.false_negatives,
        "timeWeighted": weighted,
        "contentLossSecondsPerListeningHour": round(weighted["falsePositiveSeconds"] / duration * 3600, 3) if duration else 0.0,
        "missedAdSecondsPerListeningHour": round(weighted["falseNegativeSeconds"] / duration * 3600, 3) if duration else 0.0,
        "boundary": boundary_errors(predictions, gold, matches),
        "failureModes": failure_modes(predictions, gold, matches),
        "predictions": [{"start": start, "end": end, "excerpt": excerpt(words, start, end)} for start, end in predictions],
    }


def baseline_summary(corpus: Path, slugs: list[str]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for name, path in (("heuristic-cue-v6.1", corpus / "benchmark-v6.1.json"), ("anchor-viterbi-v1", corpus / "benchmark-viterbi.json")):
        payload = json.loads(path.read_text(encoding="utf-8"))
        rows = [row for row in payload["episodes"] if row["slug"] in slugs]
        if len(rows) != len(slugs):
            raise ValueError(f"{path} is missing a pilot episode")
        result[name] = summarize(rows)
    return result


def write_review(rows: list[dict[str, Any]], output: Path) -> None:
    sections: list[str] = []
    for row in rows:
        failures = row["failureModes"]
        items = "".join(f"<li>{html.escape(json.dumps(item))}</li>" for item in failures)
        predictions = "".join(
            f"<li>{prediction['start']:.2f}-{prediction['end']:.2f}: {html.escape(prediction['excerpt'])}</li>"
            for prediction in row["predictions"]
        )
        sections.append(
            f"<h2>{html.escape(row['slug'])}</h2><p>time P={row['timeWeighted']['precision']:.3f}, R={row['timeWeighted']['recall']:.3f}</p>"
            f"<h3>Predictions</h3><ol>{predictions}</ol><h3>Failures</h3><ol>{items}</ol>"
        )
    output.write_text("<!doctype html><meta charset=utf-8><title>Gemini ad-eval review</title><h1>Gemini ad-eval review</h1>" + "\n".join(sections), encoding="utf-8")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workdir", type=Path, default=DEFAULT_WORKDIR)
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    parser.add_argument("--output", type=Path, default=None)
    parser.add_argument("--show", action="append", choices=PILOT_SLUGS, help="Run one or more pilot slugs (defaults to all five).")
    parser.add_argument("--model", default=MODEL)
    parser.add_argument("--spend-cap-usd", type=float, default=5.0)
    parser.add_argument("--dry-run", action="store_true", help="Build and validate requests without contacting Gemini.")
    parser.add_argument("--rerun", action="store_true", help="Replace an existing result for the same slug.")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.spend_cap_usd <= 0:
        raise SystemExit("--spend-cap-usd must be positive")
    workdir, corpus = args.workdir.resolve(), args.corpus.resolve()
    output = (args.output or workdir / "gemini-v1").resolve()
    slugs = list(args.show or PILOT_SLUGS)
    split, goldens = load_corpus(corpus, workdir)
    if any(split[slug] != "holdout" for slug in slugs):
        raise SystemExit("pilot must use only frozen holdout episodes")
    if args.model != MODEL:
        raise SystemExit(f"This fixed experiment only supports --model {MODEL}")
    api_key = os.environ.get("GEMINI_API_KEY", "")
    if not args.dry_run and not api_key:
        raise SystemExit("GEMINI_API_KEY is required unless --dry-run is used")

    output.mkdir(parents=True, exist_ok=True)
    (output / "price-card.json").write_text(json.dumps(PRICE_CARD, indent=2) + "\n", encoding="utf-8")
    completed: list[dict[str, Any]] = []
    spent = 0.0
    for slug in slugs:
        transcript = workdir / slug / "transcript.json"
        words = json.loads(transcript.read_text(encoding="utf-8"))
        rows = sentence_rows(words)
        prompt = build_user_prompt(load_context(workdir, slug), rows)
        request = request_payload(prompt)
        episode_dir = output / slug
        result_path = episode_dir / "result.json"
        request_hash = sha256_json(request)
        if result_path.exists() and not args.rerun:
            saved = json.loads(result_path.read_text(encoding="utf-8"))
            if saved.get("requestSha256") != request_hash or saved.get("transcriptSha256") != transcript_sha256(transcript):
                raise SystemExit(f"{slug}: existing result does not match this frozen request; use --rerun deliberately")
            completed.append(saved["score"])
            spent += float(saved.get("cost", {}).get("totalCostUsd", 0.0))
            print(f"[{slug}] reuse {result_path}")
            continue
        if args.dry_run:
            print(f"[{slug}] dry run: {len(rows)} sentence rows, {len(prompt):,} prompt characters")
            continue
        projected = spent + estimated_request_cost(prompt)
        if projected > args.spend_cap_usd:
            raise SystemExit(f"{slug}: projected spend ${projected:.4f} exceeds cap ${args.spend_cap_usd:.2f}")
        print(f"[{slug}] sending {len(rows)} sentence rows (projected cumulative spend <= ${projected:.4f})", flush=True)
        response = call_gemini(api_key, request, args.model)
        try:
            prediction, response_text, usage = extract_response(response)
        except ValueError:
            # Keep the provider response locally (under the ignored workdir) so
            # an incomplete structured response is diagnosable without logging
            # it to the terminal or retrying blindly.
            episode_dir.mkdir(parents=True, exist_ok=True)
            (episode_dir / "invalid-response.json").write_text(
                json.dumps(response, indent=2, ensure_ascii=False) + "\n",
                encoding="utf-8",
            )
            raise
        sentence_spans = validate_prediction(prediction, rows)
        time_spans = sentence_spans_to_time(sentence_spans, rows)
        score = score_episode(slug, split[slug], goldens[slug], words, time_spans)
        cost = usage_cost(usage)
        spent += float(cost["totalCostUsd"])
        episode_dir.mkdir(parents=True, exist_ok=True)
        result = {
            "schemaVersion": 1,
            "slug": slug,
            "model": args.model,
            "createdAt": datetime.now(timezone.utc).isoformat(),
            "transcriptSha256": transcript_sha256(transcript),
            "requestSha256": request_hash,
            "sentenceRows": [asdict(row) for row in rows],
            "prediction": prediction,
            "sentenceSpans": [{"startSentence": start, "endSentence": end} for start, end in sentence_spans],
            "rawResponseText": response_text,
            "usageMetadata": usage,
            "cost": cost,
            "score": score,
        }
        result_path.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        completed.append(score)
        print(f"[{slug}] time P={score['timeWeighted']['precision']:.3f} R={score['timeWeighted']['recall']:.3f} cost=${cost['totalCostUsd']:.5f}")
        if spent > args.spend_cap_usd:
            raise SystemExit(f"actual spend ${spent:.4f} exceeded cap; stopping before another request")

    if args.dry_run:
        return
    report = {
        "schemaVersion": 1,
        "model": args.model,
        "slugs": slugs,
        "priceCard": PRICE_CARD,
        "gemini": summarize(completed),
        "baselines": baseline_summary(corpus, slugs),
        "totalCostUsd": round(spent, 8),
        "costPerListeningHourUsd": round(spent / sum(row["durationSeconds"] for row in completed) * 3600, 8) if completed else 0.0,
        "monthlyCostAt1000ListeningHoursUsd": round(spent / sum(row["durationSeconds"] for row in completed) * 3_600_000, 4) if completed else 0.0,
        "episodes": completed,
    }
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    write_review(completed, output / "REVIEW.html")
    print(f"Wrote {output / 'report.json'}")
    print(f"Review {output / 'REVIEW.html'}")


if __name__ == "__main__":
    main()
