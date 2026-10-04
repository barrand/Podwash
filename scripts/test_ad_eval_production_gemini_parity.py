import unittest

from ad_eval_production_gemini_parity import prompt_for, production_rows, validate_and_normalize


class ProductionGeminiParityTests(unittest.TestCase):
    def test_rows_use_zero_based_production_ids(self):
        words = [
            {"word": "Hello.", "start": 0.0, "end": 0.5},
            {"word": "World.", "start": 0.6, "end": 1.1},
        ]
        rows = production_rows(words)
        self.assertEqual([row.id for row in rows], [0, 1])
        self.assertIn("0\t0.000\t0.500\tHello.", prompt_for(rows))

    def test_normalization_merges_adjacent_spans(self):
        rows = self.rows()
        spans = validate_and_normalize({"spans": [
            {"start_sentence_id": 0, "end_sentence_id": 1},
            {"start_sentence_id": 2, "end_sentence_id": 2},
        ]}, rows)
        self.assertEqual(spans, [(0, 2)])

    def test_normalization_rejects_out_of_range_id(self):
        with self.assertRaises(ValueError):
            validate_and_normalize({"spans": [{"start_sentence_id": 0, "end_sentence_id": 4}]}, self.rows())

    @staticmethod
    def rows():
        words = [
            {"word": "One.", "start": 0.0, "end": 0.5},
            {"word": "Two.", "start": 0.6, "end": 1.1},
            {"word": "Three.", "start": 1.2, "end": 1.7},
        ]
        return production_rows(words)


if __name__ == "__main__":
    unittest.main()
