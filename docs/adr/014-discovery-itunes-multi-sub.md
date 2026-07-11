# ADR-014 — Discovery: iTunes Search client + multi-subscription store

| Field | Value |
|-------|-------|
| **Status** | Accepted |
| **Date** | 2026-07-10 |
| **Supersedes** | — (extends [ADR-009](009-queue-resume.md) `PodcastStore` / `CDPodcast` from single-row clear-on-save to multi-subscription; does **not** replace ADR-009) |
| **Builds on** | [ADR-000](000-foundations.md) §6; [ADR-004](004-rss-parser.md) (`RSSParser`, `FeedFetching`, `PodcastFeed` / `Episode`, `URLProtocol` pattern); [ADR-007](007-persistence-core-data.md); [ADR-009](009-queue-resume.md) (`PersistenceController` reload, `PodcastStore`); [ADR-001](001-playback-engine.md) (launch-argument fixture routing) |
| **Slice** | [slice-22-discovery-subscribe.md](../slices/slice-22-discovery-subscribe.md) |

## Context

Slice 22 ships the MVP Discover shell: browse/search via Apple’s keyless iTunes
Search API (PRD §9), subscribe by fetching the result’s RSS `feedUrl`, and persist
**multiple** subscriptions in Core Data.

Today `PodcastStore.save(_:)` calls `clearPodcastRows()` before inserting one
`CDPodcast` (ADR-009 §2: “single active subscription”). That blocks multi-sub and
must change in this slice. Product pins (2026-07-10):

- Popular list = generic iTunes Search URL (below).
- Subscribe UX = loading on the tapped row (no optimistic library row; library is
  Slice 23).

Tests must never hit live iTunes or RSS — `URLProtocol` fixtures only.

**Numbering note:** Slice 22 drafts referred to “ADR-013”; that number is already
[ADR-013](013-segmentation-integration.md). This decision is **ADR-014**.

## Decision

### 1. Module layout

| File | Target | Status | Responsibility |
|------|--------|--------|----------------|
| `PodWash/PodWash/ITunesSearchClient.swift` | app | **new** | Injectable `URLSession`; `fetchPopular()` + `search(term:)`; JSON → `[PodcastSearchResult]` |
| `PodWash/PodWash/PodcastSearchResult.swift` | app | **new** | Value type for directory hits (may live in the client file) |
| `PodWash/PodWash/DiscoverViewModel.swift` | app | **new** | Popular load, debounced search, subscribe orchestration, typed `subscribeState` |
| `PodWash/PodWash/DiscoverView.swift` | app | **new** | SwiftUI Discover screen + accessibility contract |
| `PodWash/PodWash/FixtureDiscover.swift` | app | **new** | `-UITestFixtureDiscover` detection; wires stub session + bundled fixture maps |
| `PodWash/PodWash/DiscoverStubURLProtocol.swift` | app | **new** | App-target `URLProtocol` used **only** when FixtureDiscover is enabled (UI tests) |
| `PodWash/PodWash/PodcastStore.swift` | app | **changed** | Multi-sub APIs; remove clear-all-on-save; upsert by `feedURLString` |
| `PodWash/PodWash/PodWash.xcdatamodeld` | app | **changed** | `CDPodcast` schema delta (below) |
| `PodWash/PodWash/EpisodeListViewModel.swift` | app | **changed** | Pass `feedURL` into store save (no clear-all) |
| `PodWash/PodWash/RootView.swift` | app | **changed** | Route `-UITestFixtureDiscover` → `DiscoverView` |
| `PodWash/PodWash/Fixtures/itunes/*.json` | app | **new** | App-bundle copies for UI-test stub protocol |
| `PodWash/PodWashTests/Fixtures/itunes/*` | test | **new (QA)** | Unit fixtures + provenance README |
| `PodWash/PodWashTests/ITunesSearchClientTests.swift` | test | **new (QA)** | AC1–AC2 |
| `PodWash/PodWashTests/PodcastStoreMultiSubscriptionTests.swift` | test | **new (QA)** | AC3–AC4 |
| `PodWash/PodWashTests/DiscoverViewModelTests.swift` | test | **new (QA)** | AC5 |
| `PodWash/PodWashUITests/DiscoverUITests.swift` | test | **new (QA)** | AC6–AC7 |

**Unchanged:** `RSSParser` / `PodcastFeed` / `Episode` public shapes (ADR-004);
`PlaybackEngine`; `QueueStore` / `ResumePositionStore` APIs; interval/ASR stack.

### 2. Pinned popular-query URL

