# Slice 20 — UX spec: Analysis timeline (episode row)

| Field | Value |
|-------|-------|
| **Slice** | 20 — Analysis timeline visualization |
| **Screen** | `PodcastDetailView` → `EpisodeListView` episode rows (extends Slice 06 / 09 / 23 layout) |
| **ADR** | [ADR-018](../adr/018-analysis-timeline.md) (progress seam, bucketing, row binding) |
| **Builds on** | [slice-06-ux.md](slice-06-ux.md) (episode list), [slice-09-ux.md](slice-09-ux.md) (cleaning toggles + badge precedence; **retires** `analysisProgress`), [slice-23-ux.md](slice-23-ux.md) (Library → detail navigation; UIKit cell AX host) |
| **Slice story** | [slice-20-analysis-timeline.md](slice-20-analysis-timeline.md) |

## Scope note

**Episode row — timeline retired (Task 026).** The segmented `analysisTimeline`
bar no longer appears on episode rows. `AnalysisTimelineModel` still drives
mini-player and full-player super seek bar segment colors while analysis runs.
This UX spec’s color contract and model pins remain authoritative for player
chrome and unit tests; row identifiers below are **historical** unless noted.

Mini-player, expanded player, CarPlay, and lock-screen chrome use player
timeline hosts (`SuperSeekBarView`); episode list rows expose cleaning badge /
summary only after analysis completes.

Slice 20 **replaced** the Slice 09 `ProgressView` + "Analyzing…" row indicator (`analysisProgress`) with a **12-segment** horizontal bar (`analysisTimeline`) on the episode row. **Task 026 retired** that row bar; color math and yellow-on-complete rules remain unit-tested (AC1–AC2) and feed player super-seek chrome. UI tests for row timeline assert **absence**; player timeline tests own in-flight AX.

## Layout

Extends Slice 06 / 09 episode row layout. Each row keeps title, date, and trailing **episode cleaning toggle** (`episodeCleaningToggle_<index>`). The analysis region sits **inline below the title/date block**, in the same vertical band previously occupied by `analysisProgress` (and parallel to `downloadProgress_<index>` from Slice 10 when both could theoretically coexist — in fixture modes only one progress type is active).

### Analysis timeline bar (`analysisTimeline`) — retired on row (Task 026)

Row-hosted timeline chrome is **removed**. In flight, episode rows show **no**
`analysisTimeline` identifier; progress lives on mini/full player super seek bar.
The geometry/color contract below still applies to `AnalysisTimelineModel` and
player hosts.

## Color contract

Colors are assigned by `AnalysisTimelineModel` from `AnalysisProgressSnapshot`. UX pins the **semantic mapping** and **precedence** (Engineer must not restyle away from this contract without a superseding ADR/UX revision — Slice 21 brand tokens must preserve these roles).

| Color | Meaning (in-flight) | Meaning (complete) | AX bucket |
|-------|---------------------|--------------------|-----------|
| **Green** | Bucket fully processed (`[0, processedEnd)`) | Processed, non-ad bucket | `ready` |
| **Blue** | Bucket overlaps active processing window `[processingStart, processingEnd)` | — (none at terminal) | `processing` |
| **Grey** | Not yet scanned | — | `pending` |
| **Yellow** | **Not shown** while `processedEnd < episodeDuration` | Bucket overlaps any `adRange` by **> 0 s** (unrelated/ad spans from Slice 19) | `ready` |

**Precedence (per bucket, evaluate in order):** yellow (complete only) → blue → green → grey.

**Pinned mid-analysis example** (AC1 / UI snapshot 1): `processedEnd = 30.0`, processing `[30.0, 40.0)` → green **3**, blue **1**, grey **8** → `ready:3,processing:1,pending:8`.

**Pinned complete + ads example** (AC2, unit-only): `processedEnd = 120.0`, `adRanges = [(20.0, 35.0)]` → yellow **2**, green **10** → `ready:12,processing:0,pending:0` (yellow counts toward `ready`).

## States

### Episode row analysis display

