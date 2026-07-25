#!/usr/bin/env python3
"""Tests for the offline Gemini ad-evaluation harness."""

import unittest

from ad_eval_gemini import (
    MAX_SENTENCE_SECONDS,
    build_user_prompt,
    extract_response,
    request_payload,
    sentence_rows,
    sentence_spans_to_time,
    usage_cost,
    validate_prediction,
)


def word(text: str, start: float, end: float) -> dict:
    return {"word": text, "start": start, "end": end}


class TestGeminiAdEval(unittest.TestCase):
    def test_sentence_rows_use_punctuation_gap_and_max_duration(self) -> None:
        words = [
            word("Hello", 0.0, 0.2), word("there.", 0.2, 0.5),
            word("A", 1.3, 1.4), word("gap", 1.4, 1.6),
            word("After", 2.3, 2.4), word("gap.", 2.4, 2.6),
        ]
        rows = sentence_rows(words)
        self.assertEqual([(row.start_word, row.end_word) for row in rows], [(0, 2), (2, 4), (4, 6)])
        self.assertEqual(rows[0].text, "Hello there.")

        long_words = [word("word", index * 0.5, index * 0.5 + 0.1) for index in range(40)]
        long_rows = sentence_rows(long_words)
        self.assertGreaterEqual(long_rows[0].end - long_rows[0].start, MAX_SENTENCE_SECONDS)

    def test_prompt_contains_complete_untruncated_rows(self) -> None:
        rows = sentence_rows([word("One.", 0.0, 0.2), word("Two.", 0.2, 0.4)])
        prompt = build_user_prompt({"show": "Show", "episode": "Episode", "showDescription": "desc"}, rows)
        self.assertIn("[1] | 0.00-0.20 | w0-w0 | One.", prompt)
        self.assertIn("[2] | 0.20-0.40 | w1-w1 | Two.", prompt)
        self.assertEqual(request_payload(prompt)["generationConfig"]["responseMimeType"], "application/json")

    def test_valid_prediction_maps_sentence_ranges_to_times(self) -> None:
        rows = sentence_rows([word("One.", 0.0, 0.2), word("Two.", 0.2, 0.5), word("Three.", 0.5, 0.8)])
        spans = validate_prediction({"spans": [{"startSentence": 1, "endSentence": 2}]}, rows)
        self.assertEqual(sentence_spans_to_time(spans, rows), [(0.0, 0.5)])

    def test_invalid_predictions_are_rejected(self) -> None:
        rows = sentence_rows([word("One.", 0.0, 0.2), word("Two.", 0.2, 0.5)])
        with self.assertRaisesRegex(ValueError, "only a spans"):
            validate_prediction({"spans": [], "reason": "no"}, rows)
        with self.assertRaisesRegex(ValueError, "invalid sentence range"):
            validate_prediction({"spans": [{"startSentence": 2, "endSentence": 3}]}, rows)
        with self.assertRaisesRegex(ValueError, "non-overlapping"):
            validate_prediction({"spans": [{"startSentence": 1, "endSentence": 1}, {"startSentence": 1, "endSentence": 2}]}, rows)

    def test_extract_response_and_cost_include_thinking_tokens(self) -> None:
        response = {
            "candidates": [{"content": {"parts": [{"thought": True, "text": "internal reasoning, not JSON"}, {"text": '{"spans": []}'}]}}],
            "usageMetadata": {"promptTokenCount": 1000, "candidatesTokenCount": 200, "thoughtsTokenCount": 300, "totalTokenCount": 1500},
        }
        prediction, raw, usage = extract_response(response)
        self.assertEqual(prediction, {"spans": []})
        self.assertEqual(raw, '{"spans": []}')
        self.assertEqual(usage_cost(usage)["totalCostUsd"], 0.00525)


if __name__ == "__main__":
    unittest.main()
