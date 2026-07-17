#!/usr/bin/env python3
"""Render full-episode HTML transcripts with yellow ad highlights.

Default detector: topic-llm-v1 via build/labeler-cli (falls back to heuristic if
Apple Intelligence is unavailable).
"""

from __future__ import annotations

import argparse
import html
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CLI = ROOT / "build" / "segmenter-cli"
DEFAULT_WORKDIR = ROOT / "tmp" / "ad-eval"


def fmt_time(t: float) -> str:
    m, s = divmod(int(t), 60)
    h, m = divmod(m, 60)
    if h:
        return f"{h}:{m:02d}:{s:02d}"
    return f"{m}:{s:02d}"


def load_segments(path: Path) -> list[dict]:
    if not path.exists():
        return []
    data = json.loads(path.read_text(encoding="utf-8"))
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        return data.get("segments") or data.get("spans") or []
    return []


def in_any(t: float, spans: list[dict]) -> bool:
    return any(float(s["start"]) <= t < float(s["end"]) for s in spans)


def run_segmenter(cli: Path, transcript: Path) -> list[dict]:
    out = subprocess.check_output([str(cli), str(transcript)], text=True)
    data = json.loads(out)
    return data.get("segments") or []


def render_html(
    *,
    title: str,
    slug: str,
    words: list[dict],
    predicted: list[dict],
    golden: list[dict],
    approach: str,
) -> str:
    legend = [
        '<span class="ad">yellow</span> = detected ad',
    ]
    if golden:
        legend.append(
            '<span class="fn">pink underline</span> = golden ad missed by detector (FN)'
        )
        legend.append("plain text = treated as content")

    pods = "".join(
        f'<li><a href="#t{int(s["start"])}">{fmt_time(s["start"])}–{fmt_time(s["end"])}</a></li>'
        for s in predicted
    )
    if not pods:
        pods = "<li><em>no ad segments detected</em></li>"

    body_parts: list[str] = []
    prev_ad = False
    prev_fn = False
    last_minute = -1

    def close_mark() -> None:
        nonlocal prev_ad, prev_fn
        if prev_ad or prev_fn:
            body_parts.append("</span>")
        prev_ad = False
        prev_fn = False

    for w in words:
        start = float(w["start"])
        minute = int(start) // 60
        if minute != last_minute:
            close_mark()
            if body_parts and not body_parts[-1].endswith("\n"):
                body_parts.append("\n")
            body_parts.append(
                f'<div class="ts" id="t{int(start)}">[[{fmt_time(start)}]]</div>\n'
            )
            last_minute = minute

        is_ad = in_any(start, predicted)
        is_fn = (not is_ad) and in_any(start, golden)
        classes: list[str] = []
        if is_ad:
            classes.append("ad")
        if is_fn:
            classes.append("fn")

        want_ad = is_ad
        want_fn = is_fn
        if want_ad != prev_ad or want_fn != prev_fn:
            close_mark()
            if classes:
                body_parts.append(f'<span class="{" ".join(classes)}">')
                prev_ad = want_ad
                prev_fn = want_fn

        token = html.escape(str(w["word"]))
        body_parts.append(token + " ")

    close_mark()

    ad_sec = sum(float(s["end"]) - float(s["start"]) for s in predicted)
    dur = float(words[-1]["end"]) if words else 0.0
    ad_pct = (100.0 * ad_sec / dur) if dur else 0.0

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>{html.escape(title)} — ad review</title>
<style>
  :root {{
    --bg: #f7f6f2;
    --text: #1a1a1a;
    --muted: #666;
    --ad: #ffe566;
    --fn: #ffb3c1;
  }}
  body {{
    margin: 0;
    font: 17px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    color: var(--text);
    background: var(--bg);
  }}
  header {{
    position: sticky; top: 0; z-index: 2;
    background: rgba(247,246,242,0.96);
    border-bottom: 1px solid #ddd;
    padding: 12px 20px;
    backdrop-filter: blur(6px);
  }}
  h1 {{ font-size: 1.15rem; margin: 0 0 6px; }}
  .meta {{ color: var(--muted); font-size: 0.9rem; }}
  .legend span {{ padding: 0 4px; border-radius: 3px; }}
  .ad {{ background: var(--ad); }}
  .fn {{
    background: transparent;
    box-shadow: inset 0 -3px 0 var(--fn);
  }}
  .ad.fn {{ background: var(--ad); box-shadow: none; }}
  main {{
    max-width: 52rem;
    margin: 0 auto;
    padding: 20px;
    white-space: pre-wrap;
  }}
  .ts {{
    color: var(--muted);
    font-size: 0.8rem;
    font-variant-numeric: tabular-nums;
    margin: 1.1em 0 0.25em;
  }}
  nav ul {{ margin: 8px 0 0; padding-left: 1.2em; columns: 2; }}
  nav a {{ color: #0645ad; }}
</style>
</head>
<body>
<header>
  <h1>{html.escape(title)}</h1>
  <div class="meta">slug: {html.escape(slug)} · detector: {html.escape(approach)} ·
    {len(predicted)} predicted pod(s) · {ad_sec:.0f}s ad ({ad_pct:.1f}% of episode)
    {f' · {len(golden)} golden span(s)' if golden else ''}</div>
  <div class="legend meta">{" · ".join(legend)}</div>
  <nav><ul>{pods}</ul></nav>
</header>
<main>{"".join(body_parts)}</main>
</body>
</html>
"""


def load_golden_for_review(path: Path) -> tuple[list[dict], str | None]:
    """Return (spans, skip_reason). Diff-label goldens are too noisy for FN paint."""
    if not path.exists():
        return [], None
    data = json.loads(path.read_text(encoding="utf-8"))
    if isinstance(data, list):
        return data, None
    if isinstance(data, dict):
        source = str(data.get("source") or "")
        spans = data.get("segments") or data.get("spans") or []
        if "diff" in source.lower():
            return [], f"skipped FN overlay (noisy {source})"
        return spans, None
    return [], None


def run_labeler(cli: Path, transcript: Path, meta: Path | None) -> tuple[list[dict], str, bool]:
    cmd = [str(cli), str(transcript)]
    if meta and meta.exists():
        cmd.append(str(meta))
    proc = subprocess.run(cmd, text=True, capture_output=True, check=True)
    if proc.stderr.strip():
        print(proc.stderr.strip(), file=sys.stderr)
    text = proc.stdout.strip()
    brace = text.find("{")
    if brace > 0:
        text = text[brace:]
    data = json.loads(text)
    return data.get("segments") or [], str(data.get("approach") or "topic-llm-v1"), bool(data.get("available"))


def process_show(
    show_dir: Path,
    cli: Path,
    *,
    write_segments: bool = True,
    detector: str = "labeler",
) -> Path | None:
    transcript = show_dir / "transcript.json"
    if not transcript.exists():
        return None

    meta_path = show_dir / "meta.json"
    title = show_dir.name
    if meta_path.exists():
        meta = json.loads(meta_path.read_text(encoding="utf-8"))
        title = meta.get("title") or meta.get("episodeTitle") or title

    words = json.loads(transcript.read_text(encoding="utf-8"))
    if detector == "labeler":
        predicted, approach, available = run_labeler(cli, transcript, meta_path if meta_path.exists() else None)
        if not available:
            approach = f"{approach} (AI unavailable — heuristic fallback)"
        out_name = "topic-llm-v1.json"
    else:
        predicted = run_segmenter(cli, transcript)
        approach = "heuristic-cue-v6.1"
        out_name = "swift-cli-v6.1.json"

    if write_segments:
        (show_dir / out_name).write_text(
            json.dumps({"approach": approach, "segments": predicted}, indent=2) + "\n",
            encoding="utf-8",
        )

    golden, skip = load_golden_for_review(show_dir / "golden.json")
    out = show_dir / "REVIEW.html"
    page = render_html(
        title=title,
        slug=show_dir.name,
        words=words,
        predicted=predicted,
        golden=golden,
        approach=approach,
    )
    if skip:
        page = page.replace(
            "</div>\n  <div class=\"legend meta\">",
            f"</div>\n  <div class=\"meta\">{html.escape(skip)}</div>\n  <div class=\"legend meta\">",
            1,
        )
    out.write_text(page, encoding="utf-8")
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--workdir", type=Path, default=DEFAULT_WORKDIR)
    ap.add_argument(
        "--detector",
        choices=["labeler", "segmenter"],
        default="labeler",
        help="labeler = topic-llm-v1 CLI; segmenter = heuristic segmenter-cli",
    )
    ap.add_argument(
        "--swift-cli",
        type=Path,
        default=None,
        help="CLI path (default: build/labeler-cli or build/segmenter-cli)",
    )
    ap.add_argument(
        "--slug",
        action="append",
        dest="slugs",
        help="Only these show dirs (default: all with transcript.json)",
    )
    ap.add_argument("--open", action="store_true", help="open generated HTML on macOS")
    args = ap.parse_args()

    cli = args.swift_cli
    if cli is None:
        cli = ROOT / ("build/labeler-cli" if args.detector == "labeler" else "build/segmenter-cli")
    if not cli.exists():
        print(f"missing CLI: {cli}", file=sys.stderr)
        if args.detector == "labeler":
            print("run: scripts/build_labeler_cli.sh", file=sys.stderr)
        else:
            print("run: scripts/build_segmenter_cli.sh", file=sys.stderr)
        return 1

    shows = []
    for child in sorted(args.workdir.iterdir()):
        if not child.is_dir():
            continue
        if args.slugs and child.name not in args.slugs:
            continue
        if (child / "transcript.json").exists():
            shows.append(child)

    if not shows:
        print("no shows with transcript.json", file=sys.stderr)
        return 1

    written: list[Path] = []
    for show in shows:
        path = process_show(show, cli, detector=args.detector)
        if path:
            print(f"wrote {path}")
            written.append(path)

    if args.open and written:
        subprocess.run(["open", *[str(p) for p in written]], check=False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
