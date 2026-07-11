#!/usr/bin/env python3
"""Factory v3 Mechanic — regression matrix + signature contract unit tests."""

from __future__ import annotations

import os
import sys
import unittest
from unittest import mock

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)

from factory_progress import (  # noqa: E402
    ProgressTracker,
    classify_fix_paths,
    hard_cap_console_line,
    hard_cap_halt_message,
    hard_cap_stuck_line,
    is_no_progress,
    is_progress,
    make_failure_signature,
    needs_adr_diff_review,
    needs_test_diff_review,
    same_resume_family,
    thrash_halt_message,
)
from mechanic_fix import (  # noqa: E402
    build_mechanic_prompt,
    parse_review_verdict,
)
from fix_lanes import classify_fix_lane  # noqa: E402
from slice_pipeline import (  # noqa: E402
    VerifyOutcome,
    route_fix,
    run_fix_loop,
)
from slice_loop_progress import ThrashHalt  # noqa: E402
from failure_packet import FailurePacket  # noqa: E402


class SignatureContractTests(unittest.TestCase):
    def test_make_signature_sorted_ids_and_class(self):
        sig = make_failure_signature(
            test_ids=["B/testY()", "A/testX()"],
            failure_class="assertion",
        )
        self.assertEqual(sig, "A/testX()|B/testY()::assert")

    def test_empty_is_green(self):
        self.assertEqual(make_failure_signature(test_ids=[], failure_class="unknown"), "")

    def test_stress_flake_class(self):
        sig = make_failure_signature(
            test_ids=["PodWashUITests/Foo/testBar()"],
            stress_flake=True,
        )
        self.assertTrue(sig.endswith("::stress_flake"))

    def test_progress_on_count_drop(self):
        a = make_failure_signature(test_ids=["t1", "t2"], failure_class="assert")
        b = make_failure_signature(test_ids=["t1"], failure_class="assert")
        self.assertTrue(is_progress(a, b))

    def test_progress_on_signature_change(self):
        a = make_failure_signature(test_ids=["t1"], failure_class="assert")
        b = make_failure_signature(test_ids=["t1"], failure_class="build")
        self.assertTrue(is_progress(a, b))

    def test_no_progress_identical(self):
        a = make_failure_signature(test_ids=["t1"], failure_class="assert")
        self.assertTrue(is_no_progress(a, [a]))

    def test_oscillation_window(self):
        a = make_failure_signature(test_ids=["t1"], failure_class="assert")
        b = make_failure_signature(test_ids=["t2"], failure_class="assert")
        # A→B→A: A is in window
        self.assertTrue(is_no_progress(a, [a, b]))

    def test_resume_family_jaccard(self):
        a = make_failure_signature(test_ids=["t1", "t2"], failure_class="assert")
        b = make_failure_signature(test_ids=["t1", "t2", "t3"], failure_class="assert")
        self.assertTrue(same_resume_family(a, b))
        c = make_failure_signature(test_ids=["x"], failure_class="assert")
        self.assertFalse(same_resume_family(a, c))


