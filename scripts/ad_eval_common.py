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

SHOWS = [
    ("this-american-life", "This American Life"),
    ("darknet-diaries", "Dark Net Diaries"),
    ("ai-daily-brief", "AI Daily Brief"),
    ("cougar-sports", "Cougar Sports Ben Criddle"),
]

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
    best = results[0]
    feed = best.get("feedUrl")
    if not feed:
        raise RuntimeError(f"No feedUrl for {search_term!r}")
    return feed, best.get("collectionName", search_term), best.get("description", "") or ""


def _local(tag: str) -> str:
    return tag.split("}")[-1] if "}" in tag else tag


def parse_rss_latest(feed_xml: bytes) -> dict[str, Any]:
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

    item = None
    for child in channel:
        if _local(child.tag) == "item":
            item = child
            break
    if item is None:
        raise RuntimeError("RSS missing item")

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
            try:
                length = int(child.get("length", "0"))
                if length > 0:
                    # length is bytes not seconds; keep None unless itunes:duration present
                    pass
            except ValueError:
                pass
        if tag == "duration" and child.text:
            try:
                duration_sec = float(child.text.strip())
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


def guess_tal_transcript_url(episode_title: str, feed_url: str) -> str | None:
    if "thisamericanlife.org" not in feed_url.lower():
        return None
    m = re.search(r"\b(\d{3})\b", episode_title)
    if not m:
        return None
    return f"https://www.thisamericanlife.org/{m.group(1)}/transcript"


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
