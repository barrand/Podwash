"""Opt-in live TypeSafe/Jev smoke test.

This is intentionally excluded from the normal suite because it calls the
paid provider. Run it explicitly with PODWASH_RUN_LIVE_JEV=1 and
TYPESAFE_API_KEY set.
"""

import asyncio
import os
import re
import unittest

from app.main import (
    AdSpanRequest,
    EpisodeContext,
    MemoryCache,
    Service,
    Sentence,
    TypeSafeJevAPI,
)


VERSIONED_JEV = re.compile(r"^jev-\d+\.\d+\.\d+$")


class RecordingJev:
    def __init__(self, api_key: str) -> None:
        self.client = TypeSafeJevAPI(api_key)
        self.models: list[str] = []

    async def ask(self, payload: dict) -> dict:
        response = await self.client.ask(payload)
        model = response.get("model")
        if isinstance(model, str):
            self.models.append(model)
        return response


@unittest.skipUnless(
    os.environ.get("PODWASH_RUN_LIVE_JEV") == "1" and os.environ.get("TYPESAFE_API_KEY"),
    "set PODWASH_RUN_LIVE_JEV=1 and TYPESAFE_API_KEY to run the live Jev smoke test",
)
class LiveJevSmokeTests(unittest.TestCase):
    def test_realistic_transcript_completes_through_production_pipeline(self) -> None:
        jev = RecordingJev(os.environ["TYPESAFE_API_KEY"])
        service = Service(MemoryCache(), jev, b"live-jev-smoke-test-key")
        request = AdSpanRequest(
            request_id="live-jev-smoke-20261015",
            episode_id="live-jev-smoke-episode",
            episode=EpisodeContext(
                show="The Example Hour",
                title="A Short Conversation About City Parks",
                description="A reported conversation about public spaces and neighborhood planning.",
            ),
            sentences=[
                Sentence(id=0, start=0, end=3, text="Today we are talking about how cities make room for parks."),
                Sentence(id=1, start=3, end=7, text="Our guest is urban planner Maya Chen, who studies neighborhood design."),
                Sentence(id=2, start=7, end=11, text="We will come back to the question of who gets access to green space."),
                Sentence(id=3, start=11, end=14, text="This episode is supported by Northstar Coffee."),
                Sentence(id=4, start=14, end=19, text="Northstar makes small batch coffee delivered to your door every month."),
                Sentence(id=5, start=19, end=23, text="Go to northstar.example slash parks for twenty percent off your first order."),
                Sentence(id=6, start=23, end=27, text="That is northstar.example slash parks, and thanks for supporting the show."),
                Sentence(id=7, start=27, end=31, text="Now, back to Maya and the history of public playgrounds."),
                Sentence(id=8, start=31, end=35, text="In the nineteen seventies, the city converted several vacant lots."),
                Sentence(id=9, start=35, end=39, text="The decision looked simple on paper, but residents disagreed about the locations."),
                Sentence(id=10, start=39, end=43, text="Those disagreements shaped the parks that exist today."),
                Sentence(id=11, start=43, end=47, text="After the break, we will hear from a parent who led one of those campaigns."),
            ],
        )

        result = asyncio.run(service.detect(request))

        self.assertEqual(result.status, "complete")
        self.assertEqual(result.schema_version, 2)
        self.assertEqual(result.pipeline_version, "jev-1.13.0:typed-blocks-v7.1:2")
        self.assertGreaterEqual(len(jev.models), 1)
        self.assertTrue(all(VERSIONED_JEV.fullmatch(model) for model in jev.models), jev.models)
        self.assertTrue(all(span.start_sentence_id <= span.end_sentence_id for span in result.segments))


if __name__ == "__main__":
    unittest.main()
