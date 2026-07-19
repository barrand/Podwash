#!/usr/bin/env python3
"""Shared helpers for ad detection offline eval."""

from __future__ import annotations

import json
import re
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_WORKDIR = REPO_ROOT / "tmp" / "ad-eval"

# Primary listening corpus + local-radio diversity (Cougar Sports).
# TAL 891 is dogfood-only (see DOGFOOD_PINS); still in SHOWS for fetch convenience.
SHOWS: list[tuple[str, str]] = [
    ("economics-of-everyday-things", "The Economics of Everyday Things"),
    ("ai-daily-brief", "AI Daily Brief"),
    ("ai-news-strategy-daily", "AI News Strategy Daily"),
    ("unexplainable", "Unexplainable"),
    ("planet-money", "Planet Money"),
    ("99-percent-invisible", "99% Invisible"),
    ("dr-death", "Dr. Death"),
    ("version-history", "Version History"),
    ("radiolab", "Radiolab"),
    ("search-engine", "Search Engine podcast PJ Vogt"),
    ("cougar-sports", "Cougar Sports Ben Criddle"),
    ("this-american-life", "This American Life"),
]

# Optional hold-out (not primary gate).
OPTIONAL_SHOWS: list[tuple[str, str]] = [
    ("darknet-diaries", "Dark Net Diaries"),
]

# Pin by title/guid substring when present; otherwise latest episode.
# TAL 891 is required standing dogfood.
EPISODE_PINS: dict[str, str] = {
    "economics-of-everyday-things": "50. Self-Checkout",
    "this-american-life": "891",
}

# Standing dogfood slug (always score; do not tune thresholds on it alone).
DOGFOOD_SLUG = "this-american-life"

ITUNES_SEARCH = "https://itunes.apple.com/search"


@dataclass
class EpisodeMeta:
    show_slug: str
    show_name: str
    search_term: str
    feed_url: str
    show_description: str
    episode_title: str
    episode_description: str
    episode_guid: str
    audio_url: str
    audio_path: str
    duration_sec: float | None
    pub_date: str | None
    tal_transcript_url: str | None = None
    published_transcript_url: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "showSlug": self.show_slug,
            "showName": self.show_name,
            "searchTerm": self.search_term,
            "feedUrl": self.feed_url,
            "showDescription": self.show_description,
            "episodeTitle": self.episode_title,
            "episodeDescription": self.episode_description,
            "episodeGuid": self.episode_guid,
            "audioUrl": self.audio_url,
            "audioPath": self.audio_path,
            "durationSec": self.duration_sec,
            "pubDate": self.pub_date,
            "talTranscriptUrl": self.tal_transcript_url,
            "publishedTranscriptUrl": self.published_transcript_url,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> EpisodeMeta:
        return cls(
            show_slug=data["showSlug"],
            show_name=data["showName"],
            search_term=data.get("searchTerm", ""),
            feed_url=data["feedUrl"],
            show_description=data.get("showDescription", ""),
            episode_title=data["episodeTitle"],
            episode_description=data.get("episodeDescription", ""),
            episode_guid=data.get("episodeGuid", ""),
            audio_url=data.get("audioUrl", ""),
            audio_path=data.get("audioPath", ""),
            duration_sec=data.get("durationSec"),
            pub_date=data.get("pubDate"),
            tal_transcript_url=data.get("talTranscriptUrl"),
            published_transcript_url=data.get("publishedTranscriptUrl"),
        )


def show_dir(workdir: Path, slug: str) -> Path:
    return workdir / slug


def load_meta(workdir: Path, slug: str) -> EpisodeMeta:
    path = show_dir(workdir, slug) / "meta.json"
    return EpisodeMeta.from_dict(json.loads(path.read_text(encoding="utf-8")))


