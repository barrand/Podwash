# Slice 06 — UX spec: RSS feed + episode list

| Field | Value |
|-------|-------|
| **Slice** | 06 — RSS feed + episode list UI |
| **Screen** | `PodcastDetailView` (fixture mode root; future: navigation destination after subscribe) |

## Layout

Vertical stack, full width:

1. **Podcast header** — horizontal row:
   - **Artwork** — square channel image when the feed provides an artwork URL; placeholder icon when absent
   - **Title block** — podcast title (primary), optional author/subtitle (secondary, smaller)
2. **Episode list** — SwiftUI `List` of episodes, newest first (matching fixture order in `sample_feed_expected.json`)

Each episode row shows:

- **Title** — primary line, up to two lines before truncation
- **Published date** — secondary line, localized short date (e.g. `Jan 15, 2026`)

No show-notes expansion, playback controls, or download affordances in this slice.

## States

| State | Visible UI | Root `accessibilityIdentifier` | Notes |
|-------|------------|----------------------------------|-------|
| **Loading** | Centered `ProgressView` + "Loading episodes…" copy | `feed.loading` | Shown while the feed is fetched/parsed in fixture or network mode |
| **Loaded** | Podcast header + episode `List` | `episodeList` on the `List` | Default happy path for `-UITestFixtureFeed` |
| **Error** | Inline message (feed title or "Podcast" + error summary) + **Retry** button | `feed.error` | Typed error from view model (e.g. network failure); no crash |
| **Empty** | Podcast header (if channel metadata parsed) + "No episodes yet" empty copy | `feed.empty` | Valid feed with zero `<item>` elements |

Only one state root identifier is visible at a time. The podcast header (`podcastTitle`, `podcastArtwork`) is shown in **loaded** and **empty** when channel metadata is available; hidden in **loading** and **error**.

## Accessibility identifiers

| Control / region | `accessibilityIdentifier` | `accessibilityLabel` | `accessibilityValue` |
|------------------|---------------------------|----------------------|----------------------|
| Podcast title | `podcastTitle` | `Podcast title` | Channel title string from parsed feed (e.g. golden `channel.title`) |
| Podcast artwork | `podcastArtwork` | `Podcast artwork` | `loaded` when image rendered; `placeholder` when using fallback icon |
| Episode list (`List`) | `episodeList` | `Episodes` | Episode count as decimal string (e.g. `3`, `12`) |
| Episode row *i* (0-based) | `episodeCell_<index>` | Episode title (full string, matches visible title) | ISO-8601 date string from fixture (e.g. `2026-01-15T08:00:00Z`) — same field as golden `episodes[i].pubDate` |
| Loading indicator | `feed.loading` | `Loading episodes` | — |
| Error panel | `feed.error` | `Feed error` | Short error kind for UI tests (e.g. `networkFailure`, `parseFailure`) |
| Error retry button | `feed.retry` | `Retry` | — |
| Empty state | `feed.empty` | `No episodes` | — |

**Cell label contract (AC#4):** UI tests read each cell via `app.cells["episodeCell_<index>"]` (or `otherElements` if not exposed as cells) and assert `label ==` the episode title. The title in `accessibilityLabel` must equal the golden `episodes[index].title` exactly — no date suffix in the label (date lives in `accessibilityValue` only).

**Index convention:** `episodeCell_0` is the first row in the list (newest episode per fixture ordering).

## Fixture mode

Launch argument: `-UITestFixtureFeed`

App loads bundled `sample_feed.xml` from the **app** bundle (`PodWash/Fixtures/feeds/sample_feed.xml` — a copy of the unit-test fixture; UI tests cannot read `PodWashTests`). `RootView` routes directly to `PodcastDetailView` with no navigation required.

Expected content is defined by `PodWash/PodWashTests/Fixtures/feeds/sample_feed_expected.json` (hand-transcribed golden). UI and unit tests share the same expected titles and dates.

## UI test scenarios

Mapped test: `EpisodeListUITests.testEpisodeListRendersFixtureTitles` (AC#4).

1. **Launch with fixture** — `XCUIApplication` launched with `-UITestFixtureFeed`; wait for `episodeList` to exist (timeout 10 s). Assert `feed.loading` does **not** exist after load completes.
2. **List container** — assert `episodeList` exists and `episodeList` `accessibilityValue` equals the golden episode count as a decimal string.
3. **First cell title** — assert `episodeCell_0` `label` equals `episodes[0].title` from `sample_feed_expected.json`.
4. **Second cell title** — assert `episodeCell_1` `label` equals `episodes[1].title` from `sample_feed_expected.json`.
5. **Third cell title** — assert `episodeCell_2` `label` equals `episodes[2].title` from `sample_feed_expected.json`.

Scenarios 3–5 are the AC#4 assertion: the first three cells' labels match the first three fixture titles. Scenarios 1–2 establish that the list rendered in fixture mode before title checks run.

**Optional sanity checks** (same test method, not separate ACs): when the golden channel includes artwork/title, assert `podcastTitle` exists and its `accessibilityValue` equals golden `title`; assert `episodeCell_0` `value` equals `episodes[0].pubDate`.

## Verification mapping

| AC# | UX artifact | Test method |
|-----|-------------|-------------|
| 4 | Scenarios 1–5 above | `EpisodeListUITests.testEpisodeListRendersFixtureTitles` |
