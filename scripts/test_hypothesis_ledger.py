#!/usr/bin/env python3
"""Unit tests for hypothesis ledger (spawn gate + durable JSONL)."""

from __future__ import annotations

import os
import sys
import tempfile
import unittest

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)

from hypothesis_ledger import (  # noqa: E402
    append_ledger,
    format_ledger_for_prompt,
    hypothesis_seen,
    ledger_path,
    load_ledger,
    make_entry,
    normalize_hypothesis,
)


class NormalizeTests(unittest.TestCase):
    def test_collapses_whitespace_case(self):
        self.assertEqual(
            normalize_hypothesis("  Cancel Fires  Before  "),
            "cancel fires before",
        )


class LedgerRoundTripTests(unittest.TestCase):
    def test_append_load_and_seen(self):
        with tempfile.TemporaryDirectory() as tmp:
            e1 = make_entry(
                slice_id=10,
                attempt=1,
                role="Engineer",
                hypothesis="cancel fires before bytes flushed",
                signature="PodWashTests/DownloadManagerTests/testCancel()",
                files_touched=["PodWash/PodWash/DownloadManager.swift"],
                verify_tier=1,
                outcome="red",
            )
            path = append_ledger(e1, repo_root=tmp, slice_id=10)
            self.assertTrue(os.path.isfile(path))
            self.assertEqual(path, ledger_path(tmp, 10))

            loaded = load_ledger(tmp, 10)
            self.assertEqual(len(loaded), 1)
            self.assertTrue(
                hypothesis_seen(
                    loaded,
                    "Cancel fires before bytes flushed",
                    "PodWashTests/DownloadManagerTests/testCancel()",
                )
            )
            self.assertFalse(
                hypothesis_seen(
                    loaded,
                    "different theory about AX race",
                    "PodWashTests/DownloadManagerTests/testCancel()",
                )
            )
            self.assertFalse(
                hypothesis_seen(
                    loaded,
                    "cancel fires before bytes flushed",
                    "other/signature",
                )
            )

    def test_format_for_prompt(self):
        entries = [
            make_entry(
                slice_id=9,
                attempt=1,
                role="Engineer",
                hypothesis="hold analyzing longer",
                signature="sig-a",
                outcome="red",
            )
        ]
        block = format_ledger_for_prompt(entries)
        self.assertIn("hold analyzing", block)
        self.assertIn("attempt=1", block)
        self.assertIn("(empty", format_ledger_for_prompt([]))


if __name__ == "__main__":
    unittest.main()
