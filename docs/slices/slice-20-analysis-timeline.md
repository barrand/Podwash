# Slice 20 — Analysis timeline visualization (Skipper-style)

| Field | Value |
|-------|-------|
| **ID** | 20 |
| **Title** | Analysis timeline visualization |
| **Status** | Done |
| **Crux** | While analysis is in flight for an episode with cleaning enabled, the episode row renders a **12-segment** timeline whose **blue / green / grey** counts match a pinned progress snapshot from an injected stepped pipeline double — assertable in unit tests and via `analysisTimeline` accessibility values in UI tests, with no physical device or Skipper app comparison. |

## PRD / spec references

- PRD §11 (2026-07-10) — Skipper-inspired timeline deferred from Slice 13; analysis on **first play with cleaning enabled**
- PRD §3 — Clear UI indicators for analysis in progress
- Slice 07 — `AnalysisPipeline` / cache (progress seam attaches here or on `EpisodeAnalyzing`)
- Slice 09 — `analysisProgress` row indicator (**replaced** by segmented timeline in this slice)
- Slice 13 — analysis timing + interval retention policy
- Slice 19 — unrelated-content intervals (yellow segment source when analysis is complete)
- `docs/adr/005-analysis-pipeline.md` — pipeline module layout
- `docs/adr/015-app-shell-navigation.md` — `EpisodeListView` / Library navigation chrome

## Goal

Replace the Slice 09 spinner with a Skipper-style segmented timeline on the episode row so users see which portions of the episode are processed, in flight, or not yet scanned during analysis.

## Deliverables

- **`AnalysisTimelineModel`** — pure segment bucketing + color assignment from progress snapshots (no SwiftUI)
- **`AnalysisTimelineView`** — segmented bar on the episode row (and/or now-playing chrome if UX pins row-only)
- **Progress reporting seam** — `AnalysisProgressSnapshot` (or equivalent) published while `EpisodeAnalyzing` runs: `episodeDuration`, `processedEnd`, `processingStart`, `processingEnd`, optional `adRanges` for yellow on completed timelines
- **`SteppedEpisodeAnalyzer`** (or extend `InstantEpisodeAnalyzer`) — deterministic test double that emits **≥ 3** pinned progress snapshots with **0** wall-clock dependency in unit tests
- **Episode row wiring** — bind timeline to `AnalysisUIViewModel` / playback analysis path; retire `analysisProgress` identifier in favor of `analysisTimeline`
- **Launch argument** `-UITestFixtureAnalysisTimeline` — implies `-UITestFixtureFeed`; injects stepped analyzer on **120.0 s** synthetic duration, **12** buckets × **10.0 s**
- `PodWash/PodWashTests/AnalysisTimelineModelTests.swift`
- `PodWash/PodWashUITests/AnalysisTimelineUITests.swift`
- UX spec `docs/slices/slice-20-ux.md` — color contract, layout, accessibility identifiers, UI scenarios
- Architect ADR `docs/adr/018-analysis-timeline.md` — progress seam, bucket overlap rules, binding to `EpisodeListView`

## Fixture strategy (pinned — PM / QA)

| Asset | Value | Role |
|-------|-------|------|
| Episode duration | **120.0 s** | Synthetic duration for model + UI fixture |
| Bucket size | **10.0 s** | Exactly **12** segments (`segmentCount == 12`) |
| Mid-analysis snapshot | `processedEnd = 50.0`, `processingStart = 50.0`, `processingEnd = 60.0` | AC1 color counts |
| Ad spans (yellow) | `[(20.0, 35.0)]` | AC2 yellow mapping on completed timeline |
| Stepped UI fixture | Snapshots at `processedEnd ∈ {30.0, 60.0, 120.0}` with processing window on the next bucket | AC3–AC4 transitions |
| Color precedence (mid-analysis) | **blue** > **green** > **grey** | A bucket is blue iff it overlaps `[processingStart, processingEnd)`; green iff fully within `[0, processedEnd)` and not blue; otherwise grey |
| Yellow rule (complete only) | When `processedEnd ≥ episodeDuration`, a bucket is **yellow** iff it overlaps any `adRange` by **> 0 s**; yellow does not apply while `processedEnd < episodeDuration` |

## Depends on

- Slice 07 — analysis pipeline
- Slice 09 — cleaning toggles + progress row region (identifier migration)
- Slice 13 — analysis timing policy (visualize in-flight analysis; do not re-litigate trigger policy here)
- Slice 23 — production `EpisodeListView` reached from Library (**Done** — serialize edits on shared list chrome)

**Parallelizable:** After Slice 23; may parallel with Slices 15–16 on non-list files once deps are met.

## Out-of-scope

- Changing **when** analysis runs (first play vs toggle) — Slice 13 policy; this slice only visualizes any in-flight analysis
- Settings / word-list persistence (Slice 13)
- Improving segmentation detection quality (Slices 18–19)
- Mini-player or CarPlay timeline chrome (episode row only unless UX addendum expands)
- Physical device runs, Skipper app side-by-side, or subjective color review
- Re-encoding audio or playback schedule changes
- Visual identity / brand tokens (Slice 21 — timeline colors stay on the Slice 20 contract)
- Perceptual listening or wall-clock ASR benchmarks

