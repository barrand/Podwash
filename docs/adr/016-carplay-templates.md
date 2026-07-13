# ADR-016 — CarPlay templates: library, queue, now playing

| Field | Value |
|-------|-------|
| **Status** | Accepted |
| **Date** | 2026-07-11 |
| **Supersedes** | — |
| **Builds on** | [ADR-000](000-foundations.md) §1 (injected doubles for system frameworks); [ADR-001](001-playback-engine.md) (`PlaybackEngine` title / play / pause); [ADR-009](009-queue-resume.md) (`QueueStore`, `EpisodePlaying`); [ADR-011](011-remote-commands-background-audio.md) (Now Playing + `PlaybackTransporting` / remote stack — **reused, not redesigned**); [ADR-014](014-discovery-itunes-multi-sub.md) (`PodcastStore.allSubscriptions()`, `subscription(forFeedURL:)`); [ADR-015](015-app-shell-navigation.md) (`FixtureLibrary`, `AppShellModel`, namespaced `lib-<i>-…` IDs) |
| **Slice** | [slice-15-carplay.md](../slices/slice-15-carplay.md) |

## Context

Slice 15 ships PRD §2 / §7 CarPlay audio-app browsing and playback: subscribed
shows, per-show episodes, up-next queue, and now-playing state — assertable in CI
**without** a physical head unit or Xcode CarPlay simulator window as a Done gate.

Constraints:

- List contents, selection → play, and play/pause state must be asserted on
  **injectable doubles** (ADR-000), never live `CPInterfaceController` UI.
- Reuse Slice 14 Now Playing + `MPRemoteCommandCenter` stack; do not regress it.
- Apple’s `com.apple.developer.carplay-audio` entitlement approval is **external**
  and **not** a Done gate (document request steps only).
- Product pins (2026-07-10): CarPlay ships with MVP; physical checks are
  documentation-only.

**Numbering note:** Slice 15 deliverables name this file `016-carplay-templates.md`.
ADR-015 is app shell; this decision is **016**.

## Decision

### 1. Module layout

| File | Target | Status | Responsibility |
|------|--------|--------|----------------|
| `PodWash/PodWash/CarPlayListItemModel.swift` | app | **new** | Testable list row: `text`, `image`, `episodeID?`, `subscriptionIndex?` |
| `PodWash/PodWash/CarPlayLibraryDataSource.swift` | app | **new** | `PodcastStore.allSubscriptions()` → `[CarPlayListItemModel]` |
| `PodWash/PodWash/CarPlayShowDataSource.swift` | app | **new** | Episodes for subscription index → models |
| `PodWash/PodWash/CarPlayQueueDataSource.swift` | app | **new** | `QueueStore.queueEpisodeIDs()` + title/artwork resolve → models |
| `PodWash/PodWash/CarPlayTemplateBuilding.swift` | app | **new** | Protocol: build root / show / queue list models; map models → production templates |
| `PodWash/PodWash/CarPlayCoordinator.swift` | app | **new** | Wires data sources + `EpisodePlaying` + now-playing updater; selection handlers |
| `PodWash/PodWash/CarPlayNowPlayingUpdater.swift` | app | **new** | Observes engine play/pause; pushes title + state to `CarPlayNowPlayingPresenting` |
| `PodWash/PodWash/CarPlayNowPlayingPresenting.swift` | app | **new** | Protocol seam for now-playing double / production adapter |
| `PodWash/PodWash/CarPlaySceneDelegate.swift` | app | **new** | `CPTemplateApplicationSceneDelegate`; connects interface controller → coordinator |
| `PodWash/PodWash/CarPlayDependencyProviding.swift` | app | **new** | App-launch registration of stores / player for the scene delegate |
| `PodWash/PodWash/Info.plist` | app | **changed** | `UIApplicationSceneManifest`: phone `UIWindowScene` + exactly one `CPTemplateApplicationScene` (Generation = NO) |
| `PodWash/PodWash/PodWash.entitlements` | app | **changed (optional)** | Add `com.apple.developer.carplay-audio` when provisioning allows; **not** AC-gated |
| `PodWash/PodWash/AppShellModel.swift` / `PodWashApp.swift` / `RootView.swift` | app | **changed (minimal)** | Register `CarPlayDependencyProviding` with live stores + episode player; `KeyWindowActivator` keeps the phone WindowGroup key under multi-scene |
| `PodWash/PodWashTests/CarPlayTemplateTests.swift` | test | **new (QA)** | AC1–AC6 |
| `PodWash/PodWashTests/CarPlayDoubles.swift` (or inline) | test | **new (QA)** | `CPListTemplateRecorder`, `CPNowPlayingTemplateDouble` |

