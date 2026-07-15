# ADR-021 — Progressive playback + super seek bar

| Field | Value |
|-------|-------|
| **Status** | Accepted |
| **Date** | 2026-07-15 |
| **Supersedes** | — (revises [ADR-006](006-playback-integration.md) §2 so cold cleaning play may apply a **partial** schedule before `analyze` returns; revises [ADR-018](018-analysis-timeline.md) §6 so progressive analyze publishes **chunk-boundary** snapshots, not time-based ASR estimates. Does **not** replace ADR-005 / ADR-006 / ADR-018 / ADR-020 wholesale.) |
| **Builds on** | [ADR-000](000-foundations.md) §1–§3; [ADR-001](001-playback-engine.md) (seek surface); [ADR-002](002-interval-scheduler.md) (offline mix / RMS); [ADR-005](005-analysis-pipeline.md) (`AnalysisPipeline`, `IntervalCache`); [ADR-006](006-playback-integration.md) (`PlaybackCoordinator`, `EpisodeAnalyzing`); [ADR-013](013-segmentation-integration.md) (multi-source schedule); [ADR-018](018-analysis-timeline.md) (`AnalysisProgressSnapshot`, 12-segment colors / AX); [ADR-020](020-production-analysis-composition.md) (`AppShellModel.playEpisode` gates) |
| **Slice** | [slice-25-progressive-playback-super-seek-bar.md](../slices/slice-25-progressive-playback-super-seek-bar.md) |

## Context

Today, cleaning-on local play blocks audio until **full** `AnalysisPipeline.analyze`
returns: `AppShellModel` sets `isPreparingPlayback`, awaits
`PlaybackCoordinator.preparePlayback`, then (optionally) calls `engine.play()`.
`AnalysisPipeline` progress during live ASR is a **time-based estimate** (ADR-018 §6),
not WhisperKit chunk truth. Full-player chrome shows a non-interactive
`playbackAnalysisTimeline` strip plus elapsed-only time (Slice 03 deferred scrub).

Slice 25 product pins (intake — do not re-litigate):

| Pin | Choice |
|-----|--------|
| Start threshold | Playback may start after the **first 30.0 s** analysis chunk + intervals applied |
| Seek into grey / unprocessed | **Block** — clamp to `processedEnd` |
| Cleaning off / no local file | No progressive gate; elapsed + remaining + playhead only (no segment colors) |
| Cached analysis | Immediate full green/yellow; no in-flight progressive UI |
| Fixture | 120.0 s, 12 × 10.0 s buckets; first chunk `processedEnd = 30.0` |

Acceptance is fixture / injected-transcript assertable (ACs 1–8). Live WhisperKit
per-chunk wall-clock is **not** a Done gate.

## Empirical validation

**No throwaway spike required for this ADR’s Done-gate claims.** Progressive start,
frontier clamp, timeline AX strings, and partial-mute RMS are proven with:

- `SteppedEpisodeAnalyzer` / progressive fixture doubles (chunk snapshots + partial intervals)
- Injected transcripts sliced at **30.0 s** boundaries (AC8 offline render — Slice 08 /
  ADR-002 RMS pattern)
- Pure `Double` math in `SuperSeekBarModel` (AC7)

Production live ASR uses the same **logical** chunk contract (§3) by windowing the
local file and calling existing `ASRTranscribing.transcribe` per window. That path
reuses ADR-003’s measured WhisperKit stack; it does **not** introduce a new
framework claim that ACs assert. If Engineer discovers window-export / seek-range
transcription cannot meet dogfood latency, open a follow-up spike — do **not** weaken
the 30.0 s fixture pins or AC thresholds.

## Decision

### 1. Module layout / file boundaries

