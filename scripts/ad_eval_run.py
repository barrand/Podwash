#!/usr/bin/env python3
"""Run full ad-eval pipeline: fetch → transcribe → label → score."""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

from ad_eval_common import DEFAULT_WORKDIR, SHOWS

SCRIPTS = Path(__file__).resolve().parent


def run(cmd: list[str]) -> None:
    print("$", " ".join(cmd), flush=True)
    subprocess.run(cmd, check=True)


def main() -> None:
    parser = argparse.ArgumentParser(description="Run ad-eval pipeline")
    parser.add_argument("--workdir", type=Path, default=DEFAULT_WORKDIR)
    parser.add_argument("--show", action="append")
    parser.add_argument("--skip-fetch", action="store_true")
    parser.add_argument("--skip-transcribe", action="store_true")
    parser.add_argument("--skip-label", action="store_true")
    parser.add_argument("--skip-score", action="store_true")
    parser.add_argument("--no-llm", action="store_true")
    args = parser.parse_args()

    py = sys.executable
    show_args: list[str] = []
    if args.show:
        for s in args.show:
            show_args.extend(["--show", s])

    workdir = args.workdir.resolve()
    workdir.mkdir(parents=True, exist_ok=True)

    if not args.skip_fetch:
        run([py, str(SCRIPTS / "ad_eval_fetch.py"), "--workdir", str(workdir), *show_args])
    if not args.skip_transcribe:
        run(
            [
                py,
                str(SCRIPTS / "ad_eval_transcribe.py"),
                "--workdir",
                str(workdir),
                *show_args,
            ]
        )
    if not args.skip_label:
        label_cmd = [
            py,
            str(SCRIPTS / "ad_eval_label.py"),
            "--workdir",
            str(workdir),
            *show_args,
        ]
        if args.no_llm:
            label_cmd.append("--no-llm")
        run(label_cmd)
    if not args.skip_score:
        run([py, str(SCRIPTS / "ad_eval_score.py"), "--workdir", str(workdir), *show_args])

    provenance = workdir / "PROVENANCE.md"
    if not provenance.exists():
        provenance.write_text(
            """# Ad eval provenance

See `PROVENANCE.md` in the workdir for full details.

- **Goldens:** `golden.json` per show (provisional until you review `MARKUP.md`).
- **Bootstrap:** `python3 scripts/ad_eval_golden.py --from-markup --reviewer you`
- **Transcripts:** TAL from web when available; others from faster-whisper `tiny.en`.
- **Labels:** Rule-based + optional OpenAI; not generated from heuristic output.
""",
            encoding="utf-8",
        )

    print(f"\nReview MARKUP.md files under {workdir}/<show>/")
    print(f"Promote goldens: python3 scripts/ad_eval_golden.py --from-markup --reviewer you")
    print(f"Summary: {workdir / 'metrics_summary.json'}")
    print(f"Findings: {workdir / 'FINDINGS.md'}")


if __name__ == "__main__":
    main()
