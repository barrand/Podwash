#!/usr/bin/env python3
"""Forge task loop — serial rapid tasks + idle-drain batch gate.

Exit codes mirror slice_loop.py (0–6).
Polls build/factory/controls.json for soft controls (pause, ship_now, etc.).
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from typing import Any

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO_ROOT, "scripts"))

from rapid_task_pipeline import run_task_pipeline
from task_ticket import parse_task_ticket, set_task_priority, set_task_status

NEXT_TASK = os.path.join(REPO_ROOT, "scripts", "next-task.sh")
CONTROLS_PATH = os.path.join(REPO_ROOT, "build", "factory", "controls.json")
HOT_FLAG = os.path.join(REPO_ROOT, "build", "factory", "factory-hot")
BATCH_GATE_PATH = os.path.join(REPO_ROOT, "build", "factory", "batch-gate.json")
BATCH_FAILURE_PATH = os.path.join(REPO_ROOT, "build", "factory", "batch-failure.json")
STATION_PATH = os.path.join(REPO_ROOT, "build", "factory", "station.json")
HEARTBEAT_PATH = os.path.join(REPO_ROOT, "build", "factory", "heartbeat.json")
VERIFY_RESULT_JSON = os.path.join(REPO_ROOT, "build", "test-results", "verify-result.json")
VERIFY_OUTPUT_LATEST = os.path.join(
    REPO_ROOT, "build", "test-results", "verify-output-latest.txt"
)

EXIT_OK = 0
EXIT_STARTUP = 1
EXIT_RUN_FAILED = 2
EXIT_WAIT = 3
EXIT_HALT = 4
EXIT_THRASH = 5
EXIT_INFRA = 6


def log(msg: str) -> None:
    print(f"[task-loop] {msg}", flush=True)


def _git(args: list[str], *, cwd: str | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *args],
        cwd=cwd or REPO_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )


def head_sha(*, repo_root: str | None = None) -> str:
    proc = _git(["rev-parse", "HEAD"], cwd=repo_root)
    return (proc.stdout or "").strip() if proc.returncode == 0 else ""


def worktree_dirty(*, repo_root: str | None = None) -> bool:
    proc = _git(["status", "--porcelain"], cwd=repo_root)
    return bool((proc.stdout or "").strip())


def ahead_of_upstream(*, repo_root: str | None = None) -> bool:
    """True when local branch has commits not on @{upstream}."""
    proc = _git(["rev-list", "--count", "@{upstream}..HEAD"], cwd=repo_root)
    if proc.returncode != 0:
        return False
    try:
        return int((proc.stdout or "0").strip() or "0") > 0
    except ValueError:
        return False


def read_batch_gate(*, path: str | None = None) -> dict[str, Any]:
    p = path or BATCH_GATE_PATH
    if not os.path.isfile(p):
        return {}
    try:
        with open(p, encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def write_batch_gate(data: dict[str, Any], *, path: str | None = None) -> None:
    p = path or BATCH_GATE_PATH
    os.makedirs(os.path.dirname(p), exist_ok=True)
    payload = dict(data)
    payload["updated_at"] = time.time()
    with open(p, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2)
        fh.write("\n")


def batch_needed(
    *,
    force: bool = False,
    repo_root: str | None = None,
    stamp_path: str | None = None,
    failure_path: str | None = None,
) -> tuple[bool, str]:
    """Whether idle-drain should run a full tier-3 verify.

    Ship now passes force=True. Otherwise skip when HEAD matches last green
    stamp and the worktree is clean, or when an incident at HEAD is acknowledged
    (Don't push).
    """
    if force:
        return True, "ship_now"
    root = repo_root or REPO_ROOT
    sha = head_sha(repo_root=root)
    incident = read_batch_failure(path=failure_path)
    if (
        incident.get("status") == "acknowledged"
        and sha
        and str(incident.get("head_sha") or "").strip() == sha
    ):
        return False, "held"
    stamp = read_batch_gate(path=stamp_path)
    last = str(stamp.get("sha") or "").strip()
    if not last:
        return True, "never verified"
    if not sha:
        return True, "unknown HEAD"
    if sha != last:
        return True, "HEAD moved"
    if worktree_dirty(repo_root=root):
        return True, "dirty tree"
    return False, "not needed"


def read_batch_failure(*, path: str | None = None) -> dict[str, Any]:
    """Read the open/acknowledged batch incident (or {})."""
    p = path or BATCH_FAILURE_PATH
    if not os.path.isfile(p):
        return {}
    try:
        with open(p, encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def write_batch_failure(data: dict[str, Any], *, path: str | None = None) -> None:
    p = path or BATCH_FAILURE_PATH
    os.makedirs(os.path.dirname(p), exist_ok=True)
    payload = dict(data)
    payload["updated_at"] = time.time()
    with open(p, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2)
        fh.write("\n")


def clear_batch_failure(*, path: str | None = None) -> None:
    p = path or BATCH_FAILURE_PATH
    if os.path.isfile(p):
        try:
            os.remove(p)
        except OSError:
            pass


def acknowledge_batch_failure(*, path: str | None = None) -> dict[str, Any]:
    """Mark the incident acknowledged (Don't push). Returns the updated incident."""
    data = read_batch_failure(path=path)
    if not data:
        return {}
    data["status"] = "acknowledged"
    write_batch_failure(data, path=path)
    return data


def collect_verify_failures(
    *,
    repo_root: str | None = None,
) -> tuple[list[dict[str, str]], dict[str, Any]]:
    """Return (failures[{id,assertion}], verify-result.json dict)."""
    root = repo_root or REPO_ROOT
    result_path = os.path.join(root, "build", "test-results", "verify-result.json")
    result: dict[str, Any] = {}
    if os.path.isfile(result_path):
        try:
            with open(result_path, encoding="utf-8") as fh:
                raw = json.load(fh)
            if isinstance(raw, dict):
                result = raw
        except (OSError, json.JSONDecodeError):
            result = {}

    bundle = str(result.get("bundle") or "").strip()
    if bundle and not os.path.isabs(bundle):
        bundle_abs = os.path.join(root, bundle)
    else:
        bundle_abs = bundle
    if not bundle_abs or not os.path.isdir(bundle_abs):
        tr = os.path.join(root, "build", "test-results")
        try:
            cands = [
                os.path.join(tr, n)
                for n in os.listdir(tr)
                if n.startswith("verify-") and n.endswith(".xcresult")
            ]
            cands.sort(key=lambda p: os.path.getmtime(p), reverse=True)
            bundle_abs = cands[0] if cands else ""
            if bundle_abs:
                result.setdefault("bundle", os.path.relpath(bundle_abs, root))
        except OSError:
            bundle_abs = ""

    failures: list[dict[str, str]] = []
    if bundle_abs:
        try:
            from failure_packet import read_xcresult_summary, summary_test_failures

            summary = read_xcresult_summary(bundle_abs)
            if summary:
                for tid, assertion in summary_test_failures(summary):
                    failures.append({"id": tid, "assertion": assertion})
        except Exception:
            pass
    return failures, result


def build_batch_incident(
    *,
    reason: str,
    machine_tried: list[str],
    repo_root: str | None = None,
    status: str = "open",
) -> dict[str, Any]:
    """Build a ticket-shaped incident from the latest verify artifacts."""
    root = repo_root or REPO_ROOT
    prior = read_batch_failure()
    sha = head_sha(repo_root=root)
    prior_ids: list[str] = []
    if prior and str(prior.get("head_sha") or "") == sha:
        prior_ids = [
            str(f.get("id") or "")
            for f in (prior.get("failures") or [])
            if isinstance(f, dict) and f.get("id")
        ]
        if not prior_ids:
            prior_ids = [str(x) for x in (prior.get("prior_failures") or []) if x]

    failures, result = collect_verify_failures(repo_root=root)
    bundle = str(result.get("bundle") or "")
    output_rel = "build/test-results/verify-output-latest.txt"
    output_abs = os.path.join(root, output_rel)
    if not os.path.isfile(output_abs):
        output_rel = ""

    return {
        "status": status,
        "head_sha": sha,
        "reason": reason,
        "exit": result.get("exit"),
        "passed": result.get("passed"),
        "failed": result.get("failed") if result.get("failed") is not None else len(failures),
        "total": result.get("total"),
        "bundle": bundle,
        "output": output_rel,
        "failures": failures,
        "prior_failures": prior_ids,
        "retried_tests": list(prior.get("retried_tests") or []) if prior else [],
        "machine_tried": list(machine_tried),
    }


def notify_cant_ship(incident: dict[str, Any]) -> None:
    """macOS banner that names the failing test(s)."""
    fails = [f for f in (incident.get("failures") or []) if isinstance(f, dict)]
    n = int(incident.get("failed") or len(fails) or 0)
    if not fails and incident.get("reason") == "verify aborted":
        notify("Forge", "Can't ship — verify aborted")
        return
    if not fails:
        notify("Forge", f"Can't ship — {n or '?'} test(s) failed")
        return
    first = str(fails[0].get("id") or "unknown")
    # Prefer Class/method over Target/Class/method for the banner
    short = first.split("/")[-2] + "/" + first.split("/")[-1] if first.count("/") >= 2 else first
    extra = f" (+{n - 1})" if n > 1 else ""
    notify("Forge", f"Can't ship — {n} failed: {short}{extra}")


def write_batch_halt_bundle(incident: dict[str, Any], *, reason: str) -> str:
    """Write session-task-batch halt.json so Medic can diagnose thrash/abort."""
    from session_bundle import write_session_bundle

    fail_ids = [
        str(f.get("id") or "")
        for f in (incident.get("failures") or [])
        if isinstance(f, dict) and f.get("id")
    ]
    return write_session_bundle(
        repo_root=REPO_ROOT,
        slice_id=None,
        reason=reason,
        stuck_card=(
            f"Batch gate {reason}\n"
            f"HEAD {incident.get('head_sha') or '?'}\n"
            f"failed={incident.get('failed')} passed={incident.get('passed')}\n"
            + "\n".join(fail_ids[:10])
        ),
        verify_result={
            "exit": incident.get("exit"),
            "passed": incident.get("passed"),
            "failed": incident.get("failed"),
            "total": incident.get("total"),
            "bundle": incident.get("bundle"),
        },
        failures=fail_ids,
        phase="BATCH",
        extra={
            "kind": "task-batch",
            "machine_tried": incident.get("machine_tried") or [],
            "incident_reason": incident.get("reason"),
        },
        bundle_name="session-task-batch",
    )


def set_station(
    *,
    phase: str,
    role: str = "",
    task_id: int | None = None,
    mission: str = "",
    detail: str = "",
    batch: dict[str, Any] | None = None,
    path: str | None = None,
) -> None:
    """Live Floor status — polled by forge-floor /api/board."""
    p = path or STATION_PATH
    os.makedirs(os.path.dirname(p), exist_ok=True)
    payload: dict[str, Any] = {
        "phase": phase,
        "role": role,
        "task_id": task_id,
        "mission": mission,
        "detail": detail,
        "updated_at": time.time(),
    }
    if batch is not None:
        payload["batch"] = batch
    with open(p, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2)
        fh.write("\n")


def clear_station(*, path: str | None = None) -> None:
    p = path or STATION_PATH
    if os.path.isfile(p):
        try:
            os.remove(p)
        except OSError:
            pass


def read_station(*, path: str | None = None) -> dict[str, Any]:
    p = path or STATION_PATH
    if not os.path.isfile(p):
        return {}
    try:
        with open(p, encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def query_next() -> dict[str, Any]:
    env = os.environ.copy()
    proc = subprocess.run(
        [NEXT_TASK, "--json"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        env=env,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"next-task.sh failed: {proc.stderr.strip()}")
    return json.loads(proc.stdout.strip() or "{}")


def default_controls() -> dict[str, Any]:
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
        "runner_pid": None,
        "started_at": None,
        "updated_at": None,
    }


def read_controls() -> dict[str, Any]:
    if not os.path.isfile(CONTROLS_PATH):
        return default_controls()
    try:
        with open(CONTROLS_PATH, encoding="utf-8") as fh:
            data = json.load(fh)
        base = default_controls()
        base.update(data)
        return base
    except (OSError, json.JSONDecodeError):
        return default_controls()


def write_controls(data: dict[str, Any]) -> None:
    os.makedirs(os.path.dirname(CONTROLS_PATH), exist_ok=True)
    data = dict(data)
    data["updated_at"] = time.time()
    with open(CONTROLS_PATH, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")


def write_heartbeat() -> None:
    """Touch heartbeat.json so Forge Floor knows this loop is alive."""
    os.makedirs(os.path.dirname(HEARTBEAT_PATH), exist_ok=True)
    payload = {"pid": os.getpid(), "ts": time.time()}
    with open(HEARTBEAT_PATH, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2)
        fh.write("\n")


def set_factory_hot(hot: bool) -> None:
    os.makedirs(os.path.dirname(HOT_FLAG), exist_ok=True)
    if hot:
        with open(HOT_FLAG, "w", encoding="utf-8") as fh:
            fh.write("1\n")
    elif os.path.isfile(HOT_FLAG):
        os.remove(HOT_FLAG)


def apply_control_side_effects(ctrl: dict[str, Any]) -> dict[str, Any]:
    """Honor one-shot control commands; clear them after apply."""
    changed = False
    rid = ctrl.get("requeue_task_id")
    if rid is not None:
        path = _task_path_for_id(int(rid))
        if path:
            set_task_status(path, "Queued")
            log(f"requeued task-{int(rid):03d}")
        ctrl["requeue_task_id"] = None
        changed = True
    cid = ctrl.get("cancel_task_id")
    if cid is not None:
        path = _task_path_for_id(int(cid))
        if path:
            set_task_status(path, "Halted")
            log(f"cancelled task-{int(cid):03d} → Halted")
        ctrl["cancel_task_id"] = None
        changed = True
    mid = ctrl.get("mark_done_task_id")
    if mid is not None:
        path = _task_path_for_id(int(mid))
        if path:
            set_task_status(path, "Done")
            log(f"Needs-human mark done task-{int(mid):03d}")
        ctrl["mark_done_task_id"] = None
        changed = True
    bumps = ctrl.get("priority_bumps") or {}
    if bumps:
        for tid_s, prio in list(bumps.items()):
            path = _task_path_for_id(int(tid_s))
            if path:
                set_task_priority(path, str(prio))
                log(f"priority task-{int(tid_s):03d} → {prio}")
        ctrl["priority_bumps"] = {}
        changed = True
    if changed:
        write_controls(ctrl)
    return ctrl


def _task_path_for_id(tid: int) -> str | None:
    tasks_dir = os.environ.get("PODWASH_TASKS_DIR") or os.path.join(REPO_ROOT, "docs", "tasks")
    prefix = f"task-{tid:03d}-"
    if not os.path.isdir(tasks_dir):
        return None
    for name in os.listdir(tasks_dir):
        if name.startswith(prefix) and name.endswith(".md"):
            return os.path.join(tasks_dir, name)
    return None


def notify(title: str, body: str) -> None:
    """macOS notification + terminal bell (best-effort)."""
    sys.stdout.write("\a")
    sys.stdout.flush()
    try:
        subprocess.run(
            [
                "osascript",
                "-e",
                f'display notification {json.dumps(body)} with title {json.dumps(title)}',
            ],
            check=False,
            capture_output=True,
        )
    except OSError:
        pass


def run_batch_gate(
    *,
    api_key: str,
    dry_run: bool,
    no_commit: bool,
    no_push: bool,
    skip: bool,
    force: bool = False,
) -> int:
    """Tier-3 full suite; on green push (unless no_push). Returns exit code.

    Idle drain passes force=False (skip when already green at HEAD, or when
    an incident at HEAD is acknowledged). Ship now passes force=True.
    """
    from factory_events import EventLog

    write_heartbeat()

    if skip:
        log("batch gate skipped (--skip-batch-gate)")
        set_station(phase="batch", role="loop", detail="skipped", batch={"state": "idle", "needed": False, "reason": "skipped"})
        return EXIT_OK

    needed, reason = batch_needed(force=force)
    if not needed:
        log(f"batch gate skipped — already green at {head_sha()[:12] or '?'} ({reason})")
        state = "held" if reason == "held" else "green"
        set_station(
            phase="batch",
            role="loop",
            detail=(
                f"held @ {(head_sha() or '')[:12]} — not pushing"
                if reason == "held"
                else f"green @ {(head_sha() or '')[:12]} — nothing to verify"
            ),
            batch={
                "state": state,
                "needed": False,
                "reason": reason,
                "last_green_sha": read_batch_gate().get("sha"),
                "head_sha": head_sha(),
            },
        )
        if reason == "held":
            return EXIT_OK
        if not no_push and not no_commit and ahead_of_upstream():
            log("already green — push only (ahead of upstream)")
            proc = subprocess.run(["git", "push"], cwd=REPO_ROOT, capture_output=True, text=True)
            if proc.returncode != 0:
                log(f"git push failed: {proc.stderr.strip()}")
                notify("Forge", "Push failed (batch already green)")
                return EXIT_RUN_FAILED
            stamp = read_batch_gate()
            stamp["pushed"] = True
            write_batch_gate(stamp)
            notify("Forge", "Pushed (verify skipped — already green)")
            return EXIT_OK
        return EXIT_OK

    from slice_pipeline import run_verify

    if dry_run:
        log(f"dry-run batch gate: would run VERIFY_TIER=3 ({reason}) and push")
        return EXIT_OK

    events = EventLog(REPO_ROOT, None, kind="task", log=log)
    ctrl = read_controls()
    ctrl["batch_running"] = True
    write_controls(ctrl)
    set_station(
        phase="FULL-VERIFY",
        role="loop",
        detail=f"tier-3 full suite ({reason})",
        batch={"state": "running", "needed": True, "reason": reason, "head_sha": head_sha()},
    )
    events.record(
        "FULL-VERIFY",
        "loop",
        "verify_start",
        timeline=True,
        mission=f"tier-3 batch ({reason})",
        detail={"reason": reason, "force": force},
    )

    log(f"BATCH GATE: full suite (tier 3) — {reason}")
    machine_tried: list[str] = ["tier3_retries"]
    outcome = None
    try:
        outcome = run_verify(REPO_ROOT, log=log, tier=3)
    finally:
        ctrl = read_controls()
        ctrl["batch_running"] = False
        write_controls(ctrl)

    if outcome is None:
        incident = build_batch_incident(
            reason="verify aborted",
            machine_tried=machine_tried,
        )
        write_batch_failure(incident)
        write_batch_halt_bundle(incident, reason="verify aborted")
        set_station(
            phase="batch",
            role="loop",
            detail="verify aborted — Needs you",
            batch={"state": "needs_decision", "needed": True, "reason": "verify aborted"},
        )
        notify_cant_ship(incident)
        return EXIT_INFRA

    events.record(
        "FULL-VERIFY",
        "loop",
        "verify_end",
        timeline=True,
        mission="tier-3 batch",
        detail={"green": bool(outcome.green)},
    )

    if outcome.green:
        log("batch gate GREEN")
        sha = head_sha()
        clear_batch_failure()
        write_batch_gate({"sha": sha, "green": True, "pushed": False, "tier": 3})
        set_station(
            phase="batch",
            role="loop",
            detail=f"green @ {(sha or '')[:12]}",
            batch={"state": "green", "needed": False, "reason": "verified", "last_green_sha": sha, "head_sha": sha},
        )
        if not no_push and not no_commit:
            proc = subprocess.run(["git", "push"], cwd=REPO_ROOT, capture_output=True, text=True)
            if proc.returncode != 0:
                log(f"git push failed: {proc.stderr.strip()}")
                notify("Forge", "Batch green but push failed")
                return EXIT_RUN_FAILED
            write_batch_gate({"sha": sha, "green": True, "pushed": True, "tier": 3})
            log("pushed")
            notify("Forge", "Batch pushed")
        return EXIT_OK

    log("batch gate RED — one Mechanic retry")
    machine_tried.append("mechanic")
    # Snapshot failures before Mechanic so prior_failures is populated on still-red
    pre = build_batch_incident(reason="mechanic_pending", machine_tried=list(machine_tried))
    write_batch_failure(pre)
    notify_cant_ship(pre)
    set_station(
        phase="FULL-VERIFY",
        role="Mechanic",
        detail="tier-3 red — Mechanic retry",
        batch={"state": "running", "needed": True, "reason": reason},
    )

    # One Mechanic tier-3 pass
    try:
        from cursor_bridge import launch_bridge
        from factory_progress import ProgressTracker
        from mechanic_fix import run_fix_cycle

        client = launch_bridge(workspace=REPO_ROOT)
        try:
            tracker = ProgressTracker(max_spawns=3, max_minutes=20.0)
            # Use a synthetic path — Mechanic needs a slice_file for logging
            placeholder = os.path.join(REPO_ROOT, "docs", "tasks", "README.md")
            run_fix_cycle(
                client,
                slice_file=placeholder,
                repo_root=REPO_ROOT,
                api_key=api_key,
                gate_tier=3,
                tracker=tracker,
                log=log,
            )
        finally:
            try:
                client.close()
            except Exception:
                pass
    except Exception as exc:
        log(f"batch Mechanic failed: {exc}")

    ctrl = read_controls()
    ctrl["batch_running"] = True
    write_controls(ctrl)
    set_station(
        phase="FULL-VERIFY",
        role="loop",
        detail="tier-3 re-verify after Mechanic",
        batch={"state": "running", "needed": True, "reason": "mechanic_retry"},
    )
    try:
        outcome2 = run_verify(REPO_ROOT, log=log, tier=3)
    finally:
        ctrl = read_controls()
        ctrl["batch_running"] = False
        write_controls(ctrl)

    if outcome2 is None:
        incident = build_batch_incident(
            reason="verify aborted",
            machine_tried=machine_tried,
        )
        write_batch_failure(incident)
        write_batch_halt_bundle(incident, reason="verify aborted after Mechanic")
        set_station(
            phase="batch",
            role="loop",
            detail="verify aborted after Mechanic — Needs you",
            batch={"state": "needs_decision", "needed": True, "reason": "verify aborted"},
        )
        notify_cant_ship(incident)
        return EXIT_INFRA

    if outcome2.green:
        sha = head_sha()
        clear_batch_failure()
        write_batch_gate({"sha": sha, "green": True, "pushed": False, "tier": 3})
        set_station(
            phase="batch",
            role="loop",
            detail=f"green @ {(sha or '')[:12]} after Mechanic",
            batch={"state": "green", "needed": False, "reason": "verified", "last_green_sha": sha},
        )
        if not no_push and not no_commit:
            subprocess.run(["git", "push"], cwd=REPO_ROOT, check=False)
            write_batch_gate({"sha": sha, "green": True, "pushed": True, "tier": 3})
            notify("Forge", "Batch pushed after Mechanic")
        return EXIT_OK

    # Still red — write open incident + halt bundle for Medic, then EXIT_THRASH
    incident = build_batch_incident(
        reason="still_red",
        machine_tried=machine_tried,
    )
    write_batch_failure(incident)
    write_batch_halt_bundle(incident, reason="still_red")
    log("BATCH BLOCKED — open incident written; Medic (supervisor) or Needs you")
    set_station(
        phase="batch",
        role="loop",
        detail="Can't ship — Needs you",
        batch={"state": "needs_decision", "needed": True, "reason": "still_red"},
    )
    notify_cant_ship(incident)
    return EXIT_THRASH


def wait_while_paused() -> None:
    while True:
        write_heartbeat()
        ctrl = apply_control_side_effects(read_controls())
        if not ctrl.get("paused"):
            return
        log("paused — waiting")
        set_station(phase="paused", role="loop", detail="waiting for Resume")
        time.sleep(2)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Forge serial task loop")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--max", type=int, default=0, help="Max tasks this session (0=unlimited)")
    parser.add_argument("--no-commit", action="store_true")
    parser.add_argument("--no-push", action="store_true")
    parser.add_argument("--skip-batch-gate", action="store_true")
    parser.add_argument("--once", action="store_true", help="Run at most one task then exit (no batch)")
    args = parser.parse_args(argv)

    api_key = os.environ.get("CURSOR_API_KEY", "")
    if not args.dry_run and not api_key:
        log("CURSOR_API_KEY required (or use --dry-run)")
        return EXIT_STARTUP

    set_factory_hot(True)
    write_heartbeat()
    ctrl = read_controls()
    ctrl["running"] = True
    ctrl["paused"] = False
    ctrl["runner_pid"] = os.getpid()
    if not ctrl.get("started_at"):
        ctrl["started_at"] = time.time()
    write_controls(ctrl)

    ran = 0
    last_id: int | None = None
    try:
        while True:
            write_heartbeat()
            wait_while_paused()
            ctrl = apply_control_side_effects(read_controls())

            if ctrl.get("ship_now"):
                ctrl["ship_now"] = False
                write_controls(ctrl)
                code = run_batch_gate(
                    api_key=api_key,
                    dry_run=args.dry_run,
                    no_commit=args.no_commit,
                    no_push=args.no_push,
                    skip=args.skip_batch_gate,
                    force=True,
                )
                if code != EXIT_OK:
                    return code

            decision = query_next()
            action = decision.get("action")
            if action == "done":
                needed, reason = batch_needed(force=False)
                log(f"queue empty — idle drain ({reason})")
                if args.once:
                    return EXIT_OK
                return run_batch_gate(
                    api_key=api_key,
                    dry_run=args.dry_run,
                    no_commit=args.no_commit,
                    no_push=args.no_push,
                    skip=args.skip_batch_gate or ctrl.get("skip_batch_gate", False),
                    force=False,
                )
            if action == "wait":
                log(decision.get("message", "wait"))
                return EXIT_WAIT
            if action != "start":
                log(f"unexpected action: {action}")
                return EXIT_RUN_FAILED

            tid = int(decision["id"])
            if last_id is not None and tid == last_id:
                log(f"no-progress guard: task {tid} offered twice")
                return EXIT_RUN_FAILED
            last_id = tid

            tfile = decision["file"]
            log(f"start task-{tid:03d} {tfile}")
            set_station(
                phase="task",
                role="pipeline",
                task_id=tid,
                mission=os.path.basename(tfile),
                detail="starting",
            )
            try:
                ok, meta = run_task_pipeline(
                    tfile,
                    api_key=api_key,
                    repo_root=REPO_ROOT,
                    dry_run=args.dry_run,
                    no_commit=args.no_commit,
                )
            except Exception as exc:
                from slice_pipeline import InfraHalt

                if exc.__class__.__name__ == "InfraHalt" or "InfraHalt" in type(exc).__name__:
                    log(f"infra: {exc}")
                    notify("Forge", f"Infra halt task-{tid:03d}")
                    return EXIT_INFRA
                raise

            if not ok:
                halt = (meta or {}).get("halt")
                notify("Forge", f"Task-{tid:03d} Halted ({halt})")
                set_station(
                    phase="halted",
                    role="pipeline",
                    task_id=tid,
                    detail=str(halt or "halted"),
                )
                # Park and continue (plan: one retry is inside Mechanic; then continue)
                last_id = None
                ran += 1
                if args.max and ran >= args.max:
                    return EXIT_OK
                if args.once:
                    return EXIT_THRASH
                continue

            ran += 1
            last_id = None
            if args.max and ran >= args.max:
                log(f"--max {args.max} reached")
                return EXIT_OK
            if args.once:
                return EXIT_OK
    finally:
        clear_station()
        set_factory_hot(False)
        ctrl = read_controls()
        ctrl["running"] = False
        ctrl["batch_running"] = False
        write_controls(ctrl)


if __name__ == "__main__":
    sys.exit(main())
