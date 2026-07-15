# ADR-023 — Super seek bar mute markers

| Field | Value |
|-------|-------|
| **Status** | Accepted |
| **Date** | 2026-07-15 |
| **Supersedes** | — (extends [ADR-021](021-progressive-playback-super-seek-bar.md) §6 chrome only; does **not** change [ADR-018](018-analysis-timeline.md) yellow = `.unrelatedContent` rules, segment color enum, or progressive chunk contract) |
| **Builds on** | [ADR-000](000-foundations.md) §2 (AX / offline verify); [ADR-002](002-interval-scheduler.md) (`CensorInterval`); [ADR-013](013-segmentation-integration.md) (`IntervalSource` / `CensorAction`); [ADR-018](018-analysis-timeline.md) (12-segment colors + `ready/processing/pending` AX); [ADR-021](021-progressive-playback-super-seek-bar.md) (`SuperSeekBarModel` / `SuperSeekBarView` / `playback.superSeekBar`); [ADR-022](022-transcript-cache.md) (profanity stays unmarked in transcript text) |
| **Slice** | [slice-27-super-seek-bar-mute-markers.md](../slices/slice-27-super-seek-bar-mute-markers.md) |

## Context

Slice 25’s full-player super seek bar paints ADR-018 segment colors (green / blue /
grey / yellow). Yellow means **ad / unrelated** spans only. Profanity mute intervals
drive the audio mix but are invisible on the bar — users cannot see where language
will be cleaned without listening.

Slice 27 product pins (intake — do not re-litigate):

| Pin | Choice |
|-----|--------|
| What to mark | Cached intervals with `source == .profanity` **and** `action == .mute` only |
| Ads / skip | Unchanged — yellow buckets from `.unrelatedContent` only (ADR-018) |
| Skip-action profanity | **Out of scope** (mute markers only) |
| Progressive / in-flight | Markers only when timeline is **complete** (same gate as yellow) |
| Visual language | Distinct overlay ticks/markers — **not** a new `TimelineSegmentColor` |
| Entry | Full-player `playback.superSeekBar` only (mini-player OOS) |

Acceptance is pure model math (AC1–AC2) plus UITest AX (AC3–AC4). No device
listening.

## Empirical validation

**No throwaway spike required.** Claims are:

- Pure `Double` filter + normalize over `[CensorInterval]` / duration
- Composed accessibility strings (same XCTest pattern as ADR-018 / ADR-021)

No new AVFoundation, ASR, StoreKit, CarPlay, or networking behavior is asserted.
Interval provenance remains fixture / cache / coordinator — same as Slice 25.

## Decision

### 1. ADR-018 yellow is unchanged (explicit non-change)

| Concern | Rule |
|---------|------|
| Yellow paint | Still **only** when timeline is complete **and** a bucket overlaps an `adRange` from `.unrelatedContent` |
| Profanity | Must **not** create yellow (or any new segment color) |
| Mute markers | Separate overlay layer + AX key — orthogonal to `segmentColors` |

Do **not** add `.mute` / `.profanity` cases to `TimelineSegmentColor`. Do **not**
feed profanity ranges into `AnalysisProgressSnapshot.adRanges`.

### 2. Module layout / file boundaries

| File | Target | Status | Responsibility |
|------|--------|--------|----------------|
| `PodWash/PodWash/SuperSeekBarModel.swift` | app | **changed** | `MuteMarker`, filter+normalize, compose AX value with `muteMarkers:` suffix |
| `PodWash/PodWash/SuperSeekBarView.swift` | app | **changed** | Draw marker overlays; accept markers + complete gate inputs; publish composed AX |
| `PodWash/PodWash/PlaybackControlsView.swift` | app | **changed** | Pass mute intervals (or precomputed markers) into `SuperSeekBarView` |
| `PodWash/PodWash/AppShellModel.swift` | app | **changed (minimal)** | Expose applied/cached intervals for the now-playing episode to full-player chrome |
| `PodWash/PodWash/AppShellView.swift` | app | **changed (minimal)** | Wire intervals into `PlaybackControlsView` |
| `PodWash/PodWash/FixtureMuteMarkers.swift` (or extend an existing playback fixture) | app | **new / extended** | UITest launch path: complete snapshot + ≥ 1 profanity mute; ad-only control with yellow + **0** mutes |
| `PodWash/PodWashTests/SuperSeekBarMuteMarkerTests.swift` | test | **new (QA)** | AC1–AC2 |
| `PodWash/PodWashUITests/SuperSeekBarUITests.swift` | test | **new (QA)** | AC3–AC4 |
| Existing Progressive / Transcript UITests with **exact** terminal AX | test | **changed (QA)** | Terminal complete strings gain `,muteMarkers:N` (§5) |

**Unchanged:** `AnalysisTimelineModel` color rules, `IntervalScheduler` / matcher math,
`IntervalCache` keying, progressive chunk frontiers (ADR-021), transcript word
highlighting (ADR-022), mini-player interactive seek, CarPlay / lock-screen markers.

### 3. Key types / public API sketch

```swift
/// Normalized mute span on the seek bar ([0, 1] relative to episode duration).
struct MuteMarker: Equatable, Sendable {
    var startNormalized: Double
    var endNormalized: Double
}

nonisolated enum SuperSeekBarModel {
    // existing: normalizedPlayhead, remaining, clampedSeek…

    /// Intervals with `source == .profanity` && `action == .mute`, normalized by
    /// duration. Empty when `duration <= 0`. Does **not** apply the complete-only
    /// UI gate — caller supplies intervals only when markers should show.
    static func muteMarkers(
        from intervals: [CensorInterval],
        duration: Double
    ) -> [MuteMarker]

    /// Append `,muteMarkers:N` when `muteMarkerCount != nil`; otherwise return
    /// `timelineValue` unchanged (preserves in-flight exact AX strings).
    static func accessibilityValue(
        timelineValue: String,
        muteMarkerCount: Int?
    ) -> String
}
```

