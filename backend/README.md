# PodWash Cloud Run gateway

Deploy this service only after configuring a Firebase project with App Check and Anonymous Auth, a Firestore database with TTL enabled on `ad_span_results_v2.expires_at`, and Secret Manager secrets `TYPESAFE_API_KEY` and `TRANSCRIPT_HMAC_KEY`.

The service accepts schema-v2 timed transcript sentences and bounded episode context at `POST /v1/ad-spans`; it never accepts audio. It runs the pinned Jev V7.1 typed pipeline and returns all typed interruption segments for local preset filtering. Production must set `PODWASH_AUTH_BYPASS` to false or omit it. It emits only model/pipeline, counts, latency, usage/cost, cache status, and stable error categories—never transcript or RSS text. Configure Cloud Armor (or an equivalent shared rate limit) and a billing alert; the in-process limit is a secondary guard. Set `AD_DETECTION_ENABLED=false` for the kill switch.

For local tests: `PYTHONPATH=backend python3 -m unittest backend.tests.test_main`.
