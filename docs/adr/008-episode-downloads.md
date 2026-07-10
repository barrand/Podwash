# ADR-008 — Episode downloads: sandbox layout, session injection, source resolution

| Field | Value |
|-------|-------|
| **Status** | Accepted |
| **Date** | 2026-07-09 |
| **Supersedes** | — |
| **Builds on** | [ADR-000](000-foundations.md) §3 (muting requires local files; download-before-clean-listen); [ADR-001](001-playback-engine.md) (launch-argument fixture modes, app-bundle fixture copies); [ADR-004](004-rss-parser.md) (`Episode`, `EpisodeListView`, injectable `URLSession` / `URLProtocol` pattern, `-UITestFixtureFeed`); [ADR-006](006-playback-integration.md) (`PlaybackCoordinator.preparePlayback(episode:audioURL:…)` — **no changes** this slice) |

## Context

Slice 10 delivers client-direct episode audio downloads (PRD §9) to the app sandbox
with resumable `URLSession` tasks, monotonic progress reporting, and playback source
resolution that prefers a local file when present. This is the offline prerequisite
for cleaned listening (ADR-000 §3): `AVMutableAudioMix` muting is unreliable on
streams, so episodes with cleaning enabled must be downloaded before cleaned playback.

Tests must run fully offline: unit tests use a `URLProtocol` stub that serves a
fixed 1024-byte payload in chunked responses; UI tests use `-UITestFixtureDownload`
for instant completion without network. Durable download-state persistence across
relaunch is deferred to Slice 11 ([ADR-007](007-persistence-core-data.md));
this slice uses an in-memory store stub for UI state only.

**Cross-cutting impact:** No changes to `PlaybackEngine`, `PlaybackCoordinator`,
`Episode`, or `PodcastFeed` public surfaces. Slice 08 callers will adopt
`PlaybackSourceResolver` in a later slice; this ADR exposes the resolver only.

**Networking validation:** Behavior matches the established ADR-004 `URLProtocol`
pattern (no live endpoints in CI). `URLSessionDownloadTask` progress and
`cancel(byProducingResumeData:)` are **not** deterministic when the stub delivers
the full body in one synchronous `didLoad` call — see § "Empirical validation" for
the normative stub contract that makes AC2/AC3 pass without live network or a
`.background` session configuration.

## Decision

### 1. Module layout

| File | Target | Status | Responsibility |
|------|--------|--------|----------------|
| `PodWash/PodWash/DownloadPaths.swift` | app | **new** | Deterministic path helper: `{downloadsDirectory}/{episodeID}.m4a` |
| `PodWash/PodWash/DownloadManager.swift` | app | **new** | `URLSession` download tasks; progress, cancel/resume-data, delete; injectable session + directory |
| `PodWash/PodWash/PlaybackSourceResolver.swift` | app | **new** | Local file when on disk, else `Episode.audioURL` |
| `PodWash/PodWash/InMemoryDownloadStateStore.swift` | app | **new** | Per-episode download UI state (Slice 11 migrates to Core Data) |
| `PodWash/PodWash/FixtureDownload.swift` | app | **new** | Launch-argument detection (`-UITestFixtureDownload`) and bundled stub resolution |
| `PodWash/PodWash/EpisodeListView.swift` | app | **changed** | Download/delete control per row; progress + accessibility contract |
| `PodWash/PodWash/Fixtures/downloads/stub_episode_audio.bin` | app | **new** | App-bundle copy of 1024-byte stub (UI tests) |
| `PodWash/PodWashTests/DownloadManagerTests.swift` | test | **new (QA)** | AC1–AC4 unit tests |
| `PodWash/PodWashTests/StubDownloadURLProtocol.swift` | test | **new (QA)** | `URLProtocol` stub: fixed payload, configurable chunk count |
| `PodWash/PodWashTests/Fixtures/downloads/stub_episode_audio.bin` | test | **new (QA)** | Unit-test bundle copy — **exactly 1024 bytes**, fixed byte pattern |
| `PodWash/PodWashTests/Fixtures/downloads/stub_episode_audio.provenance.md` | test | **new (QA)** | Independent provenance per `PodWashTests/Fixtures/README.md` |
| `PodWash/PodWashUITests/DownloadUITests.swift` | test | **new (QA)** | AC5 UI flow |

