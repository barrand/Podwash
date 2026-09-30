# Release Validation for Post-Candidate Changes

## Purpose

This is the implementation handoff for validating the executable changes made after the 1.0 candidate, principally:

- `3d1bb1d feat: replay played episodes safely`
- `cd9761f feat: refresh feeds and prepare upcoming episodes`

The validation target includes feed refresh, two-choice preparation, played-episode replay, settings migration, the long Library list/mini-player layout, and the audio-session changes that landed in the same commits.

This plan deliberately separates two completion gates:

- **Track A — post-candidate release validation:** prove and, where necessary, repair behavior that is present in the current application.
- **Track B — full automatic-preparation roadmap:** background task scheduling, background URL-session recovery, Wi-Fi/power/thermal gates, automatic-asset ownership, the 1 GB budget, the 2 GB reserve, eviction, and durable stage recovery. These remain governed by `automatic-feed-refresh-and-preparation.md` and are not complete merely because Track A passes.

Do not add skipped or placeholder tests for Track B to the normal green suite. Keep its acceptance items in the roadmap until the corresponding production capability exists.

## Current baseline and known defects

Treat the following as facts at the start of implementation:

1. `WarmPlanner.peekCount` and `warmCap` are both `2`, through `UpcomingSelectionPolicy.readyTarget`.
2. `WarmPlannerTests.testWarmTargetPreparesAtLeastTwoFollowOnEpisodes` is stale: it waits for two warmed episodes and then asserts that the target and warmed set contain four. The targeted test currently fails for that reason.
3. `LibraryUITests.testLastEpisodeInLongListRemainsTappableAboveMiniPlayer` currently passes on the iPhone 17 Pro simulator. Preserve it as a regression test.
4. App launch asks `FeedRefreshCoordinator` to refresh feeds, but foreground activation does not. `AppShellView` currently handles only inactive/background transitions.
5. `AppShellModel` discards `[URL: FeedRefreshResult]`, so it cannot publish refresh progress or partial failure.
6. A newly subscribed feed is not recorded as freshly validated, even though subscription already fetched and parsed it.
7. Feed metadata is stored as one `UserDefaults` dictionary. Concurrent feed tasks each perform a read-modify-write, so one completion can overwrite metadata written by another completion.
8. Refresh timeout and preparation retry timing use real `Task.sleep`, which prevents fast deterministic tests.
9. `WarmPlanner.analyzeWithOneRetry` catches every error, including cancellation, and immediately starts another analysis attempt.
10. `AnalysisJobStore` restores status records, but `WarmPlanner` does not reconcile or resume interrupted jobs on construction.
11. Analysis/cache validity is not tied to the identity of downloaded audio. A new enclosure download can reuse analysis created for older bytes under the same episode ID and settings.
12. The commits listed above contain both app and test changes. Do not repeat that structure: the current CI test-isolation rule rejects any new individual commit that touches both `PodWash/PodWash/` and a test target.

Before changing behavior, run and retain evidence for:

```sh
VERIFY_TIER=2 VERIFY_NO_RETRY=1 scripts/verify.sh \
  -only-testing:PodWashTests/WarmPlannerTests/testWarmTargetPreparesAtLeastTwoFollowOnEpisodes

VERIFY_TIER=2 VERIFY_NO_RETRY=1 scripts/verify.sh \
  -only-testing:PodWashUITests/LibraryUITests/testLastEpisodeInLongListRemainsTappableAboveMiniPlayer
```

The expected initial result is red for the first command and green for the second.

## Non-negotiable test qualities

- No live RSS publisher, iTunes endpoint, cloud service, or real background scheduler.
- No multi-second sleeps in unit or integration tests.
- Retry, freshness, and timeout tests advance a manual clock/sleeper.
- Concurrency tests use explicit barriers or continuations, not polling races.
- Every test owns an isolated Core Data controller, `UserDefaults` suite, download directory, and cache directory.
- No test depends on dictionary or set iteration order.
- UI-test fixture launches must not start live feed refresh or OS background work.
- Filtered runs are development evidence only. Release acceptance requires the unfiltered unit and UI suites with retries disabled.
- New tests must prove externally meaningful state: requests made, metadata stored, rows preserved, work serialized, or user-visible state. Avoid assertions against private implementation counters unless the counter is the behavior under test.

