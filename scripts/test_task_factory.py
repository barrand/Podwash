#!/usr/bin/env python3
"""Unit tests for Forge task queue (next-task, ticket parse, batch helpers)."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest

SCRIPTS = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(SCRIPTS)
sys.path.insert(0, SCRIPTS)

from task_ticket import (  # noqa: E402
    areas_overlap,
    is_scripts_test_id,
    normalize_scripts_test_id,
    parse_task_ticket,
    set_task_status,
    surgical_backend,
    write_task_verify_result,
)


NEXT_TASK = os.path.join(SCRIPTS, "next-task.sh")


def _write_task(dirpath: str, n: int, *, status="Queued", kind="fix", prio="P1", area="Foo.swift", deps="None", verify=None) -> str:
    path = os.path.join(dirpath, f"task-{n:03d}-t.md")
    vr = verify or "VERIFY RESULT: (pending)"
    body = textwrap.dedent(
        f"""\
        # Task {n:03d} — T

        | Field | Value |
        |-------|-------|
        | **ID** | {n:03d} |
        | **Title** | T{n} |
        | **Status** | {status} |
        | **Kind** | {kind} |
        | **Priority** | {prio} |
        | **Area** | {area} |
        | **Crux** | c |

        ## Surgical test scope

        | AC# | Test id | New? |
        |-----|---------|------|
        | 1 | `PodWashTests/FooTests/testBar()` | yes |

        ## Depends on

        - {deps}

        ## Verification record

        ```
        {vr}
        ```
        """
    )
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(body)
    return path


class TestTaskTicket(unittest.TestCase):
    def test_parse_surgical_and_status(self):
        with tempfile.TemporaryDirectory() as td:
            path = _write_task(td, 7)
            t = parse_task_ticket(path)
            self.assertEqual(t.id, 7)
            self.assertEqual(t.priority, "P1")
            self.assertIn("PodWashTests/FooTests/testBar()", t.surgical_tests)
            set_task_status(path, "Done")
            t2 = parse_task_ticket(path)
            self.assertEqual(t2.status, "Done")

    def test_parse_scripts_surgical_slash_and_dotted(self):
        with tempfile.TemporaryDirectory() as td:
            path = os.path.join(td, "task-005-pause.md")
            body = textwrap.dedent(
                """\
                # Task 005 — Pause

                | Field | Value |
                |-------|-------|
                | **ID** | 005 |
                | **Title** | Pause |
                | **Status** | Queued |
                | **Kind** | fix |
                | **Priority** | P1 |
                | **Area** | scripts/task_loop.py |
                | **Crux** | c |

                ## Surgical test scope

                | AC# | Test id | New? |
                |-----|---------|------|
                | 1 | `scripts.test_task_factory.PauseInterruptsInflightTests/test_pause_kills_inflight_verify_child` | yes |
                | 2 | `scripts.test_task_factory.PauseInterruptsInflightTests.test_notify_omits_terminal_bell` | yes |

                ## Verification record

                ```
                VERIFY RESULT: (pending)
                ```
                """
            )
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(body)
            t = parse_task_ticket(path)
            self.assertEqual(
                t.surgical_tests,
                [
                    "scripts.test_task_factory.PauseInterruptsInflightTests.test_pause_kills_inflight_verify_child",
                    "scripts.test_task_factory.PauseInterruptsInflightTests.test_notify_omits_terminal_bell",
                ],
            )
            self.assertTrue(all(is_scripts_test_id(x) for x in t.surgical_tests))
            self.assertEqual(surgical_backend(t.surgical_tests), "scripts")

    def test_surgical_backend_mixed_and_normalize(self):
        self.assertEqual(
            normalize_scripts_test_id("scripts.test_foo.Bar/test_baz"),
            "scripts.test_foo.Bar.test_baz",
        )
        self.assertEqual(surgical_backend([]), "empty")
        self.assertEqual(
            surgical_backend(["PodWashTests/FooTests/testBar()"]),
            "xcode",
        )
        self.assertEqual(
            surgical_backend(
                [
                    "scripts.test_foo.Bar.test_a",
                    "PodWashTests/FooTests/testBar()",
                ]
            ),
            "mixed",
        )

    def test_write_verify_result(self):
        with tempfile.TemporaryDirectory() as td:
            path = _write_task(td, 2)
            write_task_verify_result(
                path,
                {
                    "exit": "0",
                    "total": "1",
                    "passed": "1",
                    "failed": "0",
                    "skipped": "0",
                    "filtered": "1",
                    "tier": "2",
                    "class": "tests",
                    "bundle": "x.xcresult",
                },
            )
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
            self.assertIn("VERIFY RESULT: exit=0", text)
            self.assertIn("filtered=1", text)

    def test_areas_overlap(self):
        self.assertTrue(areas_overlap("PodWash/Foo.swift", "Foo.swift, Bar.swift"))
        self.assertFalse(areas_overlap("A.swift", "B.swift"))


class TestScriptsSurgicalVerify(unittest.TestCase):
    def test_run_scripts_surgical_verify_green(self):
        from rapid_task_pipeline import run_scripts_surgical_verify

        # Existing factory test that should always be importable/green
        outcome = run_scripts_surgical_verify(
            REPO,
            ["scripts.test_task_factory.TestNotifyNoBell.test_notify_omits_terminal_bell"],
            log=lambda _m: None,
        )
        self.assertTrue(outcome.green, outcome.failures)
        self.assertEqual(outcome.result["class"], "unittest")
        self.assertEqual(outcome.result["exit"], "0")
        self.assertEqual(outcome.result["filtered"], "1")

    def test_run_scripts_surgical_verify_missing_red(self):
        from rapid_task_pipeline import run_scripts_surgical_verify

        outcome = run_scripts_surgical_verify(
            REPO,
            ["scripts.test_task_factory.NoSuchClass.test_missing"],
            log=lambda _m: None,
        )
        self.assertFalse(outcome.green)
        self.assertEqual(outcome.result["exit"], "1")
        self.assertTrue(outcome.failures)


class TestNextTask(unittest.TestCase):
    def test_priority_order(self):
        with tempfile.TemporaryDirectory() as td:
            _write_task(td, 1, prio="P2")
            _write_task(td, 2, prio="P1")
            env = {**os.environ, "PODWASH_TASKS_DIR": td}
            proc = subprocess.run(
                [NEXT_TASK, "--json"], capture_output=True, text=True, env=env
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            data = json.loads(proc.stdout)
            self.assertEqual(data["action"], "start")
            self.assertEqual(data["id"], 2)
            self.assertEqual(data["priority"], "P1")

    def test_done_accepts_filtered_tier2(self):
        with tempfile.TemporaryDirectory() as td:
            _write_task(
                td,
                1,
                status="Done",
                verify="VERIFY RESULT: exit=0 total=1 passed=1 failed=0 skipped=0 filtered=1 tier=2",
            )
            env = {**os.environ, "PODWASH_TASKS_DIR": td}
            proc = subprocess.run(
                [NEXT_TASK, "--json"], capture_output=True, text=True, env=env
            )
            data = json.loads(proc.stdout)
            self.assertEqual(data["action"], "done")

    def test_skips_needs_human(self):
        with tempfile.TemporaryDirectory() as td:
            _write_task(td, 1, kind="needs-human", status="Needs-human")
            _write_task(td, 2, prio="P2")
            env = {**os.environ, "PODWASH_TASKS_DIR": td}
            proc = subprocess.run(
                [NEXT_TASK, "--json"], capture_output=True, text=True, env=env
            )
            data = json.loads(proc.stdout)
            self.assertEqual(data["id"], 2)

    def test_reclaims_in_progress_before_queued(self):
        with tempfile.TemporaryDirectory() as td:
            _write_task(td, 1, status="In Progress", prio="P2")
            _write_task(td, 2, status="Queued", prio="P1")
            env = {**os.environ, "PODWASH_TASKS_DIR": td}
            proc = subprocess.run(
                [NEXT_TASK, "--json"], capture_output=True, text=True, env=env
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            data = json.loads(proc.stdout)
            self.assertEqual(data["action"], "start")
            self.assertEqual(data["id"], 1)

    def test_in_progress_blocks_done_when_nothing_queued(self):
        with tempfile.TemporaryDirectory() as td:
            _write_task(td, 1, status="In Progress", prio="P1")
            env = {**os.environ, "PODWASH_TASKS_DIR": td}
            proc = subprocess.run(
                [NEXT_TASK, "--json"], capture_output=True, text=True, env=env
            )
            data = json.loads(proc.stdout)
            self.assertEqual(data["action"], "start")
            self.assertEqual(data["id"], 1)

    def test_halted_only_parks_not_done(self):
        with tempfile.TemporaryDirectory() as td:
            _write_task(td, 5, status="Halted", prio="P1")
            env = {**os.environ, "PODWASH_TASKS_DIR": td}
            proc = subprocess.run(
                [NEXT_TASK, "--json"], capture_output=True, text=True, env=env
            )
            data = json.loads(proc.stdout)
            self.assertEqual(data["action"], "wait")
            self.assertIn("Halted", data["message"])
            self.assertIn("Requeue", data["message"])
            self.assertNotEqual(data["action"], "done")


class TestNotifyNoBell(unittest.TestCase):
    def test_notify_omits_terminal_bell(self):
        from io import StringIO
        from unittest import mock

        import task_loop

        buf = StringIO()
        with mock.patch.object(task_loop.sys, "stdout", buf):
            with mock.patch.object(task_loop.subprocess, "run") as run:
                task_loop.notify("Forge", "test body")
        self.assertNotIn("\a", buf.getvalue())
        run.assert_called_once()
        argv = run.call_args[0][0]
        self.assertEqual(argv[0], "osascript")


class TestIdleDrainSafety(unittest.TestCase):
    def test_list_in_progress_task_ids(self):
        import task_loop as tl

        with tempfile.TemporaryDirectory() as td:
            _write_task(td, 1, status="In Progress")
            _write_task(td, 2, status="Queued")
            _write_task(td, 3, status="Halted")
            ids = tl.list_in_progress_task_ids(tasks_dir=td)
            self.assertEqual(ids, [1])


class TestTaskDispatch(unittest.TestCase):
    def test_disjoint_scheduler(self):
        from task_dispatch import can_schedule, pick_parallel_batch

        in_flight = [{"id": 1, "area": "Player.swift"}]
        self.assertFalse(can_schedule("Player.swift", in_flight))
        self.assertTrue(can_schedule("Library.swift", in_flight))
        batch = pick_parallel_batch(
            [
                {"id": 1, "area": "A.swift"},
                {"id": 2, "area": "A.swift"},
                {"id": 3, "area": "B.swift"},
            ],
            max_lanes=2,
        )
        self.assertEqual([b["id"] for b in batch], [1, 3])


class TestForgeLoopPick(unittest.TestCase):
    def test_dry_run_pick(self):
        proc = subprocess.run(
            [sys.executable, os.path.join(SCRIPTS, "forge_loop.py"), "--dry-run"],
            cwd=REPO,
            capture_output=True,
            text=True,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr + proc.stdout)
        self.assertIn("dry-run next=", proc.stdout)


class TestBatchControls(unittest.TestCase):
    def test_default_controls_roundtrip(self):
        from task_loop import default_controls, read_controls, write_controls

        with tempfile.TemporaryDirectory() as td:
            # Point controls at temp by monkeypatching path
            import task_loop as tl

            old = tl.CONTROLS_PATH
            tl.CONTROLS_PATH = os.path.join(td, "controls.json")
            try:
                c = default_controls()
                c["ship_now"] = True
                write_controls(c)
                back = read_controls()
                self.assertTrue(back["ship_now"])
            finally:
                tl.CONTROLS_PATH = old


class TestBatchNeeded(unittest.TestCase):
    def test_force_always_needed(self):
        from task_loop import batch_needed

        needed, reason = batch_needed(force=True)
        self.assertTrue(needed)
        self.assertEqual(reason, "ship_now")

    def test_never_verified(self):
        from task_loop import batch_needed

        with tempfile.TemporaryDirectory() as td:
            stamp = os.path.join(td, "batch-gate.json")
            needed, reason = batch_needed(force=False, stamp_path=stamp, repo_root=REPO)
            self.assertTrue(needed)
            self.assertEqual(reason, "never verified")

    def test_same_sha_clean_not_needed(self):
        import task_loop as tl

        with tempfile.TemporaryDirectory() as td:
            stamp = os.path.join(td, "batch-gate.json")
            sha = tl.head_sha(repo_root=REPO)
            self.assertTrue(sha)
            tl.write_batch_gate({"sha": sha, "green": True}, path=stamp)
            # If the real worktree is dirty, needed will be dirty tree — that's ok;
            # stub worktree_dirty for a deterministic assert.
            old_dirty = tl.worktree_dirty
            try:
                tl.worktree_dirty = lambda repo_root=None: False  # type: ignore[assignment]
                needed, reason = tl.batch_needed(force=False, stamp_path=stamp, repo_root=REPO)
                self.assertFalse(needed)
                self.assertEqual(reason, "not needed")
            finally:
                tl.worktree_dirty = old_dirty

    def test_head_moved(self):
        import task_loop as tl

        with tempfile.TemporaryDirectory() as td:
            stamp = os.path.join(td, "batch-gate.json")
            tl.write_batch_gate({"sha": "deadbeef" * 5, "green": True}, path=stamp)
            old_dirty = tl.worktree_dirty
            try:
                tl.worktree_dirty = lambda repo_root=None: False  # type: ignore[assignment]
                needed, reason = tl.batch_needed(force=False, stamp_path=stamp, repo_root=REPO)
                self.assertTrue(needed)
                self.assertEqual(reason, "HEAD moved")
            finally:
                tl.worktree_dirty = old_dirty

    def test_dirty_tree(self):
        import task_loop as tl

        with tempfile.TemporaryDirectory() as td:
            stamp = os.path.join(td, "batch-gate.json")
            sha = tl.head_sha(repo_root=REPO)
            tl.write_batch_gate({"sha": sha, "green": True}, path=stamp)
            old_dirty = tl.worktree_dirty
            try:
                tl.worktree_dirty = lambda repo_root=None: True  # type: ignore[assignment]
                needed, reason = tl.batch_needed(force=False, stamp_path=stamp, repo_root=REPO)
                self.assertTrue(needed)
                self.assertEqual(reason, "dirty tree")
            finally:
                tl.worktree_dirty = old_dirty

    def test_station_roundtrip(self):
        import task_loop as tl

        with tempfile.TemporaryDirectory() as td:
            path = os.path.join(td, "station.json")
            tl.set_station(
                phase="TIER2-VERIFY",
                role="loop",
                task_id=1,
                mission="Download fix",
                detail="surgical tests",
                path=path,
            )
            back = tl.read_station(path=path)
            self.assertEqual(back["phase"], "TIER2-VERIFY")
            self.assertEqual(back["task_id"], 1)
            tl.clear_station(path=path)
            self.assertEqual(tl.read_station(path=path), {})


if __name__ == "__main__":
    unittest.main()
