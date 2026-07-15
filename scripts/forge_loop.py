#!/usr/bin/env python3
"""Unified Forge loop — one serial runner for tasks + slices.

Picks the next work item via ``scripts/next-work.sh`` (priority across both
boards), dispatches to the rapid task pipeline or slice gate FSM, and exits
each item at tier-2 green → Status **Implemented**. Full-suite ship gate is
manual (Floor **Full verify & ship** / ``ship_now``).

Exit codes mirror slice_loop / task_loop (0–6).
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from typing import Any

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO_ROOT, "scripts"))

import task_loop as tl
from forge_work import (
    count_items_since_batch_gate,
    lightweight_bisect,
    promote_implemented_to_done,
    query_next_work,
    verify_is_ship_green,
)
from rapid_task_pipeline import run_task_pipeline
from slice_pipeline import InfraHalt, run_pipeline_slice

EXIT_OK = tl.EXIT_OK
EXIT_STARTUP = tl.EXIT_STARTUP
EXIT_RUN_FAILED = tl.EXIT_RUN_FAILED
EXIT_WAIT = tl.EXIT_WAIT
EXIT_HALT = tl.EXIT_HALT
EXIT_THRASH = tl.EXIT_THRASH
EXIT_INFRA = tl.EXIT_INFRA


def log(msg: str) -> None:
    print(f"[forge-loop] {msg}", flush=True)


def run_batch_gate_unified(
    *,
    api_key: str,
    dry_run: bool,
    no_commit: bool,
    no_push: bool,
    skip: bool,
    force: bool = False,
) -> int:
    """Tier-3 ship gate: 3a then 3 (or 3b), Mechanic, bisect, promote Implemented→Done."""
    from factory_events import EventLog
    from slice_pipeline import run_verify

    tl.write_heartbeat()
    if skip:
        log("batch gate skipped (--skip-batch-gate)")
        return EXIT_OK

    needed, reason = tl.batch_needed(force=force)
    since = count_items_since_batch_gate()
    log(
        f"batch gate: needed={needed} ({reason}); "
        f"{since['items_since_green']} Implemented item(s) since last green"
    )
    if not needed and not force:
        return tl.run_batch_gate(
            api_key=api_key,
            dry_run=dry_run,
            no_commit=no_commit,
            no_push=no_push,
            skip=True,
            force=False,
        )

    if dry_run:
        log("dry-run batch gate: would run tier-3a then tier-3 + promote Implemented")
        return EXIT_OK

    if tl.read_controls().get("paused"):
        tl.set_station(phase="paused", role="loop", detail="paused — verify not started")
        return EXIT_WAIT

    events = EventLog(REPO_ROOT, None, kind="task", log=log)
    ctrl = tl.read_controls()
    ctrl["batch_running"] = True
    tl.write_controls(ctrl)
    verify_started = time.time()
    tl.set_station(
        phase="FULL-VERIFY",
        role="loop",
        detail=f"ship gate ({reason}) — tier-3a then full",
        batch={
            "state": "running",
            "needed": True,
            "reason": reason,
            "items_since_green": since["items_since_green"],
            "verify_started_at": verify_started,
        },
    )

    machine_tried: list[str] = ["tier3a", "tier3"]
    stamp = tl.read_batch_gate()
    last_green = str(stamp.get("sha") or "").strip()

    try:
        # Fast unit pass first for early red signal.
        log("BATCH GATE: tier-3a (unit-only)")
        outcome_a = run_verify(REPO_ROOT, log=log, tier="3a")
        if outcome_a is None:
            return EXIT_INFRA if not tl.read_controls().get("paused") else EXIT_WAIT
        if not outcome_a.green:
            log("BATCH GATE: tier-3a RED — escalating")
        else:
            log("BATCH GATE: tier-3a GREEN — running full tier-3")
            outcome_a = run_verify(REPO_ROOT, log=log, tier=3)
    finally:
        ctrl = tl.read_controls()
        ctrl["batch_running"] = False
        tl.write_controls(ctrl)

    outcome = outcome_a
    if outcome is None:
        if tl.read_controls().get("paused"):
            return EXIT_WAIT
        incident = tl.build_batch_incident(
            reason="verify aborted", machine_tried=machine_tried
        )
        tl.write_batch_failure(incident)
        tl.write_batch_halt_bundle(incident, reason="verify aborted")
        tl.notify_cant_ship(incident)
        return EXIT_INFRA

    if outcome.green and outcome.result and verify_is_ship_green(outcome.result):
        return _finish_batch_green(
            outcome.result,
            events=events,
            no_commit=no_commit,
            no_push=no_push,
        )

    # Not ship-green — Mechanic then bisect
    log("batch gate RED — Mechanic retry")
    machine_tried.append("mechanic")
    pre = tl.build_batch_incident(reason="mechanic_pending", machine_tried=list(machine_tried))
    tl.write_batch_failure(pre)
    tl.notify_cant_ship(pre)
    try:
        from cursor_bridge import launch_bridge
        from factory_progress import ProgressTracker
        from mechanic_fix import run_fix_cycle

        client = launch_bridge(workspace=REPO_ROOT)
        try:
            tracker = ProgressTracker(max_spawns=3, max_minutes=20.0)
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

    if tl.read_controls().get("paused"):
        return EXIT_WAIT

    ctrl = tl.read_controls()
    ctrl["batch_running"] = True
    tl.write_controls(ctrl)
    try:
        outcome2 = run_verify(REPO_ROOT, log=log, tier=3)
    finally:
        ctrl = tl.read_controls()
        ctrl["batch_running"] = False
        tl.write_controls(ctrl)

    if outcome2 and outcome2.green and outcome2.result and verify_is_ship_green(outcome2.result):
        return _finish_batch_green(
            outcome2.result,
            events=events,
            no_commit=no_commit,
            no_push=no_push,
        )

    # Still red — bisect then Your-move
    machine_tried.append("bisect")
    bisect_info: dict[str, Any] = {}
    if last_green:
        log(f"batch still red — bisecting {last_green[:12]}..HEAD via tier-3a")
        bisect_info = lightweight_bisect(
            repo_root=REPO_ROOT, last_green_sha=last_green, log=log
        )
        log(bisect_info.get("message") or "bisect complete")

    incident = tl.build_batch_incident(
        reason="still_red",
        machine_tried=machine_tried,
    )
    if bisect_info:
        incident["bisect"] = bisect_info
    tl.write_batch_failure(incident)
    tl.write_batch_halt_bundle(incident, reason="still_red")
    tl.set_station(
        phase="batch",
        role="loop",
        detail="Can't ship — Needs you"
        + (f" · {bisect_info.get('message')}" if bisect_info.get("message") else ""),
        batch={"state": "needs_decision", "needed": True, "reason": "still_red"},
    )
    tl.notify_cant_ship(incident)
    return EXIT_THRASH


def _finish_batch_green(
    ship_verify: dict[str, str],
    *,
    events: Any,
    no_commit: bool,
    no_push: bool,
) -> int:
    sha = tl.head_sha()
    fp = tl.dirty_fingerprint()
    tl.clear_batch_failure()
    try:
        promoted = promote_implemented_to_done(
            ship_verify=ship_verify, repo_root=REPO_ROOT, log=log
        )
        log(f"promoted {len(promoted)} Implemented → Done")
    except ValueError as exc:
        log(f"promote skipped: {exc}")
        promoted = []

    tl.write_batch_gate(
        {
            "sha": sha,
            "green": True,
            "pushed": False,
            "tier": 3,
            "dirty_fingerprint": fp,
            "promoted": promoted,
        }
    )
    tl.set_station(
        phase="batch",
        role="loop",
        detail=f"green @ {(sha or '')[:12]} — {len(promoted)} promoted",
        batch={
            "state": "green",
            "needed": False,
            "reason": "verified",
            "last_green_sha": sha,
            "items_since_green": 0,
        },
    )
    events.record(
        "FULL-VERIFY",
        "loop",
        "verify_end",
        timeline=True,
        mission="ship gate green",
        detail={"promoted": len(promoted)},
    )
    if not no_push and not no_commit:
        import subprocess

        proc = subprocess.run(
            ["git", "push"], cwd=REPO_ROOT, capture_output=True, text=True
        )
        if proc.returncode != 0:
            log(f"git push failed: {proc.stderr.strip()}")
            tl.notify("Forge", "Batch green but push failed")
            return EXIT_RUN_FAILED
        tl.write_batch_gate(
            {
                "sha": sha,
                "green": True,
                "pushed": True,
                "tier": 3,
                "dirty_fingerprint": fp,
                "promoted": promoted,
            }
        )
        log("pushed")
        tl.notify("Forge", "Batch pushed")
    return EXIT_OK


def _run_one_task(decision: dict[str, Any], *, api_key: str, dry_run: bool, no_commit: bool) -> int:
    tid = int(decision["id"])
    tfile = decision["file"]
    log(f"start task-{tid:03d} {tfile}")
    tl.set_station(
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
            dry_run=dry_run,
            no_commit=no_commit,
        )
    except InfraHalt as exc:
        log(f"infra: {exc}")
        tl.notify("Forge", f"Infra halt task-{tid:03d}")
        return EXIT_INFRA
    if not ok:
        halt = (meta or {}).get("halt")
        tl.notify("Forge", f"Task-{tid:03d} Halted ({halt})")
        tl.set_station(
            phase="halted",
            role="pipeline",
            task_id=tid,
            detail=str(halt or "halted"),
        )
        return EXIT_THRASH
    return EXIT_OK


def _run_one_slice(
    decision: dict[str, Any],
    *,
    api_key: str,
    dry_run: bool,
    no_commit: bool,
    no_push: bool,
) -> int:
    sid = int(decision["id"])
    sfile = decision["file"]
    log(f"start slice-{sid:02d} {sfile}")
    tl.set_station(
        phase="SLICE",
        role="pipeline",
        task_id=sid,
        mission=os.path.basename(sfile),
        detail="starting",
    )
    if dry_run:
        log(f"dry-run would run slice pipeline for {sfile}")
        return EXIT_OK
    try:
        ok, _elapsed, _verify, _meta = run_pipeline_slice(
            sid,
            sfile,
            api_key=api_key,
            repo_root=REPO_ROOT,
            log=log,
            do_commit=not no_commit,
            do_push=not no_push,
        )
    except InfraHalt as exc:
        log(f"infra: {exc}")
        return EXIT_INFRA
    except SystemExit as exc:
        code = int(exc.code) if isinstance(exc.code, int) else EXIT_RUN_FAILED
        return code
    if not ok:
        return EXIT_RUN_FAILED
    return EXIT_OK


def wait_while_forge_idle() -> None:
    """Queue clear — stay alive for intake / Full verify & ship."""
    detail = (
        "No work — waiting for intake, Requeue, or Full verify & ship"
    )
    while True:
        tl.write_heartbeat()
        if tl.read_controls().get("paused"):
            tl.wait_while_paused()
            return
        ctrl = tl.apply_control_side_effects(tl.read_controls())
        if ctrl.get("ship_now"):
            return
        since = count_items_since_batch_gate()
        tl.set_station(
            phase="idle",
            role="loop",
            detail=(
                f"{detail} · {since['items_since_green']} Implemented since last green"
            ),
            batch={
                "state": "idle",
                "needed": since["items_since_green"] > 0,
                "items_since_green": since["items_since_green"],
                "reason": "manual ship gate",
            },
        )
        again = query_next_work(repo_root=REPO_ROOT)
        action = again.get("action")
        if action in ("start", "wait", "halt"):
            return
        time.sleep(3)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Unified Forge serial loop")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--max", type=int, default=0, help="Max items (0=unlimited)")
    parser.add_argument("--no-commit", action="store_true")
    parser.add_argument("--no-push", action="store_true")
    parser.add_argument("--skip-batch-gate", action="store_true")
    parser.add_argument("--once", action="store_true", help="Run at most one item then exit")
    parser.add_argument("--lanes", type=int, default=1, help="Reserved (serial only)")
    args, _unknown = parser.parse_known_args(argv)

    api_key = os.environ.get("CURSOR_API_KEY", "")
    if not args.dry_run and not api_key:
        log("CURSOR_API_KEY required (or use --dry-run)")
        return EXIT_STARTUP

    if args.dry_run:
        decision = query_next_work(repo_root=REPO_ROOT)
        action = decision.get("action")
        kind = decision.get("kind") or "none"
        wid = decision.get("id")
        log(
            f"dry-run next= action={action} kind={kind} id={wid} "
            f"file={decision.get('file') or ''}"
        )
        if action == "done":
            since = count_items_since_batch_gate()
            log(
                f"queue empty — {since['items_since_green']} Implemented "
                "awaiting Full verify & ship"
            )
        elif action == "halt":
            log(f"HALT: {decision.get('reason') or decision.get('message')}")
        elif action == "start":
            if kind == "task":
                log(f"dry-run would run rapid task pipeline for task-{int(wid):03d}")
            else:
                log(f"dry-run would run slice pipeline for {decision.get('file')}")
        return EXIT_OK

    tl.set_factory_hot(True)
    tl.write_heartbeat()
    ctrl = tl.read_controls()
    ctrl["running"] = True
    ctrl["paused"] = False
    ctrl["runner_pid"] = os.getpid()
    ctrl["runner_lane"] = "forge"
    if not ctrl.get("started_at"):
        ctrl["started_at"] = time.time()
    tl.write_controls(ctrl)

    ran = 0
    last_key: str | None = None
    try:
        while True:
            tl.write_heartbeat()
            if tl.read_controls().get("paused"):
                tl.wait_while_paused()
                if tl.read_controls().get("paused"):
                    return EXIT_WAIT
            ctrl = tl.apply_control_side_effects(tl.read_controls())
            if tl.park_pause_after_current_at_idle_boundary(ctrl):
                continue

            if ctrl.get("ship_now"):
                ctrl["ship_now"] = False
                tl.write_controls(ctrl)
                code = run_batch_gate_unified(
                    api_key=api_key,
                    dry_run=args.dry_run,
                    no_commit=args.no_commit,
                    no_push=args.no_push,
                    skip=args.skip_batch_gate,
                    force=True,
                )
                if code != EXIT_OK:
                    if args.once:
                        return code
                    tl.wait_while_queue_idle()
                    continue
                if tl.park_pause_after_current():
                    continue

            decision = query_next_work(repo_root=REPO_ROOT)
            action = decision.get("action")
            kind = decision.get("kind") or "none"

            if action == "done":
                since = count_items_since_batch_gate()
                log(
                    f"queue empty — {since['items_since_green']} Implemented "
                    "awaiting Full verify & ship"
                )
                if args.once:
                    return EXIT_OK
                wait_while_forge_idle()
                continue

            if action == "halt":
                msg = decision.get("reason") or decision.get("message") or "halt-and-ask"
                log(f"HALT: {msg}")
                tl.set_station(
                    phase="halted",
                    role="loop",
                    task_id=int(decision["id"]) if decision.get("id") is not None else None,
                    detail=str(msg)[:200],
                )
                tl.notify("Forge", f"Halt — {str(msg)[:100]}")
                if args.once:
                    return EXIT_HALT
                # Park until Floor answers / requeues (controls side effects).
                time.sleep(3)
                continue

            if action == "wait":
                if args.once:
                    return EXIT_WAIT
                # Poll the same unified queue this loop used, not the punch-list
                # queue — otherwise the wait park exits instantly and re-notifies.
                tl.wait_while_next_is_wait(
                    decision, query=lambda: query_next_work(repo_root=REPO_ROOT)
                )
                continue

            if action != "start":
                log(f"unexpected action: {action}")
                return EXIT_RUN_FAILED

            key = f"{kind}:{decision.get('id')}"
            if last_key is not None and key == last_key:
                log(f"no-progress guard: {key} offered twice")
                return EXIT_RUN_FAILED
            last_key = key

            if kind == "task":
                code = _run_one_task(
                    decision, api_key=api_key, dry_run=args.dry_run, no_commit=args.no_commit
                )
            elif kind == "slice":
                code = _run_one_slice(
                    decision,
                    api_key=api_key,
                    dry_run=args.dry_run,
                    no_commit=args.no_commit,
                    no_push=args.no_push,
                )
            else:
                log(f"unknown kind: {kind}")
                return EXIT_RUN_FAILED

            if code == EXIT_INFRA:
                return EXIT_INFRA
            if code not in (EXIT_OK, EXIT_THRASH):
                if args.once:
                    return code
                last_key = None
                continue

            ran += 1
            last_key = None
            if args.max and ran >= args.max:
                log(f"--max {args.max} reached")
                return EXIT_OK
            if args.once:
                return code if code != EXIT_THRASH else EXIT_THRASH
            if tl.park_pause_after_current():
                continue
    finally:
        ctrl = tl.read_controls()
        if ctrl.get("paused"):
            tl.set_station(phase="paused", role="loop", detail="paused — waiting for Resume")
        else:
            tl.clear_station()
        tl.set_factory_hot(False)
        ctrl = dict(ctrl)
        ctrl["running"] = False
        ctrl["batch_running"] = False
        tl.write_controls(ctrl)


if __name__ == "__main__":
    sys.exit(main())
