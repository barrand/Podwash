#!/usr/bin/env python3
"""LLM / heuristic first-pass ad span proposals for ad-eval episodes."""

from __future__ import annotations

import argparse
import json
import os
import re
import urllib.request
from pathlib import Path
from typing import Any

from ad_eval_common import (
    DEFAULT_WORKDIR,
    SHOWS,
    fmt_time,
    load_meta,
    parse_time_to_seconds,
    show_dir,
)

RUBRIC = """
Mark these as ad-related spans:
- host-read midroll sponsor reads (sponsored by, use code, promo, discount)
- dynamic ad insertion / network ads
- NPR/public-radio underwriting reads ("this message comes from", "support for this … comes from", delivered to public radio, PRX)
- membership / Life Partner / Patreon-style pitches with explicit signup URLs or calls to join

Do NOT mark:
- break teasers ("when we come back", "coming up after the break", "when our program continues") — those announce story structure, not ads
- story content that mentions sponsors in passing
- legal phrases like "material support for terrorists"
- credits/thanks that are not promotional
"""

# Patterns for rule-based first pass (used when no API key; also seeds LLM).
SPAN_PATTERNS: list[tuple[str, str, re.Pattern[str]]] = [
    (
        "midroll",
        "high",
        re.compile(
            r"(?is)(.{0,120}(?:this episode is )?sponsored by.{0,400}|"
            r".{0,80}our friends at.{0,300}|"
            r".{0,80}use code.{0,200}|"
            r".{0,80}brought to you by.{0,300}|"
            r".{0,120}thank you to today(?:'|’)?s sponsors.{0,400})"
        ),
    ),
    (
        "underwriting",
        "high",
        re.compile(
            r"(?is).{0,40}(?:this message comes from|"
            r"support for this (?:american life|podcast) comes from|"
            r"delivered to public radio|support comes from|"
            r"funding for|underwriting from).{0,400}"
        ),
    ),
    (
        "membership",
        "medium",
        re.compile(
            r"(?is).{0,120}(?:become a (?:life )?partner|support the show|"
            r"join at .{0,40}(?:org|fm)|life partners|patreon\s*\.com|"
            r"ad free version of the show|thank you to today(?:'|’)?s sponsors).{0,350}"
        ),
    ),
    (
        "promo",
        "medium",
        re.compile(
            r"(?is).{0,80}(?:check out|link in the (?:show )?notes|"
            r"promo code|discount code|visit .{0,30}\.com|"
            r"apply in minutes at|play .{0,30}\.com).{0,250}"
        ),
    ),
    (
        "midroll",
        "high",
        re.compile(
            r"(?is)^.{0,800}(?:on deck|spinquest|built to back small businesses).{0,600}"
        ),
    ),
]

HARD_NEGATIVE_PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    (
        "legal material support phrase (not an ad)",
        re.compile(r"material support for", re.I),
    ),
]


def load_transcript(workdir: Path, slug: str) -> tuple[list[dict], str]:
    d = show_dir(workdir, slug)
    words = json.loads((d / "transcript.json").read_text(encoding="utf-8"))
    text = (d / "transcript.txt").read_text(encoding="utf-8")
    return words, text


def words_in_range(words: list[dict], start: float, end: float) -> str:
    picked = [w["word"] for w in words if w["end"] > start and w["start"] < end]
    return " ".join(picked)


def locate_excerpt(words: list[dict], excerpt: str) -> tuple[float, float] | None:
    tokens = [w["word"].lower().strip(".,!?;:\"'()[]") for w in words]
    needle = [
        t.lower().strip(".,!?;:\"'()[]")
        for t in excerpt.split()
        if t.strip()
    ]
    if len(needle) < 3:
        return None
    # Try progressively shorter prefixes for Whisper/web mismatches.
    for length in (min(12, len(needle)), min(8, len(needle)), min(5, len(needle))):
        sub = needle[:length]
        for i in range(len(tokens) - len(sub) + 1):
            if tokens[i : i + len(sub)] == sub:
                start = words[i]["start"]
                end = words[min(i + len(sub) - 1, len(words) - 1)]["end"]
                return start, end
    return None


