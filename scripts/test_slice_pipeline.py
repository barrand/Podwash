#!/usr/bin/env python3
"""Unit tests for slice_pipeline (GateState, router, verify helpers) — no SDK/Xcode."""

from __future__ import annotations

import json
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

    def test_test_ids_for_tier1_rejects_build_error(self):
        from failure_packet import FailurePacket, build_failure_packet
        from slice_pipeline import test_ids_for_tier1

        blob = (
            "VERIFY RESULT: exit=70 total=0 passed=0 failed=0 skipped=0 "
            "filtered=1 bundle=b.xcresult tier=1 class=build\n"
            'xcodebuild: error: Tests in the target "PodWash" can\'t be run because '
            '"PodWash" isn\'t a member of the specified test plan or scheme.\n'
        )
        pkt = build_failure_packet(
            failures=[],
            crashes=[],
            bundle=None,
            exit_code="70",
            output=blob,
            export_attachments=False,
        )
        self.assertEqual(pkt.test_ids, [])
        self.assertEqual(test_ids_for_tier1(pkt, pkt.raw_failures), [])
        self.assertEqual(
            test_ids_for_tier1(
                FailurePacket(test_ids=["build_error: exit=1 (0 tests executed)"]),
                ["build_error: exit=1 (0 tests executed)"],
            ),
            [],
        )

    def test_run_verify_tier2_populates_slice_tests(self):
        import tempfile
        from unittest import mock

        from slice_pipeline import run_verify

        mapping = """
## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/QueueTests.swift` | `testQueueOperationsAndPersistence` | |
"""
        with tempfile.TemporaryDirectory() as tmp:
            slice_path = os.path.join(tmp, "docs", "slices", "slice-22-foo.md")
            os.makedirs(os.path.dirname(slice_path), exist_ok=True)
            with open(slice_path, "w", encoding="utf-8") as fh:
                fh.write(mapping)
            captured: dict[str, str] = {}

            def fake_run(cmd, **kwargs):
                captured.update(kwargs.get("env") or {})
                proc = mock.MagicMock()
                proc.returncode = 0
                proc.stdout = (
                    "VERIFY RESULT: exit=0 total=1 passed=1 failed=0 skipped=0 "
                    "filtered=1 bundle=b.xcresult tier=2 class=tests\n"
                )
                proc.stderr = ""
                return proc

            with mock.patch("slice_pipeline.subprocess.run", side_effect=fake_run):
                outcome = run_verify(
                    tmp,
                    slice_file=slice_path,
                    tier=2,
                    log=lambda _m: None,
                )
            self.assertTrue(outcome.green)
            self.assertIn(
                "PodWashTests/QueueTests/testQueueOperationsAndPersistence()",
                captured.get("VERIFY_SLICE_TESTS", ""),
            )

    def test_run_verify_tier2_empty_mapping_factory_config(self):
        import tempfile

        from slice_pipeline import run_verify

        with tempfile.TemporaryDirectory() as tmp:
            slice_path = os.path.join(tmp, "docs", "slices", "slice-99-empty.md")
            os.makedirs(os.path.dirname(slice_path), exist_ok=True)
            with open(slice_path, "w", encoding="utf-8") as fh:
                fh.write("# Slice 99\n\nNo mapping table.\n")
            outcome = run_verify(
                tmp,
                slice_file=slice_path,
                tier=2,
                log=lambda _m: None,
            )
            self.assertFalse(outcome.green)
            self.assertEqual((outcome.result or {}).get("class"), "factory_config")
            self.assertTrue(
                any((f or "").startswith("factory_config:") for f in outcome.failures or [])
            )


