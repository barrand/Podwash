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
HEARTBEAT = REPO_ROOT / "build" / "factory" / "heartbeat.json"
EVENTS_DIR = REPO_ROOT / "build" / "test-results"

STARTING_GRACE_S = 30.0
ORPHAN_RESTART_COOLDOWN_S = 45.0
STALE_ACTIVITY_S = 180.0  # 3 min — UI warns while claiming work

_runner_proc: subprocess.Popen | None = None
_runner_lock = threading.Lock()
_runner_log_f: Any = None
_last_orphan_restart_ts = 0.0


def _default_controls() -> dict[str, Any]:
    return {
        "running": False,
        "paused": False,
        "pause_after_current": False,
        "ship_now": False,
        "skip_batch_gate": False,
        "cancel_task_id": None,
        "requeue_task_id": None,
        "priority_bumps": {},
        "batch_running": False,
        "mark_done_task_id": None,
        "runner_pid": None,
        "started_at": None,
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


def _meta_done_at(meta: dict[str, str]) -> str | None:
    raw = (meta.get("Done at") or "").strip()
    return raw or None


def _sort_done_column(items: list[dict[str, Any]]) -> list[dict[str, Any]]:
    dated = [i for i in items if i.get("done_at")]
    undated = [i for i in items if not i.get("done_at")]
    undated.sort(key=lambda i: int(str(i.get("id", "0"))))
    dated.sort(key=lambda i: int(str(i.get("id", "0"))))
    dated.sort(key=lambda i: str(i["done_at"]), reverse=True)
    return dated + undated


def _format_done_closed_meta(done_at: str | None) -> str:
    if not done_at:
        return ""
    from datetime import datetime, timezone

    try:
        s = done_at.strip()
        if s.endswith("Z"):
            dt = datetime.fromisoformat(s[:-1]).replace(tzinfo=timezone.utc)
        else:
            dt = datetime.fromisoformat(s)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        stamp = dt.astimezone(timezone.utc).strftime("%Y-%m-%d %H:%M")
        return f"Closed {stamp} UTC"
    except ValueError:
        return ""


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

    done_at = _meta_done_at(meta)

    return {
        "type": item_type,
        "path": str(path.relative_to(REPO_ROOT)),
        "id": meta.get("ID", path.stem),
        "title": meta.get("Title", path.stem),
        "status": meta.get("Status", ""),
        "kind": meta.get("Kind", item_type),
        "priority": meta.get("Priority", ""),
        "area": meta.get("Area", ""),
        "done_at": done_at,
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


def _pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def _file_age_s(path: Path) -> float | None:
    if not path.is_file():
        return None
    try:
        return max(0.0, time.time() - path.stat().st_mtime)
    except OSError:
        return None


def _parse_event_ts(raw: Any) -> float | None:
    """Parse event timestamp (unix float or ISO-ish string) to epoch seconds."""
    if raw is None:
        return None
    if isinstance(raw, (int, float)):
        return float(raw)
    s = str(raw).strip()
    if not s:
        return None
    try:
        return float(s)
    except ValueError:
        pass
    # ISO: 2026-07-13T18:31:47Z or without Z
    try:
        from datetime import datetime

        if s.endswith("Z"):
            s = s[:-1] + "+00:00"
        return datetime.fromisoformat(s).timestamp()
    except ValueError:
        return None


def _last_event_age_s(events: list[dict[str, Any]]) -> float | None:
    newest: float | None = None
    for ev in events:
        ts = _parse_event_ts(ev.get("ts"))
        if ts is None:
            continue
        if newest is None or ts > newest:
            newest = ts
    if newest is None:
        return None
    return max(0.0, time.time() - newest)


def _runner_alive(*, ctrl: dict[str, Any] | None = None) -> bool:
    """True when a task-loop / task-loop.sh process is actually live.

    Order: in-process Popen → controls runner_pid → heartbeat pid → ps scan.
    A fresh heartbeat *timestamp* alone is not enough — that left Floor looking
    "running" for minutes after the worker died (orphan delay).
    """
    global _runner_proc
    with _runner_lock:
        if _runner_proc is not None and _runner_proc.poll() is None:
            return True
    c = ctrl if ctrl is not None else read_controls()
    try:
        ctrl_pid = int(c.get("runner_pid") or 0)
    except (TypeError, ValueError):
        ctrl_pid = 0
    if ctrl_pid and _pid_alive(ctrl_pid):
        return True
    hb = _read_json_file(HEARTBEAT)
    try:
        hb_pid = int(hb.get("pid") or 0)
    except (TypeError, ValueError):
        hb_pid = 0
    if hb_pid and _pid_alive(hb_pid):
        return True
    root = str(REPO_ROOT)
    for line in _ps_commands():
        if "task_loop.py" in line or "task-loop.sh" in line:
            if root in line or "PodWash" in line or "task_loop" in line:
                return True
    return False


def maybe_restart_orphan_runner(*, ctrl: dict[str, Any], activity_mode: str) -> str | None:
    """If Floor claims running but the worker is dead, start it again (cooldown)."""
    global _last_orphan_restart_ts
    if activity_mode != "orphan":
        return None
    if not (ctrl.get("running") or HOT.is_file()):
        return None
    now = time.time()
    if now - _last_orphan_restart_ts < ORPHAN_RESTART_COOLDOWN_S:
        return None
    _last_orphan_restart_ts = now
    msg = start_runner()
    sys.stderr.write(f"[forge-floor] auto-restart orphan runner: {msg}\n")
    return msg


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
        elif tag == "scope_miss":
            labels.append("skipped Mechanic (failure outside punch-list test filters)")
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
    """Human-readable full-suite / push copy — no factory jargon."""
    r = (reason or "").strip()
    mapping = {
        "never verified": (
            "All tests have never been run green on this tree. "
            "When the punch-list is clear, the factory runs every test, then pushes if green."
        ),
        "HEAD moved": (
            "New commits landed since the last time all tests passed. "
            "A full test-suite run is waiting, then push if green."
        ),
        "dirty tree": "There are uncommitted changes — a full test-suite run is needed before push.",
        "ship_now": "You clicked Verify & push — full test suite runs next.",
        "not needed": "All tests already passed at this commit — nothing left to verify before push.",
        "skipped": "Full-suite check skipped for this session.",
        "unavailable": "Full-suite status unavailable (internal import failed).",
        "still_red": "Full test suite is still failing after an auto-fix pass — decide in Your move.",
        "needs_decision": (
            "Full suite needs a decision in Your move — idle drain will not re-run until "
            "you Retry, Don't push, or Verify & push."
        ),
        "scope_miss": (
            "Full suite failed on a test no recent punch-list ticket ran — "
            "likely an old test conflicting with new behavior. Decide in Your move "
            "(auto-fix skipped)."
        ),
        "verified": "Last full test suite passed.",
        "mechanic_retry": "Re-running the full test suite after an auto-fix pass.",
        "held": (
            "You chose not to push. Click Verify & push or Retry full suite when ready."
        ),
        "verify aborted": "Full test suite aborted (simulator/infra) — decide in Your move.",
    }
    if state == "verifying" or state == "running":
        return f"Running the full test suite now ({r or 'all tests'})."
    if state == "needs_decision":
        return mapping.get(r, f"Can't push ({r or 'failed'}). Decide in Your move.")
    if state == "held":
        return mapping["held"]
    if state == "green" and not r:
        return mapping["verified"]
    return mapping.get(r, f"Full suite: {r or state or 'idle'}.")


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


def _activity_ages(
    events: list[dict[str, Any]],
) -> dict[str, float | None]:
    station_age_s = _file_age_s(STATION)
    hb = _read_json_file(HEARTBEAT)
    hb_age_s: float | None = None
    try:
        hb_ts = float(hb.get("ts") or 0)
        if hb_ts:
            hb_age_s = max(0.0, time.time() - hb_ts)
    except (TypeError, ValueError):
        hb_age_s = None
    last_event_age_s = _last_event_age_s(events)
    ages = [a for a in (station_age_s, hb_age_s, last_event_age_s) if a is not None]
    activity_age_s = min(ages) if ages else None
    return {
        "station_age_s": station_age_s,
        "heartbeat_age_s": hb_age_s,
        "last_event_age_s": last_event_age_s,
        "activity_age_s": activity_age_s,
    }


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
    pause_armed = bool(ctrl.get("pause_after_current")) and not paused
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
    ages = _activity_ages(events)
    verify_running = bool(batch.get("verify_running"))
    batch_flag = bool(ctrl.get("batch_running")) or bool(batch.get("batch_running"))
    started_at = ctrl.get("started_at")
    try:
        started_age_s = (
            max(0.0, time.time() - float(started_at)) if started_at is not None else None
        )
    except (TypeError, ValueError):
        started_age_s = None

    def pack(
        *,
        mode: str,
        headline: str,
        detail: str,
        next_line: str,
        orphan: bool = False,
        agents_out: list[dict[str, str]] | None = None,
        loop_stale: bool = False,
    ) -> dict[str, Any]:
        detail_out = detail
        if pause_armed:
            hint = "Will pause after current"
            detail_out = f"{hint} — {detail}" if detail else hint
        return {
            "mode": mode,
            "headline": headline,
            "detail": detail_out,
            "agents": agents_out if agents_out is not None else agents,
            "next": next_line,
            "batch_plain": batch_plain,
            "orphan": orphan,
            "runner_alive": runner_alive,
            "loop_stale": loop_stale,
            "started_at": started_at,
            "started_age_s": started_age_s,
            **ages,
        }

    # Claimed running but no live loop — starting / orphan / mid-verify warning
    if marked_running and not runner_alive:
        if batch_flag and verify_running:
            return pack(
                mode="batch",
                headline="Full test suite still running",
                detail=(
                    "The factory loop process exited, but xcodebuild is still finishing. "
                    "Wait for it, or Stop then Restart factory."
                ),
                next_line="Wait for the full suite to finish, or Stop then Restart factory.",
                agents_out=agents
                or [
                    {
                        "role": "verify",
                        "task": "",
                        "phase": "FULL-VERIFY",
                        "doing": "full suite still running",
                    }
                ],
                loop_stale=True,
            )
        if batch_flag and not verify_running:
            stuck = (
                ", ".join(_fmt_task_id(t.get("id")) or str(t.get("id")) for t in in_prog)
                or "none"
            )
            return pack(
                mode="orphan",
                headline="Factory loop not running",
                detail=(
                    f"A full-suite flag was left on, but nothing is alive. "
                    f"In Progress stuck: {stuck}."
                ),
                next_line="Click Restart factory. Or Pause if you meant to reclaim the tree for hand-edits.",
                orphan=True,
            )
        if started_age_s is not None and started_age_s < STARTING_GRACE_S:
            return pack(
                mode="starting",
                headline="Starting factory…",
                detail=f"Waiting for the worker process ({int(started_age_s)}s).",
                next_line="Wait a few seconds. If this hangs, click Restart factory.",
            )
        stuck = (
            ", ".join(_fmt_task_id(t.get("id")) or str(t.get("id")) for t in in_prog)
            or "none"
        )
        return pack(
            mode="orphan",
            headline="Factory loop not running",
            detail=(
                f"Status says running, but no worker process is alive. "
                f"In Progress stuck: {stuck}."
            ),
            next_line="Click Restart factory. Or Pause if you meant to reclaim the tree for hand-edits.",
            orphan=True,
        )

    if paused:
        return pack(
            mode="paused",
            headline="Paused",
            detail="Workers are idle until you Resume.",
            next_line="Click Resume to continue, or Stop to shut the factory down.",
        )

    if not marked_running and not runner_alive:
        if halted:
            return pack(
                mode="stopped",
                headline="Factory stopped",
                detail=f"Halted: {', '.join(str(t.get('id')) for t in halted)}.",
                next_line=(
                    "Amend the ticket in Cursor if needed, Start factory, then Requeue Halted."
                ),
                agents_out=[],
            )
        if needs_human:
            return pack(
                mode="stopped",
                headline="Factory stopped",
                detail="Needs-human tickets are waiting.",
                next_line="Handle Needs-human in Cursor, then Start factory.",
                agents_out=[],
            )
        if queued or in_prog:
            return pack(
                mode="stopped",
                headline="Factory stopped",
                detail=f"{len(queued)} punch-list ticket(s) queued, {len(in_prog)} in progress — no workers.",
                next_line="Click Start factory.",
                agents_out=[],
            )
        return pack(
            mode="idle",
            headline="Factory idle",
            detail="No workers running.",
            next_line="Queue punch-list work with forge-intake in Cursor, then Start factory.",
            agents_out=[],
        )

    # Live / claimed running — verifying always beats needs_decision
    batch_state = str(batch.get("state") or "")
    if batch_state in ("verifying", "running") or (
        batch_flag and (runner_alive or verify_running)
    ):
        return pack(
            mode="batch",
            headline="Running full test suite",
            detail=detail or batch_plain or "Running every test, then push if green.",
            next_line="Wait — no action needed unless the suite fails.",
            agents_out=agents
            or [
                {
                    "role": "loop",
                    "task": "",
                    "phase": "FULL-VERIFY",
                    "doing": "running full test suite",
                }
            ],
        )

    if batch_state == "needs_decision":
        fail_n = (
            batch.get("failure", {}).get("failed")
            if isinstance(batch.get("failure"), dict)
            else None
        )
        detail_line = "Can't push — full test suite still failing."
        if fail_n is not None:
            detail_line = f"Can't push — {fail_n} test(s) failed."
        elif (batch.get("reason") or "") == "verify aborted":
            detail_line = "Can't push — verify aborted."
        return pack(
            mode="needs_decision",
            headline="Can't push",
            detail=detail_line,
            next_line="Your move: Don't push, Retry full suite, or Copy for Cursor.",
        )

    if batch_state == "held":
        return pack(
            mode="held",
            headline="Not pushing (held)",
            detail=f"You acknowledged the failure at {(batch.get('head_sha') or '')[:12] or 'HEAD'}.",
            next_line="Verify & push or Retry full suite when ready; or queue more punch-list work.",
        )

    if agents:
        who = agents[0]
        label = f"{who['phase']} · {who['role']}"
        if who.get("task"):
            label += f" · {who['task']}"
        nxt = "Nothing needed from you — agents are working. Watch the active card and event feed."
        if phase.lower() in ("halted",):
            nxt = "Amend ticket in Cursor if needed, then Requeue Halted."
        if phase.lower() in ("waiting",):
            # Dependency / Halted park — do not pretend this is a full-suite wait.
            return pack(
                mode="picking",
                headline="Waiting on another ticket",
                detail=who.get("doing") or mission or detail or "A Queued ticket is blocked.",
                next_line=(
                    "Nothing needed from you if the blocker is Queued — it should start next. "
                    "If this stalls, check Depends on in the ticket (prose like “orthogonal to "
                    "task-NNN” is not a real dependency)."
                ),
                agents_out=agents,
            )
        if phase.lower() in ("idle",):
            return pack(
                mode="batch_pending" if batch.get("needed") or halted else "quiet",
                headline=(
                    "Full suite waiting — Halted ticket first"
                    if halted
                    else (
                        "Waiting to run full test suite"
                        if batch.get("needed")
                        else "Waiting for punch-list work"
                    )
                ),
                detail=who.get("doing") or mission or detail or batch_plain,
                next_line=(
                    "Requeue Halted in Your move, or queue more punch-list work with forge-intake."
                    if halted
                    else (
                        "Nothing needed from you — or click Verify & push to start the full suite now."
                        if batch.get("needed")
                        else "Queue punch-list work with forge-intake, or click Verify & push."
                    )
                ),
                agents_out=agents,
            )
        return pack(
            mode="working",
            headline=label,
            detail=who.get("doing") or mission or detail,
            next_line=nxt,
        )

    if in_prog:
        t0 = in_prog[0]
        hint = ""
        if ev_role or ev_event:
            hint = f" Last event: {ev_phase} {ev_role} {ev_event}".strip()
        return pack(
            mode="working",
            headline=f"Working on {_fmt_task_id(t0.get('id')) or t0.get('id')}",
            detail=(t0.get("title") or "") + ("." if hint else "") + hint,
            next_line="Wait — a ticket is claimed. If this stalls for minutes, Stop then Start factory.",
            agents_out=[
                {
                    "role": ev_role or "pipeline",
                    "task": _fmt_task_id(t0.get("id")),
                    "phase": ev_phase or "task",
                    "doing": (t0.get("title") or "working")[:80],
                }
            ],
        )

    if queued and runner_alive:
        return pack(
            mode="picking",
            headline="Picking next punch-list ticket",
            detail=f"{len(queued)} punch-list ticket(s) ready.",
            next_line="Nothing needed from you — the next card will move to In Progress shortly.",
            agents_out=[
                {
                    "role": "loop",
                    "task": "",
                    "phase": "queue",
                    "doing": "selecting next punch-list ticket",
                }
            ],
        )

    # No punch-list work — full suite pending (or blocked by Halted)
    if batch.get("needed") and runner_alive:
        if halted:
            ids = ", ".join(
                _fmt_task_id(t.get("id")) or str(t.get("id")) for t in halted
            )
            return pack(
                mode="batch_pending",
                headline="Full suite waiting — Halted ticket first",
                detail=(
                    f"{ids} is Halted. Requeue it (or leave it parked) before the factory "
                    f"will run all tests and push. {batch_plain}"
                ),
                next_line="Requeue Halted in Your move, or queue more punch-list work with forge-intake.",
                agents_out=[
                    {
                        "role": "loop",
                        "task": "",
                        "phase": "batch",
                        "doing": "blocked on Halted ticket",
                    }
                ],
            )
        return pack(
            mode="batch_pending",
            headline="Waiting to run full test suite",
            detail=batch_plain,
            next_line=(
                "Nothing needed from you — all tests run next, then push if green. "
                "Or click Verify & push to start now."
            ),
            agents_out=[
                {
                    "role": "loop",
                    "task": "",
                    "phase": "batch",
                    "doing": "waiting to run full test suite",
                }
            ],
        )

    return pack(
        mode="quiet",
        headline="Nothing to do right now",
        detail="No punch-list tickets ready, and no full-suite run needed.",
        next_line=(
            "Queue punch-list work with forge-intake, or click Verify & push "
            "if you only want all tests + push."
        ),
        agents_out=[],
    )


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
    verify_live = _verify_running()
    runner = _runner_alive(ctrl=ctrl)
    # Only treat live verify as batch when the loop marked batch_running / ship_now —
    # otherwise surgical tier-2 would look like batch. Ignore a stale batch_running
    # flag when neither the loop nor verify children are alive.
    flag = bool(ctrl.get("batch_running"))
    if flag:
        batch_running = runner or verify_live
    elif bool(ctrl.get("ship_now")) and verify_live:
        batch_running = True
    else:
        batch_running = False
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
        "verify_running": verify_live,
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
                    "done_at": _meta_done_at(meta),
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
                    "done_at": _meta_done_at(meta),
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
    runner_alive = _runner_alive(ctrl=ctrl)
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
        if ctrl.get("batch_running") and (
            runner_alive or bool(batch.get("verify_running"))
        ):
            merged["state"] = "verifying"
        else:
            merged["state"] = derived_state
        merged["plain"] = _batch_plain(
            str(merged.get("reason") or ""), str(merged.get("state") or "")
        )
        batch = merged
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
    restarted = maybe_restart_orphan_runner(
        ctrl=ctrl, activity_mode=str(activity.get("mode") or "")
    )
    if restarted:
        ctrl = read_controls()
        runner_alive = _runner_alive(ctrl=ctrl)
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
        activity = dict(activity)
        activity["detail"] = (
            f"Auto-restarted dead worker ({restarted}). "
            + (activity.get("detail") or "")
        ).strip()
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


def apply_control(action: str, data: dict[str, Any] | None = None) -> dict[str, Any]:
    """Apply a Floor control action; return {ok, message?, controls?, error?}."""
    data = data or {}
    ctrl = read_controls()
    msg = "ok"
    if action == "start":
        msg = start_runner()
    elif action == "stop":
        msg = stop_runner()
    elif action == "pause":
        ctrl["paused"] = True
        ctrl["pause_after_current"] = False
        write_controls(ctrl)
        from task_loop import interrupt_inflight_on_pause

        interrupt_inflight_on_pause()
    elif action == "pause_after_current":
        ctrl["pause_after_current"] = True
        write_controls(ctrl)
    elif action == "resume":
        ctrl["paused"] = False
        ctrl["pause_after_current"] = False
        write_controls(ctrl)
        if not _runner_alive(ctrl=ctrl):
            msg = start_runner()
        else:
            msg = "resumed"
    elif action == "ship_now":
        ctrl["ship_now"] = True
        ctrl["paused"] = False
        write_controls(ctrl)
        if not _runner_alive(ctrl=ctrl):
            msg = start_runner()
        else:
            msg = "verify & push queued"
    elif action == "requeue":
        msg = requeue_task(data.get("task_id"))
        ctrl["requeue_task_id"] = None
        write_controls(ctrl)
        # Wake a dead runner so Requeue actually gets picked up.
        if not _runner_alive(ctrl=read_controls()):
            start_runner()
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
        return {"ok": False, "error": f"unknown action {action}"}
    return {"ok": True, "message": msg, "controls": read_controls()}


def start_runner() -> str:
    global _runner_proc, _runner_log_f
    with _runner_lock:
        if _runner_proc is not None and _runner_proc.poll() is None:
            return "already running"
        env = os.environ.copy()
        env["PODWASH_FORGE_LOOP"] = "task_loop"
        log_path = REPO_ROOT / "build" / "factory" / "task-loop.log"
        log_path.parent.mkdir(parents=True, exist_ok=True)
        if _runner_log_f is not None:
            try:
                _runner_log_f.close()
            except OSError:
                pass
            _runner_log_f = None
        _runner_log_f = open(log_path, "a", encoding="utf-8")  # noqa: SIM115
        _runner_log_f.write(
            f"\n--- start_runner {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} ---\n"
        )
        _runner_log_f.flush()
        _runner_proc = subprocess.Popen(
            [str(SCRIPTS / "task-loop.sh"), "--medic-no-push"],
            cwd=str(REPO_ROOT),
            env=env,
            stdout=_runner_log_f,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        ctrl = read_controls()
        ctrl["running"] = True
        ctrl["paused"] = False
        ctrl["runner_pid"] = _runner_proc.pid
        ctrl["started_at"] = time.time()
        write_controls(ctrl)
        return f"started pid={_runner_proc.pid}"


def stop_runner() -> str:
    global _runner_proc
    from task_loop import interrupt_inflight_on_pause

    interrupt_inflight_on_pause()
    ctrl = read_controls()
    ctrl["running"] = False
    ctrl["paused"] = True
    ctrl["runner_pid"] = None
    ctrl["started_at"] = None
    ctrl["batch_running"] = False
    write_controls(ctrl)
    with _runner_lock:
        if _runner_proc is not None and _runner_proc.poll() is None:
            try:
                os.killpg(os.getpgid(_runner_proc.pid), 15)  # SIGTERM group
            except (ProcessLookupError, PermissionError, OSError):
                _runner_proc.terminate()
            try:
                _runner_proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(os.getpgid(_runner_proc.pid), 9)  # SIGKILL group
                except (ProcessLookupError, PermissionError, OSError):
                    _runner_proc.kill()
        _runner_proc = None
    return "stopped"


def reconcile_runner_on_boot() -> None:
    """After Floor relaunch: if controls say running but worker is dead, start it."""
    ctrl = read_controls()
    if not ctrl.get("running"):
        return
    if _runner_alive(ctrl=ctrl):
        return
    msg = start_runner()
    sys.stderr.write(f"[forge-floor] boot reconcile: {msg}\n")


def _shutdown_owned_runner() -> None:
    """Kill Floor-owned children on exit; leave running=True so boot can resume."""
    global _runner_proc
    with _runner_lock:
        proc = _runner_proc
        _runner_proc = None
    if proc is None or proc.poll() is not None:
        return
    try:
        os.killpg(os.getpgid(proc.pid), 15)
    except (ProcessLookupError, PermissionError, OSError):
        try:
            proc.terminate()
        except OSError:
            pass
    try:
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(proc.pid), 9)
        except (ProcessLookupError, PermissionError, OSError):
            try:
                proc.kill()
            except OSError:
                pass


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
.station, .feed, .your-move {
  background: var(--panel); border: 1px solid var(--line); border-radius: 10px; padding: 0.75rem;
}
.station h3, .feed h3, .your-move h3 { margin: 0 0 0.5rem; font-size: 0.9rem; }
.station .label {
  font-size: 0.68rem; text-transform: uppercase; letter-spacing: 0.06em;
  color: var(--muted); margin: 0.55rem 0 0.2rem;
}
.station .label:first-of-type { margin-top: 0; }
.station .beat { color: var(--ink); font-size: 0.95rem; font-weight: 600; }
.station .sub { color: var(--muted); font-size: 0.8rem; margin-top: 0.35rem; line-height: 1.35; }
.station .fresh {
  margin-top: 0.4rem; font-size: 0.75rem; color: var(--muted); line-height: 1.3;
}
.station .fresh.warn { color: var(--warn); }
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
.station.blocked, .station.orphan, .station.needs_decision, .station.starting { border-color: var(--warn); }
.card.active {
  border-color: var(--ok);
  box-shadow: 0 0 0 1px var(--ok);
}
.card.stalled {
  border-color: var(--warn);
  box-shadow: 0 0 0 1px var(--warn);
}
.card .phase { font-size: 0.72rem; color: var(--muted); margin-top: 0.25rem; }
.card .phase.warn { color: var(--warn); }
.card .card-actions {
  display: flex; gap: 0.35rem; margin-top: 0.45rem; flex-wrap: wrap;
}
.card .card-actions button {
  font-size: 0.72rem; padding: 0.2rem 0.45rem;
}
.your-move.on { border-color: var(--warn); box-shadow: 0 0 0 1px var(--warn); }
.your-move.muted-panel { opacity: 0.85; }
.your-move .fail-list { margin: 0.5rem 0; padding-left: 1.1rem; font-size: 0.8rem; }
.your-move .fail-list li { margin: 0.25rem 0; }
.your-move .consequence { color: var(--muted); font-size: 0.75rem; margin: 0.15rem 0 0.55rem; }
.your-move .ladder { color: var(--muted); font-size: 0.78rem; margin: 0.4rem 0; line-height: 1.35; }
.your-move .also-strip {
  margin-top: 0.75rem; padding-top: 0.5rem; border-top: 1px solid var(--line);
  font-size: 0.8rem;
}
.your-move .also-strip .also-row {
  display: flex; align-items: center; justify-content: space-between; gap: 0.5rem;
  margin: 0.35rem 0;
}
.your-move .evidence { color: var(--muted); font-size: 0.72rem; word-break: break-all; margin-top: 0.35rem; }
.your-move .repeat-warn { color: var(--warn); font-size: 0.78rem; margin: 0.4rem 0; }
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
    <button id="btnPauseAfter">Pause after current</button>
    <button id="btnResume">Resume</button>
    <button id="btnShip" title="Run all tests, then git push if green">Verify &amp; push</button>
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
      <div class="label">Status</div>
      <div class="beat" id="stationBeat">Nothing to do right now</div>
      <div class="sub" id="stationSub"></div>
      <div class="fresh" id="stationFresh"></div>
      <div class="agents" id="agentList"></div>
      <div class="label">Full test suite (before push)</div>
      <div class="batch-line" id="batchLine">—</div>
    </div>
    <div class="your-move" id="yourMove">
      <h3 id="yourMoveTitle">Your move</h3>
      <div id="yourMoveBody">Nothing needed from you.</div>
      <div class="toolbar" id="yourMoveActions" style="margin-top:0.5rem; display:none; flex-wrap:wrap; gap:0.35rem">
        <button class="danger" id="btnHold">Don't push</button>
        <button id="btnRetry">Retry full suite</button>
        <button id="btnCopy">Copy for Cursor</button>
        <button id="btnRequeue">Requeue Halted</button>
      </div>
      <div class="consequence" id="yourMoveHint" hidden></div>
      <div class="also-strip" id="alsoStrip" hidden></div>
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

function formatDoneClosedMeta(iso) {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  const y = d.getFullYear();
  const mo = String(d.getMonth() + 1).padStart(2, "0");
  const da = String(d.getDate()).padStart(2, "0");
  const hr = String(d.getHours()).padStart(2, "0");
  const mi = String(d.getMinutes()).padStart(2, "0");
  return `Closed ${y}-${mo}-${da} ${hr}:${mi}`;
}

function sortDoneColumn(items) {
  const dated = items.filter(i => i.done_at).slice();
  const undated = items.filter(i => !i.done_at).slice();
  undated.sort((a, b) => parseInt(a.id, 10) - parseInt(b.id, 10));
  dated.sort((a, b) => {
    const byDate = String(b.done_at).localeCompare(String(a.done_at));
    if (byDate !== 0) return byDate;
    return parseInt(a.id, 10) - parseInt(b.id, 10);
  });
  return dated.concat(undated);
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
      ${t.done_at ? `<span class="chip">${esc(formatDoneClosedMeta(t.done_at))}</span>` : ""}
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
    const stateLabels = {
      verifying: "running",
      running: "running",
      pending: "waiting",
      needs_decision: "can't push",
      held: "not pushing",
      green: "passed",
      idle: "idle",
      blocked: "can't push",
    };
    const st = (b && b.state) || "—";
    const stLabel = stateLabels[st] || st;
    const head = `Full suite · ${stLabel}${sha ? " @ " + sha : ""}`;
    return `<strong>${esc(head)}</strong><br/>${esc(activity.batch_plain)}`;
  }
  if (!b) return "Full suite · —";
  const short = (s) => (s ? String(s).slice(0, 12) : "?");
  if (b.state === "running" || b.state === "verifying" || b.batch_running) {
    return `<strong>Full suite · running</strong><br/>${esc(b.plain || "all tests")}`;
  }
  if (b.state === "needs_decision") {
    return `<strong>Full suite · can't push</strong><br/>${esc(b.plain || "decide in Your move")}`;
  }
  if (b.state === "held") {
    return `<strong>Full suite · not pushing</strong><br/>${esc(b.plain || "held")}`;
  }
  if (b.state === "blocked") {
    return `<strong>Full suite · can't push</strong><br/>${esc(b.plain || "decide in Your move")}`;
  }
  if (b.state === "pending" || b.needed) {
    return `<strong>Full suite · waiting</strong><br/>${esc(b.plain || "needed before push")}`;
  }
  if (b.state === "green" || b.last_green_sha) {
    return `<strong>Full suite · passed @ ${esc(short(b.last_green_sha))}</strong><br/>${esc(b.plain || "ok")}`;
  }
  return `<strong>Full suite · idle</strong>`;
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

function formatAge(sec) {
  if (sec == null || !Number.isFinite(sec)) return null;
  const s = Math.max(0, Math.floor(sec));
  if (s < 60) return s + "s ago";
  if (s < 3600) return Math.floor(s / 60) + "m ago";
  return Math.floor(s / 3600) + "h ago";
}

function makeCard(item, st, activeTid, activity) {
  const card = document.createElement("div");
  const isActive = item.type==="task" && activeTid && String(item.id).padStart(3,"0")===activeTid;
  const mode = (activity && activity.mode) || "";
  const stalled = isActive && (mode === "orphan" || mode === "starting");
  card.className = "card" + (isActive ? " active" : "") + (stalled ? " stalled" : "");
  let phaseHtml = "";
  if (isActive) {
    if (stalled) {
      const label = mode === "orphan"
        ? "stalled — loop not running"
        : "waiting for loop to start";
      phaseHtml = `<div class="phase warn">${esc(label)}</div>`;
    } else if (st.phase) {
      const age = formatAge(activity && activity.activity_age_s);
      phaseHtml = `<div class="phase">${esc(st.phase)}${st.role ? " · " + esc(st.role) : ""}${st.detail ? " — " + esc(st.detail) : ""}${age ? " · last activity " + esc(age) : ""}</div>`;
    } else if (activity && activity.activity_age_s != null) {
      const age = formatAge(activity.activity_age_s);
      const stale = activity.activity_age_s > 180;
      phaseHtml = `<div class="phase${stale ? " warn" : ""}">last activity ${esc(age || "?")}</div>`;
    }
  }
  const halted = item.type === "task" && /Halted/i.test(item.status || "");
  let actionsHtml = "";
  if (halted) {
    actionsHtml = `<div class="card-actions"><button type="button" data-requeue="${esc(item.id)}">Requeue</button></div>`;
  }
  const closedMeta = (/^Done/i.test(item.status || "") && item.done_at)
    ? `<div class="meta">${esc(formatDoneClosedMeta(item.done_at))}</div>`
    : "";
  card.innerHTML = `<div><span class="prio">${esc(item.priority||"")}</span> ${esc(item.type)} ${esc(item.id)}</div>
    <div>${esc(item.title||"")}</div>
    <div class="meta">${esc(item.kind||"")} · ${esc((item.area||"").slice(0,40))}</div>${closedMeta}${phaseHtml}${actionsHtml}`;
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
  const activity = snap.activity || {};
  const mode = activity.mode || "";
  const batch = snap.batch || {};
  const st = snap.station || {};

  // Hot pill maps 1:1 from server mode — never re-derive.
  hot.style.background = "";
  hot.style.color = "";
  if (mode === "orphan") {
    hot.textContent = "orphan";
    hot.className = "status-pill";
    hot.style.background = "#40302c";
    hot.style.color = "var(--warn)";
  } else if (mode === "starting") {
    const age = activity.started_age_s != null ? Math.floor(activity.started_age_s) + "s" : "";
    hot.textContent = age ? "starting " + age : "starting";
    hot.className = "status-pill";
    hot.style.background = "#40382c";
    hot.style.color = "var(--accent)";
  } else if (mode === "paused") {
    hot.textContent = "paused";
    hot.className = "status-pill hot";
  } else if (snap.controls && snap.controls.pause_after_current && !snap.controls.paused) {
    hot.textContent = "will pause after current";
    hot.className = "status-pill hot";
  } else if (["working","batch","picking","batch_pending","needs_decision","held"].includes(mode)) {
    hot.textContent = "running";
    hot.className = "status-pill hot";
  } else {
    hot.textContent = "stopped";
    hot.className = "status-pill";
  }

  const board = document.getElementById("board");
  board.innerHTML = "";
  const items = [...(snap.tasks||[]), ...(snap.slices||[])];
  const idle = document.getElementById("idle");
  const queuedAuto = items.filter(i => colFor(i)==="Queued" && i.type==="task" && !/needs-human/i.test(i.kind||""));
  const queuedSlices = items.filter(i => colFor(i)==="Queued" && i.type==="slice");
  const inProg = items.filter(i => colFor(i)==="In Progress" && i.type==="task");
  const liveModes = ["working","batch","picking","batch_pending","starting","needs_decision","held","paused"];
  const looksLive = liveModes.includes(mode);
  const sliceNote = queuedSlices.length
    ? ` Feature slices in Queued (${queuedSlices.length}) are not auto-run by this punch-list factory.`
    : "";
  let idleMsg = "Waiting for intake — queue a punch list with forge-intake";
  if (mode === "orphan") {
    idleMsg = activity.detail || "Factory loop not running — click Restart factory";
    idle.hidden = false;
    idle.textContent = idleMsg;
  } else if (looksLive && queuedAuto.length===0 && inProg.length===0 && batch.state !== "needs_decision") {
    if (mode === "batch" || batch.state === "running" || batch.state === "verifying" || batch.batch_running) {
      idleMsg = "No punch-list tickets left · running full test suite";
    } else if (batch.state === "held" || mode === "held") {
      idleMsg = "No punch-list tickets left · not pushing (held)";
    } else if (batch.needed) {
      const why = (batch.plain || "").trim()
        || "full test suite waiting before push";
      idleMsg = `No punch-list tickets left · ${why}`;
    } else if (batch.state === "green") {
      idleMsg = `No punch-list tickets left · full suite already passed @ ${(batch.last_green_sha||"").slice(0,12)}`;
    }
    idleMsg += sliceNote;
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
    if (name === "Done") {
      colItems = sortDoneColumn(doneTasks);
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
      cards.appendChild(makeCard(item, st, activeTid, activity));
    }
    if (name === "Done" && doneSlices.length && showDoneSlices) {
      for (const item of sortDoneColumn(doneSlices)) {
        cards.appendChild(makeCard(item, st, activeTid, activity));
      }
    }
    col.appendChild(cards);
    board.appendChild(col);
  }

  const ym = document.getElementById("yourMove");
  const ymTitle = document.getElementById("yourMoveTitle");
  const ymBody = document.getElementById("yourMoveBody");
  const ymActions = document.getElementById("yourMoveActions");
  const ymHint = document.getElementById("yourMoveHint");
  const alsoStrip = document.getElementById("alsoStrip");
  const btnHold = document.getElementById("btnHold");
  const btnRetry = document.getElementById("btnRetry");
  const btnCopy = document.getElementById("btnCopy");
  const btnRequeue = document.getElementById("btnRequeue");
  const needsDecision = batch.state === "needs_decision" || mode === "needs_decision";
  const held = batch.state === "held" || mode === "held";
  const fail = batch.failure || null;
  const halted = items.filter(i => /Halted/i.test(i.status||""));
  const factoryStopped = mode === "stopped" || mode === "idle" || mode === "quiet";
  const hasQueuedWork = queuedAuto.length > 0 || inProg.length > 0;

  function cantShipHtml() {
    const reason = (fail && fail.reason) || batch.reason || "still_red";
    const fails = (fail && fail.failures) || [];
    const n = fail && fail.failed != null ? fail.failed : fails.length;
    let html = "";
    if (reason === "verify aborted" && !fails.length) {
      html += `<div><strong>Can't push — verify aborted</strong></div>`;
    } else {
      html += `<div><strong>Can't push — ${esc(String(n))} test(s) failed</strong></div>`;
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

  // Priority: orphan > can't-ship > held > halted > paused > start > quiet
  let lead = "quiet";
  if (mode === "orphan") lead = "orphan";
  else if (needsDecision) lead = "cant_ship";
  else if (held) lead = "held";
  else if (halted.length) lead = "halted";
  else if (mode === "paused") lead = "paused";
  else if (mode === "starting") lead = "starting";
  else if (factoryStopped && hasQueuedWork) lead = "start";
  else if (factoryStopped) lead = "idle";
  else lead = "quiet";

  const titles = {
    orphan: "Restart needed",
    cant_ship: "Can't push",
    held: "Not pushing (held)",
    halted: "Halted ticket",
    paused: "Paused",
    starting: "Starting…",
    start: "Start factory",
    idle: "Your move",
    quiet: "Your move",
  };
  ymTitle.textContent = titles[lead] || "Your move";

  if (lead === "orphan") {
    ymBody.textContent = activity.next || activity.detail || "Factory loop not running — Restart factory.";
  } else if (lead === "cant_ship") {
    ymBody.innerHTML = cantShipHtml();
  } else if (lead === "held") {
    const sha = (batch.head_sha || "").slice(0, 12) || "HEAD";
    ymBody.textContent = `Held at ${sha} — not pushing. Verify & push or Retry to run the full suite again.`;
  } else if (lead === "halted") {
    ymBody.textContent = `Halted: ${halted.map(h => h.id).join(", ")}. Fix the ticket in Cursor if needed, then Requeue — the factory won't run the full suite while this is parked.`;
  } else if (lead === "paused" || lead === "starting" || lead === "start" || lead === "idle") {
    ymBody.textContent = activity.next || "Nothing needed from you.";
  } else {
    ymBody.textContent = activity.next || "Nothing needed from you.";
  }

  const alertLeads = ["orphan","cant_ship","held","halted"];
  ym.classList.toggle("on", alertLeads.includes(lead));
  ym.classList.toggle("muted-panel", lead === "quiet" || lead === "idle");

  // Lead-story buttons
  const showCantShipBtns = lead === "cant_ship";
  const showRequeueLead = lead === "halted";
  btnHold.style.display = showCantShipBtns ? "" : "none";
  btnRetry.style.display = showCantShipBtns ? "" : "none";
  btnCopy.style.display = showCantShipBtns ? "" : "none";
  btnRequeue.style.display = showRequeueLead ? "" : "none";
  ymActions.style.display = (showCantShipBtns || showRequeueLead) ? "flex" : "none";
  if (showCantShipBtns) {
    ymHint.hidden = false;
    ymHint.textContent = "Don't push leaves commits local. Retry reruns all tests + one auto-fix pass (~10–15 min).";
  } else {
    ymHint.hidden = true;
  }

  // Also-strip: lower-priority items still visible + actionable
  const alsoBits = [];
  if (lead !== "halted" && halted.length) {
    alsoBits.push({
      text: `Also: Halted ${halted.map(h => h.id).join(", ")} (blocks full suite until Requeue)`,
      btn: "requeue",
    });
  }
  if (lead !== "cant_ship" && needsDecision) {
    alsoBits.push({ text: "Also: Can't push — full suite still failing", btn: null });
  }
  if (lead !== "held" && held) {
    alsoBits.push({ text: "Also: Not pushing (held)", btn: null });
  }
  if (alsoBits.length) {
    alsoStrip.hidden = false;
    alsoStrip.innerHTML = alsoBits.map(b => {
      const action = b.btn === "requeue"
        ? `<button type="button" id="btnRequeueAlso">Requeue</button>`
        : "";
      return `<div class="also-row"><span>${esc(b.text)}</span>${action}</div>`;
    }).join("");
    const alsoBtn = document.getElementById("btnRequeueAlso");
    if (alsoBtn) {
      alsoBtn.onclick = () => document.getElementById("btnRequeue").click();
    }
  } else {
    alsoStrip.hidden = true;
    alsoStrip.innerHTML = "";
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
  stationEl.className = "station" + (
    mode === "orphan" || mode === "needs_decision" || mode === "starting" ? " orphan"
    : mode === "batch" || batch.state === "verifying" || batch.state === "running" || batch.batch_running ? " running"
    : mode === "held" || batch.state === "held" ? " pending"
    : batch.needed && !activity.agents?.length ? " pending" : ""
  );
  document.getElementById("stationBeat").textContent = activity.headline
    || "Nothing to do right now";
  let subText = activity.detail || "";
  const verifyStarted = batch.verify_started_at != null ? Number(batch.verify_started_at) : null;
  if ((mode === "batch" || batch.state === "verifying" || batch.batch_running) && verifyStarted) {
    const elapsed = Math.max(0, Math.floor(Date.now() / 1000 - verifyStarted));
    const label = elapsed < 60
      ? (elapsed + "s")
      : (Math.floor(elapsed / 60) + "m " + String(elapsed % 60).padStart(2, "0") + "s");
    subText = subText.replace(/\s*—\s*[\dm\s:]+s?\s*elapsed/i, "").replace(/\s*—\s*starting$/i, "");
    subText = (subText ? subText + " — " : "") + label + " elapsed";
  }
  document.getElementById("stationSub").textContent = subText;
  document.getElementById("batchLine").innerHTML = batchLabel(batch, activity);

  const freshEl = document.getElementById("stationFresh");
  const ageLabel = formatAge(activity.activity_age_s);
  const claimsWork = ["working","batch","picking","batch_pending","starting"].includes(mode);
  if (ageLabel) {
    const stale = claimsWork && activity.activity_age_s != null && activity.activity_age_s > 180;
    freshEl.textContent = "Last activity " + ageLabel
      + (activity.loop_stale ? " · loop process missing" : "");
    freshEl.className = "fresh" + (stale || activity.loop_stale ? " warn" : "");
  } else if (claimsWork) {
    freshEl.textContent = "No recent activity signal yet";
    freshEl.className = "fresh warn";
  } else {
    freshEl.textContent = "";
    freshEl.className = "fresh";
  }

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

  syncToolbar(snap, activity);
}

/** Primary action + enable/disable follow server activity.mode only. */
function syncToolbar(snap, activity) {
  const mode = (activity && activity.mode) || "";
  const btnStart = document.getElementById("btnStart");
  const btnPause = document.getElementById("btnPause");
  const btnPauseAfter = document.getElementById("btnPauseAfter");
  const btnResume = document.getElementById("btnResume");
  const btnStop = document.getElementById("btnStop");
  const btnShip = document.getElementById("btnShip");
  const pauseAfterArmed = !!(snap.controls && snap.controls.pause_after_current && !snap.controls.paused);

  [btnStart, btnPause, btnPauseAfter, btnResume, btnStop, btnShip].forEach((b) => {
    if (b) b.classList.remove("primary");
  });

  if (mode === "orphan") {
    btnStart.textContent = "Restart factory";
    btnStart.disabled = false;
    btnStart.classList.add("primary");
    btnPause.disabled = true;
    btnPauseAfter.disabled = true;
    btnResume.disabled = true;
    btnStop.disabled = false;
    btnShip.disabled = true;
    return;
  }

  if (mode === "starting") {
    const age = activity.started_age_s != null ? Math.floor(activity.started_age_s) : null;
    btnStart.textContent = age != null ? `Starting… (${age}s)` : "Starting…";
    btnStart.disabled = true;
    btnPause.disabled = true;
    btnPauseAfter.disabled = true;
    btnResume.disabled = true;
    btnStop.disabled = false;
    btnShip.disabled = true;
    return;
  }

  if (mode === "paused") {
    btnStart.textContent = "Paused";
    btnStart.disabled = true;
    btnPause.disabled = true;
    btnPauseAfter.disabled = true;
    btnResume.disabled = false;
    btnResume.classList.add("primary");
    btnStop.disabled = false;
    btnShip.disabled = false;
    return;
  }

  if (["working","batch","picking","batch_pending","needs_decision","held"].includes(mode)) {
    btnStart.textContent = "Running";
    btnStart.disabled = true;
    btnPause.disabled = false;
    btnPause.classList.add("primary");
    btnPauseAfter.disabled = pauseAfterArmed;
    btnResume.disabled = !pauseAfterArmed;
    if (pauseAfterArmed) btnResume.classList.add("primary");
    btnStop.disabled = false;
    btnShip.disabled = false;
    return;
  }

  // stopped / idle / quiet
  btnStart.textContent = "Start factory";
  btnStart.disabled = false;
  btnStart.classList.add("primary");
  btnPause.disabled = true;
  btnPauseAfter.disabled = true;
  btnResume.disabled = true;
  btnStop.disabled = true;
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
document.getElementById("btnPauseAfter").onclick = () => post("/api/control", {action:"pause_after_current"});
document.getElementById("btnResume").onclick = () => post("/api/control", {action:"resume"});
document.getElementById("btnShip").onclick = () => post("/api/control", {action:"ship_now"});
document.getElementById("btnHold").onclick = () => {
  if (confirm("Don't push — leave commits local and idle until new work or Verify & push?")) {
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

    def handle(self) -> None:
        """Swallow client disconnects (SSE refresh / tab close) — not Start failures."""
        try:
            super().handle()
        except (ConnectionResetError, BrokenPipeError, TimeoutError):
            pass

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
        result = apply_control(data.get("action"), data)
        if not result.get("ok"):
            self._json(400, {"error": result.get("error")})
            return
        self._json(200, result)


class QuietThreadingHTTPServer(ThreadingHTTPServer):
    """Don't dump ConnectionResetError stack traces when the browser drops SSE."""

    def handle_error(self, request: Any, client_address: Any) -> None:
        err = sys.exc_info()[1]
        if isinstance(err, (ConnectionResetError, BrokenPipeError, TimeoutError)):
            return
        super().handle_error(request, client_address)


def main() -> int:
    import atexit

    atexit.register(_shutdown_owned_runner)
    reconcile_runner_on_boot()
    try:
        server = QuietThreadingHTTPServer(("127.0.0.1", PORT), Handler)
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
