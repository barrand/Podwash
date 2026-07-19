#!/usr/bin/env python3
"""Reconcile independent Codex and gpt-oss ad proposals for human review."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional


ROOT = Path(__file__).resolve().parents[1]
SHOW_DIR = ROOT / "tmp" / "ad-eval" / "cougar-sports"
LABELS = {
    "paid_dai",
    "paid_baked_in",
    "paid_host_read",
    "network_promo",
    "membership_cta",
}
RANK = {"low": 0, "medium": 1, "high": 2}


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_json(path: Path, payload: Any) -> None:
    encoded = (json.dumps(payload, ensure_ascii=False, indent=2) + "\n").encode()
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


def normalized_candidate(
    raw: dict[str, Any],
    source: str,
    word_count: int,
) -> Optional[dict[str, Any]]:
    try:
        start = int(raw["startWord"])
        end = int(raw["endWord"])
    except (KeyError, TypeError, ValueError):
        return None
    label = str(raw.get("label") or "")
    if start < 0 or end <= start or end > word_count or label not in LABELS:
        return None
    confidence = str(raw.get("confidence") or "medium").lower()
    if confidence not in RANK:
        confidence = "medium"
    return {
        "startWord": start,
        "endWord": end,
        "label": label,
        "advertiser": str(raw.get("advertiser") or "").strip(),
        "confidence": confidence,
        "rationale": str(
            raw.get("rationale") or raw.get("note") or ""
        ).strip(),
        "source": source,
    }


def overlap(left: dict[str, Any], right: dict[str, Any]) -> int:
    return max(
        0,
        min(int(left["endWord"]), int(right["endWord"]))
        - max(int(left["startWord"]), int(right["startWord"])),
    )


def overlap_fraction(left: dict[str, Any], right: dict[str, Any]) -> float:
    common = overlap(left, right)
    shortest = min(
        int(left["endWord"]) - int(left["startWord"]),
        int(right["endWord"]) - int(right["startWord"]),
    )
    return common / shortest if shortest else 0.0


def matching_index(
    candidate: dict[str, Any],
    choices: list[dict[str, Any]],
    used: set[int],
) -> Optional[int]:
    scored = [
        (overlap_fraction(candidate, choice), index)
        for index, choice in enumerate(choices)
        if index not in used
    ]
    if not scored:
        return None
    score, index = max(scored)
    return index if score >= 0.4 else None


def audit_record(
    start: int,
    end: int,
    reason: str,
    word_count: int,
) -> dict[str, Any]:
    return {
        "startWord": max(0, min(word_count - 1, start)),
        "endWord": max(1, min(word_count, end)),
        "reason": reason,
    }


def is_covered(index: int, spans: list[dict[str, Any]]) -> bool:
    return any(
        int(span["startWord"]) <= index < int(span["endWord"])
        for span in spans
    )


def commercial_cue_audits(
    words: list[dict[str, Any]],
    spans: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    tokens = [str(word.get("word") or "").lower().strip() for word in words]
    url_cues = {
        index
        for index, token in enumerate(tokens)
        if ".com" in token
        or (
            token == "com"
            and index
            and tokens[index - 1] in {"dot", "."}
        )
    }
    sponsor_cues = {
        index
        for index, token in enumerate(tokens)
        if token.startswith("sponsor")
        or (
            token == "brought"
            and any(value == "by" for value in tokens[index : index + 6])
        )
    }
    cta_words = {
        "apply",
        "visit",
        "call",
        "shop",
        "subscribe",
        "donate",
        "offer",
        "offering",
        "discount",
        "promo",
    }
    audits: list[dict[str, Any]] = []
    for cue in sorted(url_cues | sponsor_cues):
        if is_covered(cue, spans):
            continue
        left = max(0, cue - 45)
        right = min(len(tokens), cue + 46)
        nearby = set(tokens[left:right])
        strong = cue in sponsor_cues or bool(nearby & cta_words)
        if not strong:
            continue
        audits.append(
            audit_record(
                left,
                right,
                "Strong sponsor/CTA/URL cue falls outside the reconciled spans.",
                len(words),
            )
        )
    return audits


def deduplicate_audits(
    audits: list[dict[str, Any]],
    word_count: int,
) -> list[dict[str, Any]]:
    kept: list[dict[str, Any]] = []
    for item in sorted(audits, key=lambda value: (value["startWord"], value["endWord"])):
        normalized = audit_record(
            int(item["startWord"]),
            int(item["endWord"]),
            str(item.get("reason") or "Inspect this possible missed ad."),
            word_count,
        )
        duplicate = next(
            (
                existing
                for existing in kept
                if overlap_fraction(normalized, existing) >= 0.65
            ),
            None,
        )
        if duplicate:
            if normalized["reason"] not in duplicate["reason"]:
                duplicate["reason"] += " " + normalized["reason"]
            continue
        kept.append(normalized)
    for index, item in enumerate(kept, 1):
        item["id"] = f"audit-{index}"
    return kept


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--transcript", type=Path, default=SHOW_DIR / "transcript.json")
    parser.add_argument("--codex", type=Path, required=True)
    parser.add_argument("--gpt-oss", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=SHOW_DIR / "proposal.json")
    args = parser.parse_args()

    words = json.loads(args.transcript.read_text(encoding="utf-8"))
    if not isinstance(words, list) or not words:
        raise SystemExit("transcript must be a non-empty word array")
    transcript_hash = file_sha256(args.transcript)
    sources: dict[str, dict[str, Any]] = {}
    candidates: dict[str, list[dict[str, Any]]] = {}
    possible_misses: dict[str, list[dict[str, Any]]] = {}

    for source, path in (("codex", args.codex), ("gpt-oss", args.gpt_oss)):
        payload = json.loads(path.read_text(encoding="utf-8"))
        if str(payload.get("transcriptSha256") or "") != transcript_hash:
            raise SystemExit(f"{source} proposal is stale for this transcript")
        candidates[source] = [
            candidate
            for raw in payload.get("spans") or []
            if isinstance(raw, dict)
            if (
                candidate := normalized_candidate(raw, source, len(words))
            )
        ]
        possible_misses[source] = [
            raw
            for raw in payload.get("possibleMisses") or []
            if isinstance(raw, dict)
        ]
        sources[source] = {
            "fileSha256": file_sha256(path),
            "model": str(payload.get("model") or source),
            "spanCount": len(candidates[source]),
        }

    visible: list[dict[str, Any]] = []
    audits: list[dict[str, Any]] = []
    used_gpt: set[int] = set()

    for codex in candidates["codex"]:
        gpt_index = matching_index(codex, candidates["gpt-oss"], used_gpt)
        gpt = candidates["gpt-oss"][gpt_index] if gpt_index is not None else None
        if gpt_index is not None:
            used_gpt.add(gpt_index)

        if RANK[codex["confidence"]] >= RANK["medium"]:
            chosen = {**codex, "modelSupport": ["codex"]}
            if gpt:
                chosen["modelSupport"].append("gpt-oss")
            visible.append(chosen)
        elif gpt and RANK[gpt["confidence"]] >= RANK["medium"]:
            visible.append({**gpt, "modelSupport": ["codex", "gpt-oss"]})
        else:
            audits.append(
                audit_record(
                    codex["startWord"],
                    codex["endWord"],
                    "Codex flagged a low-confidence possible ad but did not mark it.",
                    len(words),
                )
            )

        if not gpt:
            audits.append(
                audit_record(
                    codex["startWord"],
                    codex["endWord"],
                    "Codex marked this region; gpt-oss did not.",
                    len(words),
                )
            )
        elif (
            codex["label"] != gpt["label"]
            or abs(codex["startWord"] - gpt["startWord"]) > 5
            or abs(codex["endWord"] - gpt["endWord"]) > 5
        ):
            audits.append(
                audit_record(
                    min(codex["startWord"], gpt["startWord"]),
                    max(codex["endWord"], gpt["endWord"]),
                    "Models disagree on this label or exact boundary.",
                    len(words),
                )
            )

    for index, gpt in enumerate(candidates["gpt-oss"]):
        if index in used_gpt:
            continue
        if RANK[gpt["confidence"]] >= RANK["high"]:
            visible.append({**gpt, "modelSupport": ["gpt-oss"]})
        audits.append(
            audit_record(
                gpt["startWord"],
                gpt["endWord"],
                "gpt-oss flagged this region; Codex did not.",
                len(words),
            )
        )

    visible.sort(key=lambda item: (item["startWord"], item["endWord"]))
    non_overlapping: list[dict[str, Any]] = []
    for candidate in visible:
        collision = next(
            (existing for existing in non_overlapping if overlap(candidate, existing)),
            None,
        )
        if collision:
            audits.append(
                audit_record(
                    min(candidate["startWord"], collision["startWord"]),
                    max(candidate["endWord"], collision["endWord"]),
                    "Candidate creatives overlap; inspect and split the exact boundary.",
                    len(words),
                )
            )
            if "codex" in candidate["modelSupport"] and "codex" not in collision["modelSupport"]:
                non_overlapping.remove(collision)
                non_overlapping.append(candidate)
            continue
        non_overlapping.append(candidate)
    visible = sorted(non_overlapping, key=lambda item: item["startWord"])

    for source_items in possible_misses.values():
        for raw in source_items:
            try:
                audits.append(
                    audit_record(
                        int(raw["startWord"]),
                        int(raw["endWord"]),
                        str(raw.get("reason") or "A model left this commercial-looking region unmarked."),
                        len(words),
                    )
                )
            except (KeyError, TypeError, ValueError):
                continue
    audits.extend(commercial_cue_audits(words, visible))
    if not any(span["startWord"] < 220 for span in visible):
        audits.append(
            audit_record(
                0,
                min(220, len(words)),
                "No ad was marked near the cold open; verify the episode really starts with content.",
                len(words),
            )
        )
    if not any(span["endWord"] > len(words) - 220 for span in visible):
        audits.append(
            audit_record(
                max(0, len(words) - 220),
                len(words),
                "No ad was marked near the ending; verify the closing region.",
                len(words),
            )
        )

    proposal_spans: list[dict[str, Any]] = []
    for index, candidate in enumerate(visible, 1):
        proposal_spans.append(
            {
                "id": f"proposal-{index}",
                "startWord": candidate["startWord"],
                "endWord": candidate["endWord"],
                "label": candidate["label"],
                "advertiser": candidate["advertiser"],
                "note": candidate["rationale"],
                "confidence": candidate["confidence"],
                "modelSupport": candidate["modelSupport"],
            }
        )

    output = {
        "schemaVersion": 1,
        "showSlug": "cougar-sports",
        "transcriptSha256": transcript_hash,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "sources": sources,
        "spans": proposal_spans,
        "auditItems": deduplicate_audits(audits, len(words)),
    }
    atomic_json(args.output, output)
    print(
        f"wrote {len(proposal_spans)} visible proposals and "
        f"{len(output['auditItems'])} audit items to {args.output}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
