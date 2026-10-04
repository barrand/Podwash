#!/usr/bin/env python3
"""Focused tests for V8.3's frozen candidate-region geometry."""

from __future__ import annotations

import unittest

from ad_eval_jev_v83_holdout_localize import build_regions


class RegionTests(unittest.TestCase):
    def test_merges_overlapping_positive_scout_windows(self) -> None:
        report = {"windows": [
            {"slug": "test", "start": 0, "end": 120, "positive": True},
            {"slug": "test", "start": 60, "end": 180, "positive": True},
            {"slug": "test", "start": 240, "end": 360, "positive": True},
            {"slug": "other", "start": 0, "end": 120, "positive": True},
        ]}
        self.assertEqual([(r.start, r.end) for r in build_regions(report, "test")], [(0.0, 180.0), (240.0, 360.0)])

    def test_requires_at_least_one_positive_region(self) -> None:
        with self.assertRaisesRegex(ValueError, "no positive"):
            build_regions({"windows": [{"slug": "test", "start": 0, "end": 120, "positive": False}]}, "test")


if __name__ == "__main__":
    unittest.main()
