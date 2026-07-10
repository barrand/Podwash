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
from slice_loop_progress import (  # noqa: E402
    _story_content_ok,
    _story_done,
    assess_slice_gates,
    story_pending_reasons,
)
from slice_pipeline import (  # noqa: E402
    FixBudget,
    adr_reviewer_cleared,
    assess_gate_state,
    build_fix_prompt,
    explain_gate_pending,
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

    def test_parse_captures_tier(self):
        v = parse_verify_result(
            "VERIFY RESULT: exit=0 total=10 passed=10 failed=0 skipped=0 "
            "filtered=0 bundle=build/test-results/verify-x.xcresult tier=3"
        )
        self.assertEqual(v.get("tier"), "3")
        self.assertTrue(verify_is_green(v))

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


class VerifyTierHelpersTests(unittest.TestCase):
    def test_verify_env_tier1(self):
        from slice_pipeline import verify_env_for_tier

        env = verify_env_for_tier(1, failed_tests=["A/b()", "C/d()"])
        self.assertEqual(env["VERIFY_TIER"], "1")
        self.assertIn("A/b()", env["VERIFY_FAILED_TESTS"])
        with self.assertRaises(ValueError):
            verify_env_for_tier(1, failed_tests=[])

    def test_test_ids_for_tier1(self):
        from failure_packet import FailurePacket
        from slice_pipeline import test_ids_for_tier1

        p = FailurePacket(test_ids=["PodWashTests/Foo/testA()"])
        self.assertEqual(
            test_ids_for_tier1(p, ["noise"]),
            ["PodWashTests/Foo/testA()"],
        )


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
        # crash class — referee returns a fresh hypothesis each attempt so ledger
        # does not halt early; both fix attempts stay red → budget exhausted.
        from failure_packet import FailurePacket
        from referee import RefereeVerdict

        packet = FailurePacket(
            test_ids=["PodWashTests/Foo/testCrash()"],
            crashes=["Crash: PodWash EXC_BAD_ACCESS at Foo"],
            failure_class="crash",
            signature="PodWashTests/Foo/testCrash()",
            raw_failures=["PodWashTests/Foo/testCrash() — crash"],
            actionable=True,
        )
        red = VerifyOutcome(
            result={"exit": "1", "total": "1", "passed": "0", "failed": "1", "skipped": "0"},
            green=False,
            failures=packet.raw_failures,
            crashes=packet.crashes,
            packet=packet,
        )
        calls = {"n": 0, "ref": 0}

        def fake_verify(**_kw):
            calls["n"] += 1
            return red

        def fake_referee(**_kw):
            calls["ref"] += 1
            return RefereeVerdict(
                primary_failure="PodWashTests/Foo/testCrash()",
                role="Engineer",
                fix_scope="app",
                files=["PodWash/PodWash/Foo.swift"],
                instruction=f"Fix crash attempt {calls['ref']}",
                hypothesis=f"nil guard missing in path {calls['ref']}",
                confidence="high",
            )

        with tempfile.TemporaryDirectory() as tmp:
            with mock.patch("slice_pipeline.run_worker", return_value=(True, "finished")):
                with self.assertRaises(ThrashHalt) as ctx:
                    run_fix_loop(
                        client=object(),
                        slice_file="docs/slices/slice-09.md",
                        repo_root=tmp,
                        api_key="k",
                        budget=budget,
                        verify_fn=fake_verify,
                        referee_fn=fake_referee,
                    )
        self.assertIn("exhausted", str(ctx.exception.reason).lower())
        self.assertEqual(budget.attempts_used, 2)
        # initial verify + tier1 + tier3 per attempt (or tier1 only when red)
        self.assertGreaterEqual(calls["n"], 3)
        self.assertEqual(calls["ref"], 2)

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
            verify_fn=lambda **_kw: green,
        )
        self.assertTrue(out.green)
        self.assertEqual(budget.attempts_used, 0)

    def test_ledger_reroutes_repeat_hypothesis_while_budget_remains(self):
        """Same hyp+sig no longer thrash-halts; flips role and spends an attempt."""
        from failure_packet import FailurePacket
        from referee import RefereeVerdict

        budget = FixBudget(max_attempts=2)
        packet = FailurePacket(
            test_ids=["PodWashTests/Foo/testA()"],
            signature="PodWashTests/Foo/testA()",
            raw_failures=["PodWashTests/Foo/testA() — fail"],
            suggested_files=["PodWash/PodWashTests/FooTests.swift"],
            actionable=True,
        )
        red = VerifyOutcome(
            result={"exit": "1", "failed": "1", "passed": "0", "skipped": "0", "total": "1"},
            green=False,
            failures=packet.raw_failures,
            packet=packet,
        )
        hyp = "cancel fires before bytes flushed"
        roles: list[str] = []

        def fake_referee(**_kw):
            return RefereeVerdict(
                primary_failure="PodWashTests/Foo/testA()",
                role="Engineer",
                fix_scope="app",
                files=["PodWash/PodWashTests/FooTests.swift"],
                instruction="Fix cancel gate",
                hypothesis=hyp,
                confidence="high",
            )

        def capture_worker(client, role, prompt, **_kw):
            roles.append(role)
            return True, "finished"

        with tempfile.TemporaryDirectory() as tmp:
            from hypothesis_ledger import append_ledger, make_entry

            append_ledger(
                make_entry(
                    slice_id=9,
                    attempt=1,
                    role="Engineer",
                    hypothesis=hyp,
                    signature=packet.signature,
                    outcome="red",
                ),
                repo_root=tmp,
                slice_id=9,
            )
            with mock.patch("slice_pipeline.run_worker", side_effect=capture_worker):
                with self.assertRaises(ThrashHalt) as ctx:
                    run_fix_loop(
                        client=object(),
                        slice_file="docs/slices/slice-09.md",
                        repo_root=tmp,
                        api_key="k",
                        budget=budget,
                        verify_fn=lambda **_kw: red,
                        referee_fn=fake_referee,
                    )
            # Budget exhausted after reroutes — not an immediate ledger halt
            self.assertIn("exhausted", str(ctx.exception.reason).lower())
            self.assertEqual(budget.attempts_used, 2)
            self.assertTrue(any(r == "QA" for r in roles), roles)

    def test_heuristic_parse_fail_allows_full_budget(self):
        """Referee JSON parse fail → heuristic try-N; must spend all attempts."""
        from failure_packet import FailurePacket
        from referee import RefereeError

        budget = FixBudget(max_attempts=2)
        packet = FailurePacket(
            test_ids=["PodWashTests/QueueTests/testAutoAdvanceOnEpisodeEnd()"],
            signature="PodWashTests/QueueTests/testAutoAdvanceOnEpisodeEnd()",
            raw_failures=[
                'PodWashTests/QueueTests/testAutoAdvanceOnEpisodeEnd() — '
                'XCTAssertEqual failed: ("2") is not equal to ("1")'
            ],
            failure_class="assertion",
            fix_scope="app",
            suggested_files=["PodWash/PodWashTests/QueueTests.swift"],
            actionable=True,
        )
        red = VerifyOutcome(
            result={"exit": "65", "failed": "1", "passed": "0", "skipped": "0", "total": "1"},
            green=False,
            failures=packet.raw_failures,
            packet=packet,
        )
        roles: list[str] = []

        def fake_referee(**_kw):
            raise RefereeError("referee JSON parse failed: Invalid control character")

        def capture_worker(client, role, prompt, **_kw):
            roles.append(role)
            return True, "finished"

        with tempfile.TemporaryDirectory() as tmp:
            with mock.patch("slice_pipeline.run_worker", side_effect=capture_worker):
                with self.assertRaises(ThrashHalt) as ctx:
                    run_fix_loop(
                        client=object(),
                        slice_file="docs/slices/slice-11-queue-resume.md",
                        repo_root=tmp,
                        api_key="k",
                        budget=budget,
                        verify_fn=lambda **_kw: red,
                        referee_fn=fake_referee,
                    )
        self.assertIn("exhausted", str(ctx.exception.reason).lower())
        self.assertEqual(budget.attempts_used, 2)
        # Scope contradiction: Engineer + test files → QA on attempt 1
        self.assertEqual(roles[0], "QA", roles)

    def test_scope_contradiction_flips_engineer_to_qa(self):
        from referee import resolve_role_scope_contradiction

        role, scope = resolve_role_scope_contradiction(
            "Engineer",
            ["PodWash/PodWashTests/QueueTests.swift", "PodWash/PodWashTests/ResumePositionTests.swift"],
        )
        self.assertEqual(role, "QA")
        self.assertEqual(scope, "tests")
        role2, scope2 = resolve_role_scope_contradiction(
            "QA",
            ["PodWash/PodWash/QueueCoordinator.swift"],
        )
        self.assertEqual(role2, "Engineer")
        self.assertEqual(scope2, "app")

    def test_tier1_then_tier3_on_fix_green(self):
        from failure_packet import FailurePacket
        from referee import RefereeVerdict

        budget = FixBudget(max_attempts=2)
        packet = FailurePacket(
            test_ids=["PodWashTests/Foo/testA()"],
            signature="PodWashTests/Foo/testA()",
            raw_failures=["PodWashTests/Foo/testA() — fail"],
            actionable=True,
        )
        red = VerifyOutcome(
            result={"exit": "1", "failed": "1", "passed": "0", "skipped": "0", "total": "1"},
            green=False,
            failures=packet.raw_failures,
            packet=packet,
        )
        green = VerifyOutcome(
            result={"exit": "0", "failed": "0", "passed": "1", "skipped": "0", "total": "1"},
            green=True,
        )
        tiers: list[int] = []

        def fake_verify(**kw):
            tier = int(kw.get("tier", 3))
            tiers.append(tier)
            # First call = initial full red; after fix, tier1 green then tier3 green
            if len(tiers) == 1:
                return red
            return green

        def fake_referee(**_kw):
            return RefereeVerdict(
                primary_failure="PodWashTests/Foo/testA()",
                role="Engineer",
                fix_scope="app",
                files=["PodWash/PodWash/Foo.swift"],
                instruction="Fix the assertion",
                hypothesis="off-by-one in Foo",
                confidence="high",
            )

        with tempfile.TemporaryDirectory() as tmp:
            with mock.patch("slice_pipeline.run_worker", return_value=(True, "finished")):
                out = run_fix_loop(
                    client=object(),
                    slice_file="docs/slices/slice-10.md",
                    repo_root=tmp,
                    api_key="k",
                    budget=budget,
                    verify_fn=fake_verify,
                    referee_fn=fake_referee,
                )
        self.assertTrue(out.green)
        self.assertEqual(tiers[:3], [3, 1, 3])

    def test_low_confidence_referee_halts(self):
        from failure_packet import FailurePacket
        from referee import RefereeError

        budget = FixBudget(max_attempts=2)
        packet = FailurePacket(
            test_ids=["PodWashTests/Foo/testA()"],
            signature="PodWashTests/Foo/testA()",
            raw_failures=["PodWashTests/Foo/testA() — fail"],
            actionable=True,
        )
        red = VerifyOutcome(
            result={"exit": "1", "failed": "1", "passed": "0", "skipped": "0", "total": "1"},
            green=False,
            failures=packet.raw_failures,
            packet=packet,
        )

        def fake_referee(**_kw):
            raise RefereeError("referee confidence=low — insufficient evidence")

        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(ThrashHalt) as ctx:
                run_fix_loop(
                    client=object(),
                    slice_file="docs/slices/slice-09.md",
                    repo_root=tmp,
                    api_key="k",
                    budget=budget,
                    verify_fn=lambda **_kw: red,
                    referee_fn=fake_referee,
                )
        self.assertIn("referee", str(ctx.exception.reason).lower())
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
        self.assertEqual(mode_for_role("Referee"), "plan")
        self.assertEqual(mode_for_role("Engineer"), "agent")
        self.assertEqual(mode_for_role("QA"), "agent")

    def test_referee_model_is_cheap(self):
        self.assertEqual(model_for_role("Referee"), "composer-2.5")


