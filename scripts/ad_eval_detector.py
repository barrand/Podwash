#!/usr/bin/env python3
"""span-grow-v1: precision-first ad detection over TimedWord transcripts.

Phases:
  1. Anchor openers (high-precision templates)
  1b. Anchorless density windows (DAI cold opens)
  2. Grow while blocks stay ad-like
  3. Snap boundaries to silence gaps
  4. Merge nearby spans into pods
"""

from __future__ import annotations

import re
from dataclasses import dataclass

# Mirrors historical Swift heuristic-cue-v5 approach (span-grow).
# Production path is heuristic-cue-v6 via scripts/build_segmenter_cli.sh.
APPROACH_ID = "span-grow-v1"

BLOCK_SECONDS = 5.0
GROW_FORWARD_MAX_SECONDS = 120.0
GROW_BACKWARD_MAX_SECONDS = 20.0
GAP_SNAP_SECONDS = 1.0
GAP_SNAP_WINDOW = 4.0
MERGE_GAP_SECONDS = 4.0
MIN_DURATION_SECONDS = 5.0
ANCHORLESS_MIN_SECONDS = 12.0
PAD_INSIDE_GAP = 0.25
# After an opener, keep reading until a silence gap or post-closer stop.
MIN_ANCHOR_GROW_SECONDS = 8.0
STOP_GAP_SECONDS = 1.2
SOFT_STOP_GAP_SECONDS = 0.75
POST_CLOSER_GAP_SECONDS = 0.55

# Precision-first openers only — no weak single-word cues.
ANCHOR_PATTERNS: list[re.Pattern[str]] = [
    re.compile(r"this episode is sponsored by", re.I),
    re.compile(r"this message comes from", re.I),
    re.compile(r"support for (?:\w+\s+){0,6}comes from", re.I),
    re.compile(r"following message comes? from", re.I),
    re.compile(r"(?:segment\s+was\s+)?brought to you by", re.I),
    re.compile(r"this episode is brought to you by", re.I),
    re.compile(r"delivered to public radio", re.I),
    re.compile(r"equivalent to public radio", re.I),  # ASR mangling of "delivered"
    re.compile(r"become a life partner", re.I),
    re.compile(r"sign up for our plus feed", re.I),
    re.compile(r"thank you to today'?s? sponsors", re.I),
    re.compile(r"help support the show", re.I),
    re.compile(r"learn more at", re.I),
    re.compile(r"discover how at", re.I),
    re.compile(r"start building at", re.I),
    re.compile(r"apply (?:today )?at", re.I),
    re.compile(r"apply in minutes at", re.I),
    re.compile(r"built to back small businesses", re.I),
    re.compile(r"play spinquest", re.I),
]


@dataclass
class Segment:
    start: float
    end: float


@dataclass
class Token:
    word: str
    start: float
    end: float


def timed_words_to_tokens(words: list) -> list[Token]:
    tokens: list[Token] = []
    for w in words:
        raw = w["word"] if isinstance(w, dict) else w.word
        start = float(w["start"] if isinstance(w, dict) else w.start)
        end = float(w["end"] if isinstance(w, dict) else w.end)
        n = raw.strip()
        if n:
            tokens.append(Token(n, start, end))
    return tokens


def _joined_text(tokens: list[Token]) -> tuple[str, list[int]]:
    """Return lowercased joined text and char→token index map."""
    parts: list[str] = []
    char_to_tok: list[int] = []
    for i, t in enumerate(tokens):
        if parts:
            char_to_tok.append(i - 1)  # space attributed to previous
            parts.append(" ")
        start_len = sum(len(p) for p in parts)
        parts.append(t.word.lower())
        for _ in range(len(t.word)):
            char_to_tok.append(i)
    return "".join(parts), char_to_tok


_CLOSER_ONLY_PHRASES = (
    "learn more at",
    "discover how at",
    "start building at",
    "apply today at",
    "apply in minutes at",
)


