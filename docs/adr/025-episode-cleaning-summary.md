# ADR-025 — Episode cleaning summary: aggregation + channel-row cache binding

| Field | Value |
|-------|-------|
| **Status** | Accepted |
| **Date** | 2026-07-15 |
| **Supersedes** | — (extends [ADR-018](018-analysis-timeline.md) row chrome only; does **not** change timeline bucketing, progress seam, or complete→clear timeline contract) |
| **Builds on** | [ADR-000](000-foundations.md) §2 (AX / offline verify); [ADR-002](002-interval-scheduler.md) / [ADR-013](013-segmentation-integration.md) (`CensorInterval`, `IntervalSource`); [ADR-005](005-analysis-pipeline.md) / [ADR-024](024-device-whisper-base-en.md) (`IntervalCache` load keyed by episode + fingerprint); [ADR-015](015-app-shell-navigation.md) (`EpisodeListView` / `PodcastDetailView`); [ADR-018](018-analysis-timeline.md) (in-flight `analysisTimeline`; clear on terminal); [ADR-022](022-transcript-cache.md) (row affordance gated by on-disk complete artifact without requiring playback) |
| **Slice** | [slice-29-episode-cleaning-summary.md](../slices/slice-29-episode-cleaning-summary.md) |

## Context

After analysis completes, ADR-018 clears the episode-row timeline. Today the
channel list has no assertable post-complete summary of what was cleaned —
users must open the player, transcript, or seek bar to infer outcomes.

Slice 29 product pins (intake — do not re-litigate):

| Pin | Choice |
|-----|--------|
| Surface | Podcast detail episode rows only (`EpisodeListView` / `PodcastDetailView`) |
| “Processed” signal | Cleaning summary present (dedicated AX id) when cache hit; absent on miss |
| Profanity sections | Count of **all** `.profanity` intervals (mute **and** skip) |
| Ad sections | Count of **all** `.unrelatedContent` intervals |
| Ad duration | Sum of `(end − start)` for `.unrelatedContent`, ÷ **60**, display **`X.X min`** (one decimal) |
| Zeros | Cache hit with empty / no-hit intervals still shows **0** / **0** / **0.0 min** |
| In flight | Slice 20 timeline remains; summary **only** when analysis is complete (not analyzing that row) |

Acceptance is pure model math (AC1–AC3) plus UITest AX (AC4–AC6). No device
listening.

## Empirical validation

**No throwaway spike required.** Claims are:

- Pure `Double` filter + sum + one-decimal round-half-up over `[CensorInterval]`
- XCTest accessibility identifiers/values (same pattern as ADR-018 / ADR-022)

No new AVFoundation, ASR, StoreKit, CarPlay, or networking behavior is asserted.
Interval provenance remains fixture / `IntervalCache` seed — independent of
implementation (slice-pinned table).

## Decision

### 1. Module layout / file boundaries

| File | Target | Status | Responsibility |
|------|--------|--------|----------------|
| `PodWash/PodWash/CleaningSummaryModel.swift` | app | **new** | Pure aggregation + formatting from `[CensorInterval]`; **no SwiftUI** |
| `PodWash/PodWash/EpisodeListView.swift` | app | **changed** | Row hosts summary chrome; identifier `episode.cleaningSummary`; mutual exclusion with `analysisTimeline` |
| `PodWash/PodWash/PodcastDetailView.swift` / shell wiring | app | **changed (minimal)** | Pass cache-lookup / summary provider into `EpisodeListView` (same injection style as `transcriptExists`) |
| `PodWash/PodWash/AppShellModel.swift` (or thin adapter) | app | **changed (minimal)** | `IntervalCache.load(episodeID:targetWords:)` with current `SettingsStore.activeNormalizedTargetSet()` for channel-row episodes — **no** playback / coordinator required |
| `PodWash/PodWash/AnalysisUIViewModel.swift` | app | **changed (minimal)** | Expose in-flight gate helper if needed (`episodeRowShowsTimeline` already exists); do **not** store summary in the timeline snapshot |
| `PodWash/PodWash/FixtureCleaningSummary.swift` (or extend existing feed fixture) | app | **new / extended** | UITest launch path: seed `IntervalCache` with pinned intervals for row 0; control path with no cache; optional in-flight path reuses timeline fixture |
| `PodWash/PodWashTests/CleaningSummaryModelTests.swift` | test | **new (QA)** | AC1–AC3 |
| `PodWash/PodWashUITests/CleaningSummaryUITests.swift` | test | **new (QA)** | AC4–AC6 |

