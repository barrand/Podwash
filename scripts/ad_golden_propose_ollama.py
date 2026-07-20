#!/usr/bin/env python3
"""Generate an independent word-indexed ad proposal with local Ollama."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import tempfile
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_TRANSCRIPT = ROOT / "tmp" / "ad-eval" / "cougar-sports" / "transcript.json"
DEFAULT_OUTPUT = (
    Path(tempfile.gettempdir()) / "podwash-cougar-proposal-gpt-oss.json"
)
LABELS = {
    "paid_dai",
    "paid_baked_in",
    "paid_host_read",
    "network_promo",
    "membership_cta",
}
CONFIDENCE_ORDER = {"low": 0, "medium": 1, "high": 2}


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_json(path: Path, payload: Any) -> None:
    encoded = (json.dumps(payload, ensure_ascii=False, indent=2) + "\n").encode()
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def numbered_words(words: list[dict[str, Any]], start: int, end: int) -> str:
    return "\n".join(
        f"{index}\t{str(words[index].get('word') or '').strip()}"
        for index in range(start, end)
    )


def prompt_for_window(
    words: list[dict[str, Any]],
    context_start: int,
    context_end: int,
    core_start: int,
    core_end: int,
) -> str:
    return f"""
You are labeling podcast advertisements for a human-golden review tool. Analyze the
numbered ASR words below. Word indices are canonical. Return strict JSON only.

Report an ad span only when its FIRST ad word is in the ownership range
[{core_start}, {core_end}). Context outside that range is supplied only so you can
find exact boundaries. endWord is EXCLUSIVE.

Labels:
- paid_dai: produced/injected commercial read, including a cold-open spot
- paid_baked_in: produced paid ad that appears embedded in the episode
- paid_host_read: sponsor copy spoken as part of the host's show
- network_promo: promotion for another program, podcast, station, or network
- membership_cta: listener membership, donation, or fundraising appeal

Boundary policy:
- One creative per span, even in a back-to-back ad pod.
- Include the complete creative: setup, CTA, URL, legal disclaimer, and tagline.
- Exclude story/show text immediately before and after it. False-positive story
  words are worse than leaving a doubtful edge word out.
- Preserve editorial re-entry, guest introductions, recaps, station/show IDs that
  resume the program, and ordinary discussion of products.
- Ads may begin at word 0 with no sponsor phrase.
- Host reads and local segment sponsorships can sound in-domain.
- ASR may mangle brands, URLs, punctuation, and numbers.
- Do not turn an entire paragraph into an ad because it contains one sponsor tag.
- A full feed-drop/cross-post episode or substantial preview played as the main
  payload of the RSS item is content, not network_promo. Do not label the body
  just because it is another podcast. Only label separate inserted ads, short
  trailers, or standalone CTAs that wrap/interrupt that payload.

Output exactly:
{{
  "spans": [
    {{
      "startWord": 0,
      "endWord": 10,
      "label": "paid_dai",
      "advertiser": "Brand or empty string",
      "confidence": "high|medium|low",
      "startQuote": "first few ASR words",
      "endQuote": "last few ASR words",
      "rationale": "brief concrete reason"
    }}
  ],
  "possibleMisses": [
    {{
      "startWord": 20,
      "endWord": 30,
      "reason": "why a human should inspect this unmarked region"
    }}
  ]
}}

Use possibleMisses for ambiguous commercial-looking regions that you intentionally
did not label. Empty arrays are valid.

