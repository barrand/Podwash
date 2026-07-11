# ADR-015 — App shell navigation: Library + Discover tabs + mini-player

| Field | Value |
|-------|-------|
| **Status** | Accepted |
| **Date** | 2026-07-11 |
| **Supersedes** | — (does **not** replace [ADR-014](014-discovery-itunes-multi-sub.md); completes the production shell ADR-014 deferred) |
| **Builds on** | [ADR-000](000-foundations.md) §1/§6; [ADR-001](001-playback-engine.md) (fixture routing, `PlaybackEngine`, `PlaybackControlsView`); [ADR-004](004-rss-parser.md) (`PodcastDetailView`, `EpisodeListView`, `sample_feed.xml`); [ADR-006](006-playback-integration.md) (`PlaybackCoordinator`); [ADR-009](009-queue-resume.md) (`QueueCoordinator`, `EpisodePlaying`, stores); [ADR-010](010-settings-word-lists.md) (`settingsButton`); [ADR-011](011-remote-commands-background-audio.md) (`RemoteCommandCoordinator`); [ADR-014](014-discovery-itunes-multi-sub.md) (`PodcastStore.allSubscriptions()`, `DiscoverView`, golden iTunes titles) |
| **Slice** | [slice-23-library-player-shell.md](../slices/slice-23-library-player-shell.md) |

## Context

Slice 23 replaces the placeholder `ContentView` with the MVP production shell:
**Library** + **Discover** tabs, Settings entry on both, show → episode list → play,
and a **mini-player** bar wired through existing coordinators.

Product pins (2026-07-10):

- Layout = `TabView` (`tabLibrary` + `tabDiscover`); Settings via `settingsButton`.
- Player chrome = mini-player bar (`miniPlayer` / `miniPlayerPlayPause`); tap bar
  expands to full `PlaybackControlsView`.

Constraints:

- Cold launch **without** UITest-only exclusive fixture args must show the shell
  (not placeholder copy).
- UI tests use `-UITestFixtureLibrary` / empty variant — **no live network**; play
  asserts use the Slice 03 bundled audio clip.
- `CDEpisode.id` remains **globally unique** (ADR-009 / ADR-014). Seeding two shows
  from the same `sample_feed.xml` **must** namespace episode IDs.
- Do not redesign cleaning / download / queue UI — only wire existing
  `PodcastDetailView` / `EpisodeListView` from Library.

**Numbering note:** Slice 23 drafts said `014-app-shell-navigation.md`; **014** is
already Discovery ([ADR-014](014-discovery-itunes-multi-sub.md)). This decision is
**ADR-015**.

## Decision

### 1. Module layout

| File | Target | Status | Responsibility |
|------|--------|--------|----------------|
| `PodWash/PodWash/AppShellView.swift` | app | **new** | Production `TabView` + mini-player overlay; replaces placeholder `ContentView` body |
| `PodWash/PodWash/LibraryView.swift` | app | **new** | Subscription list + empty state; accessibility contract |
| `PodWash/PodWash/LibraryViewModel.swift` | app | **new** | Reads `PodcastStore.allSubscriptions()`; reload after subscribe / appear |
| `PodWash/PodWash/AppShellModel.swift` | app | **new** | Composition root: stores, engine, `PlaybackCoordinator`, `QueueCoordinator`, episode-play orchestration, mini-player presentation state |
| `PodWash/PodWash/LibraryEpisodePlayer.swift` | app | **new** | `EpisodePlaying` adapter used by `QueueCoordinator` (resolve URL → engine → optional `preparePlayback` → play/pause/seek) |
| `PodWash/PodWash/MiniPlayerBar.swift` | app | **new** | Compact bar chrome (`miniPlayer`, `miniPlayerPlayPause`) |
| `PodWash/PodWash/FixtureLibrary.swift` | app | **new** | `-UITestFixtureLibrary` / `-UITestFixtureLibraryEmpty`; seed helpers |
| `PodWash/PodWash/RootView.swift` | app | **changed** | Production branch → `AppShellView`; Library fixture seeds before shell; keep exclusive fixture branches |
| `PodWash/PodWash/PodWashApp.swift` | app | **changed** | When Library fixture (seeded or empty): `PersistenceController.inMemory(…)`; else production |
| `PodWash/PodWash/ContentView.swift` | app | **changed or deleted** | Placeholder retired; preview may point at `AppShellView` |
| `PodWash/PodWash/PodcastDetailView.swift` / `EpisodeListView.swift` | app | **changed (minimal)** | Episode-row tap → shell play callback (identifiers unchanged) |
| `PodWash/PodWashTests/LibraryViewModelTests.swift` | test | **new (QA)** | AC1 |
| `PodWash/PodWashTests/LibraryNavigationTests.swift` | test | **new (QA)** | Optional unit/integration for play orchestration |
| `PodWash/PodWashUITests/LibraryUITests.swift` | test | **new (QA)** | AC2–AC7 |