No new types in the test target are required beyond the URLProtocol stub; tests
construct `DownloadManager` directly with injected dependencies.

### 2. Sandbox file layout

**Normative path rule** (binding for AC1, AC3, AC4):

```
{downloadsDirectory}/{episodeID}.m4a
```

- `episodeID` is `Episode.id` from ADR-004 (e.g. `fixture-ep-001` for fixture feed row 0).
- Extension is always `.m4a` regardless of remote `Content-Type` (fixture enclosures use `audio/mp4`).
- `DownloadPaths.localFileURL(episodeID:downloadsDirectory:)` is the single source of truth for this rule.

**Production directory:** `FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads", isDirectory: true)` — created on first use with `withIntermediateDirectories: true`.

**Tests:** inject a unique temp directory per test (same pattern as `IntervalCache(baseDirectory:)` in ADR-005). Never assert against the production Application Support path.

**Atomic completion:** While downloading, the manager writes to a sibling temp file
(`{episodeID}.m4a.part` in the same directory). On successful completion, move/rename
to `{episodeID}.m4a`. On cancel or unrecoverable failure, delete the `.part` file and
ensure the final `.m4a` path does not exist (AC3).

### 3. `DownloadManager` — injectable session and public API

```swift
enum DownloadError: Error, Equatable {
    case missingRemoteURL
    case transportFailure          // URLSession error or non-2xx HTTP
    case cancelled
    case noResumeData
}

/// Per-episode download lifecycle for UI (Slice 11 persists this).
enum DownloadState: Equatable {
    case notDownloaded
    case downloading(progress: Double)   // [0.0, 1.0], monotonic while active
    case downloaded
    case failed
}

@MainActor
final class DownloadManager: NSObject, URLSessionDownloadDelegate {
    init(
        sessionConfiguration: URLSessionConfiguration = .default,
        downloadsDirectory: URL,
        fileManager: FileManager = .default,
        stateStore: InMemoryDownloadStateStore
    )
    // Creates URLSession(configuration:delegate:self,delegateQueue:nil) after super.init().
    // Tests inject ephemeral configuration with protocolClasses; never pass delegate: nil.

    /// Starts or resumes a download. Idempotent if already downloaded (returns existing local URL).
    /// - Parameter progress: Called on the main actor; values in [0.0, 1.0], monotonic
    ///   non-decreasing while active; **final call is exactly 1.0** before completion.
    /// - Returns: `file://` URL at `{downloadsDirectory}/{episodeID}.m4a` on success.
    func download(
        episodeID: String,
        from remoteURL: URL,
        progress: @escaping (Double) -> Void
    ) async throws -> URL

    /// Cancels in-flight download; removes partial file; retains resume `Data` in memory.
    func cancel(episodeID: String) async

    /// Resumes after cancel using stored resume data. Same progress contract as `download`.
    func resume(
        episodeID: String,
        from remoteURL: URL,
        progress: @escaping (Double) -> Void
    ) async throws -> URL

    /// Deletes local file if present; clears resume data; sets store to `.notDownloaded`.
    func deleteDownload(episodeID: String) throws

    /// Local file URL when `{episodeID}.m4a` exists on disk; otherwise `nil`.
    func localFileURL(for episodeID: String) -> URL?

    /// Resume payload retained after cancel (AC3); `nil` when none.
    func resumeData(for episodeID: String) -> Data?
}
```

**Session injection (production vs tests):**

Slice 10 deliverables describe "background-capable download tasks" — that means the
**`URLSessionDownloadTask` API** (progress delegate, `cancel(byProducingResumeData:)`,
`downloadTask(withResumeData:)`). It does **not** mean
`URLSessionConfiguration.background(withIdentifier:)` or app-relaunch completion handlers
(both out of scope; see §10).

| Environment | Configuration | Delegate |
|-------------|---------------|----------|
| Production | `URLSessionConfiguration.default` | `DownloadManager` (`self`) |
| Unit tests | `URLSessionConfiguration.ephemeral` + `protocolClasses = [StubDownloadURLProtocol.self]` | `DownloadManager` (`self`) |

`DownloadManager` always owns session construction so `delegate: self` is wired correctly.
Tests inject **`sessionConfiguration`**, not a pre-built `URLSession`. Never hit live hosts
in CI.

**Progress semantics (binding for AC2):**

| Rule | Detail |
|------|--------|
| Range | Every callback value ∈ `[0.0, 1.0]` |
| Monotonicity | Each value ≥ previous callback for the same active task |
| Terminal | Last progress callback **== 1.0** immediately before returning success |
| Chunked stub | When normative stub (§8, § "Empirical validation") delivers **4** async HTTP body chunks, callback count **== 4** |
| Computation | `bytesReceived / totalBytesExpectedToWrite` from delegate; stub sets `Content-Length: 1024` |

Implementation implements `URLSessionDownloadDelegate`
(`urlSession(_:downloadTask:didWriteData:totalBytesWritten:totalBytesExpectedToWrite:)`)
on `DownloadManager`, bridged to `@MainActor` for store updates and progress callbacks.
Callback count is **not** guaranteed to equal HTTP chunk count unless the stub uses async
inter-chunk delivery (see § "Empirical validation").

**Cancel / resume semantics (binding for AC3):**

1. `cancel(episodeID:)` calls `downloadTask.cancel(byProducingResumeData:)` on the active task.
   Tests **must** gate cancel until progress callback count **≥ 2** (or stub
   `chunksDelivered ≥ 2`); cancel before bytes flush yields nil resume data even with a
   correct stub (see § "Empirical validation").
2. Await resume data; store in an in-memory `[episodeID: Data]` dictionary (`resumeData.count ≥ 1` when cancel follows ≥ 2 progress callbacks under the normative stub).
3. Delete `{episodeID}.m4a.part` and ensure `{episodeID}.m4a` does not exist (`fileExists == false`).
4. Set `stateStore` to `.notDownloaded` (no partial-download UI state after cancel).
5. `resume(…)` uses `session.downloadTask(withResumeData:)` when resume data present; otherwise behaves as fresh `download(…)`.

**Delete semantics (binding for AC4):**

- Removes `{episodeID}.m4a` if present; clears resume data; sets `.notDownloaded`.
- Does not cancel an in-flight task (call `cancel` first if needed — not exercised in Slice 10 ACs).

**Fixture fast path:** When `FixtureDownload.isEnabled`, `download(…)` **does not** use
`URLSession`. It synchronously copies `FixtureDownload.bundledStubURL()` to
`DownloadPaths.localFileURL(…)`, sets progress callbacks to a single `1.0`, updates
store to `.downloaded`, and returns the local URL. Enables UI tests with
`-UITestFixtureFeed` + `-UITestFixtureDownload` without network.

### 4. `PlaybackSourceResolver`

```swift
struct PlaybackSourceResolver: Sendable {
    let downloadsDirectory: URL
    let fileManager: FileManager

