#!/usr/bin/env python3
"""Unit tests for Forge Floor batch incident + derived Needs-you state."""

from __future__ import annotations

import json
import os
import re
import sys
import tempfile
import textwrap
import time
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock

SCRIPTS = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(SCRIPTS)
sys.path.insert(0, SCRIPTS)
sys.path.insert(0, os.path.join(SCRIPTS, "factory_floor"))


class BatchNeededHeldTests(unittest.TestCase):
    def test_acknowledged_incident_at_head_skips(self):
        from task_loop import batch_needed, write_batch_failure

        with tempfile.TemporaryDirectory() as td:
            fail = os.path.join(td, "batch-failure.json")
            stamp = os.path.join(td, "batch-gate.json")
            with mock.patch("task_loop.head_sha", return_value="abc123"):
                write_batch_failure(
                    {
                        "status": "acknowledged",
                        "head_sha": "abc123",
                        "failures": [],
                    },
                    path=fail,
                )
                with open(stamp, "w", encoding="utf-8") as fh:
                    json.dump({"sha": "old"}, fh)
                needed, reason = batch_needed(
                    force=False, stamp_path=stamp, failure_path=fail, repo_root=REPO
                )
                self.assertFalse(needed)
                self.assertEqual(reason, "held")

    def test_force_ignores_held(self):
        from task_loop import batch_needed, write_batch_failure

        with tempfile.TemporaryDirectory() as td:
            fail = os.path.join(td, "batch-failure.json")
            with mock.patch("task_loop.head_sha", return_value="abc123"):
                write_batch_failure(
                    {"status": "acknowledged", "head_sha": "abc123"},
                    path=fail,
                )
                needed, reason = batch_needed(
                    force=True, failure_path=fail, repo_root=REPO
                )
                self.assertTrue(needed)
                self.assertEqual(reason, "ship_now")

    def test_stale_ack_does_not_hold(self):
        from task_loop import batch_needed, write_batch_failure

        with tempfile.TemporaryDirectory() as td:
            fail = os.path.join(td, "batch-failure.json")
            stamp = os.path.join(td, "batch-gate.json")
            with mock.patch("task_loop.head_sha", return_value="newsha"):
                with mock.patch("task_loop.dirty_fingerprint", return_value=""):
                    write_batch_failure(
                        {"status": "acknowledged", "head_sha": "oldsha"},
                        path=fail,
                    )
                    with open(stamp, "w", encoding="utf-8") as fh:
                        json.dump({"sha": "newsha"}, fh)
                    needed, reason = batch_needed(
                        force=False,
                        stamp_path=stamp,
                        failure_path=fail,
                        repo_root=REPO,
                    )
                    self.assertFalse(needed)
                    self.assertEqual(reason, "not needed")

    def test_open_incident_at_head_parks(self):
        from task_loop import batch_needed, write_batch_failure

        with tempfile.TemporaryDirectory() as td:
            fail = os.path.join(td, "batch-failure.json")
            stamp = os.path.join(td, "batch-gate.json")
            with mock.patch("task_loop.head_sha", return_value="abc123"):
                write_batch_failure(
                    {
                        "status": "open",
                        "head_sha": "abc123",
                        "reason": "still_red",
                        "failures": [],
                    },
                    path=fail,
                )
                with open(stamp, "w", encoding="utf-8") as fh:
                    json.dump({"sha": "old"}, fh)
                needed, reason = batch_needed(
                    force=False, stamp_path=stamp, failure_path=fail, repo_root=REPO
                )
                self.assertFalse(needed)
                self.assertEqual(reason, "needs_decision")


class BuildIncidentTests(unittest.TestCase):
    def test_prior_failures_carried_at_same_head(self):
        from task_loop import build_batch_incident, write_batch_failure, clear_batch_failure

        clear_batch_failure()
        with mock.patch("task_loop.head_sha", return_value="deadbeef"):
            with mock.patch(
                "task_loop.collect_verify_failures",
                return_value=(
                    [{"id": "PodWashTests/A/testOne()", "assertion": "boom"}],
                    {"exit": 65, "passed": 1, "failed": 1, "bundle": "b.xcresult"},
                ),
            ):
                write_batch_failure(
                    {
                        "status": "open",
                        "head_sha": "deadbeef",
                        "failures": [
                            {"id": "PodWashTests/A/testOne()", "assertion": "boom"}
                        ],
                    }
                )
                inc = build_batch_incident(
                    reason="still_red",
                    machine_tried=["tier3_retries", "mechanic"],
                )
                self.assertEqual(inc["prior_failures"], ["PodWashTests/A/testOne()"])
                self.assertEqual(inc["machine_tried"], ["tier3_retries", "mechanic"])
        clear_batch_failure()


