#!/usr/bin/env python3
"""Promote reviewed (or provisional) spans into golden.json for ad-eval scoring."""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

from ad_eval_common import DEFAULT_WORKDIR, SHOWS, show_dir


def promote_provisional(workdir: Path, slug: str, reviewer: str) -> None:
    out_dir = show_dir(workdir, slug)
    proposed_path = out_dir / "llm_proposed.json"
    golden_path = out_dir / "golden.json"

    if not proposed_path.exists():
        raise FileNotFoundError(f"Missing {proposed_path}")

    proposed = json.loads(proposed_path.read_text(encoding="utf-8"))
    spans = proposed.get("spans", [])
    golden = {
        "status": "provisional",
        "reviewer": reviewer,
        "reviewedAt": datetime.now(timezone.utc).isoformat(),
        "source": "llm_proposed.json",
        "note": (
            "Bootstrap copy for scoring. Edit MARKUP.md, then re-run with "
            "--from-markup after checking agree boxes, or hand-edit golden.json."
        ),
        "spans": spans,
    }
    golden_path.write_text(json.dumps(golden, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"Wrote {golden_path} ({len(spans)} spans, provisional)")


def from_markup(workdir: Path, slug: str, reviewer: str) -> None:
    """Accept spans where MARKUP.md has [x] agree on the review line."""
    import re

    out_dir = show_dir(workdir, slug)
    markup_path = out_dir / "MARKUP.md"
    proposed_path = out_dir / "llm_proposed.json"
    golden_path = out_dir / "golden.json"

    if not markup_path.exists():
        raise FileNotFoundError(f"Missing {markup_path}")
    if not proposed_path.exists():
        raise FileNotFoundError(f"Missing {proposed_path}")

    markup = markup_path.read_text(encoding="utf-8")
    proposed = json.loads(proposed_path.read_text(encoding="utf-8"))
    spans = proposed.get("spans", [])

    agree_re = re.compile(r"\*\*Your review:\*\*\s*\[x\]\s*agree", re.IGNORECASE)
    blocks = re.split(r"(?=### Span \d+)", markup)
    accepted: list[dict] = []
    for block in blocks:
        if not block.strip().startswith("### Span"):
            continue
        m = re.search(r"### Span (\d+)", block)
        if not m:
            continue
        idx = int(m.group(1)) - 1
        if idx < 0 or idx >= len(spans):
            continue
        if agree_re.search(block):
            accepted.append(spans[idx])

    golden = {
        "status": "human-approved" if accepted else "provisional",
        "reviewer": reviewer,
        "reviewedAt": datetime.now(timezone.utc).isoformat(),
        "source": "MARKUP.md agree checkboxes",
        "spans": accepted if accepted else spans,
    }
    golden_path.write_text(json.dumps(golden, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"Wrote {golden_path} ({len(golden['spans'])} spans, {golden['status']})")


def main() -> None:
    parser = argparse.ArgumentParser(description="Create golden.json from proposals or MARKUP review")
    parser.add_argument("--workdir", type=Path, default=DEFAULT_WORKDIR)
    parser.add_argument("--show", action="append")
    parser.add_argument("--from-markup", action="store_true", help="Only include spans with [x] agree in MARKUP.md")
    parser.add_argument("--reviewer", default="pending")
    args = parser.parse_args()

    sys.path.insert(0, str(Path(__file__).resolve().parent))
    workdir = args.workdir.resolve()
    selected = SHOWS
    if args.show:
        wanted = set(args.show)
        selected = [(s, _) for s, _ in SHOWS if s in wanted]

    for slug, _ in selected:
        if args.from_markup:
            from_markup(workdir, slug, args.reviewer)
        else:
            promote_provisional(workdir, slug, args.reviewer)


if __name__ == "__main__":
    main()