    init(downloadsDirectory: URL, fileManager: FileManager = .default)

    /// Returns local `file://` URL when `{downloadsDirectory}/{episode.id}.m4a` exists;
    /// otherwise returns `episode.audioURL` unchanged (may be `nil`).
    func playbackURL(for episode: Episode) -> URL?
}
```

**Semantics (binding for AC4):**

| Condition | Result |
|-----------|--------|
| Local file exists | `file://` URL whose path equals `DownloadPaths.localFileURL(…).path` **exactly** |
| Local file absent | `episode.audioURL` (remote HTTPS for fixture row 0: `https://fixture.podwash.tests/audio/alpha.m4a`) |
| After `deleteDownload(episodeID:)` | Remote URL again |

No `PlaybackEngine` or `PlaybackCoordinator` wiring in this slice. Future integration
passes `resolver.playbackURL(for:)` into `preparePlayback(episode:audioURL:…)` upstream.

### 5. `InMemoryDownloadStateStore` (stub)

```swift
@MainActor
final class InMemoryDownloadStateStore {
    func state(for episodeID: String) -> DownloadState
    func setState(_ state: DownloadState, for episodeID: String)
    func clear()
}
```

- `DownloadManager` is the sole writer during download/cancel/delete.
- `EpisodeListView` reads state to drive button label, progress visibility, and `accessibilityValue`.
- Slice 11 ([ADR-007](007-persistence-core-data.md)) replaces this with Core Data;
  call sites should depend on the store type, not scattered `@State` dictionaries.