class DerivedBatchStateTests(unittest.TestCase):
    def test_verifying_beats_open_incident(self):
        import factory_floor.server as floor

        with mock.patch.object(floor, "_read_batch_failure", return_value={
            "status": "open",
            "head_sha": "abc",
            "reason": "still_red",
            "failures": [{"id": "T/test()", "assertion": "x"}],
            "failed": 1,
            "machine_tried": ["tier3_retries"],
        }):
            with mock.patch("task_loop.batch_needed", return_value=(True, "never verified")):
                with mock.patch("task_loop.head_sha", return_value="abc"):
                    with mock.patch("task_loop.read_batch_gate", return_value={}):
                        with mock.patch.object(floor, "_verify_running", return_value=True):
                            with mock.patch.object(floor, "_runner_alive", return_value=True):
                                snap = floor._batch_snapshot({"batch_running": True})
        self.assertEqual(snap["state"], "verifying")
        self.assertIsNotNone(snap["failure"])

    def test_stale_batch_running_flag_does_not_verify(self):
        """batch_running flag alone (no loop, no children) is not verifying."""
        import factory_floor.server as floor

        with mock.patch.object(floor, "_read_batch_failure", return_value={
            "status": "open",
            "head_sha": "abc",
            "reason": "still_red",
            "failures": [],
            "failed": 1,
            "machine_tried": [],
        }):
            with mock.patch("task_loop.batch_needed", return_value=(True, "never verified")):
                with mock.patch("task_loop.head_sha", return_value="abc"):
                    with mock.patch("task_loop.read_batch_gate", return_value={}):
                        with mock.patch.object(floor, "_verify_running", return_value=False):
                            with mock.patch.object(floor, "_runner_alive", return_value=False):
                                snap = floor._batch_snapshot({"batch_running": True})
        self.assertEqual(snap["state"], "needs_decision")
        self.assertFalse(snap["batch_running"])

    def test_open_incident_needs_decision(self):
        import factory_floor.server as floor

        with mock.patch.object(floor, "_read_batch_failure", return_value={
            "status": "open",
            "head_sha": "abc",
            "reason": "still_red",
            "failures": [{"id": "T/test()", "assertion": "x"}],
            "failed": 1,
            "machine_tried": ["tier3_retries", "mechanic", "medic:lane_test"],
        }):
            with mock.patch("task_loop.batch_needed", return_value=(True, "never verified")):
                with mock.patch("task_loop.head_sha", return_value="abc"):
                    with mock.patch("task_loop.read_batch_gate", return_value={}):
                        with mock.patch.object(floor, "_verify_running", return_value=False):
                            snap = floor._batch_snapshot({"batch_running": False})
        self.assertEqual(snap["state"], "needs_decision")
        self.assertIn("Medic", snap["failure"]["ladder"])

    def test_acknowledged_is_held(self):
        import factory_floor.server as floor

        with mock.patch.object(floor, "_read_batch_failure", return_value={
            "status": "acknowledged",
            "head_sha": "abc",
            "reason": "still_red",
            "failures": [],
            "machine_tried": [],
        }):
            with mock.patch("task_loop.batch_needed", return_value=(False, "held")):
                with mock.patch("task_loop.head_sha", return_value="abc"):
                    with mock.patch("task_loop.read_batch_gate", return_value={"sha": "abc"}):
                        with mock.patch.object(floor, "_verify_running", return_value=False):
                            snap = floor._batch_snapshot({"batch_running": False})
        self.assertEqual(snap["state"], "held")

    def test_stale_incident_ignored(self):
        import factory_floor.server as floor

        with mock.patch.object(floor, "_read_batch_failure", return_value={
            "status": "open",
            "head_sha": "old",
            "reason": "still_red",
            "failures": [],
            "machine_tried": [],
        }):
            with mock.patch("task_loop.batch_needed", return_value=(False, "not needed")):
                with mock.patch("task_loop.head_sha", return_value="new"):
                    with mock.patch("task_loop.read_batch_gate", return_value={"sha": "new"}):
                        with mock.patch.object(floor, "_verify_running", return_value=False):
                            snap = floor._batch_snapshot({"batch_running": False})
        self.assertEqual(snap["state"], "green")
        self.assertTrue(snap["failure"]["stale"])

    def test_activity_verifying_not_needs_decision(self):
        import factory_floor.server as floor

        activity = floor._activity_snapshot(
            ctrl={"running": True, "paused": False, "batch_running": True},
            station={"phase": "FULL-VERIFY", "role": "loop", "detail": "tier-3"},
            batch={
                "state": "verifying",
                "reason": "never verified",
                "verify_running": True,
                "batch_running": True,
                "failure": {"status": "open", "failed": 2},
            },
            tasks=[],
            events=[],
            factory_hot=True,
            runner_alive=True,
        )
        self.assertEqual(activity["mode"], "batch")
        self.assertNotEqual(activity["mode"], "needs_decision")