**Unchanged:** `IntervalCache` fingerprint / store shape, matcher / segmenter math,
`AnalysisTimelineModel` colors, playback schedule, transcript aggregates
(ADR-022), super seek bar mute markers (ADR-023), Library list / player / CarPlay
chrome.

### 2. Key types / public API sketch

```swift
/// Aggregated cleaning outcome for one episode’s cached interval list.
struct EpisodeCleaningSummary: Equatable, Sendable {
    var profanitySectionCount: Int
    var adSectionCount: Int
    /// Sum of `(end − start)` over `.unrelatedContent` intervals (seconds).
    var adDurationSeconds: Double
    /// Display string, e.g. `"1.5 min"`, `"0.0 min"`, `"0.8 min"`.
    var formattedAdMinutes: String
}

nonisolated enum CleaningSummaryModel {
    /// Aggregates from a **cache-hit** interval array (including empty `[]`).
    /// Callers must not invoke this for a cache miss (`load` → `nil`).
    static func summary(from intervals: [CensorInterval]) -> EpisodeCleaningSummary

    /// One-decimal round-half-up minutes string from seconds (AC3).
    static func formattedAdMinutes(adDurationSeconds: Double) -> String

    /// Machine-readable AX value for UITests (UX may refine label/hint).
    /// Exact: `profanity:N,ads:N,adMinutes:X.X` where `X.X` matches the
    /// numeric portion of `formattedAdMinutes` (no ` min` suffix).
    static func accessibilityValue(from summary: EpisodeCleaningSummary) -> String
}
```

### 3. Aggregation rules (normative)

Given intervals `I` from a successful `IntervalCache.load` (non-`nil`):

| Field | Rule |
|-------|------|
| `profanitySectionCount` | `I.filter { $0.source == .profanity }.count` — **any** `CensorAction` |
| `adSectionCount` | `I.filter { $0.source == .unrelatedContent }.count` — **any** action |
| `adDurationSeconds` | Sum of `max(0, end − start)` over `.unrelatedContent` only |
| `formattedAdMinutes` | See §4 |

Pinned fixture (slice AC1 — independent provenance):

| # | start | end | action | source |
|---|-------|-----|--------|--------|
| 1 | 10.0 | 11.0 | mute | profanity |
| 2 | 20.0 | 21.5 | mute | profanity |
| 3 | 30.0 | 90.0 | skip | unrelatedContent |
| 4 | 100.0 | 130.0 | skip | unrelatedContent |

Expected: `profanitySectionCount = 2`, `adSectionCount = 2`,
`adDurationSeconds = 90.0` (± **0.001**), `formattedAdMinutes = "1.5 min"`.

**Source filter pins (AC2):**

| Input | Profanity | Ads |
|-------|-----------|-----|
| `[]` | 0 | 0 → `"0.0 min"` |
| Only `.profanity` + `.skip` | increments | 0 |
| Only `.unrelatedContent` | **0** | increments |

Do **not** filter by Settings toggles at summary time — count what is on disk.
(ADR-013 already drops unrelated at analyze/store when disabled; playback remap
stays separate.)

### 4. Minute rounding (normative — AC3)

1. `minutes = adDurationSeconds / 60.0`
2. Round **half up** to **one** decimal place for **non-negative** durations:
   `rounded = floor(minutes * 10.0 + 0.5) / 10.0`
3. Format exactly one decimal digit + `" min"`:
   e.g. `String(format: "%.1f min", rounded)` → `"0.8 min"`, `"1.5 min"`, `"0.0 min"`.

Pinned: `adDurationSeconds = 45.0` → `45/60 = 0.75` → **`0.8 min`**.

Negative durations must not appear in cache; if `end < start`, contribute **0**
to the sum (`max(0, end − start)`).

### 5. Complete gate + row binding

**Show summary for episode `E` iff all of:**

1. `IntervalCache.load(episodeID: E, targetWords: currentTargets)` returns
   **non-`nil`** (cache **hit**, including empty `[]`).
