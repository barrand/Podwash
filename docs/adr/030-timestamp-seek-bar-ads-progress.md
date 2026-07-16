# ADR-030 — Timestamp seek-bar ads + analysis progress chrome

| Field | Value |
|-------|-------|
| **Status** | Accepted |
| **Date** | 2026-07-16 |
| **Supersedes** | [ADR-018](018-analysis-timeline.md) **player** yellow = whole-bucket overlap (episode-row timeline already retired by task-026; this ADR retires the same bucket-yellow rule on `SuperSeekBarView`). Revises [ADR-021](021-progressive-playback-super-seek-bar.md) §5–§6 in-flight segment-color / frontier-colored seek UX. Extends [ADR-023](023-super-seek-bar-mute-markers.md) overlay pattern for ads (yellow bands). Does **not** change progressive chunk size, first-chunk start gate, mute filter, or transcript `skippedAd` classification. |
| **Builds on** | [ADR-000](000-foundations.md) §2 (AX / offline verify); [ADR-013](013-segmentation-integration.md) (`IntervalSource.unrelatedContent`, `CensorAction.skip`); [ADR-018](018-analysis-timeline.md) (`AnalysisProgressSnapshot.processedEnd`); [ADR-021](021-progressive-playback-super-seek-bar.md) (`SuperSeekBarModel` / `SuperSeekBarView`, progressive start, frontier clamp); [ADR-022](022-transcript-cache.md) (`TranscriptViewModel` skip filter); [ADR-023](023-super-seek-bar-mute-markers.md) (mute overlay + AX suffix); [ADR-026](026-mini-player-super-seek-parity.md) (shared host) |
| **Slice** | [slice-33-timestamp-seek-bar-ads-progress.md](../slices/slice-33-timestamp-seek-bar-ads-progress.md) |
| **Numbering note** | Slice story originally reserved `028-…`; ADR-028 / ADR-029 were claimed by Slices 32 / smart-autoplay. This decision is **ADR-030**. |

## Context

Player chrome still paints ADR-018 **12-bucket** colors on `playback.superSeekBar` /
`miniPlayer.superSeekBar` while analysis is in flight (`ready:N,processing:N,pending:N`),
and at complete paints **whole-bucket yellow** whenever a bucket overlaps any
`adRange`. That misleads dogfood: a **30.0 s** preroll yellows multiple 10 s buckets
(or a long opening stretch) instead of ≈ **30/duration** of bar width. Transcript
`skippedAd` already uses the precise `.unrelatedContent` + `.skip` set users trust.

Slice 33 product pins (intake — do not re-litigate):

| Pin | Choice |
|-----|--------|
| In-flight segment colors | **Remove** — no green/blue/grey/yellow 12-bucket paint on player chrome |
| In-flight chrome | Analyzing affordance + **overall** analysis progress only |
| Complete chrome | Green content track + **timestamp-proportional yellow** ad bands + existing **red** mute markers |
| Yellow source | Applied `.unrelatedContent` **skip** intervals — **same set** as transcript `skippedAd` |
| Progressive **playback** | **Keep** — audio may start after first chunk; progress UI until complete, then swap to timestamp yellow/green |
| Seek while in flight | **Keep frontier clamp** to `processedEnd` on a simple playhead track — **no** grey-bucket territory UI |
| Mini player | Same complete paint; in-flight progress / analyzing — no separate false yellow |
| Segmenter / skip detection | **Out of scope** |
| CarPlay / lock screen | **Out of scope** |

Acceptance is pure model math (ACs 1–3) + chrome / progressive seams (ACs 4–5) +
UITest AX (ACs 6–7). No device listening.

## Empirical validation

**No throwaway spike required.** Claims are:

| Claim | How verified |
|-------|----------------|
| Timestamp-normalized yellow widths | Pure `Double` divide over `[CensorInterval]` / duration (same class as ADR-023 mute markers) |
| Parity with transcript `skippedAd` | Same filter predicate as `TranscriptViewModel.make` (`source == .unrelatedContent && action == .skip`) |
| Progress fraction | `processedEnd / duration` from existing `AnalysisProgressSnapshot` |
| Progressive start after first chunk | Existing Slice 25 / ADR-021 fixture gate — **retained**, without segment-color AX |

