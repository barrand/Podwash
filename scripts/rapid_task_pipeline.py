#!/usr/bin/env python3
"""Rapid task pipeline — QA → Engineer → tier-2 verify → low-cap Mechanic.

Does not push. Split commits: ``task-NNN: tests`` then ``task-NNN: implement``.
"""

from __future__ import annotations

import os
import sys
import time
from typing import Any, Callable

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if REPO_ROOT not in sys.path:
    sys.path.insert(0, os.path.join(REPO_ROOT, "scripts"))

from factory_events import EventLog
from factory_progress import ProgressTracker
from factory_narrator import NameAssigner
from task_ticket import (
    parse_task_ticket,
    set_task_status,
    write_task_verify_result,
)

LogFn = Callable[[str], None]

TASK_MAX_SPAWNS = 3
TASK_MAX_MINUTES = 15.0


def _set_phase(
    *,
    task_id: int,
    phase: str,
    role: str,
    mission: str,
    detail: str = "",
) -> None:
    try:
        from task_loop import set_station

        set_station(
            phase=phase,
            role=role,
            task_id=task_id,
            mission=mission,
            detail=detail,
        )
    except Exception:
        pass


def log_default(msg: str) -> None:
    print(f"[task-pipeline] {msg}", flush=True)


def _persona(role: str) -> str:
    from slice_pipeline import load_persona

    return load_persona(role)


def _qa_prompt(ticket_path: str, ticket: Any) -> str:
    tests = "\n".join(f"- {t}" for t in ticket.surgical_tests) or "- (none listed — derive from ACs)"
    auth = "\n".join(f"- {t}" for t in ticket.authorized_test_changes) or "- (none)"
    return f"""{_persona("qa")}

# Task ticket (read-only contract)
File: {ticket_path}

Write **only** the tests in Surgical test scope. Touch only Authorized test changes
when Kind is tweak. Do not edit app sources under PodWash/PodWash/**.
Do not run scripts/verify.sh — the loop owns verify.

## Surgical test scope
{tests}

## Authorized test changes
{auth}

After writing tests, stop.
"""


def _eng_prompt(ticket_path: str, ticket: Any) -> str:
    tests = "\n".join(f"- {t}" for t in ticket.surgical_tests) or "- (see ticket)"
    auth = "\n".join(f"- {t}" for t in ticket.authorized_test_changes) or "- (none)"
    return f"""{_persona("engineer")}

# Task ticket
File: {ticket_path}

Implement the outcome and ACs. Do **not** modify tests except those listed under
Authorized test changes. Do not run scripts/verify.sh — the loop owns verify.

## Surgical tests that must pass
{tests}

## Authorized test changes
{auth}
"""


def commit_task_changes(
    task_id: int,
    repo_root: str,
    *,
    log: LogFn | None = None,
    tests_only: bool = False,
    app_only: bool = False,
) -> bool:
    from slice_pipeline import (
        check_test_isolation,
        git_paths_changed,
        run_git,
        split_paths_for_commits,
    )

    _log = log or log_default
    nn = f"{task_id:03d}"
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
        if not check_test_isolation(repo_root, staged=True, log=_log):
            _log("check-test-isolation FAILED — aborting commit")
            run_git(repo_root, ["reset", "HEAD"], log=_log)
            return False
        return run_git(repo_root, ["commit", "-m", message], log=_log) == 0

    if tests_only:
        return stage_and_commit(tests, f"task-{nn}: tests")
    if app_only:
        return stage_and_commit(apps + other, f"task-{nn}: implement")
    ok = True
    if tests and not stage_and_commit(tests, f"task-{nn}: tests"):
        ok = False
    if ok and (apps or other) and not stage_and_commit(apps + other, f"task-{nn}: implement"):
        ok = False
    # Always allow ticket doc updates with docs commit
    docs = [
        p
        for p in paths
        if p.startswith("docs/tasks/") and p not in tests and p not in apps
    ]
    if ok and docs:
        stage_and_commit(docs, f"task-{nn}: record")
    return ok