class GateStateTests(unittest.TestCase):
    def test_slice_08_all_done(self):
        state = assess_gate_state(
            "docs/slices/slice-08-playback-integration.md", REPO
        )
        self.assertTrue(state.all_done, state.summary)
        self.assertIsNone(next_gate(state))

    def test_slice_09_done(self):
        state = assess_gate_state("docs/slices/slice-09-analysis-ui.md", REPO)
        arch = state.gate("architect")
        self.assertTrue(arch.applicable)
        self.assertEqual(arch.status, "waived")
        self.assertTrue(state.all_done, state.summary)
        self.assertIsNone(next_gate(state))

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

    def test_draft_with_full_content_story_pending_both_checkers(self):
        """Filled Crux+ACs while Draft must keep story pending in FSM and progress."""
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "slice-12-like.md")
            body = (
                "# Slice 12\n\n"
                "| Field | Value |\n"
                "|-------|-------|\n"
                "| **Status** | Draft |\n"
                "| **Crux** | Prove rate + sleep timer |\n\n"
                "## Acceptance criteria\n\n"
                "- [ ] 1. numeric AC\n\n"
                "## Role artifacts\n\n"
                "| Role | Gate | Artifact path |\n"
                "|------|------|---------------|\n"
                "| Architect | Waived | — |\n"
                "| UX | Waived | — |\n"
            )
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(body)
            self.assertTrue(_story_content_ok(body))
            self.assertFalse(_story_done(body))
            reasons = story_pending_reasons(body)
            self.assertTrue(any("Draft" in r for r in reasons), reasons)

            state = assess_gate_state(path, tmp)
            self.assertEqual(state.gate("story").status, "pending")
            self.assertEqual(next_gate(state), "story")

            heuristic = assess_slice_gates(path, tmp)
            story_h = next(g for g in heuristic["gates"] if g["id"] == "story")
            self.assertFalse(story_h["done"], heuristic["summary"])
            self.assertEqual(heuristic["next"], "story")

            msg = explain_gate_pending("story", path, tmp)
            self.assertIn("still pending", msg)
            self.assertIn("Draft", msg)
            self.assertIn("Ready", msg)

            set_slice_status(path, tmp, "Ready")
            after = assess_gate_state(path, tmp)
            self.assertEqual(after.gate("story").status, "done")
            self.assertNotEqual(next_gate(after), "story")
            heuristic2 = assess_slice_gates(path, tmp)
            story_h2 = next(g for g in heuristic2["gates"] if g["id"] == "story")
            self.assertTrue(story_h2["done"], heuristic2["summary"])

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