class FixRouterTests(unittest.TestCase):
    def test_crash_routes_mechanic(self):
        self.assertEqual(
            route_fix([], ["Crash: PodWash at Foo.testBar()"]),
            "Mechanic",
        )

    def test_ambiguous_defaults_mechanic(self):
        self.assertEqual(
            route_fix(["FooTests/testSomething — XCTAssertTrue failed"], []),
            "Mechanic",
        )

    def test_same_signature_still_mechanic(self):
        fails = ["PodWashUITests/testProgress — XCTAssertTrue failed"]
        sig = failure_signature(fails, [])
        self.assertEqual(
            route_fix(
                fails,
                [],
                previous_role="Mechanic",
                previous_signature=sig,
            ),
            "Mechanic",
        )

    def test_fixture_wording_still_mechanic(self):
        self.assertEqual(
            route_fix(
                ["golden fixture XCTAssertEqual failed in PodWashTests"],
                [],
            ),
            "Mechanic",
        )

    def test_fix_budget_persists(self):
        b = FixBudget(max_attempts=2)
        b.record("Mechanic", "sig1")
        self.assertEqual(b.attempts_used, 1)
        self.assertFalse(b.exhausted())
        b.record("Mechanic", "sig1")
        self.assertTrue(b.exhausted())

    def test_build_fix_prompt_mechanic_scopes(self):
        mech = build_fix_prompt(
            "Mechanic", "docs/slices/x.md", ["t"], [], "b.xcresult", 1, 2
        )
        self.assertIn("PodWash/PodWash/**", mech)
        self.assertIn("Mechanic", mech)
        self.assertIn("docs/adr/**", mech)
        self.assertIn("Do NOT run scripts/verify.sh", mech)

    def test_halts_on_identical_signature_thrash(self):
        from failure_packet import FailurePacket
        from factory_progress import ProgressTracker

        tracker = ProgressTracker(max_spawns=8)
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
        roles: list[str] = []

        def fake_verify(**_kw):
            return red

        def capture_worker(client, role, prompt, **_kw):
            roles.append(role)
            return True, "finished"

        with tempfile.TemporaryDirectory() as tmp:
            with mock.patch("slice_pipeline.run_worker", side_effect=capture_worker), mock.patch(
                "slice_pipeline.git_paths_changed", return_value=[]
            ), mock.patch(
                "slice_pipeline.load_persona", return_value="You are Mechanic."
            ), mock.patch(
                "mechanic_fix.append_ledger"
            ), mock.patch(
                "mechanic_fix.load_ledger", return_value=[]
            ), mock.patch(
                "mechanic_fix.write_session_bundle", return_value="/tmp/x"
            ):
                with self.assertRaises(ThrashHalt) as ctx:
                    run_fix_loop(
                        client=object(),
                        slice_file="docs/slices/slice-09.md",
                        repo_root=tmp,
                        api_key="k",
                        budget=tracker,
                        verify_fn=fake_verify,
                    )
        self.assertIn("THRASH HALT", str(ctx.exception.reason))
        self.assertTrue(all(r == "Mechanic" for r in roles), roles)
        self.assertGreaterEqual(len(roles), 1)

    def test_returns_on_green(self):
        from factory_progress import ProgressTracker

        tracker = ProgressTracker(max_spawns=2)
        green = VerifyOutcome(
            result={"exit": "0", "total": "1", "passed": "1", "failed": "0", "skipped": "0"},
            green=True,
        )
        out = run_fix_loop(
            client=None,
            slice_file="x.md",
            repo_root=REPO,
            api_key="k",
            budget=tracker,
            verify_fn=lambda **_kw: green,
        )
        self.assertTrue(out.green)
        self.assertEqual(tracker.spawns_used, 0)

    def test_tier1_then_tier3_on_fix_green(self):
        from failure_packet import FailurePacket
        from factory_progress import ProgressTracker

        tracker = ProgressTracker(max_spawns=2)
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

        with tempfile.TemporaryDirectory() as tmp:
            with mock.patch("slice_pipeline.run_worker", return_value=(True, "finished")), mock.patch(
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
                    slice_file="docs/slices/slice-10.md",
                    repo_root=tmp,
                    api_key="k",
                    budget=tracker,
                    verify_fn=fake_verify,
                )
        self.assertTrue(out.green)
        self.assertEqual(tiers[:3], [3, 1, 3])
        self.assertEqual(tracker.spawns_used, 1)


