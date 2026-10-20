# PodWash Cloud Run gateway

Deploy this service only after configuring a Firebase project with App Check and Anonymous Auth, a Firestore database with TTL enabled on `ad_span_results_v2.expires_at`, and Secret Manager secrets `TYPESAFE_API_KEY` and `TRANSCRIPT_HMAC_KEY`.

The service accepts schema-v2 timed transcript sentences and bounded episode context at `POST /v1/ad-spans`; it never accepts audio. It requests the `jev-latest` alias with the V7.1 typed pipeline and returns all typed interruption segments for local preset filtering. It accepts TypeSafe's resolved versioned Jev response while preserving the legacy iOS pipeline response contract. Production must set `PODWASH_AUTH_BYPASS` to false or omit it. It emits only model/pipeline, counts, latency, usage/cost, cache status, and stable error categories—never transcript or RSS text. Configure Cloud Armor (or an equivalent shared rate limit) and a billing alert; the in-process limit is a secondary guard. Set `AD_DETECTION_ENABLED=false` for the kill switch.

For local tests: `PYTHONPATH=backend python3 -m unittest backend.tests.test_main`.

For the opt-in live provider smoke test, set `TYPESAFE_API_KEY` and run `PODWASH_RUN_LIVE_JEV=1 PYTHONPATH=backend python3 -m unittest backend.tests.test_live_jev`. It sends a bounded synthetic podcast transcript through the production Jev pipeline and is intentionally not part of the default test suite because it makes paid provider calls.