No new AVFoundation, ASR, StoreKit, CarPlay, or networking behavior is asserted.

## Decision

### 1. Player chrome modes (normative)

| Mode | Seek-bar paint | Progress chrome | Seek frontier |
|------|----------------|-----------------|---------------|
| **In flight** (`processedEnd < duration`, cleaning on, snapshot live) | **Colorless** track (existing cleaning-off grey fill) + playhead; **no** `TimelineSegmentColor` array; **no** yellow / mute overlays | Determinate control `playback.analysisProgress` (mini: `miniPlayer.analysisProgress`) | `processedEnd` (unchanged clamp) |
| **Complete / cache hit** (cleaning on) | **Solid green** content track + **yellow ad-band overlays** + **red mute markers** | Progress control **hidden** | `duration` |
| **Cleaning off / no snapshot** | Colorless track + playhead (unchanged ADR-021) | Hidden | `duration` |

**Retired on player chrome (full + mini):** publishing or consuming in-flight
`AnalysisTimelineModel.segmentColors` / `ready:N,processing:N,pending:N` for
`SuperSeekBarView`. `AppShellModel.fullPlayerTimelineColors` /
`miniPlayerTimelineColors` must return **`nil` while incomplete**, and must **not**
drive complete yellow via bucket overlap.

`AnalysisTimelineModel` may remain for non-player / legacy helpers; **player paint
must not** use bucket-yellow rules after this ADR.

### 2. Module layout / file boundaries

| File | Target | Status | Responsibility |
|------|--------|--------|----------------|
| `PodWash/PodWash/SuperSeekBarModel.swift` | app | **changed** | `AdBand`, `adBands(from:duration:)`, analysis-progress normalize, compose complete AX (ad bands + mute) |
| `PodWash/PodWash/SuperSeekBarView.swift` | app | **changed** | Complete: green base + yellow band overlays + mute overlays + playhead; in-flight: colorless + playhead; stop requiring `[TimelineSegmentColor]?` for player paint (replace with mode / green flag + bands) |
| `PodWash/PodWash/PlaybackControlsView.swift` | app | **changed** | Host progress chrome; pass ad bands from applied intervals; drop in-flight segment colors |
| `PodWash/PodWash/MiniPlayerBar.swift` | app | **changed** | Same complete / in-flight contract as full (ADR-026 shared host) |
| `PodWash/PodWash/AppShellModel.swift` | app | **changed** | Expose applied unrelated-skip intervals for bands; `timelineColors` nil in flight; progress fraction from snapshot; keep progressive play gate |
| `PodWash/PodWash/AnalysisProgressChrome.swift` (or fold into `SuperSeekBarModel`) | app | **new / additive** | Pure `normalizedProgress(processedEnd:duration:)` |
| Fixture(s) for complete preroll + mute | app | **new / extended** | UITest path: duration ≥ **600.0 s**, skip `[0.0, 30.0)`, optional mute; progressive fixture keeps first-chunk start without segment AX |
| `PodWash/PodWashTests/SuperSeekBarAdBandTests.swift` | test | **new (QA)** | ACs 1–3 |
| `PodWash/PodWashTests/AnalysisProgressChromeTests.swift` | test | **new (QA)** | AC4 |
| `PodWash/PodWashTests/ProgressivePlaybackTests.swift` | test | **changed (QA)** | AC5 — drop segment-color gate |
| `PodWash/PodWashUITests/SuperSeekBarUITests.swift` | test | **changed (QA)** | ACs 6–7; migrate bucket-yellow / in-flight triple asserts |

**Unchanged:** `AnalysisChunking.chunkSize` (**30.0**), `PlaybackCoordinator` progressive
schedule apply, mute filter (`.profanity` + `.mute`), transcript classification,
CarPlay / lock screen, episode-row chrome, segmenter quality.

### 3. Key types / public API sketch

