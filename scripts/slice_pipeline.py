#!/usr/bin/env python3
"""PodWash slice pipeline — loop-as-orchestrator (Option B).

Python owns gate ordering, verify.sh, Mechanic fix cycles, Done-artifact writing, and
(optionally) commits. LLMs are one visible SDK worker per gate / fix attempt.

See docs/plans/loop-as-orchestrator-refactor.md and docs/slice-pipeline.md.
"""

from __future__ import annotations

import os
import re
import subprocess
import time
from dataclasses import dataclass, field
from typing import Any, Callable, Literal, Optional

from failure_packet import (
    FailurePacket,
    build_failure_packet,
    extract_artifact_regeneration_hint,
    extract_slice_swift_paths,
    format_stuck_card,
    is_artifact_fixture_failure,
    is_expectation_api_violation,
    is_flake_signal,
    is_valid_test_id,
    persist_stuck_card,
    slice_id_from_path,
)
from fix_lanes import (
    FIX_WORKER_ROLES,
    classify_fix_lane,
    extract_adr_citation_hint,
    extract_adr_doc_paths,
    format_attempt_note,
    git_delta,
    git_delta_with_fingerprints,
    snapshot_path_fingerprints,
    suggested_files_for_lane,
)
from factory_progress import (
    DEFAULT_MAX_MECHANIC_SPAWNS,
    ProgressTracker,
)
from mechanic_fix import (
    build_mechanic_prompt,
    commit_mechanic_deltas,
    run_fix_cycle,
)
from factory_events import EventLog, parse_summary_line
from factory_narrator import (
    CastLog,
    NameAssigner,
    narrate_coordinator_shift_open,
    narrate_coordinator_shift_prose,
    narrate_coordinator_shift_llm,
    parse_shift_narration_lines,
    print_coordinator_shift_banner,
    narrate_chapter_open,
    narrate_crash,
    narrate_exoneration,
    narrate_failure_detail,
    narrate_flake_confirmed,
    narrate_gate_cleared,
    narrate_gate_stuck,
    narrate_ledger_block,
    narrate_referee,
    narrate_role_report,
    extract_gate_stuck_body,
    narrate_slice_recap,
    narrate_thrash_halt,
    narrate_verify_red,
    narrate_worker_done,
)
from factory_floor_llm import (
    narrate_verify_green_dynamic,
    try_coordinator_shift_llm,
)
from hypothesis_ledger import (
    append_ledger,
    format_ledger_for_prompt,
    hypothesis_seen,
    load_ledger,
    make_entry,
    normalize_signature,
)
from session_bundle import write_session_bundle
from sdk_models import format_sdk_model, sdk_model_for_role, sdk_model_from_id
from sim_hygiene import (
    CrashWatchdog,
    classify_infra_failure,
    default_ips_roots,
    ensure_sim_booted,
    is_missing_bundle_executable,
    resolve_sim_udid,
    should_stress_run,
    stress_run_count,
)
from slice_loop_progress import (
    ThrashHalt,
    _implement_artifacts_exist,
    _mapped_test_files_exist,
    _path_exists,
    _plan_review_line,
    _read_slice_text,
    _review_cleared,
    _role_artifact_rows,
    _section_body,
    _status_from_text,
    _story_content_ok,
    _story_done,
    _verification_mapping_filled,
    architect_adr_path_from_slice,
    artifact_cell_satisfied,
    detect_simulator_crashes,
    detect_test_failures,
    enrich_build_failures,
    extract_build_error,
    extract_factory_config_error,
    is_factory_config_output,
    latest_xcresult_path,
    looks_like_build_failure,
    normalize_slice_adr_placeholders,
    summarize_ips_crash,
    missing_artifact_paths,
    parse_verify_result,
    read_failures_from_xcresult,
    story_pending_reasons,
    verify_is_green,
)

REPO_ROOT_DEFAULT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VERIFY_SH = os.path.join(REPO_ROOT_DEFAULT, "scripts", "verify.sh")
CHECK_ISOLATION = os.path.join(REPO_ROOT_DEFAULT, "scripts", "check-test-isolation.sh")
AGENTS_DIR = os.path.join(REPO_ROOT_DEFAULT, ".cursor", "agents")

DEFAULT_MAX_FIX_ATTEMPTS = DEFAULT_MAX_MECHANIC_SPAWNS  # alias — progress rule owns stop
DEFAULT_MAX_IMPLEMENT_VERIFY_RUNS = DEFAULT_MAX_MECHANIC_SPAWNS
# Sim install/launch/bootstrap cold retries — do not burn Mechanic spawn budget.
DEFAULT_MAX_TIER2_INFRA_RETRIES = 2

# Exit codes owned by the loop (slice_loop.py mirrors these).
EXIT_THRASH = 5
EXIT_INFRA = 6

# Plain SDK model ids — never scrape frontmatter bracket syntax.
# SDK path uses sdk_models.sdk_model_for_role() → ModelSelection(fast=false).
ROLE_MODELS: dict[str, str] = {
    "PM": "composer-2.5",
    "UX": "composer-2.5",
    "QA": "composer-2.5",
    "Architect": "grok-4.5",
    "Engineer": "grok-4.5",
    "PM review": "composer-2.5",
    "QA review": "composer-2.5",
    "Architect review": "grok-4.5",
    "Mechanic": "grok-4.5",
    "Coordinator": "composer-2.5",
}

ROLE_AGENT_FILES: dict[str, str] = {
    "PM": "podwash-pm.md",
    "UX": "podwash-ux.md",
    "QA": "podwash-qa.md",
    "Architect": "podwash-architect.md",
    "Engineer": "podwash-engineer.md",
    "PM review": "podwash-pm.md",
    "QA review": "podwash-qa.md",
    "Architect review": "podwash-architect.md",
    "Mechanic": "podwash-engineer.md",
}

# Reviewers + referee run in SDK plan mode (read-only). Authors/fixers use agent mode.
PLAN_MODE_ROLES = frozenset(
    {"PM review", "QA review", "Architect review", "Coordinator"}
)

GateId = Literal[
    "story",
    "architect",
    "ux",
    "adr_review_qa",
    "adr_review_pm",
    "test_spec",
    "test_review",
    "implement",
    "verify",
    "record",
    "commit",
]
GateStatus = Literal["pending", "done", "waived", "na"]

GATE_ORDER: tuple[GateId, ...] = (
    "story",
    "architect",
    "ux",
    "adr_review_qa",
    "adr_review_pm",
    "test_spec",
    "test_review",
    "implement",
    "verify",
    "record",
    "commit",
)

GATE_LABELS: dict[GateId, str] = {
    "story": "story",
    "architect": "architect",
    "ux": "ux",
    "adr_review_qa": "ADR review (QA)",
    "adr_review_pm": "ADR review (PM)",
    "test_spec": "test spec",
    "test_review": "test-spec review",
    "implement": "implement",
    "verify": "verify",
    "record": "record",
    "commit": "commit",
}

GATE_DEPS: dict[GateId, tuple[GateId, ...]] = {
    "story": (),
    "architect": ("story",),
    "ux": ("story",),
    "adr_review_qa": ("architect", "ux"),
    "adr_review_pm": ("architect", "ux"),
    "test_spec": ("adr_review_qa", "adr_review_pm"),
    "test_review": ("test_spec",),
    "implement": ("test_review",),
    "verify": ("implement",),
    "record": ("verify",),
    "commit": ("record",),
}

GATE_ROLE: dict[GateId, str] = {
    "story": "PM",
    "architect": "Architect",
    "ux": "UX",
    "adr_review_qa": "QA review",
    "adr_review_pm": "PM review",
    "test_spec": "QA",
    "test_review": "Architect review",
    "implement": "Engineer",
}

# Pre-implement gates: TDD compile-red expected; red-verify thrash + verify ban apply.
AUTHORING_GATES: frozenset[GateId] = frozenset(
    {
        "story",
        "architect",
        "ux",
        "adr_review_qa",
        "adr_review_pm",
        "test_spec",
        "test_review",
    }
)

LogFn = Callable[[str], None]


@dataclass(frozen=True)
class Gate:
    id: GateId
    label: str
    status: GateStatus
    applicable: bool

    @property
    def satisfied(self) -> bool:
        return (not self.applicable) or self.status in ("done", "waived")


@dataclass(frozen=True)
class GateState:
    slice_file: str
    slice_status: str
    gates: tuple[Gate, ...]

    def gate(self, gid: GateId) -> Gate:
        for g in self.gates:
            if g.id == gid:
                return g
        raise KeyError(gid)

    @property
    def applicable_gates(self) -> tuple[Gate, ...]:
        return tuple(g for g in self.gates if g.applicable)

    @property
    def done_count(self) -> int:
        return sum(1 for g in self.applicable_gates if g.satisfied)

    @property
    def total(self) -> int:
        return len(self.applicable_gates)

    @property
    def all_done(self) -> bool:
        return self.total > 0 and self.done_count == self.total

    @property
    def summary(self) -> str:
        nxt = next_gate(self)
        label = "done" if nxt is None else GATE_LABELS[nxt]
        bar = "█" * self.done_count + "░" * (self.total - self.done_count)
        return f"gates {self.done_count}/{self.total} {bar} · next: {label}"


@dataclass
class FixBudget:
    """Deprecated alias — Factory v3 uses ProgressTracker (progress-based stop)."""

    max_attempts: int = DEFAULT_MAX_FIX_ATTEMPTS
    attempts_used: int = 0
    last_signature: str = ""
    last_role: str = "Mechanic"
    last_packet: FailurePacket | None = None
    last_class: str = ""
    last_hypothesis: str = ""
    attempt_notes: list[str] = field(default_factory=list)
    last_lever_index: int = -1
    flake_cold_retried: bool = False
    levers_tried: list[str] = field(default_factory=list)

    @property
    def remaining(self) -> int:
        return max(0, self.max_attempts - self.attempts_used)

    def record(self, role: str, signature: str, *, note: str = "") -> None:
        self.attempts_used += 1
        self.last_role = role
        self.last_signature = signature
        if note:
            self.attempt_notes.append(note)

    def exhausted(self) -> bool:
        return self.attempts_used >= self.max_attempts

    def to_tracker(self) -> ProgressTracker:
        t = ProgressTracker(max_spawns=self.max_attempts)
        t.spawns_used = self.attempts_used
        t.last_signature = self.last_signature
        t.attempt_notes = list(self.attempt_notes)
        t.levers_tried = list(self.levers_tried)
        t.flake_cold_retried = self.flake_cold_retried
        t.last_hypothesis = self.last_hypothesis
        return t



@dataclass
class VerifyOutcome:
    result: dict[str, str] | None
    green: bool
    failures: list[str] = field(default_factory=list)
    crashes: list[str] = field(default_factory=list)
    output: str = ""
    elapsed_secs: float = 0.0
    packet: FailurePacket | None = None
    tier: int = 3


