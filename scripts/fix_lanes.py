#!/usr/bin/env python3
"""Deterministic fix lanes + worker handoff helpers (observation-first routing).

High-confidence lanes short-circuit the LLM referee on both tier-2 and full-suite
fix paths. Hard cases (crash, ui_race, generic assertion, unknown) still go
through the referee.
"""

from __future__ import annotations

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
    {"packaging", "expectation_api", "artifact_fixture", "build"}
)

_HANDOFF_RE = re.compile(
    r"^HANDOFF:\s*scope=(ok|out_of_scope);\s*route=(loop|QA|Engineer);\s*"
    r"applied=(yes|no)\s*$",
    re.IGNORECASE | re.MULTILINE,
)


@dataclass(frozen=True)
class FixLane:
    """Deterministic routing decision — skip referee when present."""

    lane_id: str
    role: str  # Engineer | QA
    instruction: str
    hypothesis: str
    fix_scope: str  # app | tests


@dataclass(frozen=True)
class WorkerHandoff:
    scope: str  # ok | out_of_scope
    route: str  # loop | QA | Engineer
    applied: str  # yes | no


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
    """Return a deterministic FixLane, or None when the referee should decide.

    Priority: packaging → expectation_api → artifact_fixture → build.
    """
    combined = "\n".join(
        p for p in (blob, _packet_blob(packet)) if p
    )
    pkt_hyp = (packet.hypothesis if packet else "") or ""

    if is_missing_bundle_executable(combined):
        return FixLane(
            lane_id="packaging",
            role="Engineer",
            instruction=(
                "Packaging failure: restore a valid PodWash.app bundle executable "
                "(do not delete the app target @main entry point). Do not edit tests."
            ),
            hypothesis="App target missing/broken executable or installable product",
            fix_scope="app",
        )

    if is_expectation_api_violation(combined):
        if escalate_expectation:
            instruction = (
                "Lever 1 (prior invalidate-KVO hyp failed): replace the KVO "
                "wait with expectation(for: NSPredicate, evaluatedWith:) on "
                "timeControlStatus == .playing. Do NOT use observe(\\.timeControlStatus) "
                "— setRate re-notifies status while still .playing and a live "
                "observer double-fulfills. No long-lived KVO across the rate loop. "
                "Do not weaken AC. Do not edit app."
            )
            sig = (packet.signature if packet else "") or "expectation"
            hypothesis = f"ledger-escalate:predicate-wait:{sig[:50]}"
        else:
            instruction = (
                "XCTestExpectation double-fulfill (KVO). Lever 0: wait only "
                "until playing, then invalidate the observation BEFORE any "
                "further player mutation (setRate / pause / play). Never leave "
                "KVO alive across the rate loop — the stack shows fulfill "
                "firing inside setRate when the observer is still registered. "
                "Do not weaken AC thresholds. Do not edit app code."
            )
            hypothesis = (
                pkt_hyp
                or "Test harness: live KVO across setRate double-fulfills expectation"
            )
        return FixLane(
            lane_id="expectation_api",
            role="QA",
            instruction=instruction,
            hypothesis=hypothesis,
            fix_scope="tests",
        )

    if is_artifact_fixture_failure(combined):
        regen = extract_artifact_regeneration_hint(combined)
        regen_line = f" Command: {regen}." if regen else ""
        return FixLane(
            lane_id="artifact_fixture",
            role="QA",
            instruction=(
                "Artifact/fixture lane: committed benchmark-results.json (or related "
                "execution evidence) is missing, stale, or unparsable. Regenerate via "
                "the slow test named in the failure message, commit under "
                "PodWashTests/Fixtures/, then stop — do not edit app code. Do not "
                f"weaken AC thresholds.{regen_line}"
            ),
            hypothesis=(
                pkt_hyp
                or "Committed execution-evidence artifact missing or stale"
            ),
            fix_scope="tests",
        )

    if is_build:
        return FixLane(
            lane_id="build",
            role="Engineer",
            instruction=(
                "Compile/link red (build lane). Fix app or project sources so the "
                "scheme builds. Do not edit tests to silence compile errors. "
                "Do not run verify."
            ),
            hypothesis=pkt_hyp or "Build/compile failure — restore a green build",
            fix_scope="app",
        )

    return None


