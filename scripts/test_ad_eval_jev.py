#!/usr/bin/env python3
"""Tests for the Jev ad-detection micro-evaluation."""

import hashlib
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from ad_eval_corpus_score import sha256
from ad_eval_gemini import sentence_rows
from ad_eval_jev import (
    CONTROL_SLUG,
    POSITIVE_SLUGS,
    ROLE_BOUNDARY_EXPERIMENT,
    ROLE_CHOICE_EXPERIMENT,
    Sample,
    boundary_metrics,
    boundary_observations_for,
    build_samples,
    deduplicate,
    metrics_at,
    parse_answers,
    parse_boundary_answers,
    request_payload,
    target_gaps,
)


def word(text: str, start: float, end: float) -> dict:
    return {"word": text, "start": start, "end": end}


def rows(count: int) -> list:
    return sentence_rows([word(f"Sentence {index}.", float(index), float(index) + 0.5) for index in range(count)])


class TestJevAdEval(unittest.TestCase):
    def test_build_samples_is_fixed_and_covers_every_positive_span(self) -> None:
        episodes = {}
        for slug in POSITIVE_SLUGS:
            episode_rows = rows(40)
            episodes[slug] = (
                {
                    "spans": [
                        {"id": "one", "start": 5.0, "end": 7.5},
                        {"id": "two", "start": 25.0, "end": 27.5},
                    ]
                },
                [],
                episode_rows,
            )
        episodes[CONTROL_SLUG] = ({"spans": []}, [], rows(100))
        samples = build_samples(episodes)
        positive = [sample for sample in samples if sample.kind == "ad-boundary"]
        controls = [sample for sample in samples if sample.kind == "no-ad-control"]
        self.assertEqual(len(positive), 4)
        self.assertEqual(len(controls), 10)
        self.assertEqual([sample.id for sample in samples], [sample.id for sample in build_samples(episodes)])
        self.assertTrue(all(sample.target_start < sample.target_end for sample in samples))

    def test_request_uses_batched_nouls_for_targets_only(self) -> None:
        episode_rows = rows(10)
        sample = Sample("sample", "show", "ad-boundary", 0, 10, 3, 6, "span")
        payload = request_payload({"show": "Show", "episode": "Episode", "showDescription": ""}, episode_rows, sample)
        self.assertEqual(payload["model"], "jev-1.13.0")
        self.assertEqual(
            set(payload["questions"]),
            {
                "sentence-4-paid-ad", "sentence-4-promo",
                "sentence-5-paid-ad", "sentence-5-promo",
                "sentence-6-paid-ad", "sentence-6-promo",
            },
        )
        self.assertTrue(all(question["type"] == "noul" for question in payload["questions"].values()))
        self.assertEqual([row["role"] for row in payload["state"]["transcript_window"]].count("target"), 3)

    def test_parse_answers_accepts_only_exact_noul_contract(self) -> None:
        target_rows = rows(2)
        response = {
            "model": "jev-1.13.0",
            "answers": {
                "sentence-1-paid-ad": {"type": "noul", "noul": 0.95},
                "sentence-1-promo": {"type": "noul", "noul": 0.1},
                "sentence-2-paid-ad": {"type": "noul", "noul": 0.1},
                "sentence-2-promo": {"type": "noul", "noul": 0.8},
            },
            "usage": {"input_tokens": 100, "output_tokens": 10},
        }
        parsed = parse_answers(response, target_rows)
        self.assertEqual([row["advertisementProbability"] for row in parsed], [0.95, 0.8])
        self.assertEqual(parsed[1]["promoProbability"], 0.8)
        response["answers"]["sentence-2-promo"]["noul"] = 1.1
        with self.assertRaisesRegex(ValueError, "outside"):
            parse_answers(response, target_rows)

    def test_role_choice_request_and_parsing(self) -> None:
        episode_rows = rows(4)
        sample = Sample("sample", "show", "ad-boundary", 0, 4, 1, 3, "span")
        payload = request_payload(
            {"show": "Show", "episode": "Episode", "showDescription": ""},
            episode_rows,
            sample,
            ROLE_CHOICE_EXPERIMENT,
        )
        self.assertEqual(set(payload["questions"]), {"sentence-2-role", "sentence-3-role"})
        self.assertTrue(all(question["type"] == "choice" for question in payload["questions"].values()))
        probabilities = {
            "paid_ad": 0.55,
            "cross_promo": 0.25,
            "routine_housekeeping": 0.05,
            "editorial_content": 0.10,
            "mixed_boundary": 0.05,
        }
        response = {
            "model": "jev-1.13.0",
            "answers": {
                f"sentence-{row.id}-role": {
                    "type": "choice",
                    "choice": "paid_ad",
                    "confidence": 0.8,
                    "probabilities": probabilities,
                }
                for row in episode_rows[1:3]
            },
            "usage": {"input_tokens": 100, "output_tokens": 10},
        }
        parsed = parse_answers(response, episode_rows[1:3], ROLE_CHOICE_EXPERIMENT)
        self.assertEqual([row["advertisementProbability"] for row in parsed], [0.8, 0.8])
        self.assertEqual(parsed[0]["selectedRole"], "paid_ad")
        response["answers"]["sentence-2-role"]["probabilities"]["paid_ad"] = 0.2
        with self.assertRaisesRegex(ValueError, "sum approximately"):
            parse_answers(response, episode_rows[1:3], ROLE_CHOICE_EXPERIMENT)

    def test_v4_role_and_boundary_contract(self) -> None:
        episode_rows = rows(4)
        sample = Sample("sample", "show", "ad-boundary", 0, 4, 1, 3, "span")
        payload = request_payload(
            {"show": "Show", "episode": "Episode", "showDescription": ""},
            episode_rows,
            sample,
            ROLE_BOUNDARY_EXPERIMENT,
        )
        gaps = target_gaps(episode_rows, sample)
        gap_ids = {f"gap-{left.id}-{right.id}-transition" for left, right in gaps}
        self.assertEqual(
            set(payload["questions"]),
            {"sentence-2-role", "sentence-3-role", *gap_ids},
        )
        role_probabilities = {
            "paid_ad": 0.6,
            "removable_bumper_or_cross_promo": 0.2,
            "routine_housekeeping": 0.05,
            "editorial_content": 0.1,
            "mixed_boundary": 0.05,
        }
        transition_probabilities = {
            "removable_begins": 0.8,
            "removable_ends": 0.05,
            "same_removable_continues": 0.05,
            "same_keep_continues": 0.05,
            "uncertain_or_mixed": 0.05,
        }
        response = {
            "model": "jev-1.13.0",
            "answers": {
                **{
                    f"sentence-{row.id}-role": {
                        "type": "choice",
                        "choice": "paid_ad",
                        "confidence": 0.8,
                        "probabilities": role_probabilities,
                    }
                    for row in episode_rows[1:3]
                },
                **{
                    question_id: {
                        "type": "choice",
                        "choice": "removable_begins",
                        "confidence": 0.8,
                        "probabilities": transition_probabilities,
                    }
                    for question_id in gap_ids
                },
            },
            "usage": {"input_tokens": 100, "output_tokens": 10},
        }
        parsed = parse_answers(
            response, episode_rows[1:3], ROLE_BOUNDARY_EXPERIMENT, gap_ids
        )
        self.assertEqual([row["advertisementProbability"] for row in parsed], [0.8, 0.8])
        boundary_answers = parse_boundary_answers(response, gaps)
        golden = {"spans": [{"start": 1.0, "end": 2.5}]}
        observations = boundary_observations_for(
            sample, episode_rows, golden, boundary_answers
        )
        self.assertEqual(observations[0]["goldenTransition"], "removable_begins")
        self.assertEqual(boundary_metrics(observations)["gapCount"], 3)

    def test_deduplication_and_fractional_time_scoring(self) -> None:
        observations = [
            {"sample": "a", "slug": "show", "sentence": 1, "start": 0.0, "end": 10.0, "text": "x", "goldenAdFraction": 1.0, "paidAdProbability": 0.8, "promoProbability": 0.1, "advertisementProbability": 0.8},
            {"sample": "b", "slug": "show", "sentence": 1, "start": 0.0, "end": 10.0, "text": "x", "goldenAdFraction": 1.0, "paidAdProbability": 1.0, "promoProbability": 0.2, "advertisementProbability": 1.0},
            {"sample": "a", "slug": "show", "sentence": 2, "start": 10.0, "end": 20.0, "text": "y", "goldenAdFraction": 0.25, "paidAdProbability": 0.1, "promoProbability": 0.05, "advertisementProbability": 0.1},
        ]
        unique = deduplicate(observations)
        self.assertEqual(unique[0]["advertisementProbability"], 0.9)
        self.assertEqual(unique[0]["observationCount"], 2)
        metrics = metrics_at(unique, 0.5)
        self.assertEqual(metrics["truePositiveSeconds"], 10.0)
        self.assertEqual(metrics["falseNegativeSeconds"], 2.5)
        self.assertEqual(metrics["precision"], 1.0)
        self.assertEqual(metrics["recall"], 0.8)

    def test_transcript_hash_is_stable_across_windows_line_endings(self) -> None:
        with TemporaryDirectory() as directory:
            path = Path(directory) / "transcript.json"
            path.write_bytes(b"[\r\n  {\"word\": \"Hello\"}\r\n]\r\n")
            expected = hashlib.sha256(b"[\n  {\"word\": \"Hello\"}\n]\n").hexdigest()
            self.assertEqual(sha256(path), expected)


if __name__ == "__main__":
    unittest.main()
