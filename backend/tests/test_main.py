import asyncio
import unittest

from app.main import AdSpanRequest, MemoryCache, Service, Sentence, chunks_for, normalize_spans


class FakeGemini:
    def __init__(self, tokens=10): self.tokens, self.calls = tokens, 0
    async def count_tokens(self, prompt): return self.tokens
    async def classify(self, prompt):
        self.calls += 1
        return [{"start_sentence_id": 1, "end_sentence_id": 2}]


class ServiceTests(unittest.TestCase):
    def request(self):
        return AdSpanRequest(request_id="r" * 16, episode_id="episode", sentences=[Sentence(id=1, start=0, end=1, text="ad"), Sentence(id=2, start=1, end=2, text="copy")])

    def test_retry_uses_versioned_cache(self):
        gemini = FakeGemini()
        service = Service(MemoryCache(), gemini, b"key")
        first = asyncio.run(service.detect(self.request()))
        second = asyncio.run(service.detect(self.request()))
        self.assertFalse(first.cached)
        self.assertTrue(second.cached)
        self.assertEqual(gemini.calls, 1)

    def test_status_returns_server_owned_completed_job(self):
        gemini = FakeGemini()
        service = Service(MemoryCache(), gemini, b"key")
        result = asyncio.run(service.detect(self.request()))

        status = asyncio.run(service.status(result.job_id))

        self.assertEqual(status.job_id, result.job_id)
        self.assertEqual(status.status, "complete")
        self.assertTrue(status.cached)

    def test_invalid_model_span_is_rejected(self):
        class BadGemini(FakeGemini):
            async def classify(self, prompt): return [{"start_sentence_id": 99, "end_sentence_id": 99}]
        with self.assertRaises(ValueError):
            asyncio.run(Service(MemoryCache(), BadGemini(), b"key").detect(self.request()))

    def test_oversized_transcript_chunks_and_merges_overlap(self):
        sentences = [Sentence(id=index, start=float(index * 100), end=float(index * 100 + 10), text="words") for index in range(8)]
        chunks = chunks_for(sentences, token_count=500_000)
        self.assertGreater(len(chunks), 1)
        self.assertEqual(
            {sentence.id for sentence in sentences},
            {sentence.id for chunk in chunks for sentence in chunk},
        )
        spans = normalize_spans(
            [{"start_sentence_id": 1, "end_sentence_id": 3}, {"start_sentence_id": 3, "end_sentence_id": 5}],
            sentences,
        )
        self.assertEqual([(span.start_sentence_id, span.end_sentence_id) for span in spans], [(1, 5)])