**Unchanged public APIs:** `PodcastStore` multi-sub surface (ADR-014),
`PlaybackEngine` transport, `PlaybackCoordinator.preparePlayback`,
`QueueCoordinator.playEpisode`, `DiscoverView` / `DiscoverViewModel`, Settings
identifiers, episode-list identifiers (`episodeList`, `episodeCell_<index>`).

### 2. Navigation graph

```text
RootView
├── [exclusive fixtures — unchanged precedence]
│   SkipOverride → Settings → Audio → Feed|Analysis|Queue → Discover
└── else → AppShellView (production + Library fixtures)
        TabView(selection: selectedTab)
        ├── tabLibrary → NavigationStack
        │     LibraryView
        │       → PodcastDetailView (existing EpisodeListViewModel path)
        │            → episode tap → AppShellModel.play…
        └── tabDiscover → NavigationStack
              DiscoverView (Slice 22)
        + toolbar settingsButton → SettingsView (both tabs)
        + MiniPlayerBar (above tab bar when session has active engine)
             → tap bar → present full PlaybackControlsView (sheet; UX may refine)
```

**Tab identifiers (binding):**

| Control | `accessibilityIdentifier` |
|---------|---------------------------|
| Library tab | `tabLibrary` |
| Discover tab | `tabDiscover` |

**Library identifiers:**

| Control | `accessibilityIdentifier` | Notes |
|---------|---------------------------|--------|
| Root | `libraryRoot` | Library tab content root |
| List | `libraryList` | When `subscriptionCount > 0` |
| Empty | `libraryEmptyState` | Label contains substring **`Discover`** (AC7) |
| Row *i* | `libraryCell_<index>` | 0-based; **label contains** subscription title (substring, case-sensitive) |

**Empty → Discover:** empty-state affordance sets `selectedTab = .discover` (same
`TabView` selection). Do not push a second Discover stack outside the tab.

**Settings:** preserve Slice 13 `settingsButton` on **both** tab roots,
navigating to `SettingsView` inside that tab’s `NavigationStack`. Implementation
binding (iOS 26 / XCTest): mount a **single** plain SwiftUI `Button` as a
safe-area overlay on `AppShellView` (not a `ToolbarItem` / `NavigationLink`).
iOS 26 liquid-glass toolbar chrome often yields `exists && !isHittable` for
trailing bar items under XCTest; a content-tree `Button` with
`accessibilityIdentifier("settingsButton")` stays hittable. The overlay opens
Settings via the selected tab’s `navigationDestination(item:)` route and hides
while Settings is pushed or the full player sheet is presented. Inline nav titles
plus a clear trailing toolbar spacer keep layout aligned with standard chrome.

### 3. `LibraryViewModel` API

```swift
@MainActor @Observable
final class LibraryViewModel {
    private let store: PodcastStore

    private(set) var subscriptions: [PodcastSummary] = []

    var subscriptionCount: Int { subscriptions.count }
    var titles: [String] { subscriptions.map(\.title) }

    init(store: PodcastStore)

    /// Re-reads `store.allSubscriptions()` (ascending `subscribedAt`, then `feedURLString`).
    func reload()
}
```

**AC1 binding:** seed two subscriptions with golden popular titles 0 and 1 →
`subscriptionCount == 2`, `titles == [goldenTitle0, goldenTitle1]` **exactly**;
after ADR-009 reload harness (`PersistenceController.inMemory(identifier:)`),
unchanged. No new store APIs — reuse ADR-014 `allSubscriptions()` /
`subscriptionCount` / `saveSubscription`.

**Show open:** tap `libraryCell_<index>` pushes `PodcastDetailView` whose
`EpisodeListViewModel` is loaded from `store.subscription(forFeedURL:)` (already
persisted episodes — **no network** on Library → detail in fixture mode).

### 4. Composition root — `AppShellModel`

Owns long-lived dependencies for the production path (mirror what fixture branches
already construct ad hoc in `RootView`):