def resolve_tier2_slice_tests(slice_file: str, repo_root: str) -> list[str]:
    """Slice mapping test ids for tier-2 implement gate (excludes nightly rows)."""
    try:
        text = _read_slice_text(slice_file, repo_root)
    except OSError:
        text = ""
    return extract_mapped_test_ids(text, tier2=True)


def test_ids_for_tier1(packet: FailurePacket | None, failures: list[str]) -> list[str]:
    """Stable -only-testing: ids for tier-1 re-verify (failed tests first)."""
    ids: list[str] = []
    if packet:
        for tid in packet.test_ids:
            t = (tid or "").strip()
            if is_valid_test_id(t) and t not in ids:
                ids.append(t)
    if not ids:
        for f in failures or []:
            low = (f or "").lower()
            if low.startswith(("xcodebuild", "build_error:", "factory_config:")):
                continue
            # Prefer "Class/test()" prefix before em-dash detail
            head = re.split(r"\s+[—–-]\s+", f, maxsplit=1)[0].strip()
            if is_valid_test_id(head) and head not in ids:
                ids.append(head)
    return ids


def verify_env_for_tier(
    tier: int,
    *,
    failed_tests: list[str] | None = None,
    slice_tests: list[str] | None = None,
) -> dict[str, str]:
    """Environment overrides passed to scripts/verify.sh for a given tier."""
    env = {"VERIFY_TIER": str(tier)}
    if tier == 1:
        ids = failed_tests or []
        if not ids:
            raise ValueError("tier 1 requires failed_tests")
        env["VERIFY_FAILED_TESTS"] = " ".join(ids)
    elif tier == 2:
        ids = slice_tests or failed_tests or []
        if ids:
            env["VERIFY_SLICE_TESTS"] = " ".join(ids)
    return env


_NIGHTLY_TIER2_EXCLUDE_RE = re.compile(
    r"nightly|not\s+(?:a\s+)?done\s+gate|not\s+the\s+done\s+gate",
    re.IGNORECASE,
)


def mapping_row_excluded_from_tier2(ac: str, notes: str) -> bool:
    """True when a mapping row is nightly/manual-only — not the tier-2 gate.

    Slow targets use ``PODWASH_SCHEME=PodWashSlowTests``; they cannot run on the
    default ``PodWash`` scheme via ``-only-testing:`` (see ADR-003 / verify.sh).
    """
    ac_l = (ac or "").strip().lower()
    notes_l = (notes or "").strip().lower()
    if ac_l.startswith("—") or ac_l.startswith("-") or "(live)" in ac_l:
        return True
    if _NIGHTLY_TIER2_EXCLUDE_RE.search(notes_l):
        return True
    return False


def extract_mapped_test_ids(slice_text: str, *, tier2: bool = False) -> list[str]:
    """Build -only-testing: ids from the slice Verification mapping table.

    Prefers ``Target/Class/testMethod()`` when the test file path encodes the
    target; otherwise ``ClassName/testMethod()``.

    When ``tier2=True``, skip rows marked nightly-only / not a Done gate so the
    implement gate never schedules ``PodWashSlowTests`` on the default scheme.
    """
    body = _section_body(slice_text or "", "Verification mapping")
    ids: list[str] = []
    for line in body.splitlines():
        if not line.strip().startswith("|"):
            continue
        cells = [c.strip().strip("`") for c in line.strip().strip("|").split("|")]
        if len(cells) < 3:
            continue
        if cells[0].lower() in ("ac#", "ac") or set(cells[0]) <= {"-", " "}:
            continue
        notes = cells[3] if len(cells) > 3 else ""
        if tier2 and mapping_row_excluded_from_tier2(cells[0], notes):
            continue
        test_file = cells[1]
        method = cells[2]
        if not method or method in ("—", "-", "(pending)", "TBD", "…", "..."):
            continue
        if method.lower() in ("—", "command-level", "n/a"):
            continue
        method = method.strip("`")
        if not method.endswith("()") and method.startswith("test"):
            method = method + "()"
        class_name = ""
        if test_file.endswith(".swift"):
            class_name = os.path.splitext(os.path.basename(test_file))[0]
        target = ""
        norm = test_file.replace("\\", "/")
        for tname in ("PodWashUITests", "PodWashSlowTests", "PodWashTests"):
            if tname in norm:
                target = tname
                break
        if class_name and method.startswith("test"):
            tid = f"{target}/{class_name}/{method}" if target else f"{class_name}/{method}"
            if tid not in ids:
                ids.append(tid)
        elif "/" in method and method not in ids:
            ids.append(method)
    return ids


def tier2_marker_path(repo_root: str, slice_id: int | None) -> str:
    name = (
        f"tier2-slice-{slice_id:02d}.ok"
        if slice_id is not None
        else "tier2-slice.ok"
    )
    return os.path.join(repo_root, "build", "test-results", name)


def write_tier2_marker(repo_root: str, slice_id: int | None) -> str:
    path = tier2_marker_path(repo_root, slice_id)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("ok\n")
    return path


def tier2_marker_ok(repo_root: str, slice_id: int | None) -> bool:
    return os.path.isfile(tier2_marker_path(repo_root, slice_id))


class InfraHalt(Exception):
    """Retry-safe infrastructure failure (exit 6) — attempt not burned if no edits."""

    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason


# ---------------------------------------------------------------------------
# GateState assessment
# ---------------------------------------------------------------------------


def _role_row(rows: list[dict[str, str]], name: str) -> dict[str, str] | None:
    for r in rows:
        if r["role"].strip().lower() == name.lower():
            return r
    return None


def _role_gate_status(
    row: dict[str, str] | None, repo_root: str
) -> tuple[GateStatus, bool]:
    if row is None:
        return "na", False
    gate = row["gate"].lower()
    if "waiv" in gate:
        return "waived", True
    path = row["path"]
    if artifact_cell_satisfied(repo_root, path):
        return "done", True
    if "accepted" in gate or "(done)" in path.lower():
        return "done", True
    return "pending", True


def _plan_review_block(text: str, prefix: str) -> str:
    """Collect Plan review lines for a prefix (handles fenced multi-line blocks)."""
    lines = text.splitlines()
    collected: list[str] = []
    in_fence = False
    capturing = False
    prefixes = ("adr review", "test spec review")
    want = prefix.lower()

    for line in lines:
        stripped = line.strip()
        if stripped.startswith("```"):
            in_fence = not in_fence
            if capturing and collected:
                # keep fence content
                continue
            continue
        lower = stripped.lower()
        starts = any(lower.startswith(p) for p in prefixes)
        if starts:
            if lower.startswith(want):
                capturing = True
                collected.append(stripped)
                continue
            if capturing:
                break
        elif capturing:
            if stripped.startswith("## ") and not in_fence:
                break
            collected.append(stripped)
    if collected:
        return "\n".join(collected)
    # Fallback: single-line helper
    return _plan_review_line(text, prefix)


def adr_reviewer_cleared(block: str, reviewer: Literal["qa", "pm"]) -> bool:
    b = (block or "").lower()
    if not b:
        return False
    if "waiv" in b and reviewer in b:
        return True
    if re.search(rf"\b{reviewer}\s+cleared\b", b):
        return True
    if re.search(rf"\b{reviewer}\b[^\n]*(?:no blockers|approved)", b):
        return True
    # Combined line: "QA cleared … PM cleared …"
    if re.search(rf"\b{reviewer}\s+cleared\b", b):
        return True
    return False


def _act_position(state: GateState, gid: GateId) -> tuple[int, int]:
    """1-based act index for gid among applicable gates, and total count."""
    apps = state.applicable_gates
    total = len(apps) or 1
    for i, g in enumerate(apps):
        if g.id == gid:
            return i + 1, total
    return min(state.done_count + 1, total), total


def _log_stuck_card_path(
    card: str,
    *,
    repo_root: str,
    slice_file: str,
    log: LogFn,
    printed: set[str] | None = None,
) -> str:
    """Persist stuck card; print full body once per path, then path-only."""
    path = persist_stuck_card(card, repo_root=repo_root, slice_file=slice_file)
    seen = printed if printed is not None else set()
    if path not in seen:
        seen.add(path)
        log(f"stuck card written: {path}")
    else:
        log(f"stuck card updated: {path}")
    return path


def _narrate_verify_failure(
    name: str,
    outcome: VerifyOutcome,
    *,
    repo_root: str,
    log: LogFn,
    voice: Any = None,
    cast: CastLog | None = None,
) -> None:
    """Red verify tally plus in-character test/intent/got detail (Murphy paths)."""
    narrate_verify_red(
        name,
        passed=(outcome.result or {}).get("passed", "?"),
        total=(outcome.result or {}).get("total", "?"),
        log=log,
        voice=voice,
    )
    packet = outcome.packet or build_failure_packet(
        failures=outcome.failures,
        crashes=outcome.crashes,
        bundle=(outcome.result or {}).get("bundle"),
        exit_code=(outcome.result or {}).get("exit"),
        output=outcome.output,
        repo_root=repo_root,
        export_attachments=False,
    )
    narrate_failure_detail(name, packet, log=log, voice=voice)
    if cast is not None:
        cast.note_murphy()


def _report_verify_green(
    client: Any,
    name: str,
    outcome: VerifyOutcome,
    *,
    role: str,
    api_key: str,
    repo_root: str,
    log: LogFn,
) -> str:
    return narrate_verify_green_dynamic(
        client,
        name,
        passed=(outcome.result or {}).get("passed", "?"),
        total=(outcome.result or {}).get("total", "?"),
        role=role,
        api_key=api_key,
        repo_root=repo_root,
        log=log,
        run_worker=run_worker,
    )


def explain_gate_pending(gid: GateId, slice_file: str, repo_root: str) -> str:
    """Actionable halt line when a gate stays pending after its worker."""
    text = _read_slice_text(slice_file, repo_root)
    status = _status_from_text(text)
    bits: list[str] = [f"Status={status or '(empty)'}"]
    hints: list[str] = []

    if gid == "story":
        reasons = story_pending_reasons(text)
        if reasons:
            bits.append("predicates: " + "; ".join(reasons))
        if _story_content_ok(text) and status.lower() in ("", "draft"):
            hints.append("set Status to Ready (harness auto-flips after PM when content is ok)")
        elif not _story_content_ok(text):
            hints.append("fill Crux + Acceptance criteria checkboxes")
    elif gid in ("architect", "ux"):
        rows = _role_artifact_rows(text)
        role_name = "Architect" if gid == "architect" else "UX"
        r = _role_row(rows, role_name)
        if r:
            miss = missing_artifact_paths(repo_root, r["path"])
            if miss:
                bits.append(f"missing artifacts: {miss}")
                hints.append(
                    f"create {miss[0]}"
                    if len(miss) == 1
                    else f"create missing artifacts or mark {role_name} Waived"
                )
            elif "waiv" not in (r.get("gate") or "").lower():
                hints.append(
                    f"ensure {role_name} artifact path exists or mark Gate Waived"
                )
    elif gid == "test_spec":
        if not _verification_mapping_filled(text):
            bits.append("verification mapping incomplete")
        if not _mapped_test_files_exist(text, repo_root):
            bits.append("mapped test files missing on disk")
            hints.append("QA must write mapped test files under PodWashTests/UITests")
    elif gid == "test_review":
        bits.append("Test spec review not cleared")
        hints.append("Architect must clear test-spec review (or record cleared outcome)")
    elif gid == "implement":
        if not _implement_artifacts_exist(text, repo_root):
            bits.append("implement artifacts missing")
            hints.append("Engineer must land app sources listed in Deliverables")

    msg = f"gate {gid} still pending after worker — stopping. ({'; '.join(bits)})"
    if hints:
        msg += f" unblock: {'; '.join(hints)}"
    return msg


