#!/usr/bin/env python3
"""Unit tests for Forge supervisor (forge_supervisor.py)."""

from __future__ import annotations

import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from forge_supervisor import (
    EXIT_HALT,
    EXIT_INFRA,
    EXIT_OK,
    EXIT_THRASH,
    EXIT_WAIT,
    strip_supervisor_args,
    supervisor_main,
)


class StripArgsTests(unittest.TestCase):
    def test_self_heal_default_on(self):
        loop, flags = strip_supervisor_args(["--max", "1", "--verbose"])
        self.assertEqual(loop, ["--max", "1", "--verbose"])
        self.assertTrue(flags["self_heal"])

    def test_strips_explicit_self_heal(self):
        loop, flags = strip_supervisor_args(
            ["--self-heal", "--max", "1", "--verbose"]
        )
        self.assertEqual(loop, ["--max", "1", "--verbose"])
        self.assertTrue(flags["self_heal"])

    def test_no_self_heal(self):
        loop, flags = strip_supervisor_args(["--no-self-heal", "--max", "1"])
        self.assertEqual(loop, ["--max", "1"])
        self.assertFalse(flags["self_heal"])

    def test_medic_no_push(self):
        loop, flags = strip_supervisor_args(["--medic-no-push"])
        self.assertEqual(loop, [])
        self.assertTrue(flags["medic_no_push"])
        self.assertTrue(flags["self_heal"])


class SupervisorDispatchTests(unittest.TestCase):
    def test_no_self_heal_passthrough(self):
        with mock.patch("forge_supervisor.run_slice_loop", return_value=EXIT_OK) as rl:
            with mock.patch("forge_supervisor.run_medic") as medic:
                rc = supervisor_main(["--no-self-heal", "--max", "1"])
                self.assertEqual(rc, EXIT_OK)
                rl.assert_called_once_with(["--max", "1"])
                medic.assert_not_called()

    def test_default_heals_on_thrash(self):
        """Without --self-heal flag, Medic still runs (default on)."""
        with mock.patch("forge_supervisor.run_slice_loop", return_value=EXIT_THRASH):
            with mock.patch(
                "forge_supervisor.run_medic", return_value=(False, 1)
            ) as medic:
                rc = supervisor_main(["--max", "1"])
                self.assertEqual(rc, EXIT_THRASH)
                medic.assert_called_once()

    def test_dry_run_never_medics(self):
        with mock.patch("forge_supervisor.run_slice_loop", return_value=EXIT_OK) as rl:
            with mock.patch("forge_supervisor.run_medic") as medic:
                rc = supervisor_main(["--dry-run"])
                self.assertEqual(rc, EXIT_OK)
                rl.assert_called_once()
                medic.assert_not_called()

    def test_halt_and_ask_no_medic(self):
        with mock.patch("forge_supervisor.run_slice_loop", return_value=EXIT_HALT):
            with mock.patch("forge_supervisor.run_medic") as medic:
                rc = supervisor_main(["--max", "1"])
                self.assertEqual(rc, EXIT_HALT)
                medic.assert_not_called()

    def test_wait_no_medic(self):
        with mock.patch("forge_supervisor.run_slice_loop", return_value=EXIT_WAIT):
            with mock.patch("forge_supervisor.run_medic") as medic:
                rc = supervisor_main([])
                self.assertEqual(rc, EXIT_WAIT)
                medic.assert_not_called()

    def test_thrash_invokes_medic_then_stops(self):
        with mock.patch("forge_supervisor.run_slice_loop", return_value=EXIT_THRASH):
            with mock.patch(
                "forge_supervisor.run_medic", return_value=(False, 1)
            ) as medic:
                rc = supervisor_main(["--max", "1"])
                self.assertEqual(rc, EXIT_THRASH)
                medic.assert_called_once()
                self.assertEqual(medic.call_args.kwargs["exit_code"], EXIT_THRASH)

    def test_thrash_heal_then_ok(self):
        loop_rcs = [EXIT_THRASH, EXIT_OK]

        def _loop(_argv):
            return loop_rcs.pop(0)

        with mock.patch("forge_supervisor.run_slice_loop", side_effect=_loop):
            with mock.patch(
                "forge_supervisor.run_medic", return_value=(True, 1)
            ) as medic:
                rc = supervisor_main(["--max", "2"])
                self.assertEqual(rc, EXIT_OK)
                medic.assert_called_once()

    def test_infra_free_retry_then_medic(self):
        loop_rcs = [EXIT_INFRA, EXIT_INFRA]

        def _loop(_argv):
            return loop_rcs.pop(0)

        with mock.patch("forge_supervisor.run_slice_loop", side_effect=_loop):
            with mock.patch(
                "forge_supervisor.run_medic", return_value=(False, 1)
            ) as medic:
                rc = supervisor_main([])
                self.assertEqual(rc, EXIT_INFRA)
                medic.assert_called_once()
                self.assertEqual(medic.call_args.kwargs["exit_code"], EXIT_INFRA)

    def test_infra_single_success_after_retry(self):
        loop_rcs = [EXIT_INFRA, EXIT_OK]

        def _loop(_argv):
            return loop_rcs.pop(0)

        with mock.patch("forge_supervisor.run_slice_loop", side_effect=_loop):
            with mock.patch("forge_supervisor.run_medic") as medic:
                rc = supervisor_main([])
                self.assertEqual(rc, EXIT_OK)
                medic.assert_not_called()


if __name__ == "__main__":
    unittest.main()
