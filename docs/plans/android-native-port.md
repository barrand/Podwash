# Native Android Port Plan

**Status:** Planning only. Creating this document does not authorize Android
implementation, Firebase changes, Play Console setup, or deployment.

## Summary

Build a native Android version of PodWash in Kotlin with Android-specific UI
while preserving the current iOS functionality, privacy model, backend behavior,
and product terminology.

The Android app will live in the existing PodWash monorepo. Swift and Kotlin
implementations remain separate; specifications, fixtures, backend contracts,
evaluation data, and documentation are shared.

### Locked decisions

- Native Kotlin with Jetpack Compose and Material 3.
- Android-native UI carrying the PodWash brand; no pixel-for-pixel iOS copy.
- No Kotlin Multiplatform.
- Existing monorepo, backend, Cloud Run API, privacy/support site, and evaluation
  corpus.
- No accounts, synchronization, or iOS-to-Android data migration for v1.
- Podcast audio must never be uploaded; transcription remains strictly
  on-device.
- English-only transcription, matching current iOS.
- Public launch requires complete user-facing iOS parity plus Android Auto.
- Phones and adaptive tablet layouts; no TV, Wear OS, or Automotive OS APK.
- Android Auto tested through the Desktop Head Unit.
- Initial Android release is free with all functionality unlocked.
- iOS receives bug fixes only while Android catches up.
- Strict tests-first workflow with automated milestone gates.
- Play Internal Testing used from the first installable milestone.
- Free CI/emulator tooling plus one physical Android benchmark phone.
- Initial Play availability limited to the benchmarked device family/specification
  tier.
- ASR qualification: a 60-minute episode completes in 15 minutes or less.
- ASR model storage limit: 200 MB.
- Shared specifications and goldens—not incidental iOS behavior—are
  authoritative.

## Architecture and shared contracts

### Repository structure

```text
PodWash/
├── android/
│   ├── app/                 # Compose application and navigation
│   ├── core/                # Models, repositories, persistence, networking
│   ├── playback/            # Media3 service and interval playback
│   ├── analysis/            # ASR, matching, caches, preparation workers
│   └── build.gradle.kts
├── PodWash/                 # Existing native Swift/iOS project
├── backend/                 # Existing Cloud Run service
├── contracts/               # Canonical schemas and cross-platform goldens
├── eval/                    # Existing ad-detection corpus
├── docs/
└── scripts/
```

No platform imports are allowed in `android/core` domain logic. Android framework
behavior stays in adapters so matching, queue rules, transcript classification,
and state machines run as fast JVM tests.

### Android stack

- Jetpack Compose, Material 3, Navigation Compose, and adaptive layouts.
- Coroutines and `Flow` for asynchronous state.
- Hilt for dependency injection and deterministic test replacement.
- Room for subscriptions, episode state, queue, positions, and analysis-job
  metadata.
- DataStore for settings, consent, word profiles, playback defaults, and model
  state.
- Files for downloads, transcripts, interval artifacts, and the ASR model.
- Media3 ExoPlayer inside a `MediaLibraryService` for background playback, system
  controls, Bluetooth, and Android Auto.
- WorkManager foreground workers for durable downloads and episode analysis.
- Retrofit/OkHttp with Kotlin serialization for iTunes and Cloud Run JSON.
- Platform XML pull parsing for RSS.
- Coil for artwork.
- Firebase Anonymous Auth, App Check with Play Integrity, and Crashlytics.

