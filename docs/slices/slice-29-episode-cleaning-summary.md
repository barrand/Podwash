# Slice 29 — Episode cleaning summary on channel screen

| Field | Value |
|-------|-------|
| **ID** | 29 |
| **Title** | Episode cleaning summary on channel screen |
| **Status** | Implemented |
| **Priority** | P3 |
| **Crux** | On the podcast detail (channel) episode list, when an episode has a **complete** interval-cache result, the row exposes an assertable **cleaning summary** — profanity section count, ad section count, and total ad duration as **`X.X min`** — derived from cached `[CensorInterval]` without requiring the episode to be playing. |

## PRD / spec references

- PRD §2 — cleaning outcomes visible to the user (download-before-clean-listen; analysis timeline exists, but post-complete row feedback does not)
- `docs/adr/000-foundations.md` — verification via XCTest / accessibility, not manual listening
- `docs/adr/005-analysis-pipeline.md` / `IntervalCache` — on-disk merged intervals keyed by episode + fingerprint
- `docs/adr/013-unrelated-content.md` (or Slice 19 integration) — `.unrelatedContent` vs `.profanity` sources
- `docs/adr/018-analysis-timeline.md` / Slice 20 — in-flight `analysisTimeline`; on complete today timeline clears → only cleaning badge

## Goal

After an episode has been analyzed, the channel screen shows at a glance that it was processed and a compact numeric summary of cleaned profanity sections, ad sections, and total ad minutes.

## Intake decisions (locked)

| Decision | Choice |
|----------|--------|
| Surface | Podcast detail episode rows (`EpisodeListView` / `PodcastDetailView`) — not player, not Library list, not transcript |
| “Processed” signal | Presence of the cleaning summary (and dedicated AX id) when cache is present; absent when never analyzed |
| Profanity sections | Count of **all** `.profanity` intervals (mute **and** skip) — “cleaned,” not skip-only |
| Ad sections | Count of **all** `.unrelatedContent` intervals |
| Ad duration | Sum of `(end − start)` for `.unrelatedContent`, ÷ **60**, displayed as **`X.X min`** (one decimal) |
| Zeros | Analyzed with no hits still shows summary with **0** / **0** / **0.0 min** |
| In flight | Slice 20 timeline remains while analyzing; summary appears only when analysis is **complete** (cache available / terminal) |

## Deliverables

- **ADR** — summary aggregation rules (source filters, minute rounding), when a row is “complete,” binding from `IntervalCache` on the channel list without requiring active playback
- **UX spec** (`slice-29-ux.md`) — row layout, copy, accessibility identifiers/values, fixture scenarios
- Pure summary model (e.g. `EpisodeCleaningSummary` / `CleaningSummaryModel`) from `[CensorInterval]` → counts + formatted minutes
- Episode-row wiring in `EpisodeListView` / related VM so cached complete episodes show the summary on return to the channel screen
- Unit + UI tests mapped below; fixture with known interval set (independent provenance)

## Depends on

- Slice 20 (episode-row analysis timeline + complete → clear timeline)
- Slice 19 / 24 (sourced intervals in cache + production wiring)

**Parallelizable:** Yes — with unrelated punch-list tasks; not with another slice that owns the same episode-row accessory band.

## Out-of-scope

- Full-player / mini-player / CarPlay summary chrome
- Transcript sheet aggregates (Slice 26 already has skipped-ad **word** counts)
- Super seek bar mute markers (Slice 27)
- Changing mute vs skip Settings defaults
- Re-running analysis from the summary control
- Per-interval detail list or tappable drill-down
- “Minutes of profanity” (profanity is section count only this slice)

## Acceptance criteria

Pinned hand-computed fixture intervals (provenance: listed here, not from implementation):

| # | `start` | `end` | `action` | `source` |
|---|---------|-------|----------|----------|
| 1 | 10.0 | 11.0 | mute | profanity |
| 2 | 20.0 | 21.5 | mute | profanity |
| 3 | 30.0 | 90.0 | skip | unrelatedContent |
| 4 | 100.0 | 130.0 | skip | unrelatedContent |

Expected: **profanitySections = 2**, **adSections = 2**, ad duration **90.0 s** → **`1.5 min`**.