**Unchanged public APIs:** `PodcastStore`, `QueueStore`, `PlaybackEngine`,
`PlaybackCoordinator`, `RemoteCommandCoordinator`, `PlaybackTransporting`,
`FixtureLibrary` seed algorithm.

### 2. Template hierarchy

```text
CPTabBarTemplate (root on didConnect)
├── Library  — CPListTemplate
│     one CPListItem per subscription (title = PodcastSummary.title)
│     accessory: disclosure
│     select → push Show list
├── Queue    — CPListTemplate
│     one CPListItem per queueEpisodeIDs() entry (Slice 11 order)
│     select → EpisodePlaying.play(episodeID:)
└── (system) CPNowPlayingTemplate.shared
      pushed after playable selection (optional UX); title/state from MPNowPlayingInfoCenter
      + CarPlayNowPlayingUpdater → presenting seam for tests
```

Show drill-down (pushed, not a tab):

```text
Show — CPListTemplate
  one CPListItem per episode for allSubscriptions()[index]
  select → EpisodePlaying.play(episodeID:)
```

No CarPlay settings, cleaning toggle, speed, sleep, segmentation, or queue reorder.

### 3. Testable models (AC1–AC3 surface)

Data sources **do not** require a live CarPlay scene. They return value models:

```swift
struct CarPlayListItemModel: Equatable {
    let text: String
    let image: UIImage?          // non-nil for AC artwork counts
    let episodeID: String?       // set for show/queue rows
    let subscriptionIndex: Int?  // set for library rows (drill-down)
}

@MainActor
final class CarPlayLibraryDataSource {
    init(store: PodcastStore, artwork: CarPlayArtworkProviding = .placeholder)
    func listItems() -> [CarPlayListItemModel]
}

@MainActor
final class CarPlayShowDataSource {
    init(store: PodcastStore, subscriptionIndex: Int, artwork: CarPlayArtworkProviding = .placeholder)
    func listItems() -> [CarPlayListItemModel]
}

@MainActor
final class CarPlayQueueDataSource {
    init(store: PodcastStore, queue: QueueStore, artwork: CarPlayArtworkProviding = .placeholder)
    func listItems() -> [CarPlayListItemModel]
}
```

**Binding:**

| Source | Order | `text` | `image` |
|--------|-------|--------|---------|
| Library | `allSubscriptions()` order | `PodcastSummary.title` exact | Always non-nil placeholder (or loaded artwork) |
| Show | `subscription(forFeedURL:).episodes` feed order | `Episode.title` exact | Always non-nil |
| Queue | `queueEpisodeIDs()` order | Resolve ID → `Episode.title` via store walk | Always non-nil |

**Episode resolve (no new store API):** for each ID, walk
`allSubscriptions()` → `subscription(forFeedURL:)` → `episodes.first { $0.id == id }`.
Missing ID → skip or empty title is a programmer error in fixtures; tests seed the store.

**Artwork:** ACs require `image != nil` only (no pixel hash). Use a deterministic
placeholder (`UIImage(systemName: "photo")` or 1×1 solid) when URL is nil / unloadable.
Never leave `image == nil` on rows under test.

**Fixture seeding (pinned to slice):**

| AC | Seed |
|----|------|
| 1–2 | `FixtureLibrary.prepareSeededStore` — 2 golden titles; show 0 has 5 episodes (`lib-0-fixture-ep-*`) |
| 3–4 | In-memory `PodcastStore` + `sample_feed.xml` via `save(_:feedURL:)` so IDs stay **`fixture-ep-001`…`003`** (Slice 11 queue contract); `QueueStore.add` those three IDs in order |

Do **not** mix namespaced Library IDs into AC3–AC4 queue asserts.

### 4. `CarPlayTemplateBuilding` + production mapping

```swift
@MainActor
protocol CarPlayTemplateBuilding: AnyObject {
    func libraryListItems() -> [CarPlayListItemModel]
    func showListItems(subscriptionIndex: Int) -> [CarPlayListItemModel]
    func queueListItems() -> [CarPlayListItemModel]
}
```

Production builder maps each model to a real `CPListItem` using the **spike-validated**
initializer (image at init — property is get-only):

```swift
let item = CPListItem(text: model.text, detailText: nil, image: model.image)
// optional later updates: item.setImage(_:), item.setText(_:)
item.userInfo = model.episodeID ?? model.subscriptionIndex.map(String.init)
item.handler = { /* coordinator */ _, completion in …; completion() }
```

Library rows set `accessoryType = .disclosureIndicator`.

