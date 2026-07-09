#!/usr/bin/env python3
"""Unit tests for slice_pipeline (GateState, router, verify helpers) — no SDK/Xcode."""

from __future__ import annotations

import os
import sys
import tempfile
import unittest
from unittest import mock

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)

from slice_loop_progress import parse_verify_result, verify_is_green  # noqa: E402
from slice_pipeline import (  # noqa: E402
    FixBudget,
    adr_reviewer_cleared,
    assess_gate_state,
    build_fix_prompt,
    failure_signature,
    format_verify_result_line,
    gates_ready_for_parallel,
    mode_for_role,
    model_for_role,
    next_gate,
    record_green_verify,
    route_fix,
    run_fix_loop,
    set_slice_status,
    should_loop_own_verify,
    split_paths_for_commits,
    write_verify_result,
    VerifyOutcome,
)
from slice_loop_progress import ThrashHalt  # noqa: E402

REPO = os.path.dirname(SCRIPT_DIR)


class ParseVerifyBundleTests(unittest.TestCase):
    def test_parse_captures_bundle_and_filtered(self):
        v = parse_verify_result(
            "VERIFY RESULT: exit=0 total=10 passed=10 failed=0 skipped=0 "
            "filtered=0 bundle=build/test-results/verify-x.xcresult"
        )
        self.assertTrue(verify_is_green(v))
        self.assertEqual(v["bundle"], "build/test-results/verify-x.xcresult")
        self.assertEqual(v["filtered"], "0")

    def test_format_verify_result_line(self):
        line = format_verify_result_line(
            {
                "exit": "0",
                "total": "3",
                "passed": "3",
                "failed": "0",
                "skipped": "0",
                "bundle": "b.xcresult",
            }
        )
        self.assertIn("VERIFY RESULT:", line)
        self.assertIn("bundle=b.xcresult", line)


class FixRouterTests(unittest.TestCase):
    def test_crash_routes_engineer(self):
        self.assertEqual(
            route_fix([], ["Crash: PodWash at Foo.testBar()"]),
            "Engineer",
        )

    def test_ambiguous_defaults_engineer(self):
        self.assertEqual(
            route_fix(["FooTests/testSomething — XCTAssertTrue failed"], []),
            "Engineer",
        )

    def test_same_signature_after_engineer_routes_qa(self):
        fails = ["PodWashUITests/testProgress — XCTAssertTrue failed"]
        sig = failure_signature(fails, [])
        self.assertEqual(
            route_fix(
                fails,
                [],
                previous_role="Engineer",
                previous_signature=sig,
            ),
            "QA",
        )

    def test_fixture_wording_can_route_qa(self):
        self.assertEqual(
            route_fix(
                ["golden fixture XCTAssertEqual failed in PodWashTests"],
                [],
            ),
            "QA",
        )

    def test_fix_budget_persists(self):
        b = FixBudget(max_attempts=2)
        b.record("Engineer", "sig1")
        self.assertEqual(b.attempts_used, 1)
        self.assertFalse(b.exhausted())
        b.record("QA", "sig1")
        self.assertTrue(b.exhausted())

    def test_build_fix_prompt_scopes(self):
        eng = build_fix_prompt(
            "Engineer", "docs/slices/x.md", ["t"], [], "b.xcresult", 1, 2
        )
        self.assertIn("PodWash/PodWash/**", eng)
        self.assertIn("Do NOT run scripts/verify.sh", eng)
        qa = build_fix_prompt("QA", "docs/slices/x.md", ["t"], [], None, 2, 2)
        self.assertIn("PodWashTests", qa)

    def test_halts_when_budget_exhausted(self):
        budget = FixBudget(max_attempts=2)
        # crash class has two Engineer levers (no early playbook halt)
        from failure_packet import FailurePacket

        packet = FailurePacket(
            test_ids=[],
            crashes=["Crash: PodWash EXC_BAD_ACCESS at Foo"],
            failure_class="crash",
            signature="crash:podwash",
            raw_failures=[],
            actionable=True,
        )
        red = VerifyOutcome(
            result={"exit": "1", "total": "1", "passed": "0", "failed": "1", "skipped": "0"},
            green=False,
            failures=[],
            crashes=packet.crashes,
            packet=packet,
        )
        calls = {"n": 0}

        def fake_verify(**_kw):
            calls["n"] += 1
            return red

        with mock.patch("slice_pipeline.run_worker", return_value=(True, "finished")):
            with self.assertRaises(ThrashHalt) as ctx:
                run_fix_loop(
                    client=object(),
                    slice_file="x.md",
                    repo_root=REPO,
                    api_key="k",
                    budget=budget,
                    verify_fn=fake_verify,
                )
        self.assertTrue(
            "exhausted" in str(ctx.exception.reason).lower()
            or "playbook halt" in str(ctx.exception.reason).lower()
            or "crash" in str(ctx.exception.reason).lower()
        )
        self.assertEqual(budget.attempts_used, 2)
        # initial verify + 2 after fixes
        self.assertGreaterEqual(calls["n"], 3)

    def test_returns_on_green(self):
        budget = FixBudget(max_attempts=2)
        green = VerifyOutcome(
            result={"exit": "0", "total": "1", "passed": "1", "failed": "0", "skipped": "0"},
            green=True,
        )
        out = run_fix_loop(
            client=None,
            slice_file="x.md",
            repo_root=REPO,
            api_key="k",
            budget=budget,
            verify_fn=lambda: green,
        )
        self.assertTrue(out.green)
        self.assertEqual(budget.attempts_used, 0)