| State | Visible indicator | `accessibilityIdentifier` | `accessibilityValue` | Notes |
|-------|-------------------|---------------------------|----------------------|-------|
| **Off** | Neither timeline nor episode badge | — | — | Channel and episode cleaning toggles off |
| **Episode on (idle)** | Episode badge | `cleaningBadge_episodeOn` | — | Cleaning enabled, not analyzing |
| **Analyzing** | *(none on row)* | — | — | Badge hidden; summary suppressed (Slice 29); player owns in-flight chrome |
| **Analyzing → complete** | Badge and/or cleaning summary | `cleaningBadge_episodeOn` / `episode.cleaningSummary` | — | Row `analysisTimeline` must not exist |

**Precedence on episode row:** `analyzing` (suppress badge + summary) > `episodeOn` (badge) / complete summary > `off`.

**Only one analyzing row** at a time (unchanged Slice 09 behavior). Timeline identifier is scoped to the row whose `analyzingEpisodeID` matches.

**No loading/error/empty states** for the timeline itself — if analysis is active but snapshot is momentarily nil, Engineer should seed the first snapshot synchronously before paint (ADR-018 §5); UX does not expose a separate spinner identifier.

### Timeline `accessibilityValue` format

Machine-readable aggregate counts (sums always equal segment count **12** in pinned fixture):

```text
ready:<int>,processing:<int>,pending:<int>
```

- **No spaces** around commas or colons.
- **`ready`** = green count + yellow count.
- **`processing`** = blue count.
- **`pending`** = grey count.

Examples: `ready:3,processing:1,pending:8` · `ready:6,processing:1,pending:5` · `ready:12,processing:0,pending:0`.

## Accessibility identifiers

| Control / region | `accessibilityIdentifier` | `accessibilityLabel` | `accessibilityValue` | `accessibilityHint` |
|------------------|---------------------------|----------------------|----------------------|---------------------|
| Analysis timeline (row *i*, analyzing) | `analysisTimeline` | `Analysis timeline` | `ready:N,processing:N,pending:N` | `Shows which parts of the episode are scanned, in progress, or waiting.` |
| Episode on badge (row *i*) | `cleaningBadge_episodeOn` | `Episode cleaning on` | — | — |
| Episode cleaning toggle (row *i*) | `episodeCleaningToggle_<index>` | `Episode cleaning` | `on` / `off` | — |
| Channel cleaning toggle | `channelCleaningToggle` | `Channel cleaning` | `on` / `off` | — |
| Channel on badge | `cleaningBadge_channelOn` | `Channel cleaning on` | — | — |

**Retired globally:** `analysisProgress` — must **not** appear in the accessibility tree after this slice (AC4). QA migrates `AnalysisProgressUITests` to query `analysisTimeline`.

**Unchanged Slice 06 identifiers:** `episodeList`, `episodeCell_<index>`, `podcastTitle`, etc.

**Cell scoping:** Prefer querying within `app.cells["episodeCell_0"]` (or `otherElements`) descendants; fall back to `app.descendants(matching: .any)["analysisTimeline"]` (same pattern as Slice 09 `analysisProgress` helpers).

**Toggle interaction:** UI tests enable cleaning via `episodeCleaningToggle_0` switch (`switches` query), unchanged from Slice 09.

## Fixture modes

### Timeline stepped fixture (new — AC3–AC5)

Launch argument: `-UITestFixtureAnalysisTimeline`

| Concern | Value |
|---------|-------|
| Feed | Implies `-UITestFixtureFeed` (`sample_feed.xml`, `RootView` → `PodcastDetailView`) |
| Synthetic duration | **120.0 s** (snapshot field; no audio decode) |
| Segments | **12** × **10.0 s** |
| Analyzer | `SteppedEpisodeAnalyzer` + `FixtureAnalysisProgressPacing` |
| Auto-analyze | `autoAnalyzeOnEpisodeEnable = true` — toggling row **0** cleaning **on** starts stepped analysis |
| Pinned snapshots | (1) `processedEnd=30`, processing `[30,40)` → `ready:3,processing:1,pending:8`; (2) `processedEnd=60`, processing `[60,70)` → `ready:6,processing:1,pending:5`; (3) `processedEnd=120`, complete → `ready:12,processing:0,pending:0`; `adRanges=[]` for all UI snapshots |

**Typical launch:** `-UITestFixtureAnalysisTimeline` only (feed implied).

### Analysis stub fixture (Slice 09 — migrated identifier)

