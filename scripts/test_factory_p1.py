#!/usr/bin/env python3
"""Unit tests for factory_events + factory_narrator + sim_hygiene (P1)."""

from __future__ import annotations

import os
import sys
import tempfile
import unittest

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)

from factory_events import (  # noqa: E402
    EventLog,
    format_phase_banner,
    parse_summary_line,
)
from factory_narrator import (  # noqa: E402
    FACTORY_NAME,
    CastLog,
    NameAssigner,
    factory_session_banner,
    format_agent_label,
    format_slice_recap,
    narrate_chapter_open,
    narrate_exoneration,
    narrate_gate_cleared,
    narrate_gate_stuck,
    narrate_slice_recap,
    narrate_spawn,
    narrate_thrash_halt,
    narrate_verify_red,
    persist_story_recap,
)
from sim_hygiene import (  # noqa: E402
    CrashWatchdog,
    classify_infra_failure,
    should_stress_run,
    stress_run_count,
)
from slice_pipeline import (  # noqa: E402
    VerifyOutcome,
    build_tier2_continue_prompt,
    extract_mapped_test_ids,
    tier2_marker_ok,
    write_tier2_marker,
)
from failure_packet import FailurePacket  # noqa: E402


class SummaryContractTests(unittest.TestCase):
    def test_parse_summary(self):
        text = "Did some work.\nSUMMARY: fixed cancel gate + resume data\nBye"
        self.assertEqual(
            parse_summary_line(text),
            "fixed cancel gate + resume data",
        )
        self.assertIsNone(parse_summary_line("no summary here"))


class EventLogTests(unittest.TestCase):
    def test_append_and_banner(self):
        with tempfile.TemporaryDirectory() as tmp:
            lines: list[str] = []
            log = EventLog(tmp, 11, log=lines.append)
            log.record(
                "REFEREE", "Referee", "spawn",
                agent_name="Rhea", timeline=True, mission="route",
            )
            self.assertTrue(os.path.isfile(log.path))
            with open(log.path, encoding="utf-8") as fh:
                body = fh.read()
            self.assertIn('"event": "spawn"', body)
            self.assertTrue(any("REFEREE" in x for x in lines))
            banner = format_phase_banner("FIX-1", role="Engineer", agent_name="Edison")
            self.assertIn("Edison", banner)
            self.assertIn("Engineer Edison", banner)


class NarratorTests(unittest.TestCase):
    def test_name_pools_cycle(self):
        n = NameAssigner()
        a = n.assign("Engineer")
        b = n.assign("Engineer", slot="Engineer-2")
        self.assertEqual(a, "Edison")
        self.assertEqual(b, "Elena")
        self.assertEqual(n.assign("Referee"), "Rhea")

    def test_format_agent_label(self):
        self.assertEqual(format_agent_label("QA", "Quincy"), "QA Quincy")
        self.assertEqual(format_agent_label("Engineer", "Edison"), "Engineer Edison")
        self.assertEqual(format_agent_label("QA", None), "QA")
        self.assertEqual(format_agent_label("", "Rhea"), "Rhea")

    def test_factory_session_banner(self):
        self.assertEqual(FACTORY_NAME, "Forge")
        banner = factory_session_banner()
        self.assertIn("Forge", banner)
        self.assertIn("Murphy", banner)
        self.assertLessEqual(banner.count("\n"), 14)

    def test_story_beats(self):
        lines: list[str] = []
        open_line = narrate_chapter_open(
            slice_id=12,
            gate_label="test spec",
            role="QA",
            name="Quincy",
            act=4,
            total=9,
            log=lines.append,
        )
        self.assertIn("Slice 12", open_line)
        self.assertIn("4/9 test spec", open_line)
        self.assertIn("QA Quincy", open_line)
        self.assertTrue(open_line.startswith("\n──"))

        clear = narrate_gate_cleared(
            "Quincy",
            "test spec",
            next_label="test-spec review",
            next_name="Ada",
            elapsed_secs=120,
            log=lines.append,
        )
        self.assertIn("✓ Quincy cleared test spec", clear)
        self.assertIn("2m", clear)
        self.assertIn("Ada", clear)

        stuck = narrate_gate_stuck(
            "story",
            "gate story still pending after worker — stopping. "
            "(Status=Draft) unblock: set Status to Ready",
            log=lines.append,
        )
        self.assertIn("✗ story stuck", stuck)
        self.assertIn("Ready", stuck)

        cast = CastLog()
        cast.add("PM", "Priya", "story")
        cast.add("QA", "Quincy", "test_spec")
        cast.note_murphy()
        recap = format_slice_recap(
            slice_id=12, elapsed_secs=1080, cast=cast, outcome="green"
        )
        self.assertIn("Forge recap", recap)
        self.assertIn("Priya", recap)
        self.assertIn("Murphy ×1", recap)
        self.assertIn("green", recap)

        with tempfile.TemporaryDirectory() as tmp:
            path = persist_story_recap(recap, repo_root=tmp, slice_id=12)
            self.assertTrue(os.path.isfile(path))
            self.assertIn("story-slice-12.txt", path)
            with open(path, encoding="utf-8") as fh:
                self.assertEqual(fh.read().strip(), recap)

        fix_open = narrate_chapter_open(
            slice_id=12,
            gate_label="fix",
            role="Engineer",
            name="Edison",
            fix_attempt=1,
            fix_max=3,
            log=lines.append,
        )
        self.assertIn("fix 1/3", fix_open)
        self.assertIn("Engineer Edison", fix_open)

    def test_murphy_only_in_narration(self):
        lines: list[str] = []
        narrate_verify_red("Quinn", passed=43, total=45, log=lines.append)
        self.assertIn("🐒", lines[0])
        narrate_exoneration(cause="cancel gate fires early", owner="Edison", log=lines.append)
        self.assertIn("wasn't Murphy", lines[1])
        narrate_thrash_halt(log=lines.append)
        self.assertIn("exit=5", lines[2])
        narrate_spawn("Edison", "Engineer", "fix DownloadManager", log=lines.append)
        self.assertIn("Edison", lines[3])


