#!/usr/bin/env python3
"""Factory hardening regressions — slice 13 failure modes + fire-drill suite.

Exclusive lanes, classifier hygiene, identical-sig infra abort, class-transition
credit, and post-edit tier-0 routing.
"""

from __future__ import annotations

import os
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from failure_packet import FailurePacket
from sim_hygiene import classify_infra_failure
from slice_pipeline import (
    VerifyOutcome,
    is_build_lane,
    is_tier2_infra_failure,
    outcome_failure_class,
    run_tier2_implement_gate,
)


BUILD_ERR = (
    "build_error: call to main actor-isolated initializer 'init(userDefaults:)' "
    "in a synchronous nonisolated context"
)

FULL_BUILD_OUTPUT = f"""{BUILD_ERR}
xcodebuild: note: Using staging directory for derivedData
CoreSimulator service connection established
** BUILD FAILED **
Testing cancelled because the build failed.
VERIFY RESULT: exit=65 total=0 passed=0 failed=0 skipped=0 filtered=1 "
bundle=build/test-results/verify-x.xcresult tier=2 class=build
"""


def _build_outcome(**kwargs) -> VerifyOutcome:
    failures = kwargs.pop("failures", [BUILD_ERR])
    return VerifyOutcome(
        result=kwargs.pop(
            "result",
            {
                "exit": "65",
                "total": "0",
                "passed": "0",
                "failed": "0",
                "skipped": "0",
                "class": "build",
                "tier": "2",
            },
        ),
        green=False,
        failures=failures,
        output=kwargs.pop("output", FULL_BUILD_OUTPUT),
        packet=kwargs.pop(
            "packet",
            FailurePacket(raw_failures=failures, failure_class="build_error"),
        ),
        tier=2,
        **kwargs,
    )


def _sim_outcome(msg: str = "Failed to install or launch (SBMainWorkspace)") -> VerifyOutcome:
    failures = [msg]
    return VerifyOutcome(
        result={"exit": "65", "failed": "1", "tier": "2", "class": "tests"},
        green=False,
        failures=failures,
        output=failures[0],
        packet=FailurePacket(raw_failures=failures, failure_class="flake"),
        tier=2,
    )


def _assert_outcome(msg: str) -> VerifyOutcome:
    failures = [msg]
    return VerifyOutcome(
        result={"exit": "65", "failed": "1", "tier": "2", "class": "tests"},
        green=False,
        failures=failures,
        output=failures[0],
        packet=FailurePacket(
            raw_failures=failures,
            assertions=failures,
            failure_class="assertion",
            fix_scope="tests",
            test_ids=["PlaybackRateTests/testFoo()"],
        ),
        tier=2,
    )


def _slice_md(tmp: str) -> str:
    path = os.path.join(tmp, "docs", "slices", "slice-13-settings.md")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(
            "## Verification mapping\n\n"
            "| AC# | Test file | Test method |\n"
            "|-----|-----------|-------------|\n"
            "| 1 | `PodWash/PodWashTests/SettingsStoreTests.swift` | "
            "`testDefaultsPersist` |\n"
        )
    return path


class ClassifierHygieneTests(unittest.TestCase):
    def test_coresimulator_alone_is_not_infra(self):
        self.assertFalse(
            classify_infra_failure(
                output="CoreSimulator service connection established",
                exit_code="65",
                files_changed=False,
            )
        )

    def test_lock_substring_in_block_is_not_infra(self):
        self.assertFalse(
            classify_infra_failure(
                output="consider using a Task or DispatchQueue block",
                exit_code="65",
                files_changed=False,
            )
        )

    def test_bare_dns_is_not_infra(self):
        self.assertFalse(
            classify_infra_failure(
                output="something about dns in a comment",
                exit_code="65",
                files_changed=False,
            )
        )

    def test_dns_lookup_phrase_is_infra(self):
        self.assertTrue(
            classify_infra_failure(
                output="failed to launch bridge: dns lookup failed",
                exit_code="65",
                files_changed=False,
            )
        )

    def test_holds_the_lock_is_infra(self):
        self.assertTrue(
            classify_infra_failure(
                output="verify.sh: another verify run holds the lock (build/.verify.lock)",
                exit_code="65",
                files_changed=False,
            )
        )

    def test_sbmainworkspace_still_infra(self):
        self.assertTrue(
            classify_infra_failure(
                output="Failed to install or launch the test runner (SBMainWorkspace)",
                files_changed=False,
            )
        )