def run_task_pipeline(
    task_file: str,
    *,
    api_key: str,
    repo_root: str | None = None,
    dry_run: bool = False,
    no_commit: bool = False,
    client: Any | None = None,
    log: LogFn | None = None,
) -> tuple[bool, dict[str, Any]]:
    """Run one task to Done (or Halted). Returns (ok, meta)."""
    from cursor_bridge import launch_bridge
    from mechanic_fix import run_fix_cycle
    from slice_loop_progress import ThrashHalt
    from slice_pipeline import InfraHalt, run_verify, run_worker

    _log = log or log_default
    root = repo_root or REPO_ROOT
    path = task_file if os.path.isabs(task_file) else os.path.join(root, task_file)
    ticket = parse_task_ticket(path)
    meta: dict[str, Any] = {"id": ticket.id, "file": path}
    events = EventLog(root, ticket.id, kind="task")
    events.record("task", "pipeline", "start", timeline=True, mission=ticket.title)

    if dry_run:
        _log(f"dry-run task-{ticket.id:03d}: QA → Engineer → tier-2 {ticket.surgical_tests}")
        meta["dry_run"] = True
        return True, meta

    if not ticket.surgical_tests and "needs-human" not in (ticket.kind or "").lower():
        _log("FACTORY CONFIG: no surgical tests on ticket — cannot run automatable pipeline")
        set_task_status(path, "Halted")
        meta["halt"] = "no_surgical_tests"
        return False, meta

    set_task_status(path, "In Progress")
    from sim_hygiene import ensure_sim_booted, resolve_sim_udid

    udid = resolve_sim_udid(log=_log)
    if udid:
        os.environ.setdefault("PODWASH_SIM_UDID", udid)
        ensure_sim_booted(udid, log=_log)

    own_client = client is None
    if own_client:
        client = launch_bridge(workspace=root)

    try:
        # --- QA ---
        _set_phase(
            task_id=ticket.id,
            phase="TEST_SPEC",
            role="QA",
            mission=ticket.title,
            detail="writing surgical tests",
        )
        ok, status = run_worker(
            client,
            role="qa",
            prompt=_qa_prompt(path, ticket),
            api_key=api_key,
            repo_root=root,
            log=_log,
        )
        events.record("task", "qa", "worker_end", detail={"ok": ok, "status": status})
        if not ok:
            set_task_status(path, "Halted")
            meta["halt"] = "qa_worker"
            _set_phase(
                task_id=ticket.id,
                phase="halted",
                role="QA",
                mission=ticket.title,
                detail="qa_worker failed",
            )
            return False, meta
        if not no_commit:
            commit_task_changes(ticket.id, root, log=_log, tests_only=True)

        # --- Engineer ---
        _set_phase(
            task_id=ticket.id,
            phase="IMPLEMENT",
            role="Engineer",
            mission=ticket.title,
            detail="implementing fix",
        )
        ok, status = run_worker(
            client,
            role="engineer",
            prompt=_eng_prompt(path, ticket),
            api_key=api_key,
            repo_root=root,
            log=_log,
        )
        events.record("task", "engineer", "worker_end", detail={"ok": ok, "status": status})
        if not ok:
            set_task_status(path, "Halted")
            meta["halt"] = "engineer_worker"
            _set_phase(
                task_id=ticket.id,
                phase="halted",
                role="Engineer",
                mission=ticket.title,
                detail="engineer_worker failed",
            )
            return False, meta

        # --- tier-2 verify + Mechanic ---
        _set_phase(
            task_id=ticket.id,
            phase="TIER2-VERIFY",
            role="loop",
            mission=ticket.title,
            detail="surgical tests",
        )
        tracker = ProgressTracker(max_spawns=TASK_MAX_SPAWNS, max_minutes=TASK_MAX_MINUTES)
        try:
            outcome = run_fix_cycle(
                client,
                slice_file=path,
                repo_root=root,
                api_key=api_key,
                gate_tier=2,
                tracker=tracker,
                log=_log,
                event_log=events,
                names=NameAssigner(),
                verify_fn=lambda **kw: run_verify(
                    root,
                    log=_log,
                    slice_file=path,
                    tier=2,
                    slice_tests=ticket.surgical_tests,
                    **{k: v for k, v in kw.items() if k not in ("tier", "slice_file", "slice_tests")},
                ),
            )
        except ThrashHalt as exc:
            _log(f"THRASH HALT task-{ticket.id:03d}: {exc}")
            set_task_status(path, "Halted")
            meta["halt"] = "thrash"
            meta["error"] = str(exc)
            _set_phase(
                task_id=ticket.id,
                phase="halted",
                role="Mechanic",
                mission=ticket.title,
                detail="thrash",
            )
            return False, meta
        except InfraHalt as exc:
            meta["halt"] = "infra"
            meta["error"] = str(exc)
            raise

        result = dict(getattr(outcome, "result", {}) or {})
        write_task_verify_result(path, result)
        if not no_commit:
            commit_task_changes(ticket.id, root, log=_log)
        set_task_status(path, "Done")
        events.record("task", "pipeline", "done", timeline=True)
        _set_phase(
            task_id=ticket.id,
            phase="done",
            role="pipeline",
            mission=ticket.title,
            detail="tier-2 green",
        )
        meta["verify"] = result
        return True, meta
    finally:
        if own_client and client is not None:
            try:
                client.close()
            except Exception:
                pass


if __name__ == "__main__":
    import argparse

    p = argparse.ArgumentParser(description="Run one Forge task pipeline")
    p.add_argument("task_file")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--no-commit", action="store_true")
    args = p.parse_args()
    key = os.environ.get("CURSOR_API_KEY", "")
    if not args.dry_run and not key:
        print("CURSOR_API_KEY required", file=sys.stderr)
        sys.exit(1)
    ok, _meta = run_task_pipeline(
        args.task_file, api_key=key, dry_run=args.dry_run, no_commit=args.no_commit
    )
    sys.exit(0 if ok else 2)