def assess_gate_state(slice_file: str, repo_root: str) -> GateState:
    """Strict gate checklist for the pipeline FSM (not the progress heuristic)."""
    text = _read_slice_text(slice_file, repo_root)
    status = _status_from_text(text)
    rows = _role_artifact_rows(text)
    arch_row = _role_row(rows, "Architect")
    ux_row = _role_row(rows, "UX")

    arch_st, arch_on = _role_gate_status(arch_row, repo_root)
    ux_st, ux_on = _role_gate_status(ux_row, repo_root)

    arch_waived = arch_on and arch_st == "waived"
    arch_na = not arch_on

    adr_block = _plan_review_block(text, "ADR review")
    if arch_waived or arch_na:
        adr_qa_st, adr_qa_on = ("waived", False) if arch_na else ("waived", True)
        adr_pm_st, adr_pm_on = adr_qa_st, adr_qa_on
        if arch_na:
            adr_qa_st, adr_qa_on = "na", False
            adr_pm_st, adr_pm_on = "na", False
    else:
        adr_qa_on = adr_pm_on = True
        adr_qa_st = "done" if adr_reviewer_cleared(adr_block, "qa") else "pending"
        adr_pm_st = "done" if adr_reviewer_cleared(adr_block, "pm") else "pending"

    test_spec_ok = _verification_mapping_filled(text) and _mapped_test_files_exist(
        text, repo_root
    )
    tsr_block = _plan_review_block(text, "Test spec review")
    tsr_l = tsr_block.lower()
    test_review_ok = _review_cleared(tsr_block) or (
        "architect cleared" in tsr_l
        or ("cleared" in tsr_l and "no blockers" in tsr_l)
    )

    verify = parse_verify_result(text)
    green = verify_is_green(verify)
    status_l = status.lower()
    record_ok = green and bool(verify)  # VERIFY RESULT present and green
    commit_ok = status_l == "done" and green

    # P1: implement exit gate prefers tier-2 marker. Done/green slices stay
    # satisfied without a marker (backward compatible).
    sid = slice_id_from_path(slice_file)
    artifacts = _implement_artifacts_exist(text, repo_root)
    implement_ok = artifacts and (
        tier2_marker_ok(repo_root, sid)
        or status_l in ("done", "verify")
        or green
    )

    statuses: dict[GateId, tuple[GateStatus, bool]] = {
        "story": ("done" if _story_done(text) else "pending", True),
        "architect": (arch_st, arch_on),
        "ux": (ux_st, ux_on),
        "adr_review_qa": (adr_qa_st, adr_qa_on),
        "adr_review_pm": (adr_pm_st, adr_pm_on),
        "test_spec": ("done" if test_spec_ok else "pending", True),
        "test_review": ("done" if test_review_ok else "pending", True),
        "implement": ("done" if implement_ok else "pending", True),
        "verify": ("done" if green else "pending", True),
        # record = VERIFY RESULT line present + green (Status may still be In Progress)
        "record": ("done" if record_ok else "pending", True),
        "commit": ("done" if commit_ok else "pending", True),
    }

    gates: list[Gate] = []
    for gid in GATE_ORDER:
        st, on = statuses[gid]
        gates.append(Gate(id=gid, label=GATE_LABELS[gid], status=st, applicable=on))

    return GateState(slice_file=slice_file, slice_status=status, gates=tuple(gates))


def _deps_satisfied(state: GateState, gid: GateId) -> bool:
    for dep in GATE_DEPS[gid]:
        g = state.gate(dep)
        if g.applicable and not g.satisfied:
            return False
    return True


def next_gate(state: GateState) -> Optional[GateId]:
    """First applicable incomplete gate whose deps are satisfied."""
    for gid in GATE_ORDER:
        g = state.gate(gid)
        if not g.applicable or g.satisfied:
            continue
        if _deps_satisfied(state, gid):
            return gid
    return None


def gates_ready_for_parallel(state: GateState) -> list[GateId]:
    """All applicable pending gates with deps satisfied (fork hints)."""
    ready: list[GateId] = []
    for gid in GATE_ORDER:
        g = state.gate(gid)
        if not g.applicable or g.satisfied:
            continue
        if _deps_satisfied(state, gid):
            ready.append(gid)
    return ready


def should_loop_own_verify(slice_file: str, repo_root: str) -> bool:
    """True when the loop should run verify (implement done or mid-flight status)."""
    state = assess_gate_state(slice_file, repo_root)
    if state.gate("implement").satisfied:
        return True
    status = state.slice_status.lower()
    return status in ("in progress", "verify")


# ---------------------------------------------------------------------------
# Verify ownership
# ---------------------------------------------------------------------------


def run_verify(
    repo_root: str,
    *,
    log: LogFn | None = None,
    extra_args: list[str] | None = None,
    slice_file: str = "",
    tier: int = 3,
    failed_tests: list[str] | None = None,
    slice_tests: list[str] | None = None,
    env: dict[str, str] | None = None,
) -> VerifyOutcome:
    """Run scripts/verify.sh as a subprocess; parse VERIFY RESULT as truth.

    ``tier`` maps to VERIFY_TIER (0 build / 1 failed-tests / 2 slice / 3 full).
    """
    _log = log or (lambda m: None)
    cmd = [VERIFY_SH if repo_root == REPO_ROOT_DEFAULT else os.path.join(repo_root, "scripts", "verify.sh")]
    if extra_args:
        cmd.extend(extra_args)
    has_cli_only = any(
        (a or "").startswith("-only-testing:") for a in (extra_args or [])
    )
    if tier == 2 and slice_file and slice_tests is None:
        slice_tests = resolve_tier2_slice_tests(slice_file, repo_root)
    if tier == 2 and not slice_tests and not has_cli_only:
        sid = slice_id_from_path(slice_file)
        label = f"slice-{sid:02d}" if sid is not None else "slice"
        msg = (
            f"FACTORY CONFIG HALT: tier-2 has no VERIFY_SLICE_TESTS — "
            f"extract_mapped_test_ids returned 0 ids for {label}; "
            f"fix slice Verification mapping or scripts/slice_pipeline.py wiring "
            f"(not an app compile error)."
        )
        _log(msg)
        fc = f"factory_config: {msg}"
        return VerifyOutcome(
            result={
                "exit": "1",
                "total": "0",
                "passed": "0",
                "failed": "0",
                "skipped": "0",
                "filtered": "0",
                "class": "factory_config",
                "tier": str(tier),
            },
            green=False,
            failures=[fc],
            output=msg + "\n",
            tier=tier,
        )
    run_env = os.environ.copy()
    try:
        tier_env = verify_env_for_tier(
            tier, failed_tests=failed_tests, slice_tests=slice_tests
        )
    except ValueError as exc:
        _log(f"loop-owned verify aborted: {exc}")
        return VerifyOutcome(
            result={"exit": "1", "total": "?", "passed": "?", "failed": "?", "skipped": "?"},
            green=False,
            failures=[str(exc)],
            output=str(exc),
            tier=tier,
        )
    run_env.update(tier_env)
    if env:
        run_env.update(env)
    _log(f"loop-owned verify: tier={tier} {' '.join(cmd)}")
    t0 = time.time()
    proc = subprocess.run(
        cmd,
        cwd=repo_root,
        capture_output=True,
        text=True,
        env=run_env,
    )
    elapsed = time.time() - t0
    output = (proc.stdout or "") + "\n" + (proc.stderr or "")
    result = parse_verify_result(output)
    # Prefer machine-readable contract when verify.sh wrote it.
    json_path = os.path.join(repo_root, "build", "test-results", "verify-result.json")
    if os.path.isfile(json_path):
        try:
            with open(json_path, encoding="utf-8") as fh:
                import json as _json

                j = _json.load(fh)
            if isinstance(j, dict) and j.get("exit") is not None:
                merged = dict(result or {})
                for k in (
                    "exit",
                    "total",
                    "passed",
                    "failed",
                    "skipped",
                    "filtered",
                    "bundle",
                    "tier",
                    "class",
                ):
                    if k in j and j[k] is not None and str(j[k]) != "":
                        merged[k] = str(j[k])
                result = merged
        except (OSError, ValueError, TypeError):
            pass
    if result is None and proc.returncode != 0:
        result = {
            "exit": str(proc.returncode),
            "total": "?",
            "passed": "?",
            "failed": "?",
            "skipped": "?",
        }
    if result is not None and "tier" not in result:
        result = dict(result)
        result["tier"] = str(tier)
    green = verify_is_green(result)
    # Tier 0 is build-only — green when exit=0 (no tests executed).
    if tier == 0 and result and result.get("exit") == "0":
        green = True
    failures = detect_test_failures(output)
    crashes = detect_simulator_crashes(output)
    bundle = (result or {}).get("bundle") or latest_xcresult_path(repo_root)
    if bundle and not failures:
        failures = read_failures_from_xcresult(bundle)
    failures = enrich_build_failures(failures, output, result)
    if is_factory_config_output(output):
        fc = extract_factory_config_error(output)
        if fc and not any((f or "").startswith("factory_config:") for f in failures):
            failures = [fc, *failures]
        if result is not None:
            result = dict(result)
            result["class"] = "factory_config"
    if result and bundle and "bundle" not in result:
        result = dict(result)
        result["bundle"] = bundle
    # Persist raw verify output for post-mortems / replay corpus.
    try:
        tr = os.path.join(repo_root, "build", "test-results")
        os.makedirs(tr, exist_ok=True)
        stamp = time.strftime("%Y%m%d-%H%M%S")
        out_path = os.path.join(tr, f"verify-output-t{tier}-{stamp}.txt")
        with open(out_path, "w", encoding="utf-8") as fh:
            fh.write(output)
        # Keep a stable "latest" pointer for the session bundle.
        latest = os.path.join(tr, "verify-output-latest.txt")
        with open(latest, "w", encoding="utf-8") as fh:
            fh.write(output)
        if result is not None:
            result = dict(result)
            result["output_path"] = os.path.relpath(out_path, repo_root)
    except OSError:
        pass
    packet: FailurePacket | None = None
    if not green:
        packet = build_failure_packet(
            failures=failures,
            crashes=crashes,
            bundle=bundle,
            exit_code=(result or {}).get("exit"),
            output=output,
            repo_root=repo_root,
        )
        if packet.raw_failures:
            failures = list(packet.raw_failures)
        card = format_stuck_card(
            packet,
            slice_file=slice_file,
            attempt=0,
            max_attempts=0,
        )
        path = _log_stuck_card_path(
            card, repo_root=repo_root, slice_file=slice_file, log=_log
        )
        del path  # path logged inside helper
    _log(
        f"loop-owned verify done: tier={tier} green={green} "
        f"exit={(result or {}).get('exit')} failed={(result or {}).get('failed')} "
        f"elapsed={elapsed:.0f}s"
    )
    return VerifyOutcome(
        result=result,
        green=green,
        failures=failures,
        crashes=crashes,
        output=output,
        elapsed_secs=elapsed,
        packet=packet,
        tier=tier,
    )