```swift
/// Normalized ad / unrelated-skip span on the seek bar ([0, 1] relative to duration).
struct AdBand: Equatable, Sendable {
    var startNormalized: Double
    var endNormalized: Double
}

nonisolated enum SuperSeekBarModel {
    // existing: normalizedPlayhead, remaining, clampedSeek, muteMarkers…

    /// Intervals with `source == .unrelatedContent` && `action == .skip`,
    /// normalized by duration. Empty when `duration <= 0`.
    /// Same predicate as `TranscriptViewModel.make` skip set — caller supplies
    /// applied/cached intervals only when complete paint should show yellow.
    static func adBands(
        from intervals: [CensorInterval],
        duration: Double
    ) -> [AdBand]

    /// `processedEnd / duration` clamped to [0, 1]; `0` when `duration <= 0`.
    static func analysisProgress(
        processedEnd: Double,
        duration: Double
    ) -> Double

    /// Complete-bar AX (see §5). In-flight bar omits accessibilityValue (or
    /// playhead-only — UX may refine label; **must not** emit ready/processing/pending).
    static func accessibilityValue(
        adBands: [AdBand],
        muteMarkerCount: Int
    ) -> String
}
```

**Normalization (AC1):** duration **3600.0**, skip **`[0.0, 30.0)`** →
`startNormalized = 0`, `endNormalized = 30/3600` (± **0.002**). Clamp edges to
**[0, 1]**; skip intervals with `end <= start`.

**Filter:**

| Input | Ad band count |
|-------|----------------|
| `.unrelatedContent` + `.skip` | counted |
| `.unrelatedContent` + `.mute` | **0** (not transcript `skippedAd`) |
| `.profanity` (any action) | **0** (red mute path only) |
| Empty / `duration <= 0` | **0** |

**Parity (AC3):** Given the **same** applied skip list passed to `adBands` and to
`TranscriptViewModel.make`, every word with `skippedAd == true` must overlap at
least one band’s denormalized range, and every band must lie inside the union of
those skips (no extra yellow).

### 4. Complete-only yellow + data wiring

**Show yellow ad bands iff** all of:

1. Cleaning chrome is on and analysis is **complete**:
   `snapshot.processedEnd >= snapshot.episodeDuration` (or cache-hit complete with
   no in-flight snapshot — treat as complete).
2. Intervals come from the **applied / cached** schedule for the now-playing
   episode (`PlaybackCoordinator.cachedIntervals` / shell mirror — same source as
   mute markers and transcript).

**In flight:** `adBands` empty for paint; progress chrome owns the in-flight story.

**Do not** derive player yellow from `AnalysisProgressSnapshot.adRanges` bucket
overlap or from `TimelineSegmentColor.yellow`. Snapshot `adRanges` may still be
populated for other callers; **player paint ignores them**.

**Green base:** when complete + cleaning on, the track fill is a single green
content color (not 12 green buckets). Yellow and red are overlays (ADR-023 z-order
extended):

```text
green content track → yellow ad bands → red mute markers → playhead
```

### 5. Accessibility contract

#### Analysis progress (in flight only)

| Host | Identifier | `accessibilityValue` |
|------|------------|----------------------|
| Full player | `playback.analysisProgress` | Fraction string of `analysisProgress(processedEnd:duration:)` — tests assert within **±0.02** of `processedEnd/duration` (e.g. `"0.25"` or equivalent parseable decimal; UX may pin display formatting) |
| Mini player | `miniPlayer.analysisProgress` | Same grammar |

Hidden when complete / cleaning off / no snapshot.

#### Super seek bar

| Phase | Identifier (unchanged) | `accessibilityValue` |
|-------|------------------------|----------------------|
| In flight | `playback.superSeekBar` / `miniPlayer.superSeekBar` | **Omitted** (or UX-pinned playhead-only string with **no** `ready:` / `processing:` / `pending:` keys) |
| Complete | same | `adBands:N,<start>-<end>(,<start>-<end>)*,muteMarkers:M` |

**Complete value rules (pinned for QA):**

- `N` = `adBands.count` after the complete gate (may be **0**).
- Each band contributes one `<start>-<end>` token with normalized edges formatted to
  **4 decimal places** (half-open semantics match model; UITests may parse and
  compare within ± **0.002**).
- Always emit `,muteMarkers:M` on complete bars (ADR-023), including `M == 0`.
- Example preroll on 3600 s: `adBands:1,0.0000-0.0083,muteMarkers:0`.
- Example two bands: `adBands:2,0.0000-0.0083,0.5000-0.5167,muteMarkers:1`.

