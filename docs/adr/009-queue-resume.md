# ADR-009 — Queue + resume: stores, coordinator, reload

| Field | Value |
|-------|-------|
| **Status** | Accepted |
| **Date** | 2026-07-10 |
| **Supersedes** | — |
| **Builds on** | [ADR-007](007-persistence-core-data.md) (Core Data stack); [ADR-001](001-playback-engine.md) (`PlaybackEngine` play/pause/seek); [ADR-004](004-rss-parser.md) (`Episode` / fixture IDs); [ADR-006](006-playback-integration.md) (`PlaybackCoordinator` — unchanged); [ADR-008](008-episode-downloads.md) (`DownloadState`, `InMemoryDownloadStateStore` stub) |
| **Slice** | [slice-11-queue-resume.md](../slices/slice-11-queue-resume.md) |

## Context

ADR-007 committed PodWash to Core Data and sketched file names. Slice 11 still needs
binding module boundaries, public APIs, schema, played-threshold math, auto-advance
wiring, and a **reload pattern** that makes “survive relaunch” assertable in XCTest
without disk pollution across tests.

Existing call sites depend on throwaway in-memory stubs:

| Stub (pre-11) | Call sites |
|---------------|------------|
| `InMemoryPodcastStore` | `EpisodeListViewModel`, `RootView` |
| `InMemoryCleaningToggleStore` | `AnalysisUIViewModel`, tests |
| `InMemoryDownloadStateStore` | `DownloadManager`, `EpisodeListView`, tests |

`PlaybackEngine` (ADR-001) is URL-bound at `init` and has no `play(episodeID:)`.
Auto-advance (AC2) therefore needs an **episode-level player seam**, not a change to
`PlaybackEngine`’s existing surface.

## Decision

### 1. Module layout

| File | Target | Status | Responsibility |
|------|--------|--------|----------------|
| `PodWash/PodWash/PodWash.xcdatamodeld` | app | **new** | Versioned Core Data model (`PodWash` v1) |
| `PodWash/PodWash/PersistenceController.swift` | app | **new** | `NSPersistentContainer` factory; production on-disk vs test in-memory; reload handle |
| `PodWash/PodWash/PodcastStore.swift` | app | **new** | Core Data–backed feed/episode persistence (replaces `InMemoryPodcastStore`) |
| `PodWash/PodWash/CleaningToggleStore.swift` | app | **new** | Channel + per-episode cleaning flags (replaces `InMemoryCleaningToggleStore`) |
| `PodWash/PodWash/DownloadStateStore.swift` | app | **new** | Durable download UI state (replaces `InMemoryDownloadStateStore`) |
| `PodWash/PodWash/QueueStore.swift` | app | **new** | Up-next order: add / remove / move / ordered IDs |
| `PodWash/PodWash/ResumePositionStore.swift` | app | **new** | Per-episode position + played flag; 95% threshold helper |
| `PodWash/PodWash/EpisodePlaying.swift` | app | **new** | `EpisodePlaying` protocol — injectable spy seam for queue auto-advance |
| `PodWash/PodWash/QueueCoordinator.swift` | app | **new** | Wires `QueueStore` + `EpisodePlaying`; auto-advance on episode end |
| `PodWash/PodWash/InMemoryPodcastStore.swift` | app | **delete** | Replaced by `PodcastStore` |
| `PodWash/PodWash/InMemoryCleaningToggleStore.swift` | app | **delete** | Replaced by `CleaningToggleStore` |
| `PodWash/PodWash/InMemoryDownloadStateStore.swift` | app | **delete** | Replaced by `DownloadStateStore` |
| `PodWash/PodWash/Item.swift` | app | **delete** | Unused SwiftData template (ADR-007) |
| `PodWash/PodWash/PodWashApp.swift` | app | **changed** | Remove `ModelContainer` / SwiftData; wire `PersistenceController` |
| Call sites (`EpisodeListViewModel`, `AnalysisUIViewModel`, `DownloadManager`, `RootView`) | app | **changed** | Inject Core Data–backed stores (same method names where possible) |
| `PodWash/PodWashTests/QueueTests.swift` | test | **new (QA)** | AC1–AC2 |
| `PodWash/PodWashTests/ResumePositionTests.swift` | test | **new (QA)** | AC3–AC4 |
| `PodWash/PodWashTests/PersistenceMigrationTests.swift` | test | **new (QA)** | AC5 |

