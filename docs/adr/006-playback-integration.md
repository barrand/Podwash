# ADR-006 — Playback integration: cache → scheduler → engine

| Field | Value |
|-------|-------|
| **Status** | Accepted |
| **Date** | 2026-07-09 |
| **Builds on** | [ADR-000](000-foundations.md) §1–§3 (audioMix, offline render, local files); [ADR-001](001-playback-engine.md) (`PlaybackEngine.applySchedule`, additive); [ADR-002](002-interval-scheduler.md) (ramp placement, `IntervalSchedule`); [ADR-005](005-analysis-pipeline.md) (`AnalysisPipeline`, `IntervalCache`) |

## Context

Slice 08 closes the loop between the analyze-episode pipeline (Slice 07) and the
interval scheduler + player (Slices 04/03). The crux:

- Cached interval **time bounds** from analysis drive `IntervalScheduler` during
  playback.
- The user's per-episode **action** (mute vs skip) is applied at playback time
  **without re-running** ASR or the matcher.
- Tests must prove wiring, offline-render quality, action toggling, and the
  no-intervals path — all offline (ADR-000 §2).

## Decision

### 1. Module layout

| File | Target | Status | Responsibility |
|------|--------|--------|----------------|
| `PodWash/PodWash/EpisodeAnalyzing.swift` | app | **new** | `EpisodeAnalyzing` protocol — thin seam so tests can spy on `analyze` call count without mocking ASR alone. |
| `PodWash/PodWash/PlaybackCoordinator.swift` | app | **new** | Loads intervals via pipeline (cache hit or miss), stores time bounds, maps `CensorAction` at playback, calls `PlaybackEngine.applySchedule`. |
| `PodWash/PodWash/AnalysisPipeline.swift` | app | **changed (conformance)** | Conforms to `EpisodeAnalyzing` (no behavior change). |
| `PodWash/PodWashTests/PlaybackIntegrationTests.swift` | PodWashTests | **new (QA)** | AC1–AC4 integration/unit tests. |
| `PodWash/PodWashTests/AudioMixRampInspector.swift` | PodWashTests | **new (QA)** | Test helper: extract mute ramp boundary times from `AVMutableAudioMix` for AC1 ±0.001 s asserts. |

No changes to `PlaybackEngine`, `IntervalScheduler`, or `IntervalCache` public surfaces.

### 2. Key types / API

```swift
/// Pipeline entry point for playback wiring (ADR-005 analyze overload with injection seam).
protocol EpisodeAnalyzing: Sendable {
    func analyze(
        episode: EpisodeIdentity,
        audioURL: URL,
        targetWords: Set<String>,
        injectedTranscript: [TimedWord]?
    ) async throws -> [CensorInterval]
}

extension AnalysisPipeline: EpisodeAnalyzing {}

/// Wires cached/pipeline intervals into the player with a swappable action setting.
@MainActor
final class PlaybackCoordinator {
    private let pipeline: any EpisodeAnalyzing
    private let engine: PlaybackEngine

    private(set) var cachedIntervals: [CensorInterval] = []
    private(set) var currentAction: CensorAction = .mute

    init(pipeline: any EpisodeAnalyzing, engine: PlaybackEngine)

    /// Runs `analyze` once (cache hit or miss), stores returned bounds, applies `action`.
    func preparePlayback(
        episode: EpisodeIdentity,
        audioURL: URL,
        targetWords: Set<String>,
        action: CensorAction = .mute,
        injectedTranscript: [TimedWord]? = nil
    ) async throws

    /// Re-maps stored bounds to `action` and re-applies schedule. **Does not** call `analyze`.
    func setAction(_ action: CensorAction) async
}
```

**`preparePlayback` algorithm:**

1. `let intervals = try await pipeline.analyze(...)` (respects cache — ADR-005).
2. Store `cachedIntervals = intervals` (time bounds + stored action from pipeline;
   typically `.mute` from `IntervalBuilder`).
3. Set `currentAction = action`.
4. Call private `applyCurrentSchedule()`.

**`setAction` algorithm:**

1. If `action == currentAction`, return.
2. Set `currentAction = action`.
3. Call `applyCurrentSchedule()` — **no pipeline / ASR / matcher invocation**.

**`applyCurrentSchedule` (private):**

1. Map bounds to the chosen action:
   `intervals.map { CensorInterval(start: $0.start, end: $0.end, action: currentAction) }`.
2. `await engine.applySchedule(IntervalSchedule(intervals: mapped))`.
3. When `mapped` is empty, `IntervalScheduler.makeAudioMix` returns `nil` and the
   engine clears `audioMix` (AC4).

### 3. AC1 — ramp boundary extraction (test helper)

ADR-002 §4 places fades **outside** interval bounds:

- Down-ramp `1 → 0` over `[s − f, s]` — **ends** at cached `start` (`s`).
- Up-ramp `0 → 1` over `[e, e + f]` — **starts** at cached `end` (`e`).

`AudioMixRampInspector` (test target) loads `AVMutableAudioMixInputParameters`,
iterates `volumeRamp(at:)` / `getVolumeRamp(...)`, and collects:

- **`muteOnsetBoundaries`**: each down-ramp's `timeRange.end.seconds` (the `s` values).
- **`muteReleaseBoundaries`**: each up-ramp's `timeRange.start.seconds` (the `e` values).

AC1 asserts every cached mute interval's `start` matches some onset boundary and
`end` matches some release boundary, each within **±0.001 s**. Test uses
`action: .mute` so ramps exist.

When `action: .skip`, `makeAudioMix` returns `nil` — AC1 uses mute action.

### 4. AC2 — offline render with pipeline intervals

Reuse `OfflineRenderRMS` (ADR-002 §7) and the pinned `sine-300hz-5s.wav` fixture.
Test flow:

1. `preparePlayback` with injected §8 transcript → pipeline returns
   `[{0.92, 1.87}, {2.92, 3.32}]`.
2. Offline-render the sine fixture with those **pipeline-returned** intervals
   (mute action).
3. Assert interior windows RMS **< 0.01** and exterior windows (≥ 0.030 s margin)
   RMS **> 0.25** — same thresholds as Slice 04 AC2.

### 5. AC3 — action toggle without reanalysis

Test uses `PipelineAnalyzeSpy` (test file) wrapping `AnalysisPipeline` and
counting `analyze` invocations, plus `ASRSpyTranscriber` (Slice 07).

1. `preparePlayback` with injected transcript, `action: .mute` — spy count = **1**
   (or **0** if cache pre-warmed; test uses fresh temp cache → **1**).
2. Record spy counts.
3. `await setAction(.skip)` then `await setAction(.mute)`.
4. Assert analyze spy **unchanged** and ASR spy **unchanged** after step 2.
5. Assert `engine.activeSchedule?.intervals` reflect `.skip` then `.mute` actions.

### 6. AC4 — no intervals

Target set that matches **no** transcript tokens (e.g. `{ "nonexistent" }`) →
pipeline returns `[]`. After `preparePlayback`:

- `engine.avPlayer.currentItem?.audioMix == nil`
- `engine.play()` + immediate `pause()` does not crash.

## Consequences

- **Slice 09 (analysis UI)** may call `preparePlayback` and expose action toggles
  via `setAction`.
- **Slice 11** may swap cache backing; coordinator keeps `(episode, targetWords)`
  → bounds semantics.
- **Slice 12+** extend `PlaybackEngine`; coordinator surface stays stable unless
  superseded.
- Fast suite stays **skipped = 0**; no new slow tests in this slice.
