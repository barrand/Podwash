#!/usr/bin/env python3
"""Unit tests for FailurePacket, stuck card, classifier, playbooks."""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from unittest import mock

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)

from failure_packet import (  # noqa: E402
    FailurePacket,
    build_failure_packet,
    classify_failure,
    format_stuck_card,
    merge_diagnose_into_packet,
    packet_signature,
    parse_attachment_texts,
    parse_diagnose_reply,
    persist_stuck_card,
    summary_test_failures,
)
from fix_playbooks import select_lever, starter_lever_text  # noqa: E402
from slice_loop_progress import RunProgress, is_verify_run  # noqa: E402
from slice_pipeline import (  # noqa: E402
    FixBudget,
    VerifyOutcome,
    build_fix_prompt,
    route_fix,
    run_fix_loop,
)
from slice_loop_progress import ThrashHalt  # noqa: E402

REPO = os.path.dirname(SCRIPT_DIR)

SAMPLE_SUMMARY = {
    "testFailures": [
        {
            "failureText": "XCTAssertTrue failed",
            "targetName": "PodWashUITests",
            "testIdentifierString": "AnalysisProgressUITests/testProgressIndicatorLifecycle()",
            "testName": "testProgressIndicatorLifecycle()",
        }
    ]
}


class SummaryParseTests(unittest.TestCase):
    def test_summary_test_ids(self):
        pairs = summary_test_failures(SAMPLE_SUMMARY)
        self.assertEqual(len(pairs), 1)
        tid, detail = pairs[0]
        self.assertIn("AnalysisProgressUITests/testProgressIndicatorLifecycle()", tid)
        self.assertIn("PodWashUITests", tid)
        self.assertIn("XCTAssertTrue", detail)


class AttachmentParseTests(unittest.TestCase):
    def test_parse_query_and_hierarchy(self):
        with tempfile.TemporaryDirectory() as tmp:
            hier = (
                "Application, 0x1, pid: 1, label: 'PodWash'\n"
                "  Other, identifier: 'cleaningBadge_episodeOn', label: 'On'\n"
                "  Other, identifier: 'episodeList'\n"
            )
            query = (
                "Query chain:\n"
                ' →Find: Elements matching predicate \'"analysisProgress" IN identifiers\'\n'
            )
            open(os.path.join(tmp, "h.txt"), "w").write(hier)
            open(os.path.join(tmp, "q.txt"), "w").write(query)
            man = [
                {
                    "attachments": [
                        {
                            "exportedFileName": "h.txt",
                            "suggestedHumanReadableName": "App UI hierarchy for PodWash",
                        },
                        {
                            "exportedFileName": "q.txt",
                            "suggestedHumanReadableName": (
                                'Debug description for `"analysisProgress" Any`'
                            ),
                        },
                    ]
                }
            ]
            open(os.path.join(tmp, "manifest.json"), "w").write(json.dumps(man))
            hierarchy, queries, got = parse_attachment_texts(tmp)
            self.assertIn("analysisProgress", queries)
            self.assertIn("cleaningBadge_episodeOn", hierarchy)
            self.assertTrue(got)


class FlakeSignalTests(unittest.TestCase):
    def test_xctwaiter_timeout_is_not_flake(self):
        from failure_packet import is_flake_signal

        packet = FailurePacket(
            test_ids=[
                "PodWashUITests/AnalysisProgressUITests/testProgressIndicatorLifecycle()"
            ],
            assertions=[
                "Asynchronous wait failed: Exceeded timeout of 2 seconds, with "
                "unfulfilled expectations: Expect predicate BLOCKPREDICATE"
            ],
            failure_class="ui_race",
            raw_failures=[
                "PodWashUITests/AnalysisProgressUITests/testProgressIndicatorLifecycle() "
                "— Asynchronous wait failed: Exceeded timeout of 2 seconds"
            ],
        )
        self.assertFalse(is_flake_signal(packet))
        self.assertEqual(classify_failure(packet), "ui_race")

    def test_idle_is_flake(self):
        from failure_packet import is_flake_signal

        packet = FailurePacket(
            test_ids=["PodWashUITests/T/testA()"],
            assertions=["Failed to become idle"],
            raw_failures=["Failed to become idle"],
            failure_class="flake",
        )
        self.assertTrue(is_flake_signal(packet))