| File | Target | Status | Responsibility |
|------|--------|--------|----------------|
| `PodWash/PodWash/AnalysisChunking.swift` | app | **new** | `AnalysisChunking.chunkSize` (**30.0**), chunk index helpers, snapshot builders for chunk frontiers (`processedEnd`, processing window) |
| `PodWash/PodWash/AnalysisPipeline.swift` | app | **changed** | Cold-miss path runs **chunked** analyze (§3); emit real chunk snapshots + partial interval callbacks; **cache write only on terminal** complete; cache-hit path unchanged (immediate complete) |
| `PodWash/PodWash/EpisodeAnalyzing.swift` | app | **changed (additive)** | Optional progressive seam: partial-result handler type + default no-op so Instant / legacy spies compile |
| `PodWash/PodWash/SteppedEpisodeAnalyzer.swift` | app | **changed** | Progressive fixture: emit partial `[CensorInterval]` with each non-terminal snapshot (or dedicated progressive double — see §5); keep Slice 20 row-timeline behavior intact when intervals empty |
| `PodWash/PodWash/PlaybackCoordinator.swift` | app | **changed** | `preparePlaybackProgressive` (or `preparePlayback` progressive mode): apply / extend schedule per chunk; expose `canStartPlayback`, `processedEnd`; keep existing full `preparePlayback` semantics for callers that need blocking complete |
| `PodWash/PodWash/AppShellModel.swift` | app | **changed** | Cleaning + local cold play → progressive prepare; start `engine.play()` on first-chunk-ready when play was requested; keep `playbackAnalysisSnapshot` live until terminal; `isPreparingPlayback` may stay true while audio plays |
| `PodWash/PodWash/SuperSeekBarModel.swift` | app | **new** | Pure playhead normalization, remaining time, frontier clamp — **no SwiftUI** |
| `PodWash/PodWash/SuperSeekBarView.swift` | app | **new** | Full-player combined timeline + playhead + tap-to-seek host; identifier `playback.superSeekBar` |
| `PodWash/PodWash/PlaybackControlsView.swift` | app | **changed** | Replace full-player `playbackAnalysisTimeline` + elapsed-only strip with super seek bar + `playback.elapsed` + `playback.remaining`; preserve transport ids (`playback.playPause`, ±15, speed, sleep) |
| `PodWash/PodWash/PlaybackEngine.swift` | app | **unchanged public** | Seek still clamps to `[0, duration]`; **frontier clamp lives above the engine** (shell / controls) so engine stays ADR-001-stable |
| `PodWash/PodWash/FixtureProgressivePlayback.swift` | app | **new** | `-UITestFixtureProgressivePlayback` launch arg; pins 120 s / 12 buckets / ≥ 3 snapshots; freeze helper for mid-run seek AC |
| `PodWash/PodWashTests/ProgressivePlaybackTests.swift` | test | **new (QA)** | AC1, AC2, AC8 |
| `PodWash/PodWashTests/SuperSeekBarModelTests.swift` | test | **new (QA)** | AC7 |
| `PodWash/PodWashUITests/ProgressivePlaybackUITests.swift` | test | **new (QA)** | AC3–AC6 |

**Unchanged:** matcher / interval padding math, `IntervalScheduler` fade geometry,
`IntervalCache` keying, download-before-clean gate (ADR-008 / ADR-020), episode-row
`analysisTimeline` (Slice 20), mini-player interactive seek (OOS), CarPlay / lock-screen
seek chrome, streaming-only progressive analysis (OOS).

### 2. Key types / public API sketch

```swift
enum AnalysisChunking {
    /// Binding progressive chunk length (slice fixture + production contract).
    static let chunkSize: TimeInterval = 30.0

    /// Half-open processing window after completing `processedEnd`, one bucket wide
    /// for timeline paint (matches Slice 20 fixture: after 30 → processing [30, 40)).
    static func inFlightSnapshot(
        duration: Double,
        processedEnd: Double,
        bucketWidth: Double = /* duration / 12 */
    ) -> AnalysisProgressSnapshot
}

/// Invoked on the analyzer task (then hop to MainActor for UI) after each chunk’s
/// intervals are ready — **before** `analyze` returns.
typealias AnalysisPartialIntervalsHandler = @Sendable (
    _ intervals: [CensorInterval],
    _ snapshot: AnalysisProgressSnapshot
) -> Void

protocol EpisodeAnalyzing: Sendable {
    // existing analyze overloads…

    /// Progressive analyzers set this; Instant / cache-only doubles may leave nil.
    var onPartialIntervals: AnalysisPartialIntervalsHandler? { get set }
}

@MainActor
final class PlaybackCoordinator {
    private(set) var cachedIntervals: [CensorInterval] = []
    private(set) var canStartPlayback: Bool = false
    private(set) var processedEnd: Double = 0

    /// Cold progressive path: applies partial schedules as chunks complete;
    /// sets `canStartPlayback == true` after the first chunk (`processedEnd >= 30`
    /// on the 120 s fixture) **without** waiting for terminal analyze.
    func preparePlaybackProgressive(
        episode: EpisodeIdentity,
        audioURL: URL,
        targetWords: Set<String>,
        action: CensorAction = .mute,
        unrelatedContent: UnrelatedContentOptions = UnrelatedContentOptions(),
        injectedTranscript: [TimedWord]? = nil,
        onChunkReady: (@MainActor () -> Void)? = nil
    ) async throws

    /// Existing blocking prepare (cache hit / callers that need full intervals first).
    func preparePlayback(...) async throws
}

enum SuperSeekBarModel {
    /// elapsed / duration → normalized playhead in [0, 1] (AC7: 15/120 → 0.125 ± 0.02).
    static func normalizedPlayhead(elapsed: Double, duration: Double) -> Double

    /// max(0, duration − elapsed); UI formats whole seconds for `playback.remaining`.
    static func remaining(elapsed: Double, duration: Double) -> Double

    /// Clamp requested seek into [0, processedEnd] (AC7: 90 → 60 ± 0.5 when frontier 60).
    static func clampedSeek(requested: Double, processedEnd: Double) -> Double
}
```

