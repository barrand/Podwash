# Slice 22 — UX spec: Discovery & subscribe

| Field | Value |
|-------|-------|
| **Slice** | 22 — Discovery & subscribe |
| **Screen** | `DiscoverView` (fixture-mode root; production shell entry is Slice 23) |
| **ADR** | [ADR-014](../adr/014-discovery-itunes-multi-sub.md) §6–§8 (view model, identifiers, fixture routing) |

## Layout

Single scrollable screen (`discoverRoot`). Top → bottom:

1. **Search** — one `TextField` (`discoverSearchField`) with placeholder copy **Search podcasts** (visible text; not a separate AX element).
2. **Results region** — one list area below search; content depends on mode (see States):
   - **Popular mode** (default after load; active when `searchResults` is empty): up to 25 rows from `fetchPopular()`, fixture shows **3** rows.
   - **Search mode** (active when `searchResults` is non-empty): rows from debounced `search(term:)`, fixture shows **2** rows for term `fixture-query`.

Each result row (popular or search) is a horizontal row:

- **Artwork** — square podcast artwork when `artworkURL` is present; system placeholder when absent. No separate `accessibilityIdentifier` on artwork in this slice (title + subscribe are the test contract).
- **Title** — primary line, up to two lines before truncation; drives the row `accessibilityLabel` (see Accessibility identifiers).
- **Subscribe** — trailing discrete `Button` (`subscribeButton_<index>`). Not a toggle/switch — `accessibilityValue` carries subscribed state for XCTest.

**List mode rule:** When `searchResults` is non-empty, **hide** the popular list and show only search rows (`searchResultCell_*`). When the search field is cleared (empty / whitespace-only term), `searchResults` clears and the popular list returns.

**Out of scope (no UI in this slice):** library tab, subscribed-podcast management, unsubscribe, production `TabView` / root navigation (Slice 23), manual paste-feed URL, recommendations, paywall gating.

## States

### Screen root

| State | Visible UI | Root `accessibilityIdentifier` | Notes |
|-------|------------|--------------------------------|-------|
| **Bootstrap** (fixture only) | `ProgressView` while `RootView` wires stub session + view model | `discover.loading` | Must resolve to `discoverRoot` within **10 s** |
| **Ready** | Search field + results region | `discoverRoot` | Default interactive shell |

### Popular list (`loadPhase`)

| State | Visible UI | Identifier | Notes |
|-------|------------|------------|-------|
| **Loading** | `ProgressView` in results region (or inline at list top) | `discoverPopular.loading` | Shown while `loadPopular()` is in flight on first appear |
| **Loaded** | `popularCell_0` … `popularCell_<n-1>` | `popularCell_<index>` | Fixture: **3** cells; production: up to 25 |
| **Failed** | Inline message **Couldn’t load podcasts** + **Retry** button | `discoverPopular.error`, `discoverPopular.retry` | Typed network/parse failure; popular rows hidden |
| **Empty** | **No podcasts found** copy | `discoverPopular.empty` | Successful parse with zero results (not fixture-mapped) |

Only one popular-phase identifier (`discoverPopular.loading` / `.error` / `.empty` / row cells) is meaningful at a time. After **loaded**, `discoverPopular.loading` is not in the AX tree.

### Search results

| State | Visible UI | Identifier | Notes |
|-------|------------|------------|-------|
| **Idle** | Popular list visible (if loaded) | — | Empty / whitespace search term; no network call |
| **Loading** | Optional inline `ProgressView` below search field | `discoverSearch.loading` | While debounced search task is in flight |
| **Loaded** | `searchResultCell_0` … | `searchResultCell_<index>` | Fixture term `fixture-query` → **2** cells |
| **Failed** | Inline **Search failed** + **Retry** | `discoverSearch.error`, `discoverSearch.retry` | Not slice-AC-mapped |
| **Empty** | **No results** copy | `discoverSearch.empty` | Successful search with zero hits |

When search is **loaded** with ≥1 result, popular rows are hidden.

### Subscribe (per active list index)

Product decision (2026-07-10): **loading on the tapped row** — no optimistic library row (library is Slice 23).

| State | Row UI | `subscribeButton_<index>` | `accessibilityValue` |
|-------|--------|---------------------------|----------------------|
| **Not subscribed** | Normal row | Enabled | `"0"` |
| **Loading** | Inline `ProgressView` on the tapped row (trailing or overlay); other rows unchanged | Present; may be disabled | `"0"` (unchanged until success) |
| **Subscribed** | Normal row | Enabled (idempotent re-tap is no-op) | `"1"` |
| **Failed** (RSS/network) | Inline error on row or brief banner; row returns to idle | Enabled | `"0"` |

