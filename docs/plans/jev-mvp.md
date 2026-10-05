# Jev-only interruption skipping MVP

**Status:** implemented locally; deployment and release verification remain
**Decision:** ship Jev V7.1 as evaluated; do not run another model-selection
experiment before implementation.

## Product contract

PodWash ships three listener presets backed only by Jev:

| Preset | Removes | Release status |
| --- | --- | --- |
| **Skip obvious interruptions** | Paid ads, host reads, DAI, underwriting, attached legal copy, and commercial CTAs. | Default |
| **Skip more interruptions** | Skip obvious plus cross-show and publisher promos and membership/support appeals. | **Experimental** |
| **Skip most interruptions** | Skip more plus engagement requests, production credits, network IDs, and routine sign-offs. | **Experimental** |

The preset defaults to **Skip obvious**, but cloud transcript processing and
automatic skipping remain off until the listener explicitly consents and
enables them. Skip more and Skip most are functional in the App Store build and
remain inside Settings with persistent Experimental badges and caution text.

Previews, recaps, substantive reporting or conversation, substantial feed-drop
content, editorially framed archival commercials, and unsafe mixed sentences
are always kept. Off-topic subject matter alone is never removable.

Gemini is not a production dependency. The app and backend contain no Gemini
client, model, API key, endpoint, cache identity, or current privacy claim.
Historical evaluation scripts, reports, and plans remain as evidence.

## Frozen Jev pipeline

Production must implement V7.1 exactly as evaluated:

1. Build sentence rows with punctuation, an 18-second inter-word gap boundary,
   an 80-word cap, and an 18-second maximum sentence duration.
2. Run the V7 broad-role prompt in windows of 12 target sentences with seven
   context sentences on each side.
3. Treat a sentence as a candidate when Jev selects `removable_candidate` or
   assigns it probability at least **0.30**.
4. Join consecutive candidates into blocks. Apply the unchanged V7.1 complete-
   block tier prompt and recursively bisect `mixed_split` blocks until every
   emitted block is resolved or is a protected/unsafe singleton.
5. Run the unchanged V7.1 block reason prompt for resolved removable blocks.
   Merge adjacent spans only when their tier and complete reason set match.

Pin `jev-1.13.0`, the prompts, criteria, thresholds, recursion, and context
shape. Include show title, show description, episode title, and episode
description. Treat transcript and RSS fields as untrusted data. Strategy 8 is
not part of the runtime.

Production fixture tests must replay frozen V7.1 responses and prove that the
backend produces identical candidate, tier, reason, and span decisions to the
evaluator before deployment.

## Backend contract and execution

Keep the authenticated `POST /v1/ad-spans` and `GET /v1/ad-spans/{job_id}`
routes, but coordinate the app and new Jev service on schema version 2.

The request adds bounded episode context beside the existing ordered timed
sentences:

```json
{
  "request_id": "stable attempt id",
  "episode_id": "library episode id",
  "episode": {
    "show": "Show title",
    "show_description": "Plain bounded text",
    "title": "Episode title",
    "description": "Plain bounded text"
  },
  "sentences": [{"id": 0, "start": 0.0, "end": 4.2, "text": "..."}]
}
```

The completed response returns all typed segments without applying a listener
preset:

```json
{
  "status": "complete",
  "schema_version": 2,
  "pipeline_version": "jev-1.13.0:typed-blocks-v7.1:2",
  "segments": [{
    "start_sentence_id": 42,
    "end_sentence_id": 48,
    "start": 632.56,
    "end": 674.20,
    "reasons": ["paid_ad"]
  }]
}
```

Supported reasons are `paid_ad`, `underwriting`, `cross_show_promo`,
`publisher_promo`, `membership_appeal`, `engagement_request`,
`production_credit`, `network_id`, and `signoff`. Unknown reasons, unknown
schema versions, invalid sentence IDs, non-finite timestamps, reversed spans,
or malformed Jev answers invalidate the complete response. Never return a
partial result to playback.

Use an asynchronous HTTP client for TypeSafe and `TYPESAFE_API_KEY` from Secret
Manager. Remove `google-genai` and `GEMINI_API_KEY`. Bound each episode:

- no Jev request above 20,000 estimated tokens;
- no more than 600 Jev subrequests;
- no more than $0.10 projected TypeSafe input cost;
- at most four Jev calls in flight;
- 15-second per-call timeout, with at most two retries for 429 and transient
  5xx/network failures; and
- a 50-second overall analysis deadline.

Any limit, terminal provider error, timeout, or invalid response abandons the
job and stores no completed typed result. PodWash may continue with profanity
cleaning or original playback; there is no Gemini or heuristic fallback.

Cache completed results for the existing 180-day TTL under a transcript HMAC
and `jev-1.13.0:typed-blocks-v7.1:2`. Give `processing` claims a ten-minute
lease. An identical request may reclaim an expired lease so a killed Cloud Run
instance cannot leave an episode processing for months. Preserve Firebase Auth,
App Check, Cloud Armor/shared rate limits, billing alerts, transcript-free logs,
and `AD_DETECTION_ENABLED` as the kill switch.

Log only model/pipeline version, sentence and subrequest counts, candidate and
output counts, latency, reported usage/cost, cache status, and stable error
categories. Never log transcript or RSS text.

