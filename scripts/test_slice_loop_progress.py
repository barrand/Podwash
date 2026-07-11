#!/usr/bin/env python3
"""Unit tests for slice-loop progress formatting (no SDK / Xcode)."""

import os
import sys
import tempfile
import unittest

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)
REPO_ROOT = os.path.dirname(SCRIPT_DIR)

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

    def test_draft_full_crux_story_not_done(self):
        """Progress must not treat Draft+Crux as story-done (align with FSM)."""
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "slice.md")
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(
                    "| **Status** | Draft |\n"
                    "| **Crux** | Prove something |\n\n"
                    "## Acceptance criteria\n\n"
                    "- [ ] 1. AC\n"
                )
            info = assess_slice_gates(path, tmp)
            story = next(g for g in info["gates"] if g["id"] == "story")
            self.assertFalse(story["done"])
            self.assertEqual(info["next"], "story")

    def test_read_slice_meta_from_repo(self):
        repo = os.path.dirname(SCRIPT_DIR)
        title, rel = read_slice_meta("docs/slices/slice-06-rss-episode-list.md", repo)
        self.assertEqual(rel, "docs/slices/slice-06-rss-episode-list.md")
        self.assertIn("RSS", title)

    def test_extract_slice_mission_and_accomplishment(self):
        from slice_loop_progress import (
            extract_slice_accomplishment,
            extract_slice_mission,
            slice_done_banner,
            slice_start_banner,
        )

        repo = os.path.dirname(SCRIPT_DIR)
        path = "docs/slices/slice-06-rss-episode-list.md"
        mission = extract_slice_mission(path, repo)
        self.assertIn("RSS", mission)
        self.assertIn("parse", mission.lower())

        accomplishment = extract_slice_accomplishment(path, repo)
        self.assertTrue(accomplishment.startswith("Shipped:"))
        self.assertIn("RSS", accomplishment)

        start = slice_start_banner(6, "RSS feed + episode list UI", path, mission=mission)
        self.assertIn("→", start)
        self.assertIn(mission[:40], start)

        verify = {"exit": "0", "total": "10", "passed": "10", "failed": "0", "skipped": "0"}
        done = slice_done_banner(
            6, "RSS feed + episode list UI", verify, 120, accomplishment=accomplishment
        )
        self.assertIn("Shipped:", done)

    def test_delegate_violation_engineer_path(self):
        hit = delegate_violation("/Users/me/PodWash/PodWash/PodcastDetailView.swift")
        self.assertEqual(hit, ("Engineer", "podwash-engineer"))

    def test_delegate_violation_slice_doc_ok(self):
        self.assertIsNone(delegate_violation("docs/slices/slice-09-analysis-ui.md"))

    def test_done_banner_is_compact_when_green(self):
        from slice_loop_progress import slice_done_banner

        v = {"exit": "0", "total": "10", "passed": "10", "failed": "0", "skipped": "0"}
        banner = slice_done_banner(7, "Test slice", v, 60)
        self.assertIn("ALL TESTS PASSED", banner)
        self.assertIn("Forge gate cleared", banner)
        self.assertNotIn("MOUNTAIN", banner)

    def test_coordinator_shift_report(self):
        from factory_narrator import format_coordinator_report

        report = format_coordinator_report(
            coordinator_name="Kai",
            slice_id=12,
            title="Variable speed + sleep timer",
            elapsed_secs=1800,
            green=True,
            mission="Deliver variable speed and a sleep timer.",
            accomplishment="Shipped: rate API; sleep timer; UI controls",
            cast_names=["Priya", "Quincy"],
            murphy_visits=1,
            verify={"exit": "0", "total": "100", "passed": "100", "skipped": "0"},
            session=(1, 6),
        )
        self.assertIn("Coordinator Kai", report)
        self.assertIn("shift report", report)
        self.assertIn("Priya", report)
        self.assertIn("Shipped:", report)
        self.assertNotIn("MOUNTAIN", report)

    def test_prefix_includes_agent_name(self):
        lines: list[str] = []
        progress = RunProgress(
            12,
            "Speed",
            "docs/slices/slice-12.md",
            lines.append,
            forced_role="QA",
            agent_name="Quincy",
        )
        self.assertEqual(progress.prefix(), "[slice 12][QA Quincy]")
        bare = RunProgress(12, "Speed", "docs/slices/slice-12.md", lines.append, forced_role="QA")
        self.assertEqual(bare.prefix(), "[slice 12][QA]")

    def test_heartbeat_forge_voice_when_named(self):
        import time
        from unittest import mock

        lines: list[str] = []
        progress = RunProgress(
            12,
            "Speed",
            "docs/slices/slice-12.md",
            lines.append,
            forced_role="QA",
            agent_name="Quincy",
        )
        progress.last_activity = time.time() - 90
        with mock.patch(
            "slice_loop_progress.sniff_background_build", return_value=None
        ):
            status = progress.format_work_status()
        self.assertIn("Forge", status)
        self.assertIn("QA Quincy", status)
        self.assertNotIn("coordinator quiet", status)