class ExclusiveLaneTests(unittest.TestCase):
    def test_build_error_with_coresimulator_stdout_is_not_infra(self):
        outcome = _build_outcome()
        self.assertTrue(is_build_lane(outcome))
        self.assertEqual(outcome_failure_class(outcome), "build_error")
        self.assertFalse(is_tier2_infra_failure(outcome))

    def test_class_build_beats_sim_markers_in_failures(self):
        # Even if curated text somehow had sim language, class=build wins.
        outcome = _build_outcome(
            failures=[
                BUILD_ERR,
                "Failed to install or launch (SBMainWorkspace)",
            ]
        )
        self.assertTrue(is_build_lane(outcome))
        self.assertFalse(is_tier2_infra_failure(outcome))

    def test_disagreement_alarm_logged(self):
        # Full stdout with CoreSimulator used to trip infra; structured=build wins.
        logs: list[str] = []
        # Force heuristic true on full blob via an infra phrase in output only
        outcome = _build_outcome(
            output=FULL_BUILD_OUTPUT
            + "\nFailed to install or launch the test runner (SBMainWorkspace)\n"
        )
        self.assertFalse(is_tier2_infra_failure(outcome, log=logs.append))
        self.assertTrue(any("CLASSIFIER DISAGREEMENT" in l for l in logs))

    def test_real_sim_launch_still_infra(self):
        self.assertTrue(is_tier2_infra_failure(_sim_outcome()))


class IdenticalSigInfraAbortTests(unittest.TestCase):
    def test_identical_infra_aborts_second_cold_retry(self):
        from slice_loop_progress import ThrashHalt

        calls = {"n": 0}

        def verify_fn(**_kw):
            calls["n"] += 1
            return _sim_outcome("Failed to install or launch (SBMainWorkspace)")

        with tempfile.TemporaryDirectory() as tmp:
            slice_path = _slice_md(tmp)
            logs: list[str] = []
            with self.assertRaises(ThrashHalt):
                run_tier2_implement_gate(
                    client=None,
                    slice_file=slice_path,
                    repo_root=tmp,
                    api_key="x",
                    log=logs.append,
                    verify_fn=verify_fn,
                    max_runs=1,
                    max_infra_retries=2,
                )
            infra_logs = [l for l in logs if "infra cold retry" in l and "aborted" not in l]
            abort_logs = [l for l in logs if "identical signature" in l]
            self.assertEqual(len(infra_logs), 1, logs)
            self.assertEqual(len(abort_logs), 1, logs)
            # First verify → retry; second → abort → fix burn → halt (client=None)
            self.assertEqual(calls["n"], 2)

    def test_distinct_infra_signatures_get_multiple_retries(self):
        from slice_loop_progress import ThrashHalt

        calls = {"n": 0}
        msgs = [
            "Failed to install or launch (SBMainWorkspace) attempt-A",
            "Early unexpected exit, operation never finished bootstrapping",
            "PodWashTests/Foo/testBar() — XCTAssertTrue failed",
        ]

        def verify_fn(**_kw):
            calls["n"] += 1
            i = min(calls["n"] - 1, len(msgs) - 1)
            if "bootstrapping" in msgs[i] or "SBMainWorkspace" in msgs[i]:
                return _sim_outcome(msgs[i])
            return _assert_outcome(msgs[i])

        with tempfile.TemporaryDirectory() as tmp:
            slice_path = _slice_md(tmp)
            logs: list[str] = []
            with self.assertRaises(ThrashHalt):
                run_tier2_implement_gate(
                    client=None,
                    slice_file=slice_path,
                    repo_root=tmp,
                    api_key="x",
                    log=logs.append,
                    verify_fn=verify_fn,
                    max_runs=1,
                    max_infra_retries=2,
                )
            infra_logs = [l for l in logs if "infra cold retry" in l and "aborted" not in l]
            self.assertEqual(len(infra_logs), 2, logs)
            self.assertGreaterEqual(calls["n"], 3)