class ActivityCopyAndLivenessTests(unittest.TestCase):
    def test_halted_stopped_next_says_requeue_halted(self):
        import factory_floor.server as floor

        activity = floor._activity_snapshot(
            ctrl={"running": False, "paused": False, "batch_running": False},
            station={},
            batch={"state": "idle", "reason": "not needed"},
            tasks=[{"id": "005", "status": "Halted", "title": "Pause"}],
            events=[],
            factory_hot=False,
            runner_alive=False,
        )
        self.assertEqual(activity["mode"], "stopped")
        self.assertIn("Requeue Halted", activity["next"])
        self.assertNotIn("Needs you", activity["next"])

    def test_needs_decision_headline_not_needs_you(self):
        import factory_floor.server as floor

        activity = floor._activity_snapshot(
            ctrl={"running": True, "paused": False, "batch_running": False},
            station={},
            batch={
                "state": "needs_decision",
                "reason": "still_red",
                "failure": {"failed": 2, "status": "open"},
            },
            tasks=[],
            events=[],
            factory_hot=True,
            runner_alive=True,
        )
        self.assertEqual(activity["mode"], "needs_decision")
        self.assertEqual(activity["headline"], "Can't push")
        self.assertNotIn("Needs you", activity["headline"])
        self.assertNotIn("Needs you", activity["next"])
        self.assertIn("Your move", activity["next"])

    def test_batch_plain_needs_decision_says_your_move(self):
        import factory_floor.server as floor

        plain = floor._batch_plain("still_red", "needs_decision")
        self.assertIn("Your move", plain)
        self.assertNotIn("Needs you", plain)

    def test_batch_plain_scope_miss(self):
        import factory_floor.server as floor

        plain = floor._batch_plain("scope_miss", "needs_decision")
        self.assertIn("Your move", plain)
        self.assertIn("punch-list", plain.lower())
        self.assertNotIn("Needs you", plain)
        self.assertNotIn("Mechanic", plain)
        ladder = floor._ladder_plain(["tier3_retries"])
        self.assertIn("full-suite retries", ladder)
        self.assertNotIn("Mechanic", ladder)

    def test_batch_scope_miss_skips_mechanic_in_incident(self):
        """scope_miss incidents must not claim Mechanic was tried."""
        from task_loop import build_batch_incident, write_batch_failure, clear_batch_failure
        from task_ticket import batch_failures_are_scope_miss

        fail_id = (
            "PodWashTests/ProductionAnalysisWiringTests/"
            "testStreamingURLSkipsAnalysisEvenWhenCleaningOn()"
        )
        surgical = [
            "PodWashTests/ProductionAnalysisWiringTests/"
            "testPlayEpisodeDownloadsInsteadOfStreamingWhenChannelCleaningOn()"
        ]
        self.assertTrue(batch_failures_are_scope_miss([fail_id], surgical))

        clear_batch_failure()
        with mock.patch("task_loop.head_sha", return_value="abc123"):
            with mock.patch(
                "task_loop.collect_verify_failures",
                return_value=(
                    [{"id": fail_id, "assertion": "analyzeCallCount"}],
                    {"exit": 65, "passed": 166, "failed": 1, "bundle": "b.xcresult"},
                ),
            ):
                # machine_tried stops at tier3_retries — no mechanic append on scope_miss
                inc = build_batch_incident(
                    reason="scope_miss",
                    machine_tried=["tier3_retries"],
                )
                self.assertEqual(inc["reason"], "scope_miss")
                self.assertEqual(inc["machine_tried"], ["tier3_retries"])
                self.assertNotIn("mechanic", inc["machine_tried"])
                write_batch_failure(inc)
        clear_batch_failure()

    def test_batch_pending_plain_english_no_jargon(self):
        import factory_floor.server as floor

        plain = floor._batch_plain("HEAD moved", "pending")
        self.assertIn("New commits", plain)
        self.assertNotIn("idle drain", plain.lower())
        self.assertNotIn("batch verify", plain.lower())

        activity = floor._activity_snapshot(
            ctrl={"running": True, "paused": False, "batch_running": False},
            station={},
            batch={
                "state": "pending",
                "reason": "HEAD moved",
                "needed": True,
                "verify_running": False,
            },
            tasks=[],
            events=[],
            factory_hot=True,
            runner_alive=True,
        )
        self.assertEqual(activity["mode"], "batch_pending")
        self.assertEqual(activity["headline"], "Waiting to run full test suite")
        self.assertNotIn("Idle drain", activity["headline"])

    def test_halted_blocks_full_suite_copy(self):
        import factory_floor.server as floor

        activity = floor._activity_snapshot(
            ctrl={"running": True, "paused": False, "batch_running": False},
            station={},
            batch={
                "state": "pending",
                "reason": "HEAD moved",
                "needed": True,
                "verify_running": False,
            },
            tasks=[{"id": "011", "status": "Halted", "title": "Timeline"}],
            events=[],
            factory_hot=True,
            runner_alive=True,
        )
        self.assertEqual(activity["mode"], "batch_pending")
        self.assertIn("Halted", activity["headline"])
        self.assertIn("Requeue", activity["next"])

    def test_starting_grace_then_orphan(self):
        import factory_floor.server as floor
        import time as time_mod

        now = time_mod.time()
        fresh = floor._activity_snapshot(
            ctrl={
                "running": True,
                "paused": False,
                "batch_running": False,
                "started_at": now - 5,
            },
            station={},
            batch={"state": "idle", "verify_running": False},
            tasks=[],
            events=[],
            factory_hot=True,
            runner_alive=False,
        )
        self.assertEqual(fresh["mode"], "starting")

        stale = floor._activity_snapshot(
            ctrl={
                "running": True,
                "paused": False,
                "batch_running": False,
                "started_at": now - 60,
            },
            station={},
            batch={"state": "idle", "verify_running": False},
            tasks=[],
            events=[],
            factory_hot=True,
            runner_alive=False,
        )
        self.assertEqual(stale["mode"], "orphan")
        self.assertTrue(stale["orphan"])

    def test_stale_batch_flag_is_orphan(self):
        import factory_floor.server as floor

        activity = floor._activity_snapshot(
            ctrl={
                "running": True,
                "paused": False,
                "batch_running": True,
                "started_at": time.time() - 120,
            },
            station={"phase": "FULL-VERIFY", "role": "loop"},
            batch={
                "state": "verifying",
                "batch_running": True,
                "verify_running": False,
            },
            tasks=[{"id": "001", "status": "In Progress"}],
            events=[],
            factory_hot=True,
            runner_alive=False,
        )
        self.assertEqual(activity["mode"], "orphan")
        self.assertTrue(activity["orphan"])

    def test_loop_dead_verify_children_alive(self):
        import factory_floor.server as floor

        activity = floor._activity_snapshot(
            ctrl={
                "running": True,
                "paused": False,
                "batch_running": True,
                "started_at": time.time() - 120,
            },
            station={"phase": "FULL-VERIFY", "role": "loop"},
            batch={
                "state": "verifying",
                "batch_running": True,
                "verify_running": True,
            },
            tasks=[],
            events=[],
            factory_hot=True,
            runner_alive=False,
        )
        self.assertEqual(activity["mode"], "batch")
        self.assertTrue(activity.get("loop_stale"))
        self.assertTrue(
            "exited" in activity["detail"].lower() or "gone" in activity["detail"].lower()
        )

    def test_runner_alive_uses_ctrl_pid(self):
        import factory_floor.server as floor

        with mock.patch.object(floor, "_runner_proc", None):
            with mock.patch.object(floor, "_pid_alive", return_value=True) as pid_alive:
                with mock.patch.object(floor, "_ps_commands", return_value=[]):
                    with mock.patch.object(floor, "_read_json_file", return_value={}):
                        alive = floor._runner_alive(ctrl={"runner_pid": 4242})
        self.assertTrue(alive)
        pid_alive.assert_called_with(4242)

    def test_runner_alive_fresh_heartbeat_without_pid(self):
        """Fresh heartbeat timestamp alone must not fake liveness (orphan delay bug)."""
        import factory_floor.server as floor

        with mock.patch.object(floor, "_runner_proc", None):
            with mock.patch.object(floor, "_pid_alive", return_value=False):
                with mock.patch.object(
                    floor,
                    "_read_json_file",
                    return_value={"pid": 0, "ts": time.time()},
                ):
                    with mock.patch.object(floor, "_ps_commands", return_value=[]):
                        alive = floor._runner_alive(ctrl={"runner_pid": None})
        self.assertFalse(alive)

    def test_runner_alive_dead_pid_ignores_fresh_heartbeat_ts(self):
        import factory_floor.server as floor

        with mock.patch.object(floor, "_runner_proc", None):
            with mock.patch.object(floor, "_pid_alive", return_value=False):
                with mock.patch.object(
                    floor,
                    "_read_json_file",
                    return_value={"pid": 99, "ts": time.time()},
                ):
                    with mock.patch.object(floor, "_ps_commands", return_value=[]):
                        alive = floor._runner_alive(ctrl={"runner_pid": 99})
        self.assertFalse(alive)

    def test_runner_not_alive_stale_heartbeat(self):
        import factory_floor.server as floor

        with mock.patch.object(floor, "_runner_proc", None):
            with mock.patch.object(floor, "_pid_alive", return_value=False):
                with mock.patch.object(
                    floor,
                    "_read_json_file",
                    return_value={"pid": 99, "ts": time.time() - 9999},
                ):
                    with mock.patch.object(floor, "_ps_commands", return_value=[]):
                        alive = floor._runner_alive(ctrl={"runner_pid": None})
        self.assertFalse(alive)

    def test_start_runner_records_pid_and_started_at(self):
        import factory_floor.server as floor

        written: dict = {}

        def capture(data):
            written.update(data)

        fake = mock.Mock(pid=55555, poll=mock.Mock(return_value=None))
        with mock.patch.object(floor, "_runner_proc", None):
            with mock.patch.object(floor.subprocess, "Popen", return_value=fake):
                with mock.patch.object(
                    floor, "read_controls", return_value=floor._default_controls()
                ):
                    with mock.patch.object(floor, "write_controls", side_effect=capture):
                        with mock.patch.object(floor, "_runner_alive", return_value=False):
                            with mock.patch("builtins.open", mock.mock_open()):
                                floor.start_runner()
        self.assertEqual(written.get("runner_pid"), 55555)
        self.assertEqual(written.get("runner_lane"), "task")
        self.assertIsNotNone(written.get("started_at"))
        floor._runner_proc = None

    def test_maybe_restart_orphan_runner_cooldown(self):
        import factory_floor.server as floor

        floor._last_orphan_restart_ts = 0.0
        with mock.patch.object(floor, "start_runner", return_value="started pid=1") as start:
            with mock.patch.object(floor, "HOT") as hot:
                hot.is_file.return_value = False
                msg = floor.maybe_restart_orphan_runner(
                    ctrl={"running": True, "runner_lane": "task"}, activity_mode="orphan"
                )
                self.assertEqual(msg, "started pid=1")
                msg2 = floor.maybe_restart_orphan_runner(
                    ctrl={"running": True, "runner_lane": "task"}, activity_mode="orphan"
                )
                self.assertIsNone(msg2)
                self.assertEqual(start.call_count, 1)

    def test_maybe_restart_orphan_uses_slice_lane(self):
        import factory_floor.server as floor

        floor._last_orphan_restart_ts = 0.0
        with mock.patch.object(
            floor, "start_slice_runner", return_value="started pid=2 lane=slice"
        ) as start:
            with mock.patch.object(floor, "HOT") as hot:
                hot.is_file.return_value = True
                msg = floor.maybe_restart_orphan_runner(
                    ctrl={"running": True, "runner_lane": "slice"}, activity_mode="orphan"
                )
        self.assertEqual(msg, "started pid=2 lane=slice")
        start.assert_called_once()