def filter_paths_for_role(paths: Iterable[str], role: str) -> list[str]:
    """Keep paths the given role is allowed to edit."""
    out: list[str] = []
    seen: set[str] = set()
    for p in paths:
        p = (p or "").strip()
        if not p or p in seen:
            continue
        if role == "Engineer":
            # App target only — PodWash/PodWashTests does not match this prefix.
            ok = p.startswith("PodWash/PodWash/")
        else:
            ok = (
                p.startswith("PodWash/PodWashTests/")
                or p.startswith("PodWash/PodWashUITests/")
                or p.startswith("PodWash/PodWashSlowTests/")
                or "/Fixtures/" in p
            )
        if ok:
            seen.add(p)
            out.append(p)
    return out


def git_delta(baseline: set[str], after: set[str]) -> list[str]:
    """Paths present after the worker that were not in the baseline snapshot."""
    return sorted(after - baseline)


def parse_handoff_line(text: str) -> WorkerHandoff | None:
    """Parse optional ``HANDOFF: scope=…; route=…; applied=…`` from worker text."""
    m = _HANDOFF_RE.search(text or "")
    if not m:
        return None
    return normalize_handoff(
        WorkerHandoff(
            scope=m.group(1),
            route=m.group(2),
            applied=m.group(3),
        )
    )


def normalize_handoff(h: WorkerHandoff) -> WorkerHandoff:
    route_raw = (h.route or "loop").strip()
    if route_raw.lower() == "qa":
        route = "QA"
    elif route_raw.lower() == "engineer":
        route = "Engineer"
    else:
        route = "loop"
    return WorkerHandoff(
        scope=(h.scope or "ok").lower(),
        route=route,
        applied=(h.applied or "no").lower(),
    )


def resolve_handoff_flip(
    current_role: str,
    handoff: WorkerHandoff | None,
    in_scope_delta: list[str],
) -> tuple[str | None, str]:
    """Return (next_role_or_None, log_reason).

    Honor out_of_scope / explicit route only when the worker made no in-scope edits.
    """
    if handoff is None:
        return None, ""
    h = normalize_handoff(handoff)
    if in_scope_delta:
        return None, (
            "HANDOFF IGNORED: worker edited in-scope paths "
            f"({', '.join(in_scope_delta[:5])})"
        )
    if h.scope == "out_of_scope":
        flip = "QA" if current_role == "Engineer" else "Engineer"
        if h.route in ("QA", "Engineer"):
            flip = h.route
        if flip == current_role:
            flip = "QA" if current_role == "Engineer" else "Engineer"
        return flip, f"HANDOFF FLIP: out_of_scope → {flip}"
    if h.route in ("QA", "Engineer") and h.route != current_role:
        return h.route, f"HANDOFF FLIP: route={h.route}"
    return None, ""


def opposite_role(role: str) -> str:
    return "QA" if role == "Engineer" else "Engineer"


def format_attempt_note(
    *,
    attempt: int,
    role: str,
    agent: str = "",
    files: list[str] | None = None,
    handoff: str = "",
    summary: str = "",
    hyp: str = "",
    status: str = "",
) -> str:
    """Rich attempt_notes line for the next fix prompt."""
    parts = [f"attempt {attempt}: role={role}"]
    if agent:
        parts.append(f"agent={agent}")
    files = files or []
    parts.append(f"files=[{', '.join(files[:8])}]" if files else "files=[]")
    if handoff:
        parts.append(f"handoff={handoff}")
    if summary:
        parts.append(f"summary={summary[:120]}")
    elif hyp:
        parts.append(f"hyp={hyp[:60]}")
    if status:
        parts.append(f"status={status}")
    return " ".join(parts)