**Normalization (AC1):** For duration **120.0**, interval **[10.0, 11.0)** →
`startNormalized = 10/120`, `endNormalized = 11/120`, tolerance **±0.001**.
Clamp each edge into **[0, 1]** after divide; skip intervals with `end <= start`.

**Filter (AC2):**

| Input | Mute marker count |
|-------|-------------------|
| Two `.profanity` + `.mute` | **2** |
| Zero matching | **0** |
| Only `.unrelatedContent` (any action) | **0** |
| `.profanity` + `.skip` | **0** (OOS this slice) |

### 4. Complete-only gate + data wiring

**Show markers iff** all of:

1. Cleaning chrome is showing segment colors (`timelineColors != nil`).
2. Timeline is **complete**: `snapshot.processedEnd >= snapshot.episodeDuration`
   (same predicate ADR-018 uses for yellow).
3. Intervals come from the **applied / cached** schedule for the now-playing
   episode (`PlaybackCoordinator.cachedIntervals` or equivalent shell mirror —
   not a second analyze pass).

**In flight / progressive:** `muteMarkers` array empty for paint; AX omits the
`muteMarkers:` key (§5) so Slice 25 mid-run exact strings stay valid.

**Cleaning off / no snapshot:** no segment colors, no markers, no timeline AX
(unchanged ADR-021).

**Shell wiring:** `AppShellModel` exposes something like
`fullPlayerMuteIntervals: [CensorInterval]` (filtered or raw — view/model may
filter). Pass into `PlaybackControlsView` → `SuperSeekBarView`. Do **not** add
markers to `MiniPlayerBar`.

### 5. Accessibility contract

Keep a **single** AX element `playback.superSeekBar` with
`accessibilityElement(children: .ignore)` (no required child id). UX may still
document a visual-only overlay.

| Phase | `accessibilityValue` |
|-------|----------------------|
| In flight (colors on) | `ready:N,processing:N,pending:N` — **unchanged** (no `muteMarkers` key) |
| Complete (colors on) | `ready:N,processing:N,pending:N,muteMarkers:M` |
| Colors off | omit `accessibilityValue` (unchanged) |

Rules:

- `M` = `muteMarkers(…).count` after the complete gate (may be **0**).
- Always emit `,muteMarkers:M` on **complete** colored bars — including ad-only
  fixtures (`M == 0`) so AC4 can assert absence without relying on key omission.
- Segment triple remains parseable: existing parsers that read `ready` /
  `processing` / `pending` must ignore the trailing key (document for QA).
- Label / hint stay Slice 25 defaults unless UX adds a short mute-marker mention.

**Cross-suite exact matches:** any UITest that asserts terminal
`ready:12,processing:0,pending:0` **exactly** must be updated in this slice to
include `,muteMarkers:N` for that fixture’s mute count (often `0`). Mid-run
progressive asserts are unchanged.

### 6. Visual language (Architect constraints; UX owns pixels)

| Constraint | Detail |
|------------|--------|
| Layer | Overlay on top of the 12-segment fill + under/beside the playhead |
| Shape | Narrow tick or short vertical mark spanning marker `[start, end)` width (or a fixed-width tick at start if span is sub-pixel — UX picks; model still exposes start **and** end) |
| Color | Must be visually distinct from green / yellow / blue / grey fills (e.g. high-contrast tick — **not** yellow) |
| Interaction | Markers are **not** separate hit targets; tap-to-seek still uses the full bar + frontier clamp |

UX spec: `docs/slices/slice-27-ux.md`.

### 7. Verification architecture

| AC | Proof |
|----|-------|
| 1 | `SuperSeekBarMuteMarkerTests.testSingleMuteMarkerNormalized` — pure math ±0.001 |
| 2 | `…testMuteMarkerCountIgnoresAds` — count 2 / 0 / ads→0 |
| 3 | `SuperSeekBarUITests.testMuteMarkersExposedWhenProfanityMutePresent` — complete fixture, `muteMarkers` ≥ 1 within **5.0 s** |
| 4 | `…testMuteMarkersAbsentForAdsOnly` — yellow intact, `muteMarkers:0`, ready/processing/pending still parse |
| 5 | Full `scripts/verify.sh` |

No XCTSkip on core ACs. No RMS / listening gates for marker chrome.

## Consequences

- **ADR-018:** yellow semantics frozen; mute visibility is an overlay + AX suffix only.
- **ADR-021:** `SuperSeekBarModel` / view grow additive APIs; seek / frontier math unchanged.
- **ADR-022:** transcript still does not highlight profanity — markers live on the bar.
- **Cross-cutting:** edits to `SuperSeekBarView.swift` / `PlaybackControlsView.swift` /
  full-player wiring serialize with other player-chrome work (task-020 / slice-28 if
  they touch the same files).
- **Test churn:** terminal exact AX strings across Progressive / Transcript / Library
  UITests pick up `,muteMarkers:N` in this slice’s test-spec commit.

## Out of scope (explicit)

- Markers for `.profanity` + `.skip` or unrelated mute
- Painting mute spans as yellow / new segment colors
- Transcript word highlighting
- Mini-player / CarPlay / lock-screen mute markers
- Changing mute/skip algorithm or ASR model
- Continuous scrub or per-marker seek targets
