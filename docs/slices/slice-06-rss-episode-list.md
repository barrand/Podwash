# Slice 06 — RSS feed + episode list UI

| Field | Value |
|-------|-------|
| **ID** | 06 |
| **Title** | RSS feed + episode list UI |
| **Status** | Done |
| **Crux** | Bundled RSS XML parses to episode metadata that matches an independent golden JSON field-for-field, and the episode list surfaces the first 3 fixture titles via `accessibilityIdentifier` asserts only — no live network in tests, no snapshot dependency. |

## PRD / spec references

- PRD §2 — Subscribe via public RSS feeds; episode list per show with show notes and artwork (directory search phased later)
- PRD §9 — Client-direct fetch (`URLSession` + XML on device); no backend; subscriptions stored on-device (this slice uses an in-memory stub — durable store is Slice 11)

## Goal

Parse a bundled RSS feed client-side and render its episodes in a SwiftUI list, verified end-to-end without network or snapshots.

## Deliverables

- RSS parser (`URLSession` + `XMLParser`); injectable session / `URLProtocol` stub for tests (PRD §9 client-direct pattern)
- `Episode` model: at minimum `title`, `pubDate` (normalized `Date` or ISO8601 string), `showNotes` (`String?`), `artworkURL` (`URL?`)
- Podcast detail + episode list SwiftUI views with stable `accessibilityIdentifier`s: `episodeList`, `episodeCell_<index>` (0-based)
- In-memory subscription/episode store stub (durable Core Data store is Slice 11, ADR-007)
- Fixture `PodWash/PodWashTests/Fixtures/feeds/sample_feed.xml` — valid RSS 2.0 with **exactly 5** `<item>` elements; ≥1 item includes artwork + show notes, ≥1 item omits both (provenance in fixture README)
- Golden `PodWash/PodWashTests/Fixtures/feeds/sample_feed_expected.json` — **hand-transcribed from the fixture XML** (independent provenance; never generated from parser output)
- **Launch-argument fixture mode** (`-UITestFixtureFeed`): app loads the bundled feed instead of the network — UI tests cannot read the unit-test bundle
- `RSSParserTests`, `EpisodeListViewModelTests`, `EpisodeListUITests`

## UI verification mechanism (decided)

**Accessibility asserts only.** No snapshot-testing dependency is added in this slice (or by default anywhere — a future slice must explicitly justify one). UI tests assert identifiers, labels, and values.

## Depends on

- Slice 01

**Parallelizable:** Yes — parallel with Slices 02, 03, 05.

## Out-of-scope

- Live network RSS fetch in automated tests (parser/network paths use `URLProtocol` stubs or bundled fixtures only)
- Snapshot / pixel-diff UI testing
- Podcast directory search / iTunes Search API (PRD §2 phased; PRD §9)
- RSS feed URL entry / subscribe flow UI (add-feed screen is a later slice)
- Playback integration (Slice 08); downloads (Slice 10)
- Durable Core Data persistence for subscriptions or episodes (Slice 11, ADR-007)
- Profanity toggles, analysis, or cleaning UI on episodes (Slices 07–09)
- Background feed polling / new-episode notifications (PRD §9)
- Server-side proxy or backend of any kind (PRD §9)

## Acceptance criteria

Automatable only. **XCTSkip is not allowed on core ACs** — a mapped test that cannot run must fail.

