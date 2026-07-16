#!/usr/bin/env python3
"""Unit tests for ad_eval_score time-weighted metrics (scripts-only gate)."""

from __future__ import annotations

import unittest

from ad_eval_score import failure_modes, match_pairs, time_weighted


class TestTimeWeightedMetrics(unittest.TestCase):
    def test_perfect_overlap(self) -> None:
        pred = [(10.0, 20.0)]
        gold = [(10.0, 20.0)]
        tw = time_weighted(pred, gold)
        self.assertEqual(tw["precision"], 1.0)
        self.assertEqual(tw["recall"], 1.0)

    def test_end_bleed_hurts_precision(self) -> None:
        pred = [(10.0, 30.0)]  # 10s bleed past gold end 20
        gold = [(10.0, 20.0)]
        tw = time_weighted(pred, gold)
        self.assertLess(tw["precision"], 0.6)
        self.assertEqual(tw["recall"], 1.0)
        self.assertGreater(tw["falsePositiveSeconds"], 9.0)

    def test_late_start_hurts_recall(self) -> None:
        pred = [(15.0, 20.0)]
        gold = [(10.0, 20.0)]
        tw = time_weighted(pred, gold)
        self.assertEqual(tw["precision"], 1.0)
        self.assertLess(tw["recall"], 0.6)

    def test_failure_mode_end_bleed(self) -> None:
        pred = [(10.0, 30.0)]
        gold = [(10.0, 20.0)]
        _, matches = match_pairs(pred, gold)
        modes = failure_modes(pred, gold, matches)
        self.assertTrue(any(m["mode"] == "end-bleed" for m in modes))


if __name__ == "__main__":
    unittest.main()