def expand_bounds(words: list[dict], start: float, end: float, pad: float = 2.0) -> tuple[float, float]:
    return max(0.0, start - pad), min(words[-1]["end"], end + pad)


def estimate_span_from_char(
    words: list[dict], text: str, char_start: int, char_end: int
) -> tuple[float, float]:
    if not words:
        return 0.0, 0.0
    total_chars = max(len(text), 1)
    duration = words[-1]["end"]
    start = duration * (char_start / total_chars)
    end = duration * (char_end / total_chars)
    return max(0.0, start), min(duration, max(start + 5.0, end))


def rule_based_proposals(words: list[dict], text: str) -> list[dict[str, Any]]:
    proposals: list[dict[str, Any]] = []
    seen: set[tuple[int, int]] = set()

    for kind, confidence, pattern in SPAN_PATTERNS:
        for match in pattern.finditer(text):
            excerpt = re.sub(r"\s+", " ", match.group(0)).strip()
            if len(excerpt) < 20:
                continue
            if kind != "underwriting" and re.search(r"material support for", excerpt, re.I):
                continue
            if kind == "promo" and re.search(r"check out those episodes", excerpt, re.I):
                continue
            loc = locate_excerpt(words, excerpt[:120])
            if loc:
                start, end = expand_bounds(words, loc[0], loc[1], pad=3.0)
            else:
                start, end = estimate_span_from_char(
                    words, text, match.start(), match.end()
                )
                end = min(words[-1]["end"], start + max(15.0, end - start))
            key = (int(start), int(end))
            if key in seen:
                continue
            seen.add(key)
            proposals.append(
                {
                    "start": round(start, 3),
                    "end": round(end, 3),
                    "kind": kind,
                    "confidence": confidence,
                    "rationale": f"Rule match for {kind} cue phrases",
                    "excerpt": excerpt[:240],
                    "source": "rules",
                }
            )

    proposals.sort(key=lambda p: p["start"])
    return proposals


def call_openai(meta: dict, text: str, model: str) -> list[dict[str, Any]]:
    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        return []

    # Chunk very long transcripts
    max_chars = 100_000
    body_text = text if len(text) <= max_chars else text[:max_chars] + "\n…[truncated]"

    prompt = f"""You label podcast ad and break spans. Return JSON only: {{"spans":[{{"start_sec":0,"end_sec":0,"kind":"midroll|underwriting|station_break|membership|promo","confidence":"high|medium|low","rationale":"...","excerpt":"..."}}]}}

Show: {meta['showName']}
Show description: {meta.get('showDescription','')[:2000]}
Episode: {meta['episodeTitle']}
Episode description: {meta.get('episodeDescription','')[:2000]}

{RUBRIC}

Transcript:
{body_text}
"""

    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": "Return valid JSON only."},
            {"role": "user", "content": prompt},
        ],
        "temperature": 0.2,
    }
    req = urllib.request.Request(
        "https://api.openai.com/v1/chat/completions",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=180) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    content = data["choices"][0]["message"]["content"]
    m = re.search(r"\{.*\}", content, re.S)
    if not m:
        return []
    parsed = json.loads(m.group(0))
    out: list[dict[str, Any]] = []
    for span in parsed.get("spans", []):
        start = float(span.get("start_sec", span.get("start", 0)))
        end = float(span.get("end_sec", span.get("end", 0)))
        if end <= start:
            continue
        out.append(
            {
                "start": round(start, 3),
                "end": round(end, 3),
                "kind": span.get("kind", "midroll"),
                "confidence": span.get("confidence", "medium"),
                "rationale": span.get("rationale", "LLM proposal"),
                "excerpt": span.get("excerpt", "")[:240],
                "source": "openai",
            }
        )
    return out


