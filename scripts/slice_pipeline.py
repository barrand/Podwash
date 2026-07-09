#!/usr/bin/env python3
"""PodWash slice pipeline — loop-as-orchestrator (Option B).

Python owns gate ordering, verify.sh, fix routing, Done-artifact writing, and
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
    extract_slice_swift_paths,
    format_stuck_card,
    merge_diagnose_into_packet,
    parse_diagnose_reply,
    persist_stuck_card,
    is_flake_signal,
)
from fix_playbooks import select_lever, starter_lever_text
from slice_loop_progress import (
    ThrashHalt,
    _implement_artifacts_exist,
    _mapped_test_files_exist,
    _path_exists,
    _plan_review_line,
    _read_slice_text,
    _review_cleared,
    _role_artifact_rows,
    _status_from_text,
    _verification_mapping_filled,
    detect_simulator_crashes,
    detect_test_failures,
    latest_xcresult_path,
    parse_verify_result,
    read_failures_from_xcresult,
    verify_is_green,
)

REPO_ROOT_DEFAULT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VERIFY_SH = os.path.join(REPO_ROOT_DEFAULT, "scripts", "verify.sh")
CHECK_ISOLATION = os.path.join(REPO_ROOT_DEFAULT, "scripts", "check-test-isolation.sh")
AGENTS_DIR = os.path.join(REPO_ROOT_DEFAULT, ".cursor", "agents")

DEFAULT_MAX_FIX_ATTEMPTS = 2

# Plain SDK model ids — never scrape frontmatter bracket syntax.
ROLE_MODELS: dict[str, str] = {
    "PM": "composer-2.5",
    "UX": "composer-2.5",
    "QA": "composer-2.5",
    "Architect": "grok-4.5",
    "Engineer": "grok-4.5",
    "PM review": "composer-2.5",
    "QA review": "composer-2.5",
    "Architect review": "grok-4.5",
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
}

# Reviewers run in SDK plan mode (read-only). Authors/fixers use agent mode.
PLAN_MODE_ROLES = frozenset({"PM review", "QA review", "Architect review"})

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
    """Shared fix-attempt budget that survives bridge retries."""

    max_attempts: int = DEFAULT_MAX_FIX_ATTEMPTS
    attempts_used: int = 0
    last_signature: str = ""
    last_role: str = ""
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


@dataclass
class VerifyOutcome:
    result: dict[str, str] | None
    green: bool
    failures: list[str] = field(default_factory=list)
    crashes: list[str] = field(default_factory=list)
    output: str = ""
    elapsed_secs: float = 0.0
    packet: FailurePacket | None = None


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
    if _path_exists(repo_root, path):
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


def _story_done(text: str) -> bool:
    status = _status_from_text(text).lower()
    if status in ("", "draft"):
        return False
    if not re.search(r"^\| \*\*Crux\*\* \|.+\|", text, re.MULTILINE):
        return False
    body = ""
    # Prefer Acceptance criteria section
    from slice_loop_progress import _section_body

    body = _section_body(text, "Acceptance criteria")
    if not re.search(r"^- \[[ xX]\]", body, re.MULTILINE):
        return False
    return True


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

    statuses: dict[GateId, tuple[GateStatus, bool]] = {
        "story": ("done" if _story_done(text) else "pending", True),
        "architect": (arch_st, arch_on),
        "ux": (ux_st, ux_on),
        "adr_review_qa": (adr_qa_st, adr_qa_on),
        "adr_review_pm": (adr_pm_st, adr_pm_on),
        "test_spec": ("done" if test_spec_ok else "pending", True),
        "test_review": ("done" if test_review_ok else "pending", True),
        "implement": (
            "done" if _implement_artifacts_exist(text, repo_root) else "pending",
            True,
        ),
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
) -> VerifyOutcome:
    """Run scripts/verify.sh as a subprocess; parse VERIFY RESULT as truth."""
    _log = log or (lambda m: None)
    cmd = [VERIFY_SH if repo_root == REPO_ROOT_DEFAULT else os.path.join(repo_root, "scripts", "verify.sh")]
    if extra_args:
        cmd.extend(extra_args)
    _log(f"loop-owned verify: {' '.join(cmd)}")
    t0 = time.time()
    proc = subprocess.run(
        cmd,
        cwd=repo_root,
        capture_output=True,
        text=True,
    )
    elapsed = time.time() - t0
    output = (proc.stdout or "") + "\n" + (proc.stderr or "")
    result = parse_verify_result(output)
    if result is None and proc.returncode != 0:
        result = {
            "exit": str(proc.returncode),
            "total": "?",
            "passed": "?",
            "failed": "?",
            "skipped": "?",
        }
    green = verify_is_green(result)
    failures = detect_test_failures(output)
    crashes = detect_simulator_crashes(output)
    bundle = (result or {}).get("bundle") or latest_xcresult_path(repo_root)
    if bundle and not failures:
        failures = read_failures_from_xcresult(bundle)
    if result and bundle and "bundle" not in result:
        result = dict(result)
        result["bundle"] = bundle
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
        path = persist_stuck_card(card, repo_root=repo_root, slice_file=slice_file)
        _log(f"stuck card:\n{card}")
        _log(f"stuck card written: {path}")
    _log(
        f"loop-owned verify done: green={green} exit={(result or {}).get('exit')} "
        f"failed={(result or {}).get('failed')} elapsed={elapsed:.0f}s"
    )
    return VerifyOutcome(
        result=result,
        green=green,
        failures=failures,
        crashes=crashes,
        output=output,
        elapsed_secs=elapsed,
        packet=packet,
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
    """Return 'Engineer' or 'QA' for the next fix worker."""
    if lever_role in ("Engineer", "QA"):
        return lever_role
    if packet is not None:
        cls = packet.failure_class
        sig = packet.signature or failure_signature(failures, crashes)
        if previous_role == "Engineer" and previous_signature and previous_signature == sig:
            if cls == "ui_race":
                return "QA"  # may become halt at lever select
            return "QA"
        if cls in ("crash", "ui_race", "missing_identifier", "wrong_state", "build_error"):
            if cls == "build_error" and packet.fix_scope == "tests":
                return "QA"
            return "Engineer"
        if cls == "assertion":
            return "QA" if packet.fix_scope == "tests" else "Engineer"
        if crashes or packet.crashes:
            return "Engineer"

    blob = "\n".join(failures + crashes)
    sig = failure_signature(failures, crashes)

    if crashes:
        return "Engineer"
    if previous_role == "Engineer" and previous_signature and previous_signature == sig:
        return "QA"
    if _TEST_PATH_HINT.search(blob) and not _APP_PATH_HINT.search(blob):
        # Pure test-side wording without app paths
        testish = any(
            tok in blob.lower()
            for tok in ("fixture", "xctassert", "golden", "test case", "uitest")
        )
        appish = any(
            tok in blob.lower()
            for tok in ("viewmodel", "view.swift", "crash", "nil", "unexpectedly")
        )
        if testish and not appish:
            return "QA"
    return "Engineer"


def failure_signature(failures: list[str], crashes: list[str]) -> str:
    parts = sorted({re.sub(r"\s+", " ", x.strip().lower())[:80] for x in failures + crashes})
    return "|".join(parts[:5])


def build_diagnose_prompt(packet: FailurePacket, slice_file: str, card: str) -> str:
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
) -> str:
    persona = load_persona(role)
    scope = (
        "PodWash/PodWash/** only (no tests)"
        if role == "Engineer"
        else "PodWash/{PodWashTests,PodWashUITests,PodWashSlowTests}/** + fixtures only"
    )
    fail_lines = "\n".join(f"- {f}" for f in (failures or ["(unknown failure)"]))
    crash_lines = "\n".join(f"- {c}" for c in crashes) if crashes else "(none)"
    bundle_line = bundle or "(none — check build/test-results/)"
    card_block = stuck_card.strip() or "(no stuck card)"
    lever_block = lever_instruction or "(no playbook lever — minimal change)"
    forbid_block = ", ".join(lever_forbid) if lever_forbid else "(none)"
    files = suggested_files or (packet.suggested_files if packet else [])
    files_block = ", ".join(files) if files else "(none suggested)"
    history = ""
    if attempt_notes:
        history = "Attempt history:\n" + "\n".join(f"- {n}" for n in attempt_notes)
    packet_block = ""
    if packet:
        packet_block = f"""
