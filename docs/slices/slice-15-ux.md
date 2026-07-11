# Slice 15 — UX spec: CarPlay templates

| Field | Value |
|-------|-------|
| **Slice** | 15 — CarPlay |
| **Surface** | CarPlay audio-app templates (`CPTabBarTemplate` → Library / Queue tabs; pushed Show list; system Now Playing) |
| **ADR** | [ADR-016](../adr/016-carplay-templates.md) §2–§7 (hierarchy, data sources, selection, now-playing seam, plist) |
| **Builds on** | Slice 23 (`PodcastStore`, golden library titles); Slice 11 (`QueueStore`, fixture episode IDs); Slice 14 (Now Playing + remote transport — **unchanged**); Slice 03 (`PlaybackEngine` play/pause) |

## Scope note (no SwiftUI / no `PodWashUITests` gate)

CarPlay UI is rendered by the system from `CPListTemplate` / `CPTabBarTemplate` in a separate `CPTemplateApplicationScene`. XCTest cannot drive live CarPlay chrome without the Xcode CarPlay simulator window or a physical head unit — both are **out of scope as Done gates** per the slice file.

This UX spec therefore defines:

1. **Driver interaction** — template hierarchy, navigation, and playback affordances.
2. **Logical test-seam identifiers** — stable keys on injectable doubles (`CPListTemplateRecorder`, `CarPlayNowPlayingPresenting`) so QA unit tests assert the same contract production maps to real `CPListItem` rows.
3. **Unit test scenarios** — mapped to slice AC#1–#6 in `CarPlayTemplateTests.swift`.

Optional manual spot-check steps (head unit / CarPlay Simulator) are documentation-only and **not** slice ACs.

## Layout

### Root (`CPTabBarTemplate`)

On `templateApplicationScene(_:didConnect:)`, the coordinator installs a tab bar with **two** tabs, left → right:

| Tab | Visible title | Test seam key | Template | Content |
|-----|---------------|---------------|----------|---------|
| **Library** | `Library` | `carPlay.tab.library` | `CPListTemplate` | One row per subscribed show (`PodcastStore.allSubscriptions()`) |
| **Queue** | `Queue` | `carPlay.tab.queue` | `CPListTemplate` | One row per `QueueStore.queueEpisodeIDs()` entry (Slice 11 order) |

**System Now Playing:** `CPNowPlayingTemplate.shared` — not a third tab. The system surfaces it when playback is active; production may push it after a playable selection (optional UX polish, not AC-mapped).

```text
CPTabBarTemplate (root)
├── Library — CPListTemplate
│     CPListItem per subscription (disclosure accessory)
│     select → push Show list
├── Queue — CPListTemplate
│     CPListItem per queue episode
│     select → EpisodePlaying.play(episodeID:)
└── (system) CPNowPlayingTemplate.shared
      play/pause via Slice 14 remote / Now Playing stack
      title + elapsed from MPNowPlayingInfoCenter
```

### Library tab (`carPlay.libraryList`)

Vertical list, store order (`allSubscriptions()`):

| Row | Primary line (`CPListItem.text`) | Accessory | Test seam | Drill-down key |
|-----|----------------------------------|-----------|-----------|----------------|
| *i* | Subscription **title** (exact `PodcastSummary.title`) | Disclosure indicator | `carPlay.libraryCell_<i>` | `subscriptionIndex == i` on model |

**Tap:** push **Show** list for subscription index *i* (no playback on library row tap).

**Artwork:** every row has non-nil `image` (placeholder or loaded art). AC#1 requires `image != nil` on all library rows under test.

### Show list (`carPlay.showList`, pushed)

Not a tab — pushed on top of the Library tab stack.

| Row | Primary line | Test seam | Playback key |
|-----|--------------|-----------|--------------|
| *e* | Episode **title** (exact `Episode.title`) | `carPlay.showCell_<e>` | `episodeID` on model |

**Tap:** `EpisodePlaying.play(episodeID:)` for that episode. Coordinator may present Now Playing after selection (optional).

**Episode order:** feed order from `subscription(forFeedURL:).episodes` for the selected subscription.

### Queue tab (`carPlay.queueList`)

Vertical list, `queueEpisodeIDs()` order (next-to-play at index **0**):

| Row | Primary line | Test seam | Playback key |
|-----|--------------|-----------|--------------|
| *q* | Resolved episode **title** | `carPlay.queueCell_<q>` | `episodeID` (e.g. `fixture-ep-002`) |

