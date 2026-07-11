#!/usr/bin/env python3
"""Factory hardening regressions — classifier hygiene + infra cold-retry.

Class-transition / handoff credits removed in Factory v3 — see test_factory_v3.py.
"""

from __future__ import annotations

import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from failure_packet import FailurePacket
from sim_hygiene import classify_infra_failure
from slice_pipeline import (
    InfraHalt,
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


class InfraColdRetryTests(unittest.TestCase):
    """Factory v3: infra cold-retries then InfraHalt (no identical-sig abort)."""

    def test_identical_infra_exhausts_retries_then_infra_halt(self):
        calls = {"n": 0}

        def verify_fn(**_kw):
            calls["n"] += 1
            return _sim_outcome("Failed to install or launch (SBMainWorkspace)")

        with tempfile.TemporaryDirectory() as tmp:
            slice_path = _slice_md(tmp)
            logs: list[str] = []
            with self.assertRaises(InfraHalt):
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
            infra_logs = [l for l in logs if "infra cold-retry" in l]
            self.assertEqual(len(infra_logs), 2, logs)
            # Initial verify + 2 cold retries
            self.assertEqual(calls["n"], 3)

    def test_distinct_infra_then_real_failure_spawns_mechanic_path(self):
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
            infra_logs = [l for l in logs if "infra cold-retry" in l]
            self.assertEqual(len(infra_logs), 2, logs)
            self.assertGreaterEqual(calls["n"], 3)


# ClassTransitionCreditTests / HandoffCreditTests / PostEditTier0Tests deleted —
# Factory v3 Mechanic loop has no role credits or post-edit tier-0. See
# scripts/test_factory_v3.py for progress-based stop + Mechanic cycle coverage.


class FireDrillSuite(unittest.TestCase):
    """End-to-end gate behavior against injected failure shapes."""

    def test_build_red_never_takes_infra_lane(self):
        logs: list[str] = []
        outcome = _build_outcome()
        self.assertFalse(is_tier2_infra_failure(outcome, log=logs.append))
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
            self.assertFalse(any("infra cold-retry" in l for l in gate_logs), gate_logs)


if __name__ == "__main__":
    unittest.main()
