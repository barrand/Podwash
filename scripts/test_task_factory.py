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
from unittest import mock

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

    def test_expand_surgical_to_class(self):
        from task_ticket import expand_surgical_to_class

        expanded, expansions = expand_surgical_to_class(
            [
                "PodWashTests/ProductionAnalysisWiringTests/testPlayEpisodeDownloadsInsteadOfStreamingWhenChannelCleaningOn()",
                "PodWashTests/ProductionAnalysisWiringTests/testPlayEpisodeStreamsWhenChannelCleaningOffAndNoLocalFile()",
                "PodWashUITests/LibraryUITests/testTapEpisodeDownloadsBeforePlayWhenChannelCleaningOn()",
                "PodWashTests/AlreadyClass",
                "scripts.test_foo.Bar.test_a",
            ]
        )
        self.assertEqual(
            expanded,
            [
                "PodWashTests/ProductionAnalysisWiringTests",
                "PodWashUITests/LibraryUITests",
                "PodWashTests/AlreadyClass",
                "scripts.test_foo.Bar.test_a",
            ],
        )
        self.assertEqual(len(expansions), 3)
        self.assertTrue(
            all(dst == "PodWashTests/ProductionAnalysisWiringTests" or dst == "PodWashUITests/LibraryUITests" for _, dst in expansions)
        )

    def test_scope_miss_sibling_not_covered_by_method_surgical(self):
        from task_ticket import (
            batch_failures_are_scope_miss,
            collect_done_surgical_tests,
            test_id_in_surgical_scope,
        )

        surgical = [
            "PodWashTests/ProductionAnalysisWiringTests/testPlayEpisodeDownloadsInsteadOfStreamingWhenChannelCleaningOn()",
            "PodWashTests/ProductionAnalysisWiringTests/testPlayEpisodeAnalyzesAfterDownloadCompletesWhenChannelCleaningOn()",
        ]
        sibling = (
            "PodWashTests/ProductionAnalysisWiringTests/"
            "testStreamingURLSkipsAnalysisEvenWhenCleaningOn()"
        )
        self.assertFalse(test_id_in_surgical_scope(sibling, surgical))
        self.assertTrue(
            test_id_in_surgical_scope(
                surgical[0],
                surgical,
            )
        )
        # Explicit class-scoped entry covers siblings
        self.assertTrue(
            test_id_in_surgical_scope(
                sibling,
                ["PodWashTests/ProductionAnalysisWiringTests"],
            )
        )
        self.assertTrue(batch_failures_are_scope_miss([sibling], surgical))
        self.assertFalse(batch_failures_are_scope_miss([surgical[0]], surgical))

        with tempfile.TemporaryDirectory() as td:
            path = _write_task(td, 12, status="Done")
            # Replace surgical table with task-012-like methods
            with open(path, encoding="utf-8") as fh:
                body = fh.read()
            body = body.replace(
                "`PodWashTests/FooTests/testBar()`",
                "`PodWashTests/ProductionAnalysisWiringTests/testPlayEpisodeDownloadsInsteadOfStreamingWhenChannelCleaningOn()`",
            )
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(body)
            done = collect_done_surgical_tests(td)
            self.assertTrue(batch_failures_are_scope_miss([sibling], done))

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

    def test_none_orthogonal_prose_is_not_a_dependency(self):
        """'None (orthogonal to task-016)' must not invent a dep and deadlock the queue."""
        with tempfile.TemporaryDirectory() as td:
            _write_task(
                td,
                15,
                prio="P1",
                deps="None (orthogonal to task-012; may land in parallel)",
            )
            _write_task(
                td,
                16,
                prio="P2",
                deps="None (orthogonal to task-015)",
            )
            env = {**os.environ, "PODWASH_TASKS_DIR": td}
            proc = subprocess.run(
                [NEXT_TASK, "--json"], capture_output=True, text=True, env=env
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            data = json.loads(proc.stdout)
            self.assertEqual(data["action"], "start")
            self.assertEqual(data["id"], 15)

    def test_explicit_task_dep_blocks_until_done(self):
        with tempfile.TemporaryDirectory() as td:
            _write_task(td, 7, status="Queued", prio="P2")
            _write_task(td, 12, prio="P1", deps="Task 007 (Done) — device download")
            env = {**os.environ, "PODWASH_TASKS_DIR": td}
            proc = subprocess.run(
                [NEXT_TASK, "--json"], capture_output=True, text=True, env=env
            )
            data = json.loads(proc.stdout)
            # P1 is blocked; P2 007 is ready and must start (not wait forever on 12).
            self.assertEqual(data["action"], "start")
            self.assertEqual(data["id"], 7)

    def test_cyclic_deps_are_ignored_not_deadlocked(self):
        """A↔B must not leave In Progress empty forever."""
        with tempfile.TemporaryDirectory() as td:
            _write_task(td, 15, prio="P1", deps="Task 016")
            _write_task(td, 16, prio="P2", deps="Task 015")
            env = {**os.environ, "PODWASH_TASKS_DIR": td}
            proc = subprocess.run(
                [NEXT_TASK, "--json"], capture_output=True, text=True, env=env
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            data = json.loads(proc.stdout)
            self.assertEqual(data["action"], "start")
            self.assertEqual(data["id"], 15)  # higher priority wins once cycle is broken
            self.assertIn("cyclic", proc.stderr.lower())


class PauseInterruptsInflightTests(unittest.TestCase):
    """Task 005 — Pause must interrupt in-flight verify, not only the next loop tick."""

    def setUp(self) -> None:
        import task_loop as tl

        self.tl = tl
        self._td = tempfile.TemporaryDirectory()
        self._td.__enter__()
        self.controls_path = os.path.join(self._td.name, "controls.json")
        self.station_path = os.path.join(self._td.name, "station.json")
        self._orig_controls = tl.CONTROLS_PATH
        self._orig_station = tl.STATION_PATH
        tl.CONTROLS_PATH = self.controls_path
        tl.STATION_PATH = self.station_path
        tl.write_controls(tl.default_controls())

    def tearDown(self) -> None:
        self.tl.CONTROLS_PATH = self._orig_controls
        self.tl.STATION_PATH = self._orig_station
        self._td.__exit__(None, None, None)

    def _apply_pause_interrupt(self) -> None:
        ctrl = self.tl.read_controls()
        ctrl["paused"] = True
        self.tl.write_controls(ctrl)
        self.tl.interrupt_inflight_on_pause()

    def test_pause_kills_inflight_verify_child(self) -> None:
        import slice_pipeline as sp

        proc = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(300)"],
            start_new_session=True,
        )
        try:
            ctrl = self.tl.default_controls()
            ctrl["batch_running"] = True
            self.tl.write_controls(ctrl)
            sp._ACTIVE_VERIFY_PROC = proc  # noqa: SLF001 — contract for pause interrupt

            self._apply_pause_interrupt()

            proc.wait(timeout=5)
            self.assertIsNotNone(proc.poll())
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait(timeout=2)

    def test_pause_clears_batch_running_and_station(self) -> None:
        self.tl.set_station(
            phase="FULL-VERIFY",
            role="loop",
            detail="tier-3 full suite (ship_now) — running",
            batch={"state": "running", "needed": True, "reason": "ship_now"},
        )
        ctrl = self.tl.default_controls()
        ctrl["batch_running"] = True
        self.tl.write_controls(ctrl)

        self._apply_pause_interrupt()

        back = self.tl.read_controls()
        self.assertTrue(back["paused"])
        self.assertFalse(back["batch_running"])
        station = self.tl.read_station()
        self.assertEqual(station.get("phase"), "paused")

    def test_paused_loop_does_not_start_verify(self) -> None:
        from unittest import mock

        ctrl = self.tl.default_controls()
        ctrl["paused"] = True
        self.tl.write_controls(ctrl)

        verify_calls: list[int] = []
        with mock.patch("slice_pipeline.run_verify", side_effect=lambda *a, **k: verify_calls.append(1)):
            with mock.patch.object(self.tl, "batch_needed", return_value=(True, "ship_now")):
                with mock.patch.object(self.tl, "head_sha", return_value="abc123"):
                    code = self.tl.run_batch_gate(
                        api_key="k",
                        dry_run=False,
                        no_commit=True,
                        no_push=True,
                        skip=False,
                        force=True,
                    )

        self.assertEqual(verify_calls, [])
        self.assertFalse(self.tl.read_controls().get("batch_running"))
        self.assertEqual(code, self.tl.EXIT_WAIT)

    def test_notify_omits_terminal_bell(self) -> None:
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


class PauseAfterCurrentTests(unittest.TestCase):
    """Task 013 — Pause after current arms at boundary without mid-ticket interrupt."""

    def setUp(self) -> None:
        from pathlib import Path

        import factory_floor.server as floor
        import task_loop as tl

        self.tl = tl
        self.floor = floor
        self._td = tempfile.TemporaryDirectory()
        self._td.__enter__()
        self.controls_path = os.path.join(self._td.name, "controls.json")
        self.station_path = os.path.join(self._td.name, "station.json")
        self._orig_tl_controls = tl.CONTROLS_PATH
        self._orig_tl_station = tl.STATION_PATH
        self._orig_floor_controls = floor.CONTROLS
        tl.CONTROLS_PATH = self.controls_path
        tl.STATION_PATH = self.station_path
        floor.CONTROLS = Path(self.controls_path)
        tl.write_controls(tl.default_controls())

    def tearDown(self) -> None:
        self.tl.CONTROLS_PATH = self._orig_tl_controls
        self.tl.STATION_PATH = self._orig_tl_station
        self.floor.CONTROLS = self._orig_floor_controls
        self._td.__exit__(None, None, None)

    def test_api_arms_flag_without_pausing(self) -> None:
        from unittest import mock

        with mock.patch("task_loop.interrupt_inflight_on_pause") as intr:
            result = self.floor.apply_control("pause_after_current", {})

        back = self.tl.read_controls()
        self.assertTrue(back.get("pause_after_current"))
        self.assertFalse(back.get("paused"))
        intr.assert_not_called()
        self.assertTrue(result.get("ok"))

    def test_pauses_after_task_done_before_next_pick(self) -> None:
        from unittest import mock

        with tempfile.TemporaryDirectory() as tasks_td:
            task_path = _write_task(tasks_td, 13, status="Queued")
            picks: list[int] = []

            def fake_query_next() -> dict:
                picks.append(1)
                if len(picks) == 1:
                    return {"action": "start", "id": 13, "file": task_path}
                return {"action": "start", "id": 99, "file": task_path}

            def fake_pipeline(*_a, **_k):
                mid = self.tl.read_controls()
                self.assertFalse(mid.get("paused"))
                mid["pause_after_current"] = True
                self.tl.write_controls(mid)
                armed = self.tl.read_controls()
                self.assertTrue(armed.get("pause_after_current"))
                self.assertFalse(armed.get("paused"))
                return True, {}

            with mock.patch.object(self.tl, "query_next", side_effect=fake_query_next):
                with mock.patch.object(self.tl, "run_task_pipeline", side_effect=fake_pipeline):
                    with mock.patch.object(self.tl, "wait_while_paused"):
                        with mock.patch.object(
                            self.tl, "batch_needed", return_value=(False, "not needed")
                        ):
                            self.tl.main(["--dry-run"])

        final = self.tl.read_controls()
        self.assertTrue(final.get("paused"))
        self.assertFalse(final.get("pause_after_current"))
        self.assertEqual(picks, [1])
        self.assertEqual(self.tl.read_station().get("phase"), "paused")

    def test_pauses_after_inflight_batch_before_next_work(self) -> None:
        from unittest import mock

        ctrl = self.tl.read_controls()
        ctrl["ship_now"] = True
        ctrl["pause_after_current"] = True
        ctrl["batch_running"] = True
        self.tl.write_controls(ctrl)

        def fake_batch_gate(**_k):
            mid = self.tl.read_controls()
            self.assertFalse(mid.get("paused"))
            self.assertTrue(mid.get("pause_after_current"))
            mid["batch_running"] = False
            self.tl.write_controls(mid)
            return self.tl.EXIT_OK

        qn_calls: list[int] = []
        with mock.patch.object(self.tl, "run_batch_gate", side_effect=fake_batch_gate):
            with mock.patch.object(
                self.tl,
                "query_next",
                side_effect=lambda: qn_calls.append(1) or {"action": "done"},
            ):
                with mock.patch.object(self.tl, "wait_while_paused"):
                    self.tl.main(["--dry-run"])

        self.assertEqual(qn_calls, [])
        final = self.tl.read_controls()
        self.assertTrue(final.get("paused"))
        self.assertFalse(final.get("pause_after_current"))

    def test_idle_arm_pauses_at_next_boundary(self) -> None:
        from unittest import mock

        ctrl = self.tl.read_controls()
        ctrl["pause_after_current"] = True
        self.tl.write_controls(ctrl)

        qn_calls: list[int] = []
        batch_calls: list[int] = []
        with mock.patch.object(
            self.tl,
            "query_next",
            side_effect=lambda: qn_calls.append(1) or {"action": "done"},
        ):
            with mock.patch.object(
                self.tl,
                "run_batch_gate",
                side_effect=lambda **_k: batch_calls.append(1) or self.tl.EXIT_OK,
            ):
                with mock.patch.object(self.tl, "wait_while_paused"):
                    self.tl.main(["--dry-run"])

        self.assertEqual(qn_calls, [])
        self.assertEqual(batch_calls, [])
        final = self.tl.read_controls()
        self.assertTrue(final.get("paused"))
        self.assertFalse(final.get("pause_after_current"))

    def test_resume_clears_arm_and_pause(self) -> None:
        ctrl = self.tl.read_controls()
        ctrl["paused"] = True
        ctrl["pause_after_current"] = True
        self.tl.write_controls(ctrl)

        self.floor.apply_control("resume", {})

        back = self.tl.read_controls()
        self.assertFalse(back.get("paused"))
        self.assertFalse(back.get("pause_after_current"))

    def test_immediate_pause_clears_arm(self) -> None:
        from unittest import mock

        ctrl = self.tl.read_controls()
        ctrl["pause_after_current"] = True
        self.tl.write_controls(ctrl)

        with mock.patch("task_loop.interrupt_inflight_on_pause") as intr:
            self.floor.apply_control("pause", {})

        back = self.tl.read_controls()
        self.assertTrue(back.get("paused"))
        self.assertFalse(back.get("pause_after_current"))
        intr.assert_called_once()

    def test_board_snapshot_shows_armed_indicator(self) -> None:
        activity = self.floor._activity_snapshot(
            ctrl={
                **self.floor._default_controls(),
                "running": True,
                "paused": False,
                "pause_after_current": True,
                "batch_running": False,
            },
            station={"phase": "task", "role": "pipeline", "detail": "task-013 running"},
            batch={"state": "idle", "reason": "not needed", "verify_running": False},
            tasks=[{"id": "013", "status": "In Progress", "title": "Pause after current"}],
            events=[],
            factory_hot=True,
            runner_alive=True,
        )
        blob = " ".join(
            str(activity.get(k) or "")
            for k in ("headline", "detail", "next", "mode")
        ).lower()
        self.assertIn("pause after current", blob)
        self.assertNotEqual(activity.get("mode"), "paused")


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


class TestWaitKeepsRunnerAlive(unittest.TestCase):
    """Halted/empty-queue wait must poll, not EXIT_WAIT (Floor 'stuck then stopped')."""

    def setUp(self) -> None:
        import task_loop as tl

        self.tl = tl
        self._td = tempfile.TemporaryDirectory()
        self._td.__enter__()
        self.controls_path = os.path.join(self._td.name, "controls.json")
        self.station_path = os.path.join(self._td.name, "station.json")
        self.heartbeat_path = os.path.join(self._td.name, "heartbeat.json")
        self._orig = (
            tl.CONTROLS_PATH,
            tl.STATION_PATH,
            tl.HEARTBEAT_PATH,
        )
        tl.CONTROLS_PATH = self.controls_path
        tl.STATION_PATH = self.station_path
        tl.HEARTBEAT_PATH = self.heartbeat_path
        tl.write_controls(tl.default_controls())

    def tearDown(self) -> None:
        tl = self.tl
        tl.CONTROLS_PATH, tl.STATION_PATH, tl.HEARTBEAT_PATH = self._orig
        self._td.__exit__(None, None, None)

    def test_wait_while_next_is_wait_exits_when_start(self) -> None:
        from unittest import mock

        calls = {"n": 0}

        def fake_next():
            calls["n"] += 1
            if calls["n"] < 2:
                return {
                    "action": "wait",
                    "id": 11,
                    "message": "Halted task(s) 11 need Requeue",
                }
            return {"action": "start", "id": 15, "file": "x.md"}

        with mock.patch.object(self.tl, "query_next", side_effect=fake_next):
            with mock.patch.object(self.tl, "notify"):
                with mock.patch.object(self.tl.time, "sleep"):
                    self.tl.wait_while_next_is_wait(
                        {
                            "action": "wait",
                            "id": 11,
                            "message": "Halted task(s) 11 need Requeue",
                        }
                    )
        self.assertGreaterEqual(calls["n"], 2)
        station = self.tl.read_station()
        self.assertEqual(station.get("phase"), "waiting")

    def test_wait_while_next_is_wait_polls_custom_query_and_notifies_once(self) -> None:
        """Forge loop passes its unified queue — the park must poll THAT queue,
        stay parked while it says wait, and fire exactly one notification
        (regression: polling next-task made this exit instantly every second)."""
        from unittest import mock

        calls = {"n": 0}

        def unified_next():
            calls["n"] += 1
            if calls["n"] < 4:
                return {"action": "wait", "id": 17, "message": "Slice 17 waiting"}
            return {"action": "start", "id": 18, "file": "y.md"}

        with mock.patch.object(self.tl, "query_next") as punch_list:
            with mock.patch.object(self.tl, "notify") as notify:
                with mock.patch.object(self.tl.time, "sleep"):
                    self.tl.wait_while_next_is_wait(
                        {"action": "wait", "id": 17, "message": "Slice 17 waiting"},
                        query=unified_next,
                    )
        punch_list.assert_not_called()
        self.assertEqual(calls["n"], 4)
        notify.assert_called_once()

    def test_wait_while_next_is_wait_exits_on_ship_now(self) -> None:
        from unittest import mock

        ctrl = self.tl.default_controls()
        ctrl["ship_now"] = True
        self.tl.write_controls(ctrl)

        with mock.patch.object(
            self.tl,
            "query_next",
            return_value={"action": "wait", "id": 11, "message": "Halted"},
        ) as qn:
            with mock.patch.object(self.tl, "notify"):
                with mock.patch.object(self.tl.time, "sleep"):
                    self.tl.wait_while_next_is_wait(
                        {"action": "wait", "id": 11, "message": "Halted"}
                    )
        qn.assert_not_called()

    def test_main_once_still_exits_on_wait(self) -> None:
        from unittest import mock

        with mock.patch.object(
            self.tl,
            "query_next",
            return_value={
                "action": "wait",
                "id": 11,
                "message": "Halted task(s) 11 need Requeue",
            },
        ):
            with mock.patch.object(self.tl, "set_factory_hot"):
                with mock.patch.object(self.tl, "notify"):
                    with mock.patch.dict(os.environ, {"CURSOR_API_KEY": "k"}):
                        code = self.tl.main(["--once", "--no-commit", "--no-push"])
        self.assertEqual(code, self.tl.EXIT_WAIT)


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
            tl.write_batch_gate({"sha": sha, "green": True, "dirty_fingerprint": ""}, path=stamp)
            old_fp = tl.dirty_fingerprint
            try:
                tl.dirty_fingerprint = lambda repo_root=None: ""  # type: ignore[assignment]
                needed, reason = tl.batch_needed(force=False, stamp_path=stamp, repo_root=REPO)
                self.assertFalse(needed)
                self.assertEqual(reason, "not needed")
            finally:
                tl.dirty_fingerprint = old_fp

    def test_head_moved(self):
        import task_loop as tl

        with tempfile.TemporaryDirectory() as td:
            stamp = os.path.join(td, "batch-gate.json")
            tl.write_batch_gate({"sha": "deadbeef" * 5, "green": True}, path=stamp)
            old_fp = tl.dirty_fingerprint
            try:
                tl.dirty_fingerprint = lambda repo_root=None: ""  # type: ignore[assignment]
                needed, reason = tl.batch_needed(force=False, stamp_path=stamp, repo_root=REPO)
                self.assertTrue(needed)
                self.assertEqual(reason, "HEAD moved")
            finally:
                tl.dirty_fingerprint = old_fp

    def test_dirty_tree(self):
        import task_loop as tl

        with tempfile.TemporaryDirectory() as td:
            stamp = os.path.join(td, "batch-gate.json")
            sha = tl.head_sha(repo_root=REPO)
            tl.write_batch_gate({"sha": sha, "green": True, "dirty_fingerprint": ""}, path=stamp)
            old_fp = tl.dirty_fingerprint
            try:
                tl.dirty_fingerprint = lambda repo_root=None: "abc123deadbeef"  # type: ignore[assignment]
                needed, reason = tl.batch_needed(force=False, stamp_path=stamp, repo_root=REPO)
                self.assertTrue(needed)
                self.assertEqual(reason, "dirty tree")
            finally:
                tl.dirty_fingerprint = old_fp

    def test_same_dirty_fingerprint_not_needed(self):
        import task_loop as tl

        with tempfile.TemporaryDirectory() as td:
            stamp = os.path.join(td, "batch-gate.json")
            sha = tl.head_sha(repo_root=REPO)
            fp = "samefp01234567"
            tl.write_batch_gate(
                {"sha": sha, "green": True, "dirty_fingerprint": fp}, path=stamp
            )
            old_fp = tl.dirty_fingerprint
            try:
                tl.dirty_fingerprint = lambda repo_root=None: fp  # type: ignore[assignment]
                needed, reason = tl.batch_needed(force=False, stamp_path=stamp, repo_root=REPO)
                self.assertFalse(needed)
                self.assertEqual(reason, "not needed")
            finally:
                tl.dirty_fingerprint = old_fp

    def test_pycache_noise_not_dirty(self):
        import task_loop as tl

        self.assertTrue(tl._is_dirty_noise_path("scripts/__pycache__/foo.cpython-313.pyc"))
        self.assertTrue(tl._is_dirty_noise_path("scripts/factory_floor/__pycache__/"))
        self.assertTrue(tl._is_dirty_noise_path("mod.pyc"))
        self.assertFalse(tl._is_dirty_noise_path("scripts/task_loop.py"))
        self.assertFalse(tl._is_dirty_noise_path("docs/tasks/task-017.md"))

        with tempfile.TemporaryDirectory() as td:
            noise = [
                "?? scripts/__pycache__/",
                "?? scripts/factory_floor/__pycache__/x.pyc",
            ]
            with mock.patch.object(tl, "porcelain_lines", return_value=noise):
                self.assertEqual(tl.meaningful_porcelain(), [])
                self.assertFalse(tl.worktree_dirty())
                self.assertEqual(tl.dirty_fingerprint(), "")

    def test_open_incident_parks_idle_drain(self):
        import task_loop as tl

        with tempfile.TemporaryDirectory() as td:
            fail = os.path.join(td, "batch-failure.json")
            stamp = os.path.join(td, "batch-gate.json")
            sha = "abc123open"
            with mock.patch.object(tl, "head_sha", return_value=sha):
                tl.write_batch_failure(
                    {"status": "open", "head_sha": sha, "reason": "still_red"},
                    path=fail,
                )
                tl.write_batch_gate({"sha": "other", "green": True}, path=stamp)
                needed, reason = tl.batch_needed(
                    force=False, stamp_path=stamp, failure_path=fail, repo_root=REPO
                )
                self.assertFalse(needed)
                self.assertEqual(reason, "needs_decision")

    def test_force_ignores_open_incident(self):
        import task_loop as tl

        with tempfile.TemporaryDirectory() as td:
            fail = os.path.join(td, "batch-failure.json")
            with mock.patch.object(tl, "head_sha", return_value="abc"):
                tl.write_batch_failure(
                    {"status": "open", "head_sha": "abc"}, path=fail
                )
                needed, reason = tl.batch_needed(
                    force=True, failure_path=fail, repo_root=REPO
                )
                self.assertTrue(needed)
                self.assertEqual(reason, "ship_now")

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
