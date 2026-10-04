#!/usr/bin/env python3
"""Tests for the Jev V8 two-minute paid-ad scout."""

import unittest
from types import SimpleNamespace

from ad_eval_jev_v8 import (
    POSITIVE_THRESHOLD,
    build_windows,
    parse_probability,
    score_results,
    scout_payload,
    union_intervals,
)


def row(identifier: int, start: float, end: float) -> SimpleNamespace:
    return SimpleNamespace(id=identifier, start=start, end=end, text=f"Sentence {identifier}.")


class JevV8Tests(unittest.TestCase):
    def test_windows_overlap_and_include_final_partial_window(self) -> None:
        rows = [row(index + 1, index * 30.0, (index + 1) * 30.0) for index in range(9)]
        windows = build_windows("show", rows, 270.0)
        self.assertEqual([(window.start, window.end) for window in windows], [(0.0, 120.0), (60.0, 180.0), (120.0, 240.0), (180.0, 270.0), (240.0, 270.0)])
        self.assertEqual(windows[-1].target_indices, (8,))

    def test_payload_has_one_noul_and_two_context_sentences(self) -> None:
        rows = [row(index + 1, index * 20.0, (index + 1) * 20.0) for index in range(10)]
        window = build_windows("show", rows, 200.0)[1]
        episode = {"context": {"show": "Show", "episode": "Episode", "showDescription": ""}, "rows": rows}
        payload = scout_payload(episode, window)
        self.assertEqual(len(payload["questions"]), 1)
        self.assertEqual(next(iter(payload["questions"].values()))["type"], "noul")
        rendered = payload["state"]["transcript_window"]
        target_count = sum(item["role"] == "target" for item in rendered)
        self.assertEqual(target_count, len(window.target_indices))
        self.assertEqual(len(rendered) - target_count, 3)  # two before; only one remains after near the episode end

    def test_probability_parser_rejects_invalid_contract(self) -> None:
        response = {"model": "jev-1.13.0", "answers": {"window-paid-ad-presence": {"type": "noul", "noul": 0.75}}}
        self.assertEqual(parse_probability(response), 0.75)
        response["answers"]["window-paid-ad-presence"]["noul"] = 1.1
        with self.assertRaisesRegex(ValueError, "0...1"):
            parse_probability(response)

    def test_union_and_scoring_apply_frozen_threshold(self) -> None:
        self.assertEqual(union_intervals([(0, 120), (60, 180), (240, 250)]), [(0, 180), (240, 250)])
        episodes = {
            "armchair-expert-grant-achatz": self.episode(300, [{"id": "a", "start": 70, "end": 100, "category": "paid_ad"}]),
            "this-american-life": self.episode(300, [{"id": "b", "start": 180, "end": 200, "category": "paid_ad"}]),
            "dr-death": self.episode(300, []),
        }
        observations = [
            self.observation("armchair-expert-grant-achatz", 0, 120, POSITIVE_THRESHOLD),
            self.observation("this-american-life", 120, 240, 0.9),
            self.observation("dr-death", 0, 120, 0.19),
        ]
        score = score_results(episodes, observations)
        self.assertTrue(score["gates"]["everyPaidSpanHit"])
        self.assertTrue(score["gates"]["controlHasZeroPositiveWindows"])
        self.assertEqual(score["aggregate"]["paidSecondsCoverageRecall"], 1.0)

    @staticmethod
    def episode(duration: float, spans: list[dict]) -> dict:
        return {"duration": duration, "golden": {"spans": spans}}

    @staticmethod
    def observation(slug: str, start: float, end: float, probability: float) -> dict:
        return {"slug": slug, "start": start, "end": end, "probability": probability, "positive": probability >= POSITIVE_THRESHOLD}


if __name__ == "__main__":
    unittest.main()