```swift
@MainActor @Observable
final class AppShellModel {
    let persistence: PersistenceController
    let podcastStore: PodcastStore
    let queueStore: QueueStore
    let resumeStore: ResumePositionStore
    let cleaningStore: CleaningToggleStore
    let downloadManager: DownloadManager
    let settingsStore: SettingsStore
    let remoteCommands: RemoteCommandCoordinator

    private(set) var engine: PlaybackEngine?
    private(set) var playbackCoordinator: PlaybackCoordinator?
    private(set) var queueCoordinator: QueueCoordinator?

    /// Drives mini-player visibility (true after a successful episode play start).
    private(set) var isMiniPlayerVisible: Bool = false
    /// Full controls presentation (sheet). UX owns animation; ADR binds existence.
    var isFullPlayerPresented: Bool = false

    init(persistence: PersistenceController, remoteCommands: RemoteCommandCoordinator)

    /// Library / detail entry: resolve audio, prepare engine + coordinators, play.
    /// Synchronous so UITest episode taps publish mini-player before post-tap idle.
    func playEpisode(_ episode: Episode, podcastTitle: String)

    func toggleMiniPlayerPlayPause()
    func expandFullPlayer()
    func stopAndDismissPlayer()  // optional; dismiss mini only on stop / UX close
}
```

**Play orchestration (binding for AC4 / 4b):**

1. Resolve local audio URL:
   - If `FixtureLibrary.isEnabled` (seeded or empty flag that still uses fixture
     audio path when playing): **`FixtureAudio.bundledURL()`** — never hit enclosure
     network.
   - Else production: prefer downloaded file when present (ADR-008); otherwise
     stream enclosure URL (cleaning still requires local file per ADR-000 §3 —
     unchanged).
2. Create or replace `PlaybackEngine(url:title:artist:)` with episode metadata.
3. Construct `PlaybackCoordinator` (pipeline can be a no-op / cache-hit path for
   fixture; production may use existing analyzer wiring). Call
   `preparePlayback` when cleaning intervals apply; fixture Library play **may**
   skip analysis and play clean audio (AC only asserts play/pause).
4. Build `LibraryEpisodePlayer` conforming to `EpisodePlaying`, wrapping the
   engine; construct `QueueCoordinator(queue:player:resume:)`.
5. `remoteCommands.bind(engine)`.
6. `queueCoordinator.playEpisode(episode.id)` (or direct engine `play()` if queue
   not required for AC — prefer `QueueCoordinator` so resume/queue stay consistent).
7. Set `isMiniPlayerVisible = true`.

**Mini-player contracts:**

| Control | Identifier | `accessibilityValue` |
|---------|------------|----------------------|
| Bar chrome (expand target) | `miniPlayer` | — |
| Play/pause on bar | `miniPlayerPlayPause` | `"playing"` / `"paused"` (same semantics as Slice 03 `playback.playPause`) |
| Expanded full controls | existing `playback.playPause` etc. | unchanged |

- Tap **`miniPlayerPlayPause`** toggles engine play/pause only (does not expand).
- Tap **`miniPlayer`** (bar, not the play button) sets `isFullPlayerPresented = true`
  → sheet (or UX-specified push) hosting `PlaybackControlsView(engine:)`.
- Mini-player stays visible while switching Library ↔ Discover and while browsing
  episode lists; hide only on stop / explicit close if UX adds one.

**Coordinator ownership:** one `AppShellModel` per `RootView` production branch.
Exclusive fixture modes keep their existing local engines and do **not** require
`AppShellModel`.

### 5. Episode list → play seam

`EpisodeListView` / `PodcastDetailView` today have no row-tap → play path. Add a
minimal callback:

```swift
// PodcastDetailView / EpisodeListView — additive
var onPlayEpisode: ((Episode) -> Void)? = nil
```

Row selection (or dedicated play affordance if UX requires) invokes `onPlayEpisode`.
**Do not** change `episodeCell_<index>` identifiers. Queue-add / download / cleaning
controls remain as today.

Fixture Feed / Analysis / Queue branches may leave `onPlayEpisode` nil (existing
UITests do not assert mini-player).

### 6. Fixture modes

```swift
enum FixtureLibrary {
    static let launchArgument = "-UITestFixtureLibrary"
    static let emptyLaunchArgument = "-UITestFixtureLibraryEmpty"

    static var isEnabled: Bool { /* ProcessInfo — seeded library */ }
    static var isEmptyEnabled: Bool { /* empty library */ }

    /// Seeds exactly 2 subscriptions; namespaces episode IDs (see below).
    static func prepareSeededStore(_ store: PodcastStore) throws

    /// Ensures zero subscriptions (clear if needed).
    static func prepareEmptyStore(_ store: PodcastStore) throws
}
```

**When `-UITestFixtureLibrary`:**

1. `PodWashApp` uses `PersistenceController.inMemory(identifier: "uitest-library-<uuid>")`
   (fresh temp SQLite **per launch** — do not reuse a fixed identifier across UITest
   processes; `inMemory` is durable temp SQLite, not process-local RAM).
