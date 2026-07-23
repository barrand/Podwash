#!/usr/bin/env python3
"""Evidence-only DAI probe; never changes playback audio or transcripts."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from ad_eval_corpus_score import DEFAULT_CORPUS, DEFAULT_WORKDIR, load_corpus


def duration(path: Path) -> float | None:
    for command in (["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", str(path)], ["afinfo", str(path)]):
        try:
            out = subprocess.run(command, text=True, capture_output=True, check=True).stdout
            if command[0] == "ffprobe":
                return round(float(out.strip()), 3)
        except (FileNotFoundError, subprocess.CalledProcessError, ValueError):
            continue
    return None


def record(path: Path, *, response: Any = None, error: Exception | None = None) -> dict[str, Any]:
    if error:
        return {"error": str(error)}
    result = {
        "requestedAt": datetime.now(timezone.utc).isoformat(),
        "bytes": path.stat().st_size,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "durationSeconds": duration(path),
    }
    if response is None:
        return result
    headers = response.headers
    return {
        **result,
        "status": getattr(response, "status", None),
        "finalUrl": response.geturl(),
        "headers": {k.lower(): v for k, v in headers.items() if k.lower() in {"content-length", "content-type", "etag", "last-modified", "cache-control", "age", "via"}},
    }


def fetch(url: str, path: Path, agent: str) -> dict[str, Any]:
    request = urllib.request.Request(url, headers={"User-Agent": agent, "Cache-Control": "no-cache", "Pragma": "no-cache"})
    try:
        with urllib.request.urlopen(request, timeout=600) as response:
            path.write_bytes(response.read())
            return record(path, response=response)
    except Exception as error:  # report individual endpoint failures, continue corpus
        return record(path, error=error)


def materially_different(a: dict[str, Any], b: dict[str, Any]) -> bool:
    if "error" in a or "error" in b:
        return False
    duration_delta = abs((a.get("durationSeconds") or 0) - (b.get("durationSeconds") or 0))
    size_delta = abs(int(a["bytes"]) - int(b["bytes"]))
    return a["sha256"] != b["sha256"] and (duration_delta >= 1.0 or size_delta >= 50_000)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--workdir", type=Path, default=DEFAULT_WORKDIR)
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    parser.add_argument("--show", action="append")
    parser.add_argument("--append", action="store_true", help="append selected episodes to an existing partial report")
    args = parser.parse_args()
    split, goldens = load_corpus(args.corpus.resolve(), args.workdir.resolve())
    output = args.workdir.resolve() / "dai-probe-report.json"
    wanted = set(args.show or goldens.keys())
    existing: dict[str, dict[str, Any]] = {}
    if args.append and output.exists():
        existing = {row["slug"]: row for row in json.loads(output.read_text()).get("rows", [])}
    rows: list[dict[str, Any]] = list(existing.values())
    for slug in sorted(wanted):
        if slug not in goldens:
            raise SystemExit(f"unknown corpus episode: {slug}")
        episode_dir = args.workdir.resolve() / slug
        meta = json.loads((episode_dir / "meta.json").read_text())
        original = episode_dir / Path(meta["audioPath"]).name
        row: dict[str, Any] = {"slug": slug, "split": split[slug], "audioUrl": meta.get("audioUrl"), "original": record(original) if original.exists() else {"error": "missing original audio"}}
        if not meta.get("audioUrl"):
            row["classification"] = "fetch_error"
        else:
            row["freshA"] = fetch(meta["audioUrl"], episode_dir / "audio-dai-a.bin", "PodWash-DAI-probe-A/1.0")
            row["freshB"] = fetch(meta["audioUrl"], episode_dir / "audio-dai-b.bin", "PodWash-DAI-probe-B/1.0")
            records = [row["original"], row["freshA"], row["freshB"]]
            if any("error" in x for x in records):
                row["classification"] = "fetch_error"
            elif any(materially_different(a, b) for i, a in enumerate(records) for b in records[i + 1:]):
                row["classification"] = "dai_likely"
            else:
                row["classification"] = "inconclusive"
        existing[slug] = row
        rows = [existing[key] for key in sorted(existing)]
        # Keep partial evidence if a host stalls or a long corpus run is
        # interrupted. A later run replaces the report with a complete pass.
        output.write_text(json.dumps({"schemaVersion": 1, "complete": False, "rows": rows}, indent=2) + "\n")
        print(f"[{slug}] {row['classification']}")
    complete = set(existing) == set(goldens)
    output.write_text(json.dumps({"schemaVersion": 1, "complete": complete, "rows": rows}, indent=2) + "\n")
    print(f"Wrote {output}")


if __name__ == "__main__":
    main()