Production `fetchPopular()` **must** request exactly:

```
https://itunes.apple.com/search?term=podcast&media=podcast&entity=podcast&limit=25
```

Binding rules:

- Host `itunes.apple.com`, path `/search`.
- Query items (order-insensitive for matching stubs): `term=podcast`,
  `media=podcast`, `entity=podcast`, `limit=25`.
- Injectable base URL is allowed **only** if the resolved absolute URL is
  identical to the string above (same host/path/query semantics). Tests stub this
  URL only for the popular path.

`search(term:)` builds the same host/path with `term=<urlencoded term>`,
`media=podcast`, `entity=podcast`, `limit=25`. Empty / whitespace-only `term` →
return `[]` **without** creating a `URLSession` task (AC2).

### 3. Domain types + `ITunesSearchClient` API

```swift
struct PodcastSearchResult: Equatable, Identifiable, Sendable {
    var id: Int { collectionId }
    let collectionId: Int
    let title: String          // JSON `collectionName`
    let feedURL: URL           // JSON `feedUrl`
    let artworkURL: URL?       // JSON `artworkUrl600` (preferred) or `artworkUrl100`
}

struct PodcastSummary: Equatable, Identifiable, Sendable {
    var id: String { feedURL.absoluteString }
    let title: String
    let feedURL: URL
    let artworkURL: URL?
    let collectionId: Int?
}

struct ITunesSearchClient: Sendable {
    let session: URLSession
    /// Defaults to the pinned production popular URL (§2).
    let popularURL: URL

    init(session: URLSession = .shared, popularURL: URL = ITunesSearchClient.defaultPopularURL)

    static let defaultPopularURL: URL  // §2 string

    func fetchPopular() async throws -> [PodcastSearchResult]
    func search(term: String) async throws -> [PodcastSearchResult]
}
```

**JSON contract (fixture-defined, not live-captured):**

| JSON field | Maps to |
|------------|---------|
| `results[].collectionId` | `collectionId` (`Int`) |
| `results[].collectionName` | `title` |
| `results[].feedUrl` | `feedURL` (invalid/missing → skip that result) |
| `results[].artworkUrl600` else `artworkUrl100` | `artworkURL` |

Top-level `resultCount` is ignored for assertions; tests assert array length and
field equality against golden fixture strings. Results missing a usable `feedUrl`
are dropped (not a thrown error). Transport / non-2xx / undecodable payload →
throw a small `ITunesSearchError` (`networkFailure` / `invalidResponse`) —
Discover treats load failures as empty list or a failed phase (UX pins UI; VM
exposes a typed load phase if needed). **AC1–AC2 only require success-path
parsing against stubs.**

### 4. Core Data schema delta (`CDPodcast`)

Additive lightweight migration on the existing model (ADR-009 v1 → same
`.xcdatamodeld` with new attributes; inferred migration OK):

| Attribute | Type | Notes |
|-----------|------|-------|
| `feedURLString` | `String` (required, default `""`) | **Stable subscription key**; uniqueness constraint |
| `collectionId` | `Int64` optional | From iTunes when known; not the idempotency key |
| `subscribedAt` | `Date` (required, default now) | Insertion order for `allSubscriptions()` |

**Why `feedURLString`, not `collectionId`:** AC3–AC5 and idempotency are defined
on `feedURL`. RSS is the subscription source of truth; a future “add by URL” path
would have no collection id. Store `collectionId` as metadata only.

**Episode uniqueness:** `CDEpisode.id` remains globally unique (ADR-009). Fixture
feeds used in multi-sub tests **must** use distinct episode `id` values across
podcasts. Upsert matches episodes by `(podcast, id)` within the subscription being
saved; re-subscribe replaces that podcast’s episode set (no duplicate rows — AC4).

### 5. `PodcastStore` multi-subscription API

```swift
nonisolated final class PodcastStore: @unchecked Sendable {
    init(context: NSManagedObjectContext, retaining controller: PersistenceController? = nil)

    /// Upsert by `result.feedURL`. Does **not** clear other subscriptions.
    /// Replaces episode rows for that feed only (idempotent count — AC4).
    func saveSubscription(from result: PodcastSearchResult, feed: PodcastFeed) throws

    /// Upsert by explicit feed URL (fixture / EpisodeListViewModel path).
    func save(_ feed: PodcastFeed, feedURL: URL) throws

    var subscriptionCount: Int { get }
    func allSubscriptions() -> [PodcastSummary]   // ascending `subscribedAt`, then `feedURLString`
    func subscription(forFeedURL feedURL: URL) -> PodcastFeed?
    func isSubscribed(feedURL: URL) -> Bool

    /// Legacy single-feed read: first subscription by `allSubscriptions()` order, else nil.
    var currentFeed: PodcastFeed? { get }
    var episodes: [Episode] { get }

    func clear() throws   // deletes all CDPodcast rows (tests / reset only)
}
```

