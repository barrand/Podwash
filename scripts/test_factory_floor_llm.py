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
    def test_streaming_tokens_join_into_sentences(self):
        from factory_floor_llm import invoke_floor_narrator_llm

        chunks = [
            "Hey",
            ", I'm",
            " Kai",
            " on",
            " the",
            " forge",
            " floor",
            ".",
            " Today's",
            " goal",
            " is",
            " segmentation",
            ".",
        ]

        def fake_run_worker(*_a, on_assistant_text=None, **_kw):
            for c in chunks:
                if on_assistant_text:
                    on_assistant_text(c)
            return True, "finished"

        lines = invoke_floor_narrator_llm(
            object(),
            role="Coordinator",
            prompt="x",
            api_key="k",
            repo_root="/tmp",
            log=lambda _m: None,
            run_worker=fake_run_worker,
            max_lines=2,
        )
        self.assertEqual(len(lines), 2)
        self.assertIn("Kai", lines[0])
        self.assertIn("segmentation", lines[1])

    def test_coalesce_token_fragments_in_shift_emit(self):
        from factory_narrator import narrate_coordinator_shift_llm

        emitted: list[str] = []
        narrate_coordinator_shift_llm(
            ["Hey", ",", " I'm", " Kai", "."],
            log=emitted.append,
        )
        self.assertEqual(len(emitted), 1)
        self.assertIn("Kai", emitted[0])

    def test_coordinator_shift_prompt_forbids_banner_repeat(self):
        from factory_floor_llm import build_coordinator_shift_llm_prompt

        p = build_coordinator_shift_llm_prompt(
            coordinator_name="Kai",
            slice_id=18,
            title="Segmentation spike",
            mission="Benchmark precision/recall on a fixture.",
        )
        self.assertIn("Do NOT repeat", p)
        self.assertIn("ONE short sentence", p)

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
