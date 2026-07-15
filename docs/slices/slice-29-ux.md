# Slice 29 — UX spec: Episode cleaning summary (channel row)

| Field | Value |
|-------|-------|
| **Slice** | 29 — Episode cleaning summary on channel screen |
| **Screen** | `PodcastDetailView` → `EpisodeListView` episode rows (extends Slice 06 / 09 / 20 layout) |
| **ADR** | [ADR-025](../adr/025-episode-cleaning-summary.md) (aggregation, cache gate, AX contract) |
| **Builds on** | [slice-06-ux.md](slice-06-ux.md) (`episodeList`, `episodeCell_<index>`), [slice-09-ux.md](slice-09-ux.md) (cleaning toggles + badge), [slice-20-ux.md](slice-20-ux.md) (`analysisTimeline` band; mutual exclusion), [slice-26-ux.md](slice-26-ux.md) (cache-gated row affordance without playback) |
| **Slice story** | [slice-29-episode-cleaning-summary.md](slice-29-episode-cleaning-summary.md) |

## Scope note

**Episode row only.** The cleaning summary appears on podcast-detail episode rows when a **complete** `IntervalCache` entry exists for that episode. Mini-player, expanded player, Library list, CarPlay, lock screen, and transcript sheet are **out of scope**.

**Read-only chrome.** The summary is informational — no tap action, no drill-down, no re-run analysis. UI tests assert identifier presence/absence and machine-readable `accessibilityValue` only; no pixel/snapshot review.

**Processed signal.** Cache **hit** (including empty `[]`) ⇒ summary visible with counts (zeros allowed). Cache **miss** ⇒ summary **absent** from the accessibility tree.

## Layout

Extends Slice 06 / 09 / 20 episode row. Each row keeps title, date, trailing accessories (`episodeCleaningToggle_<index>`, `downloadButton_<index>`, `queueAddButton_<index>`, `episode.viewTranscript` when gated), and optional `cleaningBadge_episodeOn`.

### Cleaning summary line (`episode.cleaningSummary`)

- **Placement:** Inline **below the title/date block**, in the **same vertical band** occupied by `analysisTimeline` during analysis (Slice 20). One summary line per row that passes the complete gate.
- **Host:** UIKit accessibility host inside `EpisodeTableCell` (same pattern as `analysisTimeline` / `downloadProgress_<index>`) so XCTest resolves the identifier as a descendant of `episodeCell_<index>` **or** globally.
- **Single AX surface:** one static element per qualifying row — **no** child identifiers for individual metrics. Tests read all three values via aggregate `accessibilityValue`.
- **Visual:** secondary-style single line of compact text (`.caption` / `.footnote` Dynamic Type, `secondary` foreground). Non-interactive — no button chrome, no chevron.
- **Coexistence:** May appear alongside `downloadProgress_<index>`, trailing toggles/buttons, and `cleaningBadge_episodeOn` (badge is a separate inline indicator; summary does **not** replace the badge). Must **not** appear alongside `analysisTimeline` on the same row.

### Visible copy (human-readable)

Pipe three metrics left → right with a middle dot separator (` · `, U+00B7 with spaces):

```text
<profanityCount> profanity · <adCount> ads · <formattedAdMinutes> ads
```

| Case | Example visible string |
|------|------------------------|
| Pinned fixture (AC1 / AC5) | `2 profanity · 2 ads · 1.5 min ads` |
| Analyzed, no hits (AC2) | `0 profanity · 0 ads · 0.0 min ads` |
| Rounding pin (AC3, unit-only; illustrative layout) | `0 profanity · 1 ad · 0.8 min ads` |

**Copy pins:**

- **Profanity** and **ad** section labels use natural count grammar: `0 profanity`, `1 profanity`, `2 profanity`; `0 ads`, `1 ad`, `2 ads`.
- **Minutes** reuse `formattedAdMinutes` from `CleaningSummaryModel` exactly (`1.5 min`, `0.0 min`, `0.8 min`) followed by the word **`ads`** to clarify the duration metric (total skipped unrelated-content time).
- Engineer may use `Text` composition or a single `UILabel`; UX pins the **string contract** above, not font metrics.

## States

### Episode row analysis / summary display

