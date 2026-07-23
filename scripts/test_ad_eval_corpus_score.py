#!/usr/bin/env python3
"""Corpus contract tests for the tracked ad-evaluation benchmark."""

import unittest
from pathlib import Path

from ad_eval_corpus_score import DEFAULT_CORPUS, DEFAULT_WORKDIR, grouped_coverage, load_corpus, summarize


class TestTrackedCorpus(unittest.TestCase):
    def test_manifest_discovers_all_human_approved_goldens(self) -> None:
        split, goldens = load_corpus(DEFAULT_CORPUS, DEFAULT_WORKDIR)
        self.assertEqual(len(goldens), 21)
        self.assertEqual(set(split.values()), {"development", "holdout"})
        self.assertEqual(split["cougar-sports"], "holdout")

    def test_two_zero_ad_episodes_are_preserved(self) -> None:
        _, goldens = load_corpus(DEFAULT_CORPUS, DEFAULT_WORKDIR)
        self.assertEqual(sorted(s for s, g in goldens.items() if not g["spans"]), ["ai-news-strategy-daily", "dr-death"])

    def test_every_label_is_a_binary_coverage_group(self) -> None:
        _, goldens = load_corpus(DEFAULT_CORPUS, DEFAULT_WORKDIR)
        spans = [span for golden in goldens.values() for span in golden["spans"]]
        labels = grouped_coverage([], spans, "label")
        self.assertEqual(set(labels), {"membership_cta", "network_promo", "paid_baked_in", "paid_dai", "paid_host_read"})
        self.assertTrue(all(value["coverage"] == 0.0 for value in labels.values()))

    def test_summary_reports_content_loss_per_listening_hour(self) -> None:
        row = {"durationSeconds": 1800.0, "timeWeighted": {"precision": 0.9, "recall": 0.8, "falsePositiveSeconds": 10.0, "falseNegativeSeconds": 20.0, "truePositiveSeconds": 80.0, "predictedAdSeconds": 90.0, "goldenAdSeconds": 100.0}, "contentLossSecondsPerListeningHour": 20.0}
        self.assertEqual(summarize([row])["contentLossSecondsPerListeningHour"], 20.0)


if __name__ == "__main__":
    unittest.main()