# ---------------------------------------------------------------------------
# Fix router
# ---------------------------------------------------------------------------


_TEST_PATH_HINT = re.compile(
    r"(PodWashTests|PodWashUITests|PodWashSlowTests|Fixtures/|\.swift.*Test)",
    re.IGNORECASE,
)
_APP_PATH_HINT = re.compile(r"PodWash/PodWash/", re.IGNORECASE)



def route_fix(
    failures: list[str],
    crashes: list[str],
    *,
    previous_role: str = "",
    previous_signature: str = "",
    packet: FailurePacket | None = None,
    lever_role: str = "",
) -> str:
    """Factory v3: always Mechanic (no role routing). Kept for test compatibility."""
    return "Mechanic"


def failure_signature(failures: list[str], crashes: list[str]) -> str:
    """Legacy helper — prefer factory_progress.make_failure_signature."""
    from factory_progress import make_failure_signature

    return make_failure_signature(failures=list(failures or []) + list(crashes or []))


def build_diagnose_prompt(packet: FailurePacket, slice_file: str, card: str) -> str:
    """Legacy diagnose prompt (kept for tests / fallback tooling).

    Factory v2 P0 routes via :func:`build_referee_prompt` instead.
    """
    persona = load_persona("QA review")
    return f"""{persona}

You are a **readonly diagnose** worker for PodWash (SDK plan mode).
Slice file: {slice_file}

Do NOT edit files. Do NOT run verify.sh or xcodebuild test.
Read the FailurePacket / stuck card and reply with ONLY these fields (one per line):

class: <crash|ui_race|missing_identifier|wrong_state|assertion|build_error|flake|unknown>
hypothesis: <one sentence>
fix_scope: <app|tests>
suggested_files: <comma-separated paths or none>

Stuck card:
{card}

FailurePacket:
- test_ids: {packet.test_ids}
- assertions: {packet.assertions}
- failed_queries: {packet.failed_queries}
- crashes: {packet.crashes}
- raw_failures: {packet.raw_failures[:5]}
- hierarchy_excerpt (truncated):
{packet.hierarchy_excerpt[:2000]}
"""


def _collect_ips_summaries(repo_root: str, *, limit: int = 3) -> list[str]:
    """Summarize recent PodWash .ips under build/test-results (tier-2 evidence)."""
    roots = [
        os.path.join(repo_root, r) if not os.path.isabs(r) else r
        for r in default_ips_roots()[:1]
    ]
    found: list[tuple[float, str]] = []
    for root in roots:
        if not root or not os.path.isdir(root):
            continue
        for dirpath, _dirs, files in os.walk(root):
            for name in files:
                if not name.endswith(".ips"):
                    continue
                path = os.path.join(dirpath, name)
                try:
                    found.append((os.path.getmtime(path), path))
                except OSError:
                    continue
    found.sort(reverse=True)
    out: list[str] = []
    for _mtime, path in found[:limit]:
        out.append(f"{summarize_ips_crash(path)} ({path})")
    return out


def _tier2_failure_blob(outcome: VerifyOutcome) -> str:
    """Full blob including stdout — for expectation/API scans only, not infra."""
    parts = list(outcome.failures or []) + list(outcome.crashes or [])
    if outcome.output:
        parts.append(outcome.output)
    if outcome.packet:
        parts.extend(outcome.packet.raw_failures or [])
        parts.extend(outcome.packet.assertions or [])
        parts.extend(outcome.packet.crashes or [])
    return "\n".join(parts)


def _tier2_curated_blob(outcome: VerifyOutcome) -> str:
    """Failures / crashes / packet only — never full xcodebuild stdout.

    Infra classification must not see CoreSimulator paths or other environment
    noise that appears on every sim destination run (slice 13 false-positive).
    """
    parts = list(outcome.failures or []) + list(outcome.crashes or [])
    if outcome.packet:
        parts.extend(outcome.packet.raw_failures or [])
        parts.extend(outcome.packet.assertions or [])
        parts.extend(outcome.packet.crashes or [])
    return "\n".join(parts)


def is_factory_config_lane(outcome: VerifyOutcome) -> bool:
    """True when verify failed due to factory wiring — not app compile or XCTest."""
    result = outcome.result or {}
    if result.get("class") == "factory_config":
        return True
    failures = list(outcome.failures or [])
    if any((f or "").startswith("factory_config:") for f in failures):
        return True
    pkt = outcome.packet
    if pkt and pkt.failure_class == "factory_config":
        return True
    if is_factory_config_output(outcome.output):
        return True
    return False


def is_build_lane(outcome: VerifyOutcome) -> bool:
    """True when structured signals say compile/link red (beats infra lane)."""
    if is_factory_config_lane(outcome):
        return False
    result = outcome.result or {}
    if result.get("class") == "build":
        return True
    failures = list(outcome.failures or [])
    if any((f or "").startswith("build_error:") for f in failures):
        return True
    pkt = outcome.packet
    if pkt and pkt.failure_class == "build_error":
        return True
    curated = _tier2_curated_blob(outcome)
    if looks_like_build_failure(curated, result):
        return True
    return False


def outcome_failure_class(outcome: VerifyOutcome) -> str:
    """Stable class label for budget / transition accounting."""
    if is_factory_config_lane(outcome):
        return "factory_config"
    if is_build_lane(outcome):
        return "build_error"
    blob = _tier2_failure_blob(outcome)
    if is_artifact_fixture_failure(blob):
        return "fixture_artifact"
    pkt = outcome.packet
    if pkt and pkt.failure_class:
        return str(pkt.failure_class)
    if outcome.crashes:
        return "crash"
    if outcome.failures:
        return "unknown"
    return "unknown"


def is_tier2_infra_failure(
    outcome: VerifyOutcome,
    *,
    log: LogFn | None = None,
) -> bool:
    """Sim install/launch/bootstrap — cold-retry; do not spawn a fix worker.

    Exclusive lane: ``class=build`` / ``build_error`` always wins over infra.
    """
    _log = log or (lambda m: None)
    curated = _tier2_curated_blob(outcome)
    result = outcome.result or {}
    exit_code = result.get("exit")

    # Exclusive lane — build beats infra (slice 13 invariant).
    if is_build_lane(outcome):
        # Disagreement alarm: heuristic on full stdout would have said infra.
        full = _tier2_failure_blob(outcome)
        if classify_infra_failure(
            output=full, exit_code=exit_code, files_changed=False
        ):
            _log(
                "CLASSIFIER DISAGREEMENT: structured=build but heuristic=infra "
                "on full stdout — preferring build lane"
            )
        return False

    if is_missing_bundle_executable(curated) or is_missing_bundle_executable(
        outcome.output or ""
    ):
        return False

    if classify_infra_failure(
        output=curated,
        exit_code=exit_code,
        files_changed=False,
    ):
        return True

    pkt = outcome.packet
    if pkt and pkt.failure_class == "flake":
        low = curated.lower()
        if any(
            m in low
            for m in (
                "failed to install or launch",
                "sbmainworkspace",
                "early unexpected exit",
                "bootstrapping",
            )
        ):
            return True
    return False


def _suggested_files_for_lane(
    lane_id: str,
    role: str,
    packet: FailurePacket,
    slice_files: list[str],
) -> list[str]:
    """Pick suggested edit paths for a deterministic lane."""
    if lane_id == "adr_citation" or role == "Architect":
        blob = " ".join(
            list(packet.raw_failures or [])
            + list(packet.assertions or [])
        )
        return extract_adr_doc_paths(blob, slice_files) or ["docs/adr/"]
    src = list(packet.suggested_files or []) + list(slice_files)
    if role == "QA" or lane_id in ("expectation_api", "artifact_fixture"):
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


def resolve_tier2_continue(
    *,
    slice_file: str,
    repo_root: str,
    outcome: VerifyOutcome,
    run_i: int,
    max_runs: int,
    escalate_expectation: bool = False,
) -> tuple[str, str]:
    """Return (Mechanic, prompt) for a tier-2 red continue spawn."""
    packet = outcome.packet
    if packet is None:
        packet = build_failure_packet(
            failures=outcome.failures,
            crashes=outcome.crashes,
            bundle=(outcome.result or {}).get("bundle"),
            exit_code=(outcome.result or {}).get("exit"),
            output=outcome.output,
            repo_root=repo_root,
        )
    card = format_stuck_card(
        packet,
        slice_file=slice_file,
        attempt=run_i,
        max_attempts=max_runs,
    )
    persist_stuck_card(card, repo_root=repo_root, slice_file=slice_file)
    ips = _collect_ips_summaries(repo_root)
    crashes = list(outcome.crashes or packet.crashes or [])
    for line in ips:
        if line not in crashes:
            crashes.append(line)

    blob = _tier2_failure_blob(outcome)
    slice_text = ""
    try:
        slice_text = _read_slice_text(slice_file, repo_root)
    except OSError:
        slice_text = ""
    slice_files = extract_slice_swift_paths(slice_text)

    lane = classify_fix_lane(
        blob=blob,
        packet=packet,
        is_build=is_build_lane(outcome),
        escalate_expectation=escalate_expectation or run_i >= 2,
    )
    instruction = ""
    hypothesis = packet.hypothesis or ""
    suggested = list(packet.suggested_files or slice_files)
    if lane is not None:
        instruction = lane.instruction
        hypothesis = lane.hypothesis
        suggested = suggested_files_for_lane(
            lane.lane_id, packet, slice_files
        ) or suggested

    prompt = build_mechanic_prompt(
        slice_file,
        outcome.failures or packet.raw_failures,
        crashes,
        (outcome.result or {}).get("bundle") or packet.bundle,
        run_i,
        max_runs,
        packet=packet,
        stuck_card=card,
        lane_instruction=instruction,
        lane_hypothesis=hypothesis,
        primary_failure=(outcome.failures or packet.raw_failures or ["(unknown)"])[0],
        suggested_files=suggested,
    )
    return "Mechanic", prompt


