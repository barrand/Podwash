#!/usr/bin/env python3
"""Render a readable full-episode Jev-vs-golden transcript review."""

from __future__ import annotations

import argparse
import html
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_REPORT = ROOT / "tmp" / "ad-eval" / "jev-full-v6" / "report.json"
DEFAULT_GOLDENS = ROOT / "eval" / "ad-detection" / "goldens"
DEFAULT_WORKDIR = ROOT / "tmp" / "ad-eval"


def timecode(value: float) -> str:
    total = int(value)
    hours, rem = divmod(total, 3600)
    minutes, seconds = divmod(rem, 60)
    return f"{hours}:{minutes:02d}:{seconds:02d}" if hours else f"{minutes}:{seconds:02d}"


def interval_overlap(start: float, end: float, other_start: float, other_end: float) -> bool:
    return start < other_end and end > other_start


def probability(value: object) -> str:
    return f"{float(value):.2f}"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--slug", default="version-history")
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    parser.add_argument("--goldens", type=Path, default=DEFAULT_GOLDENS)
    parser.add_argument("--workdir", type=Path, default=DEFAULT_WORKDIR)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    report = json.loads(args.report.read_text(encoding="utf-8"))
    episode = next(item for item in report["episodes"] if item["slug"] == args.slug)
    observations = [item for item in report["observations"] if item["slug"] == args.slug]
    observations.sort(key=lambda item: item["sentence"])
    words = json.loads((args.workdir / args.slug / "transcript.json").read_text(encoding="utf-8"))
    golden_data = json.loads((args.goldens / f"{args.slug}.json").read_text(encoding="utf-8"))
    golden = golden_data.get("spans", [])

    def jev_removes(observation: dict) -> bool:
        return (
            float(observation["paidAdProbability"]) >= 0.50
            or float(observation["bumperOrCrossPromoProbability"]) >= 0.90
        )

    jev_intervals = [(float(item["start"]), float(item["end"])) for item in observations if jev_removes(item)]
    golden_intervals = [(float(item["start"]), float(item["end"])) for item in golden]

    def current_golden_fraction(observation: dict) -> float:
        start, end = float(observation["start"]), float(observation["end"])
        duration = max(end - start, 1e-9)
        overlap = sum(max(0.0, min(end, right) - max(start, left)) for left, right in golden_intervals)
        return min(1.0, overlap / duration)

    blocks: list[dict] = []
    current: dict | None = None
    for item in observations:
        jev = jev_removes(item)
        golden_fraction = current_golden_fraction(item)
        kind = "jev-only" if jev and golden_fraction < 1 else "golden-only" if not jev and golden_fraction > 0 else None
        if kind is None:
            if current:
                blocks.append(current)
                current = None
            continue
        if current is None or current["kind"] != kind:
            if current:
                blocks.append(current)
            current = {"kind": kind, "start": item["start"], "end": item["end"], "first": item["sentence"], "last": item["sentence"]}
        else:
            current["end"] = item["end"]
            current["last"] = item["sentence"]
    if current:
        blocks.append(current)

    block_by_sentence: dict[int, int] = {}
    for index, block in enumerate(blocks, 1):
        for sentence in range(block["first"], block["last"] + 1):
            block_by_sentence[sentence] = index

    sentence_html: list[str] = []
    word_index = 0
    minute = None
    for observation in observations:
        start, end = float(observation["start"]), float(observation["end"])
        current_minute = int(start // 60)
        if current_minute != minute:
            minute = current_minute
            sentence_html.append(f'<div class="minute">{html.escape(timecode(start))}</div>')

        jev = jev_removes(observation)
        golden_fraction = current_golden_fraction(observation)
        block_number = block_by_sentence.get(int(observation["sentence"]))
        classes = ["sentence"]
        if block_number:
            classes.append("disagreement")
        title = (
            f"Sentence {observation['sentence']} · {timecode(start)}–{timecode(end)} · "
            f"Jev role: {observation['selectedRole']} · "
            f"paid {probability(observation['paidAdProbability'])} · "
            f"promo {probability(observation['bumperOrCrossPromoProbability'])} · "
            f"golden overlap {golden_fraction:.0%}"
        )
        content: list[str] = []
        while word_index < len(words) and float(words[word_index]["end"]) <= start:
            word_index += 1
        while word_index < len(words) and float(words[word_index]["start"]) < end:
            word = words[word_index]
            word_start, word_end = float(word["start"]), float(word["end"])
            in_golden = any(interval_overlap(word_start, word_end, left, right) for left, right in golden_intervals)
            in_jev = any(interval_overlap(word_start, word_end, left, right) for left, right in jev_intervals)
            word_classes = []
            if in_golden:
                word_classes.append("golden")
            if in_jev:
                word_classes.append("jev")
            token = html.escape(str(word.get("word", "")))
            content.append(f'<span class="{" ".join(word_classes)}">{token}</span>')
            word_index += 1
        label = ""
        if block_number:
            label = f'<sup class="delta">Δ{block_number}</sup>'
        sentence_html.append(
            f'<span id="sentence-{observation["sentence"]}" class="{" ".join(classes)}" '
            f'title="{html.escape(title)}">{label}{" ".join(content)} </span>'
        )

    nav = "".join(
        f'<li><a href="#delta-{index}">Δ{index} {timecode(block["start"])}–{timecode(block["end"])}</a> '
        f'<span>{block["kind"]}</span></li>'
        for index, block in enumerate(blocks, 1)
    )
    true_positive = false_positive = false_negative = true_negative = 0.0
    for observation in observations:
        duration = float(observation["end"]) - float(observation["start"])
        golden_seconds = duration * current_golden_fraction(observation)
        content_seconds = duration - golden_seconds
        if jev_removes(observation):
            true_positive += golden_seconds
            false_positive += content_seconds
        else:
            false_negative += golden_seconds
            true_negative += content_seconds
    precision = true_positive / (true_positive + false_positive) if true_positive + false_positive else 1.0
    recall = true_positive / (true_positive + false_negative) if true_positive + false_negative else 1.0
    output = args.output or (args.report.parent / f"{args.slug}-FULL-REVIEW.html")
    page = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{html.escape(args.slug)} — Jev full review</title>
<style>
:root {{ color-scheme: dark; --bg:#111318; --panel:#1b1e26; --text:#e8eaf0; --muted:#9ca3b4; --gold:#f0c84b; --red:#ff637d; --line:#303542; }}
* {{ box-sizing:border-box }} body {{ margin:0; background:var(--bg); color:var(--text); font:18px/1.8 system-ui,-apple-system,Segoe UI,sans-serif; }}
header {{ position:sticky; top:0; z-index:3; background:#151821ee; backdrop-filter:blur(10px); border-bottom:1px solid var(--line); padding:18px max(20px,calc((100vw - 980px)/2)); }}
h1 {{ margin:0 0 4px; font-size:1.35rem }} h2 {{ font-size:1.1rem; margin-top:2.6em; color:#fff }}
.meta {{ color:var(--muted); font-size:.84rem; line-height:1.5 }} .legend {{ display:flex; gap:18px; flex-wrap:wrap; margin-top:10px }}
.swatch {{ padding:0 6px; border-radius:4px }} .golden {{ background:#c99b2d66; border-bottom:1px solid var(--gold); }}
.jev {{ text-decoration-line:underline; text-decoration-style:wavy; text-decoration-color:var(--red); text-decoration-thickness:2px; text-underline-offset:4px; }}
.golden.jev {{ background:#c99b2d66; }} .sentence {{ cursor:help; }} .sentence.disagreement {{ background:#ffffff08; border-radius:4px; }}
.delta {{ color:#ffcf5a; font-size:.7em; vertical-align:super; margin-right:3px }} .minute {{ color:#7f8799; border-top:1px solid var(--line); margin:34px 0 8px; padding-top:5px; font:700 .76rem/1.2 ui-monospace,monospace; }}
main {{ max-width:980px; margin:auto; padding:0 24px 80px; }} nav {{ margin:12px 0 0; max-height:160px; overflow:auto; }} nav ul {{ columns:3; margin:0; padding-left:20px; }} nav a {{ color:#a9c8ff; text-decoration:none }} nav span {{ color:var(--muted); font-size:.75em; }}
.delta-card {{ scroll-margin-top:160px; margin:28px 0 10px; padding:12px 16px; background:var(--panel); border:1px solid var(--line); border-left:3px solid var(--red); border-radius:6px; }}
.delta-card h3 {{ margin:0; font-size:.95rem }} .delta-card p {{ margin:2px 0; color:var(--muted); font-size:.84rem }} .transcript {{ white-space:normal; }}
</style></head><body>
<header><h1>{html.escape(args.slug)} — full transcript review</h1>
<div class="meta">Jev v6 rescored against the current golden · precision {precision:.1%} · recall {recall:.1%} · {len(blocks)} disagreement regions</div>
<div class="legend"><span><span class="swatch golden">yellow</span> current golden says remove</span><span><span class="swatch jev">red underline</span> Jev says remove</span><span><span class="swatch golden jev">both</span> both agree</span></div>
<div class="meta">Jev operates at sentence level, so an underline may cover editorial words after a golden span ends. Hover a sentence for probabilities and timing.</div>
<nav><ul>{nav}</ul></nav></header>
<main>
{"".join(f'<div id="delta-{i}" class="delta-card"><h3>Δ{i} · {timecode(b["start"])}–{timecode(b["end"])} · {b["kind"]}</h3><p>Jump to the highlighted Δ{i} marker below. This is a visual comparison only; no verdict is implied.</p></div>' for i,b in enumerate(blocks,1))}
<div class="transcript">{"".join(sentence_html)}</div>
</main></body></html>"""
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(page, encoding="utf-8")
    print(output)


if __name__ == "__main__":
    main()