class AuthoringGateThrashTests(unittest.TestCase):
    """Factory authoring-phase thrash fix (slice 12 TDD compile-red)."""

    _BUILD_BLOB = (
        "/Users/me/PodWash/PodWashTests/SleepTimerTests.swift:12:24: "
        "error: cannot find type 'MonotonicClock' in scope\n"
        "/Users/me/PodWash/PodWashTests/SleepTimerTests.swift:18:8: "
        "error: cannot find type 'SleepTimer' in scope\n"
        "** BUILD FAILED **\n"
        "Testing cancelled because the build failed.\n"
        "** TEST FAILED **\n"
        "VERIFY RESULT: exit=65 total=0 passed=0 failed=0 skipped=0 "
        "filtered=1 bundle=build/test-results/verify-x.xcresult tier=2 class=build\n"
    )

    def test_authoring_gate_red_verify_does_not_halt(self):
        lines: list[str] = []
        progress = RunProgress(
            12,
            "Speed + sleep",
            "docs/slices/slice-12-speed-sleep.md",
            lines.append,
            max_red_verifies=2,
            authoring_gate=True,
            gate_id="test_spec",
            forced_role="QA",
        )
        verify = {
            "exit": "65",
            "total": "0",
            "passed": "0",
            "failed": "0",
            "skipped": "0",
            "class": "build",
        }
        for _ in range(3):
            progress._record_red_verify(
                ["build_error: cannot find type 'MonotonicClock' in scope"],
                cmd="scripts/verify.sh",
                blob=self._BUILD_BLOB,
                verify=verify,
            )
        self.assertEqual(progress._red_verify_count, 0)
        self.assertFalse(progress.halted)
        self.assertTrue(
            any("authoring-phase red verify ignored" in l for l in lines)
        )
        # Log once only
        self.assertEqual(
            sum(1 for l in lines if "authoring-phase red verify ignored" in l),
            1,
        )

    def test_coordinator_path_still_halts_at_two(self):
        lines: list[str] = []
        with tempfile.TemporaryDirectory() as tmp:
            progress = RunProgress(
                12,
                "Speed + sleep",
                "docs/slices/slice-12-speed-sleep.md",
                lines.append,
                max_red_verifies=2,
                authoring_gate=False,
                repo_root=tmp,
            )
            progress._tool(
                "c1",
                "shell",
                "completed",
                {"command": "scripts/verify.sh"},
                self._BUILD_BLOB,
            )
            self.assertEqual(progress._red_verify_count, 1)
            with self.assertRaises(ThrashHalt):
                progress._tool(
                    "c2",
                    "shell",
                    "completed",
                    {"command": "scripts/verify.sh"},
                    self._BUILD_BLOB,
                )
            self.assertTrue(progress.halted)
            self.assertTrue(any("session bundle" in l for l in lines))
            stuck = os.path.join(tmp, "build", "test-results", "stuck-slice-12.txt")
            self.assertTrue(os.path.isfile(stuck))
            bundle = os.path.join(tmp, "build", "test-results", "session-slice-12")
            self.assertTrue(os.path.isdir(bundle))

    def test_authoring_verify_ban_warns_without_cancel(self):
        lines: list[str] = []
        cancelled: list[bool] = []

        class FakeRun:
            def supports(self, cap: str) -> bool:
                return cap == "cancel"

            def cancel(self) -> None:
                cancelled.append(True)

        progress = RunProgress(
            12,
            "Speed + sleep",
            "docs/slices/slice-12-speed-sleep.md",
            lines.append,
            authoring_gate=True,
            gate_id="test_spec",
            forced_role="QA",
        )
        progress.bind_run(FakeRun())
        progress._tool(
            "v1",
            "shell",
            "running",
            {"command": "scripts/verify.sh -only-testing:PodWashTests"},
            None,
        )
        self.assertEqual(progress._verify_violations, 1)
        self.assertFalse(progress.verify_violation_burned)
        self.assertFalse(cancelled)  # authoring: warn-only
        self.assertTrue(any("AUTHORING VERIFY BAN" in l for l in lines))
        self.assertTrue(any("warn-only" in l for l in lines))
        # Second ban still does not burn or cancel
        progress._handle_verify_ban("xcodebuild test -scheme PodWash")
        self.assertEqual(progress._verify_violations, 2)
        self.assertFalse(progress.verify_violation_burned)
        self.assertFalse(cancelled)

    def test_architect_spike_xcodebuild_allowed(self):
        from slice_loop_progress import (
            is_architect_spike_xcodebuild,
            is_banned_verify_command,
        )

        spike = (
            "xcodebuild test -scheme PodWash "
            "-only-testing:PodWashTests/OverlaySyncSpike"
        )
        self.assertTrue(is_architect_spike_xcodebuild(spike))
        self.assertFalse(
            is_banned_verify_command(
                spike, gate_id="architect", authoring_gate=True
            )
        )
        full = "xcodebuild test -scheme PodWash"
        self.assertFalse(is_architect_spike_xcodebuild(full))
        self.assertTrue(
            is_banned_verify_command(
                full, gate_id="architect", authoring_gate=True
            )
        )
        self.assertTrue(
            is_banned_verify_command(
                "scripts/verify.sh", gate_id="architect", authoring_gate=True
            )
        )

    def test_architect_spike_shell_logs_ok_not_ban(self):
        lines: list[str] = []
        cancelled: list[bool] = []

        class FakeRun:
            def supports(self, cap: str) -> bool:
                return cap == "cancel"

            def cancel(self) -> None:
                cancelled.append(True)

        progress = RunProgress(
            16,
            "Beep overlay",
            "docs/slices/slice-16-beep-overlay.md",
            lines.append,
            authoring_gate=True,
            gate_id="architect",
            forced_role="Architect",
        )
        progress.bind_run(FakeRun())
        progress._tool(
            "v1",
            "shell",
            "running",
            {
                "command": (
                    "xcodebuild test -scheme PodWash "
                    "-only-testing:PodWashTests/_OverlaySyncSpike"
                )
            },
            None,
        )
        joined = "\n".join(lines)
        self.assertIn("architect spike ok", joined)
        self.assertNotIn("AUTHORING VERIFY BAN", joined)
        self.assertEqual(progress._verify_violations, 0)
        self.assertFalse(cancelled)
        self.assertIn("v1", progress._active_shell)

    def test_architect_full_xcodebuild_warns_without_cancel(self):
        lines: list[str] = []
        cancelled: list[bool] = []

        class FakeRun:
            def supports(self, cap: str) -> bool:
                return cap == "cancel"

            def cancel(self) -> None:
                cancelled.append(True)

        progress = RunProgress(
            16,
            "Beep overlay",
            "docs/slices/slice-16-beep-overlay.md",
            lines.append,
            authoring_gate=True,
            gate_id="architect",
            forced_role="Architect",
        )
        progress.bind_run(FakeRun())
        progress._tool(
            "v1",
            "shell",
            "running",
            {"command": "xcodebuild test -scheme PodWash"},
            None,
        )
        joined = "\n".join(lines)
        self.assertIn("AUTHORING VERIFY BAN", joined)
        self.assertIn("full-suite xcodebuild banned", joined)
        self.assertIn("warn-only", joined)
        self.assertFalse(cancelled)
        self.assertEqual(progress._verify_violations, 1)
        self.assertIn("v1", progress._active_shell)

    def test_detect_build_error_from_compile_blob(self):
        from slice_loop_progress import extract_build_error

        failures = detect_test_failures(self._BUILD_BLOB)
        self.assertTrue(any(f.startswith("build_error:") for f in failures))
        self.assertTrue(any("MonotonicClock" in f for f in failures))
        self.assertFalse(any(f == "xcodebuild — TEST FAILED" for f in failures))
        be = extract_build_error(self._BUILD_BLOB)
        self.assertIsNotNone(be)
        self.assertIn("MonotonicClock", be or "")

    def test_extract_build_error_xcodebuild_scheme_member(self):
        from slice_loop_progress import extract_build_error, extract_factory_config_error

        blob = (
            "VERIFY RESULT: exit=70 total=0 passed=0 failed=0 skipped=0 "
            "filtered=1 bundle=b.xcresult tier=2 class=build\n"
            'xcodebuild: error: Tests in the target "PodWashSlowTests" '
            "can't be run because PodWashSlowTests isn't a member of the "
            "specified test plan or scheme.\n"
        )
        be = extract_build_error(blob)
        self.assertIsNone(be)
        fc = extract_factory_config_error(blob)
        self.assertIsNotNone(fc)
        assert fc is not None
        self.assertIn("factory_config:", fc)
        self.assertIn("PodWashSlowTests", fc)

    def test_enrich_build_failures_scheme_red(self):
        from slice_loop_progress import enrich_build_failures

        blob = (
            "VERIFY RESULT: exit=70 total=0 passed=0 failed=0 skipped=0 "
            "filtered=1 bundle=b.xcresult tier=2 class=build\n"
            "xcodebuild: error: isn't a member of the specified test plan or scheme.\n"
        )
        v = parse_verify_result(blob)
        enriched = enrich_build_failures([], blob, v)
        self.assertEqual(len(enriched), 1)
        self.assertTrue(enriched[0].startswith("factory_config:"))

    def test_parse_verify_result_class_build(self):
        v = parse_verify_result(
            "VERIFY RESULT: exit=65 total=0 passed=0 failed=0 skipped=0 "
            "filtered=1 bundle=b.xcresult tier=2 class=build"
        )
        self.assertIsNotNone(v)
        assert v is not None
        self.assertEqual(v.get("class"), "build")
        self.assertEqual(v.get("exit"), "65")
        self.assertEqual(v.get("tier"), "2")
        self.assertFalse(verify_is_green(v))


