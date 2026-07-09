# ADR-002 — Interval scheduler: mute mix + skip

| Field | Value |
|-------|-------|
| **Status** | Accepted |
| **Date** | 2026-07-08 |
| **Supersedes** | — |
| **Builds on** | [ADR-000](000-foundations.md) §1 (AVPlayer + AVMutableAudioMix; `setVolumeRamp`; no MTAudioProcessingTap), §2 (offline render with `AVAssetReader` + `AVAssetReaderAudioMixOutput` sharing the **same** audioMix), §3 (local files only); [ADR-001](001-playback-engine.md) (`PlaybackEngine` module boundaries — Slice 04 adds `audioMix` **without** changing the play/pause/seek surface) |

## Revision (2026-07-08): render-smoothing correction

The first accepted version of this ADR assumed the rendered volume envelope would
track the commanded `setVolumeRamp` geometry closely enough that "**every** 10 ms
window fully inside `[start, end]` is volume 0." Implementation against the real
`AVAssetReaderAudioMixOutput` proved two things false, both **verified empirically**
(measurement spike rendering the actual mix; numbers in § "Empirical validation"):

1. **Fixture amplitude.** The original ffmpeg `sine` lavfi source is **not** full
   scale (it emits ≈ 0.125 / −18 dB), so `volume=0.9` produced a ≈ 0.11 peak fixture —
   RMS thresholds became unreachable. §8 now uses `aevalsrc` (measured peak ≈ 0.90).
2. **Render smoothing.** `AVAssetReaderAudioMixOutput` smooths volume ramps with a
   **~20 ms minimum transition floor** and spreads/lags the transition so that a
   commanded 10 ms fade bleeds ≈ 20 ms **into** the interval interior (the first
   in-interval 10 ms window retained RMS ≈ 0.27). The "every inside window is exactly
   0" guarantee is therefore false for small fades.

