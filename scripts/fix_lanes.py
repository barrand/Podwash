#!/usr/bin/env python3
"""Deterministic fix lanes + worker handoff helpers (observation-first routing).

High-confidence lanes short-circuit the LLM referee on both tier-2 and full-suite
fix paths. Hard cases (crash, ui_race, generic assertion, unknown) still go
through the referee.
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

FIX_WORKER_ROLES = frozenset({"Engineer", "QA", "Architect"})

_ADR_CITATION_RE = re.compile(
    r"ADR-\d+.*must cite|must cite committed (?:precision|recall|benchmark)|"
    r"decision artifact|ADR-\d+\s+missing",
    re.IGNORECASE,
)

_HANDOFF_RE = re.compile(
    r"^HANDOFF:\s*scope=(ok|out_of_scope);\s*route=(loop|QA|Engineer|Architect);\s*"
    r"applied=(yes|no)\s*$",
    re.IGNORECASE | re.MULTILINE,
)


@dataclass(frozen=True)
class FixLane:
    """Deterministic routing decision — skip referee when present."""

    lane_id: str
    role: str  # Engineer | QA | Architect
    instruction: str
    hypothesis: str
    fix_scope: str  # app | tests | docs


@dataclass(frozen=True)
class WorkerHandoff:
    scope: str  # ok | out_of_scope
    route: str  # loop | QA | Engineer | Architect
    applied: str  # yes | no


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
            "fixture (±0.001); do not edit app/tests"
        )
    return (
        "fill docs/adr/NNN § Benchmark results from committed fixture "
        "(±0.001); do not edit app/tests"
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


def fix_scope_for_role(role: str) -> str:
    if role == "QA":
        return "tests"
    if role == "Architect":
        return "docs"
    return "app"


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

    Priority: packaging → expectation_api → artifact_fixture → adr_citation → build.
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

    if is_adr_citation_failure(combined):
        hint = extract_adr_citation_hint(combined)
        return FixLane(
            lane_id="adr_citation",
            role="Architect",
            instruction=(
                "ADR citation lane: the slice decision artifact (ADR) must cite "
                "committed benchmark precision/recall (±0.001) and the approach "
                "string from the fixture. Edit only docs/adr/** — update "
                f"§ Benchmark results. {hint}. Do not edit app or test code. "
                "Do not run verify."
            ),
            hypothesis=(
                pkt_hyp
                or "ADR benchmark table still pending — fill from committed artifact"
            ),
            fix_scope="docs",
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
        if role == "Architect":
            ok = p.startswith("docs/adr/") or "/docs/adr/" in p.replace("\\", "/")
        elif role == "Engineer":
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
    """Set-difference plus paths that were dirty before and changed on disk.

    Slice 19: Architect edited already-untracked ``docs/adr/013-*.md``; plain
    set-difference looked like NO-EDIT and burned the fix budget.
    """
    added = set(after) - set(baseline)
    changed: set[str] = set()
    if fingerprints_before:
        for p in set(baseline) & set(after):
            before = fingerprints_before.get(p, "")
            if before and path_fingerprint(repo_root, p) != before:
                changed.add(p)
    return sorted(added | changed)


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
    elif route_raw.lower() == "architect":
        route = "Architect"
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
        flip = alternate_fix_role(current_role)
        if h.route in ("QA", "Engineer", "Architect"):
            flip = h.route
        if flip == current_role:
            flip = alternate_fix_role(current_role, skip=current_role)
        return flip, f"HANDOFF FLIP: out_of_scope → {flip}"
    if h.route in ("QA", "Engineer", "Architect") and h.route != current_role:
        return h.route, f"HANDOFF FLIP: route={h.route}"
    return None, ""


def opposite_role(role: str) -> str:
    return "QA" if role == "Engineer" else "Engineer"


def alternate_fix_role(
    role: str,
    *,
    skip: str | None = None,
    lane: FixLane | None = None,
) -> str:
    """Next fix worker when flipping after no-edit or out-of-scope handoff.

    Default rotation is Engineer ↔ QA only. Architect is reserved for the
    ``adr_citation`` lane (or an explicit ``HANDOFF: route=Architect``). Slice 19
    burned a fix attempt sending Architect at a Settings UITest via QA no-edit.
    """
    if lane is not None and lane.lane_id == "adr_citation":
        if skip == "Architect":
            return opposite_role(role) if role in ("Engineer", "QA") else "Engineer"
        return "Architect"
    if role == "QA":
        nxt = "Engineer"
    elif role == "Engineer":
        nxt = "QA"
    else:
        # Architect / unknown on a non-ADR failure → Engineer owns app/UI fallout
        nxt = "Engineer"
    if skip and nxt == skip:
        nxt = "QA" if nxt == "Engineer" else "Engineer"
    return nxt


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
