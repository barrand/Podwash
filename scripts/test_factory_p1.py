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
    NameAssigner,
    narrate_exoneration,
    narrate_spawn,
    narrate_thrash_halt,
    narrate_verify_red,
)
from sim_hygiene import (  # noqa: E402
    CrashWatchdog,
    classify_infra_failure,
    should_stress_run,
    stress_run_count,
)
from slice_pipeline import (  # noqa: E402
    extract_mapped_test_ids,
    tier2_marker_ok,
    write_tier2_marker,
)


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


class NarratorTests(unittest.TestCase):
    def test_name_pools_cycle(self):
        n = NameAssigner()
        a = n.assign("Engineer")
        b = n.assign("Engineer", slot="Engineer-2")
        self.assertEqual(a, "Edison")
        self.assertEqual(b, "Elena")
        self.assertEqual(n.assign("Referee"), "Rhea")

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


if __name__ == "__main__":
    unittest.main()