- [x] 1. Unit test: parse bundled `sample_feed.xml` → parsed episode count **== 5**; for every episode, `title`, `pubDate`, `showNotes`, and `artworkURL` equal the golden `sample_feed_expected.json` entry **exactly** (string equality for text fields; `nil` for absent optional fields).
- [x] 2. Unit test: malformed XML (unclosed tag) returns typed `RSSParserError` (not a generic `Error`); valid XML with **0** `<item>` elements returns non-optional `PodcastFeed` with `episodes.count == 0` (no crash, no `nil` result).
- [x] 3. Unit test: on the fixture, the item with artwork + show notes in XML has **non-nil** `artworkURL` and **non-empty** `showNotes`; the item omitting both has **`artworkURL == nil`** and **`showNotes == nil`**.
- [x] 4. UI test (fixture-mode launch via `-UITestFixtureFeed`): element `episodeList` exists; cells `episodeCell_0`, `episodeCell_1`, `episodeCell_2` exist and each cell's **accessibility label equals** the corresponding golden title string **exactly** (first **3** episodes).
- [x] 5. Unit test: stubbed `URLSession` network failure (injected `URLError(.notConnectedToInternet)` or equivalent) surfaces typed error state in the view model (`phase == .failed(RSSParserError.networkFailure)` — structural enum-case assert, not string matching).
- [x] 6. Full suite green via `scripts/verify.sh` with **exit 0, failed 0, skipped 0**.

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/RSSParserTests.swift` | `testParseSampleFeedMatchesGolden` | Loads `sample_feed.xml` + golden JSON from test bundle; asserts count == 5; field-for-field equality on title, pubDate, showNotes, artworkURL |
| 2 | `PodWash/PodWashTests/RSSParserTests.swift` | `testMalformedAndEmptyFeeds` | Malformed XML → `RSSParserError`; empty valid feed → `PodcastFeed` with `episodes.count == 0`; never crashes or returns nil |
| 3 | `PodWash/PodWashTests/RSSParserTests.swift` | `testArtworkAndShowNotesOptional` | Asserts non-nil/non-empty on the rich item; nil on the sparse item from the same fixture |
| 4 | `PodWash/PodWashUITests/EpisodeListUITests.swift` | `testEpisodeListRendersFixtureTitles` | Launch arg `-UITestFixtureFeed`; asserts `episodeList` + `episodeCell_0…2` labels match first 3 golden titles exactly |
| 5 | `PodWash/PodWashTests/EpisodeListViewModelTests.swift` | `testNetworkFailureErrorState` | `URLProtocol` stub returns connection error; view model ends in `phase == .failed(.networkFailure)` |
| 6 | — | — | Command-level: unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0 |

## Verification commands

```bash
# Fast inner loop (NOT sufficient for Done):
scripts/verify.sh -only-testing:PodWashTests/RSSParserTests -only-testing:PodWashTests/EpisodeListViewModelTests -only-testing:PodWashUITests/EpisodeListUITests

# Done gate — FULL suite, zero failures, zero skips:
scripts/verify.sh
```

## Verification record (QA fills at Verify)

> Paste the `VERIFY RESULT:` line from the full-suite `scripts/verify.sh` run here.
> A slice without a recorded full-suite green artifact is not Done.

```
VERIFY RESULT: exit=0 total=28 passed=28 failed=0 skipped=0 filtered=0 bundle=build/test-results/verify-20260709-090009.xcresult
```

## Plan review record (coordinator fills before downstream roles)

> Record readonly review outcomes before QA writes tests (ADR review) and before
> Engineer starts (test spec review). No record = next role must not spawn.
> See [`multitask-workflow.md`](../multitask-workflow.md) § Plan review gates.

```
ADR review (2026-07-09): QA cleared — doc harmonization resolved naming (RSSParserError), golden schema, feed.* identifiers, exact cell labels, typed Date/URL equality; fixtures delegated to QA test spec. PM cleared — no scope drift; AC2/AC5 pinned to ADR.
Test spec review (2026-07-09): Architect cleared — tests match ADR-004 public API; no blockers.
```

## Done gate

- [x] Every AC mapped to a test; all rows in the mapping table filled
- [x] **Full suite green:** unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0
- [x] Verification record pasted above (exit code + counts + .xcresult path)
- [x] Auto-commit made on green: `slice-06: <short description>` (push only when the user asks)

## Role artifacts

| Role | Gate | Artifact path |
|------|------|---------------|
| Architect | Required | `docs/adr/004-rss-parser.md` |
| UX | Required | `docs/slices/slice-06-ux.md` |