## iOS typed storage and playback

Add `SkipPreset` (`obvious`, `more`, `most`) to `SettingsStore`; persist it and
default missing values to `obvious`. Keep consent and the master Skip ads state
separate from the preset.

Replace untyped `ContentSegment` storage with schema-v2 typed segments containing
timestamps and a reason set. `EpisodeAnalysisArtifactStore` is the canonical
cloud-analysis source and records schema and pipeline versions. Reject artifacts
whose schema or pipeline differs from the current Jev version. Remove/version
out the legacy migration that converts old untyped intervals into ad artifacts.

`IntervalCache` remains a derived playback cache. Its fingerprint includes the
Jev typed revision and selected preset. Old `cloud-gemini-v1` records must miss.
Filtering rules are local and stable:

- Obvious enables `paid_ad` and `underwriting`.
- More enables Obvious plus `cross_show_promo`, `publisher_promo`, and
  `membership_appeal`.
- Most enables every supported reason.
- A multi-reason segment plays as removable when any reason is enabled.

Changing presets loads the current typed artifact, recomputes the ad intervals,
preserves profanity intervals/actions, updates the active playback schedule,
transcript rows, and timeline bands, and refreshes prepared episodes. It must
not download, retranscribe, or call the backend. If no current artifact exists,
the selection applies to the episode's next normal analysis.

Update the cloud client to use the evaluated 18-second sentence cap, attach the
existing `SegmentationContext`, decode only schema v2, and use the new Jev Cloud
Run endpoint. Preserve consent, Firebase credentials, polling, retry UI, skip/
mute action, Play with ads, and original-audio behavior.

## Settings experience

Keep the master Skip ads and cloud-consent behavior. Add one secondary Settings
row that opens “Choose what PodWash skips”:

- **Skip obvious interruptions** — Default; “Paid ads and sponsor messages.”
- **Skip more interruptions** — Experimental; “Also promos and support
  messages. May remove material you would prefer to hear.”
- **Skip most interruptions** — Experimental; “Also requests, credits, network
  IDs, and sign-offs. May remove material you would prefer to hear.”

Do not show the preset picker during onboarding, add category switches, or ask
for an extra confirmation every time an experimental preset is selected. Add
VoiceOver labels/values for the selected preset, Default label, Experimental
badges, and warnings.

## Delivery sequence

1. Extract/freeze production V7.1 policy code and fixture parity tests.
2. Implement schema-v2 Jev backend, budgets, processing leases, cache version,
   provider client, and backend tests.
3. Implement typed iOS models, canonical artifact storage, cache invalidation,
   local preset projection, and schedule recomposition.
4. Implement and test the Settings picker and Experimental presentation.
5. Deploy a new `podwash-jev` Cloud Run service with `TYPESAFE_API_KEY`; point a
   TestFlight build to it without altering the old service during verification.
6. Complete contract, release, device, consent, failure, and kill-switch tests.
7. Remove the Gemini secret, dependency, endpoint fallback, current docs/privacy
   wording, and old Cloud Run service before App Store submission.
8. Increment the build, run the full release gate, archive/validate, complete
   TestFlight, privacy answers, review notes, and submit.

### Implementation checkpoint — 2026-10-04

Steps 1–4 are implemented in the repository. The app and backend now use the
schema-v2 Jev-only contract; Obvious is the default; More and Most remain
functional and visibly Experimental; typed artifacts are projected locally on
preset changes; and the current production app/configuration/privacy surfaces
no longer reference Gemini. Offline backend, iOS contract, cache, artifact,
settings, and projection tests pass.

Steps 5–8 are release operations, not local implementation. The next gate is to
deploy `podwash-jev` with its TypeSafe secret and existing Firebase/App Check
controls, then point a TestFlight build at the verified service. Do not remove
the old deployed service or secret until that TestFlight smoke test passes.

## Acceptance gates

- Frozen fixtures prove production decisions match V7.1.
- Backend tests cover windowing, thresholds, recursion, reasons, normalization,
  budgets, retries, expired-lease recovery, auth, caching, and kill switch.
- iOS tests cover Obvious default/persistence, all preset mappings, multi-reason
  spans, artifact/cache invalidation, zero-network preset changes, active
  playback rescheduling, consent withdrawal, retries, and cached restoration.
- A contract test carries one schema-v2 response through decoding, persistence,
  and all three playback projections.
- UI tests cover all choices, badges, warnings, selection, and accessibility.
- TestFlight verifies real beginning/middle/end ads, live preset changes, offline
  cached playback, provider failure, expired processing recovery, Play with ads,
  consent decline/withdrawal, and server disablement.
- Production contains no Gemini runtime, key, dependency, endpoint, cache token,
  or current privacy claim. Historical evaluation material is exempt.
- TypeSafe/Jev data handling, privacy copy, App Store privacy answers, support
  process, billing alerts, operational owner, and rollback steps are confirmed
  before submission.

## Explicitly deferred

- Improving V7.1 or adding a second confirmation pass.
- Using the V8 scout in production.
- Removing the Experimental status from More or Most.
- Per-category controls, audio-based boundary detection, and Gemini fallback.
