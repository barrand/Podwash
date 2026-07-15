# ADR-026 — Mini-player super seek bar parity (shared chrome)

| Field | Value |
|-------|-------|
| **Status** | Accepted |
| **Date** | 2026-07-15 |
| **Supersedes** | — (lifts **mini interactive seek OOS** from [ADR-021](021-progressive-playback-super-seek-bar.md) §6 / Out of scope; lifts **mini mute-marker OOS** from [ADR-023](023-super-seek-bar-mute-markers.md) §4 / Out of scope. Does **not** change seek/frontier math, mute filter, yellow = ads, or progressive chunk contract.) |
| **Builds on** | [ADR-000](000-foundations.md) §2 (AX / offline verify); [ADR-015](015-app-shell-navigation.md) (`MiniPlayerBar`); [ADR-018](018-analysis-timeline.md) (12-segment colors + heights); [ADR-021](021-progressive-playback-super-seek-bar.md) (`SuperSeekBarModel` / `SuperSeekBarView` / frontier clamp); [ADR-023](023-super-seek-bar-mute-markers.md) (mute overlays + `muteMarkers:` AX) |
| **Slice** | [slice-30-mini-player-super-seek-parity.md](../slices/slice-30-mini-player-super-seek-parity.md) |

## Context

Full-player chrome hosts interactive `SuperSeekBarView` (`playback.superSeekBar`)
with segment colors, playhead, frontier-clamped tap-to-seek (ADR-021), and
complete-only red mute-marker overlays + `,muteMarkers:N` AX (ADR-023).

The mini player still paints a **read-only** `AnalysisTimelineView`
(`miniPlayerAnalysisTimeline`) — no playhead, no seek, no mute markers. Users
must expand the full player to scrub or see red mute streaks.

Slice 30 product pins (intake — do not re-litigate):

| Pin | Choice |
|-----|--------|
| Scope | Full mini ↔ full parity: segments, mute overlays, playhead, tap-to-seek + frontier clamp |
| Codebase | **One** `SuperSeekBarView` (+ `SuperSeekBarModel`) in both hosts — height / layout / AX id params only; **no** second mute/seek paint path |
| Expand vs seek | Tap **title / artwork** (`miniPlayer`) expands; tap **seek bar** seeks; `miniPlayerPlayPause` unchanged |
| Identifiers | Full keeps `playback.superSeekBar`; mini retires `miniPlayerAnalysisTimeline` → `miniPlayer.superSeekBar` with **same** AX value grammar |
| Mute markers | Same ADR-023 filter + complete-only gate; mini and full `muteMarkers:N` match for the same now-playing episode |
| Episode-row timeline | OOS (unchanged) |
| CarPlay / lock screen | OOS |

Acceptance is UITest AX + seek clamp (ACs 1–5) plus a shared-host seam assert
(AC6). No device listening.

## Empirical validation

**No throwaway spike required.** Claims are:

- Re-hosting an existing SwiftUI view with parameterized height + accessibility id
- Reusing proven pure math (`SuperSeekBarModel` clamp / muteMarkers / AX compose)
- XCTest identifier / value parity (same pattern as ADR-021 / ADR-023)

No new AVFoundation, ASR, StoreKit, CarPlay, or networking behavior is asserted.

## Decision

### 1. Shared host architecture (single paint path)

| Rule | Detail |
|------|--------|
| Paint + seek + mute overlays | **Only** in `SuperSeekBarView` |
| Model math | **Only** in `SuperSeekBarModel` (unchanged APIs from ADR-021 / ADR-023) |
| Mini | `MiniPlayerBar` **hosts** `SuperSeekBarView` — does **not** draw mute ticks, playhead, or seek gestures privately |
| Full | `PlaybackControlsView` continues to host the same type |
| Retired for player chrome | Mini’s `AnalysisTimelineView` + id `miniPlayerAnalysisTimeline` |
| Unchanged | Episode-row `AnalysisTimelineView` / `AnalysisTimelineBarView` / id `analysisTimeline` |

**Parameterize `SuperSeekBarView`** (today hardcodes full-player height + id):

| Parameter | Full player | Mini player |
|-----------|-------------|-------------|
| `accessibilityIdentifier` | `playback.superSeekBar` | `miniPlayer.superSeekBar` |
| `barHeight` | `AnalysisTimelineModel.fullPlayerTimelineHeight` (≥ 20) | `AnalysisTimelineModel.miniPlayerTimelineHeight` (≥ 12) — UX may refine in `slice-30-ux.md`; do not invent a second paint type |
| Colors / elapsed / duration / processedEnd / muteMarkers / muteMarkerCountForAccessibility / onSeek | Same semantics as ADR-021 / ADR-023 | Same |