**`AnalysisProgressSnapshot`:** unchanged shape from ADR-018. Progressive emission
must set `processedEnd` / `processingStart` / `processingEnd` from **chunk math**,
not from ADR-018’s 350 ms time-based estimator. Terminal snapshot still uses
`AnalysisTimelineModel.completeSnapshot` (yellow from unrelated spans).

### 3. Chunked analysis algorithm

**Constant:** `AnalysisChunking.chunkSize = 30.0` (tests pin this; do not change
without superseding this ADR + slice fixture strategy).

**Cache hit:** Load full union → emit complete snapshot → return projected intervals
→ `canStartPlayback = true` immediately (no progressive UI). Same as today’s
blocking prepare from the shell’s POV.

**Cache miss (injected transcript or live ASR):**

1. Resolve `duration` (existing `AVURLAsset` path).
2. Accumulate `transcript: [TimedWord] = []`.
3. For `chunkEnd` in `30, 60, …, duration` (last chunk may be shorter):
   - **Injected:** append / consider words with `start < chunkEnd` (or equivalent
     half-open rule documented in tests); do not call ASR.
   - **Live:** export or window local audio for `[prevEnd, chunkEnd)`,
     `transcribe` that window, append words with times offset into episode time.
   - Build profanity + segmenter intervals from **accumulated** transcript
     (ADR-013 merge rules).
   - **Schedule-eligible set:** intervals with `end ≤ chunkEnd` (AC1). Drop or
     defer intervals that extend past the frontier until a later chunk covers them.
   - Emit `onProgress` / `onMainActorProgress` with chunk snapshot:
     - Non-terminal: `processedEnd = chunkEnd`, processing
       `[chunkEnd, min(chunkEnd + bucketWidth, duration))` (fixture: after 30 →
       `[30, 40)`; after 60 → `[60, 70)`).
     - Terminal: complete snapshot (`processedEnd = duration`, processing idle,
       `adRanges` from unrelated union).
   - Invoke `onPartialIntervals(eligible, snapshot)`.
4. **Only after the final chunk:** `cache.store(fullUnion, …)` then return projected
   intervals. **No partial cache writes** (keeps ADR-005 fingerprint semantics;
   Slice 26 transcript store stays terminal-only).

**Retire** `emitTimeBasedProgressDuringTranscription` on the progressive cold path.
Non-progressive / legacy callers of blocking `analyze` without partial handlers may
keep a start→complete pair only.

### 4. Progressive prepare + shell play gate

**`PlaybackCoordinator.preparePlaybackProgressive`:**

1. Reset `canStartPlayback = false`, `processedEnd = 0`, `cachedIntervals = []`.
2. Install `pipeline.onPartialIntervals` (and progress relay already used by shell).
3. On each partial:
   - `processedEnd = snapshot.processedEnd`
   - `await applySchedule(intervals: partial)` (same source remap as ADR-013)
   - `cachedIntervals = partial`
   - If `processedEnd >= AnalysisChunking.chunkSize` (or `>= duration` for short
     episodes): set `canStartPlayback = true`, invoke `onChunkReady` **once**.
4. Await `analyze` completion; apply final schedule; ensure `canStartPlayback == true`.
5. Clear partial handler.

**`AppShellModel` (cleaning on + local file + not fixture-skip):**

- Call `preparePlaybackProgressive` instead of blocking-only prepare.
- Keep `acceptingPlaybackProgress` / `playbackAnalysisSnapshot` updates for the
  whole in-flight window (including after audio starts).
- **Play policy:** when the user has requested play (`pendingPlayAfterPrepare` /
  `startPlaybackWhenReady` / transport tap) and `canStartPlayback` becomes true,
  call `engine.play()` **immediately** — do **not** wait for `analyze` return.
- `isPreparingPlayback` remains `true` until terminal prepare finishes (timeline
  still “in flight”); transport chrome must show **playing/paused** from
  `timeControlStatus` when audio is already playing (do not keep the analyzing-only
  glyph once `isPlaying`).
- Cleaning off / streaming-only / fixture library skip: unchanged ADR-020 gates;
  super seek bar without segment colors (§6).

### 5. Fixture: `-UITestFixtureProgressivePlayback`

