# Slice 23 — UX spec: Library & player shell

| Field | Value |
|-------|-------|
| **Slice** | 23 — Library & player shell |
| **Screens** | `AppShellView` (`TabView`), `LibraryView`, `MiniPlayerBar`, expanded `PlaybackControlsView` (sheet) |
| **ADR** | [ADR-015](../adr/015-app-shell-navigation.md) §2–§6 (navigation graph, identifiers, fixtures, play orchestration) |
| **Builds on** | Slice 22 (`DiscoverView`, golden titles); Slice 06 (`PodcastDetailView`, `episodeList`, `episodeCell_*`); Slice 03 (`playback.playPause` contract); Slice 13 (`settingsButton`) |

## Layout

Production cold launch (no exclusive fixture args) shows **`AppShellView`**: a `TabView` with a **mini-player overlay** pinned directly above the tab bar when a playback session is active.

### Tab bar (`TabView`)

Two tabs, left → right:

| Tab | Visible title | `accessibilityIdentifier` | Root content |
|-----|---------------|---------------------------|--------------|
| **Library** | `Library` | `tabLibrary` | `NavigationStack` → `LibraryView` |
| **Discover** | `Discover` | `tabDiscover` | `NavigationStack` → `DiscoverView` (Slice 22) |

**Default selection:** Library tab on launch (including `-UITestFixtureLibrary` and `-UITestFixtureLibraryEmpty`).

**Toolbar (both tabs):** trailing **Settings** affordance (`settingsButton`, Slice 13) pushes `SettingsView` inside that tab’s `NavigationStack`.

### Library tab (`libraryRoot`)

When `subscriptionCount > 0`:

1. **Subscription list** (`libraryList`) — vertical list of subscribed shows, ordered by store (`subscribedAt` ascending, then `feedURLString`).
2. Each row (`libraryCell_<index>`): podcast artwork (when available), **title** as primary line (up to two lines). No swipe actions or unsubscribe in this slice.

When `subscriptionCount == 0`:

1. **Empty state** (`libraryEmptyState`) — centered message + primary CTA (see States).

**Navigation:** tap `libraryCell_<index>` → push `PodcastDetailView` with existing `EpisodeListView` (identifiers unchanged from Slice 06). Back navigation returns to the library list.

### Discover tab

Unchanged Slice 22 `DiscoverView` (`discoverRoot`). Subscribing on Discover does not auto-switch tabs; user returns to Library manually (library reloads on appear).

### Episode play

From `PodcastDetailView`, **tap an episode row** (`episodeCell_<index>`) → start playback via `AppShellModel.playEpisode` (no separate play icon required in this slice). Row tap does **not** push another screen; user remains on the episode list with mini-player visible.

### Mini-player bar (`MiniPlayerBar`)

Shown when `AppShellModel.isMiniPlayerVisible == true` (after a successful episode play start). Pinned **above** the tab bar; does not cover tab items.

Horizontal bar, leading → trailing:

1. **Artwork** — small square (episode or show art when available; placeholder when absent). No separate `accessibilityIdentifier` (title + transport are the test contract).
2. **Text block** — episode title (primary, one line truncated), show title (secondary, optional).
3. **Play/Pause** — discrete `Button` (`miniPlayerPlayPause`).

The bar chrome outside the play button is the **expand** target (`miniPlayer`).

**Persistence:** mini-player stays visible while switching Library ↔ Discover, while browsing episode lists, and while the full-player sheet is open. Hide only when playback is **stopped** and the session is torn down (no AC-mapped stop control in this slice; future slices may add explicit dismiss).

### Expanded full player

**Presentation:** `.sheet` hosting existing `PlaybackControlsView` (`isFullPlayerPresented`). UX pins **sheet** (not push) so episode-list navigation stack is preserved underneath.

**Open:** tap `miniPlayer` (bar chrome, **not** `miniPlayerPlayPause`).

**Close:** system sheet dismiss (swipe down) or optional trailing **Done** control — not slice-AC-mapped. After dismiss, `miniPlayer` remains visible; `playback.playPause` is not in the tree until re-expanded.

**Content:** Slice 03 transport row (`playback.playPause`, seek buttons, elapsed) plus Slice 12 speed/sleep controls when wired — identifiers unchanged.

### Z-order (bottom → top)

```text
TabView (Library | Discover)
MiniPlayerBar (when visible)
Full player sheet (when presented)
```

