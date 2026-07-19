#!/usr/bin/env python3
"""Tests for the local ad-golden review store."""

from __future__ import annotations

import json
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from http import HTTPStatus
from pathlib import Path

from Tools.AdGoldenReviewer.server import (
    ReviewError,
    ReviewStore,
    atomic_json,
    file_sha256,
)


class ReviewStoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        root = Path(self.temporary.name)
        self.workdir = root / "work"
        self.golden_dir = root / "goldens"
        self.episode_dir = self.workdir / "cougar-sports"
        self.episode_dir.mkdir(parents=True)

        atomic_json(
            self.episode_dir / "meta.json",
            {
                "showSlug": "cougar-sports",
                "showName": "Cougar Sports",
                "episodeTitle": "Pilot",
            },
        )
        words = [
            {"word": "story", "start": 0.0, "end": 0.4},
            {"word": "buy", "start": 0.4, "end": 0.7},
            {"word": "now", "start": 0.7, "end": 1.0},
            {"word": "maybe", "start": 1.0, "end": 1.4},
            {"word": "sponsor", "start": 1.4, "end": 1.8},
            {"word": "story", "start": 1.8, "end": 2.2},
        ]
        transcript = self.episode_dir / "transcript.json"
        atomic_json(transcript, words)
        transcript_hash = file_sha256(transcript)
        atomic_json(
            self.episode_dir / "transcript_source.json",
            {
                "audioSha256": "audio-hash",
                "transcriptSha256": transcript_hash,
                "engine": "mlx-whisper",
                "engineVersion": "test",
                "model": "large-v3",
                "modelRevision": "revision",
            },
        )
        atomic_json(
            self.episode_dir / "proposal.json",
            {
                "schemaVersion": 1,
                "showSlug": "cougar-sports",
                "transcriptSha256": transcript_hash,
                "spans": [
                    {
                        "id": "proposal-1",
                        "startWord": 1,
                        "endWord": 3,
                        "label": "paid_dai",
                    }
                ],
                "auditItems": [
                    {
                        "id": "audit-1",
                        "startWord": 3,
                        "endWord": 5,
                        "reason": "One model suspected a missed ad.",
                    }
                ],
            },
        )
        self.store = ReviewStore(self.workdir, self.golden_dir)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def payload(self, revision: int = 0) -> dict:
        return {
            "revision": revision,
            "reviewedThroughWord": 4,
            "resumeWord": 2,
            "spans": [
                {
                    "id": "span-1",
                    "startWord": 1,
                    "endWord": 3,
                    "label": "paid_dai",
                    "origin": "ai-proposal",
                }
            ],
            "auditDecisions": {},
            "attested": False,
            "reviewer": "Brian",
        }

    def test_fresh_review_copies_proposal_without_approving_it(self) -> None:
        episode = self.store.load_episode("cougar-sports")

        self.assertEqual(episode["review"]["status"], "in_review")
        self.assertEqual(episode["review"]["revision"], 0)
        self.assertEqual(episode["review"]["spans"][0]["proposalId"], "proposal-1")
        self.assertFalse((self.episode_dir / "review.json").exists())
        self.assertFalse((self.golden_dir / "cougar-sports.json").exists())

    def test_save_is_atomic_and_rejects_stale_revision(self) -> None:
        saved = self.store.save_review("cougar-sports", self.payload())

        self.assertEqual(saved["revision"], 1)
        self.assertTrue((self.episode_dir / "review.json").exists())
        with self.assertRaises(ReviewError) as raised:
            self.store.save_review("cougar-sports", self.payload())
        self.assertEqual(raised.exception.status, HTTPStatus.CONFLICT)

    def test_simultaneous_tabs_cannot_both_save_same_revision(self) -> None:
        def attempt() -> str:
            try:
                self.store.save_review("cougar-sports", self.payload())
                return "saved"
            except ReviewError as error:
                return f"error-{error.status}"

        with ThreadPoolExecutor(max_workers=2) as pool:
            outcomes = sorted(pool.map(lambda _: attempt(), range(2)))

        self.assertEqual(outcomes, [f"error-{HTTPStatus.CONFLICT}", "saved"])

    def test_overlapping_spans_are_rejected(self) -> None:
        payload = self.payload()
        payload["spans"].append(
            {
                "id": "span-2",
                "startWord": 2,
                "endWord": 4,
                "label": "paid_host_read",
            }
        )

        with self.assertRaisesRegex(ReviewError, "overlap"):
            self.store.save_review("cougar-sports", payload)

    def test_stale_transcript_hash_blocks_review(self) -> None:
        transcript = self.episode_dir / "transcript.json"
        words = json.loads(transcript.read_text())
        words.append({"word": "changed", "start": 2.2, "end": 2.5})
        atomic_json(transcript, words)

        with self.assertRaisesRegex(ReviewError, "provenance hash does not match"):
            self.store.load_episode("cougar-sports")

    def test_changed_proposal_blocks_saved_review(self) -> None:
        self.store.save_review("cougar-sports", self.payload())
        proposal = self.episode_dir / "proposal.json"
        data = json.loads(proposal.read_text())
        data["auditItems"][0]["reason"] = "Changed after review began."
        atomic_json(proposal, data)

        with self.assertRaisesRegex(ReviewError, "saved review is stale"):
            self.store.load_episode("cougar-sports")

    def test_failed_approval_without_attestation_does_not_mutate_review(self) -> None:
        payload = self.payload()
        payload["reviewedThroughWord"] = 6

        with self.assertRaisesRegex(ReviewError, "attestation"):
            self.store.approve("cougar-sports", payload)
        self.assertFalse((self.episode_dir / "review.json").exists())
        self.assertFalse((self.golden_dir / "cougar-sports.json").exists())

    def test_approval_writes_word_exact_human_golden_without_audit_gate(self) -> None:
        payload = self.payload()
        payload["reviewedThroughWord"] = 6
        payload["attested"] = True

        result = self.store.approve("cougar-sports", payload)

        golden = result["golden"]
        self.assertEqual(result["review"]["status"], "approved")
        self.assertEqual(golden["status"], "human-approved")
        self.assertEqual(golden["spans"][0]["startWord"], 1)
        self.assertEqual(golden["spans"][0]["endWord"], 3)
        self.assertEqual(golden["spans"][0]["start"], 0.4)
        self.assertEqual(golden["spans"][0]["end"], 1.0)
        self.assertEqual(golden["review"]["optionalModelNotesCount"], 1)
        self.assertTrue((self.golden_dir / "cougar-sports.json").exists())

    def test_resume_scroll_does_not_invalidate_approved_golden(self) -> None:
        payload = self.payload()
        payload["reviewedThroughWord"] = 6
        payload["auditDecisions"] = {"audit-1": True}
        payload["attested"] = True
        approved = self.store.approve("cougar-sports", payload)["review"]
        approved["resumeWord"] = 4

        saved = self.store.save_review("cougar-sports", approved)

        self.assertEqual(saved["status"], "approved")
        self.assertTrue((self.golden_dir / "cougar-sports.json").exists())

    def test_edit_reopens_and_invalidates_approved_golden(self) -> None:
        payload = self.payload()
        payload["reviewedThroughWord"] = 6
        payload["auditDecisions"] = {"audit-1": True}
        payload["attested"] = True
        approved = self.store.approve("cougar-sports", payload)["review"]
        approved["spans"][0]["label"] = "paid_host_read"

        saved = self.store.save_review("cougar-sports", approved)

        self.assertEqual(saved["status"], "in_review")
        self.assertFalse((self.golden_dir / "cougar-sports.json").exists())


if __name__ == "__main__":
    unittest.main()
