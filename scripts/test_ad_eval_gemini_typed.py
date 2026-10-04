import unittest

from pathlib import Path
from tempfile import TemporaryDirectory

from ad_eval_gemini_typed import invalid_attempt_cost, request_payload, validate_prediction


class GeminiTypedEvalTests(unittest.TestCase):
    def test_validate_prediction_accepts_typed_sorted_spans(self):
        result = validate_prediction({"spans": [{
            "startSentence": 2,
            "endSentence": 4,
            "minimumPreset": "skip_more_only",
            "reasons": ["cross_show_promo"],
        }]}, 10)
        self.assertEqual(result[0]["tier"], "skip_more_only")

    def test_validate_prediction_allows_lower_tier_reason_in_mixed_block(self):
        result = validate_prediction({"spans": [{
            "startSentence": 2,
            "endSentence": 4,
            "minimumPreset": "skip_more_only",
            "reasons": ["cross_show_promo", "underwriting"],
        }]}, 10)
        self.assertEqual(result[0]["tier"], "skip_more_only")

    def test_validate_prediction_rejects_reason_requiring_higher_tier(self):
        with self.assertRaises(ValueError):
            validate_prediction({"spans": [{
                "startSentence": 2,
                "endSentence": 4,
                "minimumPreset": "skip_obvious",
                "reasons": ["signoff"],
            }]}, 10)

    def test_validate_prediction_rejects_overlap(self):
        with self.assertRaises(ValueError):
            validate_prediction({"spans": [
                {"startSentence": 2, "endSentence": 4, "minimumPreset": "skip_obvious", "reasons": ["paid_ad"]},
                {"startSentence": 4, "endSentence": 5, "minimumPreset": "skip_more_only", "reasons": ["cross_show_promo"]},
            ]}, 10)

    def test_retry_payload_uses_low_thinking(self):
        payload = request_payload("transcript", thinking_level="LOW")
        self.assertEqual(payload["generationConfig"]["thinkingConfig"]["thinkingLevel"], "LOW")

    def test_invalid_attempt_cost_reads_provider_usage(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / "invalid.json"
            path.write_text('{"usageMetadata":{"promptTokenCount":1000000,"candidatesTokenCount":0,"thoughtsTokenCount":0}}', encoding="utf-8")
            self.assertEqual(invalid_attempt_cost(path), 1.5)


if __name__ == "__main__":
    unittest.main()