class ClassTransitionCreditTests(unittest.TestCase):
    def test_new_class_after_budget_gets_one_spawn(self):
        """Slice 13 shape: crash+UI burn budget, then build_error must still spawn."""
        from slice_loop_progress import ThrashHalt

        sequence = [
            _assert_outcome("crash-ish assertion A"),
            _assert_outcome("missing_identifier-ish B"),
            _build_outcome(),
            _build_outcome(),  # after transition spawn, still red → halt
        ]
        calls = {"n": 0}
        worker_calls = {"n": 0}

        def verify_fn(**kw):
            tier = kw.get("tier", 2)
            if tier == 0:
                # Post-edit tier-0 green so we don't inject pending build
                return VerifyOutcome(
                    result={"exit": "0", "class": "tests", "tier": "0"},
                    green=True,
                    tier=0,
                )
            calls["n"] += 1
            i = min(calls["n"] - 1, len(sequence) - 1)
            return sequence[i]

        def fake_worker(*_a, **_k):
            worker_calls["n"] += 1
            return True, "ok"

        with tempfile.TemporaryDirectory() as tmp:
            slice_path = _slice_md(tmp)
            logs: list[str] = []
            with mock.patch("slice_pipeline.run_worker", side_effect=fake_worker):
                with self.assertRaises(ThrashHalt):
                    run_tier2_implement_gate(
                        client=object(),  # truthy — allow spawns
                        slice_file=slice_path,
                        repo_root=tmp,
                        api_key="x",
                        log=logs.append,
                        verify_fn=verify_fn,
                        max_runs=2,
                        max_infra_retries=0,
                    )
            credit = [l for l in logs if "class-transition credit" in l]
            self.assertEqual(len(credit), 1, logs)
            # Two normal spawns + one transition spawn
            self.assertEqual(worker_calls["n"], 3, logs)
            self.assertTrue(
                any("build_error" in l or "class=build" in l for l in logs),
                logs,
            )


class PostEditTier0Tests(unittest.TestCase):
    def test_tier0_red_skips_to_pending_build_outcome(self):
        from slice_loop_progress import ThrashHalt

        calls = {"tier2": 0, "tier0": 0}
        worker_calls = {"n": 0}

        def verify_fn(**kw):
            tier = kw.get("tier", 2)
            if tier == 0:
                calls["tier0"] += 1
                return _build_outcome()
            calls["tier2"] += 1
            if calls["tier2"] == 1:
                return _assert_outcome("first test red")
            # Should receive pending build from tier-0, but if tier-2 runs again:
            return _build_outcome()

        def fake_worker(*_a, **_k):
            worker_calls["n"] += 1
            return True, "ok"

        with tempfile.TemporaryDirectory() as tmp:
            slice_path = _slice_md(tmp)
            logs: list[str] = []
            with mock.patch("slice_pipeline.run_worker", side_effect=fake_worker):
                with self.assertRaises(ThrashHalt):
                    run_tier2_implement_gate(
                        client=object(),
                        slice_file=slice_path,
                        repo_root=tmp,
                        api_key="x",
                        log=logs.append,
                        verify_fn=verify_fn,
                        max_runs=2,
                        max_infra_retries=0,
                    )
            self.assertGreaterEqual(calls["tier0"], 1, logs)
            self.assertTrue(any("post-edit tier-0 RED" in l for l in logs), logs)
            self.assertTrue(any("pending post-edit outcome" in l for l in logs), logs)


class FireDrillSuite(unittest.TestCase):
    """End-to-end gate behavior against injected failure shapes."""

    def test_build_red_never_takes_infra_lane(self):
        logs: list[str] = []
        outcome = _build_outcome()
        self.assertFalse(is_tier2_infra_failure(outcome, log=logs.append))
        # Even with CoreSimulator in stdout, no infra retry path
        from slice_loop_progress import ThrashHalt

        def verify_fn(**_kw):
            return outcome

        with tempfile.TemporaryDirectory() as tmp:
            slice_path = _slice_md(tmp)
            gate_logs: list[str] = []
            with self.assertRaises(ThrashHalt):
                run_tier2_implement_gate(
                    client=None,
                    slice_file=slice_path,
                    repo_root=tmp,
                    api_key="x",
                    log=gate_logs.append,
                    verify_fn=verify_fn,
                    max_runs=1,
                    max_infra_retries=2,
                )
            self.assertFalse(any("infra cold retry" in l for l in gate_logs), gate_logs)


if __name__ == "__main__":
    unittest.main()
