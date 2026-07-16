# ADR-018 — Analysis timeline: progress seam, bucketing, episode-row binding

| Field | Value |
|-------|-------|
| **Status** | Accepted |
| **Date** | 2026-07-11 |
| **Supersedes** | — (retires Slice 09 row chrome identifier `analysisProgress` → `analysisTimeline`; does **not** replace [ADR-005](005-analysis-pipeline.md) / [ADR-006](006-playback-integration.md) analyze contracts) |
| **Builds on** | [ADR-000](000-foundations.md) §6 (verify.sh); [ADR-005](005-analysis-pipeline.md) (`AnalysisPipeline` / cache); [ADR-006](006-playback-integration.md) (`EpisodeAnalyzing`); [ADR-013](013-segmentation-integration.md) (`IntervalSource.unrelatedContent` → yellow `adRanges`); [ADR-015](015-app-shell-navigation.md) (`EpisodeListView` / Library chrome) |
| **Slice** | [slice-20-analysis-timeline.md](../slices/slice-20-analysis-timeline.md) |

## Context

Slice 20 replaces the Slice 09 spinner (`analysisProgress`) with a Skipper-style
**12-segment** timeline on the episode row while analysis is in flight. Product
pins (slice fixture strategy):

| Pin | Value |
|-----|-------|
| Duration / buckets | **120.0 s**, **12** × **10.0 s** |
| Mid-analysis colors | blue > green > grey; yellow **off** until complete |
| Complete yellow | bucket overlaps any `adRange` by **> 0 s** |
| AX value | `ready:N,processing:N,pending:N` (sums to segment count) |
| UI fixture | `-UITestFixtureAnalysisTimeline` implies feed; stepped snapshots |

Acceptance is pure model counts (AC1–AC2) plus UITest AX values from an injected
**stepped** analyzer (AC3–AC5) — no device, no Skipper comparison, no live ASR.

## Empirical validation

**No framework spike required.** Segment colors and AX strings are pure
`Double` interval math over a pinned snapshot — assertable offline without
AVFoundation, ASR, StoreKit, or networking. UITests assert accessibility
identifiers/values only (same XCTest pattern as Slice 09).

If Engineer later claims live WhisperKit chunk-progress fidelity, that needs a
separate measured spike; **out of scope** for Slice 20 (fixture double owns
progress emission).

## Decision

### 1. Module layout / file boundaries

| File | Target | Status | Responsibility |
|------|--------|--------|----------------|
| `PodWash/PodWash/AnalysisProgressSnapshot.swift` | app | **new** | `AnalysisProgressSnapshot`, `AdTimeRange` |
| `PodWash/PodWash/AnalysisTimelineModel.swift` | app | **new** | Pure bucketing + color assignment + AX string; **no SwiftUI** |
| `PodWash/PodWash/AnalysisTimelineView.swift` | app | **new** | Segmented bar (SwiftUI and/or UIKit twin — see §5) |
| `PodWash/PodWash/SteppedEpisodeAnalyzer.swift` | app | **new** | Fixture/test double: emits ≥ 3 pinned snapshots then returns `[]` |
| `PodWash/PodWash/AnalysisProgressPacing.swift` | app | **new** | Injectable wait between snapshots (`Immediate` vs `Fixture`) |
| `PodWash/PodWash/FixtureAnalysisTimeline.swift` | app | **new** | `-UITestFixtureAnalysisTimeline`; enables feed path; pins 120 s / 12 buckets |
| `PodWash/PodWash/AnalysisUIViewModel.swift` | app | **changed** | Hold current snapshot; widen analyzer to `any EpisodeAnalyzing`; wire progress |
| `PodWash/PodWash/EpisodeListView.swift` | app | **changed** | Row hosts timeline; identifier `analysisTimeline`; retire `analysisProgress` |
| `PodWash/PodWash/RootView.swift` | app | **changed** | Timeline fixture → `SteppedEpisodeAnalyzer` + auto-analyze on enable |
| `PodWash/PodWash/AppShellView.swift` / `AppShellModel.swift` | app | **changed (minimal)** | Production still uses instant/pipeline analyzer; no timeline fixture |
| `PodWash/PodWash/InstantEpisodeAnalyzer.swift` | app | **changed (additive)** | Emit a trivial start→complete pair (or single hold snapshot) so Slice 09 path keeps a valid timeline AX surface |
| `PodWash/PodWash/AnalysisPipeline.swift` | app | **changed (additive, optional)** | Publish **start** + **complete** snapshots via progress hook when duration known; no ASR chunk fidelity claim |
| `PodWash/PodWash/FixtureFeed.swift` | app | **changed (minimal)** | Treat timeline fixture like analysis fixture for feed enablement |
| `PodWash/PodWashTests/AnalysisTimelineModelTests.swift` | test | **new (QA)** | AC1–AC2 |
| `PodWash/PodWashUITests/AnalysisTimelineUITests.swift` | test | **new (QA)** | AC3–AC5 |
| `PodWash/PodWashUITests/AnalysisProgressUITests.swift` | test | **changed (QA)** | Migrate assertions off `analysisProgress` → `analysisTimeline` (full suite) |

