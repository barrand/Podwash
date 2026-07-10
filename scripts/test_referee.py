#!/usr/bin/env python3
"""Unit tests for LLM referee (strict JSON parse + halt-on-low-confidence)."""

from __future__ import annotations

import os
import sys
import unittest

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)

from failure_packet import FailurePacket  # noqa: E402
from referee import (  # noqa: E402
    RefereeError,
    apply_verdict_to_packet,
    build_referee_prompt,
    parse_referee_reply,
)


SAMPLE_JSON = """{
  "primary_failure": "PodWashTests/DownloadManagerTests/testCancelRemovesPartialAndRetainsResumeData()",
  "failure_groups": [["unit cancel/resume"], ["download UI"]],
  "role": "Engineer",
  "fix_scope": "app",
  "files": ["PodWash/PodWash/DownloadManager.swift"],
  "instruction": "Resume data nil after cancel: check delegate threading and cancel gate timing",
  "hypothesis": "cancel fires before URLSession flushes bytes; main.sync risks deadlock",
  "confidence": "high",
  "narration": "Unit cancel is primary — app-side."
}"""


class ParseRefereeTests(unittest.TestCase):
    def test_parses_strict_json(self):
        v = parse_referee_reply(SAMPLE_JSON)
        self.assertEqual(v.role, "Engineer")
        self.assertEqual(v.fix_scope, "app")
        self.assertEqual(v.confidence, "high")
        self.assertIn("cancel fires", v.hypothesis)
        self.assertEqual(v.files[0], "PodWash/PodWash/DownloadManager.swift")
        self.assertEqual(len(v.failure_groups), 2)

    def test_parses_fenced_json(self):
        text = f"Here is my verdict:\n```json\n{SAMPLE_JSON}\n```\n"
        v = parse_referee_reply(text)
        self.assertEqual(v.confidence, "high")

    def test_medium_maps_to_med(self):
        blob = SAMPLE_JSON.replace('"high"', '"medium"')
        v = parse_referee_reply(blob)
        self.assertEqual(v.confidence, "med")

    def test_low_confidence_halts(self):
        blob = SAMPLE_JSON.replace('"high"', '"low"')
        with self.assertRaises(RefereeError) as ctx:
            parse_referee_reply(blob)
        self.assertIn("confidence=low", ctx.exception.reason)

    def test_empty_reply_halts(self):
        with self.assertRaises(RefereeError):
            parse_referee_reply("")

    def test_invalid_role_halts(self):
        blob = SAMPLE_JSON.replace('"Engineer"', '"PM"')
        with self.assertRaises(RefereeError):
            parse_referee_reply(blob)

    def test_missing_hypothesis_halts(self):
        blob = SAMPLE_JSON.replace(
            '"hypothesis": "cancel fires before URLSession flushes bytes; main.sync risks deadlock"',
            '"hypothesis": ""',
        )
        with self.assertRaises(RefereeError):
            parse_referee_reply(blob)

    def test_qa_role_and_tests_scope(self):
        blob = (
            SAMPLE_JSON.replace('"Engineer"', '"QA"').replace('"app"', '"tests"')
        )
        v = parse_referee_reply(blob)
        self.assertEqual(v.role, "QA")
        self.assertEqual(v.fix_scope, "tests")


class RefereePromptTests(unittest.TestCase):
    def test_prompt_includes_packet_and_ledger(self):
        packet = FailurePacket(
            test_ids=["PodWashTests/Foo/testA()"],
            assertions=["XCTAssertEqual failed"],
            signature="PodWashTests/Foo/testA()",
            actionable=True,
        )
        prompt = build_referee_prompt(
            packet,
            slice_file="docs/slices/slice-10.md",
            stuck_card="STUCK CARD HERE",
            ledger_entries=[],
        )
        self.assertIn("fix referee", prompt.lower())
        self.assertIn("STUCK CARD HERE", prompt)
        self.assertIn("PodWashTests/Foo/testA()", prompt)
        self.assertIn("confidence", prompt.lower())


class ApplyVerdictTests(unittest.TestCase):
    def test_applies_hypothesis_and_files(self):
        packet = FailurePacket(suggested_files=["PodWash/PodWash/A.swift"])
        v = parse_referee_reply(SAMPLE_JSON)
        merged = apply_verdict_to_packet(packet, v)
        self.assertIn("cancel fires", merged.hypothesis)
        self.assertEqual(merged.fix_scope, "app")
        self.assertIn("PodWash/PodWash/DownloadManager.swift", merged.suggested_files)
        self.assertIn("PodWash/PodWash/A.swift", merged.suggested_files)


if __name__ == "__main__":
    unittest.main()