## Required production design and test seams

Implement the dependency seams in app-only commits before adding tests that require them. Keep all types `internal` unless a real product API needs wider visibility. Behavioral repairs such as cancellation handling and audio-revision enforcement come after their red specifications, in Phase 3.

### Feed refresh metadata

Move the private nested metadata type out of `FeedRefreshCoordinator`:

```swift
struct FeedRefreshMetadata: Codable, Equatable, Sendable {
    var lastAttempt: Date?
    var lastSuccess: Date?
    var etag: String?
    var lastModified: String?
    var consecutiveFailures: Int
    var retryAfter: Date?
    var failureCategory: FeedRefreshFailureCategory?
}
```

Add a storage boundary:

```swift
protocol FeedRefreshMetadataStoring: Sendable {
    func metadata(for feedURL: URL) async -> FeedRefreshMetadata
    func save(_ metadata: FeedRefreshMetadata, for feedURL: URL) async
}
```

The production implementation should be an actor backed by `UserDefaults`. Its `save` operation must read the latest stored dictionary and replace only the requested feed entry while actor-isolated. The test implementation should be an in-memory actor. This removes cross-feed lost updates and lets tests inspect behavior without decoding private defaults data.

Add a listener-safe failure category, at minimum: `network`, `timeout`, `malformedFeed`, `identityCollision`, and `persistence`. Do not persist raw URLs or server error bodies as user-facing diagnostics.

### Time and sleeping

Use one small asynchronous timing boundary in both refresh and preparation code:

```swift
protocol AppTiming: Sendable {
    func now() async -> Date
    func sleep(for interval: TimeInterval) async throws
}
```

Provide:

- `SystemAppTiming`, backed by `Date()` and `Task.sleep`.
- `ManualAppTiming`, owned by tests, which records sleepers and resumes them when the test advances time.

Do not retain a separate `now:` method parameter after this seam is installed; all freshness, retry, timestamps, and timeout decisions must use the injected timing source.

As a Phase 3 behavior repair, make cancellation distinct from failure. Before retrying an analyzer operation, explicitly rethrow `CancellationError` and check `Task.isCancelled`. Cancellation must not increment retry count or create `retryAfter`.

`FeedFetching` implementations are required to cooperate with task cancellation. Keep the coordinator timeout race, but use the injected timing source and verify that cancelling the losing fetch actually unwinds the production `URLSession` request. Do not claim a hard timeout for an arbitrary transport that ignores Swift task cancellation.

### Feed catalog boundary

Add the narrow store boundary needed to test coordinator failures without manufacturing a broken Core Data stack:

```swift
protocol FeedRefreshCatalog: Sendable {
    func subscribedFeedURLs() -> [URL]
    func isSubscribed(feedURL: URL) -> Bool
    func mergeRefreshedFeed(_ feed: PodcastFeed, feedURL: URL) throws
}
```

Make `PodcastStore` conform without changing its public behavior. Coordinator tests use a recording implementation that can block a merge or throw a controlled persistence error. Test `PodcastStore.mergeRefreshedFeed` itself against real isolated Core Data; test coordinator error classification through this boundary.

### Refresh composition and observable result

Allow `AppShellModel` to receive a coordinator:

```swift
init(
    ...,
    feedRefreshCoordinator: FeedRefreshCoordinator? = nil
)
```

When omitted, construct the production coordinator with the production store, metadata repository, and timing implementation.

Replace discarded result dictionaries with a value summary:

```swift
struct FeedRefreshSummary: Equatable, Sendable {
    var refreshed: Int
    var notModified: Int
    var skipped: Int
    var failed: Int
    var total: Int
}

enum FeedRefreshViewState: Equatable {
    case idle
    case refreshing
    case complete(FeedRefreshSummary)
    case partialFailure(FeedRefreshSummary)
}
```