**Unchanged:** `EpisodeAnalyzing.analyze(...)` return type (`[CensorInterval]`),
cache fingerprint math, trigger policy (Slice 13), segmentation quality,
mini-player / CarPlay chrome, brand tokens (Slice 21).

### 2. Key types / public API

```swift
struct AdTimeRange: Equatable, Sendable {
    var start: Double
    var end: Double
}

/// Progress published while analysis runs (Slice 20 seam).
struct AnalysisProgressSnapshot: Equatable, Sendable {
    var episodeDuration: Double
    var processedEnd: Double
    var processingStart: Double
    var processingEnd: Double
    var adRanges: [AdTimeRange]
}

enum TimelineSegmentColor: String, Equatable, Sendable {
    case green   // processed / "ready"
    case blue    // in-flight processing window
    case grey    // not yet scanned / "pending"
    case yellow  // ad / unrelated span — complete timelines only
}

enum AnalysisTimelineModel {
    static let defaultSegmentCount = 12

    /// Returns exactly `segmentCount` colors. Bucket width = duration / segmentCount.
    static func segmentColors(
        snapshot: AnalysisProgressSnapshot,
        segmentCount: Int = defaultSegmentCount
    ) -> [TimelineSegmentColor]

    /// `ready` = green + yellow; `processing` = blue; `pending` = grey.
    /// Counts always sum to `colors.count`.
    static func accessibilityValue(from colors: [TimelineSegmentColor]) -> String
}

protocol AnalysisProgressPacing: Sendable {
    func waitBetweenSnapshots() async
}

struct ImmediateAnalysisProgressPacing: AnalysisProgressPacing {
    func waitBetweenSnapshots() async { /* no-op — unit tests */ }
}

struct FixtureAnalysisProgressPacing: AnalysisProgressPacing {
    /// Short yields so XCTest can observe mid-run AX values; total analyze
    /// wall time must stay under AC4/AC5 budgets (≤ 5.0 s from toggle).
    func waitBetweenSnapshots() async
}

/// Progress hook invoked on the analyzer’s task before each snapshot is “current.”
typealias AnalysisProgressHandler = @Sendable (AnalysisProgressSnapshot) -> Void

final class SteppedEpisodeAnalyzer: EpisodeAnalyzing, @unchecked Sendable {
    let snapshots: [AnalysisProgressSnapshot]  // ≥ 3 for UI fixture
    let pacing: any AnalysisProgressPacing
    var onProgress: AnalysisProgressHandler?

    init(
        snapshots: [AnalysisProgressSnapshot],
        pacing: any AnalysisProgressPacing,
        onProgress: AnalysisProgressHandler? = nil
    )

    func analyze(...) async throws -> [CensorInterval]
    // For each snapshot: onProgress?(snap); await pacing.waitBetweenSnapshots()
    // Then return [].
}
```

**`AnalysisUIViewModel` surface (additive):**

