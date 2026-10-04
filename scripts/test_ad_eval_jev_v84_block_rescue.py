#!/usr/bin/env python3
from __future__ import annotations
import unittest
from ad_eval_corpus_score import DEFAULT_CORPUS, DEFAULT_WORKDIR
from ad_eval_jev_v8 import load_episode
from ad_eval_jev_v84_block_rescue import CASES, SLUG, block_for_case

class BlockGeometryTests(unittest.TestCase):
    def test_frozen_cases_match(self) -> None:
        episode = load_episode(DEFAULT_CORPUS, DEFAULT_WORKDIR, SLUG)
        for case in CASES:
            block = block_for_case(episode, case); rows = episode["rows"]
            self.assertEqual(rows[block.start_index].id, case.first_sentence)
            self.assertEqual(rows[block.end_index - 1].id, case.last_sentence)

if __name__ == "__main__": unittest.main()