class AdrPlaceholderTests(unittest.TestCase):
    def test_next_adr_number_from_repo(self):
        from slice_loop_progress import next_adr_number

        n = next_adr_number(REPO_ROOT)
        self.assertGreaterEqual(n, 17)

    def test_resolve_adr_placeholders_in_string(self):
        from slice_loop_progress import resolve_adr_placeholders_in_string

        with tempfile.TemporaryDirectory() as tmp:
            adr = os.path.join(tmp, "docs", "adr")
            os.makedirs(adr)
            with open(os.path.join(adr, "016-carplay.md"), "w", encoding="utf-8") as fh:
                fh.write("# 016\n")
            out = resolve_adr_placeholders_in_string(
                "`docs/adr/0XX-overlay-sync.md`", tmp
            )
            self.assertIn("docs/adr/017-overlay-sync.md", out)
            self.assertNotIn("0XX", out)

    def test_normalize_slice_adr_placeholders_rewrites_file(self):
        from slice_loop_progress import normalize_slice_adr_placeholders

        with tempfile.TemporaryDirectory() as tmp:
            adr = os.path.join(tmp, "docs", "adr")
            os.makedirs(adr)
            with open(os.path.join(adr, "016-carplay.md"), "w", encoding="utf-8") as fh:
                fh.write("# 016\n")
            path = os.path.join(tmp, "slice-16.md")
            body = (
                "# Slice 16\n\n"
                "## Role artifacts\n\n"
                "| Role | Gate | Artifact path |\n"
                "|------|------|---------------|\n"
                "| Architect | Required | `docs/adr/0XX-overlay-sync.md` |\n"
            )
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(body)
            self.assertTrue(normalize_slice_adr_placeholders(path, tmp))
            text = open(path, encoding="utf-8").read()
            self.assertIn("docs/adr/017-overlay-sync.md", text)
            self.assertNotIn("0XX", text)

    def test_missing_artifact_paths_resolves_placeholder(self):
        from slice_loop_progress import missing_artifact_paths

        with tempfile.TemporaryDirectory() as tmp:
            adr = os.path.join(tmp, "docs", "adr")
            os.makedirs(adr)
            with open(os.path.join(adr, "016-carplay.md"), "w", encoding="utf-8") as fh:
                fh.write("# 016\n")
            miss = missing_artifact_paths(
                tmp, "`docs/adr/0XX-overlay-sync.md` — notes"
            )
            self.assertEqual(miss, ["docs/adr/017-overlay-sync.md"])

    def test_authoring_verify_ban_architect_message(self):
        lines: list[str] = []
        progress = RunProgress(
            16,
            "Beep overlay",
            "docs/slices/slice-16-beep-overlay.md",
            lines.append,
            authoring_gate=True,
            gate_id="architect",
            forced_role="Architect",
        )
        progress._handle_verify_ban("scripts/verify.sh")
        joined = "\n".join(lines)
        self.assertIn("AUTHORING VERIFY BAN", joined)
        self.assertIn("Spike", joined)
        self.assertIn("warn-only", joined)
        self.assertNotIn("test-spec", joined)

    def test_worker_edit_violation_architect_blocks_prod_tests(self):
        from slice_loop_progress import worker_edit_violation

        msg = worker_edit_violation(
            "Architect",
            "PodWash/PodWashTests/OverlaySyncTests.swift",
            gate_id="architect",
        )
        self.assertIsNotNone(msg)
        assert msg is not None
        self.assertIn("docs/adr", msg)

    def test_worker_edit_violation_architect_allows_spike(self):
        from slice_loop_progress import worker_edit_violation

        msg = worker_edit_violation(
            "Architect",
            "PodWash/PodWashTests/_OverlaySyncSpike.swift",
            gate_id="architect",
        )
        self.assertIsNone(msg)

    def test_worker_path_violation_logged_for_architect(self):
        lines: list[str] = []
        progress = RunProgress(
            16,
            "Beep overlay",
            "docs/slices/slice-16-beep-overlay.md",
            lines.append,
            authoring_gate=True,
            gate_id="architect",
            forced_role="Architect",
        )
        progress._warn_path_violation(
            "write",
            {"path": "PodWash/PodWashTests/OverlaySyncTests.swift"},
        )
        joined = "\n".join(lines)
        self.assertIn("may only edit", joined)
        self.assertIn("OverlaySyncTests", joined)


if __name__ == "__main__":
    unittest.main()
