#!/usr/bin/env python3
"""Unified Forge loop (Sequel 1.5b) — tasks + slices, slice monopolizes.

When a slice is In Progress (or selected next by priority), tasks wait.
Otherwise delegates to task_loop / slice_loop pipelines.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO_ROOT, "scripts"))

EXIT_OK = 0
EXIT_STARTUP = 1
EXIT_RUN_FAILED = 2
EXIT_WAIT = 3
EXIT_HALT = 4
EXIT_THRASH = 5
EXIT_INFRA = 6


def log(msg: str) -> None:
    print(f"[forge-loop] {msg}", flush=True)


def _slice_in_progress() -> bool:
    slices_dir = os.path.join(REPO_ROOT, "docs", "slices")
    if not os.path.isdir(slices_dir):
        return False
    for name in os.listdir(slices_dir):
        if not name.startswith("slice-") or not name.endswith(".md") or name.endswith("-ux.md"):
            continue
        path = os.path.join(slices_dir, name)
        try:
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
        except OSError:
            continue
        if "| **Status** |" in text and "In Progress" in text:
            # crude but effective for monopolize
            for line in text.splitlines():
                if "| **Status** |" in line and "In Progress" in line:
                    return True
    return False


def _next_slice() -> dict:
    proc = subprocess.run(
        [os.path.join(REPO_ROOT, "scripts", "next-slice.sh"), "--json"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        return {"action": "done"}
    return json.loads(proc.stdout.strip() or "{}")


def _next_task() -> dict:
    proc = subprocess.run(
        [os.path.join(REPO_ROOT, "scripts", "next-task.sh"), "--json"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        return {"action": "done"}
    return json.loads(proc.stdout.strip() or "{}")


def _prio_rank(p: str) -> int:
    return {"P0": 0, "P1": 1, "P2": 2, "P3": 3}.get(p, 2)


def pick_work() -> tuple[str, dict]:
    """Return ('task'|'slice'|'done'|'wait'|'halt', decision)."""
    if _slice_in_progress():
        log("slice monopolize — tasks wait")
        return "wait", {"action": "wait", "message": "slice in progress"}

    slice_d = _next_slice()
    task_d = _next_task()

    # Features default P3; only start slice if action=start and no higher-prio task
    if task_d.get("action") == "start" and slice_d.get("action") == "start":
        tp = _prio_rank(task_d.get("priority") or "P1")
        # slices treated as P3 unless we add priority later
        if tp <= 2:
            return "task", task_d
        return "slice", slice_d
    if task_d.get("action") == "start":
        return "task", task_d
    if slice_d.get("action") == "start":
        return "slice", slice_d
    if slice_d.get("action") == "halt":
        return "halt", slice_d
    if task_d.get("action") == "wait" or slice_d.get("action") == "wait":
        return "wait", task_d if task_d.get("action") == "wait" else slice_d
    return "done", {"action": "done"}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Unified Forge loop")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--max", type=int, default=0)
    parser.add_argument("--no-commit", action="store_true")
    parser.add_argument("--no-push", action="store_true")
    parser.add_argument("--skip-batch-gate", action="store_true")
    parser.add_argument("--lanes", type=int, default=1, help="Task parallel lanes (Phase 2)")
    args, unknown = parser.parse_known_args(argv)

    kind, decision = pick_work()
    if args.dry_run:
        log(f"dry-run next={kind} decision={json.dumps(decision)}")
        return EXIT_OK

    if kind == "done":
        # Drain tasks batch via task_loop once
        import task_loop as tl

        return tl.main(
            [
                *(["--no-commit"] if args.no_commit else []),
                *(["--no-push"] if args.no_push else []),
                *(["--skip-batch-gate"] if args.skip_batch_gate else []),
            ]
        )
    if kind == "halt":
        log(decision.get("reason") or "halt")
        return EXIT_HALT
    if kind == "wait":
        log(decision.get("message") or "wait")
        return EXIT_WAIT
    if kind == "task":
        if args.lanes > 1:
            from task_dispatch import pick_parallel_batch

            log(f"lanes={args.lanes} (serial execute for now; batch pick logged)")
            batch = pick_parallel_batch(
                [
                    {
                        "id": decision.get("id"),
                        "area": decision.get("area") or "",
                    }
                ],
                max_lanes=args.lanes,
            )
            log(f"dispatch batch={batch}")
        import task_loop as tl

        return tl.main(
            [
                "--once",
                *(["--no-commit"] if args.no_commit else []),
                *(["--no-push"] if args.no_push else []),
                *(["--skip-batch-gate"] if args.skip_batch_gate else []),
            ]
        )
    if kind == "slice":
        # Delegate one slice to slice_loop --max 1
        env = os.environ.copy()
        env["PODWASH_FORGE_LOOP"] = "slice_loop"
        cmd = [
            sys.executable,
            os.path.join(REPO_ROOT, "scripts", "slice_loop.py"),
            "--max",
            "1",
            *unknown,
        ]
        if args.dry_run:
            cmd.append("--dry-run")
        log(f"dispatch slice: {' '.join(cmd)}")
        return subprocess.run(cmd, cwd=REPO_ROOT, env=env).returncode

    return EXIT_RUN_FAILED


if __name__ == "__main__":
    sys.exit(main())
