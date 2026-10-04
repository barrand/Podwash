#!/usr/bin/env python3
"""Tests for the four-window Jev V8.1 boundary experiment."""

import unittest
from types import SimpleNamespace

from ad_eval_jev_v81_boundary import (
    CASES,
    FALSE_CRITERION,
    POSITIVE_THRESHOLD,
    evaluate_observations,
    v81_scout_payload,
)
from ad_eval_jev_v8 import ScoutWindow


class JevV81BoundaryTests(unittest.TestCase):
    def test_payload_freezes_protected_promo_policy(self) -> None:
        rows = [SimpleNamespace(id=index, start=index * 10, end=(index + 1) * 10, text=f"Sentence {index}") for index in range(4)]
        episode = {"context": {"show": "Show", "episode": "Episode"}, "rows": rows}
        window = ScoutWindow("show", 1, 10, 30, (1, 2), 0, 4)
        payload = v81_scout_payload(episode, window)
        question = payload["questions"]["window-paid-ad-presence"]
        self.assertEqual(len(payload["questions"]), 1)
        self.assertIn("third-party paid", question["instructions"])
        self.assertIn("feed-drop", FALSE_CRITERION)
        self.assertIn("ad-free subscription pitch", FALSE_CRITERION)
        self.assertEqual([row["role"] for row in payload["state"]["transcript_window"]], ["context", "target", "target", "context"])

    def test_frozen_cases_are_the_two_nearest_on_each_side(self) -> None:
        self.assertEqual([case.v8_probability for case in CASES], [0.80, 0.77, 0.86, 0.89])
        self.assertEqual(sum(case.expected_positive for case in CASES), 2)
        self.assertEqual(POSITIVE_THRESHOLD, 0.85)

    def test_evaluation_requires_all_four_cases_to_cross_correctly(self) -> None:
        passing = [
            {"id": case.id, "expectedPositive": case.expected_positive, "positive": case.expected_positive}
            for case in CASES
        ]
        result = evaluate_observations(passing)
        self.assertTrue(result["passed"])
        self.assertEqual(result["correctCount"], 4)
        failing = [dict(row) for row in passing]
        failing[0]["positive"] = True
        result = evaluate_observations(failing)
        self.assertFalse(result["passed"])
        self.assertFalse(result["protectedPromoWindowsNegative"])

    def test_evaluation_rejects_missing_case(self) -> None:
        with self.assertRaisesRegex(ValueError, "each frozen boundary case"):
            evaluate_observations([])


if __name__ == "__main__":
    unittest.main()
