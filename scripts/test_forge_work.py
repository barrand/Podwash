#!/usr/bin/env python3
"""Unit tests for scripts/forge_work.py."""

from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "scripts"))

import forge_work as fw  # noqa: E402


class VerifyShipGreenTests(unittest.TestCase):
    def test_ship_green_requires_tier3_filtered0(self):
        self.assertFalse(fw.verify_is_ship_green({"exit": "0", "failed": "0", "skipped": "0"}))
        self.assertFalse(
            fw.verify_is_ship_green(
                {"exit": "0", "failed": "0", "skipped": "0", "tier": "2", "filtered": "1"}
            )
        )
        self.assertTrue(
            fw.verify_is_ship_green(
                {"exit": "0", "failed": "0", "skipped": "0", "tier": "3", "filtered": "0"}
            )
        )


class PromoteImplementedTests(unittest.TestCase):
    def test_promote_flips_task_and_slice(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            tasks = root / "docs" / "tasks"
            slices = root / "docs" / "slices"
            tasks.mkdir(parents=True)
            slices.mkdir(parents=True)
            tpath = tasks / "task-001-x.md"
            tpath.write_text(
                "| **Status** | Implemented |\n\n## Verification record\n\n"
                "```\nVERIFY RESULT: exit=0 total=1 passed=1 failed=0 skipped=0 "
                "filtered=1 tier=2\n```\n",
                encoding="utf-8",
            )
            spath = slices / "slice-01-x.md"
            spath.write_text(
                "| **Status** | Implemented |\n\n## Verification record\n\n"
                "```\nVERIFY RESULT: exit=0 total=1 passed=1 failed=0 skipped=0 "
                "filtered=1 tier=2\n```\n",
                encoding="utf-8",
            )
            ship = {
                "exit": "0",
                "total": "10",
                "passed": "10",
                "failed": "0",
                "skipped": "0",
                "filtered": "0",
                "tier": "3",
                "bundle": "b.xcresult",
            }
            updated = fw.promote_implemented_to_done(ship_verify=ship, repo_root=str(root))
            self.assertEqual(len(updated), 2)
            self.assertIn("| **Status** | Done |", tpath.read_text(encoding="utf-8"))
            self.assertIn("| **Status** | Done |", spath.read_text(encoding="utf-8"))
            self.assertIn("tier=3", tpath.read_text(encoding="utf-8"))


class CountItemsTests(unittest.TestCase):
    def test_count_implemented(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            tasks = root / "docs" / "tasks"
            tasks.mkdir(parents=True)
            (tasks / "task-002-y.md").write_text(
                "| **Status** | Implemented |\n", encoding="utf-8"
            )
            (tasks / "task-003-z.md").write_text(
                "| **Status** | Done |\n", encoding="utf-8"
            )
            with mock.patch.object(fw, "REPO_ROOT", str(root)):
                info = fw.count_items_since_batch_gate(repo_root=str(root))
            self.assertEqual(info["implemented_count"], 1)


class SummarizeCISafetyNetTests(unittest.TestCase):
    def _run(self, sha: str, badge: str) -> dict:
        return {
            "sha": sha[:12],
            "head_sha": sha,
            "badge": badge,
            "url": f"https://example.test/{sha[:7]}",
            "title": "CI",
        }

    def test_head_pass_with_collapsed_older_fails(self):
        head = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        runs = [
            self._run(head, "pass"),
            self._run("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "fail"),
            self._run("cccccccccccccccccccccccccccccccccccccccc", "fail"),
            self._run("dddddddddddddddddddddddddddddddddddddddd", "pass"),
            self._run("eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", "pending"),
        ]
        summary = fw.summarize_ci_safety_net(runs, head_sha=head)
        self.assertEqual(summary["head"]["badge"], "pass")
        self.assertEqual(summary["head"]["sha"], head[:12])
        self.assertTrue(summary["head"]["matches_head"])
        self.assertEqual(summary["older_total"], 4)
        self.assertEqual(summary["older_fail"], 2)
        self.assertEqual(summary["older_pass"], 1)
        self.assertEqual(summary["older_pending"], 1)

    def test_no_head_match_falls_back_to_latest(self):
        runs = [
            self._run("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "pending"),
            self._run("cccccccccccccccccccccccccccccccccccccccc", "fail"),
        ]
        summary = fw.summarize_ci_safety_net(
            runs, head_sha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        )
        self.assertEqual(summary["head"]["badge"], "pending")
        self.assertFalse(summary["head"]["matches_head"])
        self.assertEqual(summary["older_total"], 1)
        self.assertEqual(summary["older_fail"], 1)

    def test_empty_runs(self):
        summary = fw.summarize_ci_safety_net([], head_sha="aaa")
        self.assertIsNone(summary["head"])
        self.assertEqual(summary["older_total"], 0)


if __name__ == "__main__":
    unittest.main()