Playhead capsule / gesture hit area scale with `barHeight` (UX owns pixels;
Architect requires tap-to-seek still maps X → clamped seconds via
`SuperSeekBarModel.clampedSeek`).

**Optional DRY (not required for AC6):** a thin SwiftUI wrapper that only forwards
to `SuperSeekBarView` is allowed if named in tests, but the **assertable shared
type** is `SuperSeekBarView`. Do **not** duplicate mute-overlay drawing in
`AnalysisTimelineView` or `MiniPlayerBar`.

### 2. Module layout / file boundaries

| File | Target | Status | Responsibility |
|------|--------|--------|----------------|
| `PodWash/PodWash/SuperSeekBarView.swift` | app | **changed** | Accept `barHeight` + `accessibilityIdentifier` (defaults preserve full-player behavior); paint / seek / mute / AX unchanged otherwise |
| `PodWash/PodWash/MiniPlayerBar.swift` | app | **changed** | Replace `AnalysisTimelineView` with `SuperSeekBarView`; wire colors, elapsed, duration, frontier, mute markers, seek; keep expand / play-pause hit targets separate |
| `PodWash/PodWash/AppShellView.swift` | app | **changed** | Pass mini the same duration / processedEnd / mute intervals / clamped seek callback as full player |
| `PodWash/PodWash/AppShellModel.swift` | app | **changed (minimal)** | Expose mute intervals for **both** hosts (rename `fullPlayerMuteIntervals` → `nowPlayingMuteIntervals` or keep name but document shared use — either OK); reuse `superSeekDuration`, `superSeekProcessedEnd`, `seekClampedToProcessedFrontier` |
| `PodWash/PodWash/PlaybackControlsView.swift` | app | **changed (minimal)** | Pass explicit full-player height + `playback.superSeekBar` if defaults change; behavior unchanged |
| `PodWash/PodWash/SuperSeekBarModel.swift` | app | **unchanged** (preferred) | No new math required; optional extract of complete-gate helper only if both hosts duplicate the same predicate |
| `PodWash/PodWash/AnalysisTimelineView.swift` | app | **unchanged** | Remains for episode-row / any non-player use |
| `PodWash/PodWashTests/…` | test | **new / changed (QA)** | AC6 shared-host seam; migrate layout tests that assumed mini = `AnalysisTimelineView` only |
| `PodWash/PodWashUITests/…` | test | **new / changed (QA)** | ACs 1–5; migrate `LibraryUITests` off `miniPlayerAnalysisTimeline` |

**Unchanged:** progressive chunking, frontier clamp formula, mute filter
(`.profanity` + `.mute`, complete-only), ADR-018 yellow = ads, episode-row
timeline, CarPlay / lock screen, mute/skip algorithm.

### 3. Key types / public API sketch

```swift
struct SuperSeekBarView: View {
    let colors: [TimelineSegmentColor]?
    let elapsed: Double
    let duration: Double
    let processedEnd: Double
    let muteMarkers: [MuteMarker]
    let muteMarkerCountForAccessibility: Int?
    /// Defaults: AnalysisTimelineModel.fullPlayerTimelineHeight
    let barHeight: CGFloat
    /// Defaults: "playback.superSeekBar"
    let accessibilityIdentifier: String
    let onSeek: (Double) -> Void
    // …
}

struct MiniPlayerBar: View {
    // existing: engine, titles, isPreparingPlayback, onExpand, onTogglePlayPause
    let timelineColors: [TimelineSegmentColor]?
    let episodeDuration: Double
    let processedEnd: Double
    let muteIntervals: [CensorInterval]
    let onSeekTo: (Double) -> Void
    // …
}
```

**Mute complete-gate (identical in both hosts — copy from `PlaybackControlsView`):**

```swift
let timelineComplete = duration > 0 && processedEnd >= duration
let showMuteMarkerAX = timelineColors != nil && timelineComplete
let muteMarkers = showMuteMarkerAX
    ? SuperSeekBarModel.muteMarkers(from: muteIntervals, duration: duration)
    : []
let muteMarkerCountForAccessibility: Int? = showMuteMarkerAX ? muteMarkers.count : nil
```

Use the **raw** `processedEnd` from the analysis snapshot for the complete gate
(not the seek-frontier fallback that substitutes `duration` when `processedEnd`
is 0). Seek gesture still uses the frontier value passed as `processedEnd` into
`SuperSeekBarView` (same as full player today).

### 4. Expand vs seek hit targets

| Target | Identifier | Action |
|--------|------------|--------|
| Title + artwork row | `miniPlayer` | `onExpand` → present full player |
| Play / pause | `miniPlayerPlayPause` | Toggle (unchanged) |
| Super seek bar | `miniPlayer.superSeekBar` | Tap → `onSeekTo(clamped)`; **must not** expand |