## Acceptance criteria

Automatable only. **XCTSkip is not allowed on core ACs** — a mapped test that cannot run must fail.

- [ ] 1. Unit test (`AnalysisTimelineModel`, duration **120.0 s**, bucket **10.0 s**, snapshot `processedEnd = 50.0`, `processingStart = 50.0`, `processingEnd = 60.0`, `adRanges = []`): `segmentCount == 12`; color counts are **green = 5**, **blue = 1**, **grey = 6**, **yellow = 0**.
- [ ] 2. Unit test (same duration/bucket, snapshot `processedEnd = 120.0`, `processingEnd = 120.0`, `adRanges = [(20.0, 35.0)]`): **yellow = 2**, **green = 10**, **blue = 0**, **grey = 0** (buckets **20–30 s** and **30–40 s**).
- [ ] 3. UI test (`-UITestFixtureAnalysisTimeline`): after enabling cleaning on row **0**, `analysisTimeline` exists within **2.0 s**; `accessibilityValue` is exactly **`ready:3,processing:1,pending:8`** within **2.0 s** (first stepped snapshot: `processedEnd = 30.0`, processing **30.0–40.0 s**).
- [ ] 4. UI test (same fixture): within **5.0 s** of enabling cleaning, `accessibilityValue` becomes **`ready:12,processing:0,pending:0`**; `analysisProgress` identifier does **not** exist on row **0**; `cleaningBadge_episodeOn` exists on row **0**.
- [ ] 5. UI test (same fixture, mid-run): within **5.0 s**, `accessibilityValue` passes through **`ready:6,processing:1,pending:5`** at least once (second snapshot: `processedEnd = 60.0`, processing **60.0–70.0 s**) before the AC4 terminal state.
- [ ] 6. Full suite green via `scripts/verify.sh` (**exit 0, failed 0, skipped 0**).

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/AnalysisTimelineModelTests.swift` | `testMidAnalysisColorCounts` | Pinned 50/50–60 snapshot; 12 segments |
| 2 | `PodWash/PodWashTests/AnalysisTimelineModelTests.swift` | `testCompletedTimelineYellowSegments` | Ad span [20,35]; yellow=2 |
| 3 | `PodWash/PodWashUITests/AnalysisTimelineUITests.swift` | `testTimelineAppearsWithFirstSnapshot` | `ready:3,processing:1,pending:8` |
| 4 | `PodWash/PodWashUITests/AnalysisTimelineUITests.swift` | `testTimelineCompletesAndRetiresProgress` | Terminal `12/12`; no `analysisProgress` |
| 5 | `PodWash/PodWashUITests/AnalysisTimelineUITests.swift` | `testTimelineMidRunSnapshot` | Observes `ready:6,processing:1,pending:5` |
| 6 | — | — | Unfiltered `scripts/verify.sh` |

## Verification commands

```bash
# Fast inner loop (NOT sufficient for Done):
scripts/verify.sh -only-testing:PodWashTests/AnalysisTimelineModelTests -only-testing:PodWashUITests/AnalysisTimelineUITests

# Done gate — FULL suite, zero failures, zero skips:
scripts/verify.sh
```

## Verification record (QA fills at Verify)

```
VERIFY RESULT: exit=0 total=111 passed=111 failed=0 skipped=0 filtered=0 bundle=build/test-results/verify-20260711-172208.xcresult tier=3 class=tests
```

## Plan review record (coordinator fills before downstream roles)

```
ADR review (2026-07-11): (pending) QA cleared — pipeline worker finished PM cleared — pipeline worker finished
Test spec review (2026-07-11): Architect cleared — pipeline worker finished
```

## Done gate

- [ ] Every AC mapped to a test; all rows in the mapping table filled
- [ ] **Full suite green:** unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0
- [ ] Verification record pasted above (exit code + counts + `.xcresult` path)
- [ ] Auto-commit on green: `slice-20: analysis timeline`

## Design notes (Architect)

Durable decisions: [`docs/adr/018-analysis-timeline.md`](../adr/018-analysis-timeline.md).

- Pure `AnalysisTimelineModel` owns bucketing / colors / AX string; UIKit cell host keeps `analysisTimeline` AX stable.
- Progress seam = `AnalysisProgressSnapshot` + `onProgress` on `SteppedEpisodeAnalyzer` (immediate pacing for unit tests; fixture pacing for UITests).
- Retire `analysisProgress` globally; migrate Slice 09 `AnalysisProgressUITests` in this slice’s test-spec commit.
- No empirical audio/ASR spike — math-only design.

## Role artifacts

| Role | Gate | Artifact path |
|------|------|---------------|
| PM | Required | this file |
| Architect | Required | `docs/adr/018-analysis-timeline.md` |
| UX | Required | `docs/slices/slice-20-ux.md` |
| QA | Required | `AnalysisTimelineModelTests.swift`, `AnalysisTimelineUITests.swift`, stepped analyzer fixture |
| Engineer | Required | timeline model/view, progress seam, `EpisodeListView` wiring |
