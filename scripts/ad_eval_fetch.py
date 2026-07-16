#!/usr/bin/env python3
"""Fetch pinned or latest episode audio + metadata for ad-eval shows."""

from __future__ import annotations

import argparse
import json
import urllib.parse
from pathlib import Path

from ad_eval_common import (
    DEFAULT_WORKDIR,
    EPISODE_PINS,
    EpisodeMeta,
    guess_published_transcript_url,
    guess_tal_transcript_url,
    http_get,
    itunes_feed_url,
    parse_rss_pin,
    save_meta,
    select_shows,
    show_dir,
)


def download_audio(url: str, dest: Path) -> None:
    data = http_get(url, timeout=600)
    dest.write_bytes(data)


def fetch_show(
    workdir: Path,
    slug: str,
    search_term: str,
    *,
    pin: str | None = None,
    force: bool = False,
) -> EpisodeMeta:
    feed_url, collection_name, itunes_desc = itunes_feed_url(search_term)
    feed_xml = http_get(feed_url, timeout=120)
    effective_pin = pin if pin is not None else EPISODE_PINS.get(slug)
    latest = parse_rss_pin(feed_xml, effective_pin)

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

    if audio_path.exists() and not force:
        print(f"[{slug}] keeping existing {audio_path.name} (pass --force to re-download)")
    else:
        print(f"[{slug}] downloading {audio_url}")
        download_audio(audio_url, audio_path)

    show_description = latest.get("showDescription") or itunes_desc
    tal_url = guess_tal_transcript_url(latest["episodeTitle"], feed_url)
    published = guess_published_transcript_url(
        slug, latest["episodeTitle"], feed_url, latest["episodeGuid"]
    )

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
        published_transcript_url=published or tal_url,
    )
    save_meta(workdir, meta)
    pin_note = f" pin={effective_pin!r}" if effective_pin else " (latest)"
    print(
        f"[{slug}] saved {audio_path.name} ({audio_path.stat().st_size // 1024} KB)"
        f" — {meta.episode_title}{pin_note}"
    )
    return meta


def main() -> None:
    parser = argparse.ArgumentParser(description="Fetch ad-eval episodes")
    parser.add_argument("--workdir", type=Path, default=DEFAULT_WORKDIR)
    parser.add_argument("--show", action="append", help="Limit to show slug")
    parser.add_argument(
        "--pin",
        action="append",
        metavar="SLUG=NEEDLE",
        help="Override episode pin (title/guid substring), e.g. this-american-life=891",
    )
    parser.add_argument("--force", action="store_true", help="Re-download audio")
    parser.add_argument(
        "--include-optional",
        action="store_true",
        help="Also fetch OPTIONAL_SHOWS (Darknet Diaries)",
    )
    args = parser.parse_args()

    workdir = args.workdir.resolve()
    workdir.mkdir(parents=True, exist_ok=True)

    pin_overrides: dict[str, str] = {}
    if args.pin:
        for raw in args.pin:
            if "=" not in raw:
                raise SystemExit(f"--pin expects SLUG=NEEDLE, got {raw!r}")
            s, n = raw.split("=", 1)
            pin_overrides[s] = n

    wanted = set(args.show) if args.show else None
    selected = select_shows(wanted, include_optional=args.include_optional)

    index: list[dict] = []
    for slug, term in selected:
        pin = pin_overrides.get(slug)
        meta = fetch_show(workdir, slug, term, pin=pin, force=args.force)
        index.append(
            {
                "slug": slug,
                "title": meta.episode_title,
                "audio": meta.audio_path,
                "talTranscriptUrl": meta.tal_transcript_url,
                "publishedTranscriptUrl": meta.published_transcript_url,
                "pin": pin_overrides.get(slug) or EPISODE_PINS.get(slug),
            }
        )

    (workdir / "index.json").write_text(
        json.dumps(index, indent=2) + "\n", encoding="utf-8"
    )
    print(f"Wrote {workdir / 'index.json'}")


if __name__ == "__main__":
    main()
