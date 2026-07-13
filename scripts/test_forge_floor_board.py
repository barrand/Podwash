#!/usr/bin/env python3
"""Unit tests for Forge Floor batch incident + derived Needs-you state."""

from __future__ import annotations

import json
import os
import sys
import tempfile
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
                        with mock.patch.object(floor, "_verify_running", return_value=False):
                            snap = floor._batch_snapshot({"batch_running": True})
        self.assertEqual(snap["state"], "verifying")
        self.assertIsNotNone(snap["failure"])

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
            batch={"state": "verifying", "reason": "never verified", "failure": {
                "status": "open", "failed": 2
            }},
            tasks=[],
            events=[],
            factory_hot=True,
            runner_alive=True,
        )
        self.assertEqual(activity["mode"], "batch")
        self.assertNotEqual(activity["mode"], "needs_decision")


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
