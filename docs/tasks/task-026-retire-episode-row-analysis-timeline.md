# Task 026 — Retire episode-row analysis timeline

| Field | Value |
|-------|-------|
| **ID** | 026 |
| **Title** | Retire episode-row analysis timeline |
| **Status** | Implemented |
| **Kind** | tweak |
| **Priority** | P2 |
| **Area** | `PodWash/PodWash/EpisodeListView.swift`, `PodWash/PodWash/AnalysisTimelineView.swift` (row host only), `PodWash/PodWashUITests/AnalysisTimelineUITests.swift`, `PodWash/PodWashUITests/AnalysisProgressUITests.swift`, `PodWash/PodWashUITests/CleaningSummaryUITests.swift`, `docs/adr/018-analysis-timeline.md`, `docs/slices/slice-20-ux.md`, `docs/slices/slice-29-*.md` (AC6 / mutual-exclusion amend) |
| **Crux** | Channel episode rows never expose `analysisTimeline` (in flight or complete); stepped-analysis UITests prove the identifier is absent while `AnalysisTimelineModel` + player super-seek chrome remain the progress source of truth. |

## Outcome

**Current (designed, Slice 20 / ADR-018):** While analysis is in flight with cleaning on, `EpisodeTableViewCell` paints a 12-segment strip (`AnalysisTimelineBarView`) with accessibility id `analysisTimeline`. On terminal complete the strip clears; Slice 29 then shows `episode.cleaningSummary` in that band.

**Observed (product):** The row strip is easy to miss / rarely noticed; progress that matters lives on mini + full player (Slice 25/27/30). Keeping a second timeline paint path on the list is dead chrome.

**Desired:** Remove episode-row timeline chrome entirely. In flight: **no** `analysisTimeline` on the row (cleaning badge / download / other accessories unchanged). Complete: keep Slice 29 `episode.cleaningSummary` when cache is present. Do **not** delete `AnalysisTimelineModel` or player `SuperSeekBarView` segment colors — those stay.

**Framing:** If UITests on `-UITestFixtureAnalysisTimeline` assert `analysisTimeline` does not exist after enabling cleaning, and CleaningSummary mutual-exclusion no longer requires a row timeline, you never re-check the channel list for a Skipper-style strip.

## Acceptance criteria

- [ ] 1. UI test (`-UITestFixtureAnalysisTimeline`): enable cleaning on row **0** → within **2.0 s**, `analysisTimeline` **does not exist** (cell-scoped and app-global query).
- [ ] 2. UI test (same fixture): within **5.0 s** of enabling cleaning, terminal complete still yields `cleaningBadge_episodeOn` on row **0** (or equivalent existing badge contract); retired `analysisProgress` remains absent.
- [ ] 3. UI test (`-UITestFixtureAnalysisTimeline` / CleaningSummary in-flight path): while analysis is in flight on row **0**, `episode.cleaningSummary` **does not exist** and `analysisTimeline` **does not exist** (summary still waits for complete; no timeline stand-in).
- [ ] 4. Unit / layout seam: `EpisodeTableViewCell` does not host a visible `AnalysisTimelineBarView` for production configure paths (bar removed or always hidden; layout test or `@testable` seam asserts timeline host height **0** / identifier nil when configuring an analyzing snapshot).

## Surgical test scope

| AC# | Test id | New? |
|-----|---------|------|
| 1 | `PodWashUITests/AnalysisTimelineUITests/testEpisodeRowDoesNotShowAnalysisTimelineWhileAnalyzing()` | yes (replaces positive mid-run AX asserts) |
| 2 | `PodWashUITests/AnalysisTimelineUITests/testEpisodeRowShowsBadgeWithoutTimelineAtComplete()` | yes (migrates AC4-style badge assert) |
| 3 | `PodWashUITests/CleaningSummaryUITests/testSummaryHiddenWhileTimelineInFlight()` | no — **authorized bend** (timeline-present → timeline-absent; summary still absent) |
| 4 | `PodWashTests/EpisodeListTimelineRetirementTests/testAnalyzingConfigureOmitsTimelineAccessibilityHost()` | yes |

## Authorized test changes

- `PodWashUITests/AnalysisTimelineUITests` — all asserts that require `analysisTimeline` existence or exact `ready:N,processing:N,pending:N` on the **episode row** (delete or invert to absence).
- `PodWashUITests/AnalysisProgressUITests` — any remaining row `analysisTimeline` positive asserts (invert / remove).
- `PodWashUITests/CleaningSummaryUITests/testSummaryHiddenWhileTimelineInFlight` — stop requiring `analysisTimeline` exists; keep “summary absent while in flight.”
- Doc/story amend (not XCTest): ADR-018 row-binding, slice-20-ux row chrome, slice-29 AC6 / UX mutual exclusion (`analyzing` band no longer hosts a timeline).

**Keep green without bend:** `PodWashTests/AnalysisTimelineModelTests` (model still feeds player seek bar colors).

## Depends on

- None

## Out of scope

- Removing the channel **episode list** itself (rows stay; only the timeline strip retires)
- Mini / full player super seek bar, mute markers, or Slice 30 shared host work
- Deleting `AnalysisTimelineModel` / segment color math used by player chrome
- Changing when analysis runs, cleaning toggles, or `episode.cleaningSummary` complete-state contract (Slice 29) beyond dropping the in-flight timeline exclusivity partner
- CarPlay / lock screen
- Related follow-up already filed: [Slice 30](../slices/slice-30-mini-player-super-seek-parity.md) (player parity; row timeline was OOS there)

**Scheduling note (human / floor):** Prefer starting after Slice 29 is **Done** or **Implemented**, so CleaningSummary AC6 can be bent in one pass without thrashing an in-flight slice-29 verify.

## Human checklist

(n/a — automatable)

## Verification record

> Loop writes `VERIFY RESULT:` here. For tasks, `tier=2` and `filtered=1` are valid for Done.

```
VERIFY RESULT: exit=0 total=6 passed=6 failed=0 skipped=0 filtered=1 bundle=build/test-results/verify-20260715-212020.xcresult tier=2 class=tests
```