FailurePacket:
- class: {packet.failure_class}
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
Slice file: {slice_file}

**Edit scope (hard):** {scope}
Do NOT run scripts/verify.sh or `xcodebuild … test` — the outer loop owns verification.
If you need failure detail, read the stuck card / xcresult attachments already provided.
Do NOT edit docs except if QA needs a fixture README note.

Stuck card:
{card_block}

Playbook lever for this attempt:
{lever_block}
Forbidden: {forbid_block}
Suggested files: {files_block}

{history}
{packet_block}
Failing tests:
{fail_lines}

Simulator crashes:
{crash_lines}

xcresult bundle: {bundle_line}

Diagnose, make the minimal fix in scope, then end your turn. Do not verify.
"""


# ---------------------------------------------------------------------------
# Workers / personas / models
# ---------------------------------------------------------------------------


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
            "out-of-scope, verification commands. Edit only this slice markdown."
        ),
        "architect": (
            "Author the ADR / design note for this slice. Edit only docs/adr/** "
            "(and slice design notes if needed)."
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
            "tests/fixtures under PodWashTests/UITests. Do NOT edit app Swift."
        ),
        "test_review": (
            "Readonly test-spec review vs ADR-000 + slice ADR. Do not edit files. "
            "Return 'Architect cleared — …' or blockers."
        ),
        "implement": (
            "Implement app code under PodWash/PodWash/** to pass existing tests. "
            "Do NOT edit tests. Do NOT run verify.sh."
        ),
    }
    task = tasks.get(gate_id, f"Complete the {gate_id} gate for this slice.")
    return f"""{persona}