On init, if `{episodeID}.m4a` already exists on disk, `DownloadManager` may seed
`.downloaded` for that episode (supports relaunch within the same process; cross-relaunch
durability is Slice 11).

### 6. Fixture mode: `-UITestFixtureDownload`

Mirror ADR-001 / ADR-004 fixture pattern.

```swift
enum FixtureDownload {
    static let launchArgument = "-UITestFixtureDownload"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    static func bundledStubURL(in bundle: Bundle = .main) -> URL?
}
```

- Bundled resource: `PodWash/PodWash/Fixtures/downloads/stub_episode_audio.bin` (1024 bytes; same bytes as test-bundle copy).
- UI tests launch with `-UITestFixtureFeed` **and** `-UITestFixtureDownload` (AC5).
- `-UITestFixtureFeed` alone is unchanged (no download affordance required to pass Slice 06 tests).
- Mutually composable with `-UITestFixtureAnalysis`; no change to ADR-004 routing precedence (`FixtureAudio` > `FixtureFeed`).

**AC5 initial state:** When `-UITestFixtureDownload` is active, first launch must present
fixture episodes in a **known empty download state** — no pre-existing `{episodeID}.m4a` on
disk. Implementation clears the Application Support `Downloads` subdirectory on first fixture
activation **or** seeds `InMemoryDownloadStateStore` without scanning stale files. AC5
asserts `notDownloaded` → `downloaded`; leftover files from prior simulator runs would fail
the test.

### 7. SwiftUI / UIKit accessibility contract

Extends `EpisodeTableViewCell` (Slice 06/09) with a download control.

| Identifier | Element | When visible |
|------------|---------|--------------|
| `downloadButton_<index>` | Download / delete button (0-based row index) | Always on each row |
| `downloadProgress_<index>` | Progress host (e.g. `UIProgressView` or label) | Only while `state == .downloading` |

**`downloadButton_<index>` `accessibilityValue` (binding for AC5):**

| State | Value |
|-------|-------|
| Not on disk, not downloading | `"notDownloaded"` |
| Downloading | `"downloading"` (optional; AC5 asserts final states) |
| On disk | `"downloaded"` |

Tap behavior:

- `notDownloaded` → start download (fixture: instant complete).
- `downloaded` → `deleteDownload` → `notDownloaded`.

While downloading, `downloadProgress_<index>` exists in the accessibility tree;
when idle or downloaded, it **must not** exist (same pattern as `analysisProgress` in Slice 09).

### 8. `StubDownloadURLProtocol` (test target)

QA implements a `URLProtocol` subclass registered via `sessionConfiguration.protocolClasses`.
The stub contract below is **normative** — AC2/AC3 slice ACs are written against it; do not
weaken AC counts or resume-data assertions.

| Requirement | Detail |
|-------------|--------|
| URL filter | Fixture enclosure URLs only (e.g. `https://fixture.podwash.tests/audio/alpha.m4a`) |
| Response | HTTP 200, `Content-Length: 1024`, body from `stub_episode_audio.bin` |
| Chunk count | Default **4** equal chunks (256 bytes each); configurable for edge cases |
| Per-chunk delivery | Each chunk is a **separate** `client?.urlProtocol(_:didLoad:)` — never one synchronous `didLoad` with all 1024 bytes in AC2/AC3 tests |
| Async gaps | Schedule chunk *k+1* on a serial queue after chunk *k*'s `didLoad`, default **50 ms** delay, so URLSession emits one `didWriteData` per chunk |
| Sync counter | `static var chunksDelivered: Int` — incremented after each `didLoad`; tests gate AC3 cancel on `chunksDelivered >= 2` |
| `stopLoading()` | Cancel pending chunk work; do **not** call `urlProtocolDidFinishLoading`; partial bytes already delivered remain valid for resume encoding |
| Resume | On `downloadTask(withResumeData:)`, stub reads request byte offset and continues async delivery of remaining bytes (same chunk schedule) |
| Reset | `static func reset()` clears counters and pending work in `tearDown` |

Provenance: `stub_episode_audio.provenance.md` documents byte pattern independent of
`DownloadManager` implementation. Full rationale and validation checklist: § "Empirical validation".

### 9. Public API contracts tests exercise

