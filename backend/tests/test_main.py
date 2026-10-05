import asyncio
import time
import unittest

from app.main import (
    AdSpanRequest,
    Block,
    BROAD_CRITERIA,
    EpisodeContext,
    MemoryCache,
    PIPELINE_VERSION,
    REASONS,
    SCHEMA_VERSION,
    Service,
    Sentence,
    TIER_CRITERIA,
    broad_payload,
    candidate_blocks,
    merge_segments,
    tier_payload,
    ContentSegment,
)


class FakeJev:
    def __init__(self, mixed_once=False):
        self.calls = 0
        self.mixed_once = mixed_once

    async def ask(self, payload):
        self.calls += 1
        answers = {}
        for question_id, question in payload["questions"].items():
            if question_id.endswith("-broad-role"):
                sentence_id = int(question_id.split("-")[1])
                choice = "removable_candidate" if sentence_id in (1, 2) else "editorial_content"
                probabilities = {name: 0.0 for name in BROAD_CRITERIA}
                probabilities[choice] = 1.0
                answers[question_id] = {"type": "choice", "choice": choice, "confidence": 1.0, "probabilities": probabilities}
            elif question_id.endswith("-tier"):
                choice = "mixed_split" if self.mixed_once else "skip_obvious"
                self.mixed_once = False
                probabilities = {name: 0.0 for name in TIER_CRITERIA}
                probabilities[choice] = 1.0
                answers[question_id] = {"type": "choice", "choice": choice, "confidence": 1.0, "probabilities": probabilities}
            elif question_id.endswith("-primary-reason"):
                criteria = question["criteria"]
                choice = next(iter(criteria))
                answers[question_id] = {"type": "choice", "choice": choice, "confidence": 1.0, "probabilities": {name: (1.0 if name == choice else 0.0) for name in criteria}}
            else:
                reason = question_id.rsplit("-also-", 1)[1]
                answers[question_id] = {"type": "noul", "noul": 1.0 if reason == "paid_ad" else 0.0}
        return {"model": "jev-1.13.0", "usage": {"input_tokens": 100, "output_tokens": 0}, "answers": answers}


class ServiceTests(unittest.TestCase):
    def request(self):
        return AdSpanRequest(
            request_id="r" * 16,
            episode_id="episode",
            episode=EpisodeContext(show="Show", title="Episode"),
            sentences=[
                Sentence(id=0, start=0, end=1, text="intro"),
                Sentence(id=1, start=1, end=2, text="ad"),
                Sentence(id=2, start=2, end=3, text="copy"),
                Sentence(id=3, start=3, end=4, text="show"),
            ],
        )

    def test_pipeline_returns_typed_schema_v2_and_reuses_cache(self):
        jev = FakeJev()
        service = Service(MemoryCache(), jev, b"key")
        first = asyncio.run(service.detect(self.request()))
        second = asyncio.run(service.detect(self.request()))
        self.assertEqual(first.schema_version, SCHEMA_VERSION)
        self.assertEqual(first.pipeline_version, PIPELINE_VERSION)
        self.assertEqual([(span.start_sentence_id, span.end_sentence_id, span.reasons) for span in first.segments], [(1, 2, ["paid_ad"])])
        self.assertFalse(first.cached)
        self.assertTrue(second.cached)
        self.assertEqual(jev.calls, 3)

    def test_mixed_block_recurses_before_reasoning(self):
        result = asyncio.run(Service(MemoryCache(), FakeJev(mixed_once=True), b"key").detect(self.request()))
        self.assertEqual([(span.start_sentence_id, span.end_sentence_id) for span in result.segments], [(1, 2)])

    def test_status_returns_completed_job(self):
        service = Service(MemoryCache(), FakeJev(), b"key")
        result = asyncio.run(service.detect(self.request()))
        restored = asyncio.run(service.status(result.job_id))
        self.assertEqual(restored.status, "complete")
        self.assertTrue(restored.cached)

    def test_expired_processing_lease_can_be_reclaimed(self):
        cache = MemoryCache()
        request = self.request()
        service = Service(cache, FakeJev(), b"key")
        key = service.cache_key(request)
        asyncio.run(cache.begin(key, time.time() - 1))
        result = asyncio.run(service.detect(request))
        self.assertEqual(result.status, "complete")

    def test_invalid_response_abandons_without_partial_result(self):
        class BadJev:
            async def ask(self, payload):
                return {"model": "jev-1.13.0", "usage": {"input_tokens": 1, "output_tokens": 0}, "answers": {}}

        cache = MemoryCache()
        service = Service(cache, BadJev(), b"key")
        request = self.request()
        with self.assertRaises(ValueError):
            asyncio.run(service.detect(request))
        self.assertIsNone(asyncio.run(cache.get(service.cache_key(request))))

    def test_candidate_blocks_group_only_adjacent_candidates(self):
        self.assertEqual(candidate_blocks([False, True, True, False, True]), [Block(1, 3), Block(4, 5)])

    def test_merge_requires_matching_reason_set(self):
        spans = [
            ContentSegment(start_sentence_id=1, end_sentence_id=1, start=1, end=2, reasons=["paid_ad"]),
            ContentSegment(start_sentence_id=2, end_sentence_id=2, start=2, end=3, reasons=["paid_ad"]),
            ContentSegment(start_sentence_id=3, end_sentence_id=3, start=3, end=4, reasons=["underwriting"]),
        ]
        merged = merge_segments(spans)
        self.assertEqual([(span.start_sentence_id, span.end_sentence_id) for span in merged], [(1, 2), (3, 3)])

    def test_unknown_reason_is_rejected(self):
        with self.assertRaises(ValueError):
            ContentSegment(start_sentence_id=1, end_sentence_id=1, start=1, end=2, reasons=["mystery"])

    def test_supported_reason_contract_is_frozen(self):
        self.assertEqual(len(REASONS), 9)

    def test_frozen_v71_prompt_text_and_context_shape(self):
        request = self.request()
        broad = broad_payload(request, 0, 4)
        self.assertEqual(
            broad["questions"]["sentence-0-broad-role"]["instructions"]["safety"],
            "Previews, recaps, editorially framed archival ads, and substantive content are always kept. When mixed, choose mixed_boundary.",
        )
        tier = tier_payload(request, Block(1, 3))
        self.assertEqual(
            tier["questions"]["s0001-e0002-tier"]["instructions"]["minimumPreset"],
            "Choose the least aggressive preset that can safely remove every target sentence. If different sentences need different minimum presets, or keep-content is included, choose mixed_split.",
        )
        self.assertEqual(
            [row["role"] for row in tier["state"]["transcript_window"]],
            ["context", "target", "target", "context"],
        )


if __name__ == "__main__":
    unittest.main()