**Binding behavior:**

| Call | Effect |
|------|--------|
| `saveSubscription` / `save(_:feedURL:)` | Upsert `CDPodcast` where `feedURLString == feedURL.absoluteString`; set title/artwork/description from `PodcastFeed` (+ `collectionId` from result when present); set `subscribedAt` only on **insert**; replace that podcast’s `episodes` ordered set |
| Same `feedURL` twice | `subscriptionCount` unchanged; episode count for that feed equals latest feed’s count (no append) — AC4 |
| Two distinct feed URLs | `subscriptionCount == 2`; reload via ADR-009 `PersistenceController.inMemory(identifier:)` retains both — AC3 |
| Legacy `save(_ feed:)` **without** URL | **Removed** from the public contract. Call sites migrate to `save(_:feedURL:)` (fixture uses `FixtureFeed.fixtureFeedURL`) |

**Forbidden:** calling `clearPodcastRows()` (or equivalent delete-all) inside
subscribe/save paths.

**`CleaningToggleStore` (cross-cutting, deferred):** remains `fetchLimit = 1`
“first podcast” semantics this slice. Multi-channel cleaning UX is Slice 23+;
existing single-subscription tests stay valid when only one `CDPodcast` exists.
Do **not** broaden cleaning APIs in Slice 22.

### 6. `DiscoverViewModel` + subscribe flow

```swift
@MainActor @Observable
final class DiscoverViewModel {
    enum LoadPhase: Equatable {
        case idle, loading, loaded, failed
    }

    enum SubscribeState: Equatable {
        case idle
        case loading(index: Int)   // loading on tapped row (product decision)
        case succeeded(index: Int)
        case failed                // AC5 — typed case, not string match
    }

    private(set) var popularResults: [PodcastSearchResult] = []
    private(set) var searchResults: [PodcastSearchResult] = []
    private(set) var loadPhase: LoadPhase = .idle
    private(set) var subscribeState: SubscribeState = .idle

    init(
        searchClient: ITunesSearchClient,
        parser: RSSParser,
        store: PodcastStore,
        searchDebounceNanoseconds: UInt64 = 300_000_000  // 300 ms
    )

    func loadPopular() async
    /// Immediate search (unit tests). Empty term → `searchResults = []`, no network.
    func search(term: String) async
    /// UI path: debounces then calls `search(term:)`.
    func scheduleSearch(term: String)
    /// Subscribe `popularResults[index]` or active search list — see below.
    func subscribe(atIndex index: Int) async
}
```

**Subscribe orchestration (AC5):**

1. Resolve `PodcastSearchResult` from the **active list**: if `searchResults` is
   non-empty, index into `searchResults`; else index into `popularResults`.
2. Set `subscribeState = .loading(index)`.
3. `parser.parse(url: result.feedURL)` via injected `RSSParser` / `FeedFetching`.
4. On success: `store.saveSubscription(from:result, feed:)`; 
   `subscribeState = .succeeded(index)`.
5. On RSS/network failure: `subscribeState = .failed` (do not write store).

`isSubscribed` / episode counts are read from `PodcastStore` (not duplicated in VM
state) so tests assert store truth after subscribe.

### 7. SwiftUI accessibility contract (Discover)

| Identifier | Element |
|------------|---------|
| `discoverRoot` | Root container |
| `discoverSearchField` | Search `TextField` |
| `popularCell_<index>` | Popular row (`0…n`) |
| `searchResultCell_<index>` | Search result row |
| `subscribeButton_<index>` | Subscribe control on the row under test |

- Row **accessibility label** = podcast `title` **exactly** (AC6/AC7).
- After successful subscribe, `subscribeButton_<index>` `accessibilityValue == "1"`
  within **5 s** (AC7). Unsubscribed value `"0"`.
- While `subscribeState == .loading(index)`, the matching row may show a progress
  affordance; identifier of the button remains stable.

Exact visual layout is UX (`docs/slices/slice-22-ux.md`); this ADR binds
identifiers and value semantics only.

### 8. Fixture mode: `-UITestFixtureDiscover`

