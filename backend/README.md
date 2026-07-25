# PodWash Cloud Run gateway

Deploy this service only after configuring a Firebase project with App Check and Anonymous Auth, a Firestore database with TTL enabled on `ad_span_results.expires_at`, and Secret Manager secrets `GEMINI_API_KEY` and `TRANSCRIPT_HMAC_KEY`.

The service accepts timed transcript sentences at `POST /v1/ad-spans`; it never accepts audio. Production must set `PODWASH_AUTH_BYPASS` to false or omit it. It emits only model/pipeline, sentence-count, and span-count telemetry—never transcript text. Configure Cloud Armor (or an equivalent shared rate limit) and a billing alert; the in-process limit is a secondary guard. Set `AD_DETECTION_ENABLED=false` for the kill switch.

For local tests: `PYTHONPATH=backend python3 -m unittest backend.tests.test_main`.
