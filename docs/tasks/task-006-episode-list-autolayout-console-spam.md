# Task 006 — Episode list Auto Layout console spam on podcast detail

| Field | Value |
|-------|-------|
| **ID** | 006 |
| **Title** | Episode list Auto Layout console spam on podcast detail |
| **Status** | Done |
| **Kind** | fix |
| **Priority** | P1 |
| **Area** | `PodWash/PodWash/EpisodeListView.swift`, `PodWash/PodWash/AnalysisTimelineView.swift`, `PodWash/PodWashTests/` (new layout tests; cell/controller are currently `private` — expose `@testable`/`internal` seam as needed) |
| **Crux** | Opening a subscribed podcast’s detail screen does not emit Auto Layout unsatisfiable-constraint recoveries for `EpisodeTableViewCell` / `AnalysisTimelineBarView` during the SwiftUI→UIKit embed’s temporary zero-width layout pass. |

## Outcome

**Observed (Simulator/Xcode console, UI looks correct):** Subscribe to a podcast → open its details screen. Console floods with:

- `UITableView was told to layout its visible cells … without being in the view hierarchy` (`frame = (0 0; 0 0)`)
- Repeated `Unable to simultaneously satisfy constraints` cascades whose smoking gun is `UIView-Encapsulated-Layout-Width … UITableViewCellContentView.width == 0`, then UIKit breaks `AnalysisTimelineBarView` trailing, `downloadButton_*` / `queueAddButton_*` width == 44, and accessory stack spacing.

**Expected:** Same navigation; episode rows still look correct; Xcode console does **not** show unsatisfiable-constraint recoveries or `UITableViewAlertForLayoutOutsideViewHierarchy` for the episode table. System noise (`nw_protocol_instance…`, “Reading from public effective user settings”, “System gesture gate timed out”, “variant selector cell index”) is out of scope.

**Root cause sketch:** `EpisodeTableViewRepresentable` / `EpisodeTableViewController` lays out cells before the table is in a window with real bounds. Fixed 44×44 accessory widths + leading/trailing margins cannot satisfy width == 0. UI looks fine because UIKit recovers once a real width arrives.

**Test gap:** `EpisodeListUITests`, `LibraryUITests`, `DownloadUITests`, `AnalysisTimelineUITests` only assert identifiers/labels/state — none exercise zero-width → phone-width layout resilience or constraint priority.

## Acceptance criteria

- [ ] 1. Unit test: configure an episode row cell (via `@testable`/`internal` seam), force layout with `contentView` width **0**, then with width **≥ 390**; after the phone-width pass, `queueAddButton` and `downloadButton` each have width **44**, and the accessory stack’s frame does not intersect the title/text stack’s frame.
- [ ] 2. Unit test: same zero→phone layout with the analysis timeline host visible; after phone-width layout, `AnalysisTimelineBarView.bounds.width` equals its host’s bounds width (within **1 pt**).
- [ ] 3. Human: after AC 1–2 green, open Library → subscribed show detail once under the debugger; confirm no `Unable to simultaneously satisfy constraints` / `UITableViewAlertForLayoutOutsideViewHierarchy` lines referencing `episodeCell_*` / `AnalysisTimelineBarView` / `queueAddButton_*` / `downloadButton_*`.

## Surgical test scope

| AC# | Test id | New? |
|-----|---------|------|
| 1 | `PodWashTests/EpisodeTableViewCellLayoutTests/testCellSurvivesZeroWidthThenPhoneWidthWithoutOverlap()` | yes |
| 2 | `PodWashTests/EpisodeTableViewCellLayoutTests/testTimelineBarFillsHostAfterZeroWidthLayout()` | yes |
| 3 | — (human checklist below) | — |

## Authorized test changes

- (none — bug fix)

## Depends on

- None

## Out of scope

- Suppressing unrelated system console noise listed above
- Changing episode-row visual design, accessory order, or 44×44 hit targets (keep Slice 10/11 contracts)
- Rewriting the list in pure SwiftUI
- CarPlay

## Human checklist

- [ ] Build from green tier-2 verify; run on Simulator with Xcode console visible.
- [ ] Library → any subscribed show → podcast detail / episode list appears (UI still looks normal).
- [ ] Console: no Auto Layout unsatisfiable-constraint recoveries involving `EpisodeTableViewCell` accessories or `AnalysisTimelineBarView`; no UITableView layout-outside-hierarchy warning for that table.

## Verification record

> Loop writes `VERIFY RESULT:` here. For tasks, `tier=2` and `filtered=1` are valid for Done.

```
VERIFY RESULT: exit=0 total=2 passed=2 failed=0 skipped=0 filtered=1 bundle=build/test-results/verify-20260713-165411.xcresult tier=2 class=tests
```