def _anchor_text(tokens: list[Token], si: int, ei: int) -> str:
    return " ".join(t.word.lower() for t in tokens[si : ei + 1])


def _is_closer_only_anchor(text: str) -> bool:
    return any(p in text for p in _CLOSER_ONLY_PHRASES)


def find_anchors(tokens: list[Token]) -> list[tuple[int, int]]:
    """Return list of (start_token_index, end_token_index) for anchor hits."""
    if not tokens:
        return []
    text, char_to_tok = _joined_text(tokens)
    hits: list[tuple[int, int]] = []
    occupied: set[int] = set()
    for pat in ANCHOR_PATTERNS:
        for m in pat.finditer(text):
            si = char_to_tok[min(m.start(), len(char_to_tok) - 1)]
            ei = char_to_tok[min(m.end() - 1, len(char_to_tok) - 1)]
            if any(k in occupied for k in range(si, ei + 1)):
                continue
            for k in range(si, ei + 1):
                occupied.add(k)
            hits.append((si, ei))
    hits.sort(key=lambda x: x[0])

    # Drop closer-only seeds that sit inside an opener's forward window — they
    # otherwise grow backward through story and merge pods.
    filtered: list[tuple[int, int]] = []
    last_opener_start = -1e9
    for si, ei in hits:
        t = _anchor_text(tokens, si, ei)
        if _is_closer_only_anchor(t):
            if tokens[si].start - last_opener_start < 90.0:
                continue
        else:
            last_opener_start = tokens[si].start
        filtered.append((si, ei))
    return filtered