class ModelModeMapTests(unittest.TestCase):
    def test_models_are_plain_ids(self):
        self.assertEqual(model_for_role("PM"), "composer-2.5")
        self.assertEqual(model_for_role("Engineer"), "grok-4.5")
        self.assertEqual(model_for_role("Mechanic"), "grok-4.5")
        self.assertNotIn("[", model_for_role("Architect"))

    def test_reviewers_use_plan_mode(self):
        self.assertEqual(mode_for_role("QA review"), "plan")
        self.assertEqual(mode_for_role("PM review"), "plan")
        self.assertEqual(mode_for_role("Architect review"), "plan")
        self.assertEqual(mode_for_role("Engineer"), "agent")
        self.assertEqual(mode_for_role("QA"), "agent")
        self.assertEqual(mode_for_role("Mechanic"), "agent")

    def test_mechanic_model_is_grok(self):
        self.assertEqual(model_for_role("Mechanic"), "grok-4.5")
        self.assertEqual(mode_for_role("Mechanic"), "agent")


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

    def test_architect_prompt_includes_resolved_adr_path(self):
        from slice_pipeline import build_gate_prompt

        with tempfile.TemporaryDirectory() as tmp:
            adr = os.path.join(tmp, "docs", "adr")
            slices = os.path.join(tmp, "docs", "slices")
            os.makedirs(adr)
            os.makedirs(slices)
            with open(os.path.join(adr, "016-carplay.md"), "w", encoding="utf-8") as fh:
                fh.write("# 016\n")
            path = os.path.join(slices, "slice-16-beep-overlay.md")
            body = (
                "# Slice 16\n\n"
                "## Role artifacts\n\n"
                "| Role | Gate | Artifact path |\n"
                "|------|------|---------------|\n"
                "| Architect | Required | `docs/adr/0XX-overlay-sync.md` |\n"
            )
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(body)
            prompt = build_gate_prompt("architect", path, tmp)
            self.assertIn("docs/adr/017-overlay-sync.md", prompt)
            self.assertIn("xcodebuild", prompt)
            self.assertIn("Spike", prompt)
            self.assertIn("verify.sh", prompt)

    def test_explain_gate_pending_architect_resolved_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            adr = os.path.join(tmp, "docs", "adr")
            slices = os.path.join(tmp, "docs", "slices")
            os.makedirs(adr)
            os.makedirs(slices)
            with open(os.path.join(adr, "016-carplay.md"), "w", encoding="utf-8") as fh:
                fh.write("# 016\n")
            path = os.path.join(slices, "slice-16-beep-overlay.md")
            body = (
                "# Slice 16\n\n"
                "| Field | Value |\n"
                "|-------|-------|\n"
                "| **Status** | Ready |\n\n"
                "## Role artifacts\n\n"
                "| Role | Gate | Artifact path |\n"
                "|------|------|---------------|\n"
                "| Architect | Required | `docs/adr/0XX-overlay-sync.md` |\n"
            )
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(body)
            msg = explain_gate_pending("architect", path, tmp)
            self.assertIn("docs/adr/017-overlay-sync.md", msg)
            self.assertNotIn("0XX", msg)

    def test_persist_gate_stuck_halt_writes_bundle(self):
        from slice_pipeline import _persist_gate_stuck_halt

        with tempfile.TemporaryDirectory() as tmp:
            tr = os.path.join(tmp, "build", "test-results")
            os.makedirs(tr)
            slices = os.path.join(tmp, "docs", "slices")
            os.makedirs(slices)
            path = os.path.join(slices, "slice-16-beep-overlay.md")
            with open(path, "w", encoding="utf-8") as fh:
                fh.write("# Slice 16\n")
            logs: list[str] = []
            explain = (
                "gate architect still pending after worker — stopping. "
                "(Status=Ready; missing artifacts: ['docs/adr/017-overlay-sync.md']) "
                "unblock: create docs/adr/017-overlay-sync.md"
            )
            _persist_gate_stuck_halt(
                slice_id=16,
                gate_id="architect",
                gate_label="architect",
                explain=explain,
                agent="Ada",
                slice_file=path,
                repo_root=tmp,
                log=logs.append,
            )
            bundle = os.path.join(tr, "session-slice-16", "halt.json")
            self.assertTrue(os.path.isfile(bundle))
            self.assertTrue(any("session bundle" in l for l in logs))
            with open(bundle, encoding="utf-8") as fh:
                meta = json.load(fh)
            self.assertEqual(meta.get("phase"), "GATE-ARCHITECT")
            self.assertEqual(meta.get("extra", {}).get("halt_kind"), "gate_stuck")

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