Numbered ASR words ({context_start} through {context_end - 1}):
{numbered_words(words, context_start, context_end)}
""".strip()


def parse_json_output(raw: str) -> dict[str, Any]:
    cleaned = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", raw).strip()
    try:
        payload = json.loads(cleaned)
    except json.JSONDecodeError:
        start = cleaned.find("{")
        end = cleaned.rfind("}")
        if start < 0 or end <= start:
            raise RuntimeError(f"Ollama did not return JSON: {cleaned[:500]}")
        payload = json.loads(cleaned[start : end + 1])
    if isinstance(payload, str):
        payload = json.loads(payload)
    if not isinstance(payload, dict):
        raise RuntimeError("Ollama response must be a JSON object")
    return payload


def run_ollama(
    model: str,
    think: str,
    prompt: str,
    context_tokens: int,
    predict_tokens: int,
) -> dict[str, Any]:
    request_payload = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "stream": False,
        "format": "json",
        "think": think,
        "keep_alive": "30m",
        "options": {
            "num_ctx": context_tokens,
            "num_predict": predict_tokens,
            "temperature": 0,
            "seed": 42,
        },
    }
    request = urllib.request.Request(
        "http://127.0.0.1:11434/api/chat",
        data=json.dumps(request_payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30 * 60) as response:
            payload = json.load(response)
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Ollama HTTP {error.code}: {detail[:1000]}") from error
    except urllib.error.URLError as error:
        raise RuntimeError(f"Could not reach local Ollama: {error}") from error
    content = str((payload.get("message") or {}).get("content") or "")
    if not content.strip():
        thinking = str((payload.get("message") or {}).get("thinking") or "")
        raise RuntimeError(
            "Ollama returned no final answer "
            f"(done_reason={payload.get('done_reason')!r}, "
            f"prompt_tokens={payload.get('prompt_eval_count')!r}, "
            f"generated_tokens={payload.get('eval_count')!r}, "
            f"thinking_chars={len(thinking)})"
        )
    return parse_json_output(content)


def normalized_candidate(
    raw: dict[str, Any],
    word_count: int,
    core_start: int,
    core_end: int,
) -> Optional[dict[str, Any]]:
    try:
        start = int(raw["startWord"])
        end = int(raw["endWord"])
    except (KeyError, TypeError, ValueError):
        return None
    if start < core_start or start >= core_end:
        return None
    if start < 0 or end <= start or end > word_count:
        return None
    label = str(raw.get("label") or "")
    if label not in LABELS:
        return None
    confidence = str(raw.get("confidence") or "low").lower()
    if confidence not in CONFIDENCE_ORDER:
        confidence = "low"
    return {
        "startWord": start,
        "endWord": end,
        "label": label,
        "advertiser": str(raw.get("advertiser") or "").strip(),
        "confidence": confidence,
        "startQuote": str(raw.get("startQuote") or "").strip(),
        "endQuote": str(raw.get("endQuote") or "").strip(),
        "rationale": str(raw.get("rationale") or "").strip(),
    }


def normalized_audit(
    raw: dict[str, Any],
    word_count: int,
    core_start: int,
    core_end: int,
) -> Optional[dict[str, Any]]:
    try:
        start = int(raw["startWord"])
        end = int(raw["endWord"])
    except (KeyError, TypeError, ValueError):
        return None
    if start < core_start or start >= core_end:
        return None
    if start < 0 or end <= start or end > word_count:
        return None
    return {
        "startWord": start,
        "endWord": end,
        "reason": str(raw.get("reason") or "Ambiguous commercial cue.").strip(),
    }


def overlap_fraction(left: dict[str, Any], right: dict[str, Any]) -> float:
    overlap = max(
        0,
        min(int(left["endWord"]), int(right["endWord"]))
        - max(int(left["startWord"]), int(right["startWord"])),
    )
    shorter = min(
        int(left["endWord"]) - int(left["startWord"]),
        int(right["endWord"]) - int(right["startWord"]),
    )
    return overlap / shorter if shorter else 0.0


def deduplicate(candidates: list[dict[str, Any]]) -> list[dict[str, Any]]:
    kept: list[dict[str, Any]] = []
    for candidate in sorted(
        candidates,
        key=lambda item: (
            int(item["startWord"]),
            -CONFIDENCE_ORDER[str(item["confidence"])],
            -(int(item["endWord"]) - int(item["startWord"])),
        ),
    ):
        duplicate_index = next(
            (
                index
                for index, existing in enumerate(kept)
                if overlap_fraction(candidate, existing) >= 0.65
            ),
            None,
        )
        if duplicate_index is None:
            kept.append(candidate)
            continue
        existing = kept[duplicate_index]
        candidate_rank = CONFIDENCE_ORDER[str(candidate["confidence"])]
        existing_rank = CONFIDENCE_ORDER[str(existing["confidence"])]
        if candidate_rank > existing_rank:
            kept[duplicate_index] = candidate
    return sorted(kept, key=lambda item: (item["startWord"], item["endWord"]))


def deduplicate_audits(items: list[dict[str, Any]]) -> list[dict[str, Any]]:
    kept: list[dict[str, Any]] = []
    for item in sorted(items, key=lambda value: (value["startWord"], value["endWord"])):
        if not any(overlap_fraction(item, existing) >= 0.65 for existing in kept):
            kept.append(item)
    return kept


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--transcript", type=Path, default=DEFAULT_TRANSCRIPT)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--model", default="gpt-oss:20b")
    parser.add_argument("--think", choices=("low", "medium", "high"), default="high")
    parser.add_argument("--context-tokens", type=int, default=16384)
    parser.add_argument("--predict-tokens", type=int, default=6000)
    parser.add_argument("--core-words", type=int, default=1800)
    parser.add_argument("--context-words", type=int, default=220)
    parser.add_argument("--max-windows", type=int)
    args = parser.parse_args()

    words = json.loads(args.transcript.read_text(encoding="utf-8"))
    if not isinstance(words, list) or not words:
        raise SystemExit("transcript must be a non-empty word array")
    transcript_hash = file_sha256(args.transcript)
    candidates: list[dict[str, Any]] = []
    audit_items: list[dict[str, Any]] = []
    raw_windows: list[dict[str, Any]] = []

    starts = list(range(0, len(words), args.core_words))
    if args.max_windows is not None:
        starts = starts[: args.max_windows]
    for window_number, core_start in enumerate(starts, 1):
        core_end = min(len(words), core_start + args.core_words)
        context_start = max(0, core_start - args.context_words)
        context_end = min(len(words), core_end + args.context_words)
        print(
            f"window {window_number}/{len(starts)}: "
            f"core {core_start}..{core_end}",
            flush=True,
        )
        response = run_ollama(
            args.model,
            args.think,
            prompt_for_window(
                words,
                context_start,
                context_end,
                core_start,
                core_end,
            ),
            args.context_tokens,
            args.predict_tokens,
        )
        normalized_spans = [
            candidate
            for raw in response.get("spans") or []
            if isinstance(raw, dict)
            if (
                candidate := normalized_candidate(
                    raw,
                    len(words),
                    core_start,
                    core_end,
                )
            )
        ]
        normalized_audits = [
            item
            for raw in response.get("possibleMisses") or []
            if isinstance(raw, dict)
            if (
                item := normalized_audit(
                    raw,
                    len(words),
                    core_start,
                    core_end,
                )
            )
        ]
        candidates.extend(normalized_spans)
        audit_items.extend(normalized_audits)
        raw_windows.append(
            {
                "coreStart": core_start,
                "coreEnd": core_end,
                "contextStart": context_start,
                "contextEnd": context_end,
                "response": response,
            }
        )

    output = {
        "schemaVersion": 1,
        "source": "gpt-oss",
        "model": args.model,
        "reasoningEffort": args.think,
        "contextTokens": args.context_tokens,
        "predictTokens": args.predict_tokens,
        "generatedAt": utc_now(),
        "transcriptSha256": transcript_hash,
        "wordCount": len(words),
        "windowing": {
            "coreWords": args.core_words,
            "contextWords": args.context_words,
            "windowCount": len(starts),
        },
        "spans": deduplicate(candidates),
        "possibleMisses": deduplicate_audits(audit_items),
        "rawWindows": raw_windows,
    }
    atomic_json(args.output, output)
    print(
        f"wrote {len(output['spans'])} spans and "
        f"{len(output['possibleMisses'])} possible misses to {args.output}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