class ProgressTrackerMatrixTests(unittest.TestCase):
    """Historical halt shapes from factory-v3-mechanic.md regression matrix."""

    def test_slice09_signature_changes_no_halt_at_2(self):
        t = ProgressTracker(max_spawns=8)
        s1 = make_failure_signature(test_ids=["a", "b", "c"], failure_class="assert")
        s2 = make_failure_signature(test_ids=["a"], failure_class="assert")
        t.observe_signature(s1)
        cont, _ = t.observe_signature(s2)
        self.assertTrue(cont)
        self.assertFalse(t.thrash_halt())

    def test_slice11_identical_2_cycles_halts(self):
        t = ProgressTracker(max_spawns=8)
        s = make_failure_signature(test_ids=["a"], failure_class="assert")
        t.observe_signature(s)
        cont1, line1 = t.observe_signature(s)
        self.assertFalse(cont1)
        self.assertIn("NO PROGRESS 1/2", line1)
        cont2, line2 = t.observe_signature(s)
        self.assertFalse(cont2)
        self.assertTrue(t.thrash_halt())
        self.assertIn("NO PROGRESS 2/2", line2)

    def test_slice12_13_class_change_continues(self):
        t = ProgressTracker(max_spawns=8)
        s1 = make_failure_signature(test_ids=["a"], failure_class="crash")
        s2 = make_failure_signature(failures=["build_error: foo"], failure_class="build")
        t.observe_signature(s1)
        cont, line = t.observe_signature(s2)
        self.assertTrue(cont)
        self.assertIn("PROGRESS", line)

    def test_oscillation_a_b_a_halts(self):
        t = ProgressTracker(max_spawns=8)
        a = make_failure_signature(test_ids=["a"], failure_class="assert")
        b = make_failure_signature(test_ids=["b"], failure_class="assert")
        t.observe_signature(a)
        t.observe_signature(b)  # progress
        cont, line = t.observe_signature(a)  # oscillation
        self.assertFalse(cont)
        self.assertIn("oscillation", line)
        t.observe_signature(a)
        self.assertTrue(t.thrash_halt())

    def test_stress_flake_thrash(self):
        t = ProgressTracker(max_spawns=8)
        cont1, _ = t.observe_stress_flake(had_harness_delta=False)
        self.assertTrue(cont1)
        cont2, _ = t.observe_stress_flake(had_harness_delta=False)
        self.assertFalse(cont2)
        self.assertTrue(t.stress_flake_thrash())

    def test_stress_flake_with_harness_resets(self):
        t = ProgressTracker(max_spawns=8)
        t.observe_stress_flake(had_harness_delta=False)
        cont, _ = t.observe_stress_flake(had_harness_delta=True)
        self.assertTrue(cont)
        self.assertFalse(t.stress_flake_thrash())

    def test_review_cap(self):
        t = ProgressTracker(max_spawns=8)
        cont1, _ = t.observe_review(cleared=False)
        self.assertTrue(cont1)
        cont2, _ = t.observe_review(cleared=False)
        self.assertFalse(cont2)
        self.assertTrue(t.review_thrash())

    def test_thrash_message_shape(self):
        t = ProgressTracker(max_spawns=8)
        t.spawns_used = 5
        t.consecutive_no_progress = 2
        t.last_signature = "a::assert"
        msg = thrash_halt_message(t, last="stress-flake after green")
        self.assertIn("THRASH HALT:", msg)
        self.assertIn("cycles=5/8", msg)
        self.assertIn("stress-flake", msg)


class HardCapBudgetTests(unittest.TestCase):
    """Slice 15 regression: verify wall clock must not burn Mechanic minutes."""

    def test_verify_time_excluded_from_mechanic_budget(self):
        t = ProgressTracker(max_spawns=8, max_minutes=45)
        t0 = 1_000_000.0
        t.start(t0)
        t.pause_for_verify(t0)
        # 60 minutes of full-suite verify (the slice-15 failure mode)
        t.resume_after_verify(t0 + 60 * 60)
        t.record_spawn()
        # 5 minutes of Mechanic agent work after verify
        now = t0 + 60 * 60 + 5 * 60
        self.assertFalse(
            t.at_hard_cap(now),
            "60m verify + 5m mechanic must not hard-cap a 45m mechanic budget",
        )
        self.assertAlmostEqual(t.mechanic_elapsed_minutes(now), 5.0, places=1)
        self.assertAlmostEqual(t.verify_elapsed_minutes(now), 60.0, places=1)
        self.assertAlmostEqual(t.wall_elapsed_minutes(now), 65.0, places=1)

    def test_old_wall_clock_bug_would_have_halted(self):
        """Document the pre-fix semantics: wall clock ≥ 45m with 1 spawn."""
        t = ProgressTracker(max_spawns=8, max_minutes=45)
        t0 = 0.0
        t.start(t0)
        t.pause_for_verify(t0)
        t.resume_after_verify(t0 + 60 * 60)
        t.record_spawn()
        now = t0 + 60 * 60 + 1.0
        # Wall is 60m but mechanic billable is ~0 — must allow spawn 2
        self.assertGreater(t.wall_elapsed_minutes(now), 45.0)
        self.assertFalse(t.at_hard_cap(now))
        self.assertEqual(t.spawns_used, 1)

    def test_mechanic_time_hits_hard_cap(self):
        t = ProgressTracker(max_spawns=8, max_minutes=45)
        t.start(0.0)
        t.record_spawn()
        self.assertTrue(t.at_hard_cap(45 * 60))
        self.assertEqual(t.hard_cap_reason(45 * 60), "mechanic time")

    def test_spawn_cap_hits_hard_cap(self):
        t = ProgressTracker(max_spawns=2, max_minutes=45)
        t.start(0.0)
        t.record_spawn()
        t.record_spawn()
        self.assertTrue(t.at_hard_cap(10.0))
        self.assertEqual(t.hard_cap_reason(10.0), "spawns")

    def test_hard_cap_message_not_no_progress(self):
        t = ProgressTracker(max_spawns=8, max_minutes=45)
        t0 = 0.0
        t.start(t0)
        t.pause_for_verify(t0)
        t.resume_after_verify(t0 + 3600)
        t.record_spawn()
        # Force mechanic-time cap with accumulated secs
        t.mechanic_elapsed_secs = 45 * 60
        t._segment_started_at = None
        now = t0 + 3600 + 1
        msg = hard_cap_halt_message(t, now=now, last="hard cap")
        self.assertIn("HARD CAP:", msg)
        self.assertIn("verify", msg.lower())
        self.assertNotIn("no progress", msg)
        console = hard_cap_console_line(t, now=now)
        self.assertIn("denying spawn 2/8", console)
        self.assertIn("verify consumed", console)
        stuck = hard_cap_stuck_line(t, now=now)
        self.assertTrue(stuck.startswith("Cap: hard_cap"))
        self.assertIn("1/8 spawns", stuck)

    def test_pause_resume_nested_is_idempotent(self):
        t = ProgressTracker(max_spawns=8, max_minutes=45)
        t.start(100.0)
        t.pause_for_verify(110.0)
        t.pause_for_verify(120.0)  # no-op
        t.resume_after_verify(200.0)
        t.resume_after_verify(210.0)  # no-op
        self.assertAlmostEqual(t.verify_elapsed_secs, 90.0, places=1)
        self.assertAlmostEqual(t.mechanic_elapsed_secs, 10.0, places=1)


