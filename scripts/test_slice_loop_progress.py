#!/usr/bin/env python3
"""Unit tests for slice-loop progress formatting (no SDK / Xcode)."""

import os
import sys
import unittest

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)

from slice_loop_progress import (  # noqa: E402
    infer_role,
    parse_verify_result,
    read_slice_meta,
    shell_result_note,
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

    def test_read_slice_meta_from_repo(self):
        repo = os.path.dirname(SCRIPT_DIR)
        title, rel = read_slice_meta("docs/slices/slice-06-rss-episode-list.md", repo)
        self.assertEqual(rel, "docs/slices/slice-06-rss-episode-list.md")
        self.assertIn("RSS", title)


if __name__ == "__main__":
    unittest.main()
