#!/usr/bin/env python3
"""Draft conservative ad-golden proposals from transcript cue clusters.

This is a reviewer-assist tool, not a production detector. It intentionally
over-surfaces sponsor/CTA regions as spans or audit notes so a human can move
quickly in the Golden Retriever UI.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_WORKDIR = ROOT / "tmp" / "ad-eval"

LABELS = {"paid_dai", "paid_baked_in", "paid_host_read", "network_promo", "membership_cta"}

SPONSOR_CUES = {
    "sponsor",
    "sponsored",
    "sponsors",
    "support",
    "brought",
    "presented",
    "partner",
    "partners",
    "advertise",
    "advertising",
}

CTA_CUES = {
    "apply",
    "buy",
    "call",
    "check",
    "click",
    "code",
    "coupon",
    "deal",
    "download",
    "free",
    "go",
    "join",
    "learn",
    "offer",
    "promo",
    "save",
    "shop",
    "sign",
    "start",
    "subscribe",
    "try",
    "use",
    "visit",
}

MONEY_CUES = {
    "%",
    "dollar",
    "dollars",
    "funded",
    "funds",
    "limited",
    "off",
    "pricing",
    "sale",
    "trial",
}

NETWORK_CUES = {
    "adchoices",
    "another",
    "available",
    "episode",
    "episodes",
    "listen",
    "podcast",
    "podcasts",
    "wherever",
}

HOST_READ_SHOW_HINTS = {
    "cougar",
    "sports",
    "studio",
    "studios",
    "hotel",
    "wealth",
    "orthodont",
    "mattress",
}

SUPPORT_OPENER_PATTERNS = (
    ("we", "get", "support", "from"),
    ("we", "are", "supported", "by"),
    ("we're", "supported", "by"),
    ("were", "supported", "by"),
    ("we", "receive", "support", "from"),
    ("this", "episode", "is", "supported", "by"),
    ("this", "show", "is", "supported", "by"),
    ("this", "podcast", "is", "supported", "by"),
    ("episode", "is", "supported", "by"),
    ("show", "is", "supported", "by"),
    ("supported", "by"),
    ("support", "for", "this", "show", "comes", "from"),
    ("support", "for", "this", "podcast", "comes", "from"),
    ("support", "comes", "from"),
    ("support", "is", "provided", "by"),
    ("made", "possible", "by"),
)

SPONSOR_OPENER_PATTERNS = SUPPORT_OPENER_PATTERNS + (
    ("this", "episode", "is", "sponsored", "by"),
    ("this", "show", "is", "sponsored", "by"),
    ("this", "podcast", "is", "sponsored", "by"),
    ("episode", "is", "sponsored", "by"),
    ("show", "is", "sponsored", "by"),
    ("sponsored", "by"),
    ("brought", "to", "you", "by"),
    ("presented", "by"),
    ("our", "friends", "at"),
)


@dataclass
class Cluster:
    start: int
    end: int
    score: int
    reasons: list[str]


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_json(path: Path, payload: Any) -> None:
    encoded = (json.dumps(payload, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def normalized_token(word: dict[str, Any]) -> str:
    raw = str(word.get("word") or "").lower().strip()
    if raw in {".com", ".org", ".fm", ".net"}:
        return raw
    return re.sub(r"^[^\w%]+|[^\w%]+$", "", raw)


def looks_like_url(tokens: list[str], index: int) -> bool:
    token = tokens[index]
    if ".com" in token or ".org" in token or ".fm" in token or ".net" in token:
        return True
    if token in {"com", "org", "fm", "net"} and index > 0 and tokens[index - 1] in {"dot", "."}:
        return True
    return False


def matches_phrase(tokens: list[str], index: int, phrase: tuple[str, ...]) -> bool:
    return tuple(tokens[index : index + len(phrase)]) == phrase


def matches_any_phrase(tokens: list[str], index: int, phrases: tuple[tuple[str, ...], ...]) -> bool:
    return any(matches_phrase(tokens, index, phrase) for phrase in phrases)


def is_cue(tokens: list[str], index: int) -> tuple[bool, str]:
    token = tokens[index]
    nearby = tokens[max(0, index - 4) : min(len(tokens), index + 7)]
    if looks_like_url(tokens, index):
        return True, "URL"
    if matches_any_phrase(tokens, index, SUPPORT_OPENER_PATTERNS):
        return True, "explicit support opener"
    if matches_any_phrase(tokens, index, SPONSOR_OPENER_PATTERNS):
        return True, "explicit sponsor opener"
    if token in SPONSOR_CUES:
        return True, "sponsor/support phrase"
    if token in CTA_CUES and any(looks_like_url(tokens, j) for j in range(index, min(len(tokens), index + 18))):
        return True, "CTA near URL"
    if token in CTA_CUES and set(nearby) & MONEY_CUES:
        return True, "CTA near offer language"
    if token == "adchoices":
        return True, "adchoices"
    if token == "code" and index > 0 and tokens[index - 1] in {"promo", "discount"}:
        return True, "promo code"
    return False, ""


def sentence_bounds(tokens: list[str], words: list[dict[str, Any]], left: int, right: int) -> tuple[int, int]:
    start = max(0, left)
    end = min(len(words), right)

    for index in range(max(0, left), -1, -1):
        raw = str(words[index].get("word") or "")
        if index < left - 45:
            break
        if index < left and re.search(r"[.!?]$", raw):
            start = index + 1
            break
    for index in range(min(len(words) - 1, right), len(words)):
        raw = str(words[index].get("word") or "")
        if index > right + 55:
            break
        if re.search(r"[.!?]$", raw):
            end = index + 1
            break
    return start, max(start + 1, end)


def find_clusters(words: list[dict[str, Any]]) -> list[Cluster]:
    tokens = [normalized_token(word) for word in words]
    cue_points: list[tuple[int, str]] = []
    for index in range(len(tokens)):
        hit, reason = is_cue(tokens, index)
        if hit:
            cue_points.append((index, reason))

    clusters: list[Cluster] = []
    active: list[tuple[int, str]] = []
    for point in cue_points:
        if not active or point[0] - active[-1][0] <= 65:
            active.append(point)
            continue
        clusters.append(make_cluster(words, tokens, active))
        active = [point]
    if active:
        clusters.append(make_cluster(words, tokens, active))

    opener_spans = find_opener_spans(words, tokens)
    generic_clusters = [
        cluster
        for cluster in clusters
        if not any(cluster.start < opener.end and cluster.end > opener.start for opener in opener_spans)
    ]
    return merge_clusters(opener_spans + generic_clusters)


def find_opener_spans(words: list[dict[str, Any]], tokens: list[str]) -> list[Cluster]:
    spans: list[Cluster] = []
    raw_openers = [
        index
        for index in range(len(tokens))
        if matches_any_phrase(tokens, index, SPONSOR_OPENER_PATTERNS)
    ]
    openers: list[int] = []
    for index in raw_openers:
        if not openers or index - openers[-1] > 8:
            openers.append(index)
    for ordinal, start in enumerate(openers):
        next_opener = openers[ordinal + 1] if ordinal + 1 < len(openers) else len(tokens)
        search_end = min(next_opener, start + 320, len(tokens))
        cue_end = start
        reasons = {"explicit sponsor opener"}
        if matches_any_phrase(tokens, start, SUPPORT_OPENER_PATTERNS):
            reasons.add("explicit support opener")

        for index in range(start + 1, search_end):
            hit, reason = is_cue(tokens, index)
            if hit:
                cue_end = index
                reasons.add(reason)

        has_tail_cue = bool(reasons & {"URL", "CTA near URL", "CTA near offer language", "promo code"})
        if not has_tail_cue:
            if next_opener < len(tokens) and next_opener - start <= 320:
                end = next_opener
            else:
                _, end = sentence_bounds(tokens, words, start, min(search_end, start + 120))
        else:
            _, end = sentence_bounds(tokens, words, cue_end, min(search_end, cue_end + 18))
        end = min(max(start + 1, end), next_opener)
        duration = float(words[end - 1]["end"]) - float(words[start]["start"])
        if duration >= 8:
            score = 9 + len(reasons)
            spans.append(Cluster(start, end, score, sorted(reasons)))
    return spans


def make_cluster(words: list[dict[str, Any]], tokens: list[str], points: list[tuple[int, str]]) -> Cluster:
    first = points[0][0]
    last = points[-1][0]
    left, right = sentence_bounds(tokens, words, max(0, first - 28), min(len(words), last + 38))
    reasons = sorted({reason for _, reason in points})
    score = len(points) + sum(
        2
        for _, reason in points
        if reason in {"URL", "sponsor/support phrase", "explicit support opener", "explicit sponsor opener"}
    )
    score += sum(4 for _, reason in points if reason in {"explicit support opener", "explicit sponsor opener"})
    return Cluster(left, right, score, reasons)


def merge_clusters(clusters: list[Cluster]) -> list[Cluster]:
    if not clusters:
        return []
    clusters = sorted(clusters, key=lambda cluster: (cluster.start, cluster.end))
    merged = [clusters[0]]
    for cluster in clusters[1:]:
        previous = merged[-1]
        previous_has_opener = "explicit sponsor opener" in previous.reasons
        cluster_has_opener = "explicit sponsor opener" in cluster.reasons
        if previous_has_opener and cluster_has_opener and cluster.start >= previous.end - 2:
            merged.append(cluster)
            continue
        if cluster.start <= previous.end + 20:
            previous.end = max(previous.end, cluster.end)
            previous.score += cluster.score
            previous.reasons = sorted(set(previous.reasons) | set(cluster.reasons))
        else:
            merged.append(cluster)
    return merged


def classify(words: list[dict[str, Any]], start: int, end: int, slug: str) -> tuple[str, str]:
    text = " ".join(str(word.get("word") or "") for word in words[start:end]).lower()
    if "adchoices" in text or ("listen" in text and "podcast" in text and "wherever" in text):
        return "network_promo", "Podcast/network promo or adchoices-style outro."
    if (
        "patreon" in text
        or "membership" in text
        or "memberships" in text
        or "become a member" in text
        or (("subscribe" in text or "subscription" in text) and re.search(r"\bad[ -]?free\b", text))
    ):
        return "membership_cta", "Membership/subscription CTA."
    if re.search(
        r"\b(?:we get support from|we are supported by|we(?:'re|re) supported by|we receive support from|"
        r"this episode is supported by|this (?:show|podcast) is supported by|episode is supported by|"
        r"show is supported by|supported by|support (?:for this (?:show|podcast) )?comes from|"
        r"support is provided by|made possible by)\b",
        text,
    ):
        return "paid_host_read", "Host-read sponsor/support cue cluster."
    if slug.startswith("cougar") or set(re.findall(r"\w+", text)) & HOST_READ_SHOW_HINTS:
        return "paid_host_read", "Host-read/local sponsor cue cluster."
    return "paid_dai", "Commercial cue cluster; dynamic/baked-in source unknown."


def guess_advertiser(words: list[dict[str, Any]], start: int, end: int) -> str:
    text = " ".join(str(word.get("word") or "") for word in words[start:end])
    patterns = [
        r"(?:sponsored by|brought to you by|we get support from|we are supported by|we(?:'re|re) supported by|we receive support from|this episode is supported by|this (?:show|podcast) is supported by|episode is supported by|show is supported by|supported by|support .*? comes from|support comes from|support is provided by|made possible by|our friends at)\s+([A-Z0-9][A-Za-z0-9& .'-]{2,60})",
        r"(?:visit|go to|at)\s+([A-Za-z0-9.-]+\s*(?:dot\s*)?(?:com|org|fm|net))",
    ]
    for pattern in patterns:
        match = re.search(pattern, text, re.I)
        if match:
            advertiser = re.sub(r"\s+", " ", match.group(1)).strip(" .")
            return advertiser[:80]
    return ""


def context_text(words: list[dict[str, Any]], start: int, end: int) -> str:
    return " ".join(str(word.get("word") or "") for word in words[start:end])


def proposal_for_slug(workdir: Path, slug: str, min_score: int, dry_run: bool) -> dict[str, Any]:
    episode_dir = workdir / slug
    words = json.loads((episode_dir / "transcript.json").read_text(encoding="utf-8"))
    transcript_hash = file_sha256(episode_dir / "transcript.json")
    clusters = [cluster for cluster in find_clusters(words) if cluster.score >= min_score]

    spans: list[dict[str, Any]] = []
    audits: list[dict[str, Any]] = []
    for cluster in clusters:
        label, note = classify(words, cluster.start, cluster.end, slug)
        item = {
            "startWord": cluster.start,
            "endWord": cluster.end,
            "reason": f"Commercial cue cluster: {', '.join(cluster.reasons)}.",
        }
        duration = float(words[cluster.end - 1]["end"]) - float(words[cluster.start]["start"])
        if cluster.score >= min_score + 3 and duration >= 8:
            spans.append(
                {
                    "id": f"proposal-{len(spans) + 1:03d}",
                    "startWord": cluster.start,
                    "endWord": cluster.end,
                    "label": label,
                    "advertiser": guess_advertiser(words, cluster.start, cluster.end),
                    "note": note,
                }
            )
        else:
            audits.append(item)

    if not any(span["startWord"] < 180 for span in spans) and len(words) > 180:
        audits.append(
            {
                "startWord": 0,
                "endWord": min(220, len(words)),
                "reason": "No visible proposal near cold open; quick-scan the start for DAI.",
            }
        )
    if len(words) > 250 and not any(span["endWord"] > len(words) - 250 for span in spans):
        audits.append(
            {
                "startWord": max(0, len(words) - 260),
                "endWord": len(words),
                "reason": "No visible proposal near episode end; quick-scan the ending.",
            }
        )

    for index, item in enumerate(audits, 1):
        item["id"] = f"audit-{index:03d}"

    proposal = {
        "schemaVersion": 1,
        "showSlug": slug,
        "transcriptSha256": transcript_hash,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "sources": {
            "primary": "keyword-cue-cluster-v1",
            "notes": "Conservative reviewer-assist proposal from sponsor, CTA, URL, and promo cue clusters.",
        },
        "spans": spans,
        "auditItems": audits[:24],
    }
    if not dry_run:
        atomic_json(episode_dir / "proposal.json", proposal)
    return proposal


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workdir", type=Path, default=DEFAULT_WORKDIR)
    parser.add_argument("--show", action="append", required=True)
    parser.add_argument("--min-score", type=int, default=4)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    for slug in args.show:
        proposal = proposal_for_slug(args.workdir.resolve(), slug, args.min_score, args.dry_run)
        print(
            f"[{slug}] {len(proposal['spans'])} proposed spans, "
            f"{len(proposal['auditItems'])} audit notes"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