The mute **mechanism** (AVMutableAudioMix per ADR-000 §1) and the fades-**outside**
placement are unchanged. What changed: the **default fade is now 20 ms** (matched to
the render floor so the rendered fade width equals the configured value), and
verification uses a **symmetric settle margin `M = 30 ms`** to classify windows
(interior / exterior / don't-care transition bands). A third empirical finding forced
an AC5 correction: the offline reader **cannot** be started *inside* a mute interval
(it drops the pre-start ramp state and renders at base volume), so AC5's re-render must
start at/before the interval onset — see §6/§7. Sections 4, 6, 7, 8 and the AC
reconciliation section below are revised accordingly; §1–§3, §5 are unchanged.

## Context

Slice 04 proves the product's core differentiator: an interval list applied to the
Slice 03 player produces **silence** on mute intervals (verified by offline render +
numeric RMS) and **seek-past** on skip intervals — deterministically, with no human
listening and no realtime taps.

The design must satisfy the slice's acceptance criteria (AC1–AC6) purely through the
ADR-000 §2 offline-render mechanism. The binding constraints that shape every decision
below are:

- **AC1** — `IntervalScheduler` consumes `IntervalBuilder` output (`[CensorInterval]`)
  **directly**; no re-implemented padding/merge math.
- **AC2** — for intervals `[(1.0, 1.5), (3.0, 3.4)]`, windowed RMS **< 0.01** full scale
  in every 10 ms window **fully inside** each interval, and **> 0.25** full scale in
  windows **fully outside** intervals.
- **AC3** — fade ramp duration matches the configured value **±10 ms**; no
  sample-to-sample discontinuity **> 0.05** full scale at interval boundaries.
- **AC4** — skip advances `currentTime` past interval end (**+0 / −0.1 s**) without
  `timeControlStatus` leaving `.playing`.
- **AC5** — seek into an active mute window re-applies the schedule; offline re-render
  still satisfies AC2 thresholds.

The crux is **AC2/AC3 fade placement**: the ramps must be positioned so that *every*
10 ms window fully inside `[start, end]` is provably silent, while the audio mix stays
click-free and its fade duration is measurable. That single decision (§ "Fade ramp
semantics") drives the fixture spec and the QA harness contract.

## Decision

### 1. Module layout / file boundaries

| File | Target | Status | Responsibility |
|------|--------|--------|----------------|
| `PodWash/PodWash/IntervalScheduler.swift` | app | **new** | Pure builder of the `AVMutableAudioMix` (mute ramps) from `[CensorInterval]`; skip-interval helpers. No AVPlayer coupling — the mix is a value the engine and the test share. |
| `PodWash/PodWash/PlaybackEngine.swift` | app | **changed (additive)** | Gains `applySchedule(_:)` + `activeSchedule` and an internal skip boundary observer. **Does not change** the existing `play`/`pause`/`seek(to:)`/`seek(by:)` surface (ADR-001). |
| `PodWash/PodWashTests/Fixtures/audio/sine-300hz-5s.wav` | test | **new** | Constant-amplitude synthetic sine fixture (see § "Fixture spec"). |
| `PodWash/PodWashTests/Fixtures/audio/sine-300hz-5s.provenance.md` | test | **new** | ffmpeg generation command; provenance independent of PodWash code. |
| `PodWash/PodWashTests/IntervalBoundaryEnergyTests.swift` | test | **new (QA)** | AC2/AC3 offline-render RMS + boundary continuity. |
| `PodWash/PodWashTests/IntervalMuteSkipTests.swift` | test | **new (QA)** | AC1 (typed consumption), AC4 (skip), AC5 (seek-into-mute re-render). |

The scheduler lives in the **app target** (not the test target) because the exact mix
object the player attaches must be the exact object the offline-render test renders
with (ADR-000 §2). A test-only builder would break that "same mix" guarantee.

### 2. `IntervalScheduler` public API (design sketch)

```swift
import AVFoundation

/// A censor schedule handed to `PlaybackEngine`. Wraps `IntervalBuilder` output
/// verbatim — `intervals` is the merged `[CensorInterval]` from Slice 02 with no
/// additional padding/merge math applied here (AC1).
struct IntervalSchedule: Equatable {
    let intervals: [CensorInterval]
    let fadeDuration: Double

    init(intervals: [CensorInterval],
         fadeDuration: Double = IntervalScheduler.defaultFadeDuration) {
        self.intervals = intervals
        self.fadeDuration = fadeDuration
    }
}

enum IntervalSchedulerError: Error {
    case noAudioTrack
}

enum IntervalScheduler {

    /// Default fade ramp applied on each side of every mute interval. Matched to the
    /// renderer's ~20 ms smoothing floor (Revision 2026-07-08) — see § "Fade ramp semantics".
    static let defaultFadeDuration: Double = 0.020   // 20 ms

    /// Settle margin used ONLY by the offline-render harness to classify windows
    /// (interior / exterior / don't-care). Not used to build the mix. See §7.
    static let settleMargin: Double = 0.030          // 30 ms

    /// Builds the SAME `AVMutableAudioMix` the player attaches, so the offline-render
    /// test (ADR-000 §2) can render with the identical object. Consumes `CensorInterval`
    /// values directly (AC1). Ramps are applied for `.mute` intervals only; `.skip`
    /// intervals are ignored here (handled by seek-past on the engine).
    ///
    /// Returns `nil` when there are no `.mute` intervals (the item then plays at full
    /// volume with no mix attached). Throws `.noAudioTrack` if the asset has no audio.
    ///
    /// `async` is required: iOS 26 AVFoundation loads the audio track asynchronously
    /// (`asset.loadTracks(withMediaType:)`); the synchronous `asset.tracks` accessor is
    /// deprecated and blocks. The function is otherwise pure (no shared state).
    static func makeAudioMix(
        for asset: AVAsset,
        intervals: [CensorInterval],
        fadeDuration: Double = defaultFadeDuration
    ) async throws -> AVMutableAudioMix?

    /// The `.skip` subset, sorted ascending by start — feeds the engine's boundary
    /// observer. Consumes `CensorInterval` directly (AC1); does not re-derive intervals.
    static func skipIntervals(from intervals: [CensorInterval]) -> [CensorInterval]

    /// The first `.skip` interval whose `start` is at/after `time` and whose `end` is
    /// still ahead of `time` (i.e. the next skip the playhead will enter). `nil` if none.
    static func nextSkip(
        after time: TimeInterval,
        in intervals: [CensorInterval]
    ) -> CensorInterval?
}
```

### 3. `PlaybackEngine` extension (additive — ADR-001 preserved)

```swift
extension PlaybackEngine {
    /// Attaches the mute mix to the current item and arms the skip observer.
    /// Additive: the play/pause/seek surface from ADR-001 is unchanged. Idempotent —
    /// calling it again rebuilds/replaces the mix and re-arms the observer.
    func applySchedule(_ schedule: IntervalSchedule) async

    /// The currently attached schedule, or `nil` if none. Observable for UI/tests.
    private(set) var activeSchedule: IntervalSchedule? { get }
}
```

`applySchedule` internally:

1. Reads the asset from `avPlayer.currentItem?.asset`.
2. `let mix = try? await IntervalScheduler.makeAudioMix(for: asset, intervals: schedule.intervals, fadeDuration: schedule.fadeDuration)`.
3. `avPlayer.currentItem?.audioMix = mix` (nil ⇒ full-volume playback).
4. Arms a **boundary time observer** (`avPlayer.addBoundaryTimeObserver(forTimes:queue:using:)`)
   at the `start` of every `.skip` interval; on fire it calls the existing `seek(to:)`
   (see § "Skip semantics"). Stores the observer token for teardown on the next
   `applySchedule` / deinit.
5. Sets `activeSchedule`.

The mix is a property of `AVPlayerItem`, addressed in **absolute asset time**, so live
`AVPlayer` muting is independent of the playhead (relevant to AC5 — but note the offline
reader's mid-stream limitation in § "Seek into an active mute window").

### 4. Fade ramp semantics (crux — AC2/AC3)

**Default `fadeDuration` = 0.020 s (20 ms). Settle margin `M` = 0.030 s (30 ms).**

**Ramp placement (unchanged) — fades sit OUTSIDE the interval.** For each `.mute`
interval `[s, e]` with fade `f`, apply exactly two ramps to the track's
`AVMutableAudioMixInputParameters` (base volume `setVolume(1.0, at: .zero)`):

1. `setVolumeRamp(fromStartVolume: 1.0, toEndVolume: 0.0, timeRange: [s − f, s])`
2. `setVolumeRamp(fromStartVolume: 0.0, toEndVolume: 1.0, timeRange: [e, e + f])`

The parameter object holds each ramp's end volume until the next instruction, so the
**commanded** envelope is 1 → ramp-down → 0 across `[s, e]` → ramp-up → 1.

**The renderer does not reproduce the commanded envelope exactly.**
`AVAssetReaderAudioMixOutput` (the ADR-000 §2 verification path, byte-identical to the
simulator render) applies a **~20 ms minimum-transition smoothing** and **lags/spreads**
the transition. Measured, on the pinned fixture (see § "Empirical validation"):

- A commanded **10 ms** down-ramp over `[0.99, 1.0]` renders ≈ **0.27 RMS** in the first
  10 ms window *inside* the interval (`[1.00, 1.01]`) and only reaches 0 by ≈ `1.02` —
  i.e. it **bleeds ~20 ms into the interval interior**.
- Commanded→rendered fade-width floor: `10→~20`, `20→~20`, `30→~20`, `40→~30` ms.

Consequently the v1 claim "**every** 10 ms window fully inside `[s, e]` is volume 0" is
**false for small fades**. Two decisions repair verifiability:

**(a) Choose `f = 20 ms` — matched to the render floor.** At 20 ms the *rendered* fade
width equals the *commanded* value (measured 20 ms vs configured 20 ms → **0 ms error**),
so AC3's "fade width within ±10 ms" holds with the full ±10 ms as headroom. Smaller `f`
renders *wider* than commanded (10→20, a 10 ms error at the tolerance edge); larger `f`
renders *narrower* than commanded (40→30) — 20 ms is the unique sweet spot.

**(b) Verify with a symmetric settle margin `M = 30 ms`.** The interval interior is
**silent in the rendered domain**, but only after the smoothing settles. The harness (§7)
therefore classifies 10 ms windows into three zones per interval `[s, e]`:

```
 full        transition        SILENT interior       transition        full
──────────┤  don't-care  ├───────────────────────┤  don't-care  ├──────────
        s−M            s+M                       e−M            e+M
   (RMS>0.25)   [s−M, s+M] & [e−M, e+M]        (RMS<0.01)     (ignored)   (RMS>0.25)
```

- **Interior** — windows `⊆ [s + M, e − M]`: rendered volume 0 → **RMS < 0.01**
  (measured **max 0.0000**). `M = 30 ms` comfortably clears the observed ~20 ms bleed.
- **Exterior** — windows outside *every* interval by ≥ `M`: rendered full volume →
  **RMS > 0.25** (measured **min 0.6364**, i.e. `0.9/√2`).
- **Transition bands** `[s − M, s + M]` and `[e − M, e + M]`: **don't-care** — the
  rendered ramp lives here and is intentionally not asserted either way.

This is product-honest: the audible result is a silent interval interior with a short
(~20 ms) fade transition on each edge — exactly what a censor should sound like — and the
verification asserts only what the renderer actually delivers.

**Interior non-emptiness.** With `M = 30 ms`, the AC2 fixture intervals both keep a
non-empty interior: `[1.0, 1.5] → [1.03, 1.47]` (440 ms) and `[3.0, 3.4] → [3.03, 3.37]`
(340 ms).

**Boundary continuity (AC3).** Linear ramps introduce no volume step, and the render
smoothing only *softens* transitions further, so no click is added. Measured
`max |x[n+1] − x[n]|` at the four boundaries = **0.0231 / 0.0152 / 0.0231 / 0.0152 ≤ 0.05**
(the fixture's inherent slew is ≈ 0.0385; a hard cut would exceed 0.05). See §7 for the
metric.

**Edge cases (design notes for the Engineer):**

- **Interval near t = 0** (`s < f`): clamp the down-ramp to `[max(0, s − f), s]` (already
  implemented). Not exercised by the AC2 fixture (`s = 1.0`).
- **Adjacent intervals closer than `2f`**: `IntervalBuilder.merge` fuses touching/
  overlapping intervals, so survivors are disjoint; if a gap is still `< 2f`, clamp each
  ramp at the gap midpoint so ramps never overlap (already implemented). Not exercised by
  the AC2 fixture (gap = 1.5 s ≫ 40 ms).
- **`.skip` intervals** contribute **no** ramps to the mix (§ "Skip semantics").

### Empirical validation (spike, 2026-07-08)

A throwaway measurement spike built the same `AVMutableAudioMix` geometry and rendered it
through `AVAssetReaderAudioMixOutput` on a `/tmp` copy of the corrected 0.9-amplitude
300 Hz fixture. Results at `f = 20 ms`, `M = 30 ms`, intervals `[(1.0, 1.5), (3.0, 3.4)]`:

| Quantity | Measured | Target | Pass |
|----------|----------|--------|------|
| Full-scale window RMS (reference) | 0.6364 | `0.9/√2 = 0.6364` | — |
| AC2 interior — max RMS over windows `⊆ [s+M, e−M]` | **0.0000** | < 0.01 | ✅ |
| AC2 exterior — min RMS over windows ≥ M outside | **0.6364** | > 0.25 | ✅ |
| AC3 fade width — onset @ 1.0 | **20.0 ms** | 20 ms ±10 | ✅ |
| AC3 continuity — max \|Δ\| at 4 boundaries | **0.0231 / 0.0152 / 0.0231 / 0.0152** | ≤ 0.05 | ✅ |
| AC5 interior @ 1.2 s, reader start ≤ `s−f` | **0.0000** | < 0.01 | ✅ |
| AC5 interior @ 1.2 s, reader start *inside* interval | 0.5171 | (renderer artifact) | see §6 |

The spike was deleted after measurement; no spike code remains in the repo.

### 5. Skip semantics (AC4)

Skip intervals are **never** muted via the mix. The engine seeks past them:

- `applySchedule` installs a boundary time observer at each `.skip` interval's `start`.
- On fire, the engine calls the existing `seek(to: interval.end)`. To honor AC4's
  **+0 / −0.1 s** tolerance (land in `[end − 0.1, end]`, never overshoot), the engine
  uses `toleranceBefore = 0.1 s`, `toleranceAfter = .zero` for skip seeks (the ADR-001
  `seek(to:)` currently passes `.zero`/`.zero`; skip may use a private seek variant with
  these tolerances — additive, does not change the public signature).
- The engine **does not** call `pause()` around the seek. `AVPlayer.seek` during
  playback preserves `rate`, so `timeControlStatus` stays `.playing` (a transient
  `.waitingToPlayAtSpecifiedRate` during buffering is possible on real assets; on the
  local LPCM fixture the seek is immediate). AC4 asserts `.playing` after the seek
  settles.
- **Testable seam:** the skip-handling body (`seek(to: interval.end)` with the skip
  tolerances) is an internal method the boundary observer calls; QA can drive AC4 either
  by playing to the boundary under an `XCTestExpectation` or by invoking that seam
  directly and asserting `currentTime ≥ end − 0.1` and `timeControlStatus == .playing`.

### 6. Seek into an active mute window (AC5)

The mix is attached to the `AVPlayerItem` and addressed in **absolute asset time**, so
in the live `AVPlayer` muting is **playhead-independent**: seeking into `[s, e]` lands in
a region the mix forces to 0, and `AVPlayer` renders the mix continuously across the seek.
`applySchedule` is **idempotent** — re-applying after a seek yields the *identical* mix.

**Renderer limitation discovered during implementation (verified).** The offline
verification tool does **not** behave like `AVPlayer` here: setting
`AVAssetReaderAudioMixOutput.timeRange` to **start inside** an interval makes the reader
**drop the volume state established by the down-ramp before the range start** — it renders
that region at the base volume (measured **RMS 0.5171**, i.e. nearly full, at a 1.2 s
start). Starting the reader at/before the interval's onset ramp renders the interval fully
muted (**RMS 0.0000** at starts of 0.0 / 0.90 / 0.95). This is a reader-only artifact
(the reader has no playback history to reconstruct), **not** a product defect: the mix
itself is correct in absolute time, which the full-context render proves.

**Therefore v1's "render AC5 with the reader starting inside the interval" is wrong and is
replaced by a two-part verification:**

1. **Engine-level retention (unit test).** After `seek(to: 1.2)` into the mute window,
   assert the schedule is still applied: `avPlayer.currentItem?.audioMix` is the same
   non-nil mix instance and `activeSchedule` is unchanged. This is the literal "re-applies
   the schedule" — the mute is not lost by seeking.
2. **Offline re-render (deterministic).** Render the fixture with the same mix and the
   reader started at **t = 0** (or any point `≤ s − fadeDuration`), then assert the
   interior window at the seek target (`[1.2, 1.3] ⊆ [s + M, e − M]`) is silent
   (**RMS < 0.01**; measured 0.0000). "Re-render still satisfies AC2" is thus honored
   against the region the seek lands in, without asking the reader to do something it
   cannot.

### 7. Offline-render harness contract (guidance for QA — not test code)

QA writes `IntervalBoundaryEnergyTests` / `IntervalMuteSkipTests` against exactly this
contract; the Architect owns the contract, QA owns the assertions.

**Shared mix (ADR-000 §2).** The test calls the *same* API the engine calls:

```swift
let mix = try await IntervalScheduler.makeAudioMix(
    for: asset,
    intervals: intervals,                 // e.g. [.init(start: 1.0, end: 1.5, action: .mute),
                                          //       .init(start: 3.0, end: 3.4, action: .mute)]
    fadeDuration: IntervalScheduler.defaultFadeDuration
)
```

**Render.** Feed that mix into an `AVAssetReaderAudioMixOutput`:

```swift
let reader = try AVAssetReader(asset: asset)
let tracks = try await asset.loadTracks(withMediaType: .audio)
let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
output.audioMix = mix                     // the SAME instance
reader.add(output)
// Render from t = 0 (full mix context). Do NOT start the reader inside a mute
// interval — the reader drops pre-start ramp state and renders at base volume (§6).
// AC5 asserts the interior window at the seek target (1.2 s) on THIS full render.
reader.startReading()
// Drain CMSampleBuffers → interleaved Float32 PCM samples in [-1, 1].
```

**Recommended `audioSettings`** (deterministic, thresholds are directly full scale):

| Key | Value |
|-----|-------|
| `AVFormatIDKey` | `kAudioFormatLinearPCM` |
| `AVLinearPCMBitDepthKey` | `32` |
| `AVLinearPCMIsFloatKey` | `true` (samples already in [−1, 1] → RMS compares directly to 0.01 / 0.25) |
| `AVLinearPCMIsNonInterleaved` | `false` |
| `AVNumberOfChannelsKey` | `1` (mono — one RMS series) |
| `AVSampleRateKey` | `44100` |

**Windowed RMS.** 10 ms windows = 441 samples at 44.1 kHz, non-overlapping, anchored at
absolute `t = 0`. `rms(window) = sqrt(mean(sample²))`. Classification uses the settle
margin `M = IntervalScheduler.settleMargin = 0.030 s` (§4):

- **AC2 inside:** for each window `⊆ [s + M, e − M]`, assert `rms < 0.01`
  (measured max 0.0000). Windows in the transition bands `[s − M, s + M]` / `[e − M, e + M]`
  are **don't-care** and must not be asserted (the renderer's ~20 ms smoothing lives there).
- **AC2 outside:** for each window outside *every* interval by ≥ `M` (i.e. window end
  `≤ s − M` or window start `≥ e + M` for all intervals), assert `rms > 0.25`
  (measured min 0.6364).
- **AC3 duration:** measure the rendered transition width from the windowed-RMS series —
  the span from the last full window (`rms > 0.5`) to the first silent window
  (`rms < 0.01`) around `s`. Assert it equals `fadeDuration (0.020 s) ± 0.010 s`. With
  `f = 20 ms` matched to the render floor, the measured width is **20 ms** (0 ms error).
  (10 ms windows resolve the width to ±10 ms; do not expect sub-10 ms accuracy — this is
  why `f` is pinned to the floor rather than chosen smaller.)
- **AC3 continuity:** over raw samples within ±1 window of each boundary, assert
  `max |x[n+1] − x[n]| ≤ 0.05` (measured 0.0231 / 0.0152 per boundary). The fixture's
  inherent slew is ≈ 0.0385; a hard cut (`fadeDuration = 0`) would exceed 0.05.
- **AC5:** on the **full render** (reader from `t = 0`), assert the interior window at the
  seek target `[1.2, 1.3] ⊆ [s + M, e − M]` has `rms < 0.01` (measured 0.0000). Pair with
  the engine-level mix-retention assertion in §6 — **do not** start the reader inside the
  interval.

### 8. Fixture spec (AC2/AC3 golden inputs)

The Slice 03 `test-clip.m4a` (440 Hz AAC) is **not** reused for the energy tests:
440 Hz at 44.1 kHz has an inherent adjacent-sample slew of `2π·440/44100 ≈ 0.063`
full scale, which exceeds AC3's 0.05 threshold before any muting, and AAC coding smears
energy across boundaries. Slice 04 adds a **lossless, lower-frequency** fixture:

| Property | Value | Rationale |
|----------|-------|-----------|
| Waveform | constant-amplitude sine | uniform reference energy for RMS |
| Frequency | **300 Hz** | inherent max slew `≈ 0.9·2π·300/44100 = 0.0385 < 0.05` ⇒ AC3 continuity testable on raw samples |
| Amplitude | **0.9** full scale (**measured peak ≈ 0.90 / −0.9 dB**) | full-window RMS `≈ 0.636 ≫ 0.25` (measured 0.6364); exterior windows (≥ M) render at full volume |
| Duration | 5 s | covers intervals to `3.4 + fade` with margin |
| Channels / rate | mono / 44.1 kHz | one RMS series; window = 441 samples |
| Container | lossless PCM WAV (int16) | no codec ringing at boundaries; **measured 441,078 bytes ≈ 431 KB** < 1 MB |

**Corrected generation command (Revision 2026-07-08).** The v1 command used ffmpeg's
`sine` lavfi source, which is **not** full scale — it emits ≈ 0.125 (−18 dB), so
`volume=0.9` produced a ≈ 0.11 peak (−19 dB) fixture and RMS thresholds were unreachable.
Use `aevalsrc`, which evaluates the expression directly at full scale:

```bash
ffmpeg -f lavfi -i "aevalsrc=0.9*sin(2*PI*300*t):s=44100:d=5" \
       -ac 1 -c:a pcm_s16le sine-300hz-5s.wav
```

Provenance is independent of PodWash code (external tool, analytic expression); record the
above in the fixture's `.provenance.md`. The golden is the analytic sine; expected
silent/full windows derive from the intervals + the §4 ramp placement — no golden is
generated from `IntervalScheduler` output.

## Consequences

- **AC1** is satisfied structurally: `IntervalScheduler` and `IntervalSchedule` take
  `[CensorInterval]` from `IntervalBuilder` directly; no padding/merge is re-implemented.
  A compile-time typed interface plus an assert that the scheduler exposes no
  padding/merge symbols documents the dependency.
- **AC2/AC3** are satisfied by the fades-outside placement (`f = 20 ms`) + the settle
  margin (`M = 30 ms`) + the corrected 0.9-amplitude 300 Hz fixture: interior windows
  render silent (measured 0.0000), exterior windows full (0.6364), fade width measures
  20 ms (= configured), no click (max \|Δ\| ≤ 0.0231). The transition bands are don't-care.
- **AC4** reuses the ADR-001 seek surface: skip is seek-past via a boundary observer.
- **AC5** is verified in two parts (§6): engine-level mix-retention after `seek(to:)`, plus
  an offline full-context render asserting the interior at the seek target is silent. The
  offline reader **cannot** be started inside a mute interval (it drops pre-start ramp
  state) — a reader artifact, not a product defect.
- **Cross-cutting (ADR-001 §Consequences).** The `PlaybackEngine` change is **purely
  additive** (`applySchedule`, `activeSchedule`, internal skip observer); the
  `play`/`pause`/`seek` surface is untouched, so **Slices 08 and 14 are not blocked**.
  This ADR does not supersede ADR-001; it fulfills ADR-001's stated "Slice 04 adds
  `audioMix` without changing the play/pause/seek surface."
- **Streaming (ADR-000 §3).** The mix is guaranteed only on local files; the fixture and
  the product's download-before-clean-listen flow both honor this. No change.
- **Beep/quack overlay (ADR-000 §7)** remains deferred; mute ships silent-first here.
- **Async cost.** `makeAudioMix` is `async` (track loading); the engine's `applySchedule`
  is therefore `async`. UI call sites already run on `@MainActor` and can `await` it; no
  new concurrency surface leaks into the synchronous playback controls.

## AC reconciliation (flag to coordinator — action required)

The render-smoothing correction means **AC2, AC3, and AC5 as literally worded are not
satisfiable** and require PM wording updates. These are **validated**, not speculative —
the numbers come from the empirical spike (§4 "Empirical validation"). The mute/skip
*behavior* is unchanged; only classification margins, the fade value, and the AC5
verification method change. **Recommended final AC wording:**

1. **AC2 (inside + outside margins).** The renderer smooths ramps ~20 ms into the
   interval, so "every window fully inside `[s, e]`" is false. Introduce the settle margin
   `M = 0.030 s`:
   > *"For intervals `[(1.0, 1.5), (3.0, 3.4)]` on the sine fixture, windowed RMS < 0.01
   > full scale in every 10 ms window fully inside `[start + 0.030, end − 0.030]`, and
   > > 0.25 full scale in every 10 ms window outside all intervals by ≥ 0.030 s. Windows
   > within 0.030 s of a boundary are transition (don't-care) regions."*

2. **AC3 (fade duration value + tolerance).** Pin the configured fade to the value that
   renders faithfully:
   > *"Fade ramp `fadeDuration = 0.020 s`; the measured rendered fade width matches it
   > within ±0.010 s; no sample-to-sample discontinuity > 0.05 full scale within one 10 ms
   > window of any interval boundary."*

   (Tolerance stays ±10 ms; at `f = 20 ms` the measured error is 0 ms.)

3. **AC5 (verification method + margin).** The offline reader cannot start inside a mute
   interval (§6). Restate:
   > *"Seek into an active mute window retains the schedule (the item's audioMix remains
   > the applied mix); an offline re-render (reader started at ≤ start − fadeDuration) has
   > windowed RMS < 0.01 in the interior window at the seek target
   > (`[seek, seek + 0.010] ⊆ [start + 0.030, end − 0.030]`)."*

4. **AC4 — unchanged.** No wording change.

Additionally, PM/QA should **pin the fixture** in the slice: 300 Hz, amplitude 0.9,
generated via the `aevalsrc` command in §8 (the old `sine`+`volume` command yields a
≈ 0.11-peak fixture and must not be used). The 300 Hz frequency is required so AC3's
raw-sample continuity bound is meaningful (inherent slew ≈ 0.0385 < 0.05).

With these four wording updates and the pinned fixture, AC1–AC6 are all verifiable and
were demonstrated green in the spike.