class ModelModeMapTests(unittest.TestCase):
    def test_models_are_plain_ids(self):
        self.assertEqual(model_for_role("PM"), "composer-2.5")
        self.assertEqual(model_for_role("Engineer"), "grok-4.5")
        self.assertNotIn("[", model_for_role("Architect"))

    def test_reviewers_use_plan_mode(self):
        self.assertEqual(mode_for_role("QA review"), "plan")
        self.assertEqual(mode_for_role("PM review"), "plan")
        self.assertEqual(mode_for_role("Architect review"), "plan")
        self.assertEqual(mode_for_role("Engineer"), "agent")
        self.assertEqual(mode_for_role("QA"), "agent")


class GateStateTests(unittest.TestCase):
    def test_slice_08_all_done(self):
        state = assess_gate_state(
            "docs/slices/slice-08-playback-integration.md", REPO
        )
        self.assertTrue(state.all_done, state.summary)
        self.assertIsNone(next_gate(state))

    def test_slice_09_partial(self):
        state = assess_gate_state("docs/slices/slice-09-analysis-ui.md", REPO)
        arch = state.gate("architect")
        self.assertTrue(arch.applicable)
        self.assertEqual(arch.status, "waived")
        self.assertFalse(state.all_done)
        nxt = next_gate(state)
        self.assertIsNotNone(nxt)

    def test_synthetic_story_pending(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "slice-99.md")
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(
                    "# Slice 99\n\n"
                    "| Field | Value |\n"
                    "|-------|-------|\n"
                    "| **Status** | Draft |\n"
                    "| **Crux** | |\n\n"
                    "## Acceptance criteria\n\n"
                    "- [ ] 1. something\n"
                )
            state = assess_gate_state(path, tmp)
            self.assertEqual(state.gate("story").status, "pending")
            self.assertEqual(next_gate(state), "story")

    def test_adr_fork_parallel_ready(self):
        with tempfile.TemporaryDirectory() as tmp:
            adr = os.path.join(tmp, "docs", "adr")
            os.makedirs(adr)
            with open(os.path.join(adr, "099.md"), "w") as fh:
                fh.write("# ADR\n")
            path = os.path.join(tmp, "slice.md")
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(
                    "| **Status** | Ready |\n"
                    "| **Crux** | Prove X |\n\n"
                    "## Acceptance criteria\n\n"
                    "- [ ] 1. numeric AC\n\n"
                    "## Plan review record\n\n"
                    "```\n"
                    "ADR review: (pending)\n"
                    "```\n\n"
                    "## Role artifacts\n\n"
                    "| Role | Gate | Artifact path |\n"
                    "|------|------|---------------|\n"
                    "| Architect | Required | `docs/adr/099.md` |\n"
                    "| UX | Waived | — |\n"
                )
            state = assess_gate_state(path, tmp)
            self.assertEqual(state.gate("story").status, "done")
            self.assertEqual(state.gate("architect").status, "done")
            self.assertEqual(state.gate("ux").status, "waived")
            ready = gates_ready_for_parallel(state)
            self.assertIn("adr_review_qa", ready)
            self.assertIn("adr_review_pm", ready)

    def test_adr_reviewer_cleared_helpers(self):
        block = (
            "ADR review (2026-07-09): QA cleared — ok. PM cleared — scope matches."
        )
        self.assertTrue(adr_reviewer_cleared(block, "qa"))
        self.assertTrue(adr_reviewer_cleared(block, "pm"))
        self.assertFalse(adr_reviewer_cleared("ADR review: (pending)", "qa"))


class DocWriterTests(unittest.TestCase):
    def test_write_verify_and_set_done(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "slice.md")
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(
                    "| **Status** | Verify |\n\n"
                    "## Verification record (QA fills at Verify)\n\n"
                    "```\n"
                    "VERIFY RESULT: (pending)\n"
                    "```\n"
                )
            result = {
                "exit": "0",
                "total": "2",
                "passed": "2",
                "failed": "0",
                "skipped": "0",
                "bundle": "x.xcresult",
            }
            record_green_verify(path, tmp, result)
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
            self.assertIn("VERIFY RESULT: exit=0", text)
            self.assertIn("bundle=x.xcresult", text)
            self.assertIn("| **Status** | Done |", text)

    def test_write_verify_inserts_when_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "slice.md")
            with open(path, "w", encoding="utf-8") as fh:
                fh.write("| **Status** | In Progress |\n")
            write_verify_result(
                path,
                tmp,
                {
                    "exit": "0",
                    "total": "1",
                    "passed": "1",
                    "failed": "0",
                    "skipped": "0",
                },
            )
            with open(path, encoding="utf-8") as fh:
                self.assertIn("VERIFY RESULT:", fh.read())

    def test_set_slice_status(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "s.md")
            with open(path, "w", encoding="utf-8") as fh:
                fh.write("| **Status** | Ready |\n")
            set_slice_status(path, tmp, "Verify")
            with open(path, encoding="utf-8") as fh:
                self.assertIn("| **Status** | Verify |", fh.read())


class ShouldOwnVerifyTests(unittest.TestCase):
    def test_status_in_progress(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "s.md")
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(
                    "| **Status** | In Progress |\n"
                    "| **Crux** | x |\n\n"
                    "## Acceptance criteria\n\n- [ ] 1. a\n"
                )
            self.assertTrue(should_loop_own_verify(path, tmp))


class SplitCommitTests(unittest.TestCase):
    def test_split_paths(self):
        tests, apps, other = split_paths_for_commits(
            [
                "PodWash/PodWashTests/FooTests.swift",
                "PodWash/PodWash/Foo.swift",
                "docs/slices/slice-01.md",
            ]
        )
        self.assertEqual(tests, ["PodWash/PodWashTests/FooTests.swift"])
        self.assertEqual(apps, ["PodWash/PodWash/Foo.swift"])
        self.assertEqual(other, ["docs/slices/slice-01.md"])


if __name__ == "__main__":
    unittest.main()
