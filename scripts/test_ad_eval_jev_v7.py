import unittest

from ad_eval_jev_v7 import Window, subtype_windows, typed_spans


class JevV7Tests(unittest.TestCase):
    def test_subtype_windows_limit_targets_and_split_distant_candidates(self):
        rows = [object()] * 30
        windows = subtype_windows("show", rows, [1, 2, 3, 4, 5, 20])
        self.assertEqual([window.target_indices for window in windows], [(1, 2, 3, 4), (5,), (20,)])
        self.assertTrue(all(isinstance(window, Window) for window in windows))

    def test_typed_spans_merge_adjacent_matching_reasons(self):
        observations = [
            self.row(1, 0, 4, {"paid_ad": 0.9}),
            self.row(2, 4, 8, {"paid_ad": 0.8}),
            self.row(3, 8, 12, {}),
            self.row(4, 12, 16, {"production_credit": 0.7}),
        ]
        spans = typed_spans(observations)
        self.assertEqual(len(spans), 2)
        self.assertEqual((spans[0]["startSentence"], spans[0]["endSentence"]), (1, 2))
        self.assertEqual(spans[0]["reasons"], ["paid_ad"])
        self.assertEqual(spans[1]["reasons"], ["production_credit"])

    def test_typed_spans_keep_multiple_reasons(self):
        spans = typed_spans([
            self.row(1, 0, 4, {"membership_appeal": 0.8, "publisher_promo": 0.9})
        ])
        self.assertEqual(spans[0]["reasons"], ["membership_appeal", "publisher_promo"])

    @staticmethod
    def row(sentence, start_word, end_word, probabilities):
        return {
            "sentence": sentence,
            "startWord": start_word,
            "endWord": end_word,
            "start": float(start_word),
            "end": float(end_word),
            "reasonProbabilities": probabilities,
        }


if __name__ == "__main__":
    unittest.main()