class ControlHandlerTests(unittest.TestCase):
    def test_start_runner_uses_medic_no_push(self):
        import factory_floor.server as floor

        fake = mock.Mock(pid=12345, poll=mock.Mock(return_value=None))
        with mock.patch.object(floor, "_runner_proc", None):
            with mock.patch.object(floor.subprocess, "Popen", return_value=fake) as popen:
                with mock.patch.object(floor, "read_controls", return_value=floor._default_controls()):
                    with mock.patch.object(floor, "write_controls"):
                        with mock.patch.object(floor, "_runner_alive", return_value=False):
                            msg = floor.start_runner()
        self.assertIn("started", msg)
        argv = popen.call_args[0][0]
        self.assertIn("--medic-no-push", argv)
        self.assertNotIn("--no-self-heal", argv)
        self.assertTrue(str(argv[0]).endswith("task-loop.sh"))
        floor._runner_proc = None

    def test_start_slice_runner_uses_slice_loop_and_hot(self):
        import factory_floor.server as floor

        written: dict = {}

        def capture(data):
            written.clear()
            written.update(data)

        fake = mock.Mock(pid=99901, poll=mock.Mock(return_value=None))
        with mock.patch.object(floor, "_runner_proc", None):
            with mock.patch.object(floor.subprocess, "Popen", return_value=fake) as popen:
                with mock.patch.object(
                    floor, "read_controls", return_value=floor._default_controls()
                ):
                    with mock.patch.object(floor, "write_controls", side_effect=capture):
                        with mock.patch.object(floor, "_runner_alive", return_value=False):
                            with mock.patch.object(floor, "_set_factory_hot") as hot:
                                with mock.patch("builtins.open", mock.mock_open()):
                                    msg = floor.start_slice_runner()
        self.assertIn("started", msg)
        self.assertIn("lane=slice", msg)
        argv = popen.call_args[0][0]
        self.assertTrue(str(argv[0]).endswith("slice-loop.sh"))
        self.assertIn("--medic-no-push", argv)
        self.assertEqual(written.get("runner_lane"), "slice")
        self.assertEqual(written.get("runner_pid"), 99901)
        hot.assert_called_with(True)
        floor._runner_proc = None

    def test_apply_control_start_slices(self):
        import factory_floor.server as floor

        with mock.patch.object(
            floor, "start_slice_runner", return_value="started pid=1 lane=slice"
        ) as start:
            with mock.patch.object(floor, "read_controls", return_value=floor._default_controls()):
                result = floor.apply_control("start_slices")
        self.assertTrue(result["ok"])
        self.assertIn("started", result["message"])
        start.assert_called_once()

    def test_runner_alive_detects_slice_loop_ps(self):
        import factory_floor.server as floor

        root = str(floor.REPO_ROOT)
        with mock.patch.object(floor, "_runner_proc", None):
            with mock.patch.object(floor, "_pid_alive", return_value=False):
                with mock.patch.object(floor, "_read_json_file", return_value={}):
                    with mock.patch.object(
                        floor,
                        "_ps_commands",
                        return_value=[f"{root}/scripts/slice_loop.py --max 1"],
                    ):
                        alive = floor._runner_alive(ctrl={"runner_pid": None})
        self.assertTrue(alive)

    def test_start_runner_stops_slice_lane_first(self):
        import factory_floor.server as floor

        fake = mock.Mock(pid=777, poll=mock.Mock(return_value=None))
        ctrl = floor._default_controls()
        ctrl["runner_lane"] = "slice"

        with mock.patch.object(floor, "_runner_proc", None):
            with mock.patch.object(floor, "stop_runner", return_value="stopped") as stop:
                with mock.patch.object(floor.subprocess, "Popen", return_value=fake):
                    with mock.patch.object(floor, "read_controls", return_value=ctrl):
                        with mock.patch.object(floor, "write_controls"):
                            with mock.patch.object(
                                floor, "_runner_alive", side_effect=[True, False]
                            ):
                                with mock.patch("builtins.open", mock.mock_open()):
                                    msg = floor.start_runner()
        stop.assert_called_once()
        self.assertIn("started", msg)
        floor._runner_proc = None

    def test_board_snapshot_lane_fields(self):
        import factory_floor.server as floor

        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            tasks = root / "docs" / "tasks"
            slices = root / "docs" / "slices"
            tasks.mkdir(parents=True)
            slices.mkdir(parents=True)
            (tasks / "task-020-a.md").write_text(
                _task_ticket_body(20, status="Queued"),
                encoding="utf-8",
            )
            (tasks / "task-021-h.md").write_text(
                textwrap.dedent(
                    """\
                    # Task 021 — H

                    | Field | Value |
                    |-------|-------|
                    | **ID** | 021 |
                    | **Title** | Human |
                    | **Status** | Needs-human |
                    | **Kind** | needs-human |
                    | **Priority** | P2 |
                    | **Area** | scripts/ |

                    ## Verification record

                    ```
                    VERIFY RESULT: (pending)
                    ```
                    """
                ),
                encoding="utf-8",
            )
            (slices / "slice-25-feature.md").write_text(
                textwrap.dedent(
                    """\
                    # Slice 25 — Feature

                    | Field | Value |
                    |-------|-------|
                    | **ID** | 25 |
                    | **Title** | Feature |
                    | **Status** | Ready |

                    ## Story
                    """
                ),
                encoding="utf-8",
            )
            with mock.patch.object(floor, "REPO_ROOT", root):
                with mock.patch.object(floor, "_runner_alive", return_value=False):
                    with mock.patch.object(floor, "maybe_restart_orphan_runner", return_value=None):
                        snap = floor.board_snapshot()
        by_task = {t["id"]: t for t in snap["tasks"]}
        self.assertEqual(by_task["020"]["lane"], "task")
        self.assertTrue(by_task["020"]["runnable"])
        self.assertEqual(by_task["021"]["lane"], "task")
        self.assertFalse(by_task["021"]["runnable"])
        self.assertEqual(len(snap["slices"]), 1)
        sl = snap["slices"][0]
        self.assertEqual(sl["lane"], "slice")
        self.assertFalse(sl["runnable"])
        self.assertIn("Start slices", floor.INDEX_HTML)
        self.assertIn("lane-slice", floor.INDEX_HTML)

    def test_requeue_applies_immediately(self):
        import factory_floor.server as floor
        from task_ticket import parse_task_ticket

        with tempfile.TemporaryDirectory() as td:
            path = os.path.join(td, "task-005-t.md")
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(
                    "# Task\n\n| Field | Value |\n|-------|-------|\n"
                    "| **ID** | 005 |\n| **Status** | Halted |\n| **Title** | T |\n"
                )
            with mock.patch.object(floor, "REPO_ROOT", type(floor.REPO_ROOT)(td)):
                # docs/tasks layout
                tasks = os.path.join(td, "docs", "tasks")
                os.makedirs(tasks)
                dest = os.path.join(tasks, "task-005-t.md")
                os.rename(path, dest)
                msg = floor.requeue_task(5)
                self.assertIn("requeued", msg)
                self.assertEqual(parse_task_ticket(dest).status, "Queued")