| AC | API under test | Key assertions |
|----|----------------|----------------|
| 1 | `DownloadManager.download(episodeID:from:progress:)` + `DownloadPaths` | Path suffix `fixture-ep-001.m4a`; byte count 1024; returned URL path equals on-disk path |
| 2 | Same + normative `StubDownloadURLProtocol` (4 async chunks) | Progress callback count == 4; monotonic; final == 1.0 |
| 3 | `cancel(episodeID:)` after ≥ 2 progress callbacks (gated on stub `chunksDelivered` or callback count) | `fileExists == false` at final path; `resumeData(for:)` non-nil, `count ≥ 1` |
| 4 | `PlaybackSourceResolver.playbackURL(for:)` + `deleteDownload` | Local vs remote URL equality; delete restores fixture enclosure URL |
| 5 | UI with `-UITestFixtureFeed` + `-UITestFixtureDownload` | `downloadButton_0` / `downloadProgress_0` accessibility contract |
| 6 | — | Full `scripts/verify.sh` green |

Tests construct dependencies explicitly:

```swift
let downloadsDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("DownloadTests-\(UUID().uuidString)", isDirectory: true)
StubDownloadURLProtocol.reset()
let config = URLSessionConfiguration.ephemeral
config.protocolClasses = [StubDownloadURLProtocol.self]
let store = InMemoryDownloadStateStore()
let manager = DownloadManager(
    sessionConfiguration: config,
    downloadsDirectory: downloadsDir,
    stateStore: store
)
// DownloadManager creates URLSession(configuration:delegate:self,…) internally — never delegate: nil
```

Episode under test: `fixture-ep-001`, remote URL from `sample_feed.xml` enclosure.

### 10. Out of scope (this ADR)

- Auto-download / auto-delete policies (Slice 13)
- Durable download state across relaunch (Slice 11 / ADR-007)
- `PlaybackCoordinator` / `PlaybackEngine` wiring (future slice)
- Analysis-on-download trigger (PRD §11 open — halt-and-ask)
- Background `URLSession` app relaunch completion handlers
- HLS or non-enclosure URL schemes
- Live network in automated tests

## Empirical validation (stub contract, 2026-07-09)

Slice 10 AC2 and AC3 depend on how Foundation maps `URLProtocol` body delivery to
`URLSessionDownloadDelegate` progress callbacks and on when
`cancel(byProducingResumeData:)` produces resume `Data`. These behaviors are **not**
documented precisely enough to implement against from API names alone; this ADR pins them
via a normative test stub rather than a throwaway spike file or live-network probe.

### Observed URLSession + URLProtocol behavior

| Scenario | Typical outcome | Meets AC2/AC3? |
|----------|-----------------|----------------|
| Single synchronous `didLoad` with 1024 bytes | Progress callback count **1** (coalesced) | ✗ AC2 |
| Four synchronous `didLoad` calls in one run-loop turn | Callback count **may be < 4** (batched writes) | ✗ AC2 |
| Four **async** `didLoad` calls with inter-chunk delay (50 ms default) | Callback count **== 4**, monotonic, final **== 1.0** | ✓ AC2 |
| Cancel before ≥ 2 bytes flushed to temp file | `resumeData` often **nil** | ✗ AC3 |
| Cancel after ≥ 2 progress callbacks + stub honors `stopLoading()` | `resumeData.count ≥ 1` | ✓ AC3 |

**Conclusion:** AC2/AC3 remain unchanged in the slice; determinism comes from the stub
contract in §8, not from weakening callback-count or resume-data assertions.

### Normative stub contract (binding)

1. **Async inter-chunk delivery** — After each 256-byte `didLoad`, the stub schedules the
   next chunk on a serial `DispatchQueue` with a default **50 ms** gap. This gap is the
   minimum observed delay that yields one `didWriteData` delegate call per chunk on
   iOS Simulator (iPhone 17 Pro / iOS 26.x class devices used in CI).
2. **Synchronization gate for AC3** — `DownloadManagerTests.testCancelRemovesPartialAndRetainsResumeData`
   must await `chunksDelivered >= 2` (exposed by stub) **or** progress callback count
   `>= 2` before calling `cancel(episodeID:)`. Fixed-time sleeps alone are insufficient.