```swift
@MainActor @Observable
final class AnalysisUIViewModel {
    // existing state…
    private(set) var progressSnapshot: AnalysisProgressSnapshot?

    init(
        store: any CleaningToggleStoring,
        analyzer: any EpisodeAnalyzing,  // widen from InstantEpisodeAnalyzer
        autoAnalyzeOnEpisodeEnable: Bool = false,
        settingsStore: SettingsStore = SettingsStore(),
        // When analyzer is SteppedEpisodeAnalyzer, VM assigns onProgress → publish snapshot
    )

    func episodeRowShowsTimeline(episodeID: String) -> Bool
    // true iff analyzingEpisodeID == episodeID && progressSnapshot != nil

    func episodeRowTimelineAccessibilityValue(episodeID: String) -> String?
    // AnalysisTimelineModel.accessibilityValue(from: colors) when showing timeline
}
```

**Progress wiring rule:** Before `analyze` returns, every progress-capable analyzer
calls `onProgress` (or the VM-installed handler) with each snapshot. The view
model sets `progressSnapshot`, bumps `contentGeneration`, and posts
`UIAccessibility.layoutChanged` (same cadence as today’s analyzing-window updates).
On analyze completion: clear `progressSnapshot`, clear `analyzingEpisodeID`, show
`cleaningBadge_episodeOn` when cleaning remains enabled (AC4).

### 3. Bucket geometry and color rules

**Geometry (half-open):**

- `width = episodeDuration / Double(segmentCount)`
- Bucket `i` covers `[i * width, (i + 1) * width)` for `i = 0 ..< segmentCount − 1`
- Last bucket covers `[ (segmentCount − 1) * width, episodeDuration ]` (include endpoint)

Pinned fixture: duration **120**, count **12** → width **10**; buckets
`[0,10) … [110,120]`.

**Overlap:** two half-open ranges overlap iff intersection length **> 0**.
Treat `adRanges` and the processing window as half-open `[start, end)`.

**Complete** iff `processedEnd >= episodeDuration`.

**Per-bucket color (evaluate in order):**

1. If **complete** and bucket overlaps any `adRange` by **> 0 s** → **yellow**
2. Else if bucket overlaps `[processingStart, processingEnd)` → **blue**
3. Else if bucket is **fully** inside `[0, processedEnd)` (i.e. `bucket.end <= processedEnd`
   for interior half-open buckets; last bucket uses `episodeDuration` as end) → **green**
4. Else → **grey**

**Invariants matching ACs:**

| Snapshot | Expected counts |
|----------|-----------------|
| `processedEnd=50`, processing `[50,60)`, `adRanges=[]` | green **5**, blue **1**, grey **6**, yellow **0** |
| `processedEnd=120`, processing end `120`, `adRanges=[(20,35)]` | yellow **2** (20–30, 30–40), green **10**, blue **0**, grey **0** |

**Mid-analysis:** yellow is **never** applied when not complete, even if `adRanges`
is non-empty.

**AX mapping:** `ready` = count(green) + count(yellow); `processing` = count(blue);
`pending` = count(grey). Format exactly:
`ready:\(r),processing:\(p),pending:\(g)` (no spaces). Yellow contributes to
`ready` so the three counts always sum to `segmentCount`.

### 4. Fixture: `-UITestFixtureAnalysisTimeline`

| Concern | Choice |
|---------|--------|
| Launch arg | `-UITestFixtureAnalysisTimeline` |
| Feed | Implies `-UITestFixtureFeed` / `FixtureFeed.isEnabled` (same pattern as `FixtureAnalysis`) |
| Analyzer | `SteppedEpisodeAnalyzer` with pacing = `FixtureAnalysisProgressPacing` |
| Duration | Synthetic **120.0 s** (snapshot field; no real audio decode required) |
| Snapshots (pinned) | (1) `processedEnd=30`, processing `[30,40)`; (2) `processedEnd=60`, processing `[60,70)`; (3) `processedEnd=120`, processing end `120`, `adRanges=[]` |
| Auto-analyze | `autoAnalyzeOnEpisodeEnable = true` (toggle on row 0 starts stepped analyze) |
| AX expectations | AC3 `ready:3,processing:1,pending:8`; AC5 `ready:6,processing:1,pending:5`; AC4 `ready:12,processing:0,pending:0` |

**Unit-test pacing:** `ImmediateAnalysisProgressPacing` — collector receives all
snapshots with **zero** intentional wall-clock delay (AC “0 wall-clock dependency”
for model/wiring unit tests). Do **not** use `scripts/verify.sh` for throwaway
spikes; model tests are ordinary `PodWashTests`.

