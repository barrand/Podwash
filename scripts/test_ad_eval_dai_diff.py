#!/usr/bin/env python3
import unittest

from ad_eval_dai_diff import divergent_original_spans


class TestDAIDiff(unittest.TestCase):
    def test_replaced_original_run_maps_to_original_timestamps(self) -> None:
        original = [
            {"word": word, "start": float(i) * 2, "end": float(i) * 2 + 1}
            for i, word in enumerate("story before alpha bravo charlie delta echo foxtrot story after".split())
        ]
        alternate = [
            {"word": word, "start": float(i) * 2, "end": float(i) * 2 + 1}
            for i, word in enumerate("story before omega sigma tau upsilon phi rho story after".split())
        ]
        spans = divergent_original_spans(original, alternate, min_seconds=3)
        self.assertEqual(spans, [(4.0, 15.0)])

    def test_alternate_only_insertion_has_no_original_prediction(self) -> None:
        original = [{"word": "story", "start": 0.0, "end": 1.0}, {"word": "after", "start": 2.0, "end": 3.0}]
        alternate = [{"word": "story", "start": 0.0, "end": 1.0}, {"word": "new", "start": 2.0, "end": 3.0}, {"word": "after", "start": 4.0, "end": 5.0}]
        self.assertEqual(divergent_original_spans(original, alternate), [])


if __name__ == "__main__":
    unittest.main()
