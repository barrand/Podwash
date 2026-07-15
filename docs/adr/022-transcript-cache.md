# ADR-022 — Transcript cache + episode transcript viewer

| Field | Value |
|-------|-------|
| **Status** | Accepted |
| **Date** | 2026-07-15 |
| **Supersedes** | — (extends [ADR-005](005-analysis-pipeline.md) with a **second** on-disk artifact; does **not** replace interval fingerprinting. Aligns with [ADR-021](021-progressive-playback-super-seek-bar.md) §Consequences — terminal-only transcript persistence.) |
| **Builds on** | [ADR-000](000-foundations.md) §4 (`TimedWord`); [ADR-005](005-analysis-pipeline.md) (`AnalysisPipeline`, `IntervalCache`); [ADR-009](009-queue-resume.md) (`ResumePositionStore` / `CDEpisode.playbackPosition`); [ADR-013](013-segmentation-integration.md) (`IntervalSource.unrelatedContent`, `CensorAction.skip`); [ADR-015](015-app-shell-navigation.md) (`AppShellModel`, `EpisodeListView`, full-player sheet); [ADR-021](021-progressive-playback-super-seek-bar.md) (chunked analyze; no partial transcript write) |
| **Slice** | [slice-26-episode-transcript-viewer.md](../slices/slice-26-episode-transcript-viewer.md) |

## Context

`AnalysisPipeline` produces `[TimedWord]` on every cache miss, then discards the
array after building `[CensorInterval]`. Only intervals are persisted
(`IntervalCache`, keyed by `(episodeID, targetFingerprint)`). Users cannot read
what ASR heard, what they have already listened to, or which ad/superfluous spans
were skipped.

Slice 26 product pins (intake — do not re-litigate):

| Pin | Choice |
|-----|--------|
| Entry | Full player `playback.viewTranscript` + episode row `episode.viewTranscript` (same sheet) |
| Affordance | Visible only when a **complete** transcript file exists on disk |
| Partial / progressive | **No** partial append; hide affordance while analysis is in flight (AC9) |
| Listened | `word.end ≤ playbackPosition` |
| Skipped ad | Overlap with cached interval `source == .unrelatedContent` **and** `action == .skip` |
| Profanity text | Show raw ASR words (no redaction); do **not** highlight profanity intervals |
| Cache key | `episodeID` only (ASR output independent of word-list fingerprint) |
| Invalidate | Episode delete / download+cache purge → `remove`; terminal re-analyze → overwrite |

Acceptance is fixture / cache / ViewModel / AX assertable (ACs 1–10). No device
listening.

## Empirical validation

**No throwaway spike required.** Claims are:

- `Codable` JSON round-trip of existing `TimedWord` (Slice 02 / ADR-000)
- Pure `Double` overlap + listened classification in `TranscriptViewModel`
- XCTest accessibility identifiers/values (same pattern as ADR-018 / ADR-021)

No new AVFoundation, ASR, StoreKit, CarPlay, or networking behavior is asserted.
Live WhisperKit fidelity is out of scope; injected / fixture transcripts own Done-gate
proof.

## Decision

### 1. Module layout / file boundaries