| State | Analysis band | `accessibilityIdentifier` | `accessibilityValue` | Notes |
|-------|---------------|---------------------------|----------------------|-------|
| **Never analyzed** (cache miss) | Empty | — | — | No summary element in AX tree (AC4) |
| **Analyzing** (in flight) | Segmented timeline | `analysisTimeline` | `ready:N,processing:N,pending:N` | Summary **must not exist** (AC6); Slice 20 unchanged |
| **Complete + cache hit** | Summary line | `episode.cleaningSummary` | `profanity:N,ads:N,adMinutes:X.X` | Timeline cleared; summary appears (AC5) |
| **Complete + empty intervals** | Summary with zeros | `episode.cleaningSummary` | `profanity:0,ads:0,adMinutes:0.0` | “Processed” with no hits (AC2) |
| **Complete + cache miss** (fingerprint drift) | Empty | — | — | Same as never analyzed until re-analyze |

**Precedence in analysis band:** `analyzing` (`analysisTimeline`) **>** `complete` (`episode.cleaningSummary`) **>** empty.

**Mutual exclusion (normative):** A row must **never** expose both `analysisTimeline` and `episode.cleaningSummary` at the same time.

**Cleaning toggle independence:** Summary visibility follows **cache + complete gate only** — not the episode/channel cleaning toggle. An episode may show a summary while cleaning is off (cache from a prior analyze). Conversely, `cleaningBadge_episodeOn` may show without a summary when cleaning is on but analysis has not completed.

**No loading/error states** for the summary itself — cache lookup is synchronous on row bind; if intervals are not yet on disk, omit the element (do not show a spinner identifier).

### Summary `accessibilityValue` format

Machine-readable aggregate (pinned for AC5):

```text
profanity:<int>,ads:<int>,adMinutes:<one-decimal>
```

- **No spaces** around commas or colons.
- **`profanity`** = profanity section count (all `.profanity` intervals, any action).
- **`ads`** = unrelated-content section count (all `.unrelatedContent` intervals).
- **`adMinutes`** = numeric portion of `formattedAdMinutes` only — **no** ` min` suffix. One decimal digit always (e.g. `1.5`, `0.0`, `0.8`).

**Pinned fixture example:** `profanity:2,ads:2,adMinutes:1.5`

**Aggregation source:** `[CensorInterval]` from `IntervalCache.load` — see ADR-025 §3–§4 and slice pinned table (independent provenance, not derived from implementation).

## Accessibility identifiers

| Control / region | `accessibilityIdentifier` | `accessibilityLabel` | `accessibilityValue` | `accessibilityHint` |
|------------------|---------------------------|----------------------|----------------------|---------------------|
| Cleaning summary (row *i*, complete + cache) | `episode.cleaningSummary` | `Cleaning summary` | `profanity:N,ads:N,adMinutes:X.X` | `Shows how many profanity and ad sections were cleaned and total ad time skipped.` |
| Analysis timeline (row *i*, analyzing) | `analysisTimeline` | `Analysis timeline` | `ready:N,processing:N,pending:N` | Unchanged Slice 20 |
| Episode on badge (row *i*) | `cleaningBadge_episodeOn` | `Episode cleaning on` | — | Unchanged Slice 09 |
| Episode cleaning toggle (row *i*) | `episodeCleaningToggle_<index>` | `Episode cleaning` | `on` / `off` | Unchanged Slice 09 |

**Traits:** `episode.cleaningSummary` is static text (`accessibilityTraits` excludes `.button`). Not hittable for an action; row tap-to-play (`textStack` / `episodeCell_<index>`) unchanged.

**Unchanged Slice 06 identifiers:** `episodeList`, `episodeCell_<index>`, `podcastTitle`, etc.

**Cell scoping:** Prefer querying within `app.cells["episodeCell_0"]` (or `otherElements`) descendants; fall back to `app.descendants(matching: .any)["episode.cleaningSummary"]` (same pattern as `analysisTimeline` helpers in `AnalysisTimelineUITests`).

**AX children:** When summary is visible, include the summary host in the cell’s `accessibilityElements` array (parallel to `progressAccessibilityHost` for timeline). Assign identifier only while visible; set `nil` when hidden.

## Fixture modes

### Cleaning summary seeded (new — AC5)

Launch argument: `-UITestFixtureCleaningSummary`

| Concern | Value |
|---------|-------|
| Feed | Implies `-UITestFixtureFeed` (`sample_feed.xml`, `RootView` → `PodcastDetailView`) |
| Cache | `IntervalCache` seeded for **row 0** episode ID with **pinned intervals** (below) |
| Analysis state | **Not in-flight** — `analyzingEpisodeID` nil; no `analysisTimeline` on row 0 at launch |
| Target words / ASR pin | Same as running app (`SettingsStore.activeNormalizedTargetSet()`, ADR-024 pin) — fixture `prepare` must match or `load` misses |