| Concern | Choice |
|---------|--------|
| Launch arg | `-UITestFixtureProgressivePlayback` |
| Duration / buckets | **120.0 s**, **12** × **10.0 s** (Slice 20 geometry) |
| Analyzer | Progressive stepped double: snapshots (1) `processedEnd=30`, processing `[30,40)`; (2) `processedEnd=60`, processing `[60,70)`; (3) terminal `processedEnd=120` — with pacing so UITests observe mid states |
| Partial intervals | After snapshot 1: ≥ 1 interval, every `end ≤ 30.0` (AC1); AC8 uses injected transcript + real pipeline chunking or coordinator spy |
| Seek freeze | Test / fixture API to hold at snapshot 2 (`processedEnd=60`) for AC5 tap-to-seek |
| Cleaning + local audio | On (same production gates) |
| Feed / library | Follow existing fixture-feed patterns so full player is reachable |

AX expectations (reuse `AnalysisTimelineModel.accessibilityValue`):

| Phase | `playback.superSeekBar` value |
|-------|-------------------------------|
| First chunk (AC3) | `ready:3,processing:1,pending:8` |
| Mid freeze (AC5 setup) | `ready:6,processing:1,pending:5` |
| Terminal (AC4) | `ready:12,processing:0,pending:0` |

### 6. Super seek bar + seek policy

**Layout (UX owns pixels — `slice-25-ux.md`):** one full-player control combining
12-segment colors + playhead + elapsed + remaining. Identifier
`playback.superSeekBar` with `accessibilityValue` = timeline count string when
segment colors are shown.

**Identifier migration:** retire full-player `playbackAnalysisTimeline`. Existing
UITests that query it (e.g. Library timeline parity) must move to
`playback.superSeekBar` in this slice’s test-spec commit. Mini-player keeps
read-only `miniPlayerAnalysisTimeline` (no interactive super seek — OOS).

**Transport ids preserved:** `playback.elapsed` (Slice 03 whole-second string),
new `playback.remaining` (same formatting), `playback.playPause`, ±15, speed, sleep.

**Interaction:** tap-to-seek (or custom accessibility action documented by UX) —
**no** continuous slider scrub (Slice 03 precedent). Map tap X → requested seconds
via duration; pass through `SuperSeekBarModel.clampedSeek` using current
`processedEnd` from `playbackAnalysisSnapshot` (or coordinator).

**When to clamp:**

| Mode | Frontier |
|------|----------|
| Cleaning on, analysis in flight | `snapshot.processedEnd` |
| Cleaning on, complete / cache hit | `duration` (no effective clamp beyond engine) |
| Cleaning off / no colors | `duration` |

±15 s buttons and any shell `seek(to:)` used by the full player must apply the same
clamp when a frontier is active.

**Colors:** Slice 20 / ADR-018 contract unchanged (green / blue / grey / yellow rules).

### 7. Verification architecture

| AC | Proof |
|----|-------|
| 1–2 | `ProgressivePlaybackTests` — stepped/progressive double; `canStartPlayback` + `play()` before terminal `processedEnd = 120` |
| 3–6 | `ProgressivePlaybackUITests` — launch arg fixture; AX values + elapsed/remaining sum |
| 7 | `SuperSeekBarModelTests` — pure math |
| 8 | Offline render RMS **< 0.01** inside mute wholly in `[0, 30)` after chunk-1 schedule (ADR-002 helper) |
| 9 | Full `scripts/verify.sh` |

No XCTSkip on core ACs. No device listening / Skipper comparison gates.

## Consequences

- **Cross-cutting:** `PlaybackCoordinator` + `AppShellModel.playEpisode` + full-player
  chrome serialize with other player work; not parallelizable with slices editing
  the same files.
- **ADR-006:** blocking `preparePlayback` remains for cache-oriented / test callers;
  production cleaning cold play prefers progressive prepare.
- **ADR-018:** progressive cold analyze replaces time-based ASR progress estimates
  with chunk snapshots; episode-row stepped fixture behavior stays valid.
- **Task-011:** Halted — full-player timeline height / visibility superseded by super
  seek bar; do not reopen unless mini-player work is re-scoped.
- **Slice 26:** transcript persistence stays terminal-complete; partial ASR must not
  unlock transcript UI early (aligned with slice-26 OOS note).
- **Dogfood:** first audio after ~one WhisperKit window instead of full-episode ASR;
  seek cannot enter uncleaned grey tail by design.

## Out of scope (explicit)

- Changing when analysis is triggered (Slice 13 / ADR-020 policy)
- Progressive analysis without a local file
- CarPlay / lock-screen custom seek bar
- Mini-player interactive super seek bar
- Partial `IntervalCache` / transcript writes
- Re-encoding, `MTAudioProcessingTap`
- Weakening frontier block (product: block grey seeks)