**`-UITestFixtureAnalysis` (Slice 09):** Keep working under the new identifier.
`InstantEpisodeAnalyzer` must leave at least one snapshot published during the
analyzing window so `analysisTimeline` exists for migrated
`AnalysisProgressUITests`. Prefer a short hold (existing sleep budget) then
complete — do not reintroduce `analysisProgress`.

### 5. Episode row binding (`EpisodeListView`)

> **Task 026 amendment:** Episode rows no longer host `analysisTimeline` chrome.
> `AnalysisTimelineModel` + player `SuperSeekBarView` remain the in-flight progress
> surface. Row `applyAnalysisDisplay` suppresses `episode.cleaningSummary` while
> `episodeRowShowsTimeline` is true; on complete, Slice 29 summary or
> `cleaningBadge_episodeOn` applies per existing contracts.

`EpisodeTableCell.applyAnalysisDisplay` (or equivalent):

| State | UI | Identifier | Notes |
|-------|-----|------------|-------|
| Analyzing + snapshot | *(none on row)* | — | Progress on mini/full player super seek bar |
| Analyzing without snapshot | *(none on row)* | — | VM still seeds snapshot for player chrome |
| Done + cleaning on | Badge and/or cleaning summary | `cleaningBadge_episodeOn` / `episode.cleaningSummary` | **`analysisProgress` and `analysisTimeline` must not exist on row** |
| Off | Neither | — | Unchanged toggles |

**Implementation:** Keep the UIKit `progressAccessibilityHost` in the cell hierarchy
but **always hidden** on production configure paths (height **0**, identifier **nil**).
`AnalysisTimelineBarView` may remain for layout-test seams; list chrome is retired.

**Serialize with Slice 23:** Edits land only in `EpisodeListView` analysis display
path + fixture routing — do not redesign Library navigation (ADR-015).

### 6. Production progress (non-fixture)

| Analyzer | Progress behavior (Slice 20 minimum) |
|----------|--------------------------------------|
| `SteppedEpisodeAnalyzer` | ≥ 3 pinned snapshots (fixture) |
| `InstantEpisodeAnalyzer` | ≥ 1 snapshot while analyzing, then clear on complete |
| `AnalysisPipeline` | Optional: emit start (`processedEnd=0`, first-bucket processing) and complete (`processedEnd=duration`, `adRanges` from `.unrelatedContent` intervals). **No** claim of WhisperKit token-level progress |

Mapping complete `adRanges`: when analysis finishes, `adRanges = intervals.filter { $0.source == .unrelatedContent }.map { AdTimeRange(start: $0.start, end: $0.end) }`. Profanity intervals do **not** paint yellow.

### 7. Verification architecture

| Layer | What it proves |
|-------|----------------|
| `AnalysisTimelineModelTests` | AC1–AC2 color counts on pinned snapshots |
| `AnalysisTimelineUITests` | AC3–AC5 AX values + identifier retirement under timeline fixture |
| `AnalysisProgressUITests` | Still green after identifier migration |
| Full `scripts/verify.sh` | AC6 |

No offline audio render. No XCTSkip on core ACs.

## Consequences

- **Cross-cutting:** `analysisProgress` removal breaks Slice 09 UITests until QA
  migrates them in the test-spec commit — expected, same slice.
- **`AnalysisUIViewModel` analyzer type** widens to `any EpisodeAnalyzing` so
  stepped / pipeline / instant inject cleanly (closes the Instant-only hardcode).
- **Playback / cache / trigger policy** unchanged — visualize only.
- **Yellow** depends on Slice 19 `IntervalSource`; mid-flight UITests use empty
  `adRanges` (AC3–AC5). Unit AC2 covers yellow without UI.
- **Slice 21** must not restyle timeline segment colors away from the Slice 20 /
  UX contract without a superseding ADR or UX revision.
- Parallel work on CarPlay / overlay must not edit `EpisodeListView` analysis
  display without coordinating with this slice.

## Out of scope (explicit)

- Changing when analysis runs (Slice 13)
- ASR chunk-progress accuracy
- Mini-player / CarPlay / now-playing timeline
- Brand tokens / perceptual color review
- Re-encoding or playback schedule changes
