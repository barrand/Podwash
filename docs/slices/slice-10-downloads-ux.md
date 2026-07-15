# Slice 10 — UX spec: Episode downloads

| Field | Value |
|-------|-------|
| **Slice** | 10 — Episode downloads |
| **Screen** | `PodcastDetailView` / `EpisodeListView` (fixture mode; extends Slice 06 + 09 layout) |

## Layout

Extends Slice 06/09 episode rows (`slice-06-ux.md`, `slice-09-ux.md`):

1. **Podcast header** — unchanged from Slice 06/09.
2. **Episode rows** — each row adds a **download control** in the trailing accessory area:
   - **Download button** — left of the existing episode cleaning toggle (`episodeCleaningToggle_<index>`)
   - Accessory layout: horizontal stack `[ downloadButton_<index> | episodeCleaningToggle_<index> ]`, trailing-aligned
   - **Download progress** — inline below the title/date block (same vertical band as `analysisProgress`), visible only while a download is in flight for that row

**Affordance contract:** One discrete button per row toggles download ↔ delete. No separate delete control. Icons differ by state: `arrow.down.circle` with accent tint when not downloaded; `trash` (or `trash.fill`) with **system red** tint when downloaded. UI tests key off `accessibilityValue`, not icon identity.

**Coexistence with analysis UI:** Download progress and analysis progress are independent. Both may be visible on the same row if both pipelines run (out of scope for Slice 10 UI tests; layout must not hide either indicator).

## States

| State | Download button | `downloadProgress_<index>` | `downloadButton_<index>` `accessibilityValue` |
|-------|-----------------|----------------------------|------------------------------------------------|
| **Not downloaded** | Download icon (action: start download) | Hidden / not in AX tree | `notDownloaded` |
| **Downloading** | Disabled or shows in-button spinner; not tappable | Visible | `downloading` |
| **Downloaded** | Delete/remove icon (action: delete local file) | Hidden / not in AX tree | `downloaded` |

Only one download state applies per row at a time. Initial fixture-mode launch: all rows start **not downloaded** (`accessibilityValue == "notDownloaded"`).

**Progress visibility:** `downloadProgress_<index>` exists in the accessibility tree only while state is **downloading**. When download completes or is deleted, the element must not exist (same contract as `analysisProgress` lifecycle in Slice 09).

## Accessibility identifiers

| Control / region | `accessibilityIdentifier` | `accessibilityLabel` | `accessibilityValue` | `accessibilityHint` |
|------------------|---------------------------|----------------------|----------------------|---------------------|
| Download button (row *i*) | `downloadButton_<index>` | `Download episode` when not downloaded; `Delete download` when downloaded; `Downloading episode` while in flight | `notDownloaded` / `downloading` / `downloaded` | When `downloaded`: `Removes downloaded audio from this device. Tap to delete.` Omit hint for `notDownloaded` and `downloading`. |
| Download progress (row *i*) | `downloadProgress_<index>` | `Downloading episode` | — | — |

Existing Slice 06/09 identifiers (`episodeList`, `episodeCell_<index>`, `episodeCleaningToggle_<index>`, `analysisProgress`, cleaning badges, etc.) are unchanged.

**Index convention:** `<index>` is 0-based, matching `episodeCell_<index>`. Row 0 corresponds to episode `fixture-ep-001` in the fixture feed.

**Button interaction contract:** UI tests tap `downloadButton_<index>` via `app.buttons["downloadButton_0"]` (or descendant query scoped to `episodeCell_0`). The control is a discrete `UIButton` (not a switch) so tap → state transition is deterministic.

**Cell scoping:** `downloadButton_<index>` and `downloadProgress_<index>` are exposed as accessibility elements on the row (direct children of the cell content or accessory stack), queryable globally by identifier.

## Fixture modes

### Feed fixture (Slice 06, reused)

Launch argument: `-UITestFixtureFeed`

Loads bundled `sample_feed.xml` as in Slice 06. Required for all Slice 10 UI tests.

### Download stub fixture (new)

Launch argument: `-UITestFixtureDownload`

When present, the app uses an instant-completing download path for UI tests:

- **No live network** — taps on `downloadButton_<index>` copy bundled `PodWash/PodWash/Fixtures/downloads/stub_episode_audio.bin` (1024 bytes) into the sandbox at `{downloadsDirectory}/{episodeID}.m4a` synchronously or near-instantly on the main actor.
- **Progress UI** — may flash `downloadProgress_<index>` briefly; fixture mode should complete within the AC#5 window so tests assert post-completion state, not chunked progress (chunked progress is covered by unit tests via `URLProtocol`).
- **Implies feed fixture behavior** when combined with `-UITestFixtureFeed` (same pattern as `-UITestFixtureAnalysis` + feed).

UI tests pass **both** launch arguments: `-UITestFixtureFeed` and `-UITestFixtureDownload`.

Implementation note for Engineer (not UX code): mirror `FixtureAnalysis` / `FixtureFeed` — e.g. `FixtureDownload.isEnabled` checks `ProcessInfo.processInfo.arguments` for `-UITestFixtureDownload`.

## UI test scenarios

Mapped test: `DownloadUITests.testDownloadAndDeleteButtonFlow` (AC#5).

### `testDownloadAndDeleteButtonFlow` (AC#5)

1. **Launch with fixtures** — `XCUIApplication` launched with `-UITestFixtureFeed` and `-UITestFixtureDownload`; wait for `episodeList` to exist (timeout **10 s**).
2. **Initial not-downloaded state** — assert `downloadButton_0` exists and `accessibilityValue == "notDownloaded"`; assert `downloadProgress_0` does **not** exist.
3. **Download** — tap `downloadButton_0`.
4. **Assert downloaded** — within **5 s**, assert `downloadButton_0` `accessibilityValue == "downloaded"` and `downloadProgress_0` does **not** exist.
5. **Delete** — tap `downloadButton_0` again.
6. **Assert not downloaded** — within **2 s**, assert `downloadButton_0` `accessibilityValue == "notDownloaded"`.

Scenarios 1–4 cover the download half of AC#5; scenarios 5–6 cover the delete half.

## Verification mapping

| AC# | UX artifact | Test method |
|-----|-------------|-------------|
| 5 | `testDownloadAndDeleteButtonFlow` scenarios 1–6 | `DownloadUITests.testDownloadAndDeleteButtonFlow` |