`AppShellModel` owns observable `feedRefreshState`. Library and detail refresh actions set `.refreshing`, then `.complete` or `.partialFailure`. A partial failure must keep successful catalog changes and expose “Some shows couldn’t update” plus a Retry action. Do not claim that all shows are current.

Add an explicit model lifecycle command, such as `sceneDidBecomeActive() async`, and call it from `AppShellView` when `scenePhase == .active`. The command requests a non-forced refresh; coordinator freshness decides whether network work is necessary. Keep playback-position flushing on inactive/background.

### Fresh subscription handoff

Add a coordinator operation that records a feed fetch already completed by subscription:

```swift
func recordSuccessfulValidation(
    feedURL: URL,
    validators: FeedValidators?,
    at date: Date? = nil
) async
```

Wire a small callback/service into `DiscoverViewModel` so successful `saveSubscription` records `lastAttempt`, `lastSuccess`, zero failures, no retry deadline, and any received validators. If the subscription fetch path cannot currently surface validators, record success with empty validators and document that conditional validation begins on the next response.

The record must be written only after the subscription database save succeeds.

### Audio identity and analysis validity design

The red specifications in Phase 2 require a stable downloaded-audio revision; implement it during Phase 3. It may be a SHA-256 digest, or a persisted tuple containing normalized source URL, final byte count, and a content-derived digest. A URL alone is not sufficient.

Persist the revision with downloaded audio and include it in the transcript/interval artifact fingerprint. Required behavior:

- Existing local bytes keep their existing valid analysis even if RSS metadata changes.
- Deleting and downloading different bytes produces a different revision.
- Analysis for revision A is never reported ready for revision B.
- Settings changes continue to invalidate only the affected derived artifacts.

Migrate legacy artifacts conservatively: artifacts without a known audio revision are protected but must be revalidated before being used for newly downloaded bytes.

## Test doubles and harnesses

Add reusable doubles under `PodWashTests`:

- `ScriptedFeedFetcher`: an actor keyed by URL with queued `.modified`, `.notModified`, and error responses; records validators and request order.
- `BlockingFeedFetcher`: suspends at a continuation until a test releases it; observes cancellation.
- `FeedConcurrencyRecorder`: records current and maximum in-flight calls.
- `InMemoryFeedRefreshMetadataStore`: actor implementation of the metadata protocol.
- `ManualAppTiming`: advances logical time and resolves registered sleeps deterministically.
- `RecordingEpisodeAnalyzer`: records episode IDs and maximum concurrent analyses.
- `LateCancellingEpisodeAnalyzer`: receives cancellation but deliberately waits on a test barrier before returning, proving replacement work does not overlap it.
- `FixtureFeedBuilder`: constructs feeds with explicit IDs, enclosure URLs, metadata, and order without XML when parser behavior is not under test.
- `RefreshLifecycleHarness`: creates an isolated persistence controller, coordinator, model, settings store, and fixture downloads without triggering live startup work.

Keep HTTP request/response behavior tests separate from coordinator tests. `URLSessionFeedFetcher` tests should use a dedicated `URLProtocol` stub; coordinator tests should inject `FeedFetching` directly.

## Implementation and commit sequence

The sequence is mandatory because `scripts/check-test-isolation.sh` rejects mixed app/test commits.

### Phase 0 — repair the test baseline

Test-only commit:

1. Rename the stale warm target test to `testWarmTargetPreparesExactlyTwoAutomaticEpisodes`.
2. Assert `WarmPlanner.peekCount == 2` and `WarmPlanner.warmCap == 2`.
3. Assert only the first two candidate IDs become automatically warmed.
4. Rename `testWarmCapStopsAtFiveAnalyzedEpisodes` to describe the two-item cap and update its inputs/assertions accordingly.
5. Do not weaken the passing long-list UI test.

Run the full unit suite after this correction. Any additional failures become explicit entries in the coverage ledger before proceeding.

### Phase 1 — add production seams

App-only commit or small series of app-only commits:

1. Add metadata storage and timing abstractions.
2. Refactor `FeedRefreshCoordinator` to use them and eliminate concurrent direct defaults mutation.
3. Add coordinator injection, refresh summary/state, foreground activation, and successful-subscription recording.
4. Add only the injection points needed to observe download identity and analyzer cancellation; do not implement audio-revision enforcement or cancellation retry repairs until their Phase 2 tests are red.