**Tap:** `EpisodePlaying.play(episodeID:)` — same contract as Show list. **No** reorder, remove, or add controls on CarPlay (in-app queue chrome remains Slice 11).

### Now Playing (`carPlay.nowPlaying`)

System template — no custom PodWash layout. Driver sees:

- **Title** — current episode title (from Now Playing metadata).
- **Transport** — play / pause (and system skip controls where the OS exposes them). CarPlay does **not** surface speed, sleep timer, cleaning toggle, segmentation, or analysis UI in this slice.

Test seam (`CarPlayNowPlayingPresenting` double) records `updateTitle(_:)` and `updatePlaybackState(_:)` calls; production adapter may no-op title writes because the system reads `MPNowPlayingInfoCenter` (Slice 14).

**Out of scope (no CarPlay UI in this slice):** settings, subscribe/discover, queue edit, download/cleaning badges, variable speed, sleep timer, segmentation banner, paywall, artwork pixel asserts, subjective head-unit polish.

## States

### Library tab

| State | Visible UI | List seam | Row seams | Notes |
|-------|------------|-----------|-----------|-------|
| **Loaded** | *N* subscription rows | `carPlay.libraryList` | `carPlay.libraryCell_0` … `_<N-1>` | Fixture AC#1: **N = 2**; golden titles pinned |
| **Empty** | Zero-row list (no custom empty copy required) | `carPlay.libraryList` | (none) | Not AC-mapped; system shows empty list chrome |

### Show list (subscription *i*)

| State | Visible UI | List seam | Row seams | Notes |
|-------|------------|-----------|-----------|-------|
| **Loaded** | *E* episode rows | `carPlay.showList` | `carPlay.showCell_0` … `_<E-1>` | Fixture AC#2: *i = 0*, **E = 5**; first two titles pinned |
| **Empty feed** | Zero-row list | `carPlay.showList` | (none) | Programmer/fixture error if shown in tests |

### Queue tab

| State | Visible UI | List seam | Row seams | Notes |
|-------|------------|-----------|-----------|-------|
| **Loaded** | *Q* queue rows | `carPlay.queueList` | `carPlay.queueCell_0` … `_<Q-1>` | Fixture AC#3: **Q = 3**; order matches queue store |
| **Empty** | Zero-row list | `carPlay.queueList` | (none) | Valid when `queueEpisodeIDs()` is empty |

### Now Playing

| State | Driver UI | Seam `playbackState` | Seam `lastTitle` | Notes |
|-------|-----------|----------------------|------------------|-------|
| **Idle** | System template may be hidden | — | — | Before first `play()` in session |
| **Playing** | Title + pause affordance | `.playing` | Current episode title | After `PlaybackEngine.play()` |
| **Paused** | Title + play affordance | `.paused` | Unchanged from last play | After `PlaybackEngine.pause()` |

Only one playback state is active at a time. State updates are ordered; AC#5 expects `[.playing, .paused]` after `play()` then `pause()`.

### Connection lifecycle (scene)

| State | Behavior | Notes |
|-------|----------|-------|
| **Connected** | `CarPlayCoordinator.activateRoot()` installs tab templates | `didConnect` on scene delegate |
| **Disconnected** | Coordinator clears retained interface-controller references | `didDisconnect`; not AC-mapped |

No loading spinners or error banners on CarPlay lists in this slice — data sources read synchronously from in-memory / Core Data stores already populated by the phone app.

## Accessibility

### Production (system CarPlay)

`CPListItem` rows use **`text`** as the primary VoiceOver label (episode or show title). Disclosure on library rows is provided by `accessoryType = .disclosureIndicator`. PodWash does **not** set custom `accessibilityIdentifier` on production `CPListItem` instances (framework surface; system drives CarPlay AX tree).

