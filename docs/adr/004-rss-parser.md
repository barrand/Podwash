# ADR-004 — RSS parser, episode list, and fixture-feed mode

| Field | Value |
|-------|-------|
| **Status** | Accepted |
| **Date** | 2026-07-09 |
| **Supersedes** | — |
| **Builds on** | [ADR-000](000-foundations.md) §6 (`scripts/verify.sh` only); [ADR-001](001-playback-engine.md) (launch-argument fixture mode, app-bundle fixture copies, `RootView` routing, injectable system doubles) |

## Context

Slice 06 delivers client-direct RSS fetch and parse (PRD §9), episode metadata
extraction, and a SwiftUI episode list — all gated by automated tests with no
snapshot dependency. UI tests cannot read the unit-test bundle, so fixture data
must be duplicated into the app bundle and selected via a launch argument, mirroring
`-UITestFixtureAudio` from Slice 03.

The parser must be deterministic against a hand-transcribed golden JSON, tolerate
optional fields (artwork, show notes), distinguish malformed XML from an empty-but-valid
feed, and surface network failures as typed view-model state. Durable persistence
(SwiftData, Slice 11) is out of scope; an in-memory store stub holds parsed results
for this slice only.

## Decision

### 1. Module layout

| File | Target | Status | Responsibility |
|------|--------|--------|----------------|
| `PodWash/PodWash/RSSParser.swift` | app | **new** | `URLSession` fetch + `XMLParser` delegate; synchronous `parse(data:)` for unit tests; async `parse(url:)` for production |
| `PodWash/PodWash/PodcastModels.swift` | app | **new** | `PodcastFeed`, `Episode`, `RSSParserError` |
| `PodWash/PodWash/FeedFetching.swift` | app | **new** | `FeedFetching` protocol + `URLSessionFeedFetcher` production adapter |
| `PodWash/PodWash/EpisodeListViewModel.swift` | app | **new** | `@MainActor @Observable` load state; calls `RSSParser`; writes through store stub |
| `PodWash/PodWash/PodcastDetailView.swift` | app | **new** | Podcast title, artwork, description |
| `PodWash/PodWash/EpisodeListView.swift` | app | **new** | `List` of episodes with stable accessibility identifiers |
| `PodWash/PodWash/FixtureFeed.swift` | app | **new** | Launch-argument detection (`-UITestFixtureFeed`) and bundled XML resolution |
| `PodWash/PodWash/InMemoryPodcastStore.swift` | app | **new** | In-memory stub: holds the latest `PodcastFeed`; replaced by SwiftData in Slice 11 |
| `PodWash/PodWash/RootView.swift` | app | **changed** | Routes fixture-feed mode alongside existing fixture-audio mode |
| `PodWash/PodWash/Fixtures/feeds/sample_feed.xml` | app | **new** | App-bundle copy of the feed fixture (UI tests) |
| `PodWash/PodWashTests/Fixtures/feeds/sample_feed.xml` | test | **new** | Unit-test bundle copy of the same feed |
| `PodWash/PodWashTests/Fixtures/feeds/sample_feed_expected.json` | test | **new** | Golden expected parse output (hand-transcribed from fixture XML) |
| `PodWash/PodWashTests/Fixtures/feeds/sample_feed.provenance.md` | test | **new** | Golden provenance note per `PodWashTests/Fixtures/README.md` |
| `PodWash/PodWashTests/RSSParserTests.swift` | test | **new** | AC1–AC3: golden match, malformed/empty, optional fields |
| `PodWash/PodWashTests/EpisodeListViewModelTests.swift` | test | **new** | AC5: stubbed network failure → error state |
| `PodWash/PodWashUITests/EpisodeListUITests.swift` | test | **new** | AC4: fixture-mode accessibility asserts |

### 2. Domain models

```swift
struct Episode: Equatable, Identifiable, Codable {
    let id: String           // RSS guid, else link, else deterministic hash of title+pubDate
    let title: String
    let pubDate: Date
    let artworkURL: URL?
    let showNotes: String?   // item description / content:encoded when present
    let audioURL: URL?       // enclosure url; stored but not played in this slice
}

struct PodcastFeed: Equatable, Codable {
    let title: String
    let artworkURL: URL?     // channel image / itunes:image
    let description: String? // channel description / itunes:summary
    let episodes: [Episode]  // ordered as in XML (typically newest-first in fixture)
}
```

Golden JSON (`sample_feed_expected.json`) encodes the same shape. Dates use ISO
8601 strings in the golden file; the parser normalizes RSS `pubDate` strings to
`Date` for comparison.

**Normative golden schema** (hand-transcribed; QA commits before Engineer):

```json
{
  "title": "Channel title string",
  "artworkURL": "https://example.com/art.png or null",
  "description": "Channel description or null",
  "episodes": [
    {
      "title": "Episode title",
      "pubDate": "2026-01-15T08:00:00Z",
      "artworkURL": "https://example.com/ep.png or null",
      "showNotes": "HTML or plain text or null"
    }
  ]
}
```