2. Row is **not** in-flight: `!analysisViewModel.episodeRowShowsTimeline(episodeID: E)`
   (ADR-018: timeline present only while `analyzingEpisodeID == E` and snapshot ≠ nil).

**Hide / omit summary when:**

| Condition | Result |
|-----------|--------|
| Cache miss (`load` → `nil`) | No summary element (AC4) |
| Timeline in flight on that row | Timeline only; summary must **not** exist (AC6) |
| Fingerprint miss after word-list / ASR-pin change | Same as miss until re-analyze |

**Data source:** Disk `IntervalCache` + current target-word set — same lookup
shape as ADR-022 interval load for non-playing episodes. Do **not** require
`PlaybackCoordinator`, now-playing identity, or an active analyze task.

**Wiring preference** (mirror transcript affordance):

```swift
// AppShellModel (sketch)
func cleaningSummary(for episodeID: String) -> EpisodeCleaningSummary? {
    guard let intervals = intervalCache.load(
        episodeID: episodeID,
        targetWords: settingsStore.activeNormalizedTargetSet()
    ) else { return nil }
    return CleaningSummaryModel.summary(from: intervals)
}
```

Pass `cleaningSummary: ((String) -> EpisodeCleaningSummary?)?` (or equivalent)
into `PodcastDetailView` → `EpisodeListView`. Cell applies summary only when the
complete gate passes; refresh on analysis generation + when returning to the
channel screen (visible-row refresh is enough — no background poller).

After terminal analyze, `analyzingEpisodeID` clears (ADR-018); if the analyzer
stored intervals, the next `load` is a hit and the summary appears. Fixture
analyzers that return `[]` without `store` must **seed the cache** in the
cleaning-summary UITest fixture so AC5 is assertable without live ASR.

### 6. Episode row chrome (`EpisodeListView`)

Extend `EpisodeTableCell` analysis display (UIKit AX host — same lesson as
ADR-018 / transcript row):

| State | UI | Identifier | Notes |
|-------|-----|------------|-------|
| In flight + snapshot | Timeline | `analysisTimeline` | Unchanged ADR-018; summary **absent** |
| Complete + cache hit | Summary | `episode.cleaningSummary` | `accessibilityValue` = `CleaningSummaryModel.accessibilityValue` |
| Never analyzed (miss) | Neither summary nor timeline | — | AC4 |
| Complete + empty `[]` | Summary with zeros | `episode.cleaningSummary` | `profanity:0,ads:0,adMinutes:0.0` |

**Mutual exclusion:** A row must not expose both `analysisTimeline` and
`episode.cleaningSummary` at once.

**Accessibility value (pinned for AC5):**

```text
profanity:2,ads:2,adMinutes:1.5
```

UX owns visible copy / layout (`slice-29-ux.md`); Engineer must keep the
identifier + value contract above (or the exact strings UX documents if they
match this shape).

**Serialize:** Edits land in the episode-row accessory / analysis band only —
do not redesign Library navigation or player chrome.

### 7. Verification architecture

| Layer | What it proves |
|-------|----------------|
| `CleaningSummaryModelTests` | AC1–AC3 counts, filters, half-up formatting |
| `CleaningSummaryUITests` | AC4–AC6 presence / absence / AX value on channel fixture |
| Full `scripts/verify.sh` | Done gate |

No offline audio render. No XCTSkip on core ACs.

## Consequences

- **Cross-cutting:** `EpisodeListView` row accessory band — do not parallelize
  with another slice that owns the same chrome.
- **Cache miss after Settings word-list change** correctly hides the summary
  until re-analyze (fingerprint). Not a bug.
- **Empty analyzed episode** still shows a zero summary — “processed” signal is
  cache presence, not non-zero counts.
- **Playback / IntervalCache API** unchanged — read-only consumer.
- Fixture seeding must use the same `asrModelPin` + target set as the running
  app (ADR-024) or UITests see a miss.

## Out of scope (explicit)

- Full-player / mini-player / CarPlay / Library-list summary
- Transcript sheet aggregates (ADR-022)
- Super seek bar markers (ADR-023)
- “Minutes of profanity”
- Per-interval drill-down or re-run analysis from the summary
- Changing mute vs skip Settings defaults
