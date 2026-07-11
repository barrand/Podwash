#!/usr/bin/env python3
"""Forge Medic — diagnose / critic / implement heal for factory scripts.

See docs/slice-pipeline.md § Medic (self-heal). Scope is scripts/** + process
docs only — never PodWash app or product tests.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Callable, Sequence

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

LANES = frozenset({"policy", "build", "infra", "test", "messaging"})
HEALABLE_LANES = frozenset({"policy", "build", "infra", "messaging"})

MAX_HEALS_PER_SIGNATURE = 1
MAX_HEALS_PER_SLICE = 2
MAX_HEALS_PER_SESSION = 3

MEDIC_DIAGNOSE_ROLE = "Medic diagnose"
MEDIC_CRITIC_ROLE = "Medic critic"
MEDIC_IMPLEMENT_ROLE = "Medic implement"

MEDIC_ROLES = (MEDIC_DIAGNOSE_ROLE, MEDIC_CRITIC_ROLE, MEDIC_IMPLEMENT_ROLE)

ALLOWED_EDIT_PREFIXES = (
    "scripts/",
    "docs/slice-",
    "docs/plans/factory-",
    "docs/forge/",
    ".cursor/skills/forge-fix/",
)

FORBIDDEN_APP_PREFIXES = (
    "PodWash/PodWash/",
    "PodWash/PodWashTests/",
    "PodWash/PodWashUITests/",
    "PodWash/PodWashSlowTests/",
)

# Diff denylist — hard reject (anti-self-lobotomy).
DENYLIST_CONSTANT_NAMES = frozenset(
    {
        "DEFAULT_MAX_MECHANIC_SPAWNS",
        "DEFAULT_FIX_LOOP_MINUTES",
        "NO_PROGRESS_HALT",
        "OSCILLATION_WINDOW",
        "FORBIDDEN_MODEL_IDS",
    }
)

FACTORY_SUITE_MODULES = (
    "scripts.test_factory_v3",
    "scripts.test_factory_p1",
    "scripts.test_fix_lanes",
    "scripts.test_factory_hardening",
    "scripts.test_hypothesis_ledger",
    "scripts.test_slice_pipeline",
    "scripts.test_slice_loop_progress",
    "scripts.test_failure_packet",
    "scripts.test_forge_medic",
    "scripts.test_forge_supervisor",
    "scripts.test_sdk_models",
)

LogFn = Callable[[str], None]


# ---------------------------------------------------------------------------
# Console
# ---------------------------------------------------------------------------


def medic_log(msg: str, log: LogFn | None = None) -> None:
    line = f"MEDIC: {msg}"
    if log:
        log(line)
    else:
        print(line, flush=True)


def medic_banner(title: str = "MEDIC") -> str:
    return f"════ {title} ════"


def chapter_open(phase: str, model_label: str) -> str:
    return f"── Medic · {phase} · {model_label} ──"


# ---------------------------------------------------------------------------
# Halt signature + ledger
# ---------------------------------------------------------------------------


def medic_ledger_path(repo_root: str) -> str:
    return os.path.join(repo_root, "build", "test-results", "medic-ledger.jsonl")


def find_halt_bundle(repo_root: str, slice_id: int | None = None) -> str | None:
    """Return newest session bundle dir (optionally for slice_id)."""
    tr = os.path.join(repo_root, "build", "test-results")
    if not os.path.isdir(tr):
        return None
    if slice_id is not None:
        cand = os.path.join(tr, f"session-slice-{slice_id:02d}")
        if os.path.isfile(os.path.join(cand, "halt.json")):
            return cand
    newest: tuple[float, str] | None = None
    for name in os.listdir(tr):
        if not name.startswith("session-slice"):
            continue
        path = os.path.join(tr, name)
        halt = os.path.join(path, "halt.json")
        if os.path.isfile(halt):
            mtime = os.path.getmtime(halt)
            if newest is None or mtime > newest[0]:
                newest = (mtime, path)
    return newest[1] if newest else None


def load_halt_json(bundle_dir: str) -> dict[str, Any]:
    path = os.path.join(bundle_dir, "halt.json")
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def compute_halt_signature(halt: dict[str, Any]) -> str:
    """Stable signature for medic dedup (one heal per signature)."""
    extra = halt.get("extra") or {}
    vr = halt.get("verify_result") or {}
    failures = halt.get("failures") or []
    # Prefer structured failure signature when present
    fail_sig = (
        extra.get("failure_signature")
        or extra.get("signature")
        or "|".join(sorted(str(f) for f in failures[:12]))
    )
    parts = [
        str(halt.get("slice") or ""),
        str(halt.get("phase") or ""),
        str(extra.get("halt_kind") or ""),
        str(vr.get("class") or ""),
        str(fail_sig),
        str(halt.get("reason") or "")[:200],
    ]
    raw = "\n".join(parts)
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:12]


def read_medic_ledger(repo_root: str) -> list[dict[str, Any]]:
    path = medic_ledger_path(repo_root)
    if not os.path.isfile(path):
        return []
    rows: list[dict[str, Any]] = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return rows


def append_medic_ledger(repo_root: str, row: dict[str, Any]) -> None:
    path = medic_ledger_path(repo_root)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    row = dict(row)
    row.setdefault("ts", datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(row, ensure_ascii=False) + "\n")


def signature_already_healed(repo_root: str, signature: str) -> bool:
    """True if a prior medic cycle recorded an attempted/successful heal for sig."""
    for row in read_medic_ledger(repo_root):
        if row.get("signature") != signature:
            continue
        outcome = str(row.get("outcome") or "")
        # Any prior heal attempt for this signature blocks another
        if outcome in (
            "healed",
            "attempted",
            "canary_failed",
            "suite_failed",
            "denylist",
            "path_guard",
            "implement_failed",
            "critic_blocked",
        ):
            return True
        if row.get("healed") is True:
            return True
    return False


def count_heals_for_slice(repo_root: str, slice_id: int) -> int:
    n = 0
    for row in read_medic_ledger(repo_root):
        if row.get("slice") == slice_id and row.get("outcome") in (
            "healed",
            "attempted",
            "canary_failed",
            "suite_failed",
            "denylist",
            "path_guard",
            "implement_failed",
            "critic_blocked",
            "lane_test",
        ):
            n += 1
    return n


# ---------------------------------------------------------------------------
# Diagnose JSON parse
# ---------------------------------------------------------------------------


@dataclass
class DiagnosePlan:
    lane: str
    halt_signature: str
    root_cause: str
    harden_plan: list[str]
    files: list[str]
    regression_test: str
    console_upgrade: str
    plain_summary: dict[str, str] = field(default_factory=dict)
    raw: dict[str, Any] = field(default_factory=dict)

    @property
    def healable(self) -> bool:
        return self.lane in HEALABLE_LANES


_JSON_FENCE_RE = re.compile(
    r"```(?:json)?\s*(\{.*?\})\s*```",
    re.DOTALL | re.IGNORECASE,
)
_MEDIC_JSON_RE = re.compile(
    r"<medic_diagnose>\s*(\{.*?\})\s*</medic_diagnose>",
    re.DOTALL | re.IGNORECASE,
)


def extract_json_object(text: str) -> dict[str, Any] | None:
    """Pull the first JSON object from assistant text (fence or tag)."""
    if not text:
        return None
    for pattern in (_MEDIC_JSON_RE, _JSON_FENCE_RE):
        m = pattern.search(text)
        if m:
            try:
                data = json.loads(m.group(1))
                if isinstance(data, dict):
                    return data
            except json.JSONDecodeError:
                pass
    # Last resort: first { … } balanced-ish scan
    start = text.find("{")
    if start < 0:
        return None
    depth = 0
    for i, ch in enumerate(text[start:], start=start):
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                try:
                    data = json.loads(text[start : i + 1])
                    if isinstance(data, dict):
                        return data
                except json.JSONDecodeError:
                    return None
    return None


def parse_diagnose_plan(text: str, *, expected_signature: str = "") -> DiagnosePlan:
    data = extract_json_object(text)
    if not data:
        raise ValueError("diagnose output missing machine-readable JSON plan")
    lane = str(data.get("lane") or "").strip().lower()
    if lane not in LANES:
        raise ValueError(f"invalid lane {lane!r}; expected one of {sorted(LANES)}")
    harden = data.get("harden_plan") or []
    if isinstance(harden, str):
        harden = [harden]
    files = data.get("files") or []
    if isinstance(files, str):
        files = [files]
    plain = data.get("plain_summary") or {}
    if not isinstance(plain, dict):
        plain = {"what_broke": str(plain)}
    plan = DiagnosePlan(
        lane=lane,
        halt_signature=str(data.get("halt_signature") or expected_signature),
        root_cause=str(data.get("root_cause") or "").strip(),
        harden_plan=[str(x).strip() for x in harden if str(x).strip()],
        files=[str(x).strip().replace("\\", "/") for x in files if str(x).strip()],
        regression_test=str(data.get("regression_test") or "").strip(),
        console_upgrade=str(data.get("console_upgrade") or "").strip(),
        plain_summary={str(k): str(v) for k, v in plain.items()},
        raw=data,
    )
    if not plan.root_cause:
        raise ValueError("diagnose plan missing root_cause")
    if plan.healable and not plan.regression_test:
        raise ValueError("healable plan must name regression_test")
    return plan


# ---------------------------------------------------------------------------
# Critic rubric (deterministic checks + optional LLM verdict parse)
# ---------------------------------------------------------------------------


@dataclass
class CriticResult:
    approved: bool
    score: int
    blockers: list[str]
    notes: str = ""


def check_files_scripts_only(files: Sequence[str]) -> list[str]:
    blockers: list[str] = []
    for f in files:
        norm = f.replace("\\", "/")
        if any(norm.startswith(p) for p in FORBIDDEN_APP_PREFIXES):
            blockers.append(f"forbidden app/test path: {norm}")
            continue
        if not any(norm.startswith(p) for p in ALLOWED_EDIT_PREFIXES):
            blockers.append(f"path outside medic scope: {norm}")
    return blockers


def deterministic_critic(plan: DiagnosePlan) -> CriticResult:
    """Encode rubric items that do not need an LLM."""
    blockers: list[str] = []
    score = 0

    # 1. Factory root cause — lane healable + root_cause not "tests failed" only
    if plan.lane == "test":
        blockers.append("lane=test — slice problem; forge must not heal")
    else:
        score += 1
    rc_l = plan.root_cause.lower()
    if plan.healable and (
        rc_l in ("tests failed", "test failed", "red verify")
        or rc_l.startswith("tests failed")
    ):
        blockers.append("root_cause blames slice tests, not factory")
    elif plan.healable:
        score += 1

    # 3-ish: plan non-empty
    if plan.healable and not plan.harden_plan:
        blockers.append("empty harden_plan")
    elif plan.healable:
        score += 1

    # 4. Real regression named
    if plan.healable:
        if not plan.regression_test or "test" not in plan.regression_test.lower():
            blockers.append("regression_test missing or not a test id")
        else:
            score += 1

    # 5. Scripts-only files
    file_blockers = check_files_scripts_only(plan.files)
    if file_blockers:
        blockers.extend(file_blockers)
    else:
        score += 1

    # Guard-weakening language in plan text
    blob = " ".join(plan.harden_plan).lower() + " " + plan.root_cause.lower()
    for bad in (
        "raise max mechanic",
        "increase spawn",
        "raise default_max_mechanic",
        "disable thrash",
        "remove thrashhalt",
        "loosen infra",
        "allow fast model",
    ):
        if bad in blob:
            blockers.append(f"plan suggests guard weakening: {bad!r}")

    approved = not blockers and plan.healable
    return CriticResult(approved=approved, score=score, blockers=blockers)


def parse_critic_verdict(text: str) -> tuple[bool | None, list[str]]:
    """Parse optional LLM critic JSON: {approved, blockers}."""
    data = extract_json_object(text or "")
    if not data:
        return None, []
    approved = data.get("approved")
    if isinstance(approved, str):
        approved = approved.strip().lower() in ("true", "yes", "approved", "pass")
    blockers = data.get("blockers") or data.get("failures") or []
    if isinstance(blockers, str):
        blockers = [blockers]
    return (
        bool(approved) if approved is not None else None,
        [str(b) for b in blockers],
    )


def merge_critic(
    deterministic: CriticResult, llm_text: str = ""
) -> CriticResult:
    """Deterministic gates always apply; LLM can only add blockers or confirm."""
    llm_approved, llm_blockers = parse_critic_verdict(llm_text)
    blockers = list(deterministic.blockers) + list(llm_blockers)
    if llm_approved is False and not llm_blockers:
        blockers.append("critic rejected plan")
    # If LLM explicitly rejects, fail even if deterministic passed
    approved = deterministic.approved and (llm_approved is not False) and not blockers
    # Recompute approved after merge
    if blockers:
        approved = False
    elif llm_approved is False:
        approved = False
    else:
        approved = deterministic.approved
    return CriticResult(
        approved=approved,
        score=deterministic.score,
        blockers=blockers,
        notes=(llm_text or "")[:500],
    )


# ---------------------------------------------------------------------------
# Diff denylist
# ---------------------------------------------------------------------------


def check_diff_denylist(diff_text: str) -> list[str]:
    """Return human-readable hits if medic diff weakens factory guards."""
    hits: list[str] = []
    if not diff_text:
        return hits
    lines = diff_text.splitlines()
    for i, line in enumerate(lines):
        # Deletion of raise ThrashHalt / InfraHalt
        if line.startswith("-") and not line.startswith("---"):
            if re.search(r"\braise\s+ThrashHalt\b", line):
                hits.append(f"denylist: remove raise ThrashHalt: {line[1:].strip()[:80]}")
            if re.search(r"\braise\s+InfraHalt\b", line):
                hits.append(f"denylist: remove raise InfraHalt: {line[1:].strip()[:80]}")
        # Constant assignment changes
        for name in DENYLIST_CONSTANT_NAMES:
            if name not in line:
                continue
            if line.startswith("+") and re.search(
                rf"\b{name}\s*=", line
            ):
                hits.append(f"denylist: modified {name}: {line[1:].strip()[:80]}")
            if line.startswith("-") and re.search(
                rf"\b{name}\s*=", line
            ):
                # paired with a + nearby — still a hit (value change)
                hits.append(f"denylist: modified {name}: {line[1:].strip()[:80]}")
    # Dedup while preserving order
    seen: set[str] = set()
    out: list[str] = []
    for h in hits:
        if h not in seen:
            seen.add(h)
            out.append(h)
    return out


def git_diff_paths(repo_root: str, paths: Sequence[str] | None = None) -> str:
    cmd = ["git", "diff", "HEAD", "--"]
    if paths:
        cmd.extend(paths)
    else:
        cmd.extend(["scripts/", "docs/", ".cursor/skills/forge-fix/"])
    proc = subprocess.run(cmd, cwd=repo_root, capture_output=True, text=True)
    return proc.stdout or ""


def git_status_paths(repo_root: str) -> list[str]:
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
        paths.append(path.replace("\\", "/"))
    return paths


def path_guard_violations(
    changed: Sequence[str], *, baseline: Sequence[str] | None = None
) -> list[str]:
    base = {p.replace("\\", "/") for p in (baseline or [])}
    hits: list[str] = []
    for p in changed:
        norm = p.replace("\\", "/")
        if norm in base:
            continue  # pre-existing dirty
        if any(norm.startswith(pref) for pref in FORBIDDEN_APP_PREFIXES):
            hits.append(norm)
    return hits


def medic_commit_paths(
    changed: Sequence[str], *, baseline: Sequence[str] | None = None
) -> list[str]:
    """Paths medic may commit (new/changed under allowed prefixes)."""
    base = {p.replace("\\", "/") for p in (baseline or [])}
    out: list[str] = []
    for p in changed:
        norm = p.replace("\\", "/")
        if "/__pycache__/" in norm or norm.endswith(".pyc"):
            continue
        if not any(norm.startswith(pref) for pref in ALLOWED_EDIT_PREFIXES):
            continue
        # Include if new relative to baseline OR was already medic-allowed dirty
        if norm not in base or any(norm.startswith(pref) for pref in ALLOWED_EDIT_PREFIXES):
            # Prefer only newly touched vs baseline for safety
            if norm not in base:
                out.append(norm)
            elif norm.startswith("scripts/") or norm.startswith("docs/forge/"):
                # Allow modifying already-dirty scripts if medic touched them —
                # fingerprint would be better; for commit we include if in allowed
                # and not in baseline OR we always include allowed paths that differ
                # from HEAD. Caller should pass only delta paths.
                out.append(norm)
    # Dedup
    seen: set[str] = set()
    uniq: list[str] = []
    for p in out:
        if p not in seen:
            seen.add(p)
            uniq.append(p)
    return uniq


def filter_medic_delta(
    changed: Sequence[str], baseline: Sequence[str]
) -> list[str]:
    """Return changed paths not in baseline, under allowed prefixes."""
    base = {p.replace("\\", "/") for p in baseline}
    out: list[str] = []
    for p in changed:
        norm = p.replace("\\", "/")
        if norm in base:
            continue
        if any(norm.startswith(pref) for pref in ALLOWED_EDIT_PREFIXES):
            out.append(norm)
    return out


# ---------------------------------------------------------------------------
# Canary + suite
# ---------------------------------------------------------------------------


def resolve_regression_unittest(regression_test: str) -> tuple[str, str | None]:
    """Return (module, optional TestClass.test_method filter).

    Accepts:
      scripts.test_factory_hardening.FooTests.test_bar
      test_factory_hardening.FooTests.test_bar
      scripts.test_factory_hardening:FooTests.test_bar
    """
    raw = (regression_test or "").strip().replace(":", ".")
    if raw.startswith("scripts."):
        parts = raw.split(".")
        # scripts.test_foo.Class.method → module scripts.test_foo
        if len(parts) >= 4:
            module = ".".join(parts[:2]) if parts[0] == "scripts" else ".".join(parts[:-2])
            # scripts.test_factory_hardening.Class.method
            module = f"{parts[0]}.{parts[1]}"
            qual = ".".join(parts[2:])
            return module, qual
        return raw, None
    if raw.startswith("test_"):
        parts = raw.split(".")
        module = f"scripts.{parts[0]}"
        qual = ".".join(parts[1:]) if len(parts) > 1 else None
        return module, qual or None
    return raw, None


def is_factory_test_path(path: str) -> bool:
    norm = path.replace("\\", "/")
    base = os.path.basename(norm)
    return norm.startswith("scripts/") and (
        base.startswith("test_") and base.endswith(".py")
    )


def run_unittest_module(
    repo_root: str,
    module: str,
    *,
    qual: str | None = None,
    log: LogFn | None = None,
) -> int:
    """Run one unittest module (optional Class.method). Returns exit code."""
    target = module if not qual else f"{module}.{qual}"
    env = os.environ.copy()
    scripts_dir = os.path.join(repo_root, "scripts")
    prev = env.get("PYTHONPATH", "")
    # repo_root for `scripts.test_*`; scripts/ for `import foo` style factory tests
    path_parts = [repo_root, scripts_dir]
    if prev:
        path_parts.append(prev)
    env["PYTHONPATH"] = os.pathsep.join(path_parts)
    cmd = [sys.executable, "-m", "unittest", target, "-q"]
    if log:
        log(f"canary/suite: {' '.join(cmd)}")
    proc = subprocess.run(cmd, cwd=repo_root, capture_output=True, text=True, env=env)
    if log and proc.returncode != 0:
        tail = (proc.stderr or proc.stdout or "")[-800:]
        for line in tail.splitlines()[-12:]:
            log(f"  {line}")
    return proc.returncode


def run_factory_suite(repo_root: str, log: LogFn | None = None) -> int:
    """Run canonical factory unit suite. Returns exit code."""
    env = os.environ.copy()
    scripts_dir = os.path.join(repo_root, "scripts")
    prev = env.get("PYTHONPATH", "")
    path_parts = [repo_root, scripts_dir]
    if prev:
        path_parts.append(prev)
    env["PYTHONPATH"] = os.pathsep.join(path_parts)
    modules: list[str] = []
    for mod in FACTORY_SUITE_MODULES:
        leaf = mod.split(".", 1)[-1] + ".py"
        if os.path.isfile(os.path.join(scripts_dir, leaf)):
            modules.append(mod)
    cmd = [sys.executable, "-m", "unittest", *modules, "-q"]
    if log:
        log(f"factory suite: {len(modules)} modules")
    proc = subprocess.run(cmd, cwd=repo_root, capture_output=True, text=True, env=env)
    if log:
        out = (proc.stdout or "") + (proc.stderr or "")
        for line in out.strip().splitlines()[-5:]:
            log(f"  {line}")
    return proc.returncode


def _read_file(path: str) -> bytes | None:
    try:
        with open(path, "rb") as fh:
            return fh.read()
    except OSError:
        return None


def _write_file(path: str, data: bytes) -> None:
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "wb") as fh:
        fh.write(data)


def _git_show(repo_root: str, rev: str, rel_path: str) -> bytes | None:
    proc = subprocess.run(
        ["git", "show", f"{rev}:{rel_path}"],
        cwd=repo_root,
        capture_output=True,
    )
    if proc.returncode != 0:
        return None
    return proc.stdout


def run_regression_canary(
    repo_root: str,
    *,
    pre_sha: str,
    regression_test: str,
    medic_paths: Sequence[str],
    log: LogFn | None = None,
) -> tuple[bool, str]:
    """Fail-before / pass-after canary.

    Keeps medic test-file(s) at post-fix content, restores other medic paths
    to pre_sha, runs the named test (must fail), restores post-fix, runs again
    (must pass).
    """
    module, qual = resolve_regression_unittest(regression_test)
    if not module:
        return False, "empty regression_test"

    abs_paths = {
        p.replace("\\", "/"): os.path.join(repo_root, p.replace("\\", "/"))
        for p in medic_paths
    }
    post_contents: dict[str, bytes | None] = {}
    for rel, abs_p in abs_paths.items():
        post_contents[rel] = _read_file(abs_p)

    test_paths = [p for p in abs_paths if is_factory_test_path(p)]
    if not test_paths:
        # Regression test must land in a scripts/test_*.py — otherwise fake
        return False, "no new/changed scripts/test_*.py in medic delta (canary)"

    try:
        # Restore non-test medic paths to pre_sha; keep test files at post
        for rel, abs_p in abs_paths.items():
            if is_factory_test_path(rel):
                continue
            old = _git_show(repo_root, pre_sha, rel)
            if old is None:
                if os.path.isfile(abs_p):
                    os.remove(abs_p)
            else:
                _write_file(abs_p, old)

        rc_before = run_unittest_module(repo_root, module, qual=qual, log=log)
        if rc_before == 0:
            return False, "canary did not fail on pre-fix tree (fake regression)"

        # Restore post-medic
        for rel, data in post_contents.items():
            abs_p = abs_paths[rel]
            if data is None:
                if os.path.isfile(abs_p):
                    os.remove(abs_p)
            else:
                _write_file(abs_p, data)

        rc_after = run_unittest_module(repo_root, module, qual=qual, log=log)
        if rc_after != 0:
            return False, "canary failed on post-fix tree (fix incomplete)"
        return True, "canary ok"
    except Exception as exc:
        # Best-effort restore
        for rel, data in post_contents.items():
            abs_p = abs_paths[rel]
            if data is not None:
                try:
                    _write_file(abs_p, data)
                except OSError:
                    pass
        return False, f"canary error: {exc}"


def revert_paths(repo_root: str, paths: Sequence[str], *, pre_sha: str) -> None:
    """Restore paths to pre_sha (delete if did not exist)."""
    for rel in paths:
        norm = rel.replace("\\", "/")
        abs_p = os.path.join(repo_root, norm)
        old = _git_show(repo_root, pre_sha, norm)
        if old is None:
            if os.path.isfile(abs_p):
                os.remove(abs_p)
            elif os.path.isdir(abs_p):
                continue
        else:
            _write_file(abs_p, old)


# ---------------------------------------------------------------------------
# Reports
# ---------------------------------------------------------------------------


def medic_reports_dir(repo_root: str) -> str:
    return os.path.join(repo_root, "docs", "forge", "medic-reports")


def write_medic_report(
    repo_root: str,
    *,
    slice_id: int | None,
    signature: str,
    plan: DiagnosePlan | None,
    outcome: str,
    detail: str = "",
    critic: CriticResult | None = None,
) -> str:
    os.makedirs(medic_reports_dir(repo_root), exist_ok=True)
    day = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    lane = plan.lane if plan else "unknown"
    sid = f"{slice_id:02d}" if slice_id is not None else "xx"
    name = f"{day}-slice-{sid}-{lane}-{signature}.md"
    path = os.path.join(medic_reports_dir(repo_root), name)
    plain = (plan.plain_summary if plan else {}) or {}
    lines = [
        f"# Medic report — slice {sid}",
        "",
        f"- **When:** {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}",
        f"- **Signature:** `{signature}`",
        f"- **Lane:** {lane}",
        f"- **Outcome:** {outcome}",
        "",
    ]
    if detail:
        lines.extend(["## Detail", "", detail, ""])
    if plan:
        lines.extend(
            [
                "## Root cause",
                "",
                plan.root_cause,
                "",
                "## Harden plan",
                "",
            ]
        )
        for i, item in enumerate(plan.harden_plan, 1):
            lines.append(f"{i}. {item}")
        lines.extend(
            [
                "",
                f"**Regression:** `{plan.regression_test}`",
                f"**Console upgrade:** {plan.console_upgrade or '(none)'}",
                "",
                "## In simple terms",
                "",
            ]
        )
        for key in ("what_broke", "slice_plan", "forge_plan"):
            if key in plain:
                lines.extend([f"### {key}", "", plain[key], ""])
        for k, v in plain.items():
            if k not in ("what_broke", "slice_plan", "forge_plan"):
                lines.extend([f"### {k}", "", v, ""])
    if critic and critic.blockers:
        lines.extend(["## Critic blockers", ""])
        for b in critic.blockers:
            lines.append(f"- {b}")
        lines.append("")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines).rstrip() + "\n")
    return path


# ---------------------------------------------------------------------------
# Prompts
# ---------------------------------------------------------------------------


def _load_forge_fix_skill(repo_root: str) -> str:
    path = os.path.join(
        repo_root, ".cursor", "skills", "forge-fix", "SKILL.md"
    )
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except OSError:
        return "(forge-fix skill missing)"


def _bundle_excerpt(bundle_dir: str, max_chars: int = 12000) -> str:
    parts: list[str] = []
    for name in (
        "halt.json",
        "stuck-card.txt",
        "verify-output.txt",
        "verify-result.json",
        "README.md",
    ):
        path = os.path.join(bundle_dir, name)
        if not os.path.isfile(path):
            continue
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                body = fh.read()
        except OSError:
            continue
        parts.append(f"### {name}\n```\n{body[:4000]}\n```")
    text = "\n\n".join(parts)
    return text[:max_chars]


def build_diagnose_prompt(
    *,
    repo_root: str,
    bundle_dir: str,
    signature: str,
    exit_code: int,
) -> str:
    skill = _load_forge_fix_skill(repo_root)
    excerpt = _bundle_excerpt(bundle_dir)
    return f"""You are the Forge **Medic diagnose** agent (plan mode — read-only).