```swift
enum FixtureDiscover {
    static let launchArgument = "-UITestFixtureDiscover"
    static var isEnabled: Bool { /* ProcessInfo launch args */ }
}
```

When enabled:

1. `RootView` shows `DiscoverView` (not `ContentView`). Routing priority: existing
   fixture modes that already win (e.g. `FixtureAudio`, `FixtureSkipOverride`,
   `FixtureSettings`) keep precedence; if only `-UITestFixtureDiscover` is set,
   Discover is shown.
2. `DiscoverViewModel` is constructed with an `URLSession` whose configuration
   sets `protocolClasses = [DiscoverStubURLProtocol.self]` (and does not use
   `.shared`).
3. `DiscoverStubURLProtocol` (app target) serves:
   - pinned popular URL → bundled `itunes_popular_response.json` (exactly 3 results)
   - search URL with `term=fixture-query` → bundled `itunes_search_response.json`
     (exactly 2 results)
   - each fixture `feedUrl` → bundled `sample_feed.xml` (5 episodes) **or** the
     second stub feed XML when that URL is requested (unit tests may use a
     one-episode stub; UI subscribe AC uses the 5-episode sample)
4. **No live network** in UI or unit tests.

Unit tests register their own `URLProtocol` on an injected session (ADR-004
pattern); they do not require `FixtureDiscover`.

### 9. Empirical validation (networking)

| Claim | Validation |
|-------|------------|
| iTunes JSON field mapping | **Fixture contract** — hand-authored JSON with documented provenance (`Fixtures/itunes/README.md`). No live capture at test time. |
| Popular URL shape | **Pinned string** (§2); stub matches host/path/query. |
| RSS subscribe path | Reuses ADR-004 `RSSParser` + `URLProtocol`; already proven in Slice 06. |
| Live Apple API drift | Out of automated scope; if production parse fails in the wild, update client + fixtures together — not a Slice 22 AC. |

No separate device spike is required before QA writes tests: behavior under test is
fully determined by fixtures and the pinned URL, consistent with ADR-004’s offline
RSS approach.

### 10. Cross-cutting impact

| Area | Impact |
|------|--------|
| `PodcastStore.save` | **Breaking** — clear-on-save removed; callers must pass `feedURL` |
| `CDPodcast` | New attributes + uniqueness on `feedURLString` |
| `EpisodeListViewModel` | Must call `save(_:feedURL:)` |
| `CleaningToggleStore` | Still single-row; document limitation; no API change this slice |
| `RootView` | New fixture branch; serialize with Slice 23 on production shell |
| Parallel slices | Do not edit `PodcastStore` / Discover files until Slice 22 Done |

### 11. Out of scope (this ADR)

- Library tab / production `TabView` shell (Slice 23)
- Multi-channel cleaning / unrelated-content per subscription UX
- PodcastIndex or keyed directory APIs
- Background feed refresh / notifications
- Manual “paste feed URL” UI
- StoreKit gating of subscribe

## File list (Engineer)

**App — new:** `ITunesSearchClient.swift`, `DiscoverViewModel.swift`,
`DiscoverView.swift`, `FixtureDiscover.swift`, `DiscoverStubURLProtocol.swift`,
app-bundle `Fixtures/itunes/*.json` (+ feed copies as needed).

**App — changed:** `PodcastStore.swift`, `PodWash.xcdatamodeld`,
`EpisodeListViewModel.swift`, `RootView.swift`.

**Tests — QA:** fixtures under `PodWashTests/Fixtures/itunes/`, mapped test files
in the slice verification table.

## Consequences

- Discover + subscribe are fully offline-assertable via `URLProtocol` and in-memory
  Core Data reload (ADR-009 pattern).
- Multi-subscription is the durable store model going forward; Slice 23 Library
  reads `allSubscriptions()` without further schema invention.
- Idempotent subscribe is keyed by **feed URL string equality**
  (`absoluteString`), not collection id.
- ADR-009’s single-subscription prose is obsolete for `PodcastStore`; this ADR
  is the binding multi-sub contract. Cleaning stores remain single-podcast until a
  later ADR.

## Alternatives considered

| Option | Why not chosen |
|--------|----------------|
| **Idempotency key = `collectionId`** | Breaks non-iTunes subscribe paths; ACs are feedURL-based. |
| **Optimistic library row while RSS loads** | Rejected by product (2026-07-10); loading on row instead. |
| **PodcastIndex / proxy** | Requires signed key (PRD §9); out of MVP. |
| **Keep clear-on-save + side table** | Unnecessary complexity; upsert-by-feedURL is enough. |