Gate: {gate_id} ({GATE_LABELS.get(gate_id, gate_id)})
Slice file: {slice_file}
SDK mode: {mode}
Repo: {repo_root}

{task}

Read the slice file and only the artifacts needed for this gate. End your turn when done.
"""


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
    model = model_for_role(role)
    mode = mode_for_role(role)
    _log(f"worker start: role={role} model={model} mode={mode}")

    options = AgentOptions(
        api_key=api_key,
        model=model,
        local=LocalAgentOptions(cwd=repo_root),
        mode=mode,  # type: ignore[arg-type]
    )
    with client.create_agent(options) as agent:
        run = agent.send(prompt)
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
                # Collect assistant text for diagnose parse
                text = ""
                if isinstance(message, dict) and message.get("type") == "assistant":
                    text = str(
                        message.get("text")
                        or message.get("content")
                        or message.get("message")
                        or ""
                    )
                else:
                    mtype = getattr(message, "type", None)
                    if mtype == "assistant":
                        text = str(
                            getattr(message, "text", "")
                            or getattr(message, "content", "")
                            or ""
                        )
                if text:
                    assistant_bits.append(text)
                    if on_assistant_text:
                        on_assistant_text(text)
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
        _log(f"worker finished: role={role} status={status}")
        if on_assistant_text is None and assistant_bits and hasattr(run, "_podwash_assistant"):
            pass
        # Stash for callers that want diagnose text via progress
        if progress is not None and hasattr(progress, "set_assistant_text"):
            progress.set_assistant_text("\n".join(assistant_bits))
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


def check_test_isolation(repo_root: str, *, staged: bool = True) -> bool:
    cmd = [os.path.join(repo_root, "scripts", "check-test-isolation.sh")]
    if staged:
        cmd.append("--staged")
    proc = subprocess.run(cmd, cwd=repo_root, capture_output=True, text=True)
    return proc.returncode == 0


def git_paths_changed(repo_root: str) -> list[str]:
    proc = subprocess.run(
        ["git", "status", "--porcelain"],
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
        paths.append(path)
    return paths


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


def commit_slice_changes(
    slice_id: int,
    repo_root: str,
    *,
    log: LogFn | None = None,
    push: bool = True,
) -> bool:
    """Split-commit tests vs app, run isolation check, optionally push."""
    _log = log or (lambda m: None)
    nn = f"{slice_id:02d}"
    paths = git_paths_changed(repo_root)
    if not paths:
        _log("commit: nothing to commit")
        return True
    tests, apps, other = split_paths_for_commits(paths)

    def stage_and_commit(files: list[str], message: str) -> bool:
        if not files:
            return True
        if run_git(repo_root, ["add", "--", *files], log=_log) != 0:
            return False
        if not check_test_isolation(repo_root, staged=True):
            _log("check-test-isolation.sh --staged FAILED — aborting commit")
            run_git(repo_root, ["reset", "HEAD"], log=_log)
            return False
        return run_git(repo_root, ["commit", "-m", message], log=_log) == 0

    # Tests first (with neutral docs that aren't status-only if mixed — keep other with implement)
    ok = True
    if tests:
        ok = stage_and_commit(tests, f"slice-{nn}: test spec") and ok
    implement_files = apps + other
    if implement_files:
        ok = stage_and_commit(implement_files, f"slice-{nn}: implement") and ok
    if ok and push:
        ok = run_git(repo_root, ["push"], log=_log) == 0
    return ok


# ---------------------------------------------------------------------------
# Fix loop (Phase 1b)
# ---------------------------------------------------------------------------


def run_fix_loop(
    client: Any,
    *,
    slice_file: str,
    repo_root: str,
    api_key: str,
    budget: FixBudget,
    log: LogFn | None = None,
    progress_factory: Callable[[str], Any] | None = None,
    verify_fn: Callable[..., VerifyOutcome] | None = None,
) -> VerifyOutcome:
    """Loop-owned verify + bounded Engineer|QA fix workers.

    Raises ThrashHalt when budget is exhausted on red.
    """
    _log = log or (lambda m: None)
    _verify = verify_fn or (
        lambda **kw: run_verify(repo_root, log=_log, slice_file=slice_file)
    )

    def _do_verify() -> VerifyOutcome:
        try:
            return _verify(slice_file=slice_file)
        except TypeError:
            return _verify()

    outcome = _do_verify()
    if outcome.green:
        return outcome

    slice_text = ""
    try:
        slice_text = _read_slice_text(slice_file, repo_root)
    except OSError:
        slice_text = ""
    slice_files = extract_slice_swift_paths(slice_text)

    while not budget.exhausted():
        packet = outcome.packet or build_failure_packet(
            failures=outcome.failures,
            crashes=outcome.crashes,
            bundle=(outcome.result or {}).get("bundle"),
            exit_code=(outcome.result or {}).get("exit"),
            output=outcome.output,
            repo_root=repo_root,
            export_attachments=False,
        )
        if slice_files and not packet.suggested_files:
            packet = packet.with_updates(suggested_files=list(slice_files))

        if not packet.actionable:
            card = format_stuck_card(
                packet, slice_file=slice_file, attempt=budget.attempts_used,
                max_attempts=budget.max_attempts,
            )
            persist_stuck_card(card, repo_root=repo_root, slice_file=slice_file)
            _log(card)
            raise ThrashHalt(packet.halt_reason or "no actionable evidence")

        # Flake: one cold re-verify without burning fix budget
        if (
            (is_flake_signal(packet) or packet.failure_class == "flake")
            and not budget.flake_cold_retried
        ):
            budget.flake_cold_retried = True
            _log("flake signal — cold re-verify (does not burn fix budget)")
            outcome = _do_verify()
            if outcome.green:
                return outcome
            continue

        sig = packet.signature or failure_signature(outcome.failures, outcome.crashes)
        same = bool(budget.last_signature and budget.last_signature == sig)
        lever_index = (budget.last_lever_index + 1) if same else 0
        if not same:
            lever_index = 0

        # Free diagnose (does not burn fix budget)
        need_diagnose = (
            packet.failure_class == "unknown"
            or packet.failure_class == "assertion"
            or (
                budget.attempts_used == 0
                and any("uitest" in t.lower() for t in packet.test_ids)
            )
        )
        if need_diagnose and client is not None:
            card0 = format_stuck_card(
                packet,
                slice_file=slice_file,
                attempt=budget.attempts_used + 1,
                max_attempts=budget.max_attempts,
                lever=starter_lever_text(packet.failure_class),
            )
            dprompt = build_diagnose_prompt(packet, slice_file, card0)
            _log("diagnose worker (free, plan mode)")
            dprogress = progress_factory("QA review") if progress_factory else None
            ok_d, _status_d = run_worker(
                client,
                role="QA review",
                prompt=dprompt,
                api_key=api_key,
                repo_root=repo_root,
                log=_log,
                progress=dprogress,
            )
            diag_text = ""
            if dprogress is not None and hasattr(dprogress, "assistant_text"):
                diag_text = dprogress.assistant_text or ""
            parsed = parse_diagnose_reply(diag_text)
            if parsed:
                packet = merge_diagnose_into_packet(packet, parsed)
                _log(
                    f"diagnose merged: class={packet.failure_class} "
                    f"scope={packet.fix_scope} hyp={packet.hypothesis[:80]}"
                )
            elif not ok_d:
                _log("diagnose failed to parse — keeping heuristic class")

        allow_wait = (
            packet.fix_scope == "tests"
            and "transient" in (packet.hypothesis or "").lower()
        ) or (
            packet.fix_scope == "tests"
            and "ac" in (packet.hypothesis or "").lower()
        )
        lever = select_lever(
            packet.failure_class,
            lever_index=lever_index,
            fix_scope=packet.fix_scope,
            allow_uitest_wait_fix=allow_wait,
        )
        if lever.role == "halt":
            card = format_stuck_card(
                packet,
                slice_file=slice_file,
                attempt=budget.attempts_used,
                max_attempts=budget.max_attempts,
                lever=lever.instruction,
                levers_tried=budget.levers_tried + [lever.instruction[:80]],
            )
            persist_stuck_card(card, repo_root=repo_root, slice_file=slice_file)
            _log(card)
            raise ThrashHalt(
                f"playbook halt ({packet.failure_class}): {lever.instruction}"
            )

        suggested = list(
            dict.fromkeys(
                list(packet.suggested_files)
                + list(lever.suggested_files)
                + list(slice_files)
            )
        )
        packet = packet.with_updates(suggested_files=suggested)
        role = route_fix(
            outcome.failures,
            outcome.crashes,
            previous_role=budget.last_role,
            previous_signature=budget.last_signature,
            packet=packet,
            lever_role=lever.role,
        )
        attempt = budget.attempts_used + 1
        bundle = (outcome.result or {}).get("bundle") or latest_xcresult_path(repo_root)
        card = format_stuck_card(
            packet,
            slice_file=slice_file,
            attempt=attempt,
            max_attempts=budget.max_attempts,
            next_role=role,
            lever=f"{lever.instruction} ({role})",
            levers_tried=budget.levers_tried,
        )
        persist_stuck_card(card, repo_root=repo_root, slice_file=slice_file)
        _log(card)

        prompt = build_fix_prompt(
            role,
            slice_file,
            outcome.failures or packet.raw_failures,
            outcome.crashes or packet.crashes,
            bundle,
            attempt,
            budget.max_attempts,
            packet=packet,
            stuck_card=card,
            lever_instruction=lever.instruction,
            lever_forbid=lever.forbid,
            attempt_notes=list(budget.attempt_notes),
            suggested_files=suggested,
        )
        _log(
            f"fix attempt {attempt}/{budget.max_attempts}: role={role} "
            f"class={packet.failure_class} lever={lever_index} "
            f"failures={(outcome.failures or packet.raw_failures)[:3]}"
        )
        progress = progress_factory(role) if progress_factory else None
        ok, status = run_worker(
            client,
            role=role,
            prompt=prompt,
            api_key=api_key,
            repo_root=repo_root,
            log=_log,
            progress=progress,
        )
        note = (
            f"attempt {attempt}: role={role} class={packet.failure_class} "
            f"hyp={packet.hypothesis[:60] or 'n/a'} status={status}"
        )
        budget.record(role, sig, note=note)
        budget.last_packet = packet
        budget.last_class = packet.failure_class
        budget.last_hypothesis = packet.hypothesis
        budget.last_lever_index = lever_index
        budget.levers_tried.append(f"L{lever_index}:{role}:{lever.instruction[:60]}")
        if not ok:
            _log(f"fix worker did not finish cleanly (status={status})")
        outcome = _do_verify()
        if outcome.green:
            return outcome
        # Refresh packet signature comparison on next loop
        if outcome.packet is None:
            outcome.packet = build_failure_packet(
                failures=outcome.failures,
                crashes=outcome.crashes,
                bundle=(outcome.result or {}).get("bundle"),
                exit_code=(outcome.result or {}).get("exit"),
                output=outcome.output,
                repo_root=repo_root,
                export_attachments=False,
            )

    packet = outcome.packet
    card = format_stuck_card(
        packet or FailurePacket(raw_failures=outcome.failures),
        slice_file=slice_file,
        attempt=budget.attempts_used,
        max_attempts=budget.max_attempts,
        levers_tried=budget.levers_tried,
    )
    persist_stuck_card(card, repo_root=repo_root, slice_file=slice_file)
    _log(card)
    reason = (
        f"fix budget exhausted ({budget.max_attempts} attempts); "
        f"still red: {outcome.failures[:3] or outcome.crashes[:2]}"
    )
    raise ThrashHalt(reason)


# ---------------------------------------------------------------------------
# Pipeline runner (Phase 2.2)
# ---------------------------------------------------------------------------


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
    do_commit: bool = True,
    do_push: bool = True,
    progress_cls: Any | None = None,
) -> tuple[bool, int, dict[str, str] | None]:
    """Drive one slice via the gate FSM. Returns (ok, elapsed, last_verify)."""
    from cursor_sdk import CursorClient

    from slice_loop_progress import read_slice_meta, slice_start_banner

    def _resolve_stream_timeout(secs: float | None) -> float | None:
        if secs is None or secs <= 0:
            return None
        return float(secs)

    _log = log or (lambda m: print(f"[slice-pipeline] {m}", flush=True))
    title, _ = read_slice_meta(slice_file, repo_root)
    print(slice_start_banner(slice_id, title, slice_file), flush=True)

    budget = FixBudget(max_attempts=max_fix_attempts)
    stream_to = _resolve_stream_timeout(stream_timeout)
    t0 = time.time()
    last_verify: dict[str, str] | None = None

    with CursorClient.launch_bridge(workspace=repo_root) as bridge_client:
        client = bridge_client.with_options(
            stream_timeout=stream_to,
            unary_timeout=unary_timeout,
        )

        # Authoring gates until implement is satisfied
        while True:
            state = assess_gate_state(slice_file, repo_root)
            _log(state.summary)
            gid = next_gate(state)
            if gid is None:
                break
            if gid in ("verify", "record", "commit"):
                break
            if gid in ("adr_review_qa", "adr_review_pm"):
                # Run all ready parallel review gates
                ready = [
                    g
                    for g in gates_ready_for_parallel(state)
                    if g in ("adr_review_qa", "adr_review_pm")
                ]
                for rg in ready or [gid]:
                    role = GATE_ROLE[rg]
                    prompt = build_gate_prompt(rg, slice_file, repo_root)
                    prog = None
                    if progress_cls:
                        prog = progress_cls(
                            slice_id, title, slice_file, _log,
                            verbose=verbose, heartbeat_secs=heartbeat_secs,
                            repo_root=repo_root,
                        )
                    ok, _ = run_worker(
                        client, role=role, prompt=prompt, api_key=api_key,
                        repo_root=repo_root, log=_log, progress=prog,
                    )
                    # Best-effort: record a cleared line if worker finished
                    if ok:
                        kind = "ADR review"
                        who = "QA" if rg == "adr_review_qa" else "PM"
                        append_plan_review_outcome(
                            slice_file, repo_root,
                            kind=kind,
                            outcome=f"{who} cleared — pipeline worker finished",
                        )
                continue

            role = GATE_ROLE.get(gid)
            if not role:
                _log(f"no worker for gate {gid} — stopping")
                break
            prompt = build_gate_prompt(gid, slice_file, repo_root)
            prog = None
            if progress_cls:
                prog = progress_cls(
                    slice_id, title, slice_file, _log,
                    verbose=verbose, heartbeat_secs=heartbeat_secs,
                    repo_root=repo_root,
                )
            ok, status = run_worker(
                client, role=role, prompt=prompt, api_key=api_key,
                repo_root=repo_root, log=_log, progress=prog,
            )
            if gid == "test_review" and ok:
                append_plan_review_outcome(
                    slice_file, repo_root,
                    kind="Test spec review",
                    outcome="Architect cleared — pipeline worker finished",
                )
            if not ok:
                _log(f"gate {gid} worker failed (status={status})")
                elapsed = int(time.time() - t0)
                return False, elapsed, last_verify

            # Re-assess; if gate still pending after worker, stop (no infinite loop)
            after = assess_gate_state(slice_file, repo_root)
            if after.gate(gid).applicable and not after.gate(gid).satisfied:
                if gid in ("adr_review_qa", "adr_review_pm", "test_review"):
                    # Reviews may need manual record — already appended above
                    pass
                else:
                    _log(f"gate {gid} still pending after worker — stopping")
                    elapsed = int(time.time() - t0)
                    return False, elapsed, last_verify

        # Verify + fix loop
        def progress_factory(role: str) -> Any:
            if not progress_cls:
                return None
            return progress_cls(
                slice_id, title, slice_file, _log,
                verbose=verbose, heartbeat_secs=heartbeat_secs,
                repo_root=repo_root,
                forced_role=role,
                fix_worker=role in ("Engineer", "QA"),
            )

        try:
            outcome = run_fix_loop(
                client,
                slice_file=slice_file,
                repo_root=repo_root,
                api_key=api_key,
                budget=budget,
                log=_log,
                progress_factory=progress_factory,
            )
        except ThrashHalt as thrash:
            _log(f"THRASH HALT: {thrash.reason}")
            raise

        last_verify = outcome.result
        if not outcome.green or not outcome.result:
            elapsed = int(time.time() - t0)
            return False, elapsed, last_verify

        # Record Done artifacts
        record_green_verify(slice_file, repo_root, outcome.result)
        _log("recorded VERIFY RESULT + Status Done")

        if do_commit:
            if not commit_slice_changes(
                slice_id, repo_root, log=_log, push=do_push
            ):
                _log("commit/push failed")
                elapsed = int(time.time() - t0)
                return False, elapsed, last_verify

    elapsed = int(time.time() - t0)
    return True, elapsed, last_verify


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
