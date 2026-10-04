#!/usr/bin/env python3
"""Unit tests for the V8.2B boundary-stitching decision test."""

from __future__ import annotations

import unittest

from ad_eval_jev_v82_stitch import bridge_intervals


class BridgeIntervalsTests(unittest.TestCase):
    def test_bridges_one_fifteen_second_gap(self) -> None:
        self.assertEqual(
            bridge_intervals([(100.0, 115.0), (130.0, 145.0)]),
            [(100.0, 145.0)],
        )

    def test_does_not_bridge_more_than_fifteen_seconds(self) -> None:
        self.assertEqual(
            bridge_intervals([(100.0, 115.0), (130.001, 145.0)]),
            [(100.0, 115.0), (130.001, 145.0)],
        )

    def test_merges_overlapping_intervals_before_bridging(self) -> None:
        self.assertEqual(
            bridge_intervals([(120.0, 140.0), (100.0, 125.0), (150.0, 160.0)]),
            [(100.0, 160.0)],
        )


if __name__ == "__main__":
    unittest.main()
