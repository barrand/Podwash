#!/usr/bin/env python3
"""Unit tests for Forge Floor batch incident + derived Needs-you state."""

from __future__ import annotations

import json
import os
import sys
import tempfile
import time
import unittest
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
                with mock.patch("task_loop.worktree_dirty", return_value=False):
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
        self.assertEqual(activity["headline"], "Can't ship")
        self.assertNotIn("Needs you", activity["headline"])
        self.assertNotIn("Needs you", activity["next"])
        self.assertIn("Your move", activity["next"])

    def test_batch_plain_needs_decision_says_your_move(self):
        import factory_floor.server as floor

        plain = floor._batch_plain("still_red", "needs_decision")
        self.assertIn("Your move", plain)
        self.assertNotIn("Needs you", plain)

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
        self.assertIn("gone", activity["detail"].lower())

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
        self.assertTrue(alive)

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
                        floor.start_runner()
        self.assertEqual(written.get("runner_pid"), 55555)
        self.assertIsNotNone(written.get("started_at"))
        floor._runner_proc = None


class ControlHandlerTests(unittest.TestCase):
    def test_start_runner_uses_medic_no_push(self):
        import factory_floor.server as floor

        fake = mock.Mock(pid=12345, poll=mock.Mock(return_value=None))
        with mock.patch.object(floor, "_runner_proc", None):
            with mock.patch.object(floor.subprocess, "Popen", return_value=fake) as popen:
                with mock.patch.object(floor, "read_controls", return_value=floor._default_controls()):
                    with mock.patch.object(floor, "write_controls"):
                        msg = floor.start_runner()
        self.assertIn("started", msg)
        argv = popen.call_args[0][0]
        self.assertIn("--medic-no-push", argv)
        self.assertNotIn("--no-self-heal", argv)
        floor._runner_proc = None

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