**Authorized migrations:** any UITest / unit asserting in-flight
`ready:N,processing:N,pending:N` on player super seek bars; terminal
`ready:12,…` bucket-complete strings; whole-bucket yellow asserts on the **player**
bar. Replace with progress-id / `adBands:` grammar above. Mid-run progressive
start-gate tests **keep** `processedEnd = 30` on **120 s** fixture (± **0.5 s**)
without segment-color AX (AC5).

### 6. Seek while in flight (Architect pin)

| Concern | Decision |
|---------|----------|
| Clamp | **Retain** `SuperSeekBarModel.clampedSeek(…, processedEnd:)` while incomplete |
| Grey-bucket UI | **Retired** — no pending/grey segment paint; colorless track is not “grey territory” |
| Slice 25 seek UITests | Migrate copy from “clamp to grey” → “clamp to analyzed frontier (`processedEnd`)”; drop segment triple setup asserts |
| ±15 s | Same frontier when incomplete (unchanged ADR-021) |

Progressive early play after the first chunk is **unchanged** (ADR-021 §4).

### 7. Visual language (Architect constraints; UX owns pixels)

| Layer | Constraint |
|-------|------------|
| In-flight progress | Determinate bar or ring reflecting overall progress; may sit above/beside the seek bar — UX pins layout in `slice-33-ux.md` |
| In-flight seek track | Colorless (existing system grey fill); playhead visible |
| Complete green | Single continuous content fill (not 12 buckets) |
| Yellow ad bands | Overlay bands spanning `[startNormalized, endNormalized)` — **timestamp width**, not bucket snaps; color distinct from mute red (system yellow / existing ad yellow token) |
| Red mute | Unchanged ADR-023 / `slice-27-ux.md` |
| Playhead | Always topmost |

Minimum band paint width may mirror mute’s **2 pt** floor for sub-pixel spans; model
still exposes true normalized start/end for unit tests.

### 8. Verification architecture

| AC | Proof |
|----|-------|
| 1 | `SuperSeekBarAdBandTests.testPrerollYellowWidthMatchesTimestampFraction` — 30/3600 ± 0.002 |
| 2 | `…testTwoAdBandsNoSpuriousCoverage` |
| 3 | `…testYellowBandsMatchTranscriptSkippedAdIntervals` |
| 4 | `AnalysisProgressChromeTests.testInFlightShowsProgressWithoutSegmentColors` — progress AX; **no** segment triple on super seek bar |
| 5 | `ProgressivePlaybackTests.testPlaybackStartsAfterFirstChunkWithoutSegmentColorGate` |
| 6 | `SuperSeekBarUITests.testCompleteBarYellowMatchesPrerollSkipNotWholeBuckets` — preroll 30 s, duration ≥ 600; not yellow for contiguous opening > 60 s |
| 7 | `…testMuteMarkersRemainWithTimestampAdBands` |
| 8 | Full `scripts/verify.sh` |

No XCTSkip on core ACs. No RMS / listening gates for this chrome change.

## Consequences

- **ADR-018:** player bucket-yellow and in-flight segment paint on the seek bar are
  superseded; snapshot / model helpers may linger but must not drive player chrome.
- **ADR-021:** progressive chunk + first-chunk start + frontier clamp stay; in-flight
  `ready/processing/pending` seek-bar AX and 12-segment progressive fixture
  expectations on the **player** bar are retired.
- **ADR-023:** mute overlay + `,muteMarkers:M` remain; complete AX prefix changes
  from segment triple → `adBands:…`.
- **ADR-026:** mini and full stay on one `SuperSeekBarView` paint path — both get
  colorless in-flight + timestamp complete.
- **ADR-022:** transcript skip filter is the semantic twin of yellow bands; no
  transcript UI change required.
- **Cross-cutting:** serialize edits to `SuperSeekBarView` / `PlaybackControlsView` /
  `MiniPlayerBar` / `AppShellModel` with any concurrent player-chrome slice.
- **Test churn:** Progressive / SuperSeekBar / mute UITests that assert segment
  triples or bucket yellow on the player bar migrate in Slice 33’s test-spec commit.

## Out of scope (explicit)

- Changing `HeuristicContentSegmenter` / ASR precision
- Reopening interval wiring as “skips wrong”
- CarPlay / lock-screen timeline
- Episode-row analysis timeline
- Auto-play on session restore (Slice 31)
- Redesigning mute-marker red semantics
- Continuous slider scrub