def merge_proposals(rule: list[dict], llm: list[dict]) -> list[dict]:
    merged = rule + llm
    merged.sort(key=lambda p: (p["start"], p["end"]))
    deduped: list[dict] = []
    for p in merged:
        if any(
            abs(p["start"] - q["start"]) < 5 and abs(p["end"] - q["end"]) < 5
            for q in deduped
        ):
            continue
        deduped.append(p)
    return deduped


def hard_negatives(text: str) -> list[dict[str, str]]:
    hits: list[dict[str, str]] = []
    for why, pat in HARD_NEGATIVE_PATTERNS:
        for m in pat.finditer(text):
            start = max(0, m.start() - 40)
            end = min(len(text), m.end() + 40)
            hits.append({"why": why, "excerpt": text[start:end].strip()})
    return hits[:20]


def write_markup(
    out_dir: Path,
    meta: dict,
    proposals: list[dict],
    negatives: list[dict],
    words: list[dict],
) -> None:
    lines = [
        f"# {meta['showName']} — {meta['episodeTitle']}",
        "",
        f"Audio: `{meta.get('audioPath', 'audio')}`",
        "Transcript: `transcript.txt`",
        "",
        "## Proposed ad / break spans (review)",
        "",
    ]

    for i, p in enumerate(proposals, 1):
        lines.extend(
            [
                f"### Span {i} — {p['kind']} ({p.get('confidence', 'medium')})",
                f"**Time:** {fmt_time(p['start'])}–{fmt_time(p['end'])}",
                f"**Source:** {p.get('source', 'unknown')}",
                f"**Excerpt:** \"{p.get('excerpt', words_in_range(words, p['start'], p['end']))[:500]}\"",
                f"**Why proposed:** {p.get('rationale', '')}",
                "**Your review:** [ ] agree  [ ] disagree  [ ] edit",
                "",
            ]
        )

    if negatives:
        lines.append("## Hard negatives flagged")
        lines.append("")
        for n in negatives:
            lines.append(f"- {n['why']}: \"{n['excerpt'][:200]}\"")
        lines.append("")

    lines.append("## Annotated transcript (inline proposals)")
    lines.append("")
    lines.append("_See `transcript.md` for timestamped text. Proposed spans listed above._")
    lines.append("")

    (out_dir / "MARKUP.md").write_text("\n".join(lines), encoding="utf-8")


def label_show(workdir: Path, slug: str, use_llm: bool, model: str) -> None:
    meta = load_meta(workdir, slug).to_dict()
    words, text = load_transcript(workdir, slug)
    out_dir = show_dir(workdir, slug)

    rule = rule_based_proposals(words, text)
    llm: list[dict] = []
    if use_llm:
        llm = call_openai(meta, text, model)
        if llm:
            print(f"[{slug}] OpenAI proposed {len(llm)} spans")
        else:
            print(f"[{slug}] OpenAI unavailable; rules only")

    proposals = merge_proposals(rule, llm)
    negatives = hard_negatives(text)

    (out_dir / "llm_proposed.json").write_text(
        json.dumps({"spans": proposals, "hardNegatives": negatives}, indent=2)
        + "\n",
        encoding="utf-8",
    )
    write_markup(out_dir, meta, proposals, negatives, words)
    print(f"[{slug}] wrote MARKUP.md ({len(proposals)} spans)")


def main() -> None:
    parser = argparse.ArgumentParser(description="Propose ad spans for review")
    parser.add_argument("--workdir", type=Path, default=DEFAULT_WORKDIR)
    parser.add_argument("--show", action="append")
    parser.add_argument("--no-llm", action="store_true")
    parser.add_argument("--model", default="gpt-4o-mini")
    args = parser.parse_args()

    workdir = args.workdir.resolve()
    selected = SHOWS
    if args.show:
        wanted = set(args.show)
        selected = [(s, _) for s, _ in SHOWS if s in wanted]

    for slug, _ in selected:
        label_show(workdir, slug, use_llm=not args.no_llm, model=args.model)


if __name__ == "__main__":
    main()
