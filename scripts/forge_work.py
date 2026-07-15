#!/usr/bin/env python3
"""Shared Forge work helpers — next-work, Implemented lifecycle, batch promote, bisect, CI."""

from __future__ import annotations

import json
import os
import re
import subprocess
import time
from pathlib import Path
from typing import Any

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def query_next_work(*, repo_root: str | None = None) -> dict[str, Any]:
    """Return next-work.sh --json decision (includes kind=task|slice|none)."""
    root = repo_root or REPO_ROOT
    proc = subprocess.run(
        [os.path.join(root, "scripts", "next-work.sh"), "--json"],
        cwd=root,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"next-work.sh failed: {proc.stderr.strip()}")
    return json.loads(proc.stdout.strip() or "{}")


def verify_is_ship_green(v: dict[str, Any] | None) -> bool:
    """Ship-gate green: exit/failed/skipped=0 AND tier=3 AND filtered=0."""
    if not v:
        return False
    if str(v.get("exit")) != "0":
        return False
    if str(v.get("failed")) != "0":
        return False
    if str(v.get("skipped")) != "0":
        return False
    tier = str(v.get("tier") or "").strip()
    filtered = str(v.get("filtered") or "").strip()
    if tier and tier != "3":
        return False
    if filtered and filtered != "0":
        return False
    # Missing tier/filtered on legacy lines: treat as not ship-green.
    if not tier or not filtered:
        return False
    return True


def _status_from_meta_text(text: str) -> str:
    for line in text.splitlines():
        if "| **Status** |" in line or "| **Status**|" in line:
            parts = [p.strip() for p in line.strip().strip("|").split("|")]
            if len(parts) >= 2:
                return parts[1]
    return ""


def _parse_verify_line(text: str) -> dict[str, str] | None:
    from slice_loop_progress import parse_verify_result

    return parse_verify_result(text)


def list_implemented_items(*, repo_root: str | None = None) -> list[dict[str, Any]]:
    """Return Implemented (tier-2 green) tasks and slices awaiting ship-gate Done."""
    root = repo_root or REPO_ROOT
    out: list[dict[str, Any]] = []
    tasks_dir = Path(root) / "docs" / "tasks"
    if tasks_dir.is_dir():
        for path in sorted(tasks_dir.glob("task-*.md")):
            if path.name.startswith("_"):
                continue
            text = path.read_text(encoding="utf-8")
            status = _status_from_meta_text(text)
            if not re.search(r"^Implemented", status, re.I):
                continue
            out.append(
                {
                    "kind": "task",
                    "path": str(path),
                    "rel": str(path.relative_to(root)),
                    "status": status,
                    "verify": _parse_verify_line(text),
                }
            )
    slices_dir = Path(root) / "docs" / "slices"
    if slices_dir.is_dir():
        for path in sorted(slices_dir.glob("slice-[0-9][0-9]-*.md")):
            if path.name.endswith("-ux.md"):
                continue
            text = path.read_text(encoding="utf-8")
            status = _status_from_meta_text(text)
            if not re.search(r"^Implemented", status, re.I):
                continue
            out.append(
                {
                    "kind": "slice",
                    "path": str(path),
                    "rel": str(path.relative_to(root)),
                    "status": status,
                    "verify": _parse_verify_line(text),
                }
            )
    return out


def count_items_since_batch_gate(
    *,
    repo_root: str | None = None,
    stamp_path: str | None = None,
) -> dict[str, Any]:
    """Count Implemented items + commits since last green batch stamp."""
    root = repo_root or REPO_ROOT
    implemented = list_implemented_items(repo_root=root)
    stamp: dict[str, Any] = {}
    path = stamp_path or os.path.join(root, "build", "factory", "batch-gate.json")
    if os.path.isfile(path):
        try:
            with open(path, encoding="utf-8") as fh:
                raw = json.load(fh)
            if isinstance(raw, dict):
                stamp = raw
        except (OSError, json.JSONDecodeError):
            stamp = {}
    last_sha = str(stamp.get("sha") or "").strip()
    commits_since = 0
    if last_sha:
        proc = subprocess.run(
            ["git", "rev-list", "--count", f"{last_sha}..HEAD"],
            cwd=root,
            capture_output=True,
            text=True,
        )
        if proc.returncode == 0:
            try:
                commits_since = int((proc.stdout or "0").strip() or "0")
            except ValueError:
                commits_since = 0
    return {
        "implemented_count": len(implemented),
        "implemented": implemented,
        "last_green_sha": last_sha or None,
        "commits_since": commits_since,
        "items_since_green": len(implemented),
    }