This phase should build cleanly before tests are added. Do not mix opportunistic UI redesign or the unimplemented Track B scheduler into these commits.

### Phase 2 — add red behavioral specifications

Test-only commits. It is acceptable and expected for locally run tests to be red until the corresponding app-only repair commit follows. Do not push an intermediate red branch as a release candidate.

Organize tests by behavior:

#### `FeedFetchingTests`

- Sends `If-None-Match` and `If-Modified-Since` when validators exist.
- Omits conditional headers when validators are absent.
- Maps a 2xx response to `.modified` with body and returned validators.
- Maps 304 to `.notModified` without attempting XML parsing.
- Returns empty received validators when a successful response omits those headers; coordinator coverage verifies that this clears stored values.
- Maps non-2xx/304, non-HTTP, and transport errors to the expected safe failure.
- Cancelling the fetch task cancels the underlying stubbed `URLSession` request and returns promptly.

#### `FeedRefreshCoordinatorTests`

- Empty library performs zero fetches and returns an empty summary.
- First automatic request fetches and records attempt/success.
- A second request at `lastSuccess + 14m59s` is skipped.
- A request at exactly `lastSuccess + 15m` fetches.
- Forced refresh bypasses freshness and retry backoff.
- A forced request joins an already in-flight same-feed request rather than opening another request.
- Concurrent same-feed requests make exactly one transport call and return the same result.
- `refreshAll` never exceeds three simultaneous transport calls.
- Concurrent completions for multiple feeds preserve every feed’s metadata.
- 304 advances `lastSuccess`, resets failures, and leaves catalog rows unchanged.
- Modified success commits the feed before advancing success metadata.
- Malformed XML, collision, and persistence failure preserve the prior catalog and prior `lastSuccess`.
- Missing response validators clear stored validators after successful commit.
- Failure delays are exactly 15 minutes, 1 hour, 6 hours, then remain capped at 6 hours.
- Success after failure resets count and retry deadline.
- Advancing manual time to the timeout returns `.failed`, categorizes timeout, and cancels the fetch.
- Unsubscribing while the fetch is blocked prevents the late result from recreating or changing the removed subscription.
- One failed feed does not cancel successful feeds in the same batch; summary reports partial failure accurately.

Run the same-feed coalescing, three-request bound, and multi-feed metadata tests through at least 25 internal iterations. Keep each iteration deterministic with barriers.

#### `PodcastStoreRefreshTests`

- Updates show and existing-episode metadata in place.
- Inserts new episodes.
- Retains episodes absent from the latest response.
- Preserves playback position, played state, dismissed state, download state, cleaning state, and queue references.
- Rejects duplicate incoming IDs atomically.
- Rejects a cross-feed ID collision without changing either feed.
- Maintains the intended listener-visible episode ordering after merge.
- A changed enclosure URL does not relabel existing local bytes as the new download.
- Downloading replacement bytes invalidates old-audio analysis.
- Persistence save failure changes neither catalog nor successful refresh metadata.

#### `UpcomingSelectionPolicyTests`

Use table-driven value tests covering:

- zero manual entries → first two eligible predictions;
- one manual entry → that entry plus one prediction;
- two or more manual entries → all valid manual entries and zero automatic entries;
- current episode, empty IDs, and duplicates removed;
- prediction duplicates never displace manual order;
- suppressed automatic IDs skipped;
- automatic preparation disabled returns manual entries only;
- Binge and least-recently-heard order is preserved from the supplied predictions;
- output origins are correctly labeled `.manual` and `.automatic`.

#### `WarmPlannerTests`