def _block_id(t: float) -> int:
    return int(t // BLOCK_SECONDS)


def block_features(tokens: list[Token]) -> dict[int, dict[str, float]]:
    buckets: dict[int, list[str]] = {}
    for t in tokens:
        buckets.setdefault(_block_id(t.start), []).append(t.word.lower())
    out: dict[int, dict[str, float]] = {}
    for bid, words in buckets.items():
        n = max(len(words), 1)
        text = " ".join(words)
        url = len(re.findall(r"\.com|\.org|\.edu|\.ai|slash|dot com", text))
        you = len(re.findall(r"\byou\b|\byour\b", text))
        cta = len(
            re.findall(
                r"\bvisit\b|\bgo to\b|\blearn more\b|\bcheck out\b|\bsign up\b|"
                r"\btry\b|\bbook\b|\bapply\b|\bplay\b|\bstart building\b|"
                r"\bclaim\b|\bdiscover\b",
                text,
            )
        )
        price = len(re.findall(r"\$|\bfree\b|\bpercent\b|%\b|\bdiscount\b|\bbucks\b", text))
        out[bid] = {
            "url": url / n * 100,
            "you": you / n * 100,
            "cta": cta / n * 100,
            "price": price / n * 100,
            "score": (url * 4.0 + cta * 3.0 + price * 2.0 + you * 0.5) / n * 100,
            "n": float(n),
        }
    return out


def is_ad_like(feat: dict[str, float], *, strict: bool = False) -> bool:
    """Block looks like ad copy."""
    if feat["url"] >= 1.0 or feat["cta"] >= 1.5:
        return True
    if feat["score"] >= (8.0 if strict else 4.0):
        return True
    if feat["you"] >= 5.0 and feat["score"] >= 3.0:
        return True
    return False


def silence_gaps(tokens: list[Token], min_gap: float = GAP_SNAP_SECONDS) -> list[tuple[float, float]]:
    """Return (gap_start_time, gap_end_time) for inter-word silences."""
    gaps: list[tuple[float, float]] = []
    for i in range(1, len(tokens)):
        gap = tokens[i].start - tokens[i - 1].end
        if gap >= min_gap:
            gaps.append((tokens[i - 1].end, tokens[i].start))
    return gaps


def snap_to_gap(
    t: float,
    gaps: list[tuple[float, float]],
    *,
    prefer: str,
    window: float = GAP_SNAP_WINDOW,
) -> float:
    """Snap time to nearest gap edge within window. prefer 'start' or 'end'."""
    best = t
    best_dist = window + 1
    for gs, ge in gaps:
        mid = (gs + ge) / 2
        # Prefer cutting inside the gap
        candidate = mid if prefer == "start" else mid
        if prefer == "start":
            candidate = min(ge - PAD_INSIDE_GAP, max(gs + PAD_INSIDE_GAP, mid))
            # For span start, snap to gap_end (first word after silence) or mid
            candidate = gs + PAD_INSIDE_GAP if ge - gs > 2 * PAD_INSIDE_GAP else mid
        else:
            candidate = ge - PAD_INSIDE_GAP if ge - gs > 2 * PAD_INSIDE_GAP else mid
            candidate = gs + (ge - gs) * 0.7  # toward end of gap before next speech
        dist = abs(candidate - t)
        # Also consider raw edges
        for edge in (gs + PAD_INSIDE_GAP, ge - PAD_INSIDE_GAP, mid):
            d = abs(edge - t)
            if d < best_dist and d <= window:
                best_dist = d
                best = edge
    return best


def has_closer(feat: dict[str, float] | None) -> bool:
    if not feat:
        return False
    return feat["url"] > 0 or feat["cta"] > 0


def _ends_sentence(word: str) -> bool:
    return word.rstrip().endswith((".", "?", "!"))



_AD_FORWARD_CUES = (
    ".com",
    ".org",
    ".edu",
    ".ai",
    "discount",
    "promo",
    "use code",
    "learn more",
    "sign up",
    "free shipping",
    "percent",
    "sponsor",
    "sponsored",
    "brought to you",
    "offer",
    "coupon",
    "subscribe",
    "visit",
    "apply",
)

_RESUME_STARTERS = frozenset(
    {
        "back",
        "anyway",
        "meanwhile",
        "okay",
        "ok",
        "alright",
        "now",
    }
)


def _bare_word(word: str) -> str:
    return "".join(ch for ch in word.lower() if ch.isalnum())


def forward_looks_like_ad(tokens: list[Token], start_idx: int, window: int = 14) -> bool:
    chunk = tokens[start_idx : start_idx + window]
    if not chunk:
        return False
    text = " ".join(t.word.lower() for t in chunk)
    return any(c in text for c in _AD_FORWARD_CUES)


def token_looks_like_url(word: str) -> bool:
    w = word.lower()
    return any(x in w for x in (".com", ".org", ".edu", ".ai")) or w == "slash"


def grow_from_anchor(
    tokens: list[Token],
    features: dict[int, dict[str, float]],
    start_idx: int,
    end_idx: int,
) -> Segment:
    """Grow through ad copy until silence gap or shortly after a URL closer."""
    hi = end_idx
    seen_closer = False
    closer_idx = end_idx
    anchor_text = " ".join(t.word.lower() for t in tokens[start_idx : end_idx + 1])
    is_closer_anchor = any(
        p in anchor_text
        for p in (
            "learn more at",
            "discover how at",
            "start building at",
            "apply in minutes",
            "apply today",
        )
    )
    while hi < len(tokens) - 1:
        nxt = hi + 1
        duration = tokens[nxt].end - tokens[start_idx].start
        if duration > GROW_FORWARD_MAX_SECONDS:
            break
        gap = tokens[nxt].start - tokens[hi].end
        feat = features.get(_block_id(tokens[nxt].start))

        if gap >= STOP_GAP_SECONDS and duration >= MIN_ANCHOR_GROW_SECONDS:
            break
        if (
            gap >= SOFT_STOP_GAP_SECONDS
            and duration >= MIN_ANCHOR_GROW_SECONDS
            and _ends_sentence(tokens[hi].word)
        ):
            next_feat = features.get(_block_id(tokens[nxt].start))
            resume = (
                next_feat is None
                or (
                    not is_ad_like(next_feat)
                    and not has_closer(next_feat)
                    and next_feat.get("you", 0) < 3.0
                )
            )
            if seen_closer or (resume and not is_closer_anchor):
                break
        if (
            gap >= SOFT_STOP_GAP_SECONDS
            and duration >= 40.0
            and _ends_sentence(tokens[hi].word)
        ):
            break
        # Content resume after a clear pause: next utterance starts like a
        # host handoff ("Back to…") and the lookahead window isn't ad copy.
        if (
            duration >= MIN_ANCHOR_GROW_SECONDS
            and _ends_sentence(tokens[hi].word)
            and gap >= SOFT_STOP_GAP_SECONDS
            and not is_closer_anchor
            and not seen_closer
            and _bare_word(tokens[nxt].word) in _RESUME_STARTERS
            and not forward_looks_like_ad(tokens, nxt)
        ):
            break

        if token_looks_like_url(tokens[nxt].word) and tokens[nxt].start >= tokens[end_idx].end:
            seen_closer = True
            closer_idx = nxt
            hi = nxt
            continue

        if seen_closer:
            if gap >= POST_CLOSER_GAP_SECONDS:
                break
            if feat is None or not (
                is_ad_like(feat) or token_looks_like_url(tokens[nxt].word)
            ):
                break
            if tokens[nxt].end - tokens[closer_idx].end > 10.0:
                break
            hi = nxt
            continue

        hi = nxt

    lo = start_idx
    back_limit = 55.0 if is_closer_anchor else GROW_BACKWARD_MAX_SECONDS
    min_start = max(0.0, tokens[start_idx].start - back_limit)
    while lo > 0:
        prev = lo - 1
        if tokens[prev].start < min_start:
            break
        gap = tokens[lo].start - tokens[prev].end
        if gap >= STOP_GAP_SECONDS:
            break
        feat = features.get(_block_id(tokens[prev].start))
        if is_closer_anchor:
            if feat is None:
                break
            if is_ad_like(feat) or feat.get("you", 0) >= 3.5 or has_closer(feat):
                lo = prev
                continue
            # Dense continuous speech inside a DAI / native read.
            # Use soft-stop gap (not 0.35) so sentence pauses inside the
            # read don't abort walkback; story handoffs usually leave ≥0.75s.
            if feat.get("n", 0) >= 8 and gap < SOFT_STOP_GAP_SECONDS:
                lo = prev
                continue
            break
        if gap >= SOFT_STOP_GAP_SECONDS and _ends_sentence(tokens[prev].word):
            break
        if feat is None or not (is_ad_like(feat) or has_closer(feat)):
            break
        lo = prev
    return Segment(tokens[lo].start, tokens[hi].end)



def density_windows(tokens: list[Token], features: dict[int, dict[str, float]]) -> list[Segment]:
    """Anchorless path: URL-bearing runs (DAI cold opens / closes)."""
    if not features:
        return []
    bids = sorted(features.keys())
    spans: list[Segment] = []
    i = 0
    while i < len(bids):
        f = features[bids[i]]
        if f["url"] < 1.5:
            i += 1
            continue
        j = i
        # Expand through adjacent ad-like / URL blocks only (no long story bridges).
        while j + 1 < len(bids) and bids[j + 1] == bids[j] + 1:
            nf = features[bids[j + 1]]
            if is_ad_like(nf) or has_closer(nf) or nf["url"] > 0:
                j += 1
            else:
                break
        back = i
        while back > 0 and bids[back - 1] == bids[back] - 1:
            pf = features[bids[back - 1]]
            if is_ad_like(pf) or pf["you"] >= 5.0 or has_closer(pf):
                back -= 1
            else:
                break
        while (bids[i] - bids[back]) * BLOCK_SECONDS > 60:
            back += 1
        start = bids[back] * BLOCK_SECONDS
        end = (bids[j] + 1) * BLOCK_SECONDS
        # Hard cap — density must not invent multi-minute story spans.
        if end - start > 90:
            end = start + 90
        if end - start >= ANCHORLESS_MIN_SECONDS:
            tok_start = next((t.start for t in tokens if t.end > start), start)
            tok_end = next((t.end for t in reversed(tokens) if t.start < end), end)
            spans.append(Segment(tok_start, tok_end))
        i = j + 1
    return spans


def merge_segments(segs: list[Segment], gap: float = MERGE_GAP_SECONDS) -> list[Segment]:
    if not segs:
        return []
    ordered = sorted(segs, key=lambda s: s.start)
    merged = [Segment(ordered[0].start, ordered[0].end)]
    for s in ordered[1:]:
        if s.start <= merged[-1].end + gap:
            merged[-1].end = max(merged[-1].end, s.end)
        else:
            merged.append(Segment(s.start, s.end))
    return merged


def apply_gap_snapping(segs: list[Segment], gaps: list[tuple[float, float]]) -> list[Segment]:
    out: list[Segment] = []
    for s in segs:
        start = snap_to_gap(s.start, gaps, prefer="start")
        end = snap_to_gap(s.end, gaps, prefer="end")
        if end <= start:
            start, end = s.start, s.end
        if abs(start - s.start) > GAP_SNAP_WINDOW:
            start = s.start
        if abs(end - s.end) > GAP_SNAP_WINDOW:
            end = s.end
        out.append(Segment(start, end))
    return out


def segment(tokens: list[Token]) -> list[Segment]:
    if len(tokens) < 3:
        return []

    features = block_features(tokens)
    anchors = find_anchors(tokens)
    grown: list[Segment] = []
    for si, ei in anchors:
        grown.append(grow_from_anchor(tokens, features, si, ei))

    # Anchorless density: open/close always; mid-episode only near anchors
    # (extends short "brought to you by" grows — avoids story URL FPs).
    episode_end = tokens[-1].end
    dens = []
    for s in density_windows(tokens, features):
        near_open_close = s.start < 180.0 or s.start > episode_end - 180.0
        near_anchor = any(
            abs(s.start - g.start) < 30
            or abs(s.end - g.end) < 30
            or (s.start <= g.end + 5 and s.end >= g.start - 5)
            for g in grown
        )
        if near_open_close or near_anchor:
            dens.append(s)
    grown.extend(dens)

    gaps = silence_gaps(tokens)
    snapped = apply_gap_snapping(grown, gaps)
    merged = merge_segments(snapped)
    return [s for s in merged if s.end - s.start >= MIN_DURATION_SECONDS]


def segment_timed_words(words: list) -> list[Segment]:
    return segment(timed_words_to_tokens(words))


def trace_segment(words: list) -> list[Segment]:
    """Log anchors + grown ranges for offline root-cause."""
    tokens = timed_words_to_tokens(words)
    features = block_features(tokens)
    anchors = find_anchors(tokens)
    print(f"anchors={len(anchors)}")
    for si, ei in anchors:
        text = " ".join(t.word for t in tokens[si : ei + 1])
        grown = grow_from_anchor(tokens, features, si, ei)
        print(f"  anchor[{si}:{ei}] {text!r} -> [{grown.start:.2f},{grown.end:.2f}]")
    segs = segment(tokens)
    print(f"segments={len(segs)}")
    for s in segs:
        print(f"  [{s.start:.2f},{s.end:.2f}]")
    return segs


if __name__ == "__main__":
    import argparse
    import json
    from pathlib import Path as P
    ap = argparse.ArgumentParser()
    ap.add_argument("transcript_json")
    ap.add_argument("--trace", action="store_true")
    args = ap.parse_args()
    words = json.loads(P(args.transcript_json).read_text())
    if args.trace:
        trace_segment(words)
    else:
        for s in segment_timed_words(words):
            print(f"{s.start:.3f} {s.end:.3f}")
