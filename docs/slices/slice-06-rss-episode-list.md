# Slice 06 — RSS feed + episode list UI

| Field | Value |
|-------|-------|
| **ID** | 06 |
| **Title** | RSS feed + episode list UI |
| **Status** | Draft |
| **Crux** | A bundled RSS fixture parses to episode metadata matching golden JSON, and the episode list renders it — verified by **accessibility-identifier asserts only** (one UI mechanism, no snapshot dependency). |

## PRD / spec references

- PRD §2 — Subscribe via RSS, episode list, show notes, artwork
- PRD §9 — Client-direct fetch; no backend

## Goal

Parse a feed (stubbed/bundled) and show episodes in a SwiftUI list.

## Deliverables

- RSS parser (`URLSession` + `XMLParser`); injectable session / `URLProtocol` stub for tests
- Podcast detail + episode list SwiftUI views with stable `accessibilityIdentifier`s (e.g. `episodeList`, `episodeCell_<index>`)
- In-memory persistence stub (durable store comes with Slice 11)
- Mock RSS XML in `PodWash/PodWashTests/Fixtures/feeds/` + golden `sample_feed_expected.json` (provenance: hand-transcribed from the fixture XML)
- **Launch-argument fixture mode** (e.g. `-UITestFixtureFeed`): app loads the bundled feed instead of the network — UI tests cannot read the unit-test bundle
- `RSSParserTests`, `EpisodeListViewModelTests`, `EpisodeListUITests`

## UI verification mechanism (decided)

**Accessibility asserts only.** No snapshot-testing dependency is added in this slice (or by default anywhere — a future slice must explicitly justify one). UI tests assert identifiers, labels, and values.

## Depends on

- Slice 01

**Parallelizable:** Yes — parallel with Slices 02, 03, 05.

## Out-of-scope

- Playback integration; downloads (Slice 10)
- Durable SwiftData/Core Data persistence (Slice 11)
- Podcast directory search / iTunes API
- Profanity toggles on episodes (Slice 09)

## Acceptance criteria

- [ ] 1. Unit test: parse bundled `sample_feed.xml` → episode count, titles, dates equal golden `sample_feed_expected.json` exactly.
- [ ] 2. Unit test: malformed feed returns a typed error; empty feed returns an empty list (no crash, no nil).
- [ ] 3. Unit test: artwork URL and show notes extracted when present in fixture; nil when absent.
- [ ] 4. UI test (fixture-mode launch): element with identifier `episodeList` exists and the first **3** cells' labels equal the first 3 fixture titles.
- [ ] 5. Unit test: stubbed network failure surfaces a typed error state in the view model.
- [ ] 6. Full suite green via `scripts/verify.sh`.

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/RSSParserTests.swift` | `testParseSampleFeedMatchesGolden` | TBD |
| 2 | `PodWash/PodWashTests/RSSParserTests.swift` | `testMalformedAndEmptyFeeds` | TBD |
| 3 | `PodWash/PodWashTests/RSSParserTests.swift` | `testArtworkAndShowNotesOptional` | TBD |
| 4 | `PodWash/PodWashUITests/EpisodeListUITests.swift` | `testEpisodeListRendersFixtureTitles` | Launch-arg fixture mode |
| 5 | `PodWash/PodWashTests/EpisodeListViewModelTests.swift` | `testNetworkFailureErrorState` | TBD |
| 6 | — | — | Command-level |

## Verification commands

```bash
# Fast inner loop:
scripts/verify.sh -only-testing:PodWashTests/RSSParserTests -only-testing:PodWashTests/EpisodeListViewModelTests -only-testing:PodWashUITests/EpisodeListUITests

# Done gate — FULL suite:
scripts/verify.sh
```

## Verification record (QA fills at Verify)

```
VERIFY RESULT: (pending)
```

## Done gate

- [ ] Every AC mapped to a test; all rows filled
- [ ] **Full suite green:** unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0
- [ ] Verification record pasted above
- [ ] Auto-commit on green: `slice-06: <short description>`

## Role artifacts

| Role | Gate | Artifact path |
|------|------|---------------|
| Architect | Required | `docs/adr/004-rss-parser.md` (TBD) |
| UX | Required | `docs/slices/slice-06-ux.md` (TBD) |