Follow the forge-fix workflow below. Diagnose the **factory** halt — do not
fix PodWash app or product tests.

Halt signature (echo this in JSON): `{signature}`
Loop exit code: {exit_code}
Bundle: {bundle_dir}

## forge-fix skill

{skill}

## Halt bundle excerpt

{excerpt}

## Required output

1. A short human post-mortem (markdown).
2. Then a machine-readable JSON block in a ```json fence with ALL fields:

```json
{{
  "lane": "policy|build|infra|test|messaging",
  "halt_signature": "{signature}",
  "root_cause": "one sentence about the factory defect (not 'tests failed')",
  "harden_plan": ["concrete behavior change 1", "change 2"],
  "files": ["scripts/….py"],
  "regression_test": "scripts.test_….ClassName.test_method",
  "console_upgrade": "exact log line that should have printed",
  "plain_summary": {{
    "what_broke": "…",
    "slice_plan": "…",
    "forge_plan": "…"
  }}
}}
```

Rules:
- Prefer lane=test when XCTest failures are real and the forge routed correctly.
- Prefer messaging/routing fixes over raising budgets.
- regression_test MUST be a **new** unittest that fails before the harden and passes after.
- Never propose editing PodWash/PodWash/** or product test targets.
"""


def build_critic_prompt(*, plan: DiagnosePlan, signature: str) -> str:
    plan_json = json.dumps(plan.raw or {
        "lane": plan.lane,
        "halt_signature": plan.halt_signature or signature,
        "root_cause": plan.root_cause,
        "harden_plan": plan.harden_plan,
        "files": plan.files,
        "regression_test": plan.regression_test,
        "console_upgrade": plan.console_upgrade,
    }, indent=2)
    return f"""You are the Forge **Medic critic** (plan mode — read-only).

Evaluate this diagnose plan against the fixed rubric. One shot — do not redesign.

## Plan

```json
{plan_json}
```

## Rubric (ALL must pass)

1. **Factory root cause** — hardens the forge, not the slice product code/tests.
2. **No guard weakening** — no raising spawn/minute caps, no deleting ThrashHalt/
   InfraHalt, no touching FORBIDDEN_MODEL_IDS to allow fast models.
3. **Simpler alternative** — reject large rewrites if messaging-only would suffice.
4. **Real regression** — named test would fail before and pass after; not a tautology.
5. **Scripts-only** — every files[] entry under scripts/ or process docs.

## Required output

A short rationale, then JSON:

```json
{{
  "approved": true,
  "blockers": [],
  "rubric": {{"factory_root": true, "no_weaken": true, "simpler_ok": true, "real_regression": true, "scripts_only": true}}
}}
```

If any rubric item fails, set approved=false and list blockers.
"""


def build_implement_prompt(*, plan: DiagnosePlan, signature: str) -> str:
    plan_json = json.dumps({
        "lane": plan.lane,
        "halt_signature": signature,
        "root_cause": plan.root_cause,
        "harden_plan": plan.harden_plan,
        "files": plan.files,
        "regression_test": plan.regression_test,
        "console_upgrade": plan.console_upgrade,
    }, indent=2)
    return f"""You are the Forge **Medic implement** agent (agent mode).

Land the approved factory hardening. Smallest change that prevents recurrence
AND improves console clarity.

## Approved plan

```json
{plan_json}
```

## Hard bans

- Edit ONLY under: scripts/**, docs/slice-*.md, docs/plans/factory-*.md,
  docs/forge/**, .cursor/skills/forge-fix/**
- NEVER edit PodWash/PodWash/** or PodWash/*Tests/**
- Do NOT run scripts/verify.sh or xcodebuild
- Do NOT raise DEFAULT_MAX_MECHANIC_SPAWNS / DEFAULT_FIX_LOOP_MINUTES /
  NO_PROGRESS_HALT or weaken ThrashHalt / InfraHalt / FORBIDDEN_MODEL_IDS
- You MAY run: `python3 -m unittest scripts.test_… -q`

## Required

1. Implement the harden_plan.
2. Add the named **new** regression test (`{plan.regression_test}`) that fails
   on the pre-fix behavior and passes after your change.
3. Keep the diff small.

When done, briefly list files touched.
"""


# ---------------------------------------------------------------------------
# Heal orchestration
# ---------------------------------------------------------------------------


@dataclass
class MedicResult:
    ok: bool
    outcome: str
    signature: str
    slice_id: int | None = None
    report_path: str = ""
    detail: str = ""
    plan: DiagnosePlan | None = None


def register_medic_roles() -> None:
    """Ensure slice_pipeline ROLE maps include Medic roles (idempotent)."""
    from slice_pipeline import PLAN_MODE_ROLES, ROLE_MODELS

    ROLE_MODELS[MEDIC_DIAGNOSE_ROLE] = "grok-4.5"
    ROLE_MODELS[MEDIC_CRITIC_ROLE] = "composer-2.5"
    ROLE_MODELS[MEDIC_IMPLEMENT_ROLE] = "grok-4.5"
    # PLAN_MODE_ROLES is a frozenset — replace via module attr
    import slice_pipeline as sp

    sp.PLAN_MODE_ROLES = frozenset(set(PLAN_MODE_ROLES) | {MEDIC_DIAGNOSE_ROLE, MEDIC_CRITIC_ROLE})


WorkerFn = Callable[[str, str], tuple[bool, str, str]]
# (role, prompt) -> (ok, status, assistant_text)


def default_worker_factory(
    *,
    api_key: str,
    repo_root: str,
    log: LogFn,
    verbose: bool = False,
) -> WorkerFn:
    """Build a WorkerFn that spawns real SDK agents via run_worker."""
    register_medic_roles()
    from cursor_bridge import launch_bridge
    from slice_pipeline import run_worker
    from slice_loop_progress import RunProgress

    def _worker(role: str, prompt: str) -> tuple[bool, str, str]:
        with launch_bridge(workspace=repo_root) as client:
            progress = RunProgress(
                slice_id=0,
                slice_title="Medic",
                slice_file="",
                log_fn=log,
                verbose=verbose,
                repo_root=repo_root,
                forced_role=role,
                agent_name="Medic",
                fix_worker=True,  # verify-ban
                heartbeat_secs=90,
            )
            ok, status = run_worker(
                client,
                role=role,
                prompt=prompt,
                api_key=api_key,
                repo_root=repo_root,
                log=log,
                progress=progress,
            )
            text = getattr(progress, "assistant_text", "") or ""
            return ok, status, text

    return _worker


def run_medic_heal(
    *,
    repo_root: str,
    exit_code: int,
    slice_id: int | None = None,
    worker: WorkerFn | None = None,
    api_key: str | None = None,
    log: LogFn | None = None,
    do_commit: bool = True,
    do_push: bool = True,
    skip_workers: bool = False,
    session_heal_count: int = 0,
) -> MedicResult:
    """Run one medic heal cycle. Returns MedicResult (ok means resume loop)."""
    _log = log or (lambda m: print(m, flush=True))

    def mlog(msg: str) -> None:
        medic_log(msg, _log)

    print(medic_banner("MEDIC"), flush=True)

    bundle = find_halt_bundle(repo_root, slice_id)
    if not bundle:
        mlog("halt — no session bundle / halt.json found")
        return MedicResult(ok=False, outcome="no_bundle", signature="")

    halt = load_halt_json(bundle)
    if slice_id is None:
        slice_id = halt.get("slice")
        if isinstance(slice_id, str) and slice_id.isdigit():
            slice_id = int(slice_id)

    signature = compute_halt_signature(halt)
    mlog(
        f"{'thrash' if exit_code == 5 else 'infra'} halt · "
        f"slice {slice_id if slice_id is not None else '?'} · "
        f"exit={exit_code} · sig={signature} · phase={halt.get('phase')}"
    )
    mlog(f"bundle {bundle}")

    if session_heal_count >= MAX_HEALS_PER_SESSION:
        mlog(f"halt — session medic cap {MAX_HEALS_PER_SESSION} reached")
        return MedicResult(
            ok=False, outcome="session_cap", signature=signature, slice_id=slice_id
        )

    if slice_id is not None and count_heals_for_slice(repo_root, int(slice_id)) >= MAX_HEALS_PER_SLICE:
        mlog(f"halt — slice medic cap {MAX_HEALS_PER_SLICE} reached")
        return MedicResult(
            ok=False, outcome="slice_cap", signature=signature, slice_id=slice_id
        )

    if signature_already_healed(repo_root, signature):
        mlog(f"halt — signature {signature} already healed once; fix did not stick")
        report = write_medic_report(
            repo_root,
            slice_id=slice_id if isinstance(slice_id, int) else None,
            signature=signature,
            plan=None,
            outcome="signature_repeat",
            detail="Signature already had a medic attempt; refusing to thrash.",
        )
        append_medic_ledger(
            repo_root,
            {
                "signature": signature,
                "slice": slice_id,
                "outcome": "signature_repeat",
                "report": report,
            },
        )
        mlog(f"report {report}")
        return MedicResult(
            ok=False,
            outcome="signature_repeat",
            signature=signature,
            slice_id=slice_id if isinstance(slice_id, int) else None,
            report_path=report,
        )

    # Snapshot
    pre_sha_proc = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=repo_root,
        capture_output=True,
        text=True,
    )
    pre_sha = (pre_sha_proc.stdout or "").strip() or "HEAD"
    baseline = git_status_paths(repo_root)

    if worker is None and not skip_workers:
        key = api_key or os.environ.get("CURSOR_API_KEY") or ""
        if not key:
            mlog("halt — CURSOR_API_KEY missing for medic workers")
            return MedicResult(
                ok=False, outcome="no_api_key", signature=signature, slice_id=slice_id
            )
        worker = default_worker_factory(api_key=key, repo_root=repo_root, log=_log)

    # --- Diagnose ---
    print(chapter_open("diagnose", "Grok 4.5 High"), flush=True)
    diagnose_text = ""
    if skip_workers or worker is None:
        mlog("halt — no worker available for diagnose")
        return MedicResult(ok=False, outcome="no_worker", signature=signature, slice_id=slice_id)

    ok, status, diagnose_text = worker(
        MEDIC_DIAGNOSE_ROLE,
        build_diagnose_prompt(
            repo_root=repo_root,
            bundle_dir=bundle,
            signature=signature,
            exit_code=exit_code,
        ),
    )
    if not ok:
        mlog(f"halt — diagnose worker status={status}")
        append_medic_ledger(
            repo_root,
            {"signature": signature, "slice": slice_id, "outcome": "diagnose_failed"},
        )
        return MedicResult(
            ok=False, outcome="diagnose_failed", signature=signature, slice_id=slice_id
        )

    try:
        plan = parse_diagnose_plan(diagnose_text, expected_signature=signature)
    except ValueError as exc:
        mlog(f"halt — diagnose parse: {exc}")
        report = write_medic_report(
            repo_root,
            slice_id=slice_id if isinstance(slice_id, int) else None,
            signature=signature,
            plan=None,
            outcome="diagnose_parse",
            detail=str(exc) + "\n\n" + (diagnose_text or "")[:2000],
        )
        append_medic_ledger(
            repo_root,
            {
                "signature": signature,
                "slice": slice_id,
                "outcome": "diagnose_parse",
                "report": report,
            },
        )
        return MedicResult(
            ok=False,
            outcome="diagnose_parse",
            signature=signature,
            slice_id=slice_id,
            report_path=report,
            detail=str(exc),
        )

    mlog(f"lane={plan.lane} · {plan.root_cause[:120]}")
    if plan.harden_plan:
        mlog(f"plan — {plan.harden_plan[0][:100]}; regression {plan.regression_test}")

    # Lane gate
    if plan.lane == "test" or not plan.healable:
        report = write_medic_report(
            repo_root,
            slice_id=slice_id if isinstance(slice_id, int) else None,
            signature=signature,
            plan=plan,
            outcome="lane_test",
            detail="Slice problem (or non-healable lane); forge behaved — no medic implement.",
        )
        append_medic_ledger(
            repo_root,
            {
                "signature": signature,
                "slice": slice_id,
                "outcome": "lane_test",
                "lane": plan.lane,
                "report": report,
            },
        )
        mlog(f"skip — lane={plan.lane} (slice problem; forge behaved). Report: {report}")
        return MedicResult(
            ok=False,
            outcome="lane_test",
            signature=signature,
            slice_id=slice_id,
            report_path=report,
            plan=plan,
        )

    # --- Critic ---
    print(chapter_open("critic", "Composer 2.5"), flush=True)
    det = deterministic_critic(plan)
    ok_c, status_c, critic_text = worker(
        MEDIC_CRITIC_ROLE,
        build_critic_prompt(plan=plan, signature=signature),
    )
    if not ok_c:
        mlog(f"halt — critic worker status={status_c}")
        critic = CriticResult(approved=False, score=det.score, blockers=det.blockers + [f"worker {status_c}"])
    else:
        critic = merge_critic(det, critic_text)

    if not critic.approved:
        reason = "; ".join(critic.blockers) or "rubric failed"
        report = write_medic_report(
            repo_root,
            slice_id=slice_id if isinstance(slice_id, int) else None,
            signature=signature,
            plan=plan,
            outcome="critic_blocked",
            detail=reason,
            critic=critic,
        )
        append_medic_ledger(
            repo_root,
            {
                "signature": signature,
                "slice": slice_id,
                "outcome": "critic_blocked",
                "report": report,
                "blockers": critic.blockers,
            },
        )
        mlog(f"halt — critic blocked: {reason}")
        mlog(f"report {report}")
        return MedicResult(
            ok=False,
            outcome="critic_blocked",
            signature=signature,
            slice_id=slice_id,
            report_path=report,
            plan=plan,
            detail=reason,
        )

    mlog(f"critic approved · rubric {critic.score}/5 · denylist pending · canary named")

    # --- Implement ---
    print(chapter_open("implement", "Grok 4.5 High"), flush=True)
    ok_i, status_i, _impl_text = worker(
        MEDIC_IMPLEMENT_ROLE,
        build_implement_prompt(plan=plan, signature=signature),
    )
    if not ok_i:
        mlog(f"halt — implement worker status={status_i}")
        append_medic_ledger(
            repo_root,
            {"signature": signature, "slice": slice_id, "outcome": "implement_failed"},
        )
        return MedicResult(
            ok=False, outcome="implement_failed", signature=signature, slice_id=slice_id
        )

    changed = git_status_paths(repo_root)
    delta = filter_medic_delta(changed, baseline)
    mlog(f"delta {len(delta)} files under scripts/docs (+tests)")

    # Path guard
    violations = path_guard_violations(changed, baseline=baseline)
    if violations:
        revert_paths(repo_root, delta, pre_sha=pre_sha)
        report = write_medic_report(
            repo_root,
            slice_id=slice_id if isinstance(slice_id, int) else None,
            signature=signature,
            plan=plan,
            outcome="path_guard",
            detail="PodWash paths touched: " + ", ".join(violations),
        )
        append_medic_ledger(
            repo_root,
            {
                "signature": signature,
                "slice": slice_id,
                "outcome": "path_guard",
                "report": report,
            },
        )
        mlog(f"halt — path guard: {violations[0]}")
        return MedicResult(
            ok=False,
            outcome="path_guard",
            signature=signature,
            slice_id=slice_id,
            report_path=report,
            plan=plan,
        )

    if not delta:
        mlog("halt — implement produced no scripts/docs delta")
        append_medic_ledger(
            repo_root,
            {"signature": signature, "slice": slice_id, "outcome": "empty_delta"},
        )
        return MedicResult(
            ok=False, outcome="empty_delta", signature=signature, slice_id=slice_id, plan=plan
        )

    # Denylist on diff
    diff_text = git_diff_paths(repo_root, delta)
    deny_hits = check_diff_denylist(diff_text)
    if deny_hits:
        revert_paths(repo_root, delta, pre_sha=pre_sha)
        report = write_medic_report(
            repo_root,
            slice_id=slice_id if isinstance(slice_id, int) else None,
            signature=signature,
            plan=plan,
            outcome="denylist",
            detail="\n".join(deny_hits),
        )
        append_medic_ledger(
            repo_root,
            {
                "signature": signature,
                "slice": slice_id,
                "outcome": "denylist",
                "report": report,
                "hits": deny_hits,
            },
        )
        mlog(f"halt — denylist hit: {deny_hits[0]}")
        return MedicResult(
            ok=False,
            outcome="denylist",
            signature=signature,
            slice_id=slice_id,
            report_path=report,
            plan=plan,
        )

    # Canary
    canary_ok, canary_msg = run_regression_canary(
        repo_root,
        pre_sha=pre_sha,
        regression_test=plan.regression_test,
        medic_paths=delta,
        log=mlog,
    )
    if not canary_ok:
        revert_paths(repo_root, delta, pre_sha=pre_sha)
        report = write_medic_report(
            repo_root,
            slice_id=slice_id if isinstance(slice_id, int) else None,
            signature=signature,
            plan=plan,
            outcome="canary_failed",
            detail=canary_msg,
        )
        append_medic_ledger(
            repo_root,
            {
                "signature": signature,
                "slice": slice_id,
                "outcome": "canary_failed",
                "report": report,
            },
        )
        mlog(f"halt — {canary_msg}")
        return MedicResult(
            ok=False,
            outcome="canary_failed",
            signature=signature,
            slice_id=slice_id,
            report_path=report,
            plan=plan,
            detail=canary_msg,
        )
    mlog("canary — new test fails on pre-fix tree ✓")

    # Full suite
    suite_rc = run_factory_suite(repo_root, log=mlog)
    if suite_rc != 0:
        revert_paths(repo_root, delta, pre_sha=pre_sha)
        report = write_medic_report(
            repo_root,
            slice_id=slice_id if isinstance(slice_id, int) else None,
            signature=signature,
            plan=plan,
            outcome="suite_failed",
            detail="factory suite red; medic delta reverted",
        )
        append_medic_ledger(
            repo_root,
            {
                "signature": signature,
                "slice": slice_id,
                "outcome": "suite_failed",
                "report": report,
            },
        )
        mlog("halt — factory suite red; medic delta reverted")
        return MedicResult(
            ok=False,
            outcome="suite_failed",
            signature=signature,
            slice_id=slice_id,
            report_path=report,
            plan=plan,
        )
    mlog("factory suite green ✓")

    # Report + commit
    report = write_medic_report(
        repo_root,
        slice_id=slice_id if isinstance(slice_id, int) else None,
        signature=signature,
        plan=plan,
        outcome="healed",
        detail="Medic heal landed; loop may resume.",
    )
    # Include report in commit set
    commit_paths = list(delta)
    rel_report = os.path.relpath(report, repo_root).replace("\\", "/")
    if rel_report not in commit_paths:
        commit_paths.append(rel_report)

    if do_commit:
        lane_slug = re.sub(r"[^a-z0-9]+", "-", plan.lane)[:40]
        msg = f"forge: harden {lane_slug}-{signature}"
        subprocess.run(
            ["git", "add", "--", *commit_paths],
            cwd=repo_root,
            check=False,
        )
        commit = subprocess.run(
            ["git", "commit", "-m", msg],
            cwd=repo_root,
            capture_output=True,
            text=True,
        )
        if commit.returncode != 0:
            mlog(f"commit failed: {(commit.stderr or commit.stdout or '')[:200]}")
        else:
            mlog(f"committed {msg}")
            if do_push:
                push = subprocess.run(
                    ["git", "push"],
                    cwd=repo_root,
                    capture_output=True,
                    text=True,
                )
                if push.returncode != 0:
                    mlog(f"push failed (heal kept locally): {(push.stderr or '')[:200]}")
                else:
                    mlog("pushed")

    append_medic_ledger(
        repo_root,
        {
            "signature": signature,
            "slice": slice_id,
            "outcome": "healed",
            "lane": plan.lane,
            "files": commit_paths,
            "report": report,
            "healed": True,
        },
    )
    mlog(f"healed · report {report}")
    print(medic_banner("FORGE RESUME"), flush=True)
    return MedicResult(
        ok=True,
        outcome="healed",
        signature=signature,
        slice_id=slice_id if isinstance(slice_id, int) else None,
        report_path=report,
        plan=plan,
    )