- Top-level keys match `PodcastFeed` fields (`title`, `artworkURL`, `description`, `episodes`).
- Episode keys use `pubDate` (not `published`). Tests decode golden JSON into `PodcastFeed` and compare with typed `Equatable` (`Date` via ISO8601 decoder, `URL` via `absoluteString` equality).
- Fixture XML uses **offline artwork URLs only** (`file://` or omitted); no network image fetch in CI.

### 3. Error types

```swift
enum RSSParserError: Error, Equatable {
    case networkFailure       // URLSession transport error or non-2xx HTTP (no body parse attempted)
    case malformedFeed        // XML parse failure, missing required channel/item fields, or unrecoverable structure
}
```

**Semantics (binding for tests):**

| Input | Result |
|-------|--------|
| Valid XML, zero `<item>` elements | `PodcastFeed` with `episodes: []` — **not** an error |
| Truncated/invalid XML, or channel with no title | `RSSParserError.malformedFeed` |
| `URLSession` error or HTTP status outside 200–299 | `RSSParserError.networkFailure` |
| Valid item missing optional artwork/show-notes elements | `nil` on those fields; parse succeeds |

`RSSParserError` is `Equatable` with `networkFailure` treated as a single case
(no underlying-error equality in tests — assert the case, not `NSError` identity).

### 4. `FeedFetching` — injectable network boundary

```swift
protocol FeedFetching: Sendable {
    func data(from url: URL) async throws -> Data
}

struct URLSessionFeedFetcher: FeedFetching {
    let session: URLSession
    init(session: URLSession = .shared)
    func data(from url: URL) async throws -> Data
}
```

**Unit tests** register a custom `URLProtocol` subclass on a `URLSessionConfiguration`
with `protocolClasses = [StubURLProtocol.self]` and pass that session into
`URLSessionFeedFetcher` → `RSSParser`. This stubs transport without hitting the
network. **Never** assert against live RSS endpoints in CI.

`RSSParser` also exposes **synchronous** `parse(data: Data) throws -> PodcastFeed`
so golden tests load XML directly from `Bundle(for: RSSParserTests.self)` with no
session involved.

### 5. `RSSParser` public API (sketch)

```swift
struct RSSParser: Sendable {
    let fetcher: any FeedFetching

    init(fetcher: any FeedFetching = URLSessionFeedFetcher())
    init(session: URLSession)  // convenience → URLSessionFeedFetcher(session:)

    func parse(data: Data) throws -> PodcastFeed
    func parse(url: URL) async throws -> PodcastFeed
}
```

- Uses `XMLParser` with a delegate that accumulates channel + item fields.
- `XMLParser` sets `shouldProcessNamespaces = false`; element matching uses local names
  (`image`, `date`, `encoded`) **and** prefixed names (`itunes:image` as element name
  string when the feed declares `xmlns:itunes`). Fixture XML includes explicit
  `xmlns:itunes` and `xmlns:content` declarations validated in QA's golden tests.
- Required per item: `title`, `pubDate` (or `dc:date` fallback). Missing either → `malformedFeed`.
- Optional: `itunes:image` / `image` url, `description` / `content:encoded`, `enclosure` url.
- `parse(url:)` fetches via `fetcher`, then calls `parse(data:)`. Fetch failures map to `networkFailure`.

### 6. `EpisodeListViewModel` public API (sketch)

```swift
@MainActor @Observable
final class EpisodeListViewModel {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded(PodcastFeed)
        case failed(RSSParserError)
    }

    private(set) var phase: Phase = .idle

    init(parser: RSSParser, store: InMemoryPodcastStore)

    func load(feedURL: URL) async
    func load(data: Data) async   // fixture / test shortcut; skips network
}
```

- `load` sets `.loading`, then `.loaded` or `.failed`.
- On success, writes the feed into `InMemoryPodcastStore` (stub for Slice 11 wiring).
- Views read `phase` only; no force-unwrap of optional feed.

### 7. `InMemoryPodcastStore` (stub)

```swift
@MainActor
final class InMemoryPodcastStore {
    private(set) var currentFeed: PodcastFeed?

    func save(_ feed: PodcastFeed)
    func clear()
}
```

No disk I/O, no SwiftData. Slice 11 replaces this with a durable store behind the
same call sites where possible.

### 8. SwiftUI views and accessibility contract

| Identifier | Element |
|------------|---------|
| `episodeList` | `List` (or `ScrollView` + `LazyVStack`) containing all episode rows |
| `episodeCell_<index>` | Row at zero-based index (e.g. `episodeCell_0` … `episodeCell_2` for AC4) |
| `podcastTitle` | Channel title text |
| `podcastArtwork` | Artwork `Image` when URL present (fixture uses bundle-local placeholder only — no network fetch) |
| `feed.loading` | `ProgressView` while `phase == .loading` |
| `feed.error` | Error placeholder when `phase == .failed` |
| `feed.empty` | Empty state when loaded feed has zero episodes |

