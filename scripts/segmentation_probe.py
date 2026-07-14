#!/usr/bin/env python3
"""Probe HeuristicContentSegmenter (heuristic-cue-v3) on a plain-text transcript.

Assigns synthetic word timings spread across a pinned duration, then runs the
same cue-window logic as PodWash/PodWash/HeuristicContentSegmenter.swift.

Usage:
  python3 scripts/segmentation_probe.py TRANSCRIPT.txt --duration 4470
  python3 scripts/segmentation_probe.py --url https://www.thisamericanlife.org/891/transcript
"""

from __future__ import annotations

import argparse
import re
import sys
import urllib.request
from dataclasses import dataclass


# Mirrors HeuristicContentSegmenter.Constants + phrase tables (heuristic-cue-v3).
ANCHOR_MAX_SECONDS = 20.0
ANCHOR_MAX_TOKENS = 80
WINDOW_SECONDS = 10.0
WINDOW_STEP_SECONDS = 2.5
SCORE_THRESHOLD = 2.0
DRIFT_BOOST_THRESHOLD = 0.5
DRIFT_BOOST = 0.5
SPONSOR_WEIGHT = 2.0
TANGENT_WEIGHT = 1.5
MIN_DURATION_SECONDS = 5.0
MERGE_GAP_SECONDS = 1.5
LEAD_IN_TOKENS = 3
TRAIL_SECONDS = 3.0
SPONSOR_TRAIL_SECONDS = 12.0
MAX_TOKEN_GAP_SECONDS = 0.55

SPONSOR_PHRASES = sorted(
    [
        "link in the description",
        "thank you to today",
        "thank you to todays sponsors",
        "this message comes from",
        "support for this american life",
        "segment was brought to you by",
        "this episode is brought to you by",
        "built to back small businesses",
        "support comes from",
        "delivered to public radio",
        "public radio stations",
        "thanks to our sponsors",
        "become a life partner",
        "support the show",
        "apply in minutes at",
        "our friends at",
        "brought to you by",
        "brought to you",
        "sponsored by",
        "underwriting from",
        "funding for",
        "use code",
        "ad break",
        "advertisement",
        "check out",
        "sponsored",
        "sponsor",
        "promo",
        "discount",
    ],
    key=len,
    reverse=True,
)

TANGENT_PHRASES = sorted(
    [
        "before we continue",
        "speaking of",
        "side note",
        "real quick",
        "tangent",
        "unrelated",
        "anyway",
    ],
    key=len,
    reverse=True,
)

STOP_WORDS = {
    "a", "an", "the", "and", "or", "but", "if", "in", "on", "of", "to", "for",
    "with", "from", "by", "as", "at", "is", "are", "was", "were", "be", "been",
    "being", "this", "that", "these", "those", "it", "its", "i", "we", "you",
    "he", "she", "they", "them", "their", "our", "your", "my", "me", "us",
    "not", "no", "so", "too", "very", "just", "about", "into", "over", "under",
    "again", "then", "than", "also", "can", "could", "would", "should", "will",
    "may", "might", "must", "do", "does", "did", "done", "have", "has", "had",
    "having",
}

CUE_LEXICON_WORDS = {
    part for phrase in SPONSOR_PHRASES + TANGENT_PHRASES for part in phrase.split()
}


@dataclass
class Token:
    word: str
    start: float
    end: float


@dataclass
class CueHit:
    start_index: int
    end_index: int
    weight: float
    phrase: str


@dataclass
class Segment:
    start: float
    end: float


def normalize(raw: str) -> str:
    lower = raw.lower()
    alnum = re.sub(r"^[^a-z0-9]+|[^a-z0-9]+$", "", lower)
    return alnum


def text_to_tokens(text: str, duration: float) -> list[Token]:
    words = [normalize(w) for w in re.findall(r"\S+", text)]
    words = [w for w in words if w]
    if not words:
        return []
    if len(words) == 1:
        return [Token(words[0], 0.0, duration)]
    step = duration / len(words)
    tokens: list[Token] = []
    t = 0.0
    for word in words:
        tokens.append(Token(word, t, t + step))
        t += step
    tokens[-1] = Token(tokens[-1].word, tokens[-1].start, duration)
    return tokens