Launch argument: `-UITestFixtureAnalysis`

Implies feed. `InstantEpisodeAnalyzer` (or equivalent) publishes **at least one** timeline snapshot during the analyzing window so `analysisTimeline` exists, then completes within existing budgets. On completion: timeline disappears, `cleaningBadge_episodeOn` on row 0. **`analysisProgress` must not be reintroduced.**

### Feed fixture (Slice 06 — badge tests)

Launch argument: `-UITestFixtureFeed`

Unchanged for `testToggleBadges` (no timeline unless cleaning triggers production/stub analyze path).

## UI test scenarios

Mapped tests: `AnalysisTimelineUITests.swift` (AC3–AC5) + migrated `AnalysisProgressUITests.swift` (Slice 09 AC2–AC3 with `analysisTimeline`).

**Query helpers:** wait for `episodeList` (timeout **10 s**); use `episodeCleaningToggle_0` switch; assert `analysisTimeline` via cell-scoped or global descendant search; assert `accessibilityValue` with **exact** string match.

### `testTimelineAppearsWithFirstSnapshot` (AC#3)

1. Launch with `-UITestFixtureAnalysisTimeline`; wait for `episodeList` (10 s).
2. Tap `episodeCleaningToggle_0` switch to enable cleaning (auto-analyze starts).
3. Within **2.0 s**, assert `analysisTimeline` exists (row 0 scope or global).
4. Within **2.0 s**, assert `analysisTimeline` `accessibilityValue` equals exactly **`ready:3,processing:1,pending:8`**.

### `testTimelineCompletesAndRetiresProgress` (AC#4)

1. Launch with `-UITestFixtureAnalysisTimeline`; wait for `episodeList` (10 s).
2. Tap `episodeCleaningToggle_0` switch to enable cleaning.
3. Within **5.0 s** of enabling cleaning, assert `analysisTimeline` `accessibilityValue` equals **`ready:12,processing:0,pending:0`**.
4. Assert `analysisProgress` does **not** exist (global descendant query).
5. Assert `cleaningBadge_episodeOn` exists on row 0.

### `testTimelineMidRunSnapshot` (AC#5)

1. Launch with `-UITestFixtureAnalysisTimeline`; wait for `episodeList` (10 s).
2. Tap `episodeCleaningToggle_0` switch to enable cleaning.
3. Within **5.0 s**, observe `analysisTimeline` `accessibilityValue` equal to **`ready:6,processing:1,pending:5`** at least once before the terminal `ready:12,processing:0,pending:0` state (AC#4).

**Implementation note:** use `NSPredicate` / `XCTNSPredicateExpectation` or polling loop — do not assume fixed sleep offsets; fixture pacing must stay within AC4/AC5 wall-clock budgets.

### `testToggleBadges` (Slice 09 AC#2 — migrated)

Unchanged steps from [slice-09-ux.md](slice-09-ux.md); launch `-UITestFixtureFeed`. No timeline assertions.

### `testProgressIndicatorLifecycle` (Slice 09 AC#3 — migrated to timeline)

1. Launch with `-UITestFixtureAnalysis`; wait for `episodeList` (10 s).
2. Tap `episodeCleaningToggle_0` switch.
3. Assert `analysisTimeline` exists within **2 s** (replaces `analysisProgress`).
4. Assert `analysisTimeline` does **not** exist within **5 s** (stub completes).
5. Assert `cleaningBadge_episodeOn` exists.

## Verification mapping

| AC# | UX artifact | Test file / method |
|-----|-------------|-------------------|
| 1 | Color contract (mid-analysis counts) | `AnalysisTimelineModelTests.testMidAnalysisColorCounts` |
| 2 | Color contract (complete + yellow) | `AnalysisTimelineModelTests.testCompletedTimelineYellowSegments` |
| 3 | `testTimelineAppearsWithFirstSnapshot` | `AnalysisTimelineUITests.testTimelineAppearsWithFirstSnapshot` |
| 4 | `testTimelineCompletesAndRetiresProgress` | `AnalysisTimelineUITests.testTimelineCompletesAndRetiresProgress` |
| 5 | `testTimelineMidRunSnapshot` | `AnalysisTimelineUITests.testTimelineMidRunSnapshot` |
| 6 | — | Full `scripts/verify.sh` |
