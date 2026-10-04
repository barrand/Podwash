import unittest

from ad_eval_jev_v71 import Block, candidate_blocks, interval_metrics, merge_spans, split_block


class JevV71Tests(unittest.TestCase):
    def test_candidate_blocks_group_only_adjacent_candidates(self):
        rows = [
            self.observation(1, 0.9),
            self.observation(2, 0.8),
            self.observation(3, 0.0, "editorial_content"),
            self.observation(4, 0.31, "editorial_content"),
        ]
        blocks = candidate_blocks("show", rows)
        self.assertEqual(blocks, [Block("show", 0, 2), Block("show", 3, 4)])

    def test_split_block_covers_original_without_overlap(self):
        left, right = split_block(Block("show", 2, 9))
        self.assertEqual(left, Block("show", 2, 5))
        self.assertEqual(right, Block("show", 5, 9))

    def test_merge_spans_requires_same_tier_and_reasons(self):
        spans = [
            self.span(1, 2, "skip_obvious", ["paid_ad"]),
            self.span(3, 4, "skip_obvious", ["paid_ad"]),
            self.span(5, 6, "skip_more_only", ["cross_show_promo"]),
        ]
        merged = merge_spans(spans)
        self.assertEqual(len(merged), 2)
        self.assertEqual((merged[0]["startSentence"], merged[0]["endSentence"]), (1, 4))

    def test_interval_metrics(self):
        metrics = interval_metrics([(0, 10)], [(5, 15)])
        self.assertEqual(metrics["precision"], 0.5)
        self.assertEqual(metrics["recall"], 0.5)

    @staticmethod
    def observation(sentence, probability, role="removable_candidate"):
        return {
            "sentence": sentence,
            "selectedRole": role,
            "probabilities": {"removable_candidate": probability},
        }

    @staticmethod
    def span(first, last, tier, reasons):
        return {
            "startSentence": first,
            "endSentence": last,
            "startWord": first,
            "endWord": last + 1,
            "start": float(first),
            "end": float(last + 1),
            "tier": tier,
            "reasons": reasons,
        }


if __name__ == "__main__":
    unittest.main()