class AuthoringGatePromptTests(unittest.TestCase):
    def test_test_spec_prompt_bans_verify(self):
        from slice_pipeline import AUTHORING_GATES, build_gate_prompt

        prompt = build_gate_prompt(
            "test_spec",
            "docs/slices/slice-12-speed-sleep.md",
            REPO,
        )
        self.assertIn("Do NOT run scripts/verify.sh", prompt)
        self.assertIn("fail to compile", prompt)
        self.assertIn("test_spec", AUTHORING_GATES)
        self.assertNotIn("implement", AUTHORING_GATES)

    def test_parse_verify_result_class_build(self):
        v = parse_verify_result(
            "VERIFY RESULT: exit=65 total=0 passed=0 failed=0 skipped=0 "
            "filtered=1 bundle=b.xcresult tier=2 class=build"
        )
        self.assertIsNotNone(v)
        assert v is not None
        self.assertEqual(v.get("class"), "build")
        self.assertFalse(verify_is_green(v))

    def test_format_verify_result_line_includes_class(self):
        line = format_verify_result_line(
            {
                "exit": "65",
                "total": "0",
                "passed": "0",
                "failed": "0",
                "skipped": "0",
                "class": "build",
            }
        )
        self.assertIn("class=build", line)


if __name__ == "__main__":
    unittest.main()