- [ ] 1. Unit test (`CleaningSummaryModel` or equivalent): given the pinned fixture intervals → `profanitySectionCount == 2`, `adSectionCount == 2`, `adDurationSeconds == 90.0` (± **0.001**), formatted minutes string **`1.5 min`** (exact).
- [ ] 2. Unit test: empty interval array (analyzed, nothing cleaned) → counts **0**, **0**, formatted **`0.0 min`**. Unit test: intervals that are **only** `.profanity` with `.skip` still increment profanity count (skip-only profanity is cleaned). Unit test: `.unrelatedContent` alone does **not** increment profanity count.
- [ ] 3. Unit test: `adDurationSeconds = 45.0` → formatted string **`0.8 min`** (45/60 = 0.75 → one-decimal **round half up** to **0.8**). Pin rounding in ADR.
- [ ] 4. UI test (channel/podcast detail fixture): episode with **no** interval cache → cleaning summary identifier **does not exist** within **2 s** of list appearing.
- [ ] 5. UI test (same surface, fixture seeds IntervalCache with the pinned intervals for row **0**, analysis complete / not in-flight): within **5 s**, summary element exists; `accessibilityValue` (or documented child values) encodes **profanity=2**, **ads=2**, and minutes **`1.5`** (exact format pinned in UX — e.g. `profanity:2,ads:2,adMinutes:1.5`).
- [ ] 6. UI test (Slice 20 stepped timeline still in flight on row 0): `analysisTimeline` exists; cleaning summary for that row **does not exist** until terminal/complete (summary must not replace in-flight timeline).

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/CleaningSummaryModelTests.swift` | `testPinnedFixtureCountsAndFormattedMinutes` | Fixture: `Fixtures/cleaning/cleaning-summary-pinned.intervals.json` |
| 2 | `PodWash/PodWashTests/CleaningSummaryModelTests.swift` | `testEmptyAndSourceFilters` | Empty `[]`, skip-only profanity, ads-only source filter |
| 3 | `PodWash/PodWashTests/CleaningSummaryModelTests.swift` | `testAdMinutesRoundsHalfUpToOneDecimal` | 45.0 s → `0.8 min` half-up pin |
| 4 | `PodWash/PodWashUITests/CleaningSummaryUITests.swift` | `testSummaryAbsentWithoutCache` | `-UITestFixtureFeed`; absent within 2 s |
| 5 | `PodWash/PodWashUITests/CleaningSummaryUITests.swift` | `testSummaryShowsPinnedCountsWhenCached` | `-UITestFixtureCleaningSummary`; AX value exact |
| 6 | `PodWash/PodWashUITests/CleaningSummaryUITests.swift` | `testSummaryHiddenWhileTimelineInFlight` | `-UITestFixtureAnalysisTimeline`; mutual exclusion |

## Verification commands

```bash
# Fast inner loop (NOT sufficient for Done):
scripts/verify.sh -only-testing:PodWashTests/CleaningSummaryModelTests
scripts/verify.sh -only-testing:PodWashUITests/CleaningSummaryUITests

# Done gate — FULL suite, zero failures, zero skips:
scripts/verify.sh
```

## Verification record (QA fills at Verify)

> Paste the `VERIFY RESULT:` line from the full-suite `scripts/verify.sh` run here.
> A slice without a recorded full-suite green artifact is not Done.

```
VERIFY RESULT: exit=0 total=6 passed=6 failed=0 skipped=0 filtered=1 bundle=build/test-results/verify-20260715-170409.xcresult tier=2 class=tests
```

## Plan review record (coordinator fills before downstream roles)

```
ADR review (2026-07-15): (pending) QA cleared — pipeline worker finished PM cleared — pipeline worker finished
Test spec review (2026-07-15): Architect cleared — pipeline worker finished
```

## Done gate

- [ ] Every AC mapped to a test; all rows in the mapping table filled
- [ ] **Full suite green:** unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0
- [ ] Verification record pasted above (exit code + counts + .xcresult path)
- [ ] Auto-commit made on green: `slice-29: episode cleaning summary on channel screen` (push only when the user asks)

## Tickets (optional)

| Ticket | Owner role | AC subset | Depends on |
|--------|------------|-----------|------------|
| — | — | — | — |

## Role artifacts

| Role | Gate | Artifact path |
|------|------|---------------|
| Architect | Required | `docs/adr/025-episode-cleaning-summary.md` |
| UX | Required | `docs/slices/slice-29-ux.md` |
| PM | Story (this file) | `docs/slices/slice-29-episode-cleaning-summary.md` |
| QA | Test spec after ADR plan review | `PodWashTests` / `PodWashUITests` as mapped |
| Engineer | Implement after test-spec review | `EpisodeListView` + summary model |