`subscribeState` is view-model typed (`idle` / `loading(index:)` / `succeeded(index:)` / `failed` per ADR-014 §6). UI failure affordance is UX-complete but **not** slice-AC-mapped (AC#5 covers VM `failed` in unit tests only).

**Active list for subscribe:** If `searchResults` is non-empty, `subscribe(atIndex:)` and all `subscribeButton_<index>` / `searchResultCell_<index>` refer to **search** indices. Otherwise indices refer to **popular** rows.

## Accessibility identifiers

| Control / region | `accessibilityIdentifier` | `accessibilityLabel` | `accessibilityValue` | `accessibilityHint` |
|------------------|---------------------------|----------------------|----------------------|---------------------|
| Discover screen root | `discoverRoot` | `Discover` | — | — |
| Fixture bootstrap spinner | `discover.loading` | `Loading discover` | — | — |
| Search field | `discoverSearchField` | `Search podcasts` | Current field text when non-empty | `Search the podcast directory.` |
| Popular load spinner | `discoverPopular.loading` | `Loading popular podcasts` | — | — |
| Popular error panel | `discoverPopular.error` | `Popular load error` | Short kind (e.g. `networkFailure`) | — |
| Popular retry | `discoverPopular.retry` | `Retry` | — | `Loads the popular podcast list again.` |
| Popular empty | `discoverPopular.empty` | `No podcasts` | — | — |
| Popular row *i* | `popularCell_<index>` | Podcast `title` **exactly** (golden `collectionName`) | — | — |
| Search load spinner | `discoverSearch.loading` | `Searching` | — | — |
| Search error panel | `discoverSearch.error` | `Search error` | Short kind | — |
| Search retry | `discoverSearch.retry` | `Retry` | — | `Runs the search again.` |
| Search empty | `discoverSearch.empty` | `No search results` | — | — |
| Search result row *i* | `searchResultCell_<index>` | Podcast `title` **exactly** | — | — |
| Subscribe (row *i* in active list) | `subscribeButton_<index>` | `Subscribe` when `"0"`; `Subscribed` when `"1"` | `"0"` / `"1"` | When `"0"`: `Adds this podcast to your subscriptions.` |

**Cell label contract (AC#6):** `popularCell_<index>` `label` equals golden `results[index].collectionName` from `itunes_popular_response.json` **exactly** — no artwork or “Subscribe” suffix in the label.

**Search label contract (AC#7):** `searchResultCell_0` `label` equals golden `results[0].collectionName` from `itunes_search_response.json` **exactly**.

**Subscribe value contract (AC#7):** After successful subscribe, `subscribeButton_<index>` `accessibilityValue == "1"` within **5 s**. Fresh install / empty store starts at `"0"`.

**Index convention:** `<index>` is **0-based** in the **active** list (popular or search). `popularCell_0` is the first popular row; `searchResultCell_0` is the first search hit.

**Discrete controls:** Subscribe is a `Button`, not a slider or `Switch`. UI tests query via `app.buttons["subscribeButton_0"]` (or `cells` descendants if embedded). Post-tap value updates must land on the main actor before XCTest idle.

**Cell scoping:** All identifiers are globally queryable on `XCUIApplication` (descendant search), consistent with Slices 06–13.

## Fixture mode

Launch argument: `-UITestFixtureDiscover`

When present (per ADR-014 §8):

1. `RootView` shows `DiscoverView` directly when no higher-precedence fixture wins (`FixtureSkipOverride`, `FixtureSettings`, `FixtureAudio`, `FixtureFeed` / `FixtureAnalysis` / `FixtureQueue` keep existing precedence).
2. `DiscoverViewModel` uses an `URLSession` with `protocolClasses = [DiscoverStubURLProtocol.self]` — **no live network**.
3. Stub protocol serves:
   - Pinned popular URL → bundled `itunes_popular_response.json` (**3** results)
   - Search URL with `term=fixture-query` → bundled `itunes_search_response.json` (**2** results)
   - Each fixture `feedUrl` → bundled `sample_feed.xml` (**5** episodes) for subscribe success path
4. Core Data starts **empty** (no pre-seeded subscriptions) unless a future test adds launch env keys.

**Golden provenance:** `PodWash/PodWashTests/Fixtures/itunes/README.md` (hand-authored JSON; app bundle carries copies under `PodWash/Fixtures/itunes/` for the stub protocol). UI and unit tests assert the same golden `collectionName` / `feedUrl` strings.

**Typical argument set:**

| Test | Launch arguments |
|------|------------------|
| All Slice 22 UI tests | `-UITestFixtureDiscover` only |

Do **not** combine with `-UITestFixtureFeed` or other fixture flags for mapped AC tests.

**Search typing in UI tests:** Tap `discoverSearchField`, then `typeText("fixture-query")` (no trailing newline required). Allow **≥300 ms** debounce plus layout; wait up to **10 s** for `searchResultCell_0` before assertions.

## UI test scenarios

Mapped tests live in `DiscoverUITests.swift`. Scenarios below are the authoritative UX contract for slice AC#6–#7; AC#1–#5 are unit-tested (no UI coverage required).

### `testPopularListRendersGoldenTitles` (AC#6)

1. **Launch** — `XCUIApplication` with `-UITestFixtureDiscover`; wait for `discoverRoot` (timeout **10 s**).
2. **Load complete** — assert `discoverPopular.loading` does **not** exist (or wait until absent) before row checks.
3. **Popular rows exist** — assert `popularCell_0`, `popularCell_1`, and `popularCell_2` exist.
4. **First title** — assert `popularCell_0` `label` equals golden `results[0].collectionName` from `itunes_popular_response.json` **exactly**.
5. **Second title** — assert `popularCell_1` `label` equals golden `results[1].collectionName` **exactly**.
6. **Third title** — assert `popularCell_2` `label` equals golden `results[2].collectionName` **exactly**.

Scenarios 3–6 are the AC#6 assertion. Scenarios 1–2 establish fixture routing and that the popular list finished loading.

**Query note:** Use `app.cells["popularCell_<index>"]` or `app.otherElements["popularCell_<index>"]` depending on list container; Engineer must expose the identifier on the row element XCTest can see.

### `testSearchAndSubscribeUpdatesButton` (AC#7)

1. **Launch** — `XCUIApplication` with `-UITestFixtureDiscover`; wait for `discoverRoot` (timeout **10 s**).
2. **Search** — tap `discoverSearchField`; type `fixture-query`.
3. **Wait for results** — wait for `searchResultCell_0` (timeout **10 s**).
4. **Search title** — assert `searchResultCell_0` `label` equals golden `results[0].collectionName` from `itunes_search_response.json` **exactly**.
5. **Subscribe** — tap `subscribeButton_0`.
6. **Subscribed state** — within **5 s**, assert `subscribeButton_0` `accessibilityValue == "1"`.

Step 6 is the AC#7 timing assertion. `subscribeButton_0` indexes the **search** list because `searchResults` is non-empty after step 2.

### UX smoke scenarios (not slice ACs; optional QA coverage)

#### `testPopularSubscribeUpdatesButton` (optional)

1. Launch with `-UITestFixtureDiscover`; wait for `discoverRoot` and `popularCell_0`.
2. Assert `subscribeButton_0` `accessibilityValue == "0"`.
3. Tap `subscribeButton_0`; within **5 s** assert `accessibilityValue == "1"`.

#### `testClearSearchRestoresPopular` (optional)

1. Launch; type `fixture-query`; wait for `searchResultCell_0`.
2. Clear `discoverSearchField` (select all + delete, or dedicated clear control if added).
3. Within **5 s**, assert `popularCell_0` exists and `searchResultCell_0` does **not** exist.

## Verification mapping

| AC# | UX artifact | Test method | Notes |
|-----|-------------|-------------|-------|
| 6 | `testPopularListRendersGoldenTitles` scenarios 1–6 | `DiscoverUITests.testPopularListRendersGoldenTitles` | Three `popularCell_*` labels match golden JSON |
| 7 | `testSearchAndSubscribeUpdatesButton` scenarios 1–6 | `DiscoverUITests.testSearchAndSubscribeUpdatesButton` | Search + subscribe; `accessibilityValue == "1"` within 5 s |
| 1–5 | — | `ITunesSearchClientTests`, `PodcastStoreMultiSubscriptionTests`, `DiscoverViewModelTests` | Unit tests per slice verification table |
| 8 | — | `scripts/verify.sh` | Command-level; not UX-authored |