class AntiCheatPathTests(unittest.TestCase):
    def test_test_diff_review_trigger(self):
        self.assertTrue(
            needs_test_diff_review(["PodWash/PodWashUITests/SettingsUITests.swift"])
        )
        self.assertFalse(needs_test_diff_review(["PodWash/PodWash/Foo.swift"]))

    def test_adr_diff_review_trigger(self):
        self.assertTrue(needs_adr_diff_review(["docs/adr/013-segmentation.md"]))
        self.assertFalse(needs_adr_diff_review(["PodWash/PodWash/Foo.swift"]))

    def test_commit_path_split(self):
        tests, apps, adrs, other = classify_fix_paths(
            [
                "PodWash/PodWashTests/A.swift",
                "PodWash/PodWash/B.swift",
                "docs/adr/013.md",
                "docs/slices/x.md",
            ]
        )
        self.assertEqual(len(tests), 1)
        self.assertEqual(len(apps), 1)
        self.assertEqual(len(adrs), 1)
        self.assertEqual(len(other), 1)

    def test_app_bundle_fixture_not_classified_as_test(self):
        """Regression: PodWash/PodWash/Fixtures/ must land in apps, not tests."""
        tests, apps, adrs, other = classify_fix_paths(
            [
                "PodWash/PodWashTests/ITunesStubURLProtocol.swift",
                "PodWash/PodWash/Fixtures/feeds/second_feed.xml",
            ]
        )
        self.assertEqual(tests, ["PodWash/PodWashTests/ITunesStubURLProtocol.swift"])
        self.assertEqual(apps, ["PodWash/PodWash/Fixtures/feeds/second_feed.xml"])
        self.assertEqual(adrs, [])
        self.assertEqual(other, [])

    def test_test_target_fixture_still_classified_as_test(self):
        tests, apps, _adrs, _other = classify_fix_paths(
            ["PodWash/PodWashTests/Fixtures/feeds/sample_feed.xml"]
        )
        self.assertEqual(tests, ["PodWash/PodWashTests/Fixtures/feeds/sample_feed.xml"])
        self.assertEqual(apps, [])


class MechanicPromptTests(unittest.TestCase):
    def test_prompt_allows_app_tests_adr(self):
        text = build_mechanic_prompt(
            "docs/slices/slice-19.md",
            ["PodWashUITests/Foo/testBar()"],
            [],
            None,
            1,
            8,
            lane_instruction="Suggested recipe: adr_citation",
        )
        self.assertIn("Mechanic", text)
        self.assertIn("PodWash/PodWash/**", text)
        self.assertIn("docs/adr/**", text)
        self.assertIn("optional", text.lower())
        self.assertNotIn("HANDOFF:", text)

    def test_lane_hint_optional_wording(self):
        lane = classify_fix_lane(
            blob="must cite committed precision",
            is_build=False,
        )
        self.assertIsNotNone(lane)
        assert lane is not None
        self.assertEqual(lane.lane_id, "adr_citation")
        self.assertIn("optional", lane.instruction.lower())

    def test_route_fix_always_mechanic(self):
        self.assertEqual(route_fix(["crash"], []), "Mechanic")
        self.assertEqual(route_fix(["fixture"], []), "Mechanic")


