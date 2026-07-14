#!/usr/bin/env python3
"""Fetch latest episode audio + metadata for ad-eval shows."""

from __future__ import annotations

import argparse
import json
import urllib.parse
from pathlib import Path

from ad_eval_common import (
    DEFAULT_WORKDIR,
    SHOWS,
    EpisodeMeta,
    guess_tal_transcript_url,
    http_get,
    itunes_feed_url,
    parse_rss_latest,
    save_meta,
    show_dir,
)


def download_audio(url: str, dest: Path) -> None:
    data = http_get(url, timeout=600)
    dest.write_bytes(data)


def fetch_show(workdir: Path, slug: str, search_term: str) -> EpisodeMeta:
    feed_url, collection_name, itunes_desc = itunes_feed_url(search_term)
    feed_xml = http_get(feed_url, timeout=120)
    latest = parse_rss_latest(feed_xml)

    audio_url = latest["audioUrl"]
    if not audio_url:
        raise RuntimeError(f"No enclosure URL in RSS for {search_term}")

    ext = ".mp3"
    parsed = urllib.parse.urlparse(audio_url)
    suffix = Path(parsed.path).suffix.lower()
    if suffix in {".m4a", ".mp3", ".wav", ".aac", ".ogg"}:
        ext = suffix

    out_dir = show_dir(workdir, slug)
    out_dir.mkdir(parents=True, exist_ok=True)
    audio_path = out_dir / f"audio{ext}"

    print(f"[{slug}] downloading {audio_url}")
    download_audio(audio_url, audio_path)

    show_description = latest.get("showDescription") or itunes_desc
    tal_url = guess_tal_transcript_url(latest["episodeTitle"], feed_url)

    meta = EpisodeMeta(
        show_slug=slug,
        show_name=collection_name,
        search_term=search_term,
        feed_url=feed_url,
        show_description=show_description,
        episode_title=latest["episodeTitle"],
        episode_description=latest.get("episodeDescription", ""),
        episode_guid=latest["episodeGuid"],
        audio_url=audio_url,
        audio_path=str(audio_path.relative_to(workdir)),
        duration_sec=latest.get("durationSec"),
        pub_date=latest.get("pubDate"),
        tal_transcript_url=tal_url,
    )
    save_meta(workdir, meta)
    print(f"[{slug}] saved {audio_path.name} ({audio_path.stat().st_size // 1024} KB)")
    return meta


def main() -> None:
    parser = argparse.ArgumentParser(description="Fetch ad-eval episodes")
    parser.add_argument("--workdir", type=Path, default=DEFAULT_WORKDIR)
    parser.add_argument("--show", action="append", help="Limit to show slug")
    args = parser.parse_args()

    workdir = args.workdir.resolve()
    workdir.mkdir(parents=True, exist_ok=True)

    selected = SHOWS
    if args.show:
        wanted = set(args.show)
        selected = [(s, t) for s, t in SHOWS if s in wanted]

    index: list[dict] = []
    for slug, term in selected:
        meta = fetch_show(workdir, slug, term)
        index.append(
            {
                "slug": slug,
                "title": meta.episode_title,
                "audio": meta.audio_path,
                "talTranscriptUrl": meta.tal_transcript_url,
            }
        )

    (workdir / "index.json").write_text(
        json.dumps(index, indent=2) + "\n", encoding="utf-8"
    )
    print(f"Wrote {workdir / 'index.json'}")


if __name__ == "__main__":
    main()