def on_topic_anchor(tokens: list[Token]) -> set[str]:
    selected: list[Token] = []
    for i, token in enumerate(tokens):
        if i >= ANCHOR_MAX_TOKENS:
            break
        if token.start >= ANCHOR_MAX_SECONDS:
            break
        selected.append(token)
    bag: set[str] = set()
    for token in selected:
        if len(token.word) <= 2:
            continue
        if token.word in STOP_WORDS:
            continue
        if token.word in CUE_LEXICON_WORDS:
            continue
        bag.add(token.word)
    return bag


def find_cue_hits(tokens: list[Token]) -> list[CueHit]:
    words = [t.word for t in tokens]
    occupied = [False] * len(tokens)
    hits: list[CueHit] = []
    phrases = [(p, SPONSOR_WEIGHT) for p in SPONSOR_PHRASES] + [
        (p, TANGENT_WEIGHT) for p in TANGENT_PHRASES
    ]
    for phrase, weight in phrases:
        parts = phrase.split()
        n = len(parts)
        if n == 0 or len(words) < n:
            continue
        for i in range(len(words) - n + 1):
            if any(occupied[i : i + n]):
                continue
            if words[i : i + n] == parts:
                if phrase == "support for" and i > 0 and words[i - 1] == "material":
                    continue
                for k in range(i, i + n):
                    occupied[k] = True
                hits.append(CueHit(i, i + n - 1, weight, phrase))
    return sorted(hits, key=lambda h: h.start_index)


def positive_cue_spans(
    tokens: list[Token], hits: list[CueHit], anchor: set[str]
) -> list[tuple[int, int]]:
    spans: list[tuple[int, int]] = []
    window_start = tokens[0].start
    episode_end = tokens[-1].end
    while window_start < episode_end:
        window_end = window_start + WINDOW_SECONDS
        indices = [
            i
            for i, t in enumerate(tokens)
            if t.end > window_start and t.start < window_end
        ]
        if len(indices) >= 3:
            first, last = indices[0], indices[-1]
            score = 0.0
            local: list[tuple[int, int]] = []
            for hit in hits:
                if hit.start_index >= first and hit.end_index <= last:
                    score += hit.weight
                    local.append((hit.start_index, hit.end_index))
            if score > 0 and anchor:
                content = {
                    tokens[i].word
                    for i in indices
                    if len(tokens[i].word) > 2 and tokens[i].word not in STOP_WORDS
                }
                if content:
                    overlap = len(content & anchor) / len(content)
                    drift = 1.0 - overlap
                    if drift > DRIFT_BOOST_THRESHOLD:
                        score += DRIFT_BOOST
            if score >= SCORE_THRESHOLD:
                spans.extend(local)
        window_start += WINDOW_STEP_SECONDS
    seen: set[str] = set()
    deduped: list[tuple[int, int]] = []
    for start, end in sorted(spans):
        key = f"{start}-{end}"
        if key in seen:
            continue
        seen.add(key)
        deduped.append((start, end))
    return deduped


def merge_token_spans(spans: list[tuple[int, int]], tokens: list[Token], gap: float) -> list[tuple[int, int]]:
    if not spans:
        return []
    current = spans[0]
    merged: list[tuple[int, int]] = []
    for start, end in spans[1:]:
        gap_seconds = tokens[start].start - tokens[current[1]].end
        if gap_seconds > gap:
            merged.append(current)
            current = (start, end)
        else:
            current = (current[0], max(current[1], end))
    merged.append(current)
    return merged


def expand_span(
    start_index: int,
    end_index: int,
    tokens: list[Token],
    hits: list[CueHit],
) -> Segment:
    lead_in = max(0, start_index - LEAD_IN_TOKENS)
    cue_end = tokens[end_index].end
    is_sponsor = any(
        h.weight >= SPONSOR_WEIGHT
        and h.start_index >= start_index
        and h.end_index <= end_index
        for h in hits
    )
    trail_limit = SPONSOR_TRAIL_SECONDS if is_sponsor else TRAIL_SECONDS
    hi = end_index
    while hi < len(tokens) - 1:
        nxt = tokens[hi + 1]
        if nxt.start - tokens[hi].end > MAX_TOKEN_GAP_SECONDS:
            break
        if nxt.end - cue_end > trail_limit:
            break
        if nxt.word == "back":
            break
        hi += 1
    return Segment(tokens[lead_in].start, tokens[hi].end)


def merge_time_ranges(ranges: list[Segment], gap: float) -> list[Segment]:
    if not ranges:
        return []
    sorted_ranges = sorted(ranges, key=lambda r: r.start)
    merged: list[Segment] = []
    current = sorted_ranges[0]
    for r in sorted_ranges[1:]:
        if r.start > current.end + gap:
            merged.append(current)
            current = r
        else:
            current = Segment(current.start, max(current.end, r.end))
    merged.append(current)
    return merged


