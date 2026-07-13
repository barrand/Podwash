#!/usr/bin/env python3
"""Forge Floor — localhost mission control (port 7420).

Lens + soft controls. Starts/attaches task-loop via controls.json.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlparse

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = REPO_ROOT / "scripts"
sys.path.insert(0, str(SCRIPTS))

PORT = 7420
CONTROLS = REPO_ROOT / "build" / "factory" / "controls.json"
HOT = REPO_ROOT / "build" / "factory" / "factory-hot"
BATCH_GATE = REPO_ROOT / "build" / "factory" / "batch-gate.json"
BATCH_FAILURE = REPO_ROOT / "build" / "factory" / "batch-failure.json"
STATION = REPO_ROOT / "build" / "factory" / "station.json"
EVENTS_DIR = REPO_ROOT / "build" / "test-results"

_runner_proc: subprocess.Popen | None = None
_runner_lock = threading.Lock()


def _default_controls() -> dict[str, Any]:
    return {
        "running": False,
        "paused": False,
        "ship_now": False,
        "skip_batch_gate": False,
        "cancel_task_id": None,
        "requeue_task_id": None,
        "priority_bumps": {},
        "batch_running": False,
        "mark_done_task_id": None,
        "updated_at": None,
    }


def read_controls() -> dict[str, Any]:
    if not CONTROLS.is_file():
        return _default_controls()
    try:
        data = json.loads(CONTROLS.read_text(encoding="utf-8"))
        base = _default_controls()
        base.update(data)
        return base
    except (OSError, json.JSONDecodeError):
        return _default_controls()


def write_controls(data: dict[str, Any]) -> None:
    CONTROLS.parent.mkdir(parents=True, exist_ok=True)
    data = dict(data)
    data["updated_at"] = time.time()
    CONTROLS.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def parse_meta(path: Path) -> dict[str, str]:
    text = path.read_text(encoding="utf-8")
    meta: dict[str, str] = {}
    for m in re.finditer(
        r"^\|\s*\*\*([^*]+)\*\*\s*\|\s*([^|]*)\|", text, re.MULTILINE
    ):
        meta[m.group(1).strip()] = m.group(2).strip()
    return meta


def _md_section(text: str, *headings: str) -> str:
    """Return body under the first matching ## heading (case-insensitive)."""
    for heading in headings:
        m = re.search(
            rf"^##\s+{re.escape(heading)}\s*$",
            text,
            re.MULTILINE | re.IGNORECASE,
        )
        if not m:
            continue
        start = m.end()
        n = re.search(r"^##\s+", text[start:], re.MULTILINE)
        end = start + n.start() if n else len(text)
        return text[start:end].strip()
    return ""


def _checklist_items(section: str) -> list[dict[str, Any]]:
    items: list[dict[str, Any]] = []
    for line in section.splitlines():
        m = re.match(r"^[-*]\s+\[([ xX])\]\s+(.*)$", line.strip())
        if m:
            items.append({"done": m.group(1).lower() == "x", "text": m.group(2).strip()})
            continue
        m2 = re.match(r"^[-*]\s+(\d+\.\s+.+)$", line.strip())
        if m2:
            items.append({"done": False, "text": m2.group(1).strip()})
    return items


def _plain_bullets(section: str) -> list[str]:
    out: list[str] = []
    for line in section.splitlines():
        s = line.strip()
        if s.startswith("- ") or s.startswith("* "):
            out.append(s[2:].strip())
    return out


def _safe_ticket_path(rel: str) -> Path | None:
    """Resolve a docs/tasks or docs/slices path under the repo; reject traversal."""
    if not rel or ".." in rel or rel.startswith("/"):
        return None
    if not (rel.startswith("docs/tasks/") or rel.startswith("docs/slices/")):
        return None
    path = (REPO_ROOT / rel).resolve()
    try:
        path.relative_to(REPO_ROOT.resolve())
    except ValueError:
        return None
    if not path.is_file():
        return None
    return path


def ticket_detail(rel_path: str) -> dict[str, Any] | None:
    """Human-readable ticket payload for the Floor drawer."""
    path = _safe_ticket_path(rel_path)
    if path is None:
        return None
    text = path.read_text(encoding="utf-8")
    meta = parse_meta(path)
    item_type = "task" if path.parent.name == "tasks" else "slice"

    crux = meta.get("Crux", "")
    outcome = _md_section(text, "Outcome", "Goal")
    ac_sec = _md_section(text, "Acceptance criteria")
    oos = _md_section(text, "Out of scope", "Out-of-scope")
    tests_sec = _md_section(text, "Surgical test scope", "Verification mapping")
    human = _md_section(text, "Human checklist")
    depends = _md_section(text, "Depends on")
    auth = _md_section(text, "Authorized test changes")
    verify = _md_section(text, "Verification record", "Verification record (QA fills at Verify)")

    verify_line = ""
    vm = re.search(r"^VERIFY RESULT:\s*(.+)$", text, re.MULTILINE | re.IGNORECASE)
    if vm:
        verify_line = vm.group(0).strip()

    return {
        "type": item_type,
        "path": str(path.relative_to(REPO_ROOT)),
        "id": meta.get("ID", path.stem),
        "title": meta.get("Title", path.stem),
        "status": meta.get("Status", ""),
        "kind": meta.get("Kind", item_type),
        "priority": meta.get("Priority", ""),
        "area": meta.get("Area", ""),
        "crux": crux,
        "outcome": outcome,
        "acceptance": _checklist_items(ac_sec) or _plain_bullets(ac_sec),
        "out_of_scope": _plain_bullets(oos),
        "tests": tests_sec,
        "authorized_test_changes": _plain_bullets(auth),
        "depends_on": _plain_bullets(depends) or ([depends] if depends else []),
        "human_checklist": _checklist_items(human),
        "verify_result": verify_line,
        "verification": verify,
    }