- Exactly two speculative episodes are prepared.
- Explicit replay and every manual queue entry remain eligible even when there are more than two.
- Manual work runs before automatic work.
- Automatic preparation off starts no speculative download or analysis.
- Smart Autoplay off does not prevent automatic preparation.
- Identical repeated re-aim events do not cancel or restart useful work.
- Re-aim cancellation settles the old analyzer before the replacement starts.
- `CancellationError` causes zero retry and no delayed job.
- A genuine retryable failure retries according to manual time.
- A non-retryable failure reaches `needsAttention` immediately.
- Existing audio is reused for replay, but replay still runs required analysis.
- A completed download is not repeated when analysis is interrupted.
- Loading a persisted job is tested separately from resuming it; do not claim recovery until execution actually continues from the correct stage.

Replace polling and fixed sleeps in the existing warm-planner tests where the new barriers/manual timing can provide an exact completion signal.

#### `AppShellLifecycleTests`

- Construction restores cached subscriptions and paused playback before a blocked launch refresh completes.
- Fixture mode performs no live launch refresh.
- Active transition inside the freshness window makes no transport call.
- Active transition at the stale boundary refreshes.
- Library manual refresh forces every subscription.
- Detail manual refresh forces only that feed.
- Model state transitions `idle → refreshing → complete` on success.
- Mixed results transition to `partialFailure` while successful catalog changes remain visible.
- Retry from partial failure is forced and clears the message only after a completely successful pass.
- A successful subscription records freshness only after database save.
- Refresh never starts playback, changes playback position, or replaces the current engine.

#### `SettingsStoreTests`

- Fresh install defaults automatic preparation on and schedules the notice.
- Existing install migration enables once and writes the version marker immediately.
- Notice dismissal is independent of the migration marker.
- A later opt-out remains off across store recreation and notice dismissal.
- Migration does not change Smart Autoplay, cloud consent, cleaning, or unrelated-content settings.

Do not set private key strings directly in most tests. Add a narrowly scoped legacy-settings fixture helper that documents the pre-migration keys and values.

#### `PlayedEpisodeReplayTests`

- Unplayed episodes do not expose replay preparation.
- Played episode with valid local audio and valid analysis exposes replay immediately.
- Missing audio requests download and preparation without clearing played state prematurely.
- Existing audio avoids another transfer but re-runs required replay analysis.
- Only one active replay preparation is accepted; a second episode reports blocked state.
- Cancelling or failing preparation leaves the episode played and resumable.
- `replayFromBeginning` resets position/played state only after readiness and starts the selected episode.
- Removing downloaded audio preserves played state and transcript, while replacement audio cannot reuse stale interval analysis.
- Relaunch restores an honest status; it must not say work resumed unless the worker actually resumed.

#### Audio-session and CarPlay tests

Keep the existing audio-session resilience coverage and add:

- interruption ending with `shouldResume == false` stays paused;
- configure failure and activate failure both avoid claiming playback intent;
- route loss outside an interruption pauses and deactivates correctly;
- media-service reset causes `AppShellModel` to replace/rebind the engine once;
- stale engine callbacks cannot mutate the replacement session;
- now-playing metadata and CarPlay dependencies point at the replacement engine;
- refresh and preparation activity do not deactivate or interrupt active playback.

### Phase 3 — make red specifications pass

Use app-only commits. Fix one coherent behavior group at a time:

1. Feed metadata atomicity, timeout, validators, and backoff.
2. Lifecycle refresh, subscription freshness, and partial-failure presentation.
3. Merge preservation and audio-identity validity.
4. Selection/preparation cancellation, serialization, and retry behavior.
5. Played-episode replay state transitions.
6. Audio-session/AppShell/CarPlay replacement wiring.

After every app-only fix commit, run the corresponding filtered tests. After each group is green, run all unit tests before moving to UI work.

### Phase 4 — minimal end-to-end UI coverage

Test-only commit. Keep UI coverage limited to wiring and user-visible truth:

1. Preserve `testLastEpisodeInLongListRemainsTappableAboveMiniPlayer` unchanged.
2. Add a deterministic fixture in which Library pull-to-refresh inserts one known episode and proves the new row becomes tappable.
3. Add a mixed-result fixture that shows “Some shows couldn’t update” and a Retry control without hiding successfully refreshed content.
4. Verify the automatic-preparation migration notice appears once, links to Settings, and stays dismissed after relaunch.
5. Add one played-episode flow: prepare replay, observe preparing/ready state, then replay from the beginning.