class ReviewParseTests(unittest.TestCase):
    def test_clear(self):
        self.assertTrue(parse_review_verdict("VERDICT: clear\nLooks good."))

    def test_blocker(self):
        self.assertFalse(parse_review_verdict("VERDICT: blocker — weakened assert"))


class SyntheticFixCycleTests(unittest.TestCase):
    """Synthetic red→Mechanic→green (acceptance gate shape)."""

    def test_green_first_verify(self):
        def verify_fn(**kwargs):
            return VerifyOutcome(
                result={"exit": "0", "failed": "0", "skipped": "0", "total": "1"},
                green=True,
                failures=[],
            )

        out = run_fix_loop(
            client=None,
            slice_file="docs/slices/slice-99-synthetic.md",
            repo_root=os.path.dirname(SCRIPT_DIR),
            api_key="test",
            verify_fn=verify_fn,
        )
        self.assertTrue(out.green)

    def test_progress_then_green(self):
        calls = {"n": 0}

        def verify_fn(**kwargs):
            calls["n"] += 1
            n = calls["n"]
            if n == 1:
                pkt = FailurePacket(
                    test_ids=["PodWashTests/Foo/testA()"],
                    raw_failures=["PodWashTests/Foo/testA()"],
                    failure_class="assertion",
                    actionable=True,
                    signature="PodWashTests/Foo/testA()::assert",
                )
                return VerifyOutcome(
                    result={"exit": "1", "failed": "1"},
                    green=False,
                    failures=["PodWashTests/Foo/testA()"],
                    packet=pkt,
                )
            return VerifyOutcome(
                result={"exit": "0", "failed": "0", "skipped": "0", "total": "1"},
                green=True,
                failures=[],
            )

        with mock.patch("slice_pipeline.run_worker", return_value=(True, "ok")), mock.patch(
            "slice_pipeline.git_paths_changed", return_value=[]
        ), mock.patch(
            "slice_pipeline.load_persona", return_value="You are Mechanic."
        ), mock.patch(
            "mechanic_fix.append_ledger"
        ), mock.patch(
            "mechanic_fix.load_ledger", return_value=[]
        ):
            out = run_fix_loop(
                client=object(),
                slice_file="docs/slices/slice-99-synthetic.md",
                repo_root=os.path.dirname(SCRIPT_DIR),
                api_key="test",
                verify_fn=verify_fn,
            )
        self.assertTrue(out.green)

    def test_identical_signature_thrash(self):
        def verify_fn(**kwargs):
            pkt = FailurePacket(
                test_ids=["PodWashTests/Foo/testA()"],
                raw_failures=["PodWashTests/Foo/testA()"],
                failure_class="assertion",
                actionable=True,
                signature="x",
            )
            return VerifyOutcome(
                result={"exit": "1", "failed": "1"},
                green=False,
                failures=["PodWashTests/Foo/testA()"],
                packet=pkt,
            )

        with mock.patch("slice_pipeline.run_worker", return_value=(True, "ok")), mock.patch(
            "slice_pipeline.git_paths_changed", return_value=[]
        ), mock.patch(
            "slice_pipeline.load_persona", return_value="You are Mechanic."
        ), mock.patch(
            "mechanic_fix.append_ledger"
        ), mock.patch(
            "mechanic_fix.load_ledger", return_value=[]
        ), mock.patch(
            "mechanic_fix.write_session_bundle", return_value="/tmp/x"
        ), mock.patch(
            "session_bundle.write_session_bundle", return_value="/tmp/x"
        ):
            with self.assertRaises(ThrashHalt) as ctx:
                run_fix_loop(
                    client=object(),
                    slice_file="docs/slices/slice-99-synthetic.md",
                    repo_root=os.path.dirname(SCRIPT_DIR),
                    api_key="test",
                    verify_fn=verify_fn,
                    budget=ProgressTracker(max_spawns=8),
                )
        self.assertIn("THRASH HALT", str(ctx.exception.reason))


if __name__ == "__main__":
    unittest.main()