class SimHygieneTests(unittest.TestCase):
    def test_crash_watchdog(self):
        with tempfile.TemporaryDirectory() as tmp:
            wd = CrashWatchdog(roots=[tmp])
            wd.arm()
            self.assertEqual(wd.new_crashes(), [])
            open(os.path.join(tmp, "PodWash.ips"), "w").write("crash")
            fresh = wd.new_crashes()
            self.assertEqual(len(fresh), 1)
            self.assertTrue(fresh[0].endswith(".ips"))

    def test_stress_run_uitest_only(self):
        ids = ["PodWashUITests/Foo/testBar()"]
        self.assertTrue(should_stress_run(ids, just_fixed=True))
        self.assertEqual(stress_run_count(ids, just_fixed=True), 5)
        self.assertFalse(should_stress_run(["PodWashTests/Foo/testA()"], just_fixed=True))
        self.assertFalse(should_stress_run(ids, just_fixed=False))

    def test_classify_infra(self):
        self.assertTrue(
            classify_infra_failure(
                output="failed to launch bridge: connection reset",
                files_changed=False,
            )
        )
        self.assertFalse(
            classify_infra_failure(
                output="failed to launch bridge",
                files_changed=True,
            )
        )


class MappedTestsAndTierTests(unittest.TestCase):
    def test_extract_mapped_test_ids(self):
        text = """
## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/QueueTests.swift` | `testQueueOperationsAndPersistence` | |
| 2 | `PodWash/PodWashUITests/FooUITests.swift` | `testSomething()` | |
| 5 | — | — | Command-level |
"""
        ids = extract_mapped_test_ids(text)
        self.assertIn("PodWashTests/QueueTests/testQueueOperationsAndPersistence()", ids)
        self.assertIn("PodWashUITests/FooUITests/testSomething()", ids)

    def test_tier2_marker(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertFalse(tier2_marker_ok(tmp, 11))
            write_tier2_marker(tmp, 11)
            self.assertTrue(tier2_marker_ok(tmp, 11))


class ArtifactCellTests(unittest.TestCase):
    def test_multi_backtick_paths(self):
        from slice_loop_progress import artifact_cell_satisfied, missing_artifact_paths

        cell = (
            "`docs/adr/007-persistence-core-data.md` (stack) + "
            "`docs/adr/009-queue-resume.md` (modules/APIs)"
        )
        with tempfile.TemporaryDirectory() as tmp:
            os.makedirs(os.path.join(tmp, "docs", "adr"), exist_ok=True)
            open(os.path.join(tmp, "docs", "adr", "007-persistence-core-data.md"), "w").write("x")
            self.assertFalse(artifact_cell_satisfied(tmp, cell))
            self.assertEqual(
                missing_artifact_paths(tmp, cell),
                ["docs/adr/009-queue-resume.md"],
            )
            open(os.path.join(tmp, "docs", "adr", "009-queue-resume.md"), "w").write("y")
            self.assertTrue(artifact_cell_satisfied(tmp, cell))


class SessionBundleTests(unittest.TestCase):
    def test_writes_halt_artifacts(self):
        from session_bundle import write_session_bundle

        with tempfile.TemporaryDirectory() as tmp:
            tr = os.path.join(tmp, "build", "test-results")
            os.makedirs(tr, exist_ok=True)
            open(os.path.join(tr, "events-slice-11.jsonl"), "w").write(
                '{"event":"verify_start"}\n'
            )
            open(os.path.join(tr, "ledger-slice-11.jsonl"), "w").write(
                '{"hypothesis":"x"}\n'
            )
            dest = write_session_bundle(
                repo_root=tmp,
                slice_id=11,
                reason="implement tier-2 gate failed after 3 runs",
                stuck_card="STUCK — Slice 11\nClass: crash\n",
                verify_result={"exit": "65", "failed": "5", "bundle": "build/x.xcresult"},
                failures=["crash a"],
                crashes=["Crash: PodWash"],
                phase="TIER2-GATE",
            )
            self.assertTrue(dest.endswith("session-slice-11"))
            self.assertTrue(os.path.isfile(os.path.join(dest, "halt.json")))
            self.assertTrue(os.path.isfile(os.path.join(dest, "stuck-card.txt")))
            self.assertTrue(os.path.isfile(os.path.join(dest, "events.jsonl")))
            self.assertTrue(os.path.isfile(os.path.join(dest, "ledger.jsonl")))
            self.assertTrue(os.path.isfile(os.path.join(dest, "README.md")))
            self.assertIn("STUCK", open(os.path.join(dest, "stuck-card.txt")).read())


class Tier2ContinuePromptTests(unittest.TestCase):
    """Factory death-run gap: tier-2 continue must not be failures-only."""

    def _make_outcome(self, *, failures, crashes=None, failure_class="crash") -> VerifyOutcome:
        packet = FailurePacket(
            raw_failures=failures,
            crashes=crashes or [],
            failure_class=failure_class,
            test_ids=["QueueTests/testAutoAdvanceOnEpisodeEnd()"],
            signature="sig",
        )
        return VerifyOutcome(
            result={"exit": "65", "failed": "1", "bundle": "build/test-results/x.xcresult"},
            green=False,
            failures=failures,
            crashes=crashes or [],
            output="\n".join(failures),
            packet=packet,
            tier=2,
        )

    def test_rich_prompt_has_stuck_card_and_packet(self):
        with tempfile.TemporaryDirectory() as tmp:
            outcome = self._make_outcome(
                failures=[
                    "PodWashTests/testAutoAdvanceOnEpisodeEnd() — "
                    "Crash: PodWash at QueueTests.testAutoAdvanceOnEpisodeEnd()"
                ],
                crashes=["Crash: PodWash at QueueTests.testAutoAdvanceOnEpisodeEnd()"],
            )
            prompt = build_tier2_continue_prompt(
                slice_file="docs/slices/slice-11-queue-resume.md",
                repo_root=tmp,
                outcome=outcome,
                run_i=1,
                max_runs=3,
            )
            self.assertIn("STUCK", prompt)
            self.assertIn("FailurePacket:", prompt)
            self.assertIn("hypothesis", prompt.lower())
            self.assertNotIn("Failing: ['PodWashTests", prompt)
            self.assertGreater(len(prompt), 800)

    def test_install_failure_gets_packaging_instruction(self):
        with tempfile.TemporaryDirectory() as tmp:
            outcome = self._make_outcome(
                failures=[
                    "PodWashTests/PodWash encountered an error — "
                    "missing its bundle executable"
                ],
                failure_class="build_error",
            )
            prompt = build_tier2_continue_prompt(
                slice_file="docs/slices/slice-11-queue-resume.md",
                repo_root=tmp,
                outcome=outcome,
                run_i=1,
                max_runs=3,
            )
            self.assertIn("Packaging/install", prompt)
            self.assertIn("bundle executable", prompt.lower())


if __name__ == "__main__":
    unittest.main()