def build_tier2_continue_prompt(
    *,
    slice_file: str,
    repo_root: str,
    outcome: VerifyOutcome,
    run_i: int,
    max_runs: int,
    escalate_expectation: bool = False,
) -> str:
    """Rich continue prompt for tier-2 red — stuck card + packet + IPS, not failures-only."""
    _role, prompt = resolve_tier2_continue(
        slice_file=slice_file,
        repo_root=repo_root,
        outcome=outcome,
        run_i=run_i,
        max_runs=max_runs,
        escalate_expectation=escalate_expectation,
    )
    return prompt


def build_fix_prompt(
    role: str,
    slice_file: str,
    failures: list[str],
    crashes: list[str],
    bundle: str | None,
    attempt: int,
    max_attempts: int,
    *,
    packet: FailurePacket | None = None,
    stuck_card: str = "",
    lever_instruction: str = "",
    lever_forbid: tuple[str, ...] | list[str] = (),
    attempt_notes: list[str] | None = None,
    suggested_files: list[str] | None = None,
    referee_instruction: str = "",
    referee_hypothesis: str = "",
    ledger_block: str = "",
    primary_failure: str = "",
) -> str:
    if role == "Mechanic":
        return build_mechanic_prompt(
            slice_file,
            failures,
            crashes,
            bundle,
            attempt,
            max_attempts,
            packet=packet,
            stuck_card=stuck_card,
            lane_instruction=referee_instruction or lever_instruction,
            lane_hypothesis=referee_hypothesis,
            attempt_notes=attempt_notes,
            suggested_files=suggested_files,
            ledger_block=ledger_block,
            primary_failure=primary_failure,
        )
    persona = load_persona(role if role != "Mechanic" else "Engineer")
    if role == "Architect":
        scope = (
            "docs/adr/** only — fill § Benchmark results from committed fixture "
            "(±0.001); do not edit app or tests"
        )
        docs_guard = ""
    elif role == "Engineer":
        scope = "PodWash/PodWash/** only (no tests)"
        docs_guard = (
            "Do NOT edit docs/adr/** (Architect owns decision artifacts). "
        )
    else:
        scope = "PodWash/{PodWashTests,PodWashUITests,PodWashSlowTests}/** + fixtures only"
        docs_guard = "Do NOT edit docs except if QA needs a fixture README note.\n"
    fail_lines = "\n".join(f"- {f}" for f in (failures or ["(unknown failure)"]))
    crash_lines = "\n".join(f"- {c}" for c in crashes) if crashes else "(none)"
    bundle_line = bundle or "(none — check build/test-results/)"
    card_block = stuck_card.strip() or "(no stuck card)"
    instruction = (
        referee_instruction
        or lever_instruction
        or "(no referee instruction — minimal change guided by FailurePacket)"
    )
    forbid_block = ", ".join(lever_forbid) if lever_forbid else "weaken XCTAssert, delete assertions"
    files = suggested_files or (packet.suggested_files if packet else [])
    files_block = ", ".join(files) if files else "(none suggested)"
    history = ""
    if attempt_notes:
        history = "Attempt history:\n" + "\n".join(f"- {n}" for n in attempt_notes)
    ledger = ledger_block or "(empty)"
    hyp = referee_hypothesis or (packet.hypothesis if packet else "") or "(none)"
    primary = primary_failure or "(see failing tests)"
    assertions_block = ""
    if packet and packet.assertions:
        assertions_block = "Failing assertions:\n" + "\n".join(
            f"- {a}" for a in packet.assertions[:8]
        )
    packet_block = ""
    if packet:
        packet_block = f"""
FailurePacket:
- class hint: {packet.failure_class}
- signature: {packet.signature}
- test_ids: {packet.test_ids}
- assertions: {packet.assertions}
- failed_queries: {packet.failed_queries}
- hypothesis: {packet.hypothesis or "(none)"}
- fix_scope: {packet.fix_scope}
- hierarchy_excerpt:
{packet.hierarchy_excerpt[:2500]}
"""
    return f"""{persona}

You are a **fix worker** for PodWash (attempt {attempt}/{max_attempts}).
Fresh context — do not defend prior theories; the hypothesis ledger is authoritative.
Slice file: {slice_file}

**Edit scope (hard):** {scope}
Do NOT run scripts/verify.sh or `xcodebuild … test` — the outer loop owns verification.
If you need failure detail, read the stuck card / xcresult attachments already provided.
{docs_guard}
Stuck card:
{card_block}

Referee verdict for this attempt:
- primary_failure: {primary}
- hypothesis: {hyp}
- instruction: {instruction}
Forbidden: {forbid_block}
Suggested files: {files_block}

Hypothesis ledger (do not repeat a prior hypothesis on the same signature):
{ledger}

{history}
{assertions_block}
{packet_block}
Failing tests:
{fail_lines}

Simulator crashes:
{crash_lines}

xcresult bundle: {bundle_line}

Diagnose, make the minimal fix in scope, then end your turn. Do not verify.
End with:
SUMMARY: <one line of what you changed>
"""


def load_persona(role: str) -> str:
    fname = ROLE_AGENT_FILES.get(role)
    if not fname:
        return f"You are the PodWash {role} agent."
    path = os.path.join(AGENTS_DIR, fname)
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except OSError:
        return f"You are the PodWash {role} agent."
    # Strip YAML frontmatter
    if text.startswith("---"):
        end = text.find("\n---", 3)
        if end != -1:
            text = text[end + 4 :].lstrip()
    return text.strip()


def model_for_role(role: str) -> str:
    return ROLE_MODELS.get(role, "composer-2.5")


def mode_for_role(role: str) -> str:
    return "plan" if role in PLAN_MODE_ROLES else "agent"


def build_gate_prompt(gate_id: GateId, slice_file: str, repo_root: str) -> str:
    role = GATE_ROLE.get(gate_id, "PM")
    persona = load_persona(role)
    mode = mode_for_role(role)
    tasks = {
        "story": (
            "Write/refine the slice story: Crux, Goal, Deliverables, numeric ACs, "
            "out-of-scope, verification commands. Edit only this slice markdown. "
            "When Crux + Acceptance criteria checkboxes are complete, the harness "
            "sets Status to Ready — you may leave Status as Draft."
        ),
        "architect": (
            "Author the ADR / design note for this slice. Edit only docs/adr/** "
            "(and slice design notes if needed). When empirical validation is "
            "required, a throwaway spike may live in PodWashTests/_*Spike.swift — "
            "run it with xcodebuild, not scripts/verify.sh. The gate artifact is "
            "the ADR markdown file."
        ),
        "ux": (
            "Author the UX spec (interaction, a11y, UI test scenarios) in "
            "docs/slices/*-ux.md. Do NOT edit app Swift."
        ),
        "adr_review_qa": (
            "Readonly ADR plan review (testability). Do not edit files. "
            "Return a short outcome: 'QA cleared — …' or blockers."
        ),
        "adr_review_pm": (
            "Readonly ADR plan review (story↔design). Do not edit files. "
            "Return a short outcome: 'PM cleared — …' or blockers."
        ),
        "test_spec": (
            "Author the test spec: map every AC to a test method, write failing "
            "tests/fixtures under PodWashTests/UITests. Do NOT edit app Swift. "
            "Do NOT run scripts/verify.sh or xcodebuild test — the loop owns "
            "verification after Engineer. Your tests are expected to fail to "
            "compile until app code exists."
        ),
        "test_review": (
            "Readonly test-spec review vs ADR-000 + slice ADR. Do not edit files. "
            "Return 'Architect cleared — …' or blockers."
        ),
        "implement": (
            "Implement app code under PodWash/PodWash/** to pass existing tests. "
            "Do NOT edit tests. Do NOT run verify.sh. "
            "End with a single line: SUMMARY: <≤25 words of what you changed>."
        ),
    }
    task = tasks.get(gate_id, f"Complete the {gate_id} gate for this slice.")
    adr_hint = ""
    if gate_id == "architect":
        adr_path = architect_adr_path_from_slice(slice_file, repo_root)
        if adr_path:
            adr_hint = f"\nRequired ADR path (resolved): {adr_path}\n"
    return f"""{persona}

Gate: {gate_id} ({GATE_LABELS.get(gate_id, gate_id)})
Slice file: {slice_file}
SDK mode: {mode}
Repo: {repo_root}
{adr_hint}
{task}

Read the slice file and only the artifacts needed for this gate. End your turn when done.
Always end with: SUMMARY: <one line>
"""


def _assistant_text_from_message(message: Any) -> str:
    """Extract plain text from SDK assistant stream messages (dict or typed)."""
    if message is None:
        return ""
    if isinstance(message, dict):
        if message.get("type") not in (None, "assistant"):
            # Still try if nested
            pass
        direct = message.get("text") or message.get("content")
        if isinstance(direct, str) and direct.strip():
            return direct
        msg = message.get("message") or {}
        if isinstance(msg, dict):
            parts: list[str] = []
            for block in msg.get("content") or []:
                if isinstance(block, dict) and block.get("type") == "text":
                    t = block.get("text") or ""
                    if t:
                        parts.append(str(t))
                elif isinstance(block, str):
                    parts.append(block)
            if parts:
                return "\n".join(parts)
            if isinstance(msg.get("text"), str):
                return msg["text"]
        return ""
    mtype = getattr(message, "type", None)
    if mtype and mtype != "assistant":
        return ""
    direct = getattr(message, "text", None) or getattr(message, "content", None)
    if isinstance(direct, str) and direct.strip():
        return direct
    inner = getattr(message, "message", None)
    parts = []
    for block in getattr(inner, "content", None) or []:
        if getattr(block, "type", None) == "text":
            t = getattr(block, "text", "") or ""
            if t:
                parts.append(str(t))
    return "\n".join(parts)


