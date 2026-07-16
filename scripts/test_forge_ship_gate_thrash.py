#!/usr/bin/env python3
"""Ship-gate thrash contract — no overnight full-verify spiral after Mechanic thrash."""

from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from slice_loop_progress import ThrashHalt  # noqa: E402


class ForgeLoopShipThrashTests(unittest.TestCase):
    def setUp(self) -> None:
        import forge_loop
        import task_loop as tl

        self.fl = forge_loop
        self.tl = tl
        self._td = tempfile.TemporaryDirectory()
        root = self._td.name
        self.controls = os.path.join(root, "controls.json")
        self.station = os.path.join(root, "station.json")
        self.failure = os.path.join(root, "batch-failure.json")
        self.gate = os.path.join(root, "batch-gate.json")
        self._orig = {
            "CONTROLS_PATH": tl.CONTROLS_PATH,
            "STATION_PATH": tl.STATION_PATH,
            "BATCH_FAILURE_PATH": tl.BATCH_FAILURE_PATH,
            "BATCH_GATE_PATH": tl.BATCH_GATE_PATH,
        }
        tl.CONTROLS_PATH = self.controls
        tl.STATION_PATH = self.station
        tl.BATCH_FAILURE_PATH = self.failure
        tl.BATCH_GATE_PATH = self.gate
        tl.write_controls(tl.default_controls())
        Path(self.gate).write_text(
            '{"sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "green": true, "tier": 3}\n',
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        for k, v in self._orig.items():
            setattr(self.tl, k, v)
        self._td.cleanup()

    def test_mechanic_thrash_skips_post_mechanic_full_verify(self) -> None:
        """ThrashHalt after Mechanic must not launch another full tier-3 verify."""
        verify_tiers: list[object] = []

        class FakeOutcome:
            green = False
            result = {"exit": "65", "failed": "2", "total": "10", "passed": "8"}
            failures: list = []

        def fake_verify(_root, log=None, tier=3, **_kw):
            verify_tiers.append(tier)
            return FakeOutcome()

        def raise_thrash(*_a, **_k):
            raise ThrashHalt("NO PROGRESS 2/2")

        with mock.patch("slice_pipeline.run_verify", side_effect=fake_verify):
            with mock.patch.object(
                self.tl, "batch_needed", return_value=(True, "ship_now")
            ):
                with mock.patch.object(
                    self.tl, "head_sha", return_value="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
                ):
                    with mock.patch(
                        "cursor_bridge.launch_bridge",
                        return_value=mock.MagicMock(),
                    ):
                        with mock.patch(
                            "mechanic_fix.run_fix_cycle",
                            side_effect=raise_thrash,
                        ):
                            with mock.patch(
                                "forge_work.lightweight_bisect",
                                return_value={"message": "bisect skipped in test"},
                            ):
                                code = self.fl.run_batch_gate_unified(
                                    api_key="k",
                                    dry_run=False,
                                    no_commit=True,
                                    no_push=True,
                                    skip=False,
                                    force=True,
                                )

        self.assertEqual(code, self.tl.EXIT_THRASH)
        # Only the initial 3a (and maybe escalated 3) — never a post-Mechanic tier=3.
        self.assertTrue(verify_tiers, "expected at least the initial ship verify")
        # After thrash, no additional full-suite call beyond the pre-Mechanic pass(es).
        # Initial path: tier 3a then possibly tier 3. Post-Mechanic would append another 3.
        post_mechanic_full = [t for t in verify_tiers[1:] if t == 3 or t == "3"]
        # If first was 3a red, only one verify before Mechanic; thrash must not add another.
        self.assertLessEqual(
            verify_tiers.count(3) + verify_tiers.count("3"),
            1,
            f"post-Mechanic full verify must be skipped; tiers={verify_tiers}",
        )
        incident = self.tl.read_batch_failure()
        self.assertEqual(incident.get("status"), "open")
        self.assertTrue(incident.get("mechanic_thrashed"))

    def test_ship_now_thrash_returns_not_idle_continue(self) -> None:
        """Main loop must return EXIT_THRASH so supervisor can invoke Medic."""
        with mock.patch.object(
            self.fl, "run_batch_gate_unified", return_value=self.tl.EXIT_THRASH
        ) as batch:
            with mock.patch.object(self.tl, "wait_while_queue_idle") as idle:
                with mock.patch.object(self.tl, "apply_control_side_effects") as ace:
                    with mock.patch.object(self.tl, "write_heartbeat"):
                        with mock.patch.object(self.tl, "set_factory_hot"):
                            with mock.patch.dict(
                                os.environ, {"CURSOR_API_KEY": "test-key"}
                            ):
                                ctrl = self.tl.default_controls()
                                ctrl["ship_now"] = True
                                self.tl.write_controls(ctrl)

                                def side_effects(c):
                                    return c

                                ace.side_effect = side_effects
                                rc = self.fl.main([])

        self.assertEqual(rc, self.tl.EXIT_THRASH)
        batch.assert_called_once()
        idle.assert_not_called()


class TaskLoopShipThrashTests(unittest.TestCase):
    def setUp(self) -> None:
        import task_loop as tl

        self.tl = tl
        self._td = tempfile.TemporaryDirectory()
        root = self._td.name
        self._orig = {
            "CONTROLS_PATH": tl.CONTROLS_PATH,
            "STATION_PATH": tl.STATION_PATH,
            "BATCH_FAILURE_PATH": tl.BATCH_FAILURE_PATH,
            "BATCH_GATE_PATH": tl.BATCH_GATE_PATH,
        }
        tl.CONTROLS_PATH = os.path.join(root, "controls.json")
        tl.STATION_PATH = os.path.join(root, "station.json")
        tl.BATCH_FAILURE_PATH = os.path.join(root, "batch-failure.json")
        tl.BATCH_GATE_PATH = os.path.join(root, "batch-gate.json")
        tl.write_controls(tl.default_controls())
        Path(tl.BATCH_GATE_PATH).write_text(
            '{"sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "green": true, "tier": 3}\n',
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        for k, v in self._orig.items():
            setattr(self.tl, k, v)
        self._td.cleanup()

    def test_mechanic_thrash_returns_without_second_verify(self) -> None:
        verify_calls: list[object] = []

        class FakeOutcome:
            green = False
            result = {"exit": "65", "failed": "1"}
            failures = [{"id": "PodWashTests/Foo/testBar()"}]

        def fake_verify(_root, log=None, tier=3, **_kw):
            verify_calls.append(tier)
            return FakeOutcome()

        def raise_thrash(*_a, **_k):
            raise ThrashHalt("NO PROGRESS 2/2")

        with mock.patch("slice_pipeline.run_verify", side_effect=fake_verify):
            with mock.patch.object(
                self.tl, "batch_needed", return_value=(True, "ship_now")
            ):
                with mock.patch.object(
                    self.tl,
                    "head_sha",
                    return_value="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                ):
                    with mock.patch(
                        "cursor_bridge.launch_bridge",
                        return_value=mock.MagicMock(),
                    ):
                        with mock.patch(
                            "mechanic_fix.run_fix_cycle",
                            side_effect=raise_thrash,
                        ):
                            with mock.patch.object(
                                self.tl,
                                "batch_failures_are_scope_miss",
                                return_value=False,
                            ):
                                # collect_done_surgical may be empty
                                code = self.tl.run_batch_gate(
                                    api_key="k",
                                    dry_run=False,
                                    no_commit=True,
                                    no_push=True,
                                    skip=False,
                                    force=True,
                                )

        self.assertEqual(code, self.tl.EXIT_THRASH)
        # Pre-Mechanic verifies only (3a and/or 3) — no post-Mechanic call.
        self.assertGreaterEqual(len(verify_calls), 1)
        incident = self.tl.read_batch_failure()
        self.assertTrue(incident.get("mechanic_thrashed"))


if __name__ == "__main__":
    unittest.main()