class InferQueryTests(unittest.TestCase):
    def test_infer_analysis_progress(self):
        from failure_packet import infer_failed_queries

        qs = infer_failed_queries(
            ["PodWashUITests/AnalysisProgressUITests/testProgressIndicatorLifecycle()"],
            ["Asynchronous wait failed: Exceeded timeout of 2 seconds"],
        )
        self.assertIn("analysisProgress", qs)


class PacketBuilderTests(unittest.TestCase):
    def test_sparse_shell_rich_summary(self):
        with mock.patch(
            "failure_packet.read_xcresult_summary", return_value=SAMPLE_SUMMARY
        ), mock.patch(
            "failure_packet.export_attachments_for_test", return_value=None
        ):
            packet = build_failure_packet(
                failures=["xcodebuild — TEST FAILED"],
                crashes=[],
                bundle="/fake.xcresult",
                exit_code="65",
                export_attachments=False,
            )
        self.assertTrue(packet.test_ids)
        self.assertFalse(
            any(r.lower().startswith("xcodebuild") for r in packet.raw_failures)
        )
        self.assertIn("testProgressIndicatorLifecycle", packet.test_ids[0])
        card = format_stuck_card(packet, slice_file="docs/slices/slice-09-x.md")
        self.assertIn("testProgressIndicatorLifecycle", card)
        self.assertIn("STUCK — Slice 09", card)

    def test_wait_timeout_infers_query_without_hierarchy(self):
        summary = {
            "testFailures": [
                {
                    "failureText": (
                        "Asynchronous wait failed: Exceeded timeout of 2 seconds, "
                        "with unfulfilled expectations: "
                        '"Expect predicate `BLOCKPREDICATE` for object '
                        "Target Application 'com.barrandfarm.PodWash'\"."
                    ),
                    "targetName": "PodWashUITests",
                    "testIdentifierString": (
                        "AnalysisProgressUITests/testProgressIndicatorLifecycle()"
                    ),
                    "testName": "testProgressIndicatorLifecycle()",
                }
            ]
        }
        with tempfile.TemporaryDirectory() as tmp:
            # Sparse NSPredicate attachments — Target Application only
            open(os.path.join(tmp, "q.txt"), "w", encoding="utf-8").write(
                "Query chain:\n →Find: Target Application 'com.barrandfarm.PodWash'\n"
            )
            open(os.path.join(tmp, "manifest.json"), "w", encoding="utf-8").write(
                json.dumps(
                    [
                        {
                            "attachments": [
                                {
                                    "exportedFileName": "q.txt",
                                    "suggestedHumanReadableName": (
                                        "Debug description for Target Application"
                                    ),
                                }
                            ]
                        }
                    ]
                )
            )
            with mock.patch(
                "failure_packet.read_xcresult_summary", return_value=summary
            ), mock.patch(
                "failure_packet.export_attachments_for_test", return_value=tmp
            ):
                packet = build_failure_packet(
                    failures=["xcodebuild — TEST FAILED"],
                    crashes=[],
                    bundle="/fake.xcresult",
                    export_attachments=True,
                )
        self.assertEqual(packet.failure_class, "ui_race")
        self.assertIn("analysisProgress", packet.failed_queries)
        from failure_packet import is_flake_signal

        self.assertFalse(is_flake_signal(packet))
        card = format_stuck_card(packet, slice_file="docs/slices/slice-09.md")
        self.assertIn("analysisProgress", card)

    def test_ui_race_class_from_attachments(self):
        with tempfile.TemporaryDirectory() as tmp:
            hier = "Other, identifier: 'cleaningBadge_episodeOn'\n"
            query = '"analysisProgress" IN identifiers\n'
            with open(os.path.join(tmp, "h.txt"), "w", encoding="utf-8") as fh:
                fh.write(hier)
            with open(os.path.join(tmp, "q.txt"), "w", encoding="utf-8") as fh:
                fh.write(query)
            with open(os.path.join(tmp, "manifest.json"), "w", encoding="utf-8") as fh:
                fh.write(
                    json.dumps(
                        [
                            {
                                "attachments": [
                                    {
                                        "exportedFileName": "h.txt",
                                        "suggestedHumanReadableName": "App UI hierarchy",
                                    },
                                    {
                                        "exportedFileName": "q.txt",
                                        "suggestedHumanReadableName": "Debug description",
                                    },
                                ]
                            }
                        ]
                    )
                )
            with mock.patch(
                "failure_packet.read_xcresult_summary", return_value=SAMPLE_SUMMARY
            ), mock.patch(
                "failure_packet.export_attachments_for_test", return_value=tmp
            ):
                packet = build_failure_packet(
                    failures=["xcodebuild — TEST FAILED"],
                    crashes=[],
                    bundle="/fake.xcresult",
                    export_attachments=True,
                )
        self.assertEqual(packet.failure_class, "ui_race")
        self.assertIn("analysisProgress", packet.failed_queries)

    def test_build_error_soft_undiagnosable(self):
        packet = build_failure_packet(
            failures=["error: cannot find type 'Foo' in scope", "SwiftCompile failed"],
            crashes=[],
            bundle=None,
            exit_code="65",
            output="** BUILD FAILED **",
            export_attachments=False,
        )
        self.assertTrue(packet.actionable)
        self.assertEqual(packet.failure_class, "build_error")
        card = format_stuck_card(packet, slice_file="docs/slices/slice-01.md")
        self.assertIn("build_error", card)

    def test_hard_halt_no_evidence(self):
        packet = build_failure_packet(
            failures=[],
            crashes=[],
            bundle=None,
            exit_code="1",
            output="",
            export_attachments=False,
        )
        self.assertFalse(packet.actionable)
        self.assertIn("DIAGNOSE FAILED", packet.halt_reason)

    def test_signature_stable_across_assertion_jitter(self):
        a = packet_signature(
            ["PodWashUITests/AnalysisProgressUITests/testProgressIndicatorLifecycle()"],
            [],
        )
        b = packet_signature(
            ["PodWashUITests/AnalysisProgressUITests/testProgressIndicatorLifecycle()"],
            [],
        )
        self.assertEqual(a, b)
        self.assertNotIn("xctassert", a.lower())