def run_worker(
    client: Any,
    *,
    role: str,
    prompt: str,
    api_key: str,
    repo_root: str,
    log: LogFn | None = None,
    progress: Any | None = None,
    on_assistant_text: Callable[[str], None] | None = None,
) -> tuple[bool, str]:
    """Create one SDK agent, send prompt, stream, wait. Returns (ok, status)."""
    from cursor_sdk import AgentOptions, LocalAgentOptions

    _log = log or (lambda m: None)
    model_id = model_for_role(role)
    model = sdk_model_for_role(model_id)
    mode = mode_for_role(role)
    # Mechanical start/finish lines are verbose-only — chapter beats carry the story.
    if progress is not None and getattr(progress, "verbose", False):
        _log(f"worker start: role={role} model={format_sdk_model(model)} mode={mode}")

    options = AgentOptions(
        api_key=api_key,
        model=model,
        local=LocalAgentOptions(cwd=repo_root),
        mode=mode,  # type: ignore[arg-type]
    )
    with client.create_agent(options) as agent:
        run = agent.send(prompt)
        if progress is not None and getattr(progress, "verbose", False):
            _log(
                f"worker agent_id={getattr(agent, 'agent_id', '?')} "
                f"run_id={getattr(run, 'id', '?')}"
            )
        if progress is not None:
            # Expose run for verify-ban cancel
            if hasattr(progress, "bind_run"):
                progress.bind_run(run)
            progress.start()
        assistant_bits: list[str] = []
        try:
            for message in run.messages():
                if progress is not None:
                    progress.handle(message)
                text = _assistant_text_from_message(message)
                if text:
                    assistant_bits.append(text)
                    if on_assistant_text:
                        on_assistant_text(text)
                    # Do NOT also append via progress.append_assistant_text —
                    # progress.handle() already captures assistant text; double
                    # append corrupts referee JSON with embedded newlines.
            result = run.wait()
        finally:
            if progress is not None:
                progress.stop()
                if hasattr(progress, "bind_run"):
                    progress.bind_run(None)
        status = getattr(result, "status", "unknown")
        # Verify-ban may mark violation_burned
        if progress is not None and getattr(progress, "verify_violation_burned", False):
            _log("WORKER VIOLATION: verify owned by loop (attempt burned)")
            return False, "verify_violation"
        if progress is not None and getattr(progress, "verbose", False):
            _log(f"worker finished: role={role} status={status}")
        if progress is not None and hasattr(progress, "set_assistant_text"):
            # Always prefer the clean stream join when present — never keep a
            # longer corrupted buffer from dual-capture.
            if assistant_bits:
                progress.set_assistant_text("".join(assistant_bits))
            elif not (getattr(progress, "assistant_text", "") or "").strip():
                progress.set_assistant_text("")
        return status == "finished", str(status)


# ---------------------------------------------------------------------------
# Slice-doc writer + commits
# ---------------------------------------------------------------------------


def format_verify_result_line(result: dict[str, str]) -> str:
    parts = [
        f"exit={result.get('exit', '?')}",
        f"total={result.get('total', '?')}",
        f"passed={result.get('passed', '?')}",
        f"failed={result.get('failed', '?')}",
        f"skipped={result.get('skipped', '?')}",
    ]
    if "filtered" in result:
        parts.append(f"filtered={result['filtered']}")
    if "bundle" in result:
        parts.append(f"bundle={result['bundle']}")
    if "tier" in result:
        parts.append(f"tier={result['tier']}")
    if "class" in result:
        parts.append(f"class={result['class']}")
    return "VERIFY RESULT: " + " ".join(parts)


def write_verify_result(slice_file: str, repo_root: str, result: dict[str, str]) -> None:
    """Insert or replace VERIFY RESULT line in the slice verification record."""
    path = slice_file if os.path.isabs(slice_file) else os.path.join(repo_root, slice_file)
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    line = format_verify_result_line(result)
    if re.search(r"^VERIFY RESULT:", text, re.MULTILINE | re.IGNORECASE):
        text = re.sub(
            r"^VERIFY RESULT:.*$",
            line,
            text,
            count=1,
            flags=re.MULTILINE | re.IGNORECASE,
        )
    else:
        # Insert after ## Verification record heading if present
        m = re.search(
            r"(##\s+Verification record[^\n]*\n)",
            text,
            re.IGNORECASE,
        )
        if m:
            insert_at = m.end()
            text = text[:insert_at] + "\n```\n" + line + "\n```\n" + text[insert_at:]
        else:
            text = text.rstrip() + "\n\n## Verification record\n\n```\n" + line + "\n```\n"
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


def set_slice_status(slice_file: str, repo_root: str, status: str) -> None:
    path = slice_file if os.path.isabs(slice_file) else os.path.join(repo_root, slice_file)
    with open(path, encoding="utf-8") as fh:
        lines = fh.readlines()
    out: list[str] = []
    for line in lines:
        if "| **Status** |" in line or "| **Status**|" in line:
            parts = [p.strip() for p in line.strip().strip("|").split("|")]
            if len(parts) >= 2:
                parts[1] = status
                line = "| " + " | ".join(parts) + " |\n"
        out.append(line)
    with open(path, "w", encoding="utf-8") as fh:
        fh.writelines(out)


def append_plan_review_outcome(
    slice_file: str,
    repo_root: str,
    *,
    kind: Literal["ADR review", "Test spec review"],
    outcome: str,
) -> None:
    """Append or merge a plan-review outcome under Plan review record."""
    path = slice_file if os.path.isabs(slice_file) else os.path.join(repo_root, slice_file)
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    stamp = time.strftime("%Y-%m-%d")
    outcome = outcome.strip()
    pattern = re.compile(r"(```[^\n]*\n)(.*?)(```)", re.DOTALL)
    section = re.search(
        r"(##\s+Plan review record[^\n]*\n)(.*?)(?=\n##\s+|\Z)",
        text,
        re.DOTALL | re.IGNORECASE,
    )

    def merge_line(existing: str) -> str:
        # ADR review: merge QA/PM fragments onto one line when possible.
        if kind == "ADR review" and existing:
            base = existing
            # Strip leading "ADR review (date):" if present
            if ":" in base:
                base = base.split(":", 1)[1].strip()
            parts = [p for p in (base, outcome) if p]
            # Dedup identical fragments
            uniq: list[str] = []
            for p in parts:
                if p not in uniq:
                    uniq.append(p)
            return f"{kind} ({stamp}): " + " ".join(uniq)
        return f"{kind} ({stamp}): {outcome}"

    if section:
        body = section.group(2)
        kind_re = re.compile(rf"^({re.escape(kind)}.*)$", re.MULTILINE | re.IGNORECASE)
        m = kind_re.search(body)
        if m:
            new_line = merge_line(m.group(1))
            body = kind_re.sub(new_line, body, count=1)
        else:
            new_line = f"{kind} ({stamp}): {outcome}"
            fence = pattern.search(body)
            if fence:
                inner = fence.group(2).rstrip() + "\n" + new_line + "\n"
                body = (
                    body[: fence.start()]
                    + fence.group(1)
                    + inner
                    + fence.group(3)
                    + body[fence.end() :]
                )
            else:
                body = body.rstrip() + "\n" + new_line + "\n"
        text = text[: section.start(2)] + body + text[section.end(2) :]
    else:
        new_line = f"{kind} ({stamp}): {outcome}"
        text = text.rstrip() + f"\n\n## Plan review record\n\n```\n{new_line}\n```\n"
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


def record_green_verify(
    slice_file: str, repo_root: str, result: dict[str, str]
) -> None:
    """Write VERIFY RESULT and set Status to Done."""
    write_verify_result(slice_file, repo_root, result)
    set_slice_status(slice_file, repo_root, "Done")


def is_ignored_commit_path(path: str) -> bool:
    """Paths that must never land in factory split commits."""
    p = (path or "").replace("\\", "/")
    return "/__pycache__/" in p or p.endswith(".pyc")


def check_test_isolation(
    repo_root: str, *, staged: bool = True, log: LogFn | None = None
) -> bool:
    _log = log or (lambda m: None)
    cmd = [os.path.join(repo_root, "scripts", "check-test-isolation.sh")]
    if staged:
        cmd.append("--staged")
    proc = subprocess.run(cmd, cwd=repo_root, capture_output=True, text=True)
    if proc.returncode != 0:
        for line in (proc.stderr or proc.stdout or "").splitlines():
            if line.strip():
                _log(line.strip())
    return proc.returncode == 0


def git_paths_changed(repo_root: str) -> list[str]:
    proc = subprocess.run(
        ["git", "status", "--porcelain", "-uall"],
        cwd=repo_root,
        capture_output=True,
        text=True,
    )
    paths: list[str] = []
    for line in (proc.stdout or "").splitlines():
        if len(line) < 4:
            continue
        path = line[3:].strip()
        if " -> " in path:
            path = path.split(" -> ", 1)[1]
        if is_ignored_commit_path(path):
            continue
        paths.append(path)
    return paths


def log_dirty_commit_paths(repo_root: str, log: LogFn) -> None:
    dirty = git_paths_changed(repo_root)
    if not dirty:
        return
    log(f"commit phase incomplete — {len(dirty)} path(s) still dirty:")
    for path in dirty[:12]:
        log(f"  {path}")
    if len(dirty) > 12:
        log(f"  … and {len(dirty) - 12} more")


def split_paths_for_commits(paths: list[str]) -> tuple[list[str], list[str], list[str]]:
    """Return (test_paths, app_paths, other_paths)."""
    tests: list[str] = []
    apps: list[str] = []
    other: list[str] = []
    for p in paths:
        if p.startswith("PodWash/PodWashTests/") or p.startswith("PodWash/PodWashUITests/") or p.startswith("PodWash/PodWashSlowTests/"):
            tests.append(p)
        elif p.startswith("PodWash/PodWash/"):
            apps.append(p)
        else:
            other.append(p)
    return tests, apps, other


def run_git(repo_root: str, args: list[str], log: LogFn | None = None) -> int:
    _log = log or (lambda m: None)
    _log(f"git {' '.join(args)}")
    proc = subprocess.run(["git", *args], cwd=repo_root, capture_output=True, text=True)
    if proc.returncode != 0:
        _log(f"git failed: {(proc.stderr or proc.stdout or '').strip()}")
    return proc.returncode


def commit_test_spec_changes(
    slice_id: int,
    repo_root: str,
    *,
    log: LogFn | None = None,
) -> bool:
    """Commit only test paths as ``slice-NN: test spec`` (no push).

    Called after test_spec + test_review clear so a later halt never orphans
    authored tests on disk.
    """
    _log = log or (lambda m: None)
    nn = f"{slice_id:02d}"
    paths = git_paths_changed(repo_root)
    tests, _apps, _other = split_paths_for_commits(paths)
    if not tests:
        _log("commit test spec: no test paths changed")
        return True
    if run_git(repo_root, ["add", "--", *tests], log=_log) != 0:
        return False
    if not check_test_isolation(repo_root, staged=True, log=_log):
        _log("check-test-isolation.sh --staged FAILED — aborting test-spec commit")
        run_git(repo_root, ["reset", "HEAD"], log=_log)
        return False
    ok = run_git(repo_root, ["commit", "-m", f"slice-{nn}: test spec"], log=_log) == 0
    if ok:
        _log(f"committed slice-{nn}: test spec ({len(tests)} path(s))")
    return ok


