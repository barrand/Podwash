# Cloud Gemini ad detection

PodWash transcribes audio locally with Whisper. Only the timed transcript text is sent to `POST /v1/ad-spans`; raw audio is never uploaded.

## Deployment configuration

1. Create a Firebase project, enable Anonymous Auth and App Check (App Attest for release, Debug provider for development), then add its `GoogleService-Info.plist` to the PodWash target. The plist is intentionally not committed.
2. Deploy `backend/` to Cloud Run with a service account permitted to read `GEMINI_API_KEY` and `TRANSCRIPT_HMAC_KEY` from Secret Manager, and configure Firestore TTL on `ad_span_results.expires_at`.
3. Add `PodWashCloudAdEndpoint` to the app target's generated Info.plist, set to the Cloud Run base URL. Configure Cloud Run to require the Firebase-verified gateway, a billing alert, and an outer shared rate limit (Cloud Armor or equivalent).
4. Keep `AD_DETECTION_ENABLED=true`; set it to `false` to immediately disable requests. The app then leaves ad spans unscheduled and never uses a local-detection fallback.

Successful results are retained for 180 days. Results are keyed by an HMAC of the transcript plus the server-owned model, prompt, and schema versions. Updating any of those versions deliberately reprocesses an episode.