**Unchanged:** `PlaybackEngine`, `PlaybackCoordinator`, `IntervalCache` (JSON), download
file layout (ADR-008), RSS parse behavior (ADR-004).

### 2. Schema (`PodWash` model v1)

Entity names are Core Data; domain types (`Episode`, `PodcastFeed`, `DownloadState`)
remain the app-facing value types from ADR-004 / ADR-008.

| Entity | Attributes (binding) | Notes |
|--------|----------------------|-------|
| `CDPodcast` | `title: String`, `artworkURLString: String?`, `feedDescription: String?`, `channelCleaningEnabled: Bool` | Single active subscription for MVP (one row after feed save) |
| `CDEpisode` | `id: String` (unique), `title: String`, `pubDate: Date`, `artworkURLString: String?`, `showNotes: String?`, `audioURLString: String?`, `playbackPosition: Double` (default `0`), `isPlayed: Bool` (default `false`), `episodeCleaningEnabled: Bool` (default `false`), `downloadStateRaw: String` (default `"notDownloaded"`) | `id` matches RSS guid / fixture IDs (`fixture-ep-001`…`005`) |
| `CDQueueEntry` | `episodeID: String`, `sortIndex: Int32` | Ordered up-next; one row per queued episode; no duplicate `episodeID` |

Relationships (optional convenience): `CDPodcast.episodes ↔ CDEpisode.podcast`. Queue
entries reference episodes by `episodeID` string (no required relationship) so queue
ops stay simple when an ID is known from fixtures.

**Download state persistence:** Only durable cases are stored:
`notDownloaded`, `downloaded`, `failed`. In-flight `downloading(progress:)` is **not**
written; on read, unknown/missing raw values map to `.notDownloaded`. After relaunch,
`DownloadManager` may still seed `.downloaded` from on-disk files (ADR-008) — Core Data
and file scan must agree (file present → `.downloaded`).

**Interval cache:** Remains JSON files (ADR-005 / ADR-007 optional defer).

### 3. `PersistenceController` + reload pattern

```swift
@MainActor
final class PersistenceController {
    let container: NSPersistentContainer
    var viewContext: NSManagedObjectContext { container.viewContext }

    /// On-disk store under Application Support (`PodWash.sqlite`).
    static func production() -> PersistenceController

    /// Isolated in-memory store for unit tests.
    /// - Parameter identifier: Stable id shared by two controllers in the same test
    ///   to simulate process relaunch (see reload pattern below).
    static func inMemory(identifier: String = UUID().uuidString) -> PersistenceController

    func save() throws
}
```

**Reload pattern (binding for AC1, AC3–AC5):**

1. Pick a fresh `identifier` (or temp directory) **per test** — never reuse across tests.
2. `let pc1 = PersistenceController.inMemory(identifier: id)` → mutate via stores → `save()`.
3. Release `pc1` / stores (set to `nil`) so no live context caches remain.
4. `let pc2 = PersistenceController.inMemory(identifier: id)` → new stores on `pc2.viewContext`.
5. Assert persisted values on `pc2`.

**Implementation requirement:** `inMemory(identifier:)` must attach a second controller
to the **same** underlying in-memory store for a given `identifier` while any handle
for that id remains registered, **or** use a unique temp SQLite URL keyed by
`identifier` (still deleted in `tearDown`). Pure `NSInMemoryStoreType` without sharing
does **not** survive a second `loadPersistentStores` — Engineer must implement one of:

| Approach | Allowed? | Notes |
|----------|----------|-------|
| Process-local registry of `NSPersistentStoreCoordinator` keyed by `identifier` | Yes | Keeps `isStoredInMemoryOnly = true` (ADR-007 §3) |
| Temp-directory SQLite URL per `identifier`, deleted in tearDown | Yes | Proves on-disk durability; still isolated per test |

**Forbidden:** Tests reading a shared on-disk store left by another test; production
path in unit tests; `XCTSkip` when reload is flaky.

### 4. Store public APIs

All stores are `@MainActor`, take `NSManagedObjectContext` (or `PersistenceController`)
in `init`, and save on each mutating call (or batch + explicit `save()` — either is fine
if ACs see durable state after the mutating API returns).

