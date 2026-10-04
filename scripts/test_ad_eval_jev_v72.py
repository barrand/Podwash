import unittest

from ad_eval_jev_v72 import choose_sentence_candidates, isolated_skip_most_ids, normalize_reasons


class JevV72Tests(unittest.TestCase):
    def test_normalize_reasons_can_abstain(self):
        result = normalize_reasons({"reasonProbabilities": {"signoff": 0.04, "network_id": 0.2}})
        self.assertEqual(result["primaryReason"], "uncertain")
        self.assertEqual(result["reasons"], [])
        self.assertTrue(result["reasonUncertain"])

    def test_normalize_reasons_selects_strongest_supported_reason(self):
        result = normalize_reasons({"reasonProbabilities": {"paid_ad": 0.91, "underwriting": 0.62}})
        self.assertEqual(result["primaryReason"], "paid_ad")
        self.assertEqual(result["reasons"], ["paid_ad", "underwriting"])

    def test_choose_sentence_candidates_prefers_anchor_then_probability(self):
        candidates = [
            self.candidate(10, 0.95, False, "skip_more_only"),
            self.candidate(10, 0.55, True, "skip_obvious"),
            self.candidate(11, 0.49, True, "skip_obvious"),
        ]
        chosen = choose_sentence_candidates(candidates)
        self.assertEqual(chosen[10]["tier"], "skip_obvious")
        self.assertNotIn(11, chosen)

    def test_isolated_skip_most_only_flags_unconnected_sentences(self):
        chosen = {
            1: {"tier": "skip_most_only"},
            3: {"tier": "skip_most_only"},
            4: {"tier": "skip_most_only"},
            6: {"tier": "skip_more_only"},
        }
        self.assertEqual(isolated_skip_most_ids(chosen), [1])

    @staticmethod
    def candidate(sentence, probability, anchor, tier):
        return {
            "sentence": sentence,
            "membershipProbability": probability,
            "insideSourceAnchor": anchor,
            "tier": tier,
        }


if __name__ == "__main__":
    unittest.main()