Give every new interactive fixture element a stable accessibility identifier. Assert resulting state, not animation timing. Do not duplicate coordinator backoff/concurrency coverage in UI tests.

## Coverage ledger and acceptance matrix

Maintain a table in the implementation handoff or pull request with these columns:

| Requirement | Test name | Initial state | Final state | Evidence |
|---|---|---|---|---|
| Example: stale foreground activation refreshes | `AppShellLifecycleTests/testStaleActivationRefreshes` | Missing behavior | Pass | xcresult path |

Every Track A requirement must end as one of:

- automated and passing;
- physical-device-only and passing with recorded device evidence;
- explicitly removed from the advertised behavior by a product decision.

“Covered indirectly” is not an acceptable final state for feed data safety, cancellation, audio identity, or playback interruption.

## Verification commands

During development, use filtered test classes:

```sh
VERIFY_TIER=2 VERIFY_NO_RETRY=1 scripts/verify.sh \
  -only-testing:PodWashTests/FeedRefreshCoordinatorTests

VERIFY_TIER=2 VERIFY_NO_RETRY=1 scripts/verify.sh \
  -only-testing:PodWashTests/PodcastStoreRefreshTests

VERIFY_TIER=2 VERIFY_NO_RETRY=1 scripts/verify.sh \
  -only-testing:PodWashTests/UpcomingSelectionPolicyTests

VERIFY_TIER=2 VERIFY_NO_RETRY=1 scripts/verify.sh \
  -only-testing:PodWashTests/WarmPlannerTests
```

Before each commit:

```sh
scripts/check-test-isolation.sh --working
```

Before handoff:

```sh
VERIFY_TIER=0 VERIFY_NO_RETRY=1 scripts/verify.sh
VERIFY_TIER=3a VERIFY_NO_RETRY=1 scripts/verify.sh
VERIFY_TIER=3b VERIFY_NO_RETRY=1 scripts/verify.sh
scripts/release-verify.sh
```

The last command intentionally repeats the fresh build and complete suites as the repository’s release gate. Record the `VERIFY RESULT` lines and retain the generated `.xcresult` bundles. A filtered green run is never sufficient for completion.

## Physical-device acceptance for Track A

Run on a supported iPhone and record device model, OS version, app build, network, output route, and timestamps.

1. **Stale refresh:** seed an older saved library, advance past the freshness interval, foreground the app, and confirm new episodes arrive without leaving Library.
2. **Playback isolation:** play an episode, refresh all feeds, and prepare another episode. Audio must remain responsive and uninterrupted; position must continue advancing.
3. **Interruption:** start playback, receive a phone/Siri interruption, and verify resume only when the system permits and the listener did not pause during the interruption.
4. **Route loss:** disconnect wired/Bluetooth output. Playback must pause and must not resume automatically on the device speaker.
5. **Media reset:** exercise the available diagnostic path for media-services reset and confirm controls, lock-screen metadata, and CarPlay/Now Playing bind to the replacement engine.
6. **Replay:** prepare a previously played episode with and without an existing local download. Confirm played state remains until “Replay from Beginning” is chosen.
7. **Long Library:** with the mini-player visible, scroll a long show to its last episode and tap it successfully.

Track B retains its separate locked/charging/background-transfer/resource-pressure acceptance matrix. Do not claim those capabilities from Track A device evidence.

## Definition of done

Track A is complete only when:

- the corrected baseline, all new unit/integration tests, and the minimal UI tests pass;
- the full unit and UI suites pass with retries disabled and no unexpected skips;
- concurrency tests prove atomic metadata and non-overlapping analysis;
- cancellation is observably distinct from failure;
- refresh state communicates partial failure honestly;
- replacement audio cannot reuse old-audio analysis;
- the physical-device checklist passes;
- every new commit satisfies test isolation;
- the handoff lists any Track B capability that remains unimplemented or unverified.

Do not mark Track B complete until its background scheduling, recovery, resource gates, ownership, budgets, and eviction behavior are implemented and pass the original plan’s automated and physical-device acceptance requirements.