Layout constraint: seek bar is a **sibling below** the title/play-pause row (same
as today’s timeline placement), not nested inside the `miniPlayer` expand
`Button`. Do not wrap the whole bar (including seek) in one expand control.

### 5. When the mini bar is visible

| Mode | Mini hosts `SuperSeekBarView`? | Segment colors | Mute AX |
|------|-------------------------------|----------------|---------|
| Mini player visible, cleaning on, snapshot present | **Yes** | ADR-018 colors | Complete → `,muteMarkers:N`; in flight → omit key |
| Mini player visible, cleaning off / no colors | **Yes** | Grey track + playhead + seek (ADR-021 cleaning-off) | No timeline / mute AX |
| Mini player hidden | No | — | — |

Do **not** hide the mini seek bar when colors are nil (today’s
`AnalysisTimelineView` early-exit). Seek + playhead must work without analysis
colors, matching full-player behavior.

### 6. Accessibility contract

| Host | Identifier | `accessibilityValue` grammar |
|------|------------|------------------------------|
| Full | `playback.superSeekBar` | Unchanged ADR-023 |
| Mini | `miniPlayer.superSeekBar` | **Identical** compose: in flight `ready:N,processing:N,pending:N`; complete `…,muteMarkers:M` |

Rules:

- Same `SuperSeekBarModel.accessibilityValue(timelineValue:muteMarkerCount:)` path.
- For the same now-playing episode at the same analysis phase, parsed
  `ready` / `processing` / `pending` / `muteMarkers` **must match** across hosts
  (ACs 1–3).
- Retire queries of `miniPlayerAnalysisTimeline` in Library / SuperSeek UITests
  (authorized migration).
- Label / hint: UX may shorten for mini; value grammar is Architect-pinned.

### 7. Shell wiring

`AppShellView` already passes mute intervals + clamped seek into
`PlaybackControlsView`. Extend the same seams into `MiniPlayerBar`:

```text
AppShellModel
  ├── miniPlayerTimelineColors / fullPlayerTimelineColors (same source)
  ├── superSeekDuration / superSeekProcessedEnd
  ├── nowPlayingMuteIntervals (cachedIntervals)
  └── seekClampedToProcessedFrontier(to:)
        │
        ├── MiniPlayerBar → SuperSeekBarView (miniPlayer.superSeekBar)
        └── PlaybackControlsView → SuperSeekBarView (playback.superSeekBar)
```

Fixtures: reuse `-UITestFixtureMuteMarkers` / progressive / library analysis
timeline launch paths already used by full-player ACs — no new framework fixture
required unless QA needs a mini-visible-only convenience (prefer existing).

### 8. Verification architecture

| AC | Proof |
|----|-------|
| 1 | UITest — mute-marker fixture; within **5.0 s**, `miniPlayer.superSeekBar` value includes `muteMarkers:` with count **≥ 1** (pinned **2** if fixture matches full) |
| 2 | UITest — expand; `playback.superSeekBar` mute count **equals** mini; segment triple matches |
| 3 | UITest — ads-only; mini terminal `muteMarkers:0`; segment sum **12** |
| 4 | UITest — tap mini bar past frontier; elapsed clamped within **±0.5 s** of `processedEnd` (same as Slice 25) |
| 5 | UITest — tap `miniPlayer` (not bar) still presents full player within **5.0 s** |
| 6 | Unit / compile-time seam — both hosts construct `SuperSeekBarView`; no mute overlay path in `MiniPlayerBar` / `AnalysisTimelineView` for player chrome |
| 7 | Full `scripts/verify.sh` |

No XCTSkip on core ACs. No RMS / listening gates for chrome parity.

## Consequences

- **ADR-021 / ADR-023:** mini interactive seek and mini mute markers are **in
  scope**; prior OOS lines are superseded by this ADR for player chrome only.
- **Task-011 / slice-25 UX:** mini is no longer a read-only strip — QA must migrate
  Library asserts that pin `miniPlayerAnalysisTimeline` or exact terminal strings
  without `muteMarkers:`.
- **Cross-cutting:** edits to `SuperSeekBarView.swift` / `MiniPlayerBar.swift` /
  `AppShellView.swift` serialize with other player-chrome work; not parallel with
  slices that edit those files concurrently.
- **ADR-018 heights:** mini/full height constants remain the default bar heights;
  UX may adjust mini height in `slice-30-ux.md` without a new ADR if paint stays
  in `SuperSeekBarView`.

## Out of scope (explicit)

- Episode-row `analysisTimeline` markers or removal
- CarPlay / lock-screen seek chrome
- Changing mute/skip algorithm, ASR, or ADR-018 yellow = ads
- Transcript word highlighting
- Interactive seek on episode rows
- Replacing full-player sheet chrome beyond sharing the bar view
- Continuous scrub (tap-to-seek only, ADR-021)