def promote_implemented_to_done(
    *,
    ship_verify: dict[str, str],
    repo_root: str | None = None,
    log: Any = None,
) -> list[str]:
    """Flip all Implemented items → Done with the full-suite VERIFY RESULT line.

    Requires ship_verify to be ship-gate green (tier=3 filtered=0).
    Returns list of relative paths updated.
    """
    _log = log or (lambda m: None)
    if not verify_is_ship_green(ship_verify):
        raise ValueError("ship verify is not tier=3 filtered=0 green")
    root = repo_root or REPO_ROOT
    from slice_pipeline import write_verify_result
    from task_ticket import set_task_status

    updated: list[str] = []
    for item in list_implemented_items(repo_root=root):
        path = item["path"]
        kind = item["kind"]
        if kind == "task":
            write_verify_result(path, root, ship_verify)
            set_task_status(path, "Done")
        else:
            write_verify_result(path, root, ship_verify)
            from slice_pipeline import set_slice_status

            set_slice_status(path, root, "Done")
        updated.append(item["rel"])
        _log(f"promoted {item['rel']} Implemented → Done")
    return updated


def append_slice_decision(
    slice_file: str,
    answer: str,
    *,
    repo_root: str | None = None,
) -> None:
    """Append a Floor halt-and-ask answer under ## Decision record (or create it)."""
    root = repo_root or REPO_ROOT
    path = slice_file if os.path.isabs(slice_file) else os.path.join(root, slice_file)
    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    block = f"\n- **Floor answer ({stamp}):** {answer.strip()}\n"
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    if re.search(r"^##\s+Decision record", text, re.MULTILINE | re.IGNORECASE):
        text = re.sub(
            r"(##\s+Decision record[^\n]*\n)",
            r"\1" + block,
            text,
            count=1,
            flags=re.IGNORECASE,
        )
    else:
        text = text.rstrip() + f"\n\n## Decision record\n{block}"
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


def find_open_halt_cards(*, repo_root: str | None = None) -> list[dict[str, Any]]:
    """Scan build/test-results/session-*/halt.json for actionable Your-move cards."""
    root = repo_root or REPO_ROOT
    tr = Path(root) / "build" / "test-results"
    if not tr.is_dir():
        return []
    cards: list[dict[str, Any]] = []
    for halt_path in sorted(tr.glob("session-*/halt.json"), key=lambda p: p.stat().st_mtime):
        try:
            data = json.loads(halt_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if not isinstance(data, dict):
            continue
        reason = str(data.get("reason") or data.get("halt_kind") or "")
        cards.append(
            {
                "path": str(halt_path.relative_to(root)),
                "session": halt_path.parent.name,
                "reason": reason,
                "slice": data.get("slice"),
                "question": data.get("question") or data.get("message") or reason,
                "halt": data,
            }
        )
    return cards[-10:]


def lightweight_bisect(
    *,
    repo_root: str | None = None,
    last_green_sha: str,
    log: Any = None,
) -> dict[str, Any]:
    """Commit-range bisect using tier-3a (unit-only) verifies at midpoints.

    Does not checkout permanently — uses ``git bisect`` in a subprocess if available,
    otherwise binary-searches ``git rev-list`` with temporary checkouts restored after.
    Returns {bad_sha, message, steps}.
    """
    _log = log or (lambda m: None)
    root = repo_root or REPO_ROOT
    head_proc = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=root, capture_output=True, text=True
    )
    head = (head_proc.stdout or "").strip()
    if not last_green_sha or not head:
        return {"bad_sha": None, "message": "missing SHAs for bisect", "steps": []}

    list_proc = subprocess.run(
        ["git", "rev-list", "--reverse", f"{last_green_sha}..{head}"],
        cwd=root,
        capture_output=True,
        text=True,
    )
    shas = [ln.strip() for ln in (list_proc.stdout or "").splitlines() if ln.strip()]
    if not shas:
        return {"bad_sha": head, "message": "no commits in range; HEAD is suspect", "steps": []}

    from slice_pipeline import run_verify

    steps: list[dict[str, Any]] = []
    lo, hi = 0, len(shas) - 1
    bad = shas[-1]
    original = head

    def _checkout(sha: str) -> bool:
        proc = subprocess.run(
            ["git", "checkout", "-q", sha],
            cwd=root,
            capture_output=True,
            text=True,
        )
        return proc.returncode == 0

    try:
        # Cap steps to keep batch reds bounded.
        for _ in range(min(8, len(shas).bit_length() + 2)):
            if lo > hi:
                break
            mid = (lo + hi) // 2
            sha = shas[mid]
            _log(f"bisect checkout {sha[:12]} ({mid + 1}/{len(shas)})")
            if not _checkout(sha):
                steps.append({"sha": sha, "ok": False, "error": "checkout failed"})
                break
            outcome = run_verify(root, log=_log, tier="3a")
            green = bool(outcome and outcome.green)
            steps.append({"sha": sha, "green": green})
            if green:
                lo = mid + 1
            else:
                bad = sha
                hi = mid - 1
    finally:
        subprocess.run(
            ["git", "checkout", "-q", original],
            cwd=root,
            capture_output=True,
            text=True,
        )

    return {
        "bad_sha": bad,
        "message": f"first bad commit (tier-3a): {bad[:12] if bad else '?'}",
        "steps": steps,
        "range": f"{last_green_sha[:12]}..{head[:12]}",
    }