def save_meta(workdir: Path, meta: EpisodeMeta) -> None:
    d = show_dir(workdir, meta.show_slug)
    d.mkdir(parents=True, exist_ok=True)
    (d / "meta.json").write_text(
        json.dumps(meta.to_dict(), indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )


def http_get(url: str, timeout: int = 120) -> bytes:
    req = urllib.request.Request(
        url,
        headers={"User-Agent": "PodWash-ad-eval/1.0"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def itunes_feed_url(search_term: str) -> tuple[str, str, str]:
    params = urllib.parse.urlencode(
        {
            "term": search_term,
            "media": "podcast",
            "entity": "podcast",
            "limit": 5,
        }
    )
    data = json.loads(http_get(f"{ITUNES_SEARCH}?{params}").decode("utf-8"))
    results = data.get("results") or []
    if not results:
        raise RuntimeError(f"No iTunes results for {search_term!r}")
    # Prefer exact-ish collection name match when multiple hits.
    best = results[0]
    term_l = search_term.lower()
    for r in results:
        name = (r.get("collectionName") or "").lower()
        if term_l in name or name in term_l:
            best = r
            break
    feed = best.get("feedUrl")
    if not feed:
        raise RuntimeError(f"No feedUrl for {search_term!r}")
    return feed, best.get("collectionName", search_term), best.get("description", "") or ""


def _local(tag: str) -> str:
    return tag.split("}")[-1] if "}" in tag else tag


def _parse_rss_item(item: ET.Element, show_description: str) -> dict[str, Any]:
    def item_text(name: str) -> str:
        for child in item:
            if _local(child.tag) == name and child.text:
                return child.text.strip()
        return ""

    title = item_text("title")
    guid = item_text("guid") or item_text("link") or title
    description = item_text("description") or item_text("summary")
    pub_date = item_text("pubDate")

    audio_url = ""
    duration_sec: float | None = None
    for child in item:
        tag = _local(child.tag)
        if tag == "enclosure" and child.get("url"):
            audio_url = child.get("url", "")
        if tag == "duration" and child.text:
            raw = child.text.strip()
            try:
                if ":" in raw:
                    parts = [float(p) for p in raw.split(":")]
                    if len(parts) == 3:
                        duration_sec = parts[0] * 3600 + parts[1] * 60 + parts[2]
                    elif len(parts) == 2:
                        duration_sec = parts[0] * 60 + parts[1]
                else:
                    duration_sec = float(raw)
            except ValueError:
                pass

    return {
        "showDescription": show_description,
        "episodeTitle": title,
        "episodeGuid": guid,
        "episodeDescription": description,
        "audioUrl": audio_url,
        "durationSec": duration_sec,
        "pubDate": pub_date or None,
    }


def parse_rss_items(feed_xml: bytes) -> list[dict[str, Any]]:
    root = ET.fromstring(feed_xml)
    channel = root.find("channel")
    if channel is None:
        channel = root.find("{*}channel")
    if channel is None:
        raise RuntimeError("RSS missing channel")

    show_description = ""
    for child in channel:
        if _local(child.tag) == "description" and child.text:
            show_description = child.text.strip()
            break

    items: list[dict[str, Any]] = []
    for child in channel:
        if _local(child.tag) == "item":
            items.append(_parse_rss_item(child, show_description))
    if not items:
        raise RuntimeError("RSS missing item")
    return items


def parse_rss_latest(feed_xml: bytes) -> dict[str, Any]:
    return parse_rss_items(feed_xml)[0]


def parse_rss_pin(feed_xml: bytes, pin: str | None) -> dict[str, Any]:
    """Return first item whose title/guid contains `pin` (case-insensitive), else latest."""
    items = parse_rss_items(feed_xml)
    if not pin:
        return items[0]
    needle = pin.lower()
    for item in items:
        hay = f"{item.get('episodeTitle', '')} {item.get('episodeGuid', '')}".lower()
        if needle in hay:
            return item
    raise RuntimeError(f"No RSS item matching pin {pin!r} (scanned {len(items)} items)")


def guess_tal_transcript_url(episode_title: str, feed_url: str) -> str | None:
    if "thisamericanlife.org" not in feed_url.lower():
        return None
    m = re.search(r"\b(\d{3,4})\b", episode_title)
    if not m:
        return None
    return f"https://www.thisamericanlife.org/{m.group(1)}/transcript"


def guess_published_transcript_url(
    slug: str, episode_title: str, feed_url: str, episode_guid: str
) -> str | None:
    """Best-effort published (often ad-free) transcript URL for diff labeling."""
    tal = guess_tal_transcript_url(episode_title, feed_url)
    if tal:
        return tal
    # NPR Planet Money episode pages sometimes expose transcripts; leave None
    # and let ad_eval_diff_label try known patterns from meta.
    _ = (slug, episode_guid, feed_url)
    return None


def fmt_time(seconds: float) -> str:
    seconds = max(0.0, seconds)
    m, s = divmod(int(seconds), 60)
    h, m = divmod(m, 60)
    if h:
        return f"{h}:{m:02d}:{s:02d}"
    return f"{m}:{s:02d}"


def parse_time_to_seconds(text: str) -> float | None:
    text = text.strip()
    if not text:
        return None
    parts = text.split(":")
    try:
        nums = [float(p) for p in parts]
    except ValueError:
        return None
    if len(nums) == 3:
        return nums[0] * 3600 + nums[1] * 60 + nums[2]
    if len(nums) == 2:
        return nums[0] * 60 + nums[1]
    if len(nums) == 1:
        return nums[0]
    return None


def select_shows(
    wanted: set[str] | None = None, *, include_optional: bool = False
) -> list[tuple[str, str]]:
    rows = list(SHOWS)
    if include_optional:
        rows.extend(OPTIONAL_SHOWS)
    if wanted:
        rows = [(s, t) for s, t in rows if s in wanted]
    return rows