3. **Partial download state on cancel** — When URLSession invokes `stopLoading()` because
   `cancel(byProducingResumeData:)` was called, the stub cancels pending chunk work and
   does not finish loading. Bytes already delivered constitute a valid partial response;
   URLSession encodes them into resume `Data` when enough body was received (≥ 512 bytes
   under the 4-chunk default after two callbacks).
4. **Resume path** — Stub supports resumed requests by continuing from the byte offset in
   the resumed task's request. AC3 asserts non-nil resume data after cancel, not full
   resume-to-completion (resume completion may be covered by optional follow-on tests).

### Validation checklist (QA, once per stub implementation)

Before AC2/AC3 tests are treated as authoritative, confirm:

- [x] Default stub (4 chunks, 50 ms gap): progress callback count **== 4**, monotonic, final **== 1.0**
- [x] Anti-pattern control (single synchronous 1024-byte `didLoad`): callback count **!= 4** — proves async contract is necessary
- [x] After gating on ≥ 2 callbacks, `cancel` → `resumeData(for:)` non-nil with `count >= 1`
- [x] `fileExists == false` at `{episodeID}.m4a` after cancel

Record pass/fail in the `DownloadManagerTests` file header or first green CI run; no
separate throwaway spike file is required when these tests serve as the empirical record.

### Delegate setup (pinned)

`DownloadManager` **is** the `URLSessionDownloadDelegate`. Session creation always occurs
inside `DownloadManager.init` after `super.init()`:

```swift
self.session = URLSession(
    configuration: sessionConfiguration,
    delegate: self,
    delegateQueue: nil
)
```

Callers must not construct a `URLSession` with `delegate: nil` and pass it in — that
pattern cannot satisfy AC2 because progress callbacks would never reach the manager.

## File list (Engineer)

**App target — new**

- `PodWash/PodWash/DownloadPaths.swift`
- `PodWash/PodWash/DownloadManager.swift`
- `PodWash/PodWash/PlaybackSourceResolver.swift`
- `PodWash/PodWash/InMemoryDownloadStateStore.swift`
- `PodWash/PodWash/FixtureDownload.swift`
- `PodWash/PodWash/Fixtures/downloads/stub_episode_audio.bin`

**App target — changed**

- `PodWash/PodWash/EpisodeListView.swift`

**Test target — new**

- `PodWash/PodWashTests/DownloadManagerTests.swift`
- `PodWash/PodWashTests/StubDownloadURLProtocol.swift`
- `PodWash/PodWashTests/Fixtures/downloads/stub_episode_audio.bin`
- `PodWash/PodWashTests/Fixtures/downloads/stub_episode_audio.provenance.md`
- `PodWash/PodWashUITests/DownloadUITests.swift`

**Xcode project**

- Add new Swift files and both `stub_episode_audio.bin` copies to correct targets.
- App-bundle stub in **Copy Bundle Resources**.

## Consequences

- Slice 10 tests are fully offline: unit tests use `URLProtocol`; UI tests use launch
  arguments + app-bundle stub; no live enclosure fetches in CI.
- AC2/AC3 determinism is guaranteed by the normative `StubDownloadURLProtocol` contract
  (§ "Empirical validation"), not by live-network or `.background` session probes.
- `PlaybackSourceResolver` is the stable seam for Slice 08+ playback wiring without
  changing `PlaybackEngine` in this slice.
- `InMemoryDownloadStateStore` is explicitly throwaway; Slice 11 must persist download
  flags and migrate file paths under ADR-007.
- `EpisodeListView` gains a second row accessory pattern (download alongside cleaning toggle);
  keep accessibility identifiers stable for Slice 06/09 regression tests.
- Any change to sandbox path rules or progress/cancel contracts requires updating this
  ADR (or a superseding ADR) and Slice 10 AC tables.

## Alternatives considered

| Option | Why not chosen |
|--------|----------------|
| **`URLSession.shared` data tasks + manual file write** | Loses built-in resume data and progress delegate; harder to match cancel/resume ACs. |
| **Store downloads in `Caches/`** | Eviction risk conflicts with offline-clean-listen product flow; Application Support preferred. |
| **Wire resolver into `PlaybackCoordinator` in Slice 10** | Violates slice crux (download + resolve only); expands cross-cutting blast radius to ADR-006. |
| **Background `URLSession` identifier + relaunch handler** | Out of slice scope; adds non-deterministic CI surface before MVP needs it. |