```swift
@MainActor
final class PodcastStore {
    init(context: NSManagedObjectContext)

    func save(_ feed: PodcastFeed) throws
    func clear() throws
    var currentFeed: PodcastFeed? { get }   // episodes ordered as last saved
    var episodes: [Episode] { get }         // convenience; empty if no feed
}

@MainActor
final class CleaningToggleStore {
    init(context: NSManagedObjectContext)

    var isChannelCleaningEnabled: Bool { get }
    func isEpisodeCleaningEnabled(_ episodeID: String) -> Bool
    func setChannelCleaning(_ enabled: Bool) throws
    func setEpisodeCleaning(_ episodeID: String, enabled: Bool) throws
}

@MainActor
final class DownloadStateStore {
    init(context: NSManagedObjectContext)

    func state(for episodeID: String) -> DownloadState
    func setState(_ state: DownloadState, for episodeID: String) throws
    func clear() throws
}

@MainActor
final class QueueStore {
    init(context: NSManagedObjectContext)

    func queueEpisodeIDs() -> [String]          // ascending sortIndex
    func add(_ episodeID: String) throws        // append; no-op if already queued
    func remove(_ episodeID: String) throws
    func move(_ episodeID: String, toIndex: Int) throws  // 0-based; clamps to bounds
}

@MainActor
final class ResumePositionStore {
    init(context: NSManagedObjectContext)

    func position(for episodeID: String) -> TimeInterval
    func setPosition(_ seconds: TimeInterval, for episodeID: String) throws
    func isPlayed(_ episodeID: String) -> Bool
    func setPlayed(_ played: Bool, for episodeID: String) throws

    /// Updates position; sets `isPlayed == true` when
    /// `duration > 0 && seconds / duration >= playedThreshold` (default **0.95**).
    /// Does not clear `isPlayed` when progress later drops below threshold.
    func recordProgress(
        episodeID: String,
        seconds: TimeInterval,
        duration: TimeInterval,
        playedThreshold: Double = 0.95
    ) throws
}
```

**Played threshold (AC4, binding):**

| Duration | Progress | `isPlayed` after `recordProgress` |
|----------|----------|-----------------------------------|
| 100.0 s | 94.9 s | `false` (`0.949 < 0.95`) |
| 100.0 s | 95.0 s | `true` (`0.95 >= 0.95`) |

Comparison uses `seconds / duration >= playedThreshold` with `Double` division (no
rounding). `duration <= 0` → never auto-marks played.

**Call-site migration:** Replace stub types with the Core Data stores above. Prefer
keeping method names so view models / `DownloadManager` diffs stay mechanical.
Delete stub source files once call sites and tests compile against the new types.

### 5. `EpisodePlaying` + `QueueCoordinator`

```swift
@MainActor
protocol EpisodePlaying: AnyObject {
    /// Start or switch playback to `episodeID` (resolve URL upstream in production).
    func play(episodeID: String)
    func pause()
    func seek(to seconds: TimeInterval)
}

@MainActor
final class QueueCoordinator {
    private let queue: QueueStore
    private let player: any EpisodePlaying
    private let resume: ResumePositionStore

    private(set) var currentEpisodeID: String?

    init(queue: QueueStore, player: any EpisodePlaying, resume: ResumePositionStore)

    /// Sets current episode; restores saved position via `player.seek` then `play`
    /// when `resume.position(for:) > 0`.
    func playEpisode(_ episodeID: String)

    /// Saves `resume` position from the supplied seconds (production passes engine time).
    func pause(savingPosition seconds: TimeInterval)

    /// AC2 entry: treat `episodeID` as finished.
    /// 1. `recordProgress(..., seconds: duration, duration: duration)` when duration known,
    ///    or `setPlayed(true)` for the ended episode when tests stub duration.
    /// 2. If `queueEpisodeIDs()` is non-empty, remove and play the **first** ID
    ///    (exactly one `player.play(episodeID:)` call).
    /// 3. Update `currentEpisodeID` to the advanced episode, or `nil` if queue empty.
    func handlePlaybackEnded(episodeID: String, duration: TimeInterval?)
}
```

**AC2 sequence (normative):**

Given `currentEpisodeID == "fixture-ep-001"` and
`queueEpisodeIDs() == ["fixture-ep-002", "fixture-ep-003"]`:

1. Test calls `handlePlaybackEnded(episodeID: "fixture-ep-001", duration: …)`.
2. Within **1.0 s**, spy records exactly **one** `play(episodeID:)` with
   `"fixture-ep-002"`.