| File | Target | Status | Responsibility |
|------|--------|--------|----------------|
| `PodWash/PodWash/TranscriptCache.swift` | app | **new** | On-disk JSON `[TimedWord]` keyed by `episodeID`; injectable `baseDirectory`; `store` / `load` / `exists` / `remove` / `clear` |
| `PodWash/PodWash/TranscriptViewModel.swift` | app | **new** | Pure flags: per-word `listened` / `skippedAd`, aggregate counts, scroll-anchor time; **no SwiftUI** |
| `PodWash/PodWash/TranscriptView.swift` | app | **new** | Scrollable transcript sheet; auto-scroll on open; accessibility contract (UX owns pixels — `slice-26-ux.md`) |
| `PodWash/PodWash/AnalysisPipeline.swift` | app | **changed** | Inject `TranscriptCache`; **terminal-only** `store` of full `[TimedWord]` on cold-miss complete (blocking + chunked); on interval cache hit **skip** overwrite when transcript exists, **backfill** `store` when missing (task-020) |
| `PodWash/PodWash/ProductionAnalyzerFactory.swift` | app | **changed** | Wire production `TranscriptCache.applicationSupport` (or injected test dirs) into pipeline |
| `PodWash/PodWash/AppShellModel.swift` | app | **changed** | Affordance gate (`exists`); present transcript sheet; load transcript + intervals + resume position into ViewModel |
| `PodWash/PodWash/AppShellView.swift` | app | **changed** | Full-player `playback.viewTranscript` content-tree overlay when transcript exists (not ToolbarItem; avoids duplicate AX id); transcript sheets |
| `PodWash/PodWash/EpisodeListView.swift` | app | **changed** | Row trailing affordance `episode.viewTranscript` when transcript exists |
| `PodWash/PodWash/DownloadManager.swift` (and/or purge call sites) | app | **changed (minimal)** | On `deleteDownload` / episode cache purge, call `TranscriptCache.remove(episodeID:)` (same lifetime as interval retention — Slice 13) |
| `PodWash/PodWash/FixtureTranscript.swift` | app | **new** | `-UITestFixtureTranscript`; seeds transcript + intervals + preset resume; implies Library/feed path; no-transcript control omits transcript file |
| `PodWash/PodWashTests/TranscriptCacheTests.swift` | test | **new (QA)** | AC1, AC10 |
| `PodWash/PodWashTests/TranscriptViewModelTests.swift` | test | **new (QA)** | AC3 |
| `PodWash/PodWashTests/AnalysisPipelineTests.swift` | test | **changed (QA)** | AC2 extension |
| `PodWash/PodWashUITests/TranscriptUITests.swift` | test | **new (QA)** | AC4–AC9 |

**Unchanged:** `TimedWord` schema, matcher / segmenter math, `IntervalCache` fingerprint
keying, progressive chunk frontiers (ADR-021), tap-word-to-seek (OOS), CarPlay /
lock-screen / mini-player transcript entry (OOS).

### 2. Key types / public API sketch

```swift
/// On-disk JSON cache of the full episode ASR transcript.
struct TranscriptCache: Sendable {
    let baseDirectory: URL

    init(baseDirectory: URL)

    /// Production: Application Support/TranscriptCache/
    static var applicationSupport: TranscriptCache { get }

    /// True iff a transcript file exists for `episodeID` (affordance gate; no decode required).
    func exists(episodeID: String) -> Bool

    func load(episodeID: String) -> [TimedWord]?

    /// Overwrites any prior file for this episode (terminal re-analyze).
    func store(_ words: [TimedWord], episodeID: String) throws

    /// Episode delete / download+cache purge — AC10.
    func remove(episodeID: String) throws

    /// Test helper — removes the cache directory.
    func clear() throws
}

struct TranscriptWordDisplay: Equatable, Sendable {
    var index: Int
    var word: TimedWord
    var listened: Bool
    var skippedAd: Bool
}

/// Pure classification over transcript + intervals + resume position.
struct TranscriptViewModel: Equatable, Sendable {
    var words: [TranscriptWordDisplay]
    var wordCount: Int { words.count }
    var listenedCount: Int
    var skippedAdCount: Int
    /// Whole seconds for `transcript.scrollAnchor` (nearest scroll target time).
    var scrollAnchorSeconds: Int

    /// Builds display rows. `playbackPosition` from `ResumePositionStore` /
    /// `CDEpisode.playbackPosition` (0 when unknown).
    static func make(
        transcript: [TimedWord],
        intervals: [CensorInterval],
        playbackPosition: TimeInterval
    ) -> TranscriptViewModel
}
```

**Classification rules** (`TranscriptViewModel.make`):

1. **Skipped-ad candidate:** `source == .unrelatedContent && action == .skip` and
   overlap `word.start < interval.end && word.end > interval.start`.