def _read_json_file(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def _ps_commands() -> list[str]:
    try:
        out = subprocess.check_output(["ps", "-ax", "-o", "command="], text=True)
    except (OSError, subprocess.CalledProcessError):
        return []
    return out.splitlines()


def _verify_running() -> bool:
    """Best-effort: xcodebuild test or verify.sh alive under this repo."""
    root = str(REPO_ROOT)
    for line in _ps_commands():
        if "xcodebuild" in line and "test" in line and ("PodWash" in line or root in line):
            return True
        if "verify.sh" in line and root in line:
            return True
    return False


def _runner_alive() -> bool:
    """True when the Floor-spawned or any task-loop process is live for this repo."""
    global _runner_proc
    with _runner_lock:
        if _runner_proc is not None and _runner_proc.poll() is None:
            return True
    root = str(REPO_ROOT)
    for line in _ps_commands():
        if "task_loop.py" in line or "task-loop.sh" in line:
            if root in line or "PodWash" in line or "task_loop" in line:
                return True
    return False


def _read_batch_failure() -> dict[str, Any]:
    if not BATCH_FAILURE.is_file():
        return {}
    try:
        data = json.loads(BATCH_FAILURE.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def _write_batch_failure(data: dict[str, Any]) -> None:
    BATCH_FAILURE.parent.mkdir(parents=True, exist_ok=True)
    payload = dict(data)
    payload["updated_at"] = time.time()
    BATCH_FAILURE.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def _ladder_plain(machine_tried: list[Any]) -> str:
    """Human-readable summary of what the factory already tried."""
    labels: list[str] = []
    for raw in machine_tried:
        tag = str(raw or "")
        if tag == "tier3_retries":
            labels.append("full-suite retries")
        elif tag == "mechanic":
            labels.append("Mechanic fix")
        elif tag.startswith("medic:"):
            outcome = tag.split(":", 1)[1]
            if outcome == "lane_test":
                labels.append("Medic (declined — product tests aren't factory-healable)")
            elif outcome == "healed":
                labels.append("Medic heal")
            else:
                labels.append(f"Medic ({outcome})")
        elif tag:
            labels.append(tag)
    if not labels:
        return ""
    return "Factory already tried: " + ", ".join(labels) + "."


def _batch_plain(reason: str, state: str) -> str:
    """Human-readable batch gate copy — not agent status."""
    r = (reason or "").strip()
    mapping = {
        "never verified": (
            "No full-suite green stamp yet. After the punch-list queue empties, "
            "the loop runs the full test suite (tier-3) and pushes if green."
        ),
        "HEAD moved": "Commits landed since the last green full suite — a batch verify is queued for idle drain.",
        "dirty tree": "Uncommitted changes in the tree — full suite needed before ship.",
        "ship_now": "Ship now requested — full suite will run next.",
        "not needed": "Full suite already green at this commit — nothing to batch-verify.",
        "skipped": "Batch gate skipped for this session.",
        "unavailable": "Batch status unavailable (task_loop import failed).",
        "still_red": "Full suite still failing after Mechanic — decide in Needs you.",
        "verified": "Last full suite was green.",
        "mechanic_retry": "Re-running full suite after Mechanic.",
        "held": "Held — not pushing. Ship now or Retry to run the full suite again.",
        "verify aborted": "Full suite aborted (simulator/infra) — decide in Needs you.",
    }
    if state == "verifying" or state == "running":
        return f"Full suite is running now ({r or 'tier-3'})."
    if state == "needs_decision":
        return mapping.get(r, f"Can't ship ({r or 'failed'}). Open Needs you.")
    if state == "held":
        return mapping["held"]
    if state == "green" and not r:
        return mapping["verified"]
    return mapping.get(r, f"Batch: {r or state or 'idle'}.")


def _fmt_task_id(task_id: Any) -> str:
    if task_id is None or task_id == "":
        return ""
    try:
        return f"task-{int(task_id):03d}"
    except (TypeError, ValueError):
        s = str(task_id)
        if s.isdigit():
            return f"task-{int(s):03d}"
        return s if s.startswith("task-") else f"task-{s}"


def _activity_snapshot(
    *,
    ctrl: dict[str, Any],
    station: dict[str, Any],
    batch: dict[str, Any],
    tasks: list[dict[str, Any]],
    events: list[dict[str, Any]],
    factory_hot: bool,
    runner_alive: bool,
) -> dict[str, Any]:
    """Plain-English Now / agents / next for the Stations panel."""
    paused = bool(ctrl.get("paused"))
    marked_running = bool(ctrl.get("running")) or factory_hot
    in_prog = [t for t in tasks if re.search(r"In Progress", t.get("status") or "", re.I)]
    halted = [t for t in tasks if re.search(r"Halted", t.get("status") or "", re.I)]
    queued = [
        t
        for t in tasks
        if re.search(r"Queued|Ready|Draft", t.get("status") or "", re.I)
        and not re.search(r"needs-human", t.get("kind") or "", re.I)
    ]
    needs_human = [
        t
        for t in tasks
        if re.search(r"Needs-human", t.get("status") or "", re.I)
        or re.search(r"needs-human", t.get("kind") or "", re.I)
    ]

    agents: list[dict[str, str]] = []
    phase = str(station.get("phase") or "").strip()
    role = str(station.get("role") or "").strip()
    detail = str(station.get("detail") or station.get("mission") or "").strip()
    tid = _fmt_task_id(station.get("task_id"))
    mission = str(station.get("mission") or "").strip()

    if phase and role:
        agents.append(
            {
                "role": role,
                "task": tid,
                "phase": phase,
                "doing": detail or mission or phase,
            }
        )

    # Recent event hint when station is thin
    last_ev = events[-1] if events else {}
    ev_role = str(last_ev.get("role") or last_ev.get("agent_name") or "").strip()
    ev_phase = str(last_ev.get("phase") or "").strip()
    ev_event = str(last_ev.get("event") or "").strip()

    batch_plain = _batch_plain(str(batch.get("reason") or ""), str(batch.get("state") or ""))
    orphan = marked_running and not runner_alive and not bool(ctrl.get("batch_running"))

    if orphan:
        stuck = ", ".join(_fmt_task_id(t.get("id")) or str(t.get("id")) for t in in_prog) or "none"
        return {
            "mode": "orphan",
            "headline": "Loop not running",
            "detail": (
                f"UI says hot, but no task-loop process is alive. "
                f"In Progress stuck: {stuck}."
            ),
            "agents": agents,
            "next": "Click Start factory to resume. Or Pause then hand-edit if you meant to reclaim the tree.",
            "batch_plain": batch_plain,
            "orphan": True,
            "runner_alive": False,
        }

    if paused:
        return {
            "mode": "paused",
            "headline": "Paused",
            "detail": "Agents are idle until you Resume.",
            "agents": agents,
            "next": "Click Resume to continue, or Stop to end the shift.",
            "batch_plain": batch_plain,
            "orphan": False,
            "runner_alive": runner_alive,
        }

    if not marked_running and not runner_alive:
        if halted:
            return {
                "mode": "stopped",
                "headline": "Factory stopped",
                "detail": f"Halted: {', '.join(str(t.get('id')) for t in halted)}.",
                "agents": [],
                "next": "Amend the ticket in Cursor if needed, Start factory, then Requeue from Needs you.",
                "batch_plain": batch_plain,
                "orphan": False,
                "runner_alive": False,
            }
        if needs_human:
            return {
                "mode": "stopped",
                "headline": "Factory stopped",
                "detail": "Needs-human tickets are waiting.",
                "agents": [],
                "next": "Handle Needs-human in Cursor, then Start factory.",
                "batch_plain": batch_plain,
                "orphan": False,
                "runner_alive": False,
            }
        if queued or in_prog:
            return {
                "mode": "stopped",
                "headline": "Factory stopped",
                "detail": f"{len(queued)} queued, {len(in_prog)} in progress — no workers.",
                "agents": [],
                "next": "Click Start factory.",
                "batch_plain": batch_plain,
                "orphan": False,
                "runner_alive": False,
            }
        return {
            "mode": "idle",
            "headline": "Shift quiet",
            "detail": "No workers on the floor.",
            "agents": [],
            "next": "Queue work with forge-intake in Cursor, then Start factory.",
            "batch_plain": batch_plain,
            "orphan": False,
            "runner_alive": False,
        }

    # Live / claimed running — verifying always beats needs_decision
    batch_state = str(batch.get("state") or "")
    if batch_state in ("verifying", "running") or ctrl.get("batch_running"):
        return {
            "mode": "batch",
            "headline": "FULL-VERIFY · loop",
            "detail": detail or f"Running full suite ({batch.get('reason') or 'tier-3'}).",
            "agents": agents
            or [{"role": "loop", "task": "", "phase": "FULL-VERIFY", "doing": "tier-3 full suite"}],
            "next": "Wait — no action needed unless it fails (Needs you will light up).",
            "batch_plain": batch_plain,
            "orphan": False,
            "runner_alive": runner_alive,
        }

    if batch_state == "needs_decision":
        fail_n = batch.get("failure", {}).get("failed") if isinstance(batch.get("failure"), dict) else None
        detail_line = "Can't ship — full suite still failing."
        if fail_n is not None:
            detail_line = f"Can't ship — {fail_n} test(s) failed."
        elif (batch.get("reason") or "") == "verify aborted":
            detail_line = "Can't ship — verify aborted."
        return {
            "mode": "needs_decision",
            "headline": "Needs you",
            "detail": detail_line,
            "agents": agents,
            "next": "Open Needs you: Don't push, Retry full suite, or Copy for Cursor.",
            "batch_plain": batch_plain,
            "orphan": False,
            "runner_alive": runner_alive,
        }

    if batch_state == "held":
        return {
            "mode": "held",
            "headline": "Held — not pushing",
            "detail": f"Incident acknowledged at {(batch.get('head_sha') or '')[:12] or 'HEAD'}.",
            "agents": agents,
            "next": "Ship now or Retry full suite when ready; or queue more work.",
            "batch_plain": batch_plain,
            "orphan": False,
            "runner_alive": runner_alive,
        }

    if agents:
        who = agents[0]
        label = f"{who['phase']} · {who['role']}"
        if who.get("task"):
            label += f" · {who['task']}"
        nxt = "Nothing — agents are working. Watch the active card and event feed."
        if phase.lower() in ("halted",):
            nxt = "Amend ticket in Cursor if needed, then Requeue from Needs you."
        return {
            "mode": "working",
            "headline": label,
            "detail": who.get("doing") or mission or detail,
            "agents": agents,
            "next": nxt,
            "batch_plain": batch_plain,
            "orphan": False,
            "runner_alive": runner_alive,
        }

    if in_prog:
        t0 = in_prog[0]
        hint = ""
        if ev_role or ev_event:
            hint = f" Last event: {ev_phase} {ev_role} {ev_event}".strip()
        return {
            "mode": "working",
            "headline": f"In Progress · {_fmt_task_id(t0.get('id')) or t0.get('id')}",
            "detail": (t0.get("title") or "") + ("." if hint else "") + hint,
            "agents": [
                {
                    "role": ev_role or "pipeline",
                    "task": _fmt_task_id(t0.get("id")),
                    "phase": ev_phase or "task",
                    "doing": (t0.get("title") or "working")[:80],
                }
            ],
            "next": "Wait — task is claimed. If this stalls for minutes, Stop then Start factory.",
            "batch_plain": batch_plain,
            "orphan": False,
            "runner_alive": runner_alive,
        }

    if queued and runner_alive:
        return {
            "mode": "picking",
            "headline": "Queue · loop picking next task",
            "detail": f"{len(queued)} queued.",
            "agents": [{"role": "loop", "task": "", "phase": "queue", "doing": "selecting next task"}],
            "next": "Nothing — next card will move to In Progress shortly.",
            "batch_plain": batch_plain,
            "orphan": False,
            "runner_alive": runner_alive,
        }

    # Idle drain / batch pending while queue empty
    if batch.get("needed") and runner_alive:
        return {
            "mode": "batch_pending",
            "headline": "Idle drain · batch pending",
            "detail": batch_plain,
            "agents": [{"role": "loop", "task": "", "phase": "batch", "doing": "waiting to run full suite"}],
            "next": "Nothing — full suite runs when the queue is empty. Or click Ship now to force it.",
            "batch_plain": batch_plain,
            "orphan": False,
            "runner_alive": runner_alive,
        }

    return {
        "mode": "quiet",
        "headline": "Shift quiet — no workers on the floor yet.",
        "detail": "",
        "agents": [],
        "next": "Queue work with forge-intake, or click Ship now if you only need a full verify/push.",
        "batch_plain": batch_plain,
        "orphan": False,
        "runner_alive": runner_alive,
    }


def _batch_snapshot(ctrl: dict[str, Any]) -> dict[str, Any]:
    """Derive batch gate UI state from incident + stamp + liveness.

    Single enum: verifying | needs_decision | held | green | idle | pending
    """
    try:
        from task_loop import batch_needed, head_sha, read_batch_gate
    except ImportError:
        return {
            "state": "idle",
            "needed": False,
            "reason": "unavailable",
            "plain": _batch_plain("unavailable", "idle"),
            "failure": None,
        }

    stamp = read_batch_gate(path=str(BATCH_GATE)) if BATCH_GATE.is_file() else {}
    needed, reason = batch_needed(force=False)
    head = head_sha()
    last = str(stamp.get("sha") or "")
    # Only treat live verify as batch when the loop marked batch_running / ship_now —
    # otherwise surgical tier-2 would look like batch.
    batch_running = bool(ctrl.get("batch_running")) or (
        bool(ctrl.get("ship_now")) and _verify_running()
    )
    verifying = bool(batch_running)

    incident = _read_batch_failure()
    failure_payload: dict[str, Any] | None = None
    incident_at_head = False
    if incident:
        inc_sha = str(incident.get("head_sha") or "").strip()
        stale = bool(head and inc_sha and inc_sha != head)
        failure_payload = dict(incident)
        failure_payload["stale"] = stale
        failure_payload["ladder"] = _ladder_plain(list(incident.get("machine_tried") or []))
        incident_at_head = (not stale) and bool(inc_sha) and (not head or inc_sha == head)

    if verifying:
        state = "verifying"
        reason_out = reason if needed else "tier-3"
    elif incident_at_head and incident.get("status") == "open":
        state = "needs_decision"
        reason_out = str(incident.get("reason") or "still_red")
    elif incident_at_head and incident.get("status") == "acknowledged":
        state = "held"
        reason_out = "held"
    elif last and head and last == head and not needed:
        state = "green"
        reason_out = reason
    elif needed:
        state = "pending"
        reason_out = reason
    elif last:
        state = "green"
        reason_out = reason
    else:
        state = "idle"
        reason_out = reason

    return {
        "state": state,
        "needed": needed,
        "reason": reason_out,
        "last_green_sha": last,
        "head_sha": head,
        "verify_running": _verify_running(),
        "batch_running": batch_running,
        "plain": _batch_plain(reason_out, state),
        "failure": failure_payload,
    }


def board_snapshot() -> dict[str, Any]:
    tasks = []
    tasks_dir = REPO_ROOT / "docs" / "tasks"
    if tasks_dir.is_dir():
        for path in sorted(tasks_dir.glob("task-*.md")):
            if path.name.startswith("_"):
                continue
            meta = parse_meta(path)
            tasks.append(
                {
                    "id": meta.get("ID", path.name),
                    "title": meta.get("Title", path.stem),
                    "status": meta.get("Status", "?"),
                    "kind": meta.get("Kind", ""),
                    "priority": meta.get("Priority", ""),
                    "area": meta.get("Area", ""),
                    "path": str(path.relative_to(REPO_ROOT)),
                    "type": "task",
                }
            )
    slices = []
    slices_dir = REPO_ROOT / "docs" / "slices"
    if slices_dir.is_dir():
        for path in sorted(slices_dir.glob("slice-[0-9][0-9]-*.md")):
            if path.name.endswith("-ux.md"):
                continue
            meta = parse_meta(path)
            st = meta.get("Status", "")
            if re.search(r"Deferred|post-MVP", st, re.I):
                continue
            slices.append(
                {
                    "id": meta.get("ID", path.name),
                    "title": meta.get("Title", path.stem),
                    "status": st,
                    "kind": "slice",
                    "priority": "P3",
                    "area": "",
                    "path": str(path.relative_to(REPO_ROOT)),
                    "type": "slice",
                }
            )
    events: list[dict[str, Any]] = []
    if EVENTS_DIR.is_dir():
        files = sorted(EVENTS_DIR.glob("events-*.jsonl"), key=lambda p: p.stat().st_mtime)
        for ef in files[-5:]:
            try:
                for line in ef.read_text(encoding="utf-8").splitlines()[-20:]:
                    if line.strip():
                        events.append(json.loads(line))
            except (OSError, json.JSONDecodeError):
                pass
    ctrl = read_controls()
    station = _read_json_file(STATION)
    batch = _batch_snapshot(ctrl)
    derived_state = batch.get("state")
    # Prefer live station.batch overlay for reason/detail, but derived state wins
    # (prevents sticky "blocked" while verify is running).
    if isinstance(station.get("batch"), dict):
        merged = dict(batch)
        for k, v in station["batch"].items():
            if k in ("state", "failure"):
                continue
            merged[k] = v
        if ctrl.get("batch_running"):
            merged["state"] = "verifying"
        else:
            merged["state"] = derived_state
        merged["plain"] = _batch_plain(
            str(merged.get("reason") or ""), str(merged.get("state") or "")
        )
        batch = merged
    runner_alive = _runner_alive()
    factory_hot = HOT.is_file()
    activity = _activity_snapshot(
        ctrl=ctrl,
        station=station,
        batch=batch,
        tasks=tasks,
        events=events[-40:],
        factory_hot=factory_hot,
        runner_alive=runner_alive,
    )
    return {
        "tasks": tasks,
        "slices": slices,
        "controls": ctrl,
        "factory_hot": factory_hot,
        "runner_alive": runner_alive,
        "station": station,
        "batch": batch,
        "activity": activity,
        "events": events[-40:],
        "ts": time.time(),
    }


def _task_path_for_id(tid: int) -> Path | None:
    tasks_dir = REPO_ROOT / "docs" / "tasks"
    if not tasks_dir.is_dir():
        return None
    prefix = f"task-{int(tid):03d}-"
    for path in tasks_dir.glob(f"{prefix}*.md"):
        return path
    return None


def requeue_task(task_id: Any) -> str:
    """Immediately move a Halted (or any) task back to Queued — do not wait for the loop."""
    try:
        tid = int(task_id)
    except (TypeError, ValueError):
        return f"invalid task_id {task_id!r}"
    path = _task_path_for_id(tid)
    if path is None:
        return f"task-{tid:03d} not found"
    from task_ticket import set_task_status

    set_task_status(str(path), "Queued")
    return f"requeued task-{tid:03d} → Queued"


def start_runner() -> str:
    global _runner_proc
    with _runner_lock:
        if _runner_proc is not None and _runner_proc.poll() is None:
            return "already running"
        env = os.environ.copy()
        env["PODWASH_FORGE_LOOP"] = "task_loop"
        _runner_proc = subprocess.Popen(
            [str(SCRIPTS / "task-loop.sh"), "--medic-no-push"],
            cwd=str(REPO_ROOT),
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        ctrl = read_controls()
        ctrl["running"] = True
        ctrl["paused"] = False
        write_controls(ctrl)
        return f"started pid={_runner_proc.pid}"


def stop_runner() -> str:
    global _runner_proc
    ctrl = read_controls()
    ctrl["running"] = False
    ctrl["paused"] = True
    write_controls(ctrl)
    with _runner_lock:
        if _runner_proc is not None and _runner_proc.poll() is None:
            _runner_proc.terminate()
            try:
                _runner_proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                _runner_proc.kill()
        _runner_proc = None
    return "stopped"


INDEX_HTML = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<title>Forge Floor</title>
<style>
:root {
  --bg: #1a1c1e;
  --panel: #24282c;
  --ink: #e8eaed;
  --muted: #9aa0a6;
  --accent: #e8a838;
  --ok: #5bb88a;
  --warn: #e07a5f;
  --line: #3a3f45;
  --font: "IBM Plex Sans", "Segoe UI", system-ui, sans-serif;
}
* { box-sizing: border-box; }
body {
  margin: 0; font-family: var(--font); background:
    radial-gradient(1200px 600px at 10% -10%, #2a3140 0%, transparent 55%),
    var(--bg);
  color: var(--ink); min-height: 100vh;
}
header {
  display: flex; align-items: center; gap: 1rem; padding: 1rem 1.25rem;
  border-bottom: 1px solid var(--line);
}
header h1 { margin: 0; font-size: 1.35rem; letter-spacing: 0.04em; }
header .brand { color: var(--accent); font-weight: 700; }
.hint { color: var(--muted); font-size: 0.85rem; }
.toolbar { display: flex; flex-wrap: wrap; gap: 0.5rem; margin-left: auto; }
button {
  background: var(--panel); color: var(--ink); border: 1px solid var(--line);
  border-radius: 6px; padding: 0.45rem 0.75rem; cursor: pointer; font: inherit;
}
button.primary { background: var(--accent); color: #1a1c1e; border-color: transparent; font-weight: 600; }
button:disabled {
  opacity: 0.45; cursor: not-allowed;
}
button.primary:disabled {
  background: #3a3f45; color: var(--muted); border-color: var(--line);
}
button.danger { border-color: var(--warn); color: var(--warn); }
button:hover { filter: brightness(1.08); }
main {
  display: grid; grid-template-columns: 1fr 340px; gap: 1rem; padding: 1rem;
  align-items: start;
  height: calc(100vh - 4.5rem);
}
@media (max-width: 900px) {
  main { grid-template-columns: 1fr; height: auto; }
}
.columns {
  display: grid; grid-template-columns: repeat(5, minmax(140px, 1fr)); gap: 0.75rem;
  height: 100%; min-height: 0;
}
.col {
  background: var(--panel); border-radius: 10px; border: 1px solid var(--line);
  display: flex; flex-direction: column; min-height: 0;
  max-height: calc(100vh - 6.5rem); overflow: hidden;
}
.col h2 {
  margin: 0; padding: 0.6rem 0.75rem; font-size: 0.8rem; text-transform: uppercase;
  letter-spacing: 0.06em; color: var(--muted); border-bottom: 1px solid var(--line);
  flex-shrink: 0; background: var(--panel); position: sticky; top: 0; z-index: 1;
  display: flex; align-items: baseline; justify-content: space-between; gap: 0.35rem;
}
.col h2 .count { font-weight: 500; text-transform: none; letter-spacing: 0; color: var(--muted); }
.col h2 .col-toggle {
  font: inherit; font-size: 0.68rem; font-weight: 600; text-transform: none;
  letter-spacing: 0; color: var(--accent); background: transparent; border: none;
  padding: 0; cursor: pointer; white-space: nowrap;
}
.col h2 .col-toggle:hover { filter: brightness(1.15); text-decoration: underline; }
.col .cards {
  overflow-y: auto; flex: 1; min-height: 0; padding-bottom: 0.35rem;
}
.card {
  margin: 0.5rem; padding: 0.65rem; border-radius: 8px; background: #2c3136;
  border: 1px solid var(--line); cursor: pointer;
}
.card.summary {
  border-style: dashed; color: var(--muted); font-size: 0.82rem; cursor: pointer;
}
.card .meta { font-size: 0.75rem; color: var(--muted); }
.card .prio { color: var(--accent); font-weight: 600; }
.side {
  display: flex; flex-direction: column; gap: 0.75rem;
  max-height: calc(100vh - 6.5rem); min-height: 0;
}
.station, .feed, .needs-you {
  background: var(--panel); border: 1px solid var(--line); border-radius: 10px; padding: 0.75rem;
}
.station h3, .feed h3, .needs-you h3 { margin: 0 0 0.5rem; font-size: 0.9rem; }
.station .label {
  font-size: 0.68rem; text-transform: uppercase; letter-spacing: 0.06em;
  color: var(--muted); margin: 0.55rem 0 0.2rem;
}
.station .label:first-of-type { margin-top: 0; }
.station .beat { color: var(--ink); font-size: 0.95rem; font-weight: 600; }
.station .sub { color: var(--muted); font-size: 0.8rem; margin-top: 0.35rem; line-height: 1.35; }
.station .next-line {
  margin-top: 0.35rem; font-size: 0.82rem; color: var(--ink); line-height: 1.35;
  padding: 0.45rem 0.55rem; background: #2a2f35; border-radius: 6px;
  border-left: 3px solid var(--accent);
}
.station .agents { margin-top: 0.35rem; display: flex; flex-direction: column; gap: 0.35rem; }
.station .agent {
  font-size: 0.8rem; padding: 0.4rem 0.5rem; border-radius: 6px;
  background: #2c3136; border: 1px solid var(--line); line-height: 1.3;
}
.station .agent strong { color: var(--ok); }
.station .agent .muted { color: var(--muted); font-size: 0.75rem; }
.station .batch-line {
  margin-top: 0.35rem; font-size: 0.78rem; color: var(--muted); line-height: 1.4;
}
.station .batch-line strong { color: var(--accent); }
.station.running { border-color: var(--ok); }
.station.pending { border-color: var(--accent); }
.station.blocked, .station.orphan, .station.needs_decision { border-color: var(--warn); }
.card.active {
  border-color: var(--ok);
  box-shadow: 0 0 0 1px var(--ok);
}
.card .card-actions {
  display: flex; gap: 0.35rem; margin-top: 0.45rem; flex-wrap: wrap;
}
.card .card-actions button {
  font-size: 0.72rem; padding: 0.2rem 0.45rem;
}
.needs-you.on { border-color: var(--warn); box-shadow: 0 0 0 1px var(--warn); }
.needs-you .fail-list { margin: 0.5rem 0; padding-left: 1.1rem; font-size: 0.8rem; }
.needs-you .fail-list li { margin: 0.25rem 0; }
.needs-you .consequence { color: var(--muted); font-size: 0.75rem; margin: 0.15rem 0 0.55rem; }
.needs-you .ladder { color: var(--muted); font-size: 0.78rem; margin: 0.4rem 0; line-height: 1.35; }
.needs-you .halted-strip { margin-top: 0.75rem; padding-top: 0.5rem; border-top: 1px solid var(--line); font-size: 0.8rem; }
.needs-you .evidence { color: var(--muted); font-size: 0.72rem; word-break: break-all; margin-top: 0.35rem; }
.needs-you .repeat-warn { color: var(--warn); font-size: 0.78rem; margin: 0.4rem 0; }
.feed { flex: 1; min-height: 120px; max-height: none; overflow: auto; font-size: 0.8rem; }
.feed div { padding: 0.25rem 0; border-bottom: 1px solid var(--line); }
.feed .ts { color: var(--muted); font-size: 0.72rem; margin-right: 0.35rem; }
.status-pill { display: inline-block; padding: 0.15rem 0.5rem; border-radius: 999px;
  background: #333; font-size: 0.75rem; }
.status-pill.hot { background: #3a4a3a; color: var(--ok); }
.drawer {
  position: fixed; right: 0; top: 0; bottom: 0; width: min(520px, 100%);
  background: #1e2226; border-left: 1px solid var(--line); padding: 1rem 1.1rem 2rem;
  transform: translateX(100%); transition: transform 0.2s ease; z-index: 20;
  overflow-y: auto;
}
.drawer.open { transform: translateX(0); }
.drawer h2 { margin: 0.65rem 0 0.4rem; font-size: 1.15rem; line-height: 1.3; }
.drawer .ticket-meta {
  display: flex; flex-wrap: wrap; gap: 0.4rem; margin: 0.5rem 0 1rem;
}
.drawer .chip {
  display: inline-block; padding: 0.15rem 0.55rem; border-radius: 999px;
  font-size: 0.72rem; font-weight: 600; letter-spacing: 0.02em;
  background: #333940; color: var(--ink); border: 1px solid var(--line);
}
.drawer .chip.status-queued { background: #2f3540; }
.drawer .chip.status-progress { background: #2a4038; color: var(--ok); border-color: #3d5c4c; }
.drawer .chip.status-halted, .drawer .chip.status-needs { background: #40302c; color: var(--warn); border-color: #6a4538; }
.drawer .chip.status-done { background: #2a4038; color: var(--ok); }
.drawer .chip.prio { color: var(--accent); border-color: #6a5530; }
.drawer .ticket-section { margin: 1rem 0; }
.drawer .ticket-section h3 {
  margin: 0 0 0.4rem; font-size: 0.72rem; text-transform: uppercase;
  letter-spacing: 0.07em; color: var(--muted); font-weight: 600;
}
.drawer .ticket-section p, .drawer .ticket-section .prose {
  margin: 0; font-size: 0.9rem; line-height: 1.45; color: var(--ink);
  white-space: pre-wrap;
}
.drawer .crux {
  background: #2a2f35; border-left: 3px solid var(--accent);
  padding: 0.65rem 0.75rem; border-radius: 0 8px 8px 0; font-size: 0.92rem;
  line-height: 1.4;
}
.drawer ul.ac { list-style: none; margin: 0; padding: 0; }
.drawer ul.ac li {
  display: flex; gap: 0.5rem; align-items: flex-start;
  padding: 0.4rem 0; border-bottom: 1px solid var(--line);
  font-size: 0.88rem; line-height: 1.35;
}
.drawer ul.ac li:last-child { border-bottom: none; }
.drawer .box {
  width: 1rem; height: 1rem; flex-shrink: 0; margin-top: 0.15rem;
  border: 1.5px solid var(--muted); border-radius: 3px;
  display: inline-flex; align-items: center; justify-content: center;
  font-size: 0.7rem; color: var(--ok);
}
.drawer .box.done { border-color: var(--ok); background: #2a4038; }
.drawer ul.plain { margin: 0; padding-left: 1.1rem; }
.drawer ul.plain li { margin: 0.25rem 0; font-size: 0.88rem; color: var(--muted); }
.drawer .area { font-size: 0.8rem; color: var(--muted); word-break: break-word; }
.drawer .path-link { font-size: 0.75rem; color: var(--muted); margin-top: 1.25rem; }
.drawer .loading, .drawer .error { color: var(--muted); font-size: 0.9rem; margin-top: 1rem; }
.drawer .error { color: var(--warn); }
.idle { text-align: center; padding: 2rem; color: var(--muted); }
</style>
</head>
<body>
<header>
  <div>
    <h1><span class="brand">Forge Floor</span></h1>
    <div class="hint">Add work in Cursor with <code>forge-intake</code></div>
  </div>
  <span id="hot" class="status-pill">stopped</span>
  <div class="toolbar">
    <button class="primary" id="btnStart">Start factory</button>
    <button id="btnPause">Pause</button>
    <button id="btnResume">Resume</button>
    <button id="btnShip">Ship now</button>
    <button id="btnStop">Stop</button>
  </div>
</header>
<main>
  <section>
    <div id="idle" class="idle" hidden>Waiting for intake — queue a punch list with forge-intake</div>
    <div class="columns" id="board"></div>
  </section>
  <aside class="side">
    <div class="station" id="station">
      <h3>Now</h3>
      <div class="label">Working on</div>
      <div class="beat" id="stationBeat">Shift quiet — no workers on the floor yet.</div>
      <div class="sub" id="stationSub"></div>
      <div class="agents" id="agentList"></div>
      <div class="label">What you should do</div>
      <div class="next-line" id="nextLine">—</div>
      <div class="label">Batch (full suite / ship)</div>
      <div class="batch-line" id="batchLine">—</div>
    </div>
    <div class="needs-you" id="needsYou">
      <h3>Needs you</h3>
      <div id="needsYouBody">All clear.</div>
      <div class="toolbar" id="needsYouActions" style="margin-top:0.5rem; display:none; flex-wrap:wrap; gap:0.35rem">
        <button class="danger" id="btnHold">Don't push</button>
        <button id="btnRetry">Retry full suite</button>
        <button id="btnCopy">Copy for Cursor</button>
      </div>
      <div class="consequence" id="needsYouHint" hidden></div>
      <div class="halted-strip" id="haltedStrip" hidden>
        <div id="haltedBody"></div>
        <div class="toolbar" style="margin-top:0.35rem">
          <button id="btnRequeue">Requeue Halted</button>
        </div>
      </div>
    </div>
    <div class="feed">
      <h3>Event feed</h3>
      <div id="feed"></div>
    </div>
  </aside>
</main>
<div class="drawer" id="drawer">
  <button id="btnClose">Close</button>
  <h2 id="drawerTitle"></h2>
  <div id="drawerBody"></div>
</div>
<script>
const cols = ["Queued","In Progress","Needs-human","Halted","Done"];
let snap = null;
let selected = null;
let showDoneSlices = false;

function colFor(item) {
  const s = (item.status||"");
  if (/Needs-human/i.test(s) || /needs-human/i.test(item.kind||"")) return "Needs-human";
  if (/Halted/i.test(s)) return "Halted";
  if (/In Progress/i.test(s)) return "In Progress";
  if (/^Done/i.test(s)) return "Done";
  if (/Queued|Ready|Draft/i.test(s)) return "Queued";
  return "Queued";
}

function statusChipClass(status) {
  const s = status || "";
  if (/Needs-human/i.test(s)) return "status-needs";
  if (/Halted/i.test(s)) return "status-halted";
  if (/In Progress/i.test(s)) return "status-progress";
  if (/^Done/i.test(s)) return "status-done";
  return "status-queued";
}

function esc(s) {
  return String(s ?? "").replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/"/g,"&quot;");
}

/** Light markdown → HTML after escaping: **bold**, `code` */
function md(s) {
  return esc(s)
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
    .replace(/`([^`]+)`/g, "<code style=\"font-size:0.85em;background:#333;padding:0.05em 0.3em;border-radius:3px\">$1</code>");
}

function renderChecklist(items) {
  if (!items || !items.length) return "";
  // acceptance may be checklist objects or plain strings
  const lis = items.map(it => {
    if (typeof it === "string") {
      return `<li><span class="box"></span><span>${md(it)}</span></li>`;
    }
    return `<li><span class="box${it.done?" done":""}">${it.done?"✓":""}</span><span>${md(it.text)}</span></li>`;
  }).join("");
  return `<ul class="ac">${lis}</ul>`;
}

function renderBullets(items) {
  if (!items || !items.length) return "";
  const filtered = items.filter(x => x && !/^none$/i.test(String(x).trim()));
  if (!filtered.length) return `<p class="prose" style="color:var(--muted)">(none)</p>`;
  return `<ul class="plain">${filtered.map(x => `<li>${md(x)}</li>`).join("")}</ul>`;
}

function renderTicket(t) {
  const meta = `
    <div class="ticket-meta">
      <span class="chip ${statusChipClass(t.status)}">${esc(t.status || "?")}</span>
      ${t.priority ? `<span class="chip prio">${esc(t.priority)}</span>` : ""}
      ${t.kind ? `<span class="chip">${esc(t.kind)}</span>` : ""}
      <span class="chip">${esc(t.type || "task")}</span>
    </div>`;

  const crux = t.crux
    ? `<div class="ticket-section"><h3>What this proves</h3><div class="crux">${md(t.crux)}</div></div>`
    : "";

  const outcomeLabel = t.type === "slice" ? "Goal" : "Outcome";
  const outcome = t.outcome
    ? `<div class="ticket-section"><h3>${outcomeLabel}</h3><div class="prose">${md(t.outcome)}</div></div>`
    : "";

  const ac = (t.acceptance && t.acceptance.length)
    ? `<div class="ticket-section"><h3>Acceptance criteria</h3>${renderChecklist(t.acceptance)}</div>`
    : "";

  const human = (t.human_checklist && t.human_checklist.length)
    ? `<div class="ticket-section"><h3>Human checklist</h3>${renderChecklist(t.human_checklist)}</div>`
    : "";

  const tests = t.tests
    ? `<div class="ticket-section"><h3>Tests</h3><div class="prose">${md(t.tests)}</div></div>`
    : "";

  const auth = (t.authorized_test_changes && t.authorized_test_changes.length)
    ? `<div class="ticket-section"><h3>Authorized test changes</h3>${renderBullets(t.authorized_test_changes)}</div>`
    : "";

  const oos = (t.out_of_scope && t.out_of_scope.length)
    ? `<div class="ticket-section"><h3>Out of scope</h3>${renderBullets(t.out_of_scope)}</div>`
    : "";

  const area = t.area
    ? `<div class="ticket-section"><h3>Area</h3><div class="area">${md(t.area)}</div></div>`
    : "";

  const depends = (t.depends_on && t.depends_on.length)
    ? `<div class="ticket-section"><h3>Depends on</h3>${renderBullets(t.depends_on)}</div>`
    : "";

  const verify = t.verify_result
    ? `<div class="ticket-section"><h3>Verification</h3><div class="prose">${esc(t.verify_result)}</div></div>`
    : "";

  const path = t.path
    ? `<div class="path-link">${esc(t.path)}</div>`
    : "";

  return meta + crux + outcome + ac + human + tests + auth + oos + area + depends + verify + path;
}

function batchLabel(b, activity) {
  if (activity && activity.batch_plain) {
    const short = (s) => (s ? String(s).slice(0, 12) : "");
    const sha = short(b && b.last_green_sha);
    const head = `Batch · ${b && b.state ? b.state : "—"}${sha ? " @ " + sha : ""}`;
    return `<strong>${esc(head)}</strong><br/>${esc(activity.batch_plain)}`;
  }
  if (!b) return "Batch · —";
  const short = (s) => (s ? String(s).slice(0, 12) : "?");
  if (b.state === "running" || b.state === "verifying" || b.batch_running) {
    return `<strong>Batch · verifying</strong><br/>${esc(b.plain || b.reason || "tier-3")}`;
  }
  if (b.state === "needs_decision") {
    return `<strong>Batch · needs you</strong><br/>${esc(b.plain || "decide below")}`;
  }
  if (b.state === "held") {
    return `<strong>Batch · held</strong><br/>${esc(b.plain || "not pushing")}`;
  }
  if (b.state === "blocked") {
    return `<strong>Batch · needs you</strong><br/>${esc(b.plain || "decide below")}`;
  }
  if (b.state === "pending" || b.needed) {
    return `<strong>Batch · pending</strong><br/>${esc(b.plain || b.reason || "full verify needed")}`;
  }
  if (b.state === "green" || b.last_green_sha) {
    return `<strong>Batch · green @ ${esc(short(b.last_green_sha))}</strong><br/>${esc(b.plain || "ok")}`;
  }
  return `<strong>Batch · idle</strong>`;
}

function formatEvent(ev) {
  const ts = (ev.ts || "").replace("T", " ").replace("Z", "").slice(11, 19) || "";
  const slice = ev.slice != null ? `task/slice ${ev.slice}` : "";
  const parts = [ev.phase, ev.role || ev.agent_name, ev.event, slice]
    .filter(Boolean).map(String);
  const mission = (ev.detail && ev.detail.mission) || ev.mission || "";
  if (mission) parts.push("— " + mission);
  return { ts, text: parts.join(" ") };
}

function makeCard(item, st, activeTid) {
  const card = document.createElement("div");
  const isActive = item.type==="task" && activeTid && String(item.id).padStart(3,"0")===activeTid;
  card.className = "card" + (isActive ? " active" : "");
  let phaseHtml = "";
  if (isActive && st.phase) {
    phaseHtml = `<div class="phase">${esc(st.phase)}${st.role ? " · " + esc(st.role) : ""}${st.detail ? " — " + esc(st.detail) : ""}</div>`;
  }
  const halted = item.type === "task" && /Halted/i.test(item.status || "");
  let actionsHtml = "";
  if (halted) {
    actionsHtml = `<div class="card-actions"><button type="button" data-requeue="${esc(item.id)}">Requeue</button></div>`;
  }
  card.innerHTML = `<div><span class="prio">${esc(item.priority||"")}</span> ${esc(item.type)} ${esc(item.id)}</div>
    <div>${esc(item.title||"")}</div>
    <div class="meta">${esc(item.kind||"")} · ${esc((item.area||"").slice(0,40))}</div>${phaseHtml}${actionsHtml}`;
  card.onclick = (e) => {
    const btn = e.target && e.target.closest && e.target.closest("[data-requeue]");
    if (btn) {
      e.stopPropagation();
      const id = parseInt(String(btn.getAttribute("data-requeue") || "").replace(/\D/g, ""), 10);
      if (!id) return alert("Bad task id");
      post("/api/control", {action: "requeue", task_id: id});
      return;
    }
    openDrawer(item);
  };
  return card;
}

function render() {
  if (!snap) return;
  const hot = document.getElementById("hot");
  const runnerAlive = !!snap.runner_alive;
  const marked = !!(snap.controls && snap.controls.running) || snap.factory_hot;
  const running = marked || runnerAlive;
  const activity = snap.activity || {};
  if (activity.orphan) {
    hot.textContent = "orphan";
    hot.className = "status-pill";
    hot.style.background = "#40302c";
    hot.style.color = "var(--warn)";
  } else {
    hot.style.background = "";
    hot.style.color = "";
    hot.textContent = running
      ? (snap.controls && snap.controls.paused ? "paused" : (runnerAlive ? "hot" : "hot?"))
      : "stopped";
    hot.className = "status-pill" + (running ? " hot" : "");
  }

  const board = document.getElementById("board");
  board.innerHTML = "";
  const items = [...(snap.tasks||[]), ...(snap.slices||[])];
  const idle = document.getElementById("idle");
  const queuedAuto = items.filter(i => colFor(i)==="Queued" && i.type==="task" && !/needs-human/i.test(i.kind||""));
  const inProg = items.filter(i => colFor(i)==="In Progress" && i.type==="task");
  const batch = snap.batch || {};
  const st = snap.station || {};
  let idleMsg = "Waiting for intake — queue a punch list with forge-intake";
  if (activity.orphan) {
    idleMsg = activity.detail || "Loop not running — click Start factory";
    idle.hidden = false;
    idle.textContent = idleMsg;
  } else if (running && queuedAuto.length===0 && inProg.length===0 && batch.state !== "needs_decision") {
    if (batch.state === "running" || batch.state === "verifying" || batch.batch_running) {
      idleMsg = `Queue empty · full verify running (${batch.reason||"tier-3"})`;
    } else if (batch.state === "held") {
      idleMsg = `Queue empty · held — not pushing`;
    } else if (batch.needed) {
      idleMsg = `Queue empty · full verify pending — ${batch.reason||"needed"}`;
    } else if (batch.state === "green") {
      idleMsg = `Queue empty · full verify not needed (green @ ${(batch.last_green_sha||"").slice(0,12)})`;
    }
    idle.hidden = false;
    idle.textContent = idleMsg;
  } else {
    idle.hidden = true;
  }

  const activeTid = st.task_id != null ? String(st.task_id).padStart(3,"0") : null;
  for (const name of cols) {
    const col = document.createElement("div");
    col.className = "col";
    let colItems = items.filter(i => colFor(i)===name);
    const doneSlices = name === "Done" ? colItems.filter(i => i.type === "slice") : [];
    const doneTasks = name === "Done" ? colItems.filter(i => i.type === "task") : [];
    if (name === "Done" && !showDoneSlices) {
      colItems = doneTasks;
    }
    const h2 = document.createElement("h2");
    const left = document.createElement("span");
    left.textContent = name;
    const right = document.createElement("span");
    right.style.display = "inline-flex";
    right.style.alignItems = "baseline";
    right.style.gap = "0.45rem";
    const totalCount = name === "Done"
      ? (doneTasks.length + doneSlices.length)
      : colItems.length;
    const countEl = document.createElement("span");
    countEl.className = "count";
    countEl.textContent = String(totalCount);
    right.appendChild(countEl);
    if (name === "Done" && doneSlices.length) {
      const toggle = document.createElement("button");
      toggle.type = "button";
      toggle.className = "col-toggle";
      toggle.textContent = showDoneSlices
        ? "Collapse slices"
        : `Show ${doneSlices.length} slices`;
      toggle.onclick = (e) => {
        e.stopPropagation();
        showDoneSlices = !showDoneSlices;
        render();
      };
      right.appendChild(toggle);
    }
    h2.appendChild(left);
    h2.appendChild(right);
    col.appendChild(h2);
    const cards = document.createElement("div");
    cards.className = "cards";
    for (const item of colItems) {
      cards.appendChild(makeCard(item, st, activeTid));
    }
    if (name === "Done" && doneSlices.length && showDoneSlices) {
      for (const item of doneSlices) {
        cards.appendChild(makeCard(item, st, activeTid));
      }
    }
    col.appendChild(cards);
    board.appendChild(col);
  }

  const ny = document.getElementById("needsYou");
  const nyBody = document.getElementById("needsYouBody");
  const nyActions = document.getElementById("needsYouActions");
  const nyHint = document.getElementById("needsYouHint");
  const haltedStrip = document.getElementById("haltedStrip");
  const haltedBody = document.getElementById("haltedBody");
  const needsDecision = batch.state === "needs_decision";
  const held = batch.state === "held";
  const fail = batch.failure || null;
  const halted = items.filter(i => /Halted/i.test(i.status||""));

  function renderNeedsYouBody() {
    if (activity.orphan) {
      return "Loop died while marked hot — click Start factory to resume.";
    }
    if (held) {
      const sha = (batch.head_sha || "").slice(0, 12) || "HEAD";
      return `Held at ${sha} — not pushing. Ship now or Retry to run the full suite again.`;
    }
    if (!needsDecision) return "All clear.";
    const reason = (fail && fail.reason) || batch.reason || "still_red";
    const fails = (fail && fail.failures) || [];
    const n = fail && fail.failed != null ? fail.failed : fails.length;
    let html = "";
    if (reason === "verify aborted" && !fails.length) {
      html += `<div><strong>Can't ship — verify aborted</strong></div>`;
    } else {
      html += `<div><strong>Can't ship — ${esc(String(n))} test(s) failed</strong></div>`;
      if (fail && (fail.passed != null)) {
        html += `<div class="consequence">${esc(String(fail.passed))} passed · ${esc(String(n))} failed</div>`;
      }
    }
    if (fails.length) {
      html += `<ul class="fail-list">` + fails.slice(0, 5).map(f => {
        const id = (f && f.id) || "?";
        const assertion = (f && f.assertion) || "";
        return `<li><code>${esc(id)}</code>${assertion ? " — " + esc(assertion) : ""}</li>`;
      }).join("") + `</ul>`;
    }
    if (fail && fail.ladder) {
      html += `<div class="ladder">${esc(fail.ladder)}</div>`;
    }
    const prior = (fail && fail.prior_failures) || [];
    const curIds = fails.map(f => f && f.id).filter(Boolean);
    const repeat = curIds.length && prior.length && curIds.every(id => prior.includes(id));
    if (repeat) {
      html += `<div class="repeat-warn">Same tests failed twice — retry is unlikely to pass. Copy for Cursor and file a fix.</div>`;
    }
    const evidence = [];
    if (fail && fail.bundle) evidence.push(fail.bundle);
    if (fail && fail.output) evidence.push(fail.output);
    if (evidence.length) {
      html += `<div class="evidence">${evidence.map(esc).join(" · ")}</div>`;
    }
    return html;
  }

  nyBody.innerHTML = renderNeedsYouBody();
  if (activity.orphan || needsDecision || held) {
    ny.classList.add("on");
  } else {
    ny.classList.remove("on");
  }
  nyActions.style.display = needsDecision ? "flex" : "none";
  if (needsDecision) {
    nyHint.hidden = false;
    nyHint.textContent = "Don't push leaves commits local. Retry reruns the full suite + one auto-fix pass (~10–15 min).";
  } else {
    nyHint.hidden = true;
  }
  if (halted.length) {
    haltedStrip.hidden = false;
    haltedBody.textContent = `Halted: ${halted.map(h => h.id).join(", ")}. Amend in Cursor if needed, then Requeue.`;
  } else {
    haltedStrip.hidden = true;
  }

  const feed = document.getElementById("feed");
  feed.innerHTML = "";
  for (const ev of (snap.events||[]).slice().reverse()) {
    const d = document.createElement("div");
    const { ts, text } = formatEvent(ev);
    d.innerHTML = (ts ? `<span class="ts">${esc(ts)}</span>` : "") + esc(text);
    feed.appendChild(d);
  }

  const stationEl = document.getElementById("station");
  const mode = activity.mode || "";
  stationEl.className = "station" + (
    mode === "orphan" || mode === "needs_decision" ? " orphan"
    : batch.state === "verifying" || batch.state === "running" || batch.batch_running ? " running"
    : batch.state === "needs_decision" || batch.state === "blocked" ? " blocked"
    : batch.state === "held" ? " pending"
    : batch.needed && !activity.agents?.length ? " pending" : ""
  );
  document.getElementById("stationBeat").textContent = activity.headline
    || "Shift quiet — no workers on the floor yet.";
  document.getElementById("stationSub").textContent = activity.detail || "";
  document.getElementById("nextLine").textContent = activity.next || "—";
  document.getElementById("batchLine").innerHTML = batchLabel(batch, activity);

  const agentList = document.getElementById("agentList");
  agentList.innerHTML = "";
  const agents = activity.agents || [];
  if (agents.length) {
    for (const a of agents) {
      const row = document.createElement("div");
      row.className = "agent";
      const taskBit = a.task ? ` on ${esc(a.task)}` : "";
      row.innerHTML = `<strong>${esc(a.role || "?")}</strong>${taskBit}`
        + `<div class="muted">${esc(a.phase || "")}${a.doing ? " — " + esc(a.doing) : ""}</div>`;
      agentList.appendChild(row);
    }
  } else {
    const row = document.createElement("div");
    row.className = "agent";
    row.innerHTML = `<span class="muted">No agents active</span>`;
    agentList.appendChild(row);
  }

  syncToolbar(snap, activity, running, runnerAlive);
}

/** Primary action + enable/disable follow real factory state. */
function syncToolbar(snap, activity, running, runnerAlive) {
  const ctrl = (snap && snap.controls) || {};
  const paused = !!ctrl.paused;
  const orphan = !!(activity && activity.orphan);
  const btnStart = document.getElementById("btnStart");
  const btnPause = document.getElementById("btnPause");
  const btnResume = document.getElementById("btnResume");
  const btnStop = document.getElementById("btnStop");
  const btnShip = document.getElementById("btnShip");

  [btnStart, btnPause, btnResume, btnStop, btnShip].forEach((b) => {
    if (b) b.classList.remove("primary");
  });

  if (orphan) {
    btnStart.textContent = "Restart factory";
    btnStart.disabled = false;
    btnStart.classList.add("primary");
    btnPause.disabled = true;
    btnResume.disabled = true;
    btnStop.disabled = false;
    btnShip.disabled = true;
    return;
  }

  if (!running) {
    btnStart.textContent = "Start factory";
    btnStart.disabled = false;
    btnStart.classList.add("primary");
    btnPause.disabled = true;
    btnResume.disabled = true;
    btnStop.disabled = true;
    btnShip.disabled = false;
    return;
  }

  if (paused) {
    btnStart.textContent = "Paused";
    btnStart.disabled = true;
    btnPause.disabled = true;
    btnResume.disabled = false;
    btnResume.classList.add("primary");
    btnStop.disabled = false;
    btnShip.disabled = false;
    return;
  }

  // Live shift
  btnStart.textContent = runnerAlive ? "Running" : "Starting…";
  btnStart.disabled = true;
  btnPause.disabled = false;
  btnPause.classList.add("primary");
  btnResume.disabled = true;
  btnStop.disabled = false;
  btnShip.disabled = false;
}

async function openDrawer(item) {
  selected = item;
  const drawer = document.getElementById("drawer");
  const body = document.getElementById("drawerBody");
  drawer.classList.add("open");
  document.getElementById("drawerTitle").textContent = `${item.type} ${item.id} — ${item.title}`;
  body.innerHTML = `<div class="loading">Loading ticket…</div>`;
  if (!item.path) {
    body.innerHTML = `<div class="error">No ticket path on this card.</div>`;
    return;
  }
  try {
    const r = await fetch("/api/ticket?path=" + encodeURIComponent(item.path));
    if (!r.ok) {
      body.innerHTML = `<div class="error">Could not load ticket (${r.status}).</div>`;
      return;
    }
    const t = await r.json();
    document.getElementById("drawerTitle").textContent = `${t.type} ${t.id} — ${t.title}`;
    body.innerHTML = renderTicket(t);
  } catch (e) {
    body.innerHTML = `<div class="error">Failed to load ticket.</div>`;
  }
}

async function post(path, body) {
  await fetch(path, { method:"POST", headers:{"Content-Type":"application/json"}, body: JSON.stringify(body||{}) });
  await refresh();
}

async function refresh() {
  const r = await fetch("/api/board");
  snap = await r.json();
  render();
}

document.getElementById("btnClose").onclick = () => document.getElementById("drawer").classList.remove("open");
document.getElementById("btnStart").onclick = () => post("/api/control", {action:"start"});
document.getElementById("btnStop").onclick = () => post("/api/control", {action:"stop"});
document.getElementById("btnPause").onclick = () => post("/api/control", {action:"pause"});
document.getElementById("btnResume").onclick = () => post("/api/control", {action:"resume"});
document.getElementById("btnShip").onclick = () => post("/api/control", {action:"ship_now"});
document.getElementById("btnHold").onclick = () => {
  if (confirm("Don't push — leave commits local and idle until new work or Ship now?")) {
    post("/api/control", {action:"batch_hold"});
  }
};
document.getElementById("btnRetry").onclick = () => {
  if (confirm("Retry full suite? Reruns tier-3 + one auto-fix pass (~10–15 min).")) {
    post("/api/control", {action:"batch_retry"});
  }
};
document.getElementById("btnCopy").onclick = async () => {
  const fail = (snap && snap.batch && snap.batch.failure) || {};
  const fails = fail.failures || [];
  const lines = [
    "Forge batch can't ship",
    `HEAD: ${fail.head_sha || (snap.batch && snap.batch.head_sha) || "?"}`,
    `Reason: ${fail.reason || "still_red"}`,
    `Passed: ${fail.passed ?? "?"}  Failed: ${fail.failed ?? fails.length}`,
    fail.ladder ? fail.ladder : "",
    "",
    "Failures:",
    ...(fails.length ? fails.map(f => `- ${(f && f.id) || "?"} — ${(f && f.assertion) || ""}`) : ["- (none listed)"]),
    "",
    fail.bundle ? `Bundle: ${fail.bundle}` : "",
    fail.output ? `Output: ${fail.output}` : "Output: build/test-results/verify-output-latest.txt",
  ].filter(Boolean).join("\n");
  try {
    await navigator.clipboard.writeText(lines);
    alert("Copied failure details for Cursor.");
  } catch (_) {
    prompt("Copy this for Cursor:", lines);
  }
};
document.getElementById("btnRequeue").onclick = () => {
  const halted = (snap.tasks||[]).find(t => /Halted/i.test(t.status||""));
  if (!halted) return alert("No Halted task");
  const id = parseInt(String(halted.id).replace(/\D/g,""), 10);
  post("/api/control", {action:"requeue", task_id: id});
};

const es = new EventSource("/api/events");
es.onmessage = (e) => { try { snap = JSON.parse(e.data); render(); } catch(_){} };
refresh();
setInterval(refresh, 5000);
</script>
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args: Any) -> None:
        sys.stderr.write("[forge-floor] " + (fmt % args) + "\n")

    def _json(self, code: int, obj: Any) -> None:
        raw = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _html(self, html: str) -> None:
        raw = html.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        path = parsed.path
        if path in ("/", "/index.html"):
            self._html(INDEX_HTML)
            return
        if path == "/api/board":
            self._json(200, board_snapshot())
            return
        if path == "/api/ticket":
            qs = parse_qs(parsed.query)
            rel = (qs.get("path") or [""])[0]
            detail = ticket_detail(rel)
            if detail is None:
                self._json(404, {"error": "ticket not found", "path": rel})
                return
            self._json(200, detail)
            return
        if path == "/api/events":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "keep-alive")
            self.end_headers()
            try:
                while True:
                    payload = json.dumps(board_snapshot())
                    self.wfile.write(f"data: {payload}\n\n".encode("utf-8"))
                    self.wfile.flush()
                    time.sleep(2)
            except (BrokenPipeError, ConnectionResetError):
                return
        self.send_error(404)

    def do_POST(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        length = int(self.headers.get("Content-Length", "0") or 0)
        body = self.rfile.read(length) if length else b"{}"
        try:
            data = json.loads(body.decode("utf-8") or "{}")
        except json.JSONDecodeError:
            data = {}
        if path != "/api/control":
            self.send_error(404)
            return
        action = data.get("action")
        ctrl = read_controls()
        msg = "ok"
        if action == "start":
            msg = start_runner()
        elif action == "stop":
            msg = stop_runner()
        elif action == "pause":
            ctrl["paused"] = True
            write_controls(ctrl)
        elif action == "resume":
            ctrl["paused"] = False
            write_controls(ctrl)
        elif action == "ship_now":
            ctrl["ship_now"] = True
            write_controls(ctrl)
        elif action == "requeue":
            msg = requeue_task(data.get("task_id"))
            ctrl["requeue_task_id"] = None
            write_controls(ctrl)
        elif action == "cancel":
            ctrl["cancel_task_id"] = data.get("task_id")
            write_controls(ctrl)
        elif action == "mark_done":
            ctrl["mark_done_task_id"] = data.get("task_id")
            write_controls(ctrl)
        elif action == "batch_hold":
            incident = _read_batch_failure()
            if incident:
                incident["status"] = "acknowledged"
                _write_batch_failure(incident)
                msg = "held — not pushing"
            else:
                msg = "no open incident to hold"
            write_controls(ctrl)
        elif action == "batch_retry":
            incident = _read_batch_failure()
            if incident:
                incident["status"] = "open"
                _write_batch_failure(incident)
            ctrl["ship_now"] = True
            ctrl["paused"] = False
            write_controls(ctrl)
            if not _runner_alive():
                msg = start_runner()
            else:
                msg = "retry queued (ship_now)"
        elif action == "bump":
            bumps = ctrl.get("priority_bumps") or {}
            bumps[str(data.get("task_id"))] = data.get("priority", "P0")
            ctrl["priority_bumps"] = bumps
            write_controls(ctrl)
        else:
            self._json(400, {"error": f"unknown action {action}"})
            return
        self._json(200, {"ok": True, "message": msg, "controls": read_controls()})


def main() -> int:
    try:
        server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    except OSError as exc:
        print(f"forge-floor: port {PORT} busy — {exc}", file=sys.stderr)
        return 1
    print(f"Forge Floor → http://127.0.0.1:{PORT}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nbye", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
