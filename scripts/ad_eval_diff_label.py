#!/usr/bin/env python3
"""Diff-label ads: ASR spans absent from a published (ad-free) transcript."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any

from ad_eval_common import DEFAULT_WORKDIR, fmt_time, http_get, load_meta, select_shows, show_dir
from ad_eval_transcribe import fetch_tal_transcript, strip_html


def normalize_token(raw: str) -> str:
    lower = raw.lower()
    return re.sub(r"[^a-z0-9']+", "", lower)


def tokenize_published(text: str) -> list[str]:
    return [t for t in (normalize_token(w) for w in re.findall(r"\S+", text)) if t]


def fetch_published_text(url: str) -> str:
    if "thisamericanlife.org" in url:
        return fetch_tal_transcript(url)
    raw = http_get(url, timeout=120).decode("utf-8", errors="replace")
    raw = re.sub(r"<script[^>]*>.*?</script>", " ", raw, flags=re.I | re.S)
    raw = re.sub(r"<style[^>]*>.*?</style>", " ", raw, flags=re.I | re.S)
    return strip_html(raw)


def align_missing_spans(
    asr_words: list[dict],
    published_tokens: list[str],
    *,
    window: int = 12,
) -> list[tuple[float, float]]:
    """Greedy forward align ASR to published; emit time ranges of unmatched ASR runs.

    When the next ASR token is not among the next `window` published tokens,
    start an unmatched run until alignment resumes.
    """
    pub = published_tokens
    pi = 0
    unmatched_start: float | None = None
    unmatched_end: float | None = None
    spans: list[tuple[float, float]] = []

    def flush() -> None:
        nonlocal unmatched_start, unmatched_end
        if unmatched_start is not None and unmatched_end is not None:
            if unmatched_end - unmatched_start >= 3.0:
                spans.append((unmatched_start, unmatched_end))
        unmatched_start = None
        unmatched_end = None

    for w in asr_words:
        tok = normalize_token(w["word"])
        if not tok:
            continue
        # Look ahead in published for a match.
        found = None
        for j in range(pi, min(pi + window, len(pub))):
            if pub[j] == tok:
                found = j
                break
        if found is not None:
            flush()
            pi = found + 1
        else:
            if unmatched_start is None:
                unmatched_start = float(w["start"])
            unmatched_end = float(w["end"])
    flush()
    return merge_close(spans, gap=4.0)


def merge_close(
    spans: list[tuple[float, float]], gap: float
) -> list[tuple[float, float]]:
    if not spans:
        return []
    ordered = sorted(spans)
    out = [list(ordered[0])]
    for s, e in ordered[1:]:
        if s <= out[-1][1] + gap:
            out[-1][1] = max(out[-1][1], e)
        else:
            out.append([s, e])
    return [(a, b) for a, b in out]


def label_show(workdir: Path, slug: str, *, min_seconds: float = 5.0) -> dict[str, Any] | None:
    meta = load_meta(workdir, slug)
    out_dir = show_dir(workdir, slug)
    words_path = out_dir / "transcript.json"
    if not words_path.exists():
        print(f"[{slug}] skip — no transcript.json")
        return None

    url = meta.published_transcript_url or meta.tal_transcript_url
    if not url:
        print(f"[{slug}] skip — no published transcript URL")
        return None

    print(f"[{slug}] fetching published transcript {url}")
    try:
        published = fetch_published_text(url)
    except Exception as exc:  # noqa: BLE001
        print(f"[{slug}] published fetch failed: {exc}")
        return None

    pub_tokens = tokenize_published(published)
    if len(pub_tokens) < 50:
        print(f"[{slug}] skip — published text too short ({len(pub_tokens)} tokens)")
        return None

    asr = json.loads(words_path.read_text(encoding="utf-8"))
    spans = [
        (s, e)
        for s, e in align_missing_spans(asr, pub_tokens)
        if e - s >= min_seconds
    ]

    (out_dir / "published_transcript.txt").write_text(published + "\n", encoding="utf-8")
    payload = {
        "source": "diff-label",
        "publishedTranscriptUrl": url,
        "publishedTokenCount": len(pub_tokens),
        "asrWordCount": len(asr),
        "spans": [
            {
                "start": round(s, 3),
                "end": round(e, 3),
                "kind": "diff-absent",
                "rationale": "ASR span absent from published ad-free transcript",
            }
            for s, e in spans
        ],
    }
    (out_dir / "diff_golden.json").write_text(
        json.dumps(payload, indent=2) + "\n", encoding="utf-8"
    )
    # Promote to golden.json when none exists yet (human can override later).
    golden_path = out_dir / "golden.json"
    if not golden_path.exists():
        golden_path.write_text(
            json.dumps(
                {
                    "source": "diff-label-auto-promoted",
                    "reviewer": "pending-human-spot-check",
                    "spans": payload["spans"],
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        print(f"[{slug}] wrote golden.json ({len(spans)} spans) — spot-check recommended")
    else:
        print(f"[{slug}] wrote diff_golden.json ({len(spans)} spans); golden.json unchanged")

    for s, e in spans:
        print(f"  {fmt_time(s)}–{fmt_time(e)} ({e - s:.1f}s)")
    return payload


def main() -> None:
    parser = argparse.ArgumentParser(description="Diff-label ads vs published transcripts")
    parser.add_argument("--workdir", type=Path, default=DEFAULT_WORKDIR)
    parser.add_argument("--show", action="append")
    parser.add_argument("--min-seconds", type=float, default=5.0)
    args = parser.parse_args()

    workdir = args.workdir.resolve()
    wanted = set(args.show) if args.show else None
    for slug, _ in select_shows(wanted):
        label_show(workdir, slug, min_seconds=args.min_seconds)


if __name__ == "__main__":
    main()