2. **Mutual exclusion:** if skipped-ad candidate → `skippedAd = true`, `listened = false`
   (even when `end ≤ playbackPosition`). Else if `word.end ≤ playbackPosition` →
   `listened = true`. Else unmarked.
3. Profanity / mute intervals never set `skippedAd`.
4. **Scroll anchor:** when `playbackPosition > 0`, choose the word whose time range
   contains `playbackPosition`, else the last word with `end ≤ playbackPosition`, else
   index 0; set `scrollAnchorSeconds = Int(round(anchorWord.start))` (or
   `Int(round(playbackPosition))` if no words — AC8 band **28…32** for position
   **30.0**). When `playbackPosition <= 0`, anchor **0** (no auto-scroll required).

### 3. On-disk layout + invalidate rules

**Directory:** `{Application Support}/TranscriptCache/` (tests inject temp
`baseDirectory`).

**File path:** `{baseDirectory}/{safeStem}.json` where `safeStem =
DownloadPaths.fileNameStem(for: episodeID)` — **no** word-list fingerprint hash.

**Encoding:** JSON array of `TimedWord` (`word`, `start`, `end`) via `JSONEncoder` /
`JSONDecoder`. Round-trip tolerance for tests: **±0.0005 s** (Slice 07 / §8 fixture).

| Event | Behavior |
|-------|----------|
| Terminal cold-miss analyze completes | `store(fullTranscript, episodeID:)` **once** (overwrite) |
| Interval cache hit + transcript file present | **Do not** call `store` (leave existing file stable — Slice 26 AC2) |
| Interval cache hit + transcript file **missing** | **Backfill** — ASR or injected transcript → `store` once (task-020); do **not** re-derive / rewrite intervals |
| Progressive chunk mid-flight | **No** transcript write (ADR-021); affordance stays hidden |
| Word-list change → interval miss → re-ASR | Terminal complete **overwrites** transcript |
| `deleteDownload` / episode cache purge | `remove(episodeID:)` |
| Episode row / player affordance | `exists(episodeID:)` (or `load != nil`) |

**Why `episodeID` only:** ASR text is independent of matcher target words. Interval
cache remains fingerprint-keyed (ADR-005 / ADR-013). Transcript must not disappear
when the user edits the word list without re-running ASR; when ASR **does** re-run,
terminal overwrite refreshes both artifacts.

### 4. Pipeline integration

Inject `TranscriptCache` into `AnalysisPipeline` (default `applicationSupport` in
production factory; temp dirs in tests — same pattern as `IntervalCache`).

**Blocking cold miss** (existing non-progressive path): after building `union` and
`cache.store(intervals, …)`, call `transcriptCache.store(transcript, episodeID:)`.

**Chunked cold miss** (ADR-021): accumulate / hold `fullTranscript` in memory across
chunks; **only after the final chunk**, alongside `IntervalCache.store`, call
`transcriptCache.store(fullTranscript, episodeID:)`. Partial chunks must not write.

**Interval cache hit:** return cached intervals. If a transcript file already
exists, **omit** transcript `store` (Slice 26 AC2 — second `analyze` → ASR spy
**0** additional calls; loaded transcript `Equatable` to first persist). If the
transcript file is **missing** (legacy / pre–Slice 26 intervals), run ASR or use
an injected transcript and `store` once without rewriting intervals (task-020).

Public `analyze(...) → [CensorInterval]` return type **unchanged**.

### 5. Shell wiring + fixture

**Affordance gate:** Show `episode.viewTranscript` / `playback.viewTranscript` only
when `transcriptCache.exists(episodeID:)`. During progressive in-flight analysis
(no terminal file yet) both are absent — AC9 reuses
`-UITestFixtureProgressivePlayback`.

**Presentation:** `AppShellModel` owns sheet state (e.g. `transcriptSheetEpisodeID`).
On present:

1. `load` transcript (non-nil or do not present).
2. Load intervals from `IntervalCache` with current target words **or** use
   `PlaybackCoordinator.cachedIntervals` / last union when already prepared.
3. `playbackPosition = resumeStore.position(for:)` (fixture may preset).
4. Build `TranscriptViewModel.make(...)` → `TranscriptView`.

**`-UITestFixtureTranscript`:**

| Concern | Choice |
|---------|--------|
| Launch arg | `-UITestFixtureTranscript` |
| Feed / library | Implies Library (or feed) path so row 0 + full player are reachable |
| Transcript | **24** words, **2.5** s each, span **0…60** s |
| Intervals | ≥ 1 unrelated **skip** spanning **35.0–42.5** s (→ **3** skippedAd words) |
| Resume | `playbackPosition = 30.0` → **12** listened |
| No-transcript control | `-UITestFixtureTranscriptNoCache` — intervals + resume, omit transcript file (AC7). With cleaning on + play/prepare, task-020 backfills transcript so `episode.viewTranscript` appears. |
| Progressive negative | Separate launch: `-UITestFixtureProgressivePlayback` (AC9) |

Fast unit fixtures stay as pinned in the slice file (`spec-section8.input.json`;
synthetic 10-word ViewModel table).

### 6. Accessibility contract (binding for QA / UX)

| Identifier | Role |
|------------|------|
| `transcript.view` | Sheet root |
| `transcript.wordCount` | `accessibilityValue` = `"\(wordCount)"` |
| `transcript.listenedCount` | `accessibilityValue` = `"\(listenedCount)"` |
| `transcript.skippedAdCount` | `accessibilityValue` = `"\(skippedAdCount)"` |
| `transcript.scrollAnchor` | `accessibilityValue` = `"\(scrollAnchorSeconds)"` (Int) |
| `transcript.word_<index>` | Per-word cell; optional per-word listened suffix via `accessibilityValue` |
| `episode.viewTranscript` | Episode row affordance |
| `playback.viewTranscript` | Full-player affordance (content-tree overlay) |

Visual highlight colors live in `docs/slices/slice-26-ux.md` (Architect does not pin
hex here).

### 7. Verification architecture

| AC | Proof |
|----|-------|
| 1, 10 | `TranscriptCacheTests` — store/load §8 fixture; `remove` → nil |
| 2 | `AnalysisPipelineTests` — persist on analyze; cache hit ASR spy 0; transcript stable |
| 3 | `TranscriptViewModelTests` — listened 6; skippedAd 3; mutual exclusion |
| 4–8 | `TranscriptUITests` + `-UITestFixtureTranscript` |
| 9 | `TranscriptUITests` + `-UITestFixtureProgressivePlayback` |
| 11 | Full `scripts/verify.sh` |

No XCTSkip on core ACs. No live ASR / device listening gates.

## Consequences

- **Cross-cutting:** `AnalysisPipeline`, `AppShellModel`, `EpisodeListView`,
  `PlaybackControlsView`, download purge path — **not** parallelizable with other
  slices editing the same files.
- **ADR-005:** interval cache semantics unchanged; transcript is a sibling artifact
  with a simpler key.
- **ADR-021:** progressive cold path remains terminal-only for **both** interval and
  transcript writes; AC9 locks the affordance to post-terminal existence.
- **Legacy installs:** episodes with interval files but no transcript file show no
  affordance until the next ASR cold miss (word-list change or cleared interval cache).
- **Follow-ups (explicit OOS):** tap word → seek; progressive partial viewer;
  mini-player / CarPlay entry; search / copy / share; RSS-provided transcripts.

## Out of scope (explicit)

- Streaming-only episodes with no local analysis run
- In-transcript search, copy/share, speaker diarization, punctuation editing
- Tap word → seek / play from timestamp
- Highlighting profanity matches in transcript text
- CarPlay / lock-screen / mini-player transcript entry
- Server-side or RSS-provided transcripts
- Partial transcript display or persistence during in-flight analysis