def commit_slice_changes(
    slice_id: int,
    repo_root: str,
    *,
    log: LogFn | None = None,
    push: bool = True,
    fix_mode: bool = True,
) -> bool:
    """Split-commit tests vs app vs docs, run isolation check, optionally push.

    Factory v3: default ``fix_mode`` uses ``fix tests`` / ``fix app`` /
    ``fix docs`` so Mechanic deltas never share a commit with mixed targets.
    """
    _log = log or (lambda m: None)
    paths = git_paths_changed(repo_root)
    if not paths:
        _log("commit: nothing to commit")
        return True
    if fix_mode:
        ok = commit_mechanic_deltas(slice_id, repo_root, paths, log=_log)
    else:
        nn = f"{slice_id:02d}"
        tests, apps, other = split_paths_for_commits(paths)

        def stage_and_commit(files: list[str], message: str) -> bool:
            if not files:
                return True
            if run_git(repo_root, ["add", "--", *files], log=_log) != 0:
                return False
            if not check_test_isolation(repo_root, staged=True, log=_log):
                _log("check-test-isolation.sh --staged FAILED — aborting commit")
                run_git(repo_root, ["reset", "HEAD"], log=_log)
                return False
            return run_git(repo_root, ["commit", "-m", message], log=_log) == 0

        ok = True
        for batch, message in (
            (tests, f"slice-{nn}: test spec"),
            (apps + other, f"slice-{nn}: implement"),
        ):
            if not batch:
                continue
            if not stage_and_commit(batch, message):
                ok = False
                break
    if not ok:
        log_dirty_commit_paths(repo_root, _log)
        _log("push skipped — commit phase incomplete")
        return False
    if push:
        if run_git(repo_root, ["push"], log=_log) != 0:
            _log("git push failed")
            return False
    return True


# ---------------------------------------------------------------------------
# Fix loop (Phase 1b)
# ---------------------------------------------------------------------------


def run_fix_loop(
    client: Any,
    *,
    slice_file: str,
    repo_root: str,
    api_key: str,
    budget: FixBudget | ProgressTracker | None = None,
    log: LogFn | None = None,
    progress_factory: Callable[..., Any] | None = None,
    verify_fn: Callable[..., VerifyOutcome] | None = None,
    referee_fn: Callable[..., Any] | None = None,  # ignored (v3)
    event_log: EventLog | None = None,
    names: NameAssigner | None = None,
    cast: CastLog | None = None,
) -> VerifyOutcome:
    """Loop-owned verify + Mechanic fix cycles (Factory v3).

    Re-verify order after a fix: **tier 1 (failed tests) → tier 3 (full)**.
    Raises ThrashHalt on no-progress / hard cap; InfraHalt on infra failures.
    ``referee_fn`` is accepted but ignored (no role routing).
    """
    if referee_fn is not None and log:
        log("v3: referee_fn ignored — Mechanic owns all fixes")
    tracker: ProgressTracker
    if isinstance(budget, ProgressTracker):
        tracker = budget
    elif isinstance(budget, FixBudget):
        tracker = budget.to_tracker()
    else:
        tracker = ProgressTracker(max_spawns=DEFAULT_MAX_MECHANIC_SPAWNS)
    return run_fix_cycle(
        client,
        slice_file=slice_file,
        repo_root=repo_root,
        api_key=api_key,
        gate_tier=3,
        tracker=tracker,
        log=log,
        progress_factory=progress_factory,
        verify_fn=verify_fn,
        event_log=event_log,
        names=names,
        cast=cast,
    )




# ---------------------------------------------------------------------------
# Pipeline runner (Phase 2.2)
# ---------------------------------------------------------------------------



def format_tier2_halt_reason(
    outcome: VerifyOutcome,
    *,
    max_runs: int,
    handoff_honored: str = "",
) -> str:
    """Human halt line for tier-2 budget exhaustion — never bare ``still red: []``."""
    fail_cls = outcome_failure_class(outcome)
    detail: list[str] = list(outcome.failures or [])[:3]
    if not detail and outcome.packet is not None:
        detail = list(outcome.packet.raw_failures or [])[:3]
    if not detail and outcome.output:
        be = extract_build_error(outcome.output)
        if be:
            detail = [be]
        else:
            fc = extract_factory_config_error(outcome.output)
            if fc:
                detail = [fc]
    if not detail:
        detail = list(outcome.crashes or [])[:2]
    handoff_bit = ""
    if handoff_honored:
        handoff_bit = f"pending handoff {handoff_honored} was honored once; "
    if detail:
        return (
            f"implement tier-2 gate failed after {max_runs} runs; "
            f"{handoff_bit}"
            f"class={fail_cls}: {detail}"
        )
    return (
        f"implement tier-2 gate failed after {max_runs} runs; "
        f"{handoff_bit}"
        f"class={fail_cls} (no per-test detail — see verify-output-latest.txt)"
    )


def run_tier2_implement_gate(
    client: Any,
    *,
    slice_file: str,
    repo_root: str,
    api_key: str,
    log: LogFn | None = None,
    progress_factory: Callable[..., Any] | None = None,
    verify_fn: Callable[..., VerifyOutcome] | None = None,
    max_runs: int = DEFAULT_MAX_IMPLEMENT_VERIFY_RUNS,
    max_infra_retries: int = DEFAULT_MAX_TIER2_INFRA_RETRIES,
    event_log: EventLog | None = None,
    names: NameAssigner | None = None,
    cast: CastLog | None = None,
) -> VerifyOutcome:
    """Tier-2 implement exit gate via unified Mechanic fix cycle (Factory v3)."""
    tracker = ProgressTracker(max_spawns=max_runs)
    return run_fix_cycle(
        client,
        slice_file=slice_file,
        repo_root=repo_root,
        api_key=api_key,
        gate_tier=2,
        tracker=tracker,
        log=log,
        progress_factory=progress_factory,
        verify_fn=verify_fn,
        event_log=event_log,
        names=names,
        cast=cast,
        max_infra_retries=max_infra_retries,
        write_tier2_marker_on_green=True,
    )