2. `RootView` constructs `AppShellModel`, then calls `FixtureLibrary.prepareSeededStore`
   on **that** model's `podcastStore` before presenting `AppShellView`.
3. Lands on **Library** tab (`selectedTab = .library`).
4. No live network; Discover tab may still construct a stubbed client if opened
   (optional); Library ACs must not require Discover network.
5. Play uses `FixtureAudio` bundled clip (§4).

**Seed algorithm (`prepareSeededStore`):**

1. `store.clear()` (isolated in-memory store).
2. Load golden popular results 0 and 1 from bundled `itunes_popular_response.json`
   (same titles as Slice 22: **"Fixture Popular Alpha"**, **"Fixture Popular Beta"**).
3. Parse bundled `sample_feed.xml` once per show.
4. **Namespace episode IDs** before save (ADR-014 uniqueness):
   `id' = "lib-\(index)-\(originalID)"` (e.g. `lib-0-fixture-ep-001`,
   `lib-1-fixture-ep-001`). Titles/order of episodes unchanged (5 each).
5. `saveSubscription(from:result, feed: namespacedFeed)` for index 0 then 1.
6. Result: `subscriptionCount == 2`; `allSubscriptions().map(\.title)` equals
   golden titles 0 and 1 in store order.

**When `-UITestFixtureLibraryEmpty`:**

1. Same in-memory policy with a distinct `uitest-library-empty-<uuid>` identifier.
2. `prepareEmptyStore` → `subscriptionCount == 0` (fresh UUID store is already empty).
3. Library tab shows `libraryEmptyState`; affordance → `discoverRoot` within 5 s.

**Routing precedence** (exclusive shells first; Library is **not** exclusive — it
configures the production shell):

```text
SkipOverride > Settings > Audio > Feed|Analysis|Queue > Discover
  > AppShellView  // production, Library, LibraryEmpty
```

`-UITestFixtureLibrary` must **not** be combined with exclusive fixtures in UITests
(AC2: Library arg only). If both Discover and Library args appear, Discover
exclusive branch wins (document; tests must not do this).

### 7. Empirical validation

| Claim | Validation |
|-------|------------|
| Tab + NavigationStack + sheet chrome | SwiftUI UITest identifiers only — no framework spike. |
| Mini-player play/pause value | Reuses Slice 03 `PlaybackEngine` + accessibilityValue contract; Library fixture binds bundled `FixtureAudio` clip (already proven). |
| Multi-sub seed + global episode IDs | **Deterministic namespacing** in `prepareSeededStore` — no Core Data schema change. |
| Network | None in Library UITests; Discover stubs remain ADR-014. |

No audio-mix / ASR / StoreKit spike required for this shell slice.

### 8. Cross-cutting impact

| Area | Impact |
|------|--------|
| `RootView` / `PodWashApp` | Production shell + in-memory switch for Library fixtures; serialize with parallel slices editing the same files (18–21) |
| `PodcastDetailView` / `EpisodeListView` | Additive play callback only |
| `PodcastStore` | **No API change** — read via `allSubscriptions()` |
| `CleaningToggleStore` | Still first-podcast semantics (ADR-014 deferral). Library play ACs use `libraryCell_0` only — acceptable for Slice 23; multi-channel cleaning remains later |
| `PlaybackEngine` / `PlaybackCoordinator` / `QueueCoordinator` | Wired in production for the first time; public APIs unchanged |
| `RemoteCommandCoordinator` | Bind when shell creates an engine (same as fixture audio path) |
| CarPlay (15) | May start after this slice Done; will consume the same shell/session concepts |

### 9. Out of scope (this ADR)

- CarPlay templates / scene delegate (Slice 15)
- Visual identity tokens (Slice 21)
- Analysis timeline / segmentation UI (20 / 18–19)
- Deep links / universal links
- Multi-channel cleaning store redesign
- Changing Discover network behavior in production
- Paywall (17)

## Consequences

- Placeholder `ContentView` is retired; cold launch shows Library/Discover tabs.
- QA maps AC1–AC7 to `LibraryViewModelTests` + `LibraryUITests` against the APIs
  and identifiers above; Engineer must not invent alternate tab or mini-player IDs.
- Fixture seeding namespaces episode IDs so two `sample_feed.xml` subscriptions
  do not violate `CDEpisode.id` uniqueness.
- Plan review (QA + PM) should confirm empty-state copy contains **`Discover`** and
  that AC2 launches with **only** `-UITestFixtureLibrary`.