def timed_words_to_tokens(words: list) -> list[Token]:
    """Convert PodWash TimedWord dicts/objects to normalized Token stream."""
    tokens: list[Token] = []
    for w in words:
        raw = w["word"] if isinstance(w, dict) else w.word
        start = w["start"] if isinstance(w, dict) else w.start
        end = w["end"] if isinstance(w, dict) else w.end
        n = normalize(raw)
        if n:
            tokens.append(Token(n, float(start), float(end)))
    return tokens


def segment(tokens: list[Token]) -> tuple[list[Segment], list[CueHit], set[str]]:
    if len(tokens) < 3:
        return [], [], set()
    anchor = on_topic_anchor(tokens)
    hits = find_cue_hits(tokens)
    if not hits:
        return [], hits, anchor
    positive = positive_cue_spans(tokens, hits, anchor)
    if not positive:
        return [], hits, anchor
    merged_hits = merge_token_spans(positive, tokens, MERGE_GAP_SECONDS)
    expanded = [expand_span(s, e, tokens, hits) for s, e in merged_hits]
    merged = merge_time_ranges(expanded, MERGE_GAP_SECONDS)
    return [
        s for s in merged if s.end - s.start >= MIN_DURATION_SECONDS
    ], hits, anchor


def fmt_time(seconds: float) -> str:
    m, s = divmod(int(seconds), 60)
    h, m = divmod(m, 60)
    if h:
        return f"{h}:{m:02d}:{s:02d}"
    return f"{m}:{s:02d}"


def excerpt(tokens: list[Token], start: float, end: float, width: int = 120) -> str:
    words = [t.word for t in tokens if t.end > start and t.start < end]
    text = " ".join(words)
    return text[:width] + ("…" if len(text) > width else "")


def load_text(path: str | None, url: str | None) -> str:
    if url:
        with urllib.request.urlopen(url, timeout=60) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
        # Strip HTML-ish noise from TAL transcript pages.
        raw = re.sub(r"<[^>]+>", " ", raw)
        raw = re.sub(r"\s+", " ", raw)
        return raw
    if path:
        with open(path, encoding="utf-8") as f:
            return f.read()
    raise SystemExit("Provide TRANSCRIPT.txt or --url")


def main() -> None:
    parser = argparse.ArgumentParser(description="Probe PodWash ad/unrelated segmentation")
    parser.add_argument("transcript", nargs="?", help="Plain-text transcript file")
    parser.add_argument("--url", help="Fetch transcript from URL")
    parser.add_argument(
        "--duration",
        type=float,
        default=4470.0,
        help="Synthetic episode duration in seconds (default: TAL 891 length)",
    )
    args = parser.parse_args()

    text = load_text(args.transcript, args.url)
    tokens = text_to_tokens(text, args.duration)
    segments, hits, anchor = segment(tokens)

    print(f"Tokens: {len(tokens)}  Duration: {args.duration:.0f}s  Approach: heuristic-cue-v3")
    print(f"On-topic anchor ({len(anchor)} words): {', '.join(sorted(list(anchor))[:20])}…")
    print(f"\nCue phrase hits ({len(hits)}):")
    for hit in hits:
        t0, t1 = tokens[hit.start_index].start, tokens[hit.end_index].end
        print(f"  [{fmt_time(t0)}–{fmt_time(t1)}] {hit.phrase!r} (w={hit.weight})")

    print(f"\nPositive segments after window scoring (≥{MIN_DURATION_SECONDS}s): {len(segments)}")
    for i, seg in enumerate(segments, 1):
        pct = 100.0 * seg.start / args.duration
        print(
            f"  {i}. {fmt_time(seg.start)}–{fmt_time(seg.end)} ({seg.end - seg.start:.1f}s, ~{pct:.0f}% in)"
        )
        print(f"     …{excerpt(tokens, seg.start, seg.end)}")

    if not segments:
        print(
            "\nNo segments passed the score threshold. Common reasons on real episodes:\n"
            "  • Cue phrases present but isolated (score < 2.0 without topic-drift boost)\n"
            "  • Whisper transcript wording differs from polished web transcript\n"
            "  • TAL mid-roll breaks use station IDs, not 'sponsored by …' language"
        )


if __name__ == "__main__":
    main()