def run_pipeline_slice(
    slice_id: int,
    slice_file: str,
    *,
    api_key: str,
    repo_root: str = REPO_ROOT_DEFAULT,
    log: LogFn | None = None,
    verbose: bool = False,
    heartbeat_secs: int = 90,
    stream_timeout: float | None = 0.0,
    unary_timeout: float = 120.0,
    max_fix_attempts: int = DEFAULT_MAX_FIX_ATTEMPTS,
    max_implement_verify_runs: int = DEFAULT_MAX_IMPLEMENT_VERIFY_RUNS,
    do_commit: bool = True,
    do_push: bool = True,
    progress_cls: Any | None = None,
    preboot_sim: bool = True,
    coordinator_name: str | None = None,
    session_voice: Any | None = None,
) -> tuple[bool, int, dict[str, str] | None, dict[str, Any]]:
    """Drive one slice via the gate FSM.

    Returns ``(ok, elapsed, last_verify, meta)`` where *meta* may include
    ``cast_names`` and ``murphy_visits`` for the end-of-slice coordinator report.
    """
    from slice_loop_progress import (
        extract_slice_accomplishment,
        extract_slice_mission,
        read_slice_meta,
    )

    def _resolve_stream_timeout(secs: float | None) -> float | None:
        if secs is None or secs <= 0:
            return None
        return float(secs)

    _log = log or (lambda m: print(f"[slice-pipeline] {m}", flush=True))
    title, _ = read_slice_meta(slice_file, repo_root)
    mission = extract_slice_mission(slice_file, repo_root)

    budget = ProgressTracker(max_spawns=max_fix_attempts)
    stream_to = _resolve_stream_timeout(stream_timeout)
    t0 = time.time()
    last_verify: dict[str, str] | None = None
    names = NameAssigner()
    cast = CastLog()
    _voice = cast.voice if session_voice is None else session_voice
    if session_voice is not None:
        cast.voice = session_voice
    coordinator = (coordinator_name or "").strip() or names.assign("Coordinator", slot="session")
    print_coordinator_shift_banner(
        slice_id=slice_id,
        title=title,
        slice_file=slice_file,
        mission=mission,
    )
    events = EventLog(repo_root, slice_id, log=_log)

    def _slice_meta() -> dict[str, Any]:
        return {
            "cast_names": cast.cast_names(),
            "murphy_visits": cast.murphy_visits,
            "coordinator_name": coordinator,
        }

    if preboot_sim:
        udid = resolve_sim_udid(log=_log)
        if udid:
            os.environ.setdefault("PODWASH_SIM_UDID", udid)
            ensure_sim_booted(udid, log=_log)
            events.record(
                "SIM", "loop", "sim_boot",
                detail={"udid": udid}, timeline=True, mission="pre-boot simulator",
            )

    def _emit_recap(outcome: str, elapsed: int) -> None:
        accomplishment = None
        if outcome == "green":
            accomplishment = extract_slice_accomplishment(slice_file, repo_root)
        narrate_slice_recap(
            slice_id=slice_id,
            elapsed_secs=elapsed,
            cast=cast,
            outcome=outcome,
            accomplishment=accomplishment,
            log=_log,
        )

    from cursor_bridge import launch_bridge as launch_cursor_bridge

    with launch_cursor_bridge(workspace=repo_root) as bridge_client:
        client = bridge_client.with_options(
            stream_timeout=stream_to,
            unary_timeout=unary_timeout,
        )
        if not try_coordinator_shift_llm(
            client,
            coordinator_name=coordinator,
            slice_id=slice_id,
            title=title,
            mission=mission,
            api_key=api_key,
            repo_root=repo_root,
            log=_log,
            run_worker=run_worker,
        ):
            narrate_coordinator_shift_prose(
                coordinator_name=coordinator,
                slice_id=slice_id,
                title=title,
                mission=mission,
                log=_log,
                voice=_voice,
            )

        # Authoring gates until implement artifacts exist (tier-2 is separate)
        while True:
            state = assess_gate_state(slice_file, repo_root)
            gid = next_gate(state)
            if gid is None:
                break
            if gid in ("verify", "record", "commit"):
                break
            # Always spawn implement at least once when pending — even if artifacts
            # already exist (skipping left tier-2 burning budget on a broken build).
            # After the worker, the post-gate check breaks into the tier-2 gate.
            if gid in ("adr_review_qa", "adr_review_pm"):
                ready = [
                    g
                    for g in gates_ready_for_parallel(state)
                    if g in ("adr_review_qa", "adr_review_pm")
                ]
                for rg in ready or [gid]:
                    role = GATE_ROLE[rg]
                    agent = names.assign(role, slot=rg)
                    act, total = _act_position(state, rg)
                    label = GATE_LABELS.get(rg, rg)
                    narrate_chapter_open(
                        slice_id=slice_id,
                        gate_label=label,
                        role=role,
                        name=agent,
                        act=act,
                        total=total,
                        log=_log,
                        voice=_voice,
                    )
                    cast.add(role, agent, rg)
                    prompt = build_gate_prompt(rg, slice_file, repo_root)
                    prog = None
                    if progress_cls:
                        prog = progress_cls(
                            slice_id, title, slice_file, _log,
                            verbose=verbose, heartbeat_secs=heartbeat_secs,
                            repo_root=repo_root,
                            forced_role=role,
                            agent_name=agent,
                            authoring_gate=rg in AUTHORING_GATES,
                            gate_id=rg,
                            event_log=events,
                        )
                    events.record(
                        "IMPLEMENT", role, "spawn",
                        agent_name=agent, timeline=False, mission=f"gate {rg}",
                    )
                    t_gate = time.time()
                    ok, _ = run_worker(
                        client, role=role, prompt=prompt, api_key=api_key,
                        repo_root=repo_root, log=_log, progress=prog,
                    )
                    if ok:
                        kind = "ADR review"
                        who = "QA" if rg == "adr_review_qa" else "PM"
                        append_plan_review_outcome(
                            slice_file, repo_root,
                            kind=kind,
                            outcome=f"{who} cleared — pipeline worker finished",
                        )
                        narrate_gate_cleared(
                            agent, label,
                            elapsed_secs=time.time() - t_gate,
                            log=_log,
                            voice=_voice,
                        )
                        if prog is not None and hasattr(prog, "log_gate_progress"):
                            prog.log_gate_progress(force=True)
                        else:
                            _log(assess_gate_state(slice_file, repo_root).summary)
                continue

            role = GATE_ROLE.get(gid)
            if not role:
                _log(f"no worker for gate {gid} — stopping")
                break
            if gid == "architect":
                if normalize_slice_adr_placeholders(slice_file, repo_root):
                    _log("resolved ADR 0XX/XXX placeholders in slice file")
            agent = names.assign(role, slot=gid)
            act, total = _act_position(state, gid)
            label = GATE_LABELS.get(gid, gid)
            narrate_chapter_open(
                slice_id=slice_id,
                gate_label=label,
                role=role,
                name=agent,
                act=act,
                total=total,
                log=_log,
                voice=_voice,
            )
            cast.add(role, agent, gid)
            prompt = build_gate_prompt(gid, slice_file, repo_root)
            prog = None
            if progress_cls:
                prog = progress_cls(
                    slice_id, title, slice_file, _log,
                    verbose=verbose, heartbeat_secs=heartbeat_secs,
                    repo_root=repo_root,
                    forced_role=role,
                    agent_name=agent,
                    authoring_gate=gid in AUTHORING_GATES,
                    gate_id=gid,
                    event_log=events,
                )
            events.record(
                "IMPLEMENT" if gid == "implement" else gid.upper(),
                role, "spawn",
                agent_name=agent, timeline=False, mission=f"gate {gid}",
            )
            t_gate = time.time()
            ok, status = run_worker(
                client, role=role, prompt=prompt, api_key=api_key,
                repo_root=repo_root, log=_log, progress=prog,
            )
            gate_secs = time.time() - t_gate
            if prog is not None and hasattr(prog, "assistant_text"):
                summary = parse_summary_line(prog.assistant_text or "")
                if summary:
                    narrate_worker_done(agent, summary, log=_log, voice=_voice)
            if gid == "test_review" and ok:
                append_plan_review_outcome(
                    slice_file, repo_root,
                    kind="Test spec review",
                    outcome="Architect cleared — pipeline worker finished",
                )
                # Durability: commit authored tests so a later halt never orphans them.
                if not commit_test_spec_changes(slice_id, repo_root, log=_log):
                    _log("test-spec commit failed (continuing — artifacts remain on disk)")
            # Deterministic Ready flip: PM owns content; harness owns Status.
            if gid == "story" and ok:
                text = _read_slice_text(slice_file, repo_root)
                if _story_content_ok(text):
                    st = _status_from_text(text).lower()
                    if st in ("", "draft"):
                        set_slice_status(slice_file, repo_root, "Ready")
                        _log("story content ok — set Status Ready")
                    if normalize_slice_adr_placeholders(slice_file, repo_root):
                        _log("resolved ADR 0XX/XXX placeholders in slice file")
            if not ok:
                explain = explain_gate_pending(gid, slice_file, repo_root)
                narrate_gate_stuck(label, explain, log=_log, voice=_voice)
                narrate_role_report(
                    agent,
                    extract_gate_stuck_body(explain),
                    log=_log,
                    voice=_voice,
                )
                elapsed = int(time.time() - t0)
                _emit_recap("halt", elapsed)
                return False, elapsed, last_verify, _slice_meta()

            after = assess_gate_state(slice_file, repo_root)
            if after.gate(gid).applicable and not after.gate(gid).satisfied:
                if gid in ("adr_review_qa", "adr_review_pm", "test_review"):
                    # Review outcomes written above; treat as cleared for story.
                    narrate_gate_cleared(
                        agent, label, elapsed_secs=gate_secs, log=_log, voice=_voice,
                    )
                    if prog is not None and hasattr(prog, "log_gate_progress"):
                        prog.log_gate_progress(force=True)
                elif gid == "implement":
                    # Artifacts may exist now — tier-2 gate handles the rest
                    text = _read_slice_text(slice_file, repo_root)
                    if _implement_artifacts_exist(text, repo_root):
                        narrate_gate_cleared(
                            agent, label, elapsed_secs=gate_secs, log=_log, voice=_voice,
                        )
                        break
                    explain = explain_gate_pending(gid, slice_file, repo_root)
                    narrate_gate_stuck(label, explain, log=_log, voice=_voice)
                    narrate_role_report(
                        agent,
                        extract_gate_stuck_body(explain),
                        log=_log,
                        voice=_voice,
                    )
                    elapsed = int(time.time() - t0)
                    _emit_recap("halt", elapsed)
                    return False, elapsed, last_verify, _slice_meta()
                else:
                    explain = explain_gate_pending(gid, slice_file, repo_root)
                    narrate_gate_stuck(label, explain, log=_log, voice=_voice)
                    narrate_role_report(
                        agent,
                        extract_gate_stuck_body(explain),
                        log=_log,
                        voice=_voice,
                    )
                    elapsed = int(time.time() - t0)
                    _emit_recap("halt", elapsed)
                    return False, elapsed, last_verify, _slice_meta()
            else:
                nxt = next_gate(after)
                next_label = GATE_LABELS.get(nxt, nxt) if nxt else None
                next_name = None
                if nxt and nxt in GATE_ROLE:
                    next_name = names.assign(GATE_ROLE[nxt], slot=nxt)
                narrate_gate_cleared(
                    agent,
                    label,
                    next_label=next_label,
                    next_name=next_name,
                    elapsed_secs=gate_secs,
                    log=_log,
                    voice=_voice,
                )
                if prog is not None and hasattr(prog, "log_gate_progress"):
                    prog.log_gate_progress(force=True)
                else:
                    _log(after.summary)

        def progress_factory(role: str, agent_name: str | None = None) -> Any:
            if not progress_cls:
                return None
            label = agent_name or names.assign(role, slot=f"progress-{role}")
            return progress_cls(
                slice_id, title, slice_file, _log,
                verbose=verbose, heartbeat_secs=heartbeat_secs,
                repo_root=repo_root,
                forced_role=role,
                agent_name=label,
                fix_worker=role in FIX_WORKER_ROLES,
            )

        # P1: implement exit = tier-2 green
        text = _read_slice_text(slice_file, repo_root)
        if _implement_artifacts_exist(text, repo_root) and not tier2_marker_ok(
            repo_root, slice_id
        ):
            try:
                run_tier2_implement_gate(
                    client,
                    slice_file=slice_file,
                    repo_root=repo_root,
                    api_key=api_key,
                    log=_log,
                    progress_factory=progress_factory,
                    max_runs=max_implement_verify_runs,
                    event_log=events,
                    names=names,
                    cast=cast,
                )
            except ThrashHalt as thrash:
                _log(f"TIER2 HALT: {thrash.reason}")
                elapsed = int(time.time() - t0)
                _emit_recap("halt", elapsed)
                raise

        try:
            outcome = run_fix_loop(
                client,
                slice_file=slice_file,
                repo_root=repo_root,
                api_key=api_key,
                budget=budget,
                log=_log,
                progress_factory=progress_factory,
                event_log=events,
                names=names,
                cast=cast,
            )
        except InfraHalt as infra:
            _log(f"INFRA HALT: {infra.reason}")
            elapsed = int(time.time() - t0)
            _emit_recap("halt", elapsed)
            raise
        except ThrashHalt as thrash:
            _log(f"THRASH HALT: {thrash.reason}")
            elapsed = int(time.time() - t0)
            _emit_recap("halt", elapsed)
            raise

        last_verify = outcome.result
        if not outcome.green or not outcome.result:
            elapsed = int(time.time() - t0)
            _emit_recap("red", elapsed)
            return False, elapsed, last_verify, _slice_meta()

        events.record("RECORD", "loop", "record_start", timeline=True, mission="VERIFY RESULT")
        write_verify_result(slice_file, repo_root, outcome.result)
        _log("recorded VERIFY RESULT")

        if do_commit:
            events.record("COMMIT", "loop", "commit_start", timeline=True, mission="split commits")
            if not commit_slice_changes(
                slice_id, repo_root, log=_log, push=do_push
            ):
                set_slice_status(slice_file, repo_root, "Verify")
                _log("commit/push incomplete — Status reverted to Verify")
                elapsed = int(time.time() - t0)
                _emit_recap("halt", elapsed)
                return False, elapsed, last_verify, _slice_meta()
            set_slice_status(slice_file, repo_root, "Done")
            _log("Status Done" + (" + pushed" if do_push else ""))
        else:
            set_slice_status(slice_file, repo_root, "Done")
            _log("Status Done (commit skipped)")

    elapsed = int(time.time() - t0)
    _emit_recap("green", elapsed)
    return True, elapsed, last_verify, _slice_meta()


# ---------------------------------------------------------------------------
# Coordinator handoff helpers (Phase 1)
# ---------------------------------------------------------------------------


def run_post_coordinator_verify(
    client: Any | None,
    *,
    slice_file: str,
    repo_root: str,
    api_key: str,
    budget: FixBudget,
    log: LogFn | None = None,
    progress_factory: Callable[[str], Any] | None = None,
    spawn_workers: bool = True,
) -> VerifyOutcome:
    """After coordinator authoring: loop owns verify (+ optional fix workers)."""
    _log = log or (lambda m: None)
    if not should_loop_own_verify(slice_file, repo_root):
        _log("skip loop-owned verify — implement gate not ready / status not mid-flight")
        return VerifyOutcome(result=None, green=False, failures=["implement not ready"])

    if not spawn_workers or client is None:
        outcome = run_verify(repo_root, log=_log)
        if not outcome.green:
            raise ThrashHalt(
                f"loop-owned verify red (no fix workers): {outcome.failures[:3]}"
            )
        return outcome

    return run_fix_loop(
        client,
        slice_file=slice_file,
        repo_root=repo_root,
        api_key=api_key,
        budget=budget,
        log=_log,
        progress_factory=progress_factory,
    )
