#!/usr/bin/env python3
"""Factory v3 — failure signature / progress / thrash contract.

See docs/plans/factory-v3-mechanic.md § Phase 2 signature contract.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Iterable, Sequence

OSCILLATION_WINDOW = 4
NO_PROGRESS_HALT = 2
DEFAULT_MAX_MECHANIC_SPAWNS = 8
DEFAULT_FIX_LOOP_MINUTES = 45

_TEST_TARGET_PREFIXES = (
    "PodWash/PodWashTests/",
    "PodWash/PodWashUITests/",
    "PodWash/PodWashSlowTests/",
)
_APP_PREFIX = "PodWash/PodWash/"
_ADR_PREFIX = "docs/adr/"

_FAILURE_CLASSES = frozenset(
    {
        "build",
        "build_error",
        "assert",
        "assertion",
        "ui_race",
        "crash",
        "stress_flake",
        "infra",
        "flake",
        "fixture_artifact",
        "packaging",
        "unknown",
    }
)


def normalize_failure_class(raw: str | None) -> str:
    """Map packet / outcome labels onto the v3 class vocabulary."""
    c = (raw or "unknown").strip().lower()
    if c in ("build_error", "build"):
        return "build"
    if c in ("assertion", "assert"):
        return "assert"
    if c == "fixture_artifact":
        return "assert"
    if c in _FAILURE_CLASSES:
        return c
    return "unknown"


def extract_test_ids(failures: Sequence[str] | None) -> list[str]:
    """Pull XCTest-style ids from failure strings when present."""
    ids: list[str] = []
    seen: set[str] = set()
    for f in failures or []:
        f = (f or "").strip()
        if not f:
            continue
        # Prefer already-canonical ids (Target/Class/test())
        if "/" in f and ("test" in f.lower() or "Test" in f):
            # Strip leading labels like "failed: "
            m = re.search(
                r"((?:PodWash(?:Tests|UITests|SlowTests)/)?[\w.]+/[\w.]+(?:\(\))?)",
                f,
            )
            cand = m.group(1) if m else f.split(":", 1)[-1].strip()
        else:
            cand = f
        key = cand.lower()
        if key not in seen:
            seen.add(key)
            ids.append(cand)
    return ids


def make_failure_signature(
    *,
    test_ids: Sequence[str] | None = None,
    failures: Sequence[str] | None = None,
    failure_class: str | None = None,
    stress_flake: bool = False,
) -> str:
    """Canonical signature: sorted test ids + normalized class.

    Empty failing set → "" (green / no signature).
    """
    ids = list(test_ids or [])
    if not ids and failures:
        ids = extract_test_ids(failures)
    ids = sorted({re.sub(r"\s+", " ", i.strip()) for i in ids if i and i.strip()})
    if not ids and not stress_flake and normalize_failure_class(failure_class) in (
        "unknown",
        "",
    ):
        # Build/infra with no test ids still needs a signature for progress.
        cls = normalize_failure_class(failure_class)
        if cls in ("unknown",) and not failures:
            return ""
    cls = "stress_flake" if stress_flake else normalize_failure_class(failure_class)
    if not ids and cls in ("unknown",) and failures:
        # Fall back to truncated failure text so build errors still progress.
        blob = sorted(
            {
                re.sub(r"\s+", " ", (f or "").strip().lower())[:80]
                for f in failures
                if f and f.strip()
            }
        )[:5]
        if not blob:
            return ""
        return f"{'|'.join(blob)}::{cls}"
    if not ids and cls == "unknown":
        return ""
    id_part = "|".join(ids) if ids else "(no-tests)"
    return f"{id_part}::{cls}"


def failure_count_from_signature(sig: str) -> int:
    if not sig:
        return 0
    id_part = sig.rsplit("::", 1)[0]
    if id_part == "(no-tests)":
        return 1
    return len([p for p in id_part.split("|") if p])


def test_ids_from_signature(sig: str) -> set[str]:
    if not sig:
        return set()
    id_part = sig.rsplit("::", 1)[0]
    if id_part == "(no-tests)":
        return set()
    return {p for p in id_part.split("|") if p}


def is_progress(
    prev_sig: str,
    new_sig: str,
    *,
    prev_count: int | None = None,
    new_count: int | None = None,
) -> bool:
    """True when signature set changed or failure count strictly dropped."""
    if not prev_sig and new_sig:
        return True  # first observation after green→red is not "progress" for halt
    if prev_sig != new_sig:
        return True
    pc = prev_count if prev_count is not None else failure_count_from_signature(prev_sig)
    nc = new_count if new_count is not None else failure_count_from_signature(new_sig)
    return nc < pc


def is_no_progress(
    new_sig: str,
    history: Sequence[str],
    *,
    window: int = OSCILLATION_WINDOW,
) -> bool:
    """Identical to previous, or equals any signature in the last *window* cycles."""
    if not history:
        return False
    if new_sig == history[-1]:
        return True
    recent = list(history[-window:])
    # Oscillation: seen before in window (excluding comparing only to immediate
    # prev which already returned True above — still count earlier repeats).
    return new_sig in recent[:-1]


def jaccard(a: set[str], b: set[str]) -> float:
    if not a and not b:
        return 1.0
    if not a or not b:
        return 0.0
    inter = len(a & b)
    union = len(a | b)
    return inter / union if union else 0.0


def same_resume_family(sig_a: str, sig_b: str) -> bool:
    """Same family iff Jaccard ≥ 0.5 or symmetric difference ≤ 1 test id."""
    if not sig_a or not sig_b:
        return False
    # Class must match for family (stress_flake vs assert are different families).
    cls_a = sig_a.rsplit("::", 1)[-1]
    cls_b = sig_b.rsplit("::", 1)[-1]
    if cls_a != cls_b:
        return False
    a = test_ids_from_signature(sig_a)
    b = test_ids_from_signature(sig_b)
    if not a and not b:
        return sig_a == sig_b
    if jaccard(a, b) >= 0.5:
        return True
    return len(a.symmetric_difference(b)) <= 1


def is_test_path(path: str) -> bool:
    p = (path or "").replace("\\", "/")
    return any(p.startswith(pref) for pref in _TEST_TARGET_PREFIXES) or "/Fixtures/" in p


def is_app_path(path: str) -> bool:
    p = (path or "").replace("\\", "/")
    return p.startswith(_APP_PREFIX) and "Tests" not in p.split("/")[1:2]


def is_adr_path(path: str) -> bool:
    p = (path or "").replace("\\", "/")
    return p.startswith(_ADR_PREFIX) or "/docs/adr/" in p


def classify_fix_paths(
    paths: Iterable[str],
) -> tuple[list[str], list[str], list[str], list[str]]:
    """Return (tests, apps, adrs, other)."""
    tests: list[str] = []
    apps: list[str] = []
    adrs: list[str] = []
    other: list[str] = []
    for raw in paths:
        p = (raw or "").strip()
        if not p:
            continue
        if is_adr_path(p):
            adrs.append(p)
        elif is_test_path(p):
            tests.append(p)
        elif p.startswith(_APP_PREFIX):
            apps.append(p)
        else:
            other.append(p)
    return tests, apps, adrs, other


def needs_test_diff_review(paths: Iterable[str]) -> bool:
    """Any non-trivial test-target path → QA readonly review."""
    return bool(classify_fix_paths(paths)[0])


def needs_adr_diff_review(paths: Iterable[str]) -> bool:
    return bool(classify_fix_paths(paths)[2])


def is_harness_delta(paths: Iterable[str]) -> bool:
    """Test wait/query/setup edits count as harness delta for stress_flake thrash."""
    return any(is_test_path(p) for p in paths)


@dataclass
class ProgressTracker:
    """Progress-based stop rule for the Mechanic fix loop."""

    max_spawns: int = DEFAULT_MAX_MECHANIC_SPAWNS
    max_minutes: float = DEFAULT_FIX_LOOP_MINUTES
    window: int = OSCILLATION_WINDOW
    no_progress_limit: int = NO_PROGRESS_HALT

    spawns_used: int = 0
    started_at: float = 0.0
    signature_history: list[str] = field(default_factory=list)
    consecutive_no_progress: int = 0
    consecutive_stress_flake_no_harness: int = 0
    consecutive_blocked_reviews: int = 0
    attempt_notes: list[str] = field(default_factory=list)
    levers_tried: list[str] = field(default_factory=list)
    flake_cold_retried: bool = False
    cumulative_delta: list[str] = field(default_factory=list)
    last_signature: str = ""
    last_in_scope_delta: list[str] = field(default_factory=list)
    last_hypothesis: str = ""

    def start(self, now: float) -> None:
        self.started_at = now

    def elapsed_minutes(self, now: float) -> float:
        if not self.started_at:
            return 0.0
        return (now - self.started_at) / 60.0

    def at_hard_cap(self, now: float) -> bool:
        return (
            self.spawns_used >= self.max_spawns
            or self.elapsed_minutes(now) >= self.max_minutes
        )

    def record_spawn(self) -> int:
        self.spawns_used += 1
        return self.spawns_used

    def observe_signature(
        self,
        sig: str,
        *,
        failure_count: int | None = None,
    ) -> tuple[bool, str]:
        """Return (should_continue, console_line).

        Call *after* a Mechanic cycle's re-verify (or stress_flake observation).
        First signature after loop start seeds history without counting as thrash.
        """
        if not self.signature_history:
            self.signature_history.append(sig)
            self.last_signature = sig
            self.consecutive_no_progress = 0
            return True, (
                f"PROGRESS: initial signature ({failure_count_from_signature(sig)} "
                f"failures) — continuing (cycle {self.spawns_used}, cap {self.max_spawns})"
            )

        prev = self.signature_history[-1]
        prev_n = failure_count_from_signature(prev)
        new_n = (
            failure_count
            if failure_count is not None
            else failure_count_from_signature(sig)
        )

        if is_no_progress(sig, self.signature_history, window=self.window):
            self.consecutive_no_progress += 1
            if sig == prev:
                line = (
                    f"NO PROGRESS {self.consecutive_no_progress}/{self.no_progress_limit}: "
                    f"identical signature after Mechanic cycle"
                )
            else:
                line = (
                    f"NO PROGRESS {self.consecutive_no_progress}/{self.no_progress_limit}: "
                    f"signature seen in window (oscillation)"
                )
            self.signature_history.append(sig)
            self.last_signature = sig
            return False, line

        if is_progress(prev, sig, prev_count=prev_n, new_count=new_n):
            self.consecutive_no_progress = 0
            self.signature_history.append(sig)
            self.last_signature = sig
            return True, (
                f"PROGRESS: signature changed ({prev_n} failures → {new_n}) — "
                f"continuing (cycle {self.spawns_used}, cap {self.max_spawns})"
            )

        # Same signature, same count — no progress
        self.consecutive_no_progress += 1
        self.signature_history.append(sig)
        self.last_signature = sig
        return False, (
            f"NO PROGRESS {self.consecutive_no_progress}/{self.no_progress_limit}: "
            f"identical signature after Mechanic cycle"
        )

    def thrash_halt(self) -> bool:
        return self.consecutive_no_progress >= self.no_progress_limit

    def observe_stress_flake(self, *, had_harness_delta: bool) -> tuple[bool, str]:
        """Return (should_continue, line). 2 no-harness stress_flake → thrash."""
        if had_harness_delta:
            self.consecutive_stress_flake_no_harness = 0
            return True, "PROGRESS: stress_flake with harness delta — continuing"
        self.consecutive_stress_flake_no_harness += 1
        line = (
            f"NO PROGRESS stress_flake {self.consecutive_stress_flake_no_harness}/2: "
            f"no harness delta"
        )
        return self.consecutive_stress_flake_no_harness < 2, line

    def stress_flake_thrash(self) -> bool:
        return self.consecutive_stress_flake_no_harness >= 2

    def observe_review(self, *, cleared: bool) -> tuple[bool, str]:
        """Return (should_continue, line). 2 blocked reviews → halt."""
        if cleared:
            self.consecutive_blocked_reviews = 0
            return True, "REVIEW: cleared"
        self.consecutive_blocked_reviews += 1
        line = (
            f"REVIEW BLOCKED {self.consecutive_blocked_reviews}/2"
        )
        return self.consecutive_blocked_reviews < 2, line

    def review_thrash(self) -> bool:
        return self.consecutive_blocked_reviews >= 2

    def merge_delta(self, paths: Iterable[str]) -> None:
        seen = set(self.cumulative_delta)
        for p in paths:
            p = (p or "").strip()
            if p and p not in seen:
                seen.add(p)
                self.cumulative_delta.append(p)
        self.last_in_scope_delta = [p for p in paths if p]


def thrash_halt_message(
    tracker: ProgressTracker,
    *,
    last: str = "",
) -> str:
    sig = tracker.last_signature
    return (
        f"THRASH HALT: no progress {tracker.consecutive_no_progress}/"
        f"{tracker.no_progress_limit} on sig={sig[:80]}; "
        f"cycles={tracker.spawns_used}/{tracker.max_spawns}"
        + (f"; last={last}" if last else "")
    )