def fetch_ci_status(*, repo_root: str | None = None, limit: int = 12) -> list[dict[str, Any]]:
    """Best-effort CI run badges via ``gh run list`` (empty if gh unavailable)."""
    root = repo_root or REPO_ROOT
    try:
        proc = subprocess.run(
            [
                "gh",
                "run",
                "list",
                "--limit",
                str(limit),
                "--json",
                "databaseId,headSha,status,conclusion,displayTitle,url,createdAt,event",
            ],
            cwd=root,
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired):
        return []
    if proc.returncode != 0 or not (proc.stdout or "").strip():
        return []
    try:
        rows = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return []
    out: list[dict[str, Any]] = []
    for row in rows if isinstance(rows, list) else []:
        if not isinstance(row, dict):
            continue
        out.append(
            {
                "id": row.get("databaseId"),
                "sha": (row.get("headSha") or "")[:12],
                "head_sha": row.get("headSha"),
                "status": row.get("status"),
                "conclusion": row.get("conclusion"),
                "title": row.get("displayTitle"),
                "url": row.get("url"),
                "created_at": row.get("createdAt"),
                "event": row.get("event"),
                "badge": _ci_badge(row.get("status"), row.get("conclusion")),
            }
        )
    return out


def _ci_badge(status: Any, conclusion: Any) -> str:
    st = str(status or "").lower()
    conc = str(conclusion or "").lower()
    if st in ("queued", "pending", "in_progress", "waiting"):
        return "pending"
    if conc == "success":
        return "pass"
    if conc in ("failure", "timed_out", "cancelled"):
        return "fail"
    return "unknown"


def task_gate_chips() -> list[dict[str, Any]]:
    """Short gate strip for punch-list tasks."""
    return [
        {"id": "qa", "label": "QA tests"},
        {"id": "engineer", "label": "Engineer"},
        {"id": "tier2", "label": "tier-2"},
    ]


def slice_gate_chips(slice_file: str, *, repo_root: str | None = None) -> list[dict[str, Any]]:
    """Full gate chip strip from assess_gate_state."""
    root = repo_root or REPO_ROOT
    try:
        from slice_pipeline import assess_gate_state

        state = assess_gate_state(slice_file, root)
    except Exception:
        return []
    chips: list[dict[str, Any]] = []
    for g in state.gates:
        if not g.applicable:
            continue
        chips.append(
            {
                "id": g.id,
                "label": g.label,
                "done": g.satisfied,
                "status": g.status,
            }
        )
    return chips
