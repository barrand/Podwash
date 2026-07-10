#!/usr/bin/env python3
"""Tests for LLM floor narration helpers."""

from __future__ import annotations

import os
import sys
import unittest
import unittest.mock

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)

from factory_floor_llm import (  # noqa: E402
    build_verify_green_llm_prompt,
    first_narration_line,
    floor_narration_llm_enabled,
    narrate_verify_green_dynamic,
    narrate_verify_green_minimal,
)


class FloorLlmTests(unittest.TestCase):
    def test_verify_green_prompt_is_not_a_template(self):
        p = build_verify_green_llm_prompt(
            name="Edison", role="Engineer", passed=6, total=6
        )
        self.assertIn("Edison", p)
        self.assertIn("6", p)
        self.assertIn("template", p.lower())
        self.assertNotIn("signs the sheet", p)

    def test_first_narration_line(self):
        self.assertEqual(
            first_narration_line('  "All six passed."  '),
            "All six passed.",
        )

    def test_minimal_fallback_when_llm_disabled(self):
        lines: list[str] = []
        with unittest.mock.patch.dict(os.environ, {"FORGE_LLM_NARRATION": "0"}):
            self.assertFalse(floor_narration_llm_enabled())
            line = narrate_verify_green_dynamic(
                None,
                "Edison",
                passed=6,
                total=6,
                role="Engineer",
                log=lines.append,
            )
        self.assertIn("all green (6/6)", line)
        self.assertEqual(len(lines), 1)

    def test_minimal_direct(self):
        lines: list[str] = []
        line = narrate_verify_green_minimal(
            "Edison", passed=6, total=6, log=lines.append
        )
        self.assertIn("Edison", line)
        self.assertIn("6/6", line)


if __name__ == "__main__":
    unittest.main()
