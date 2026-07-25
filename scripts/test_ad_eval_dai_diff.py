#!/usr/bin/env python3
import json
import unittest
from pathlib import Path

from ad_eval_dai_diff import DEFAULT_GATE, Parameters, aggregate, divergent_original_spans, initial_prompt, validate_provenance


def words(text: str) -> list[dict]:
    return [{"word": word, "start": float(i) * 2, "end": float(i) * 2 + 1} for i, word in enumerate(text.split())]


P = Parameters(window_words=20, overlap_words=2, search_padding_words=20, anchor_words=2, min_seconds=3, merge_gap_seconds=1)


class TestDAIDiff(unittest.TestCase):
    def test_replacement_maps_to_original_timestamps(self) -> None:
        original = words("stable opening alpha bravo charlie delta stable ending")
        alternate = words("stable opening omega sigma tau upsilon stable ending")
        self.assertEqual(divergent_original_spans(original, alternate, P), [(4.0, 11.0)])

    def test_alternate_only_insertion_has_no_original_prediction(self) -> None:
        original = words("stable opening stable ending")
        alternate = words("stable opening new inserted advertisement stable ending")
        self.assertEqual(divergent_original_spans(original, alternate, P), [])

    def test_original_only_deletion_is_predicted(self) -> None:
        original = words("stable opening paid message lives here stable ending")
        alternate = words("stable opening stable ending")
        self.assertEqual(divergent_original_spans(original, alternate, P), [(4.0, 11.0)])

    def test_short_fragmented_asr_substitution_is_ignored(self) -> None:
        original = words("stable opening a brief error stable ending")
        alternate = words("stable opening a tiny error stable ending")
        strict = Parameters(**{**P.__dict__, "min_seconds": 5.0})
        self.assertEqual(divergent_original_spans(original, alternate, strict), [])

    def test_adjacent_creatives_with_content_anchor_stay_separate(self) -> None:
        original = words("stable opening alpha bravo charlie sponsor interlude delta echo foxtrot stable ending")
        alternate = words("stable opening omega sigma tau sponsor interlude gamma theta lambda stable ending")
        separate = Parameters(**{**P.__dict__, "merge_gap_seconds": 0.5})
        spans = divergent_original_spans(original, alternate, separate)
        self.assertEqual(len(spans), 2)

    def test_long_stable_content_surrounding_changed_pod(self) -> None:
        prefix = " ".join(f"before{i}" for i in range(20))
        suffix = " ".join(f"after{i}" for i in range(20))
        original = words(f"{prefix} original ad copy is here today {suffix}")
        alternate = words(f"{prefix} alternate paid message runs right now {suffix}")
        self.assertEqual(len(divergent_original_spans(original, alternate, P)), 1)

    def test_repeated_phrase_alignment_does_not_mark_stable_episode(self) -> None:
        transcript = words("repeat phrase repeat phrase repeat phrase stable ending")
        self.assertEqual(divergent_original_spans(transcript, transcript, P), [])

    def test_repetitive_asr_hallucination_does_not_mark_content(self) -> None:
        original = words(
            "stable opening im not going to take it anymore if you were shooting "
            "a time capsule into space for an advanced alien species stable ending"
        )
        alternate = words(
            "stable opening im mad as hell im mad as hell im mad as hell im mad as hell "
            "im mad as hell im mad as hell im mad as hell im mad as hell stable ending"
        )
        self.assertEqual(divergent_original_spans(original, alternate, P), [])

    def test_provenance_rejects_prompt_mismatch(self) -> None:
        original = {"engine": "mlx-whisper", "engineVersion": "1", "model": "m", "modelRevision": "r", "language": "en", "wordTimestamps": True, "conditionOnPreviousText": False, "temperatureFallback": [0.0]}
        alternate = {**original, "initialPrompt": "wrong", "validation": {"audioCoverage": 1.0}}
        with self.assertRaisesRegex(ValueError, "initialPrompt"):
            validate_provenance(original, alternate, "right")

    def test_provenance_rejects_incomplete_coverage(self) -> None:
        original = {"engine": "mlx-whisper", "engineVersion": "1", "model": "m", "modelRevision": "r", "language": "en", "wordTimestamps": True, "conditionOnPreviousText": False, "temperatureFallback": [0.0]}
        alternate = {**original, "initialPrompt": "right", "validation": {"audioCoverage": 0.5}}
        with self.assertRaisesRegex(ValueError, "incomplete"):
            validate_provenance(original, alternate, "right")

    def test_prompt_matches_golden_transcriber_convention(self) -> None:
        self.assertEqual(initial_prompt({"showName": "Show", "episodeTitle": "Episode"}), "Show. Episode")

    def test_gate_manifest_partitions_do_not_overlap(self) -> None:
        gate = json.loads(Path(DEFAULT_GATE).read_text())
        groups = [set(gate[key]) for key in ("development", "validation", "negativeControls")]
        self.assertFalse(groups[0] & groups[1])
        self.assertFalse(groups[0] & groups[2])
        self.assertFalse(groups[1] & groups[2])
        self.assertEqual(gate["candidateCopy"], "a")

    def test_aggregate_uses_duration_weighted_safety_and_coverage(self) -> None:
        row = {
            "durationSeconds": 3600.0,
            "metrics": {
                "allRemovable": {"truePositiveSeconds": 98.0, "predictedAdSeconds": 100.0, "goldenAdSeconds": 120.0, "falsePositiveSeconds": 2.0},
                "dynamic": {"truePositiveSeconds": 80.0, "goldenAdSeconds": 100.0},
                "contentLossSecondsPerListeningHour": 2.0,
            },
        }
        result = aggregate([row])
        self.assertEqual(result["allRemovablePrecision"], 0.98)
        self.assertEqual(result["dynamicRecall"], 0.8)
        self.assertEqual(result["contentLossSecondsPerListeningHour"], 2.0)


if __name__ == "__main__":
    unittest.main()
