#!/usr/bin/env python3
"""Deterministic fix-lane hints for the Mechanic (Factory v3).

Lanes are **optional prompt recipes** — they never route roles. The Mechanic
may ignore a wrong hint. See docs/plans/factory-v3-mechanic.md.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass
from typing import Iterable

from failure_packet import (
    FailurePacket,
    extract_artifact_regeneration_hint,
    is_artifact_fixture_failure,
    is_expectation_api_violation,
)
from sim_hygiene import is_missing_bundle_executable

DETERMINISTIC_LANES = frozenset(
    {"packaging", "expectation_api", "artifact_fixture", "adr_citation", "build"}
)

# Mechanic is the only fix worker in v3; kept for progress/event tagging.
FIX_WORKER_ROLES = frozenset({"Mechanic"})

_ADR_CITATION_RE = re.compile(
    r"ADR-\d+.*must cite|must cite committed (?:precision|recall|benchmark)|"
    r"decision artifact|ADR-\d+\s+missing",
    re.IGNORECASE,
)


@dataclass(frozen=True)
class FixLane:
    """Optional recipe hint for the Mechanic prompt (not a role router)."""

    lane_id: str
    instruction: str
    hypothesis: str
    # Historical field — ignored for routing; kept for prompt/context only.
    suggested_scope: str = "any"  # app | tests | docs | any


def is_adr_citation_failure(blob: str) -> bool:
    """True when verify failed because an ADR lacks committed benchmark numbers."""
    return bool(_ADR_CITATION_RE.search(blob or ""))


def extract_adr_citation_hint(blob: str) -> str:
    """Console hint for adr_citation lane."""
    m = re.search(r"ADR-(\d+)", blob or "", re.IGNORECASE)
    if m:
        num = int(m.group(1))
        return (
            f"fill docs/adr/{num:03d}-*.md § Benchmark results from committed "
            "fixture (±0.001)"
        )
    return (
        "fill docs/adr/NNN § Benchmark results from committed fixture (±0.001)"
    )


def extract_adr_doc_paths(blob: str, slice_files: list[str]) -> list[str]:
    """Suggest ADR paths for adr_citation fixes."""
    from_slice = [f for f in slice_files if f.startswith("docs/adr/")]
    if from_slice:
        return from_slice
    m = re.search(r"ADR-(\d+)", blob or "", re.IGNORECASE)
    if m:
        num = int(m.group(1))
        prefix = f"docs/adr/{num:03d}-"
        return [f"{prefix}*.md"]
    return ["docs/adr/"]


def _packet_blob(packet: FailurePacket | None) -> str:
    if packet is None:
        return ""
    return "\n".join(
        list(packet.raw_failures or [])
        + list(packet.assertions or [])
        + list(packet.crashes or [])
    )


def classify_fix_lane(
    *,
    blob: str = "",
    packet: FailurePacket | None = None,
    is_build: bool = False,
    escalate_expectation: bool = False,
) -> FixLane | None:
    """Return an optional FixLane recipe, or None when no deterministic hint.

    Priority: packaging → expectation_api → artifact_fixture → adr_citation → build.
    """
    combined = "\n".join(p for p in (blob, _packet_blob(packet)) if p)
    pkt_hyp = (packet.hypothesis if packet else "") or ""

    if is_missing_bundle_executable(combined):
        return FixLane(
            lane_id="packaging",
            instruction=(
                "Suggested recipe (optional — ignore if wrong): packaging failure — "
                "restore a valid PodWash.app bundle executable "
                "(do not delete the app target @main entry point)."
            ),
            hypothesis="App target missing/broken executable or installable product",
            suggested_scope="app",
        )

    if is_expectation_api_violation(combined):
        if escalate_expectation:
            instruction = (
                "Suggested recipe (optional — ignore if wrong): Lever 1 — replace the "
                "KVO wait with expectation(for: NSPredicate, evaluatedWith:) on "
                "timeControlStatus == .playing. Do NOT use observe(\\.timeControlStatus) "
                "— setRate re-notifies status while still .playing and a live "
                "observer double-fulfills. No long-lived KVO across the rate loop. "
                "Do not weaken AC."
            )
            sig = (packet.signature if packet else "") or "expectation"
            hypothesis = f"ledger-escalate:predicate-wait:{sig[:50]}"
        else:
            instruction = (
                "Suggested recipe (optional — ignore if wrong): XCTestExpectation "
                "double-fulfill (KVO). Lever 0: wait only until playing, then "
                "invalidate the observation BEFORE any further player mutation "
                "(setRate / pause / play). Never leave KVO alive across the rate "
                "loop. Do not weaken AC thresholds."
            )
            hypothesis = (
                pkt_hyp
                or "Test harness: live KVO across setRate double-fulfills expectation"
            )
        return FixLane(
            lane_id="expectation_api",
            instruction=instruction,
            hypothesis=hypothesis,
            suggested_scope="tests",
        )

    if is_artifact_fixture_failure(combined):
        regen = extract_artifact_regeneration_hint(combined)
        regen_line = f" Command: {regen}." if regen else ""
        return FixLane(
            lane_id="artifact_fixture",
            instruction=(
                "Suggested recipe (optional — ignore if wrong): committed "
                "benchmark-results.json (or related execution evidence) is missing, "
                "stale, or unparsable. Regenerate via the slow test named in the "
                "failure message, commit under PodWashTests/Fixtures/."
                f"{regen_line} Do not weaken AC thresholds."
            ),
            hypothesis=(
                pkt_hyp or "Committed execution-evidence artifact missing or stale"
            ),
            suggested_scope="tests",
        )

    if is_adr_citation_failure(combined):
        hint = extract_adr_citation_hint(combined)
        return FixLane(
            lane_id="adr_citation",
            instruction=(
                "Suggested recipe (optional — ignore if wrong): ADR must cite "
                "committed benchmark precision/recall (±0.001) and the approach "
                f"string from the fixture. Update docs/adr/** § Benchmark results. "
                f"{hint}."
            ),
            hypothesis=(
                pkt_hyp
                or "ADR benchmark table still pending — fill from committed artifact"
            ),
            suggested_scope="docs",
        )

    if is_build:
        return FixLane(
            lane_id="build",
            instruction=(
                "Suggested recipe (optional — ignore if wrong): compile/link red — "
                "fix app or project sources so the scheme builds. Do not edit tests "
                "only to silence compile errors."
            ),
            hypothesis=pkt_hyp or "Build/compile failure — restore a green build",
            suggested_scope="app",
        )

    return None


def git_delta(baseline: set[str], after: set[str]) -> list[str]:
    """Paths present after the worker that were not in the baseline snapshot."""
    return sorted(after - baseline)


def path_fingerprint(repo_root: str, rel: str) -> str:
    """Cheap content proxy (mtime_ns + size) for already-dirty path detection."""
    path = os.path.join(repo_root, rel)
    try:
        st = os.stat(path)
        return f"{st.st_mtime_ns}:{st.st_size}"
    except OSError:
        return ""


def snapshot_path_fingerprints(
    repo_root: str, paths: Iterable[str]
) -> dict[str, str]:
    """Fingerprint dirty paths before a worker so in-place edits count as delta."""
    out: dict[str, str] = {}
    for p in paths:
        p = (p or "").strip()
        if p:
            out[p] = path_fingerprint(repo_root, p)
    return out


def git_delta_with_fingerprints(
    baseline: set[str],
    after: set[str],
    *,
    repo_root: str,
    fingerprints_before: dict[str, str] | None = None,
) -> list[str]:
    """Set-difference plus paths that were dirty before and changed on disk."""
    added = set(after) - set(baseline)
    changed: set[str] = set()
    if fingerprints_before:
        for p in set(baseline) & set(after):
            before = fingerprints_before.get(p, "")
            if before and path_fingerprint(repo_root, p) != before:
                changed.add(p)
    return sorted(added | changed)


def format_attempt_note(
    *,
    attempt: int,
    role: str = "Mechanic",
    agent: str = "",
    files: list[str] | None = None,
    handoff: str = "",
    summary: str = "",
    hyp: str = "",
    status: str = "",
) -> str:
    """Rich attempt_notes line for the next Mechanic prompt."""
    parts = [f"attempt {attempt}: role={role}"]
    if agent:
        parts.append(f"agent={agent}")
    files = files or []
    parts.append(f"files=[{', '.join(files[:8])}]" if files else "files=[]")
    if handoff:
        parts.append(f"note={handoff}")
    if summary:
        parts.append(f"summary={summary[:120]}")
    elif hyp:
        parts.append(f"hyp={hyp[:60]}")
    if status:
        parts.append(f"status={status}")
    return " ".join(parts)


def suggested_files_for_lane(
    lane_id: str,
    packet: FailurePacket,
    slice_files: list[str],
) -> list[str]:
    """Pick suggested edit paths for a deterministic lane hint."""
    if lane_id == "adr_citation":
        blob = " ".join(
            list(packet.raw_failures or []) + list(packet.assertions or [])
        )
        return extract_adr_doc_paths(blob, slice_files) or ["docs/adr/"]
    src = list(packet.suggested_files or []) + list(slice_files)
    if lane_id in ("expectation_api", "artifact_fixture"):
        picked = [f for f in src if "Tests" in f or "Fixtures" in f]
        return picked or [f for f in slice_files if "Tests" in f or "Fixtures" in f]
    picked = [
        f
        for f in src
        if f.startswith("PodWash/PodWash/") and "Tests" not in f
    ]
    if lane_id == "packaging" and not picked:
        return ["PodWash/PodWash/PodWashApp.swift"]
    return picked or [f for f in slice_files if "Tests" not in f]