### 5. Selection → playback (AC4)

List selection calls **`EpisodePlaying.play(episodeID:)`** (ADR-009), **not**
`PlaybackTransporting.play()` (ADR-011 — no episode ID).

```swift
@MainActor
final class CarPlayCoordinator {
    init(
        builder: any CarPlayTemplateBuilding,
        player: any EpisodePlaying,
        nowPlaying: CarPlayNowPlayingUpdater,
        listRecorder: (any CarPlayListPresenting)? = nil  // test double
    )

    /// Install root tab templates (or record them on the list double).
    func activateRoot()

    /// Programmatic selection for tests / handler body.
    func selectQueueItem(at index: Int)
    func selectShowEpisode(subscriptionIndex: Int, episodeIndex: Int)
}
```

**AC4 binding:** inject `EpisodePlayingSpy` (existing Slice 11 spy). Invoke the
queue item handler / `selectQueueItem(at: 1)` → exactly one
`play(episodeID: "fixture-ep-002")`.

Slice wording “PlaybackTransportSpy” is interpreted as **the episode-play spy
seam**; do not extend `PlaybackTransporting` with `play(episodeID:)`. Remote
lock-screen transport stays ADR-011-only.

**Test double — `CPListTemplateRecorder` / `CarPlayListPresenting`:**

- Records sections/items (text, image non-nil, episode IDs).
- Stores selection handlers per index; `fireSelection(at:)` invokes handler +
  completion (mirrors `CPListItem.handler`).

### 6. Now playing updater (AC5)

`CPNowPlayingTemplate` has **no** title or play/pause API — CarPlay reads
`MPNowPlayingInfoCenter` (already fed by Slice 14). Tests still need a seam:

```swift
enum CarPlayPlaybackState: Equatable {
    case playing
    case paused
}

@MainActor
protocol CarPlayNowPlayingPresenting: AnyObject {
    func updatePlaybackState(_ state: CarPlayPlaybackState)
    func updateTitle(_ title: String)
}

@MainActor
final class CarPlayNowPlayingUpdater {
    init(engine: PlaybackEngine, presenting: any CarPlayNowPlayingPresenting)

    /// Call after constructing / when engine identity changes.
    func attach()

    /// Forward engine.play() / pause() side effects into `presenting`.
    /// Production: also relies on existing Now Playing info pushes from PlaybackEngine.
}
```

**AC5 binding:**

1. `PlaybackEngine` with `test-clip.m4a`, title **"Alpha Signal — Pilot Launch"**.
2. Inject `CPNowPlayingTemplateDouble` conforming to `CarPlayNowPlayingPresenting`.
3. `play()` then `pause()` → double records exactly **`[.playing, .paused]`**.
4. After first `play()` only, `lastTitle == "Alpha Signal — Pilot Launch"` exactly.

**Production adapter:** may no-op title writes (system UI uses Now Playing center) but
**must** still call the presenting methods when used behind the updater in tests;
production can use a recorder-free adapter that only ensures
`CPNowPlayingTemplate.shared` is configured (buttons optional; rate/sleep OOS).

### 7. Scene delegate + Info.plist (AC6)

```swift
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        // Resolve CarPlayDependencyProviding.shared → CarPlayCoordinator.activateRoot()
        // interfaceController.setRootTemplate(tabBar, animated: …)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) { /* clear retained controller ref */ }
}
```

**Info.plist** (structural AC6 — exactly **one** scene whose `UISceneClassName` is
`CPTemplateApplicationScene`). With
`INFOPLIST_KEY_UIApplicationSceneManifest_Generation = NO` (required so the CarPlay
role is not overwritten), the phone **`UIWindowSceneSessionRoleApplication`** must
also be declared explicitly — otherwise SwiftUI’s `WindowGroup` never connects,
the test host fails to launch / play audio, and UITests time out:

```xml
<key>UIApplicationSceneManifest</key>
<dict>
  <key>UIApplicationSupportsMultipleScenes</key>
  <true/>
  <key>UISceneConfigurations</key>
  <dict>
    <key>UIWindowSceneSessionRoleApplication</key>
    <array>
      <dict>
        <key>UISceneClassName</key>
        <string>UIWindowScene</string>
        <key>UISceneConfigurationName</key>
        <string>Default Configuration</string>
      </dict>
    </array>
    <key>CPTemplateApplicationSceneSessionRoleApplication</key>
    <array>
      <dict>
        <key>UISceneClassName</key>
        <string>CPTemplateApplicationScene</string>
        <key>UISceneConfigurationName</key>
        <string>CarPlay</string>
        <key>UISceneDelegateClassName</key>
        <string>$(PRODUCT_MODULE_NAME).CarPlaySceneDelegate</string>
      </dict>
    </array>
  </dict>
</dict>
```