class BridgeCloseHaltTests(unittest.TestCase):
    def test_is_bridge_network_error(self):
        from slice_pipeline import _is_bridge_network_error

        class NetworkError(Exception):
            pass

        self.assertTrue(
            _is_bridge_network_error(
                NetworkError("Server disconnected without sending a response.")
            )
        )
        self.assertTrue(
            _is_bridge_network_error(
                RuntimeError("Bridge request failed: RemoteProtocolError")
            )
        )
        self.assertFalse(_is_bridge_network_error(ValueError("not network")))

    def test_run_worker_bridge_close_raises_infra_halt(self):
        from unittest import mock

        from slice_loop_progress import RunProgress
        from slice_pipeline import InfraHalt, run_worker

        class NetworkError(Exception):
            pass

        class FakeRun:
            def messages(self):
                return iter([])

            def wait(self):
                class R:
                    status = "finished"

                return R()

        class FakeAgent:
            agent_id = "a1"

            def send(self, _prompt: str) -> FakeRun:
                return FakeRun()

            def __enter__(self) -> "FakeAgent":
                return self

            def __exit__(self, *_args: object) -> None:
                raise NetworkError(
                    "Bridge request failed: RemoteProtocolError: "
                    "Server disconnected without sending a response."
                )

        class FakeClient:
            def create_agent(self, _options: object) -> FakeAgent:
                return FakeAgent()

        fake_sdk = mock.MagicMock()
        fake_sdk.AgentOptions = mock.MagicMock(return_value=object())
        fake_sdk.LocalAgentOptions = mock.MagicMock(return_value=object())

        with tempfile.TemporaryDirectory() as tmp:
            os.makedirs(os.path.join(tmp, "build", "test-results"))
            logs: list[str] = []
            prog = RunProgress(
                16,
                "Beep overlay",
                "docs/slices/slice-16-beep-overlay.md",
                logs.append,
                authoring_gate=True,
                gate_id="architect",
                forced_role="Architect",
                repo_root=tmp,
            )
            with mock.patch.dict(sys.modules, {"cursor_sdk": fake_sdk}):
                with mock.patch(
                    "slice_pipeline.sdk_model_for_role", return_value="m"
                ), mock.patch(
                    "slice_pipeline.format_sdk_model", return_value="m"
                ):
                    with self.assertRaises(InfraHalt) as ctx:
                        run_worker(
                            FakeClient(),
                            role="Architect",
                            prompt="write ADR",
                            api_key="test-key",
                            repo_root=tmp,
                            log=logs.append,
                            progress=prog,
                        )
            self.assertIn("bridge disconnect", ctx.exception.reason)
            self.assertTrue(any("INFRA HALT" in l for l in logs))
            halt = os.path.join(
                tmp, "build", "test-results", "session-slice-16", "halt.json"
            )
            self.assertTrue(os.path.isfile(halt))
            with open(halt, encoding="utf-8") as fh:
                meta = json.load(fh)
            self.assertEqual(meta.get("phase"), "BRIDGE-CLOSE")
            self.assertEqual(meta.get("extra", {}).get("halt_kind"), "bridge_close")


class CommitPathFilterTests(unittest.TestCase):
    def test_ignored_pycache_paths(self):
        from slice_pipeline import is_ignored_commit_path

        self.assertTrue(
            is_ignored_commit_path("scripts/__pycache__/slice_pipeline.cpython-313.pyc")
        )
        self.assertFalse(is_ignored_commit_path("scripts/slice_pipeline.py"))

    def test_git_paths_changed_skips_pycache(self):
        from slice_pipeline import git_paths_changed

        with tempfile.TemporaryDirectory() as tmp:
            subprocess = __import__("subprocess")
            os.makedirs(os.path.join(tmp, "scripts", "__pycache__"), exist_ok=True)
            real_file = os.path.join(tmp, "docs", "note.md")
            os.makedirs(os.path.dirname(real_file), exist_ok=True)
            with open(real_file, "w", encoding="utf-8") as fh:
                fh.write("v1\n")
            pyc = os.path.join(
                tmp, "scripts", "__pycache__", "slice_pipeline.cpython-313.pyc"
            )
            subprocess.run(["git", "init"], cwd=tmp, capture_output=True, check=True)
            subprocess.run(
                ["git", "add", "docs/note.md"],
                cwd=tmp,
                capture_output=True,
                check=True,
            )
            subprocess.run(
                ["git", "commit", "-m", "init"],
                cwd=tmp,
                capture_output=True,
                check=True,
            )
            with open(real_file, "w", encoding="utf-8") as fh:
                fh.write("v2\n")
            with open(pyc, "wb") as fh:
                fh.write(b"\x00\x01")
            paths = git_paths_changed(tmp)
            self.assertEqual(paths, ["docs/note.md"])


if __name__ == "__main__":
    unittest.main()