class StuckCardPersistTests(unittest.TestCase):
    def test_persist(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = persist_stuck_card(
                "STUCK — Slice 09\nTest: x",
                repo_root=tmp,
                slice_file="docs/slices/slice-09-analysis-ui.md",
            )
            self.assertTrue(os.path.isfile(path))
            self.assertTrue(path.endswith("stuck-slice-09.txt"))
            self.assertIn("STUCK", open(path).read())


class ClassifyTests(unittest.TestCase):
    def test_crash(self):
        p = FailurePacket(crashes=["Crash: PodWash EXC_BAD_ACCESS"], test_ids=[])
        self.assertEqual(classify_failure(p), "crash")

    def test_assertion(self):
        p = FailurePacket(
            test_ids=["PodWashTests/FooTests/testBar()"],
            assertions=["XCTAssertEqual failed"],
            raw_failures=["PodWashTests/FooTests/testBar() — XCTAssertEqual failed"],
        )
        self.assertEqual(classify_failure(p), "assertion")

    def test_missing_bundle_executable_is_build_error(self):
        """Death-run runs 1–2: install failure must not look like a mystery crash."""
        p = FailurePacket(
            test_ids=["PodWash encountered an error"],
            raw_failures=[
                "PodWashTests/PodWash encountered an error — Failed to install "
                "or launch: PodWash.app is missing its bundle executable"
            ],
        )
        self.assertEqual(classify_failure(p), "build_error")


class DiagnoseMergeTests(unittest.TestCase):
    def test_parse_and_heuristic_wins(self):
        text = (
            "class: assertion\n"
            "hypothesis: progress finishes too fast\n"
            "fix_scope: app\n"
            "suggested_files: PodWash/PodWash/EpisodeListView.swift\n"
        )
        parsed = parse_diagnose_reply(text)
        self.assertEqual(parsed["class"], "assertion")
        packet = FailurePacket(failure_class="ui_race")
        merged = merge_diagnose_into_packet(packet, parsed)
        self.assertEqual(merged.failure_class, "ui_race")  # heuristic wins
        self.assertEqual(merged.fix_scope, "app")
        self.assertIn("EpisodeListView", merged.suggested_files[0])

    def test_unknown_may_be_overwritten(self):
        packet = FailurePacket(failure_class="unknown")
        merged = merge_diagnose_into_packet(
            packet, {"class": "ui_race", "hypothesis": "race"}
        )
        self.assertEqual(merged.failure_class, "ui_race")


class PlaybookTests(unittest.TestCase):
    def test_ui_race_lever1_is_second_engineer(self):
        lever = select_lever("ui_race", lever_index=1, fix_scope="app")
        self.assertEqual(lever.role, "Engineer")
        self.assertIn("attempt 1", lever.instruction.lower())

    def test_ui_race_lever2_halts_by_default(self):
        lever = select_lever("ui_race", lever_index=2, fix_scope="app")
        self.assertEqual(lever.role, "halt")

    def test_ui_race_lever2_qa_when_allowed(self):
        lever = select_lever(
            "ui_race",
            lever_index=2,
            fix_scope="tests",
            allow_uitest_wait_fix=True,
        )
        self.assertEqual(lever.role, "QA")

    def test_starter_text(self):
        self.assertIn("observable", starter_lever_text("ui_race").lower())


class FixPromptTests(unittest.TestCase):
    def test_prompt_embeds_packet_and_ban(self):
        packet = FailurePacket(
            test_ids=["PodWashUITests/X/testY()"],
            failure_class="ui_race",
            assertions=["XCTAssertTrue failed"],
            failed_queries=["analysisProgress"],
        )
        prompt = build_fix_prompt(
            "Engineer",
            "docs/slices/slice-09.md",
            packet.raw_failures or ["t"],
            [],
            "b.xcresult",
            1,
            2,
            packet=packet,
            stuck_card="STUCK — Slice 09\nTest: t",
            lever_instruction="hold analyzing state",
            attempt_notes=["attempt 1: role=Engineer"],
        )
        self.assertIn("Do NOT run scripts/verify.sh", prompt)
        self.assertIn("hold analyzing state", prompt)
        self.assertIn("ui_race", prompt)
        self.assertIn("Attempt history", prompt)


class VerifyBanTests(unittest.TestCase):
    def test_is_verify_run(self):
        self.assertTrue(is_verify_run("scripts/verify.sh"))
        self.assertTrue(is_verify_run("xcodebuild test -scheme PodWash"))
        self.assertFalse(is_verify_run("xcrun xcresulttool get test-results summary"))

    def test_fix_worker_skips_nested_thrash(self):
        lines: list[str] = []
        progress = RunProgress(
            9,
            "Analysis UI",
            "docs/slices/slice-09.md",
            lines.append,
            fix_worker=True,
            forced_role="Engineer",
        )
        self.assertEqual(progress.active_role(), "Engineer")
        self.assertEqual(progress.max_red_verifies, 0)
        progress._record_red_verify(
            ["fail"],
            cmd="scripts/verify.sh",
            blob="TEST FAILED",
            verify={"exit": "1", "failed": "1", "skipped": "0", "passed": "0", "total": "1"},
        )
        self.assertEqual(progress._red_verify_count, 0)
        self.assertFalse(progress.halted)

    def test_first_violation_does_not_burn(self):
        lines: list[str] = []
        progress = RunProgress(
            9, "t", "docs/slices/slice-09.md", lines.append,
            fix_worker=True, forced_role="QA",
        )
        progress._handle_verify_ban("scripts/verify.sh")
        self.assertEqual(progress._verify_violations, 1)
        self.assertFalse(progress.verify_violation_burned)
        progress._handle_verify_ban("xcodebuild test -scheme X")
        self.assertTrue(progress.verify_violation_burned)


class FixLoopPacketTests(unittest.TestCase):
    def test_halts_when_no_actionable(self):
        budget = FixBudget(max_attempts=2)
        red = VerifyOutcome(
            result={"exit": "1", "total": "?", "passed": "?", "failed": "?", "skipped": "?"},
            green=False,
            failures=[],
            packet=FailurePacket(
                actionable=False,
                halt_reason="DIAGNOSE FAILED: no actionable evidence",
            ),
        )

        def fake_verify(**_kw):
            return red

        with self.assertRaises(ThrashHalt) as ctx:
            run_fix_loop(
                client=None,
                slice_file="docs/slices/slice-09.md",
                repo_root=REPO,
                api_key="k",
                budget=budget,
                verify_fn=fake_verify,
            )
        self.assertIn("DIAGNOSE FAILED", str(ctx.exception.reason))

    def test_flake_cold_retry_no_budget(self):
        budget = FixBudget(max_attempts=2)
        calls = {"n": 0}
        flake = VerifyOutcome(
            result={"exit": "1", "failed": "1", "passed": "0", "skipped": "0", "total": "1"},
            green=False,
            failures=["Failed to become idle"],
            packet=FailurePacket(
                test_ids=["PodWashUITests/T/testA()"],
                raw_failures=["Failed to become idle"],
                failure_class="flake",
                signature="PodWashUITests/T/testA()",
                actionable=True,
            ),
        )
        green = VerifyOutcome(
            result={"exit": "0", "failed": "0", "passed": "1", "skipped": "0", "total": "1"},
            green=True,
        )

        def fake_verify(**_kw):
            calls["n"] += 1
            return flake if calls["n"] == 1 else green

        out = run_fix_loop(
            client=None,
            slice_file="docs/slices/slice-09.md",
            repo_root=REPO,
            api_key="k",
            budget=budget,
            verify_fn=fake_verify,
        )
        self.assertTrue(out.green)
        self.assertEqual(budget.attempts_used, 0)
        self.assertTrue(budget.flake_cold_retried)

    def test_attempt_memory_second_prompt(self):
        from referee import RefereeVerdict

        budget = FixBudget(max_attempts=2)
        packet = FailurePacket(
            test_ids=["PodWashUITests/AnalysisProgressUITests/testProgressIndicatorLifecycle()"],
            assertions=["XCTAssertTrue failed"],
            failed_queries=["analysisProgress"],
            hierarchy_excerpt="[got] cleaningBadge_episodeOn present; analysisProgress query empty",
            failure_class="ui_race",
            signature="PodWashUITests/AnalysisProgressUITests/testProgressIndicatorLifecycle()",
            raw_failures=[
                "PodWashUITests/AnalysisProgressUITests/testProgressIndicatorLifecycle() — XCTAssertTrue failed"
            ],
            actionable=True,
        )
        red = VerifyOutcome(
            result={"exit": "1", "failed": "1", "passed": "0", "skipped": "0", "total": "1",
                    "bundle": "b.xcresult"},
            green=False,
            failures=packet.raw_failures,
            packet=packet,
        )
        prompts: list[str] = []
        refs = {"n": 0}

        def fake_verify(**_kw):
            return red

        def fake_worker(*_a, **kwargs):
            prompts.append(kwargs.get("prompt") or "")
            return True, "finished"

        def fake_referee(**_kw):
            refs["n"] += 1
            return RefereeVerdict(
                primary_failure=packet.test_ids[0],
                role="Engineer",
                fix_scope="app",
                files=["PodWash/PodWash/EpisodeListView.swift"],
                instruction="Hold analyzing state so UITests can observe progress",
                hypothesis=f"download refresh clobbers analysisProgress AX (try {refs['n']})",
                confidence="high",
            )

        with tempfile.TemporaryDirectory() as tmp:
            with mock.patch("slice_pipeline.run_worker", side_effect=fake_worker):
                with self.assertRaises(ThrashHalt):
                    run_fix_loop(
                        client=object(),
                        slice_file="docs/slices/slice-09-analysis-ui.md",
                        repo_root=tmp,
                        api_key="k",
                        budget=budget,
                        verify_fn=fake_verify,
                        referee_fn=fake_referee,
                    )
        fix_prompts = [p for p in prompts if "fix worker" in p]
        self.assertGreaterEqual(len(fix_prompts), 2)
        self.assertIn("Attempt history", fix_prompts[1])
        self.assertIn("Hold analyzing", fix_prompts[0])
        self.assertIn("Hypothesis ledger", fix_prompts[0])


class RouteWithPacketTests(unittest.TestCase):
    def test_ui_race_engineer(self):
        p = FailurePacket(failure_class="ui_race", signature="t1")
        self.assertEqual(route_fix([], [], packet=p), "Engineer")

    def test_lever_role_overrides(self):
        p = FailurePacket(failure_class="ui_race", signature="t1")
        self.assertEqual(
            route_fix([], [], packet=p, lever_role="QA"),
            "QA",
        )


if __name__ == "__main__":
    unittest.main()