AC6 reads the **built** test-host app bundle plist and counts configurations with
`UISceneClassName == CPTemplateApplicationScene` → exactly **1** (window scenes
are ignored by that count).

**Key-window caveat:** Declaring both phone `UIWindowScene` and CarPlay scenes can
leave an empty system window as key while SwiftUI’s `WindowGroup` is visible but
not key. XCTest then synthesizes taps that miss UIKit `UISwitch` controls (Slice 09
`AnalysisProgressUITests` recording: episode toggle stays off; `testToggleBadges`
passes only because it first taps the SwiftUI channel toggle). `RootView` installs
`KeyWindowActivator` so the content window becomes key on appear.

### 8. Entitlement request (not a Done gate)

| Step | Detail |
|------|--------|
| Entitlement key | `com.apple.developer.carplay-audio` |
| Request | Apple Developer → Certificates, Identifiers & Profiles → App ID → Additional Capabilities → CarPlay Audio (or CarPlay entitlement request form per current Apple process) |
| Local | May add the key to `PodWash.entitlements` once the App ID is enabled; simulator/device without approval still builds |
| CI / Done | **Never** block on Apple approval or head-unit pairing |
| Manual spot-check | Optional CarPlay Simulator / car after entitlement; documentation only |

### 9. Empirical validation (CarPlay framework spike)

Measured against **iPhoneSimulator26.1.sdk** CarPlay headers + `swiftc -typecheck`
(2026-07-11):

| Claim | Result |
|-------|--------|
| `CPListItem(text:detailText:)` | Compiles; `text` is get-only `String?` |
| `image` property assignment `item.image = …` | **Fails** — property is **get-only** |
| Image at init | `CPListItem(text:detailText:image:)` compiles; `item.image != nil` |
| Image update | `setImage(_:)` compiles (iOS 14+) |
| Selection | `handler: (CPSelectableListItem, @escaping () -> Void) -> Void`; must call completion |
| Now Playing | `CPNowPlayingTemplate.shared` (ObjC `sharedTemplate` renamed in Swift); `init` unavailable |
| Now Playing title/state APIs | **None** on template — doubles must own title/state recording; production UI reads Now Playing center |
| Root chrome | `CPListTemplate` + `CPTabBarTemplate(templates:)` typecheck |
| Scene | `CPTemplateApplicationScene` / `CPTemplateApplicationSceneDelegate.didConnectInterfaceController` present in SDK |
| Entitlement | Documented as `com.apple.developer.carplay-audio` (CarPlay Developer Guide) |

**Consequence for QA:** AC1–AC3 assert on `CarPlayListItemModel` (or recorder rows), not
by mutating `CPListItem.image` as a stored property. AC5 asserts on
`CarPlayNowPlayingPresenting` double fields, never live `CPNowPlayingTemplate.shared`
metadata. Production mapping uses init-with-image / `setImage`.

No head-unit measurement is required for Done.

### 10. MainActor deinit (test-host)

Under `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`, `@MainActor` CarPlay types must
use **`nonisolated deinit {}`** (and `nonisolated(unsafe)` on stored properties
released from that deinit) — same pattern as `LibraryViewModel` /
`QueueCoordinator`. Without it, XCTest teardown hits
`swift_task_deinitOnExecutorImpl` → `BUG_IN_CLIENT_OF_LIBMALLOC` / SIGABRT when
short-lived data sources (e.g. inside `queueListItems()`) deallocate.

### 11. Cross-cutting impact

| Surface | Impact |
|---------|--------|
| `PodcastStore` / `QueueStore` | **Read-only** consumption; no API change |
| `PlaybackEngine` | Optional `onPlayPauseIntent` + `nowPlayingTitle` for CarPlay updater (Slice 15) |
| `PlaybackTransporting` / remote commands | **Unchanged**; CarPlay list play uses `EpisodePlaying` |
| `AppShellModel` / `PodWashApp` | Minimal dependency registration for scene delegate |
| `Info.plist` | Scene manifest addition (AC6) |
| Parallel Slice 16 | No shared CarPlay files; serialize only if both touch `Info.plist` / app bootstrap |

## Consequences

- CarPlay browsing/playback is CI-assertable via data sources + doubles.
- Framework quirks (get-only `image`, shared Now Playing, entitlement) are pinned
  before QA writes tests.
- Lock-screen / Control Center behavior remains Slice 14’s responsibility.
- Physical CarPlay remains a manual spot-check after Apple entitlement approval.