def _task_ticket_body(
    n: int,
    *,
    status: str = "Queued",
    done_at: str | None = None,
) -> str:
    done_row = f"| **Done at** | {done_at} |\n" if done_at is not None else ""
    return textwrap.dedent(
        f"""\
        # Task {n:03d} — T

        | Field | Value |
        |-------|-------|
        | **ID** | {n:03d} |
        | **Title** | T{n} |
        | **Status** | {status} |
        | **Kind** | tweak |
        | **Priority** | P2 |
        | **Area** | scripts/ |
        {done_row}
        ## Verification record

        ```
        VERIFY RESULT: (pending)
        ```
        """
    )


class DoneColumnTests(unittest.TestCase):
    def test_set_task_status_done_writes_done_at(self):
        from task_ticket import set_task_status

        first = datetime(2026, 7, 13, 23, 23, 0, tzinfo=timezone.utc)
        second = datetime(2026, 7, 14, 1, 0, 0, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as td:
            path = os.path.join(td, "task-014-t.md")
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(_task_ticket_body(14, status="In Progress"))
            with mock.patch("task_ticket.datetime") as dt_mod:
                dt_mod.now.return_value = first
                dt_mod.UTC = timezone.utc
                set_task_status(path, "Done")
            text = Path(path).read_text(encoding="utf-8")
            self.assertIn("| **Status** | Done |", text)
            self.assertRegex(
                text,
                r"\|\s*\*\*Done at\*\*\s*\|\s*2026-07-13T23:23:00Z\s*\|",
            )
            self.assertEqual(text.count("| **Done at** |"), 1)

            set_task_status(path, "In Progress")
            with mock.patch("task_ticket.datetime") as dt_mod:
                dt_mod.now.return_value = second
                dt_mod.UTC = timezone.utc
                set_task_status(path, "Done")
            text2 = Path(path).read_text(encoding="utf-8")
            self.assertRegex(
                text2,
                r"\|\s*\*\*Done at\*\*\s*\|\s*2026-07-14T01:00:00Z\s*\|",
            )
            self.assertEqual(text2.count("| **Done at** |"), 1)

    def test_board_snapshot_includes_done_at(self):
        import factory_floor.server as floor

        with tempfile.TemporaryDirectory() as td:
            tasks = Path(td) / "docs" / "tasks"
            tasks.mkdir(parents=True)
            (tasks / "task-010-dated.md").write_text(
                _task_ticket_body(10, status="Done", done_at="2026-07-10T12:00:00Z"),
                encoding="utf-8",
            )
            (tasks / "task-011-legacy.md").write_text(
                _task_ticket_body(11, status="Done"),
                encoding="utf-8",
            )
            with mock.patch.object(floor, "REPO_ROOT", Path(td)):
                snap = floor.board_snapshot()
        by_id = {t["id"]: t for t in snap["tasks"]}
        self.assertEqual(by_id["010"]["done_at"], "2026-07-10T12:00:00Z")
        self.assertIsNone(by_id["011"]["done_at"])

    def test_done_sort_newest_first(self):
        import factory_floor.server as floor

        items = [
            {"id": "003", "done_at": "2026-07-10T12:00:00Z"},
            {"id": "001", "done_at": "2026-07-13T23:23:00Z"},
            {"id": "002", "done_at": None},
            {"id": "004", "done_at": "2026-07-12T00:00:00Z"},
            {"id": "005", "done_at": None},
        ]
        ordered = floor._sort_done_column(items)
        self.assertEqual(
            [i["id"] for i in ordered],
            ["001", "004", "003", "002", "005"],
        )

    def test_done_card_html_includes_closed_at(self):
        import factory_floor.server as floor

        line = floor._format_done_closed_meta("2026-07-13T23:23:00Z")
        self.assertIn("closed", line.lower())
        self.assertRegex(line, r"\d{4}-\d{2}-\d{2}|\bJan\b|\bFeb\b|\bMar\b|\bApr\b|\bMay\b|\bJun\b|\bJul\b|\bAug\b|\bSep\b|\bOct\b|\bNov\b|\bDec\b")
        self.assertEqual(floor._format_done_closed_meta(None), "")


class SessionBundleNameTests(unittest.TestCase):
    def test_bundle_name_override(self):
        from session_bundle import write_session_bundle

        with tempfile.TemporaryDirectory() as td:
            dest = write_session_bundle(
                repo_root=td,
                slice_id=None,
                reason="still_red",
                bundle_name="session-task-batch",
                extra={"kind": "task-batch"},
            )
            self.assertTrue(dest.endswith("session-task-batch"))
            halt = os.path.join(dest, "halt.json")
            self.assertTrue(os.path.isfile(halt))
            with open(halt, encoding="utf-8") as fh:
                meta = json.load(fh)
            self.assertEqual(meta["extra"]["kind"], "task-batch")


if __name__ == "__main__":
    unittest.main()
