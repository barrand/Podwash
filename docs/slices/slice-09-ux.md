# Slice 09 — UX spec: Analysis progress UI + cleaning toggles

| Field | Value |
|-------|-------|
| **Slice** | 09 — Analysis progress UI + cleaning toggles |
| **Screen** | `PodcastDetailView` (fixture mode; extends Slice 06 layout) |

## Layout

Extends Slice 06 layout (`slice-06-ux.md`):

1. **Podcast header** — adds a **channel cleaning toggle** to the right of the title block:
   - `Toggle` labeled "Clean channel" (visible label hidden from a11y tree; toggle carries identifiers)
   - **Channel badge** — small pill below toggle when channel cleaning is on
2. **Episode rows** — each row adds:
   - **Episode cleaning toggle** — trailing accessory on the row (UISwitch in UITableView)
   - **Episode badge** — inline text badge when episode cleaning is on (not channel-wide)
   - **Analysis progress** — `ProgressView` + "Analyzing…" on the row while pipeline runs

Only one badge type is visible per row at a time: `analyzing` suppresses on-badges; when analysis completes, the appropriate on-badge appears.

## States

| State | Visible badge / indicator | `accessibilityIdentifier` | When |
|-------|---------------------------|---------------------------|------|
| **Off** | No cleaning badge | — | Channel and episode toggles off |
| **Channel on** | Channel badge in header | `cleaningBadge_channelOn` | Channel toggle on (episode may still be off) |
| **Episode on** | Episode badge on row *i* | `cleaningBadge_episodeOn` | Episode *i* toggle on (channel may be off) |
| **Analyzing** | Progress on row *i* | `analysisProgress` | Pipeline running for episode *i* |

**Precedence on episode row:** `analyzing` > `episodeOn` > `off`. Channel badge is independent in the header.

**Combined channel + episode on:** both `cleaningBadge_channelOn` (header) and `cleaningBadge_episodeOn` (row) may be visible simultaneously.

## Accessibility identifiers

| Control / region | `accessibilityIdentifier` | `accessibilityLabel` | `accessibilityValue` |
|------------------|---------------------------|----------------------|----------------------|
| Channel cleaning toggle | `channelCleaningToggle` | `Channel cleaning` | `on` / `off` |
| Episode cleaning toggle (row *i*) | `episodeCleaningToggle_<index>` | `Episode cleaning` | `on` / `off` |
| Channel on badge | `cleaningBadge_channelOn` | `Channel cleaning on` | — |
| Episode on badge (row *i*) | `cleaningBadge_episodeOn` | `Episode cleaning on` | — |
| Analysis progress (row *i*) | `analysisProgress` | `Analyzing episode` | — |

Existing Slice 06 identifiers (`podcastTitle`, `episodeList`, `episodeCell_<index>`, etc.) are unchanged.

**Toggle interaction contract:** UI tests tap `channelCleaningToggle` and `episodeCleaningToggle_0` switches (via `switches` query). Toggles use standard `UISwitch` / SwiftUI `Toggle` so `accessibilityValue` reflects `on`/`off`.

## Fixture modes

### Feed fixture (Slice 06, reused)

Launch argument: `-UITestFixtureFeed`

Loads bundled `sample_feed.xml` as in Slice 06. Used for toggle badge tests (AC#2).

### Analysis stub fixture (new)

Launch argument: `-UITestFixtureAnalysis`

Implies `-UITestFixtureFeed` behavior (feed loads) **plus** injects an instant-completing analysis pipeline: when episode 0 cleaning is toggled on, `analysisProgress` appears briefly then completes within 1 s, leaving `cleaningBadge_episodeOn` on row 0.

Implementation: `FixtureAnalysis` enum checks launch args; `RootView` wires `AnalysisUIViewModel` with a stub `EpisodeAnalyzing` that returns immediately with an empty interval list.

## UI test scenarios

### `testToggleBadges` (AC#2)

1. Launch with `-UITestFixtureFeed`; wait for `episodeList` (10 s).
2. Assert `cleaningBadge_channelOn` and `cleaningBadge_episodeOn` do **not** exist.
3. Tap `channelCleaningToggle` switch → assert `cleaningBadge_channelOn` exists within 2 s.
4. Tap `episodeCleaningToggle_0` switch → assert `cleaningBadge_episodeOn` exists within 2 s.

### `testProgressIndicatorLifecycle` (AC#3)

1. Launch with `-UITestFixtureAnalysis`; wait for `episodeList` (10 s).
2. Tap `episodeCleaningToggle_0` switch to enable cleaning.
3. Assert `analysisProgress` exists within 2 s.
4. Assert `analysisProgress` does **not** exist within 5 s (stub completes).
5. Assert `cleaningBadge_episodeOn` exists.

## Verification mapping

| AC# | UX artifact | Test method |
|-----|-------------|-------------|
| 2 | `testToggleBadges` scenarios 1–4 | `AnalysisProgressUITests.testToggleBadges` |
| 3 | `testProgressIndicatorLifecycle` scenarios 1–5 | `AnalysisProgressUITests.testProgressIndicatorLifecycle` |
