#!/usr/bin/env python3
"""Tests for the locked Jev V8.1 six-episode regression."""

import unittest

from ad_eval_jev_v81 import (
    CONTROL_SLUG,
    PROTECTED_CATEGORIES,
    SLUGS,
    STAGE2_CONTROL_SLUGS,
    STAGE2_SLUGS,
    score_results,
)


class JevV81RegressionTests(unittest.TestCase):
    def test_frozen_regression_corpus_and_protected_categories(self) -> None:
        self.assertEqual(
            SLUGS,
            (
                "bill-simmons-kawhi", "economics-of-everyday-things", "darknet-diaries",
                "99-percent-invisible", "unexplainable", "ai-news-strategy-daily",
            ),
        )
        self.assertEqual(CONTROL_SLUG, "ai-news-strategy-daily")
        self.assertEqual(PROTECTED_CATEGORIES, {"network_promo", "membership_cta"})

    def test_passing_results_meet_every_gate(self) -> None:
        episodes, observations = self.fixture()
        score = score_results(episodes, observations)
        self.assertTrue(score["passed"])
        self.assertEqual(score["aggregate"]["paidSecondsCoverageRecall"], 1.0)
        self.assertEqual(score["aggregate"]["promoOnlyPositiveWindowCount"], 0)

    def test_protected_promo_positive_fails_its_own_gate(self) -> None:
        episodes, observations = self.fixture()
        next(row for row in observations if row["promoOnly"])["positive"] = True
        score = score_results(episodes, observations)
        self.assertFalse(score["passed"])
        self.assertFalse(score["gates"]["promoOnlyWindowsAllNegative"])

    def test_control_positive_fails_its_own_gate(self) -> None:
        episodes, observations = self.fixture()
        next(row for row in observations if row["slug"] == CONTROL_SLUG)["positive"] = True
        score = score_results(episodes, observations)
        self.assertFalse(score["passed"])
        self.assertFalse(score["gates"]["controlHasZeroPositiveWindows"])

    def test_stage2_rejects_a_positive_in_either_control(self) -> None:
        self.assertEqual(
            STAGE2_CONTROL_SLUGS,
            ("stage2-ai-news", "stage2-dr-death"),
        )
        episodes = {
            "paid": {"duration": 120.0, "golden": {"spans": [{"id": "ad", "start": 20, "end": 40, "category": "paid_ad"}]}},
            "stage2-ai-news": {"duration": 120.0, "golden": {"spans": []}},
            "stage2-dr-death": {"duration": 120.0, "golden": {"spans": [{"id": "promo", "start": 0, "end": 120, "category": "network_promo"}]}},
        }
        observations = [
            {"slug": "paid", "start": 0, "end": 120, "positive": True, "promoOnly": False},
            {"slug": "stage2-ai-news", "start": 0, "end": 120, "positive": False, "promoOnly": False},
            {"slug": "stage2-dr-death", "start": 0, "end": 120, "positive": True, "promoOnly": True},
        ]
        score = score_results(
            episodes,
            observations,
            slugs=("paid", *STAGE2_CONTROL_SLUGS),
            control_slugs=STAGE2_CONTROL_SLUGS,
        )
        self.assertFalse(score["passed"])
        self.assertFalse(score["gates"]["controlHasZeroPositiveWindows"])

    @staticmethod
    def fixture() -> tuple[dict, list[dict]]:
        episodes, observations = {}, []
        for slug in SLUGS:
            spans = [] if slug == CONTROL_SLUG else [{"id": f"{slug}-ad", "start": 20, "end": 40, "category": "paid_ad"}]
            if slug == "darknet-diaries":
                spans.append({"id": "promo", "start": 60, "end": 80, "category": "membership_cta"})
            episodes[slug] = {"duration": 180.0, "golden": {"spans": spans}}
            observations.extend(
                [
                    {"slug": slug, "start": 0, "end": 60, "positive": slug != CONTROL_SLUG, "promoOnly": False},
                    {"slug": slug, "start": 60, "end": 120, "positive": False, "promoOnly": slug == "darknet-diaries"},
                ]
            )
        return episodes, observations


if __name__ == "__main__":
    unittest.main()