**Out of scope (no new UI in this slice):** CarPlay, visual identity pass (Slice 21), unsubscribe, library search/sort, queue/download/cleaning UI redesign, paywall, deep links, subjective “feels like a podcast app” review.

## States

### App shell

| State | Visible UI | Notes |
|-------|------------|-------|
| **Ready (no playback)** | Tab bar + active tab content only | Default cold launch before any episode play |
| **Playing (mini-player)** | Tab content + `miniPlayer` + `miniPlayerPlayPause` | After episode row tap succeeds |
| **Full player open** | Above + sheet with `playback.playPause` | `isFullPlayerPresented == true` |

### Library tab

| State | Visible UI | Root / region identifier | Notes |
|-------|------------|--------------------------|-------|
| **Loaded (subscriptions)** | `libraryList` + `libraryCell_0` … | `libraryRoot` | Fixture: exactly **2** cells with golden titles |
| **Empty** | Message + Discover CTA | `libraryEmptyState` | `subscriptionCount == 0`; see empty copy below |
| **Loading** (optional) | Inline `ProgressView` at list top | `library.loading` | Only if async reload is introduced; **not** fixture-mapped — fixture seed is synchronous before first frame |

Only one of `libraryList` or `libraryEmptyState` is visible at a time.

**Empty copy (AC#7):** headline **No subscriptions yet**; body includes the word **Discover** (exact substring, case-sensitive) — e.g. *“Discover podcasts to build your library.”* Primary CTA button label **Discover podcasts** (also contains **Discover**).

### Mini-player play state (`miniPlayerPlayPause`)

| State | `accessibilityValue` | `accessibilityLabel` |
|-------|----------------------|----------------------|
| **Paused** | `paused` | `Play` |
| **Playing** | `playing` | `Pause` |

Same semantics as Slice 03 `playback.playPause`. Value must update on the main actor before XCTest post-tap idle.

### Expanded full player

Inherits Slice 03 play/pause states on `playback.playPause`. Sheet presence is asserted by identifier existence only (AC#4b).

## Accessibility identifiers

### Tab bar

| Control | `accessibilityIdentifier` | `accessibilityLabel` | `accessibilityValue` | `accessibilityHint` |
|---------|---------------------------|----------------------|----------------------|---------------------|
| Library tab | `tabLibrary` | `Library` | — | `Shows your subscribed podcasts.` |
| Discover tab | `tabDiscover` | `Discover` | — | `Search and subscribe to podcasts.` |

### Library

| Control / region | `accessibilityIdentifier` | `accessibilityLabel` | `accessibilityValue` | `accessibilityHint` |
|------------------|---------------------------|----------------------|----------------------|---------------------|
| Library screen root | `libraryRoot` | `Library` | — | — |
| Subscription list | `libraryList` | `Subscriptions` | Subscription count as decimal string (e.g. `2`) | — |
| Empty state container | `libraryEmptyState` | Copy containing **Discover** (see Empty copy) | — | — |
| Empty → Discover CTA | `libraryEmptyDiscoverButton` | `Discover podcasts` | — | `Opens the Discover tab.` |
| Subscription row *i* | `libraryCell_<index>` | Subscription **title** (substring match for tests) | — | `Opens episodes for this podcast.` |
| Optional load spinner | `library.loading` | `Loading library` | — | — |

**Cell label contract (AC#2):** `libraryCell_0` label contains golden title 0 **`Fixture Popular Alpha`**; `libraryCell_1` contains **`Fixture Popular Beta`** — substring match, **case-sensitive**. Titles sourced from `itunes_popular_response.json` entries 0 and 1 (`collectionName`).

**Index convention:** `<index>` is **0-based** in store order (`allSubscriptions()`).

### Mini-player

| Control | `accessibilityIdentifier` | `accessibilityLabel` | `accessibilityValue` | `accessibilityHint` |
|---------|---------------------------|----------------------|----------------------|---------------------|
| Bar chrome (expand) | `miniPlayer` | Episode title (or `Now playing`) | — | `Opens full playback controls.` |
| Play/Pause on bar | `miniPlayerPlayPause` | `Play` / `Pause` | `playing` / `paused` | — |

**Hit targeting:** `miniPlayerPlayPause` is a child control; taps on it must **not** expand the sheet. XCTest uses the play button element for AC#4 and the bar container (or a non-button region) for AC#4b.

### Settings (unchanged Slice 13)

| Control | `accessibilityIdentifier` | `accessibilityLabel` |
|---------|---------------------------|----------------------|
| Settings entry | `settingsButton` | `Settings` |

Present and hittable on **both** Library and Discover tab roots (AC#5 asserts from Library only).

### Episode list & playback (unchanged)

Reuse Slice 06 `episodeList`, `episodeCell_<index>` and Slice 03 `playback.playPause` without renaming.

### Discover (unchanged Slice 22)

`discoverRoot` and related identifiers unchanged when reached via `tabDiscover` or empty-library CTA.

**Discrete controls:** play/pause and empty-state CTA are `Button`s, not sliders. UI tests query via `app.buttons[...]` or descendant search on `XCUIApplication`, consistent with Slices 03–22.

## Fixture modes

### `-UITestFixtureLibrary` (seeded library)

When present (and no higher-precedence exclusive fixture wins):

1. `PodWashApp` uses in-memory Core Data (`PersistenceController.inMemory(identifier: "uitest-library")`).
2. `FixtureLibrary.prepareSeededStore` runs before `AppShellView` appears.
3. Seeds **exactly 2** subscriptions with golden popular titles 0 and 1; **5** episodes each from bundled `sample_feed.xml` with namespaced episode IDs (`lib-0-*`, `lib-1-*` per ADR-015).
4. Lands on **Library** tab; **no live network** for Library → detail → play.
5. Episode play resolves **bundled `FixtureAudio` clip** (Slice 03 path), not enclosure URLs.

**Golden titles:**

| Index | `collectionName` |
|-------|------------------|
| 0 | `Fixture Popular Alpha` |
| 1 | `Fixture Popular Beta` |

**Typical launch arguments (AC-mapped UI tests):** `-UITestFixtureLibrary` **only**. Do **not** combine with `-UITestFixtureFeed`, `-UITestFixtureAudio`, `-UITestFixtureDiscover`, or other exclusive fixtures.

### `-UITestFixtureLibraryEmpty` (empty library)

1. Same in-memory persistence policy as seeded mode.
2. `FixtureLibrary.prepareEmptyStore` → `subscriptionCount == 0`.
3. Lands on Library tab with `libraryEmptyState` visible.

**Typical launch arguments:** `-UITestFixtureLibraryEmpty` only.

### Production (no library fixture args)

Cold launch shows `AppShellView` with real persistence; Library may be empty or populated from user data. Slice 23 ACs **do not** map production UI tests without fixtures except where noted — unit test AC#1 uses in-memory store in `LibraryViewModelTests`.

## UI test scenarios

Mapped tests live in `LibraryUITests.swift`. Scenarios below are the authoritative UX contract for slice AC#2–#7; AC#1 is unit-tested; AC#8 is command-level.

**Global query:** use `app.descendants(matching: .any)["<identifier>"]` (or typed queries) with **5 s** timeouts where the slice pins timing, **10 s** for initial shell appearance if bootstrap spinner is added.

### `testLibraryRendersSeededSubscriptions` (AC#2)

1. **Launch** — `XCUIApplication` with **only** `-UITestFixtureLibrary`; wait for `libraryRoot` (timeout **5 s**).
2. **List cells** — assert `libraryCell_0` and `libraryCell_1` exist.
3. **Title 0** — assert `libraryCell_0` `label` contains `Fixture Popular Alpha` (substring, case-sensitive).
4. **Title 1** — assert `libraryCell_1` `label` contains `Fixture Popular Beta` (substring, case-sensitive).

Steps 2–4 are the AC#2 assertion. Launch must **not** include `-UITestFixtureFeed`, `-UITestFixtureAudio`, or `-UITestFixtureDiscover`.

### `testTapShowOpensEpisodeList` (AC#3)

1. **Launch** — `-UITestFixtureLibrary`; wait for `libraryRoot` and `libraryCell_0`.
2. **Open show** — tap `libraryCell_0`.
3. **Episode list** — within **5 s**, assert `episodeList` exists.
4. **First episodes** — assert `episodeCell_0`, `episodeCell_1`, and `episodeCell_2` exist (first three episodes from `sample_feed.xml` for show 0).

### `testTapEpisodeShowsMiniPlayerAndPlays` (AC#4)

1. **Launch** — `-UITestFixtureLibrary`; tap `libraryCell_0`; wait for `episodeList`.
2. **Play episode** — tap `episodeCell_0`.
3. **Mini-player** — within **5 s**, assert `miniPlayer` exists.
4. **Play** — tap `miniPlayerPlayPause`; within **5 s**, assert `miniPlayerPlayPause` `accessibilityValue == "playing"`.

Step 4 is the AC#4 timing assertion (Slice 03 play-state contract).

### `testMiniPlayerExpandsToFullControls` (AC#4b)

1. **Launch** — `-UITestFixtureLibrary`; navigate to episode list via `libraryCell_0`; tap `episodeCell_0`; wait for `miniPlayer`.
2. **Expand** — tap `miniPlayer` (bar chrome, **not** `miniPlayerPlayPause`).
3. **Full controls** — within **5 s**, assert `playback.playPause` exists.

### `testSettingsReachableFromLibrary` (AC#5)

1. **Launch** — `-UITestFixtureLibrary`; wait for `libraryRoot`.
2. **Settings** — assert `settingsButton` exists and `isHittable == true`.

### `testDiscoverEntryFromLibrary` (AC#6)

1. **Launch** — `-UITestFixtureLibrary`; wait for `libraryRoot`.
2. **Switch tab** — tap `tabDiscover`.
3. **Discover** — within **5 s**, assert `discoverRoot` exists.

### `testEmptyLibraryShowsDiscoverPrompt` (AC#7)

1. **Launch** — `XCUIApplication` with **only** `-UITestFixtureLibraryEmpty`; wait for `libraryRoot` (timeout **5 s**).
2. **Empty state** — assert `libraryEmptyState` exists; assert `libraryEmptyState` `label` contains **`Discover`** (exact substring, case-sensitive).
3. **Navigate** — tap `libraryEmptyDiscoverButton` (or the documented primary CTA inside `libraryEmptyState`).
4. **Discover** — within **5 s**, assert `discoverRoot` exists.

Step 2–4 satisfy AC#7 empty → Discover flow without network.

### UX smoke scenarios (not slice ACs; optional QA coverage)

#### `testMiniPlayerPersistsAcrossTabSwitch` (optional)

1. Launch `-UITestFixtureLibrary`; play via `libraryCell_0` → `episodeCell_0`; assert `miniPlayer` exists.
2. Tap `tabDiscover`; assert `discoverRoot` exists and `miniPlayer` still exists.
3. Tap `tabLibrary`; assert `libraryRoot` exists and `miniPlayer` still exists.

#### `testMiniPlayerPlayPauseToggles` (optional)

1. After AC#4 setup with `miniPlayerPlayPause` showing `playing`, tap again; within **5 s** assert `accessibilityValue == "paused"`.

#### `testSettingsReachableFromDiscover` (optional)

1. Launch `-UITestFixtureLibrary`; tap `tabDiscover`; assert `settingsButton` `isHittable == true`.

## Verification mapping

| AC# | UX artifact | Test method | Notes |
|-----|-------------|-------------|-------|
| 1 | — | `LibraryViewModelTests.testLibraryListsAllSubscriptionsAfterReload` | Unit; not UX-authored |
| 2 | `testLibraryRendersSeededSubscriptions` scenarios 1–4 | `LibraryUITests.testLibraryRendersSeededSubscriptions` | Library fixture only; golden title substrings |
| 3 | `testTapShowOpensEpisodeList` scenarios 1–4 | `LibraryUITests.testTapShowOpensEpisodeList` | Show → episode list |
| 4 | `testTapEpisodeShowsMiniPlayerAndPlays` scenarios 1–4 | `LibraryUITests.testTapEpisodeShowsMiniPlayerAndPlays` | `miniPlayer` + `"playing"` within 5 s |
| 4b | `testMiniPlayerExpandsToFullControls` scenarios 1–3 | `LibraryUITests.testMiniPlayerExpandsToFullControls` | Tap bar → `playback.playPause` |
| 5 | `testSettingsReachableFromLibrary` scenarios 1–2 | `LibraryUITests.testSettingsReachableFromLibrary` | `settingsButton` hittable |
| 6 | `testDiscoverEntryFromLibrary` scenarios 1–3 | `LibraryUITests.testDiscoverEntryFromLibrary` | Tab → `discoverRoot` |
| 7 | `testEmptyLibraryShowsDiscoverPrompt` scenarios 1–4 | `LibraryUITests.testEmptyLibraryShowsDiscoverPrompt` | Empty fixture; **Discover** substring |
| 8 | — | `scripts/verify.sh` | Command-level; not UX-authored |