Row **accessibility labels** must **equal** the episode **title exactly** (AC4 compares
labels to fixture titles via `.accessibilityLabel(title)` with
`.accessibilityElement(children: .ignore)` on each row). Dates appear in
`accessibilityValue` only (ISO-8601 string), not in the label.

`PodcastDetailView` hosts metadata; `EpisodeListView` hosts the list. Fixture mode
may compose them in a single `NavigationStack` root without requiring navigation taps
in UI tests.

### 9. Fixture mode: `-UITestFixtureFeed`

Mirror [ADR-001](001-playback-engine.md) § Fixture mode.

```swift
enum FixtureFeed {
    static let launchArgument = "-UITestFixtureFeed"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    static func bundledData(in bundle: Bundle = .main) -> Data?
    static func bundledURL(in bundle: Bundle = .main) -> URL?

    static let fixtureFeedURL = URL(string: "https://fixture.podwash.tests/sample-feed")!
}
```

When `FixtureFeed.isEnabled`:

1. `RootView` shows the episode-list fixture shell (not `ContentView`, not the audio player).
2. `EpisodeListViewModel.load(data:)` reads `FixtureFeed.bundledData()` — **no network**.
3. Fixed feed URL constant is available for display/debug but is not fetched.

Unit tests load XML from `Bundle(for: RSSParserTests.self)` at
`Fixtures/feeds/sample_feed.xml`. UI tests depend only on the app-bundle copy at
`PodWash/PodWash/Fixtures/feeds/sample_feed.xml`.

### 10. `RootView` routing

Extend the Slice 03 router to support **both** fixture modes. Modes are mutually
exclusive in practice (each UI test passes one launch argument). If both arguments
are present, **`FixtureAudio` wins** (preserves existing playback UI tests).

```swift
// RootView routing order (sketch)
if FixtureAudio.isEnabled {
    // existing PlaybackControlsView path (ADR-001)
} else if FixtureFeed.isEnabled {
    // EpisodeListView + PodcastDetailView driven by fixture-fed view model
} else {
    ContentView()   // production shell until subscription UX lands
}
```

Fixture-feed branch:

- `@State` holds `EpisodeListViewModel` (same pattern as `fixtureEngine`).
- `.task` creates the view model, calls `load(data:)` with bundled XML once.
- Shows `ProgressView` with `feed.loading` until loaded.

### 11. UI verification

Per slice spec: **accessibility-identifier asserts only** — no snapshot testing.
`EpisodeListUITests` launches with `-UITestFixtureFeed`, waits for `episodeList`,
and asserts the first three `episodeCell_<index>` labels match golden titles.

### 12. Out of scope (this ADR)

- Playback of enclosure URLs (Slice 03 engine is separate; no wiring here)
- Downloads (Slice 10)
- SwiftData / Core Data persistence (Slice 11)
- Podcast directory / iTunes search API
- Profanity toggles on episode rows (Slice 09)

## File list (Engineer)

**App target — new**

- `PodWash/PodWash/RSSParser.swift`
- `PodWash/PodWash/PodcastModels.swift`
- `PodWash/PodWash/FeedFetching.swift`
- `PodWash/PodWash/EpisodeListViewModel.swift`
- `PodWash/PodWash/PodcastDetailView.swift`
- `PodWash/PodWash/EpisodeListView.swift`
- `PodWash/PodWash/FixtureFeed.swift`
- `PodWash/PodWash/InMemoryPodcastStore.swift`
- `PodWash/PodWash/Fixtures/feeds/sample_feed.xml`

**App target — changed**

- `PodWash/PodWash/RootView.swift`

**Test target — new**

- `PodWash/PodWashTests/Fixtures/feeds/sample_feed.xml`
- `PodWash/PodWashTests/Fixtures/feeds/sample_feed_expected.json`
- `PodWash/PodWashTests/Fixtures/feeds/sample_feed.provenance.md`
- `PodWash/PodWashTests/RSSParserTests.swift`
- `PodWash/PodWashTests/EpisodeListViewModelTests.swift`
- `PodWash/PodWashUITests/EpisodeListUITests.swift`

**Xcode project**

- Add new Swift files and both `sample_feed.xml` copies to the correct targets.
- Ensure app-bundle feed is in **Copy Bundle Resources**.

## Consequences

- Slice 06 tests are fully offline: golden parse tests use bundled XML; UI tests use
  launch argument + app-bundle XML; network tests use `URLProtocol` stubs only.
- `RSSParser.parse(data:)` is the stable contract for golden verification; fetch layer
  is swappable without changing parse assertions.
- `InMemoryPodcastStore` is explicitly throwaway; Slice 11 must introduce a superseding
  ADR or slice note before replacing it.
- `RootView` accumulates fixture branches; a future refactor may extract a small
  `FixtureRouter`, but Slice 06 keeps the ADR-001 pattern (inline `if/else`).
- Any change to `PodcastFeed` / `Episode` schema or `RSSParserError` cases requires
  updating the golden JSON and this ADR (or a superseding ADR).