Media3 explicitly supports background media sessions and external controllers
such as Android Auto through a service-hosted player: [Android Media3 background
playback](https://developer.android.com/media/media3/session/background-playback).

### Canonical cross-platform contracts

Create versioned, machine-readable fixtures for:

- `TimedWord`: `word`, `start`, and `end`.
- `CensorInterval`: `start`, `end`, `action`, and `source`.
- Word normalization, exact matching, padding, midpoint expansion, and merge
  behavior.
- Transcript display classification and ad-span highlighting.
- RSS parsing inputs and expected podcast/episode models.
- `POST /v1/ad-spans` request and response bodies.
- `GET /v1/ad-spans/{job_id}` polling responses and failures.
- Consent and cloud-disabled behavior.
- Queue, resume, played-state, and smart-order scenarios.

Both Swift and Kotlin test suites must consume or validate the same canonical
fixtures. A contract change must update the specification, canonical fixture, iOS
test, Android test, and backend test atomically.

No backend route or payload change is planned. The Android client registers as
another Firebase app and sends Android Firebase Auth and App Check tokens to the
existing generic verification path.

## Delivery phases

### Phase 0 — Freeze the target and establish contracts

- Record the exact physical Android phone model, OS version, RAM, chipset, and
  free storage.
- Freeze new iOS feature development; bug fixes and contract corrections remain
  allowed.
- Create a checklist of every current user-visible iOS behavior, including
  settings and diagnostics.
- Establish `contracts/` as the canonical machine-readable behavior source.
- Add backend schema/contract tests without changing production behavior.
- Define Android verification tiers and evidence format analogous to
  `scripts/verify.sh`.

**Exit gate:** approved parity matrix, canonical contract suite, exact
benchmark-device record, and no unresolved interpretation of “feature parity.”

### Phase 1 — Feasibility cruxes

Build disposable technical spikes before production UI or persistence.

#### On-device ASR

Benchmark at least:

- `whisper.cpp` with a quantized English tiny model.
- One maintained ONNX-based Android alternative capable of word timestamps.

A candidate passes only if it:

- Uploads no audio.
- Uses no proprietary cloud dependency.
- Stays at or below 200 MB of model storage.
- Processes a 60-minute fixture in no more than 15 minutes on the benchmark
  phone.
- Produces no more than two word errors on the existing pangram fixture.
- Keeps maximum word-boundary drift within ±200 ms.
- Produces full-pipeline intervals within ±200 ms of the existing golden.
- Completes with the screen off through an Android foreground worker.
- Survives cancellation, retry, low-storage failure, and process recreation
  without corrupting artifacts.

If multiple candidates pass, choose the fastest median result across three cold
runs. If results are within 10%, choose the smaller and simpler maintained
integration.

Bundle the model only if its compressed artifact is at most 100 MB and the
complete base app remains at most 150 MB. Otherwise, download it when cleaning is
first enabled, verify its checksum, and support resumable replacement.

#### Precise playback

Prototype Media3 interval playback using the player's injectable audio-processing
pipeline.

It must prove:

- Mute-window interior RMS below `0.01`.
- Unmuted fixture RMS above `0.25`.
- Twenty-millisecond fades within ±10 ms.
- No adjacent-sample discontinuity above `0.05`.
- Skip landing between interval end minus 100 ms and interval end.
- Correct behavior after seeking, changing speed, pausing, losing audio focus,
  reconnecting Bluetooth, backgrounding, and restoring the process.
- Original podcast audio remains unmodified.

#### Background and Android Auto

- Prove a `MediaLibraryService` can expose fixture library, queue, metadata, and
  transport controls to the Desktop Head Unit.
- Prove download and analysis workers behave under screen-off, network loss,
  cancellation, and process death.

**Exit gate:** all crux thresholds pass on the benchmark phone. If ASR or precise
playback fails, stop the port and revisit product constraints in a new decision
document.

### Phase 2 — Android foundation and automated pipeline

- Create the Kotlin/Compose project under `android/`.
- Use application ID `com.barrandfarm.podwash`.
- Set `minSdk` to Android 12/API 31, support `arm64-v8a`, and target the latest
  Play-required stable SDK at implementation time.
- Establish modules and dependency injection.
- Add debug, test, internal, and release configurations.
- Add deterministic fixture injection without production code paths reading live
  test data.
- Add `scripts/verify-android.sh` with focused, unit, UI, and release tiers.
- Add path-filtered CI:
  - `android/**` runs Android checks.
  - `PodWash/**` runs iOS checks.
  - `contracts/**` and `backend/**` run both clients' contract suites plus backend
    tests.
- Extend the repository's test-isolation enforcement to Android app and test
  sources.
- Produce a signed Play Internal Testing build with Firebase debug App Check.

**Exit gate:** a clean clone builds, fast tests run on every change, emulator
tests publish evidence, and an internal build installs on the physical phone.

### Phase 3 — Normal podcast player

Build a complete non-cleaning vertical slice first:

- Material 3 navigation for Library, Queue, Discover, and Settings.
- iTunes discovery and search.
- RSS parsing, subscription, refresh, and unsubscribe.
- Room persistence for podcasts, episodes, queue, positions, and played state.
- Streaming and offline downloads.
- Mini player and full player.
- Play, pause, seek, forward/back, speed, sleep timer, and resume.
- Background playback, media notification, lock-screen controls, audio focus,
  Bluetooth controls, and playback resumption.
- Queue editing, auto-advance, and now-playing restoration.
- Adaptive phone and tablet layouts.

**Exit gate:** a user can discover, subscribe, stream, download, queue, play,
background, terminate, relaunch, and resume without any cleaning feature enabled.

### Phase 4 — Local transcription and profanity handling

- Productionize the Phase 1 ASR engine and model manager.
- Implement durable analysis jobs and visible preparation progress.
- Port transcript and interval caches with version/fingerprint invalidation.
- Port canonical word profiles, categories, custom words, and defaults.
- Port matching, padding, merging, and interval building from shared contracts.
- Implement profanity mute and skip.
- Implement silence, beep, and quack overlay modes.
- Preserve schedules through seeks, speed changes, interruption, and process
  restoration.
- Add transcript viewing, follow behavior, listened classification, timestamps,
  and progress indicators.
- Match download-before-clean behavior and cache deletion semantics.

**Exit gate:** every shared matching golden passes, audio thresholds pass on
emulator and phone, and the complete profanity flow works offline after model
installation.

### Phase 5 — Cloud ad detection and skip experience

- Register the Android Firebase app in the existing Firebase project.
- Configure Anonymous Auth and Play Integrity App Check.
- Reproduce explicit transcript-sharing consent and withdrawal.
- Send only timed transcript sentences to the existing Cloud Run API.
- Implement idempotent submission, polling, bounded backoff, and existing error
  categories.
- Preserve the backend kill switch and rate-limit behavior.
- Port ad-span caching, analysis timeline, yellow ad bands, transcript
  highlighting, skipped-duration feedback, and replay override.
- Confirm declined consent leaves core playback and profanity handling
  functional.

**Exit gate:** Android requests match canonical JSON, production App Check
succeeds from Play Internal Testing, no podcast audio leaves the phone, and
consent acceptance/decline/withdrawal flows pass automation.

### Phase 6 — Remaining parity and Android Auto

- Close every remaining parity-matrix item, including smart ordering, preparation
  shelf, warm planning, settings, diagnostics, privacy/support links, empty/error
  states, and interruption handling.
- Complete polished Material 3 phone and tablet layouts.
- Expose Library, Queue, recent/resumable episodes, metadata, and supported
  controls through `MediaLibraryService`.
- Validate Android Auto navigation and controls with the Desktop Head Unit.
- Complete TalkBack semantics, font scaling, contrast, touch targets,
  keyboard/focus behavior, and landscape layouts.
- Add deterministic screenshot tests for key phone and tablet states.

**Exit gate:** no unresolved user-visible parity gaps, all accessibility tests
pass, and the repeatable DHU checklist passes.

### Phase 7 — Release hardening

- Run release/minified builds with Crashlytics symbol/mapping upload.
- Verify migration, corrupt-cache recovery, low storage, offline mode, network
  changes, process death, rotation, audio focus, phone calls, Bluetooth, and
  model-update recovery.
- Run an emulator matrix:
  - API 31 phone.
  - Latest stable API phone.
  - Latest stable API tablet.
  - One foldable layout profile for adaptive-layout regression only.
- Run the automated physical-phone benchmark and functional suite.
- Run backend tests against staging and a bounded production smoke request.
- Complete Google Play Data Safety, privacy policy updates, content rating,
  screenshots, signing, Android Auto declaration, and model/library license
  review.
- Publish to Play Internal Testing, then closed testing, then a staged public
  rollout.
- Restrict initial public device availability to the benchmarked
  family/specification tier; expand only when another physical device passes the
  identical benchmark artifact.

**Exit gate:** full unfiltered Android suite green with no unexplained skips,
physical benchmark evidence attached, internal/closed feedback resolved, and the
release parity checklist fully complete.

## Test strategy

Use the lowest reliable test layer for each behavior, following Android's
recommended testing pyramid: [Android testing
strategy](https://developer.android.com/training/testing/fundamentals/strategies).

### Every change

- Kotlin/JVM tests for matching, intervals, state machines, repositories, queue
  logic, transcript classification, request mapping, and errors.
- Backend unit/contract tests when shared API files change.
- Static analysis, formatting check, dependency verification, and release
  compilation for affected modules.

### Every completed vertical slice

- Room, DataStore, WorkManager, download, file-cache, and Media3 component tests.
- Compose screen behavior and navigation tests using fake repositories.
- Shared cross-platform contract tests.
- No live internet, Firebase, podcast feed, or model download in ordinary UI
  tests.

### Nightly and milestone gates

- Full emulator suite with deterministic fixture launch modes.
- Compose screenshot tests for phone/tablet layouts.
- Accessibility semantics and large-font checks.
- Media service, notification, audio focus, and process-recreation tests.
- ASR/full-pipeline slow tests when the model is available.

### Physical release gate

- ASR speed, accuracy, memory, thermal result, and artifact integrity.
- Real playback mute/skip/overlay behavior.
- Screen-off analysis and downloads.
- Bluetooth and interruption smoke tests.
- Play-installed Firebase Auth and App Check.
- DHU Android Auto smoke test.

Manual listening and DHU inspection supplement automation but never replace an
automatable assertion.

## Assumptions and boundaries

- The exact benchmark phone must be recorded before Phase 1 begins.
- No Android implementation starts merely because this document is committed.
- The server remains shared and unchanged unless Android contract tests expose a
  platform-neutral defect.
- No modified podcast audio is created, stored, uploaded, or redistributed.
- No cloud transcription fallback is added.
- No cross-device sync, user account, Play Billing, casting, TV, Wear OS, or
  dedicated Automotive OS app is included.
- New iOS product features remain frozen until Android reaches public parity.
- Model and native-library licenses must permit Google Play redistribution before
  an engine is selected.
- Firebase App Check for the custom backend will use Play Integrity as documented
  by Firebase: [Play Integrity App
  Check](https://firebase.google.com/docs/app-check/android/play-integrity-provider)
  and [custom backend
  protection](https://firebase.google.com/docs/app-check/android/custom-resource).