3. After handling, `queueEpisodeIDs() == ["fixture-ep-003"]`
   (`fixture-ep-002` removed from queue as it becomes current).

Production may forward `AVPlayerItemDidPlayToEndTime` into `handlePlaybackEnded`;
tests call the method directly — **no real `AVPlayer` end-notification dependency**.

**Production adapter (sketch, not required for ACs):** A thin
`PlaybackEngineEpisodePlayer` may own URL resolution + `PlaybackEngine` lifecycle and
conform to `EpisodePlaying`. That adapter is out of AC scope if unit tests inject a
spy; do **not** broaden `PlaybackEngine` with `play(episodeID:)`.

**AC3 resume path:**

1. `pause(savingPosition: 127.5)` (or `resume.setPosition(127.5, for:)`) for
   `"fixture-ep-001"` with stub duration **600.0 s**.
2. Container reload (§3).
3. `playEpisode("fixture-ep-001")` → spy/engine `seek` argument `restored` satisfies
   `abs(restored - 127.5) <= 1.0`.

### 6. Accessibility identifiers (UX-light)

| Identifier | Role |
|------------|------|
| `queueAddButton_<index>` | Add episode at episode-list row index to up-next |
| `queueCell_<index>` | 0-based up-next list row |
| `queueRemoveButton_<index>` | Remove from up-next |

Full UX contract may land in `docs/slices/slice-11-queue-resume-ux.md`; these IDs are
the minimum for UI tests if/when added. Unit ACs do not require UI.

### 7. Cross-cutting impact

| Surface | Impact |
|---------|--------|
| `PlaybackEngine` | **No public API change** — queue uses `EpisodePlaying` seam |
| `PlaybackCoordinator` / intervals | Unchanged; do not alter mute/skip in this slice |
| `TimedWord` / matcher | None |
| `EpisodeListViewModel` | Store type swap → `PodcastStore` |
| `AnalysisUIViewModel` | Store type swap → `CleaningToggleStore` |
| `DownloadManager` | Store type swap → `DownloadStateStore` |
| Parallel slices 10 / 12 | Store migration only; no download or speed behavior change |
| Slice 13+ | May read `isPlayed` / queue; schema v1 is the contract |

### 8. Empirical validation / verification posture

No new AVFoundation, StoreKit, or network claims. Persistence and coordinator behavior
are fully injectable:

| Claim | How verified |
|-------|----------------|
| Queue order survives “relaunch” | AC1: two `PersistenceController.inMemory(identifier:)` instances |
| Auto-advance | AC2: `EpisodePlaying` spy; direct `handlePlaybackEnded` |
| Position restore | AC3: saved Double + seek argument tolerance ±1.0 s |
| 95% played rule | AC4: `recordProgress` with stub duration 100.0 s |
| Stub → Core Data migration smoke | AC5: seed from `sample_feed.xml` + toggles + `.downloaded` |

No framework spike required before QA writes tests. If Engineer chooses temp SQLite
for reload instead of an in-memory coordinator registry, document the choice in a
one-line comment on `PersistenceController.inMemory` — both are ADR-compliant.

## Consequences

- Slice 11 Architect gate artifacts: **ADR-007** (stack) + **this ADR** (modules/APIs).
- QA maps ACs to the APIs in §4–§5; tests must not invent alternate queue/resume surfaces.
- Engineer removes SwiftData template and in-memory stub types after call-site migration.
- Supersede this ADR (do not silently edit) if `PlaybackEngine` must gain episode-level
  APIs or if the played threshold changes.

## Alternatives considered

| Option | Why not chosen |
|--------|----------------|
| **Extend `PlaybackEngine` with `play(episodeID:)`** | Couples URL loading + queue; breaks ADR-001 URL-at-init model; harder to spy without AVPlayer. |
| **Queue as ordered attribute on `CDPodcast` only** | Reorder/move is clumsier; `CDQueueEntry` keeps sortIndex explicit for AC1. |
| **Unplay when progress drops below 95%** | AC4 only requires sticky `true` after threshold; auto-unplay deferred. |
| **Persist `.downloading` progress** | Meaningless across process death; ADR-008 file scan re-seeds `.downloaded`. |
| **Move `IntervalCache` into Core Data in Slice 11** | Explicitly deferred (ADR-007 / slice out-of-scope) unless zero-cost. |