**Pinned intervals (independent provenance — AC1):**

| # | `start` | `end` | `action` | `source` |
|---|---------|-------|----------|----------|
| 1 | 10.0 | 11.0 | mute | profanity |
| 2 | 20.0 | 21.5 | mute | profanity |
| 3 | 30.0 | 90.0 | skip | unrelatedContent |
| 4 | 100.0 | 130.0 | skip | unrelatedContent |

**Expected summary:** visible `2 profanity · 2 ads · 1.5 min ads`; AX value `profanity:2,ads:2,adMinutes:1.5`.

**Typical launch:** `-UITestFixtureCleaningSummary` only (feed implied).

### No cache control (AC4)

Launch argument: `-UITestFixtureFeed`

Unchanged Slice 06 feed fixture — **no** `IntervalCache` seed for any episode. Row 0 must **not** expose `episode.cleaningSummary`.

Do **not** combine `-UITestFixtureCleaningSummary` with feed-only negative tests.

### In-flight timeline (AC6 — reuses Slice 20)

Launch argument: `-UITestFixtureAnalysisTimeline`

Same stepped analyzer contract as [slice-20-ux.md](slice-20-ux.md): auto-analyze on row 0 cleaning toggle; `analysisTimeline` appears while in flight. **`episode.cleaningSummary` must not exist** on row 0 until terminal complete (timeline retires). After terminal + cache store, summary may appear — AC6 asserts only the **in-flight** negative.

## UI test scenarios

Mapped tests: `CleaningSummaryUITests.swift` (AC4–AC6). Unit scenarios AC1–AC3 are model tests (no UX steps).

**Query helpers:** wait for `episodeList` (timeout **10 s**); resolve `episode.cleaningSummary` via cell-scoped or global descendant search; assert `accessibilityValue` with **exact** string match.

### `testSummaryAbsentWithoutCache` (AC#4)

1. Launch with `-UITestFixtureFeed`; wait for `episodeList` (10 s).
2. Within **2.0 s** of `episodeList` appearing, assert `episode.cleaningSummary` does **not** exist (scoped to `episodeCell_0` and global descendant query).

### `testSummaryShowsPinnedCountsWhenCached` (AC#5)

1. Launch with `-UITestFixtureCleaningSummary`; wait for `episodeList` (10 s).
2. Within **5.0 s**, assert `episode.cleaningSummary` exists (row 0 scope or global).
3. Assert `episode.cleaningSummary` `accessibilityValue` equals exactly **`profanity:2,ads:2,adMinutes:1.5`**.
4. *(Optional sanity, not separate AC:)* assert `accessibilityLabel` equals **`Cleaning summary`**.

### `testSummaryHiddenWhileTimelineInFlight` (AC#6)

1. Launch with `-UITestFixtureAnalysisTimeline`; wait for `episodeList` (10 s).
2. Tap `episodeCleaningToggle_0` switch to enable cleaning (auto-analyze starts).
3. Within **2.0 s**, assert `analysisTimeline` exists on row 0.
4. Assert `episode.cleaningSummary` does **not** exist (cell-scoped and global) while timeline is visible.
5. *(Optional post-terminal check, not AC6:)* after timeline completes per Slice 20, summary may appear if cache was stored — AC6 does **not** require asserting post-complete summary in this test.

**Implementation note:** For step 4, poll immediately after timeline appears; do not wait for analysis completion. Reuse `AnalysisTimelineUITests` launch/toggle helpers where practical.

## Verification mapping

| AC# | UX artifact | Test file / method |
|-----|-------------|-------------------|
| 1 | Pinned fixture table + `accessibilityValue` shape | `CleaningSummaryModelTests.testPinnedFixtureCountsAndFormattedMinutes` |
| 2 | Zero / source-filter copy + `profanity:0,ads:0,adMinutes:0.0` | `CleaningSummaryModelTests.testEmptyAndSourceFilters` |
| 3 | `0.8 min` rounding pin | `CleaningSummaryModelTests.testAdMinutesRoundsHalfUpToOneDecimal` |
| 4 | `testSummaryAbsentWithoutCache` | `CleaningSummaryUITests.testSummaryAbsentWithoutCache` |
| 5 | `testSummaryShowsPinnedCountsWhenCached` | `CleaningSummaryUITests.testSummaryShowsPinnedCountsWhenCached` |
| 6 | `testSummaryHiddenWhileTimelineInFlight` | `CleaningSummaryUITests.testSummaryHiddenWhileTimelineInFlight` |