**Driver copy contract:** row `text` values must match in-app titles exactly (golden strings in AC#1–#3).

### Test seams (doubles — stable logical keys)

Doubles mirror production row semantics so unit tests query by index without a head unit.

#### List recorder (`CPListTemplateRecorder` / `CarPlayListPresenting`)

| Region / control | Seam key | Recorded fields | `accessibilityLabel` equivalent |
|----------------|----------|-----------------|--------------------------------|
| Library tab list | `carPlay.libraryList` | `items: [RecordedRow]` | — |
| Library row *i* | `carPlay.libraryCell_<i>` | `text`, `image != nil`, `subscriptionIndex` | `text` |
| Show list (pushed) | `carPlay.showList` | `items` | — |
| Show row *e* | `carPlay.showCell_<e>` | `text`, `image != nil`, `episodeID` | `text` |
| Queue tab list | `carPlay.queueList` | `items` | — |
| Queue row *q* | `carPlay.queueCell_<q>` | `text`, `image != nil`, `episodeID` | `text` |
| Tab: Library | `carPlay.tab.library` | template title `Library` | `Library` |
| Tab: Queue | `carPlay.tab.queue` | template title `Queue` | `Queue` |

**Row query contract (doubles):**

- `recordedText(at:listKey:)` → exact `text` string (AC#1–#3).
- `recordedEpisodeID(at:listKey:)` → episode ID for show/queue rows (AC#4).
- `recordedImageIsNonNil(at:listKey:)` → `true` for artwork ACs.

**Selection:** `fireSelection(listKey:at:)` invokes the stored handler at index (mirrors `CPListItem.handler` + completion). AC#4 uses queue list index **1** → `play(episodeID: "fixture-ep-002")`.

**Index convention:** `<i>`, `<e>`, `<q>` are **0-based** positions in the list under test.

#### Now Playing presenter (`CarPlayNowPlayingPresenting` double)

| Seam key | Recorded property | Values |
|----------|-------------------|--------|
| `carPlay.nowPlaying` | `playbackStateUpdates` | Ordered `[.playing, .paused, …]` |
| `carPlay.nowPlaying` | `lastTitle` | Last `updateTitle` argument |

Production `CarPlayNowPlayingUpdater` must call the presenting seam on engine play/pause so tests do not depend on live `CPNowPlayingTemplate.shared` metadata APIs (none exist per ADR-016 spike).

## Fixture modes (unit tests — not UI launch arguments)

CarPlay ACs are **unit-tested** with in-memory stores. There are **no** `-UITestFixtureCarPlay` launch arguments and **no** `PodWashUITests` scenarios in the Done gate.

### Library + Show seed (AC#1–#2)

| Step | Detail |
|------|--------|
| Store | `PersistenceController(isStoredInMemoryOnly: true)` |
| Seed | `FixtureLibrary.prepareSeededStore` — **2** subscriptions |
| Golden library titles | `Fixture Popular Alpha` (index 0), `Fixture Popular Beta` (index 1) |
| Show 0 episodes | **5** from `sample_feed.xml`; namespaced IDs `lib-0-fixture-ep-*` |
| Pinned show titles | `Alpha Signal — Pilot Launch`, `Beta Notes — Listener Mail` (indices 0–1) |

Assert via `CarPlayLibraryDataSource.listItems()` / `CarPlayShowDataSource(subscriptionIndex: 0).listItems()` or equivalent recorder rows.

### Queue seed (AC#3–#4)

| Step | Detail |
|------|--------|
| Store | In-memory `PodcastStore` + `save(_:feedURL:)` with `sample_feed.xml` so episode IDs remain **`fixture-ep-001`…`003`** (Slice 11 contract — **not** namespaced library IDs) |
| Queue | `QueueStore.add("fixture-ep-001")`, `add("fixture-ep-002")`, `add("fixture-ep-003")` in order |
| Pinned queue titles | `Alpha Signal — Pilot Launch`, `Beta Notes — Listener Mail`, `Gamma Graph — Data Deep Dive` |

### Now Playing seed (AC#5)

| Asset | Detail |
|-------|--------|
| Clip | `PodWash/PodWashTests/Fixtures/audio/test-clip.m4a` (**30.0 s**, Slice 14 provenance) |
| Engine title | **`Alpha Signal — Pilot Launch`** (exact) |
| Double | `CPNowPlayingTemplateDouble` conforming to `CarPlayNowPlayingPresenting` |

### Plist structural check (AC#6)

Read built test-host `Info.plist`; count `UISceneConfigurations` entries with `UISceneClassName == CPTemplateApplicationScene` → exactly **1**. No UI fixture.

## UI test scenarios

**Authoritative automated scenarios for slice Done** — implemented as **unit tests** in `PodWash/PodWashTests/CarPlayTemplateTests.swift`. Steps below are the UX contract QA maps to test methods.

### 1. `testLibraryListItemsFromSubscriptions` (AC#1)

1. **Seed** — in-memory store with `FixtureLibrary.prepareSeededStore` (**2** subscriptions).
2. **Load** — `CarPlayLibraryDataSource.listItems()` (or `carPlay.libraryList` recorder after `activateRoot()`).
3. **Count** — assert `count == 2`.
4. **Titles** — `items[0].text == "Fixture Popular Alpha"` and `items[1].text == "Fixture Popular Beta"` **exactly**.
5. **Artwork** — `items.filter { $0.image != nil }.count == 2`.

### 2. `testShowListItemsForSubscription` (AC#2)

1. **Seed** — same library seed as scenario 1.
2. **Load** — `CarPlayShowDataSource(store:, subscriptionIndex: 0).listItems()`.
3. **Count** — assert `count == 5`.
4. **Titles** — `items[0].text == "Alpha Signal — Pilot Launch"` and `items[1].text == "Beta Notes — Listener Mail"` **exactly**.

### 3. `testQueueListItemsFromStore` (AC#3)

1. **Seed** — `PodcastStore` with `sample_feed.xml`; `QueueStore` with three fixture IDs in order (`fixture-ep-001`, `002`, `003`).
2. **Load** — `CarPlayQueueDataSource.listItems()`.
3. **Count** — assert `count == 3`.
4. **Titles** — `items.map(\.text) == ["Alpha Signal — Pilot Launch", "Beta Notes — Listener Mail", "Gamma Graph — Data Deep Dive"]` **exactly**.
5. **Artwork** — `items.filter { $0.image != nil }.count == 3`.

### 4. `testQueueSelectionStartsPlayback` (AC#4)

1. **Seed** — same queue seed as scenario 3.
2. **Wire** — `CarPlayCoordinator` with injected list recorder + `EpisodePlayingSpy` (Slice 11 spy — **not** `PlaybackTransporting`).
3. **Select** — programmatically invoke queue selection at index **1** (`selectQueueItem(at: 1)` or `fireSelection(listKey: carPlay.queueList, at: 1)`).
4. **Assert** — spy records exactly **1** `play(episodeID:)` with argument **`fixture-ep-002`**.

### 5. `testNowPlayingStatePropagation` (AC#5)

1. **Wire** — `PlaybackEngine` + `test-clip.m4a`, title **`Alpha Signal — Pilot Launch`**; inject `CPNowPlayingTemplateDouble`.
2. **Play** — `engine.play()`; assert double `playbackStateUpdates` ends with `.playing` and `lastTitle == "Alpha Signal — Pilot Launch"` **exactly** (after first play only).
3. **Pause** — `engine.pause()`; assert full `playbackStateUpdates == [.playing, .paused]` in order.

### 6. `testCarPlaySceneDeclaredInPlist` (AC#6)

1. **Read** — test-host app bundle `Info.plist`.
2. **Assert** — exactly **1** scene configuration whose `UISceneClassName` is `CPTemplateApplicationScene`.

### 7. Full suite (AC#7)

Command-level: unfiltered `scripts/verify.sh` exit **0**, failed **0**, skipped **0**.

## Optional manual spot-check (not gated)

After Apple grants `com.apple.developer.carplay-audio` (see ADR-016 §8):

1. Pair iPhone with CarPlay Simulator or vehicle.
2. Open PodWash CarPlay app → confirm **Library** and **Queue** tabs.
3. Library → select a show → episode list → tap episode → audio plays; Now Playing shows title.
4. Queue → tap second item → plays `fixture-ep-002` equivalent in user library.
5. Use steering-wheel / on-screen play-pause → transport matches phone lock-screen behavior (Slice 14).

Document result in PR notes only; **never** block Done.

## Verification mapping

| AC# | UX artifact | Test method | Notes |
|-----|-------------|-------------|-------|
| 1 | Scenario 1 | `CarPlayTemplateTests.testLibraryListItemsFromSubscriptions` | 2 subs; exact golden titles; artwork non-nil |
| 2 | Scenario 2 | `CarPlayTemplateTests.testShowListItemsForSubscription` | Sub index 0; 5 episodes; first 2 titles pinned |
| 3 | Scenario 3 | `CarPlayTemplateTests.testQueueListItemsFromStore` | 3 queue IDs; 3 titles; artwork non-nil |
| 4 | Scenario 4 | `CarPlayTemplateTests.testQueueSelectionStartsPlayback` | Index 1 → `fixture-ep-002` |
| 5 | Scenario 5 | `CarPlayTemplateTests.testNowPlayingStatePropagation` | `[.playing, .paused]`; pinned title |
| 6 | Scenario 6 | `CarPlayTemplateTests.testCarPlaySceneDeclaredInPlist` | Exactly 1 CarPlay scene |
| 7 | Scenario 7 | `scripts/verify.sh` | Command-level |
