#!/usr/bin/env python3
"""Unit tests for slice-loop progress formatting (no SDK / Xcode)."""

import os
import sys
import unittest

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)

from slice_loop_progress import (  # noqa: E402
    RunProgress,
    ThrashHalt,
    assess_slice_gates,
    delegate_violation,
    detect_simulator_crashes,
    detect_test_failures,
    detect_wrong_role_spawn,
    failure_signature,
    format_active_tasks,
    format_gate_detail,
    infer_role,
    is_verify_run,
    list_new_podwash_ips,
    parse_verify_result,
    read_slice_meta,
    role_edit_paths,
    shell_result_note,
    summarize_ips_crash,
    summarize_tool,
    verify_is_green,
)


class ProgressFormattingTests(unittest.TestCase):
    def test_infer_role_pm(self):
        args = {
            "description": "PM story gate Slice 06",
            "subagent_type": "generalPurpose",
            "prompt": "You are the PM agent for PodWash Slice 06.",
        }
        self.assertEqual(infer_role(args), "PM")

    def test_infer_role_qa_review(self):
        args = {
            "description": "QA ADR plan review readonly",
            "readonly": True,
            "prompt": "You are the QA agent reviewing an Architect ADR (READONLY).",
        }
        self.assertEqual(infer_role(args), "QA review")

    def test_infer_role_engineer_subagent(self):
        args = {"subagent_type": "podwash-engineer", "description": "Implement slice"}
        self.assertEqual(infer_role(args), "Engineer")

    def test_summarize_edit_with_path(self):
        label = summarize_tool(
            "edit",
            {"path": "docs/slices/slice-06-rss-episode-list.md"},
        )
        self.assertIn("edit", label)
        self.assertIn("slice-06-rss-episode-list.md", label)

    def test_summarize_verify_shell_running(self):
        label = summarize_tool(
            "shell",
            {"command": "scripts/verify.sh -only-testing:PodWashTests/Foo"},
        )
        self.assertIn("verify.sh", label)
        self.assertIn("filtered", label)

    def test_summarize_verify_shell_complete_green(self):
        result = (
            "VERIFY RESULT: exit=0 total=42 passed=42 failed=0 skipped=0 "
            "filtered=0 bundle=build/test-results/verify.xcresult"
        )
        label = summarize_tool("shell", {"command": "scripts/verify.sh"}, result)
        self.assertIn("GREEN", label)
        self.assertIn("42/42", label)

    def test_parse_verify_result(self):
        v = parse_verify_result(
            "VERIFY RESULT: exit=0 total=10 passed=10 failed=0 skipped=0 filtered=0"
        )
        self.assertTrue(verify_is_green(v))
        self.assertEqual(v["passed"], "10")

    def test_shell_result_note_commit(self):
        self.assertEqual(
            shell_result_note({"command": "git commit -m 'slice-06: foo'"}, "ok"),
            "committed",
        )

    def test_detect_simulator_crashes_from_xcresult_text(self):
        blob = (
            "Crash: PodWash at AnalysisUIStateTests.testStateMachineTransitions()\n"
            "Crash: PodWash at AnalysisUIStateTests.testTogglePersistence()\n"
            "Crash: PodWash at AnalysisUIStateTests.testStateMachineTransitions()\n"
        )
        crashes = detect_simulator_crashes(blob)
        self.assertEqual(len(crashes), 2)
        self.assertIn("testStateMachineTransitions", crashes[0])

    def test_detect_test_failures_from_xctest_output(self):
        blob = (
            "Test Case '-[AnalysisProgressUITests testProgressIndicatorLifecycle]' failed "
            "(0.123 seconds).\n"
            "    error: XCTAssertTrue failed\n"
            "Test Case '-[AnalysisProgressUITests testToggleBadges]' failed "
            "(0.456 seconds).\n"
            "    error: XCTAssertEqual failed: (\"off\") is not equal to (\"on\")\n"
            "Executed 4 tests, with 2 failures (0 unexpected) in 1.2 (1.3) seconds\n"
        )
        failures = detect_test_failures(blob)
        self.assertGreaterEqual(len(failures), 2)
        self.assertTrue(any("testProgressIndicatorLifecycle" in f for f in failures))
        self.assertTrue(any("XCTAssertTrue" in f for f in failures))

    def test_shell_result_note_includes_failure_count(self):
        result = (
            "Test Case '-[AnalysisProgressUITests testProgressIndicatorLifecycle]' failed.\n"
            "    error: XCTAssertTrue failed\n"
            "VERIFY RESULT: exit=1 total=4 passed=3 failed=1 skipped=0 filtered=1"
        )
        note = shell_result_note({"command": "scripts/verify.sh"}, result)
        self.assertIn("RED", note)
        self.assertIn("FAIL", note)

    def test_run_progress_announces_test_failure_once(self):
        lines: list[str] = []

        progress = RunProgress(9, "Analysis UI", "docs/slices/slice-09.md", lines.append)
        progress._run_started_at = 1.0
        progress._announce_test_failures(
            ["AnalysisProgressUITests/testProgressIndicatorLifecycle — XCTAssertTrue failed"],
            source="verify/xcodebuild",
        )
        progress._announce_test_failures(
            ["AnalysisProgressUITests/testProgressIndicatorLifecycle — XCTAssertTrue failed"],
            source="verify/xcodebuild",
        )
        fail_lines = [l for l in lines if "TEST FAIL" in l]
        same_lines = [l for l in lines if "same failure" in l]
        self.assertEqual(len(fail_lines), 1)
        self.assertEqual(len(same_lines), 1)
        self.assertIn("×2", same_lines[0])
        self.assertIn("testProgressIndicatorLifecycle", progress._known_failing_test)

    def test_detect_wrong_role_spawn_ux_fix(self):
        msg = detect_wrong_role_spawn("UX", "Fix progress UI test failure")
        self.assertIsNotNone(msg)
        self.assertIn("podwash-engineer", msg or "")
        self.assertIsNone(detect_wrong_role_spawn("Engineer", "Fix progress UI test"))
        self.assertIsNone(detect_wrong_role_spawn("UX", "Write slice-09 UX scenarios"))

    def test_failure_signature_prefers_test_id(self):
        sig = failure_signature(
            ["AnalysisProgressUITests/testProgressIndicatorLifecycle — XCTAssertTrue failed"]
        )
        self.assertIn("testProgressIndicatorLifecycle", sig)

    def test_role_edit_paths_ux_forbids_app(self):
        self.assertIn("MUST NOT", role_edit_paths("UX"))
        self.assertIn("PodWash/PodWash", role_edit_paths("Engineer"))

    def test_halt_after_two_red_verifies(self):
        lines: list[str] = []
        progress = RunProgress(
            9,
            "Analysis UI",
            "docs/slices/slice-09.md",
            lines.append,
            max_red_verifies=2,
        )
        red_blob = (
            "Test Case '-[AnalysisProgressUITests testProgressIndicatorLifecycle]' failed.\n"
            "    error: XCTAssertTrue failed\n"
            "VERIFY RESULT: exit=1 total=4 passed=3 failed=1 skipped=0 filtered=1\n"
            "** TEST FAILED **\n"
        )
        progress._tool(
            "c1",
            "shell",
            "completed",
            {"command": "scripts/verify.sh -only-testing:PodWashUITests"},
            red_blob,
        )
        self.assertEqual(progress._red_verify_count, 1)
        self.assertFalse(progress.halted)
        with self.assertRaises(ThrashHalt) as ctx:
            progress._tool(
                "c2",
                "shell",
                "completed",
                {"command": "scripts/verify.sh"},
                red_blob,
            )
        self.assertTrue(progress.halted)
        self.assertEqual(progress._red_verify_count, 2)
        self.assertIn("HALT", str(ctx.exception))
        halt_logs = [l for l in lines if "🛑" in l or "HALT" in l]
        self.assertTrue(any("What happened" in l or "HALT" in l for l in halt_logs))

    def test_xcresulttool_does_not_count_as_red_verify(self):
        lines: list[str] = []
        progress = RunProgress(
            9,
            "Analysis UI",
            "docs/slices/slice-09.md",
            lines.append,
            max_red_verifies=2,
        )
        red_blob = (
            "Test Case '-[AnalysisProgressUITests testProgressIndicatorLifecycle]' failed.\n"
            "VERIFY RESULT: exit=1 total=4 passed=3 failed=1 skipped=0 filtered=1\n"
            "** TEST FAILED **\n"
        )
        progress._tool(
            "c1",
            "shell",
            "completed",
            {"command": "scripts/verify.sh -only-testing:PodWashUITests"},
            red_blob,
        )
        self.assertEqual(progress._red_verify_count, 1)
        # Inspecting the bundle must refine the failure name without burning a retry.
        progress._tool(
            "c2",
            "shell",
            "completed",
            {
                "command": (
                    "xcrun xcresulttool get test-results --path "
                    "build/test-results/verify-20260709.xcresult"
                )
            },
            (
                "PodWashUITests/testProgressIndicatorLifecycle() — "
                "XCTAssertTrue failed\n"
            ),
        )
        self.assertEqual(progress._red_verify_count, 1)
        self.assertFalse(progress.halted)
        self.assertTrue(any("TEST FAIL" in l and "xcresulttool" in l for l in lines))

    def test_is_verify_run_excludes_xcresulttool(self):
        self.assertTrue(is_verify_run("scripts/verify.sh"))
        self.assertTrue(
            is_verify_run(
                "xcodebuild test -scheme PodWash -only-testing:PodWashUITests"
            )
        )
        self.assertFalse(
            is_verify_run(
                "xcrun xcresulttool get test-results --path build/test-results/verify.xcresult"
            )
        )
        self.assertFalse(is_verify_run("grep TEST FAILED build/log.txt"))

    def test_spawn_logs_wrong_role_and_allowed_paths(self):
        lines: list[str] = []
        progress = RunProgress(9, "Analysis UI", "docs/slices/slice-09.md", lines.append)
        progress._handle_task_tool(
            "ux-1",
            "running",
            {
                "description": "Fix progress UI test failure",
                "subagent_type": "podwash-ux",
            },
        )
        self.assertTrue(any("WRONG ROLE" in l for l in lines))
        self.assertTrue(any("allowed edits:" in l for l in lines))
        self.assertTrue(any("MUST NOT" in l for l in lines))

    def test_heartbeat_includes_known_failing_test(self):
        progress = RunProgress(9, "Analysis UI", "docs/slices/slice-09.md", lambda *_: None)
        progress._known_failing_test = "testProgressIndicatorLifecycle"
        progress._same_failure_streak = 2
        progress.last_activity = __import__("time").time()
        status = progress.format_work_status()
        self.assertIn("testProgressIndicatorLifecycle", status)
        self.assertIn("×2", status)

    def test_shell_result_note_includes_crash_count(self):
        result = (
            "Crash: PodWash at AnalysisUIStateTests.testTogglePersistence()\n"
            "VERIFY RESULT: exit=1 total=4 passed=2 failed=2 skipped=0 filtered=1"
        )
        note = shell_result_note({"command": "scripts/verify.sh"}, result)
        self.assertIn("RED", note)
        self.assertIn("CRASH", note)

    def test_summarize_ips_and_list_new(self):
        import json
        import tempfile
        import time

        with tempfile.TemporaryDirectory() as tmp:
            payload = {
                "exception": {"type": "EXC_CRASH", "signal": "SIGABRT"},
                "faultingThread": 0,
                "usedImages": [{"name": "/tmp/PodWash.debug.dylib"}],
                "threads": [
                    {
                        "frames": [
                            {"imageIndex": 0, "symbol": "AnalysisUIViewModel.__deallocating_deinit"},
                            {"imageIndex": 0, "symbol": "InMemoryCleaningToggleStore.deinit"},
                        ]
                    }
                ],
            }
            path = os.path.join(tmp, "PodWash-2026-07-09-120000.ips")
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(json.dumps({"app_name": "PodWash"}) + "\n")
                fh.write(json.dumps(payload))
            summary = summarize_ips_crash(path)
            self.assertIn("EXC_CRASH", summary)
            self.assertIn("AnalysisUIViewModel", summary)

            before = time.time() - 10
            newer = list_new_podwash_ips(before, reports_dir=tmp)
            self.assertEqual(newer, [path])
            older = list_new_podwash_ips(time.time() + 10, reports_dir=tmp)
            self.assertEqual(older, [])

    def test_run_progress_announces_crash_once(self):
        lines: list[str] = []

        progress = RunProgress(9, "Analysis UI", "docs/slices/slice-09.md", lines.append)
        progress._run_started_at = 1.0
        progress._crash_watch_enabled = True
        progress._announce_crashes(
            ["AnalysisUIStateTests.testTogglePersistence()"],
            source="verify/xcodebuild",
        )
        progress._announce_crashes(
            ["AnalysisUIStateTests.testTogglePersistence()"],
            source="verify/xcodebuild",
        )
        crash_lines = [l for l in lines if "SIMULATOR CRASH" in l]
        investigate = [l for l in lines if "investigating crash" in l]
        self.assertEqual(len(crash_lines), 1)
        self.assertEqual(len(investigate), 1)
        self.assertIn("💥 crash:", progress.last_label)

    def test_parallel_tasks_prefer_engineer_over_architect_review(self):
        lines: list[str] = []
        progress = RunProgress(9, "Analysis UI", "docs/slices/slice-09.md", lines.append)

        progress._handle_task_tool(
            "arch-1",
            "running",
            {
                "description": "Architect test spec review",
                "readonly": True,
                "prompt": "You are the Architect agent reviewing the test spec (READONLY).",
            },
        )
        progress._handle_task_tool(
            "eng-1",
            "running",
            {
                "description": "Engineer fix slice 09",
                "subagent_type": "podwash-engineer",
            },
        )
        self.assertEqual(progress.active_role(), "Engineer")
        self.assertIn("parallel", progress.active_roles_label())

        # Architect finishes first — Engineer must remain the active role
        # (old LIFO stack wrongly left "Architect review" stuck here).
        progress._handle_task_tool("arch-1", "completed", {})
        self.assertEqual(progress.active_role(), "Engineer")
        self.assertEqual(progress.active_roles_label(), "Engineer")
        finished = [l for l in lines if "Architect review] finished" in l]
        self.assertTrue(any("still running: Engineer" in l for l in finished))

        progress._handle_task_tool("eng-1", "completed", {})
        self.assertEqual(progress.active_role(), "Coordinator")

    def test_infer_role_ux_from_accessibility_desc(self):
        args = {"description": "Fix UI test accessibility", "subagent_type": "generalPurpose"}
        self.assertEqual(infer_role(args), "UX")

    def test_format_active_tasks_shows_elapsed(self):
        import time

        now = time.time()
        line = format_active_tasks(
            [
                {
                    "role": "UX",
                    "desc": "Fix UI test accessibility",
                    "started_at": now - 685,
                }
            ],
            now=now,
        )
        self.assertIn("UX:", line)
        self.assertIn("Fix UI test accessibility", line)
        self.assertIn("11m", line)

    def test_heartbeat_shows_active_task_not_stale_done_label(self):
        import time

        lines: list[str] = []
        progress = RunProgress(9, "Analysis UI", "docs/slices/slice-09.md", lines.append)
        progress._handle_task_tool(
            "ux-1",
            "running",
            {"description": "Fix UI test accessibility", "subagent_type": "podwash-ux"},
        )
        # Nested subagent completes without a matching running entry — UX stays open.
        progress._handle_task_tool("nested-1", "completed", {})
        progress._active_tasks["ux-1"]["started_at"] = time.time() - 400
        status = progress.format_work_status()
        self.assertIn("UX:", status)
        self.assertIn("Fix UI test accessibility", status)
        self.assertNotIn("Subagent done", status)

    def test_assess_slice_gates_slice_09(self):
        repo = os.path.dirname(SCRIPT_DIR)
        info = assess_slice_gates("docs/slices/slice-09-analysis-ui.md", repo)
        self.assertGreaterEqual(info["total"], 6)
        self.assertEqual(info["done"], info["total"])  # Status Done + green VERIFY
        self.assertIn("gates ", info["summary"])
        self.assertIn("next:", info["summary"])
        labels = {g["label"] for g in info["gates"]}
        self.assertIn("story", labels)
        self.assertIn("ux", labels)
        self.assertIn("implement", labels)
        self.assertIn("verify", labels)
        detail = format_gate_detail(info)
        self.assertIn("story✓", detail)
        self.assertIn("verify✓", detail)

    def test_assess_slice_gates_done_slice(self):
        repo = os.path.dirname(SCRIPT_DIR)
        info = assess_slice_gates("docs/slices/slice-08-playback-integration.md", repo)
        self.assertEqual(info["done"], info["total"])
        self.assertEqual(info["next"], "done")

    def test_read_slice_meta_from_repo(self):
        repo = os.path.dirname(SCRIPT_DIR)
        title, rel = read_slice_meta("docs/slices/slice-06-rss-episode-list.md", repo)
        self.assertEqual(rel, "docs/slices/slice-06-rss-episode-list.md")
        self.assertIn("RSS", title)

    def test_delegate_violation_engineer_path(self):
        hit = delegate_violation("/Users/me/PodWash/PodWash/PodcastDetailView.swift")
        self.assertEqual(hit, ("Engineer", "podwash-engineer"))

    def test_delegate_violation_slice_doc_ok(self):
        self.assertIsNone(delegate_violation("docs/slices/slice-09-analysis-ui.md"))

    def test_done_banner_includes_ascii_art_when_green(self):
        from slice_loop_progress import slice_done_banner

        v = {"exit": "0", "total": "10", "passed": "10", "failed": "0", "skipped": "0"}
        banner = slice_done_banner(7, "Test slice", v, 60)
        self.assertIn("MOUNTAIN", banner)
        self.assertIn("CONQUERED", banner)
        self.assertIn("ALL TESTS PASSED", banner)


if __name__ == "__main__":
    unittest.main()
