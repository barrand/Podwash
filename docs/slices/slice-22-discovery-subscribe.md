# Slice 22 — Discovery & subscribe (MVP shell — before CarPlay)

| Field | Value |
|-------|-------|
| **ID** | 22 |
| **Title** | Discovery & subscribe |
| **Status** | Ready |
| **Crux** | Stubbed iTunes Search API JSON drives a Discover screen (popular list + search); subscribing fetches RSS via injectable `URLSession`, persists **multiple** subscriptions in Core Data without clear-on-save, and survives container reload — all assertable with `URLProtocol` fixtures, never live network. |

> **Placement:** MVP app shell insert **before CarPlay (Slice 15)** — historically scoped as **"14a"**. Slice 23 completes the production navigation shell ("14b").

## Product decisions (user, 2026-07-10 — unblocks this slice)

| Decision | Choice |
|----------|--------|
| Popular list | **A — generic iTunes Search** — production URL pinned below; tests stub this URL only |
| Subscribe UX while RSS loads | **Loading on tapped row** (PM default) — no optimistic library row (library is Slice 23) |

**Pinned popular query (production):**

```
https://itunes.apple.com/search?term=podcast&media=podcast&entity=podcast&limit=25
```

Architect records the same URL in ADR-014; `fetchPopular()` must hit this path (or an equivalent injectable base + query the ADR documents as identical).

## PRD / spec references

- PRD §2 — Subscribe via public RSS feeds; podcast directory search (table stakes; phased in PRD, MVP via iTunes)
- PRD §9 — iTunes Search API (free, keyless, client-direct); on-device subscription storage; no backend
- `docs/adr/007-persistence-core-data.md` — Core Data stack; multi-subscription schema extension in this slice
- `docs/adr/004-rss-parser.md` — `RSSParser`, `PodcastFeed`, `Episode` models; client-direct fetch pattern

## Goal

Ship a Discover screen powered by the on-device iTunes Search API so users can browse a simple popular list, search podcasts, and subscribe — persisting multiple RSS subscriptions in `PodcastStore`.

## Deliverables

- **`ITunesSearchClient`** (name may refine in ADR) — injectable `URLSession`; parses iTunes Search JSON into `PodcastSearchResult` (minimum: `collectionId: Int`, `title: String`, `feedURL: URL`, `artworkURL: URL?`)
- **`DiscoverViewModel`** — loads popular list on appear; debounced search; subscribe orchestration (resolve feed URL → fetch RSS → save subscription)
- **`DiscoverView`** — SwiftUI Discover screen:
  - Popular/top podcast list (pinned query — see § Product decisions)
  - Search field + results list
  - Subscribe affordance per result
- **Multi-subscription `PodcastStore` refactor** (this slice owns the data model change):
  - Remove single-podcast `clearPodcastRows()` on every `save`
  - Add stable subscription key (`feedURLString` or `collectionId` on `CDPodcast` — Architect pins in ADR)
  - APIs at minimum: `subscriptionCount`, `allSubscriptions() -> [PodcastSummary]`, `saveSubscription(from: PodcastSearchResult, feed: PodcastFeed)`, `subscription(forFeedURL:)`, `isSubscribed(feedURL:)`
  - Idempotent subscribe: same `feedURL` twice → `subscriptionCount` unchanged
- **Launch-argument fixture mode** — `-UITestFixtureDiscover`: routes `RootView` to Discover with stubbed iTunes + RSS (`URLProtocol`); no live network
- **Fixtures** (hand-authored; provenance in `PodWash/PodWashTests/Fixtures/itunes/README.md`):
  - `itunes_popular_response.json` — **exactly 3** podcast results with distinct `collectionName` + `feedUrl` values (never captured from live API at test time)
  - `itunes_search_response.json` — **exactly 2** results for pinned search term `"fixture-query"`
  - RSS stub for subscribe path reuses `Feeds/sample_feed.xml` (5 episodes) served by `URLProtocol` at URLs referenced in the iTunes fixtures
- `ITunesSearchClientTests`, `DiscoverViewModelTests`, `PodcastStoreMultiSubscriptionTests`, `DiscoverUITests`
- Architect decision: `docs/adr/014-discovery-itunes-multi-sub.md` — iTunes client API, popular-query URL, Core Data schema delta, subscribe idempotency

## Fixture strategy (pinned)

| Asset | Role |
|-------|------|
| `URLProtocol` stub | All iTunes + RSS HTTP in unit/UI tests |
| `itunes_popular_response.json` | Popular list AC — 3 rows, golden titles |
| `itunes_search_response.json` | Search AC — term `"fixture-query"`, 2 rows |
| `sample_feed.xml` | Subscribe AC — persisted episode count **== 5** |
| In-memory Core Data container | Per-test isolation; reload = new `PersistenceController` on same store (ADR-007/009 pattern) |

## Depends on

- Slice 06 — `RSSParser`, `PodcastFeed` / `Episode`, episode list models
- Slice 11 — `PodcastStore`, `PersistenceController`, Core Data entities (extended here for multi-sub)

**Parallelizable:** No — Slice 23 (library + player shell) depends on this slice. After Slice 22 is **Done**, parallel with Slices 18–21 and other tracks that do not edit `PodcastStore` / Discover files (serialize on shared files).

## Out-of-scope

- Library list UI and production root navigation (Slice 23)
- Tap-to-play / `PlaybackControlsView` in production shell (Slice 23)
- Recommendations ML, personalized charts, or "For You" feeds
- PodcastIndex or any API requiring a signed key / proxy (PRD §9)
- User accounts, sync, or cloud subscription backup
- CarPlay templates (Slice 15)
- StoreKit / paywall gating of subscribe (Slice 17)
- Live iTunes or RSS network calls in automated tests
- Background feed polling / new-episode notifications (PRD §9)
- Manual URL paste / "add feed by URL" screen (defer unless user requests — Discover search is the MVP add path)
- Subjective discover ranking quality or visual polish (Slice 21 may restyle later)

## Open product questions

None — popular list and subscribe loading UX resolved 2026-07-10 (see § Product decisions).

## Acceptance criteria

Automatable only. **XCTSkip is not allowed on core ACs** — a mapped test that cannot run must fail.

- [ ] 1. Unit test (`ITunesSearchClient`, `URLProtocol` stub serving `itunes_popular_response.json`): `fetchPopular()` returns **exactly 3** results; `results[0].title`, `results[1].title`, `results[2].title` equal the golden JSON `collectionName` strings **exactly**; each `feedURL.absoluteString` equals the golden `feedUrl` **exactly**.
- [ ] 2. Unit test (`ITunesSearchClient`, stub serving `itunes_search_response.json`): `search(term: "fixture-query")` returns **exactly 2** results with golden titles and `feedURL`s **exactly**; `search(term: "")` returns **0** results (no network call required for empty term — client short-circuits).
- [ ] 3. Unit test (`PodcastStore`, in-memory container): seed subscription A from golden popular result 0 + `sample_feed.xml` (5 episodes), then subscription B from golden popular result 1 + a second stub feed with **exactly 1** episode → `subscriptionCount == 2`; after **new** `PersistenceController` reload on the same store, `subscriptionCount == 2` and `allSubscriptions().map(\.title)` equals `[goldenTitle0, goldenTitle1]` **exactly** (order pinned in test).
- [ ] 4. Unit test (`PodcastStore` idempotency): subscribe same `feedURL` twice → `subscriptionCount == 1`; episode rows for that subscription remain **== 5** (not duplicated).
- [ ] 5. Unit test (`DiscoverViewModel` subscribe flow): stub iTunes result 0 + RSS stub → `subscribe(atIndex: 0)` sets `isSubscribed(feedURL:) == true` and `subscription(forFeedURL:).episodes.count == 5`; stub network failure on RSS fetch → `subscribeState == .failed` (typed enum case, not string match).
- [ ] 6. UI test (`-UITestFixtureDiscover`): `discoverRoot` exists; `popularCell_0`, `popularCell_1`, `popularCell_2` exist; each cell's **accessibility label** equals the corresponding golden `collectionName` **exactly**.
- [ ] 7. UI test (`-UITestFixtureDiscover`): type **`fixture-query`** into `discoverSearchField`, wait for `searchResultCell_0`; label equals golden search result 0 title **exactly**; tap `subscribeButton_0` → `subscribeButton_0` `accessibilityValue == "1"` within **5 s**.
- [ ] 8. Full suite green via `scripts/verify.sh` with **exit 0, failed 0, skipped 0**.

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/ITunesSearchClientTests.swift` | `testFetchPopularMatchesGolden` | 3 results; exact title + feedURL |
| 2 | `PodWash/PodWashTests/ITunesSearchClientTests.swift` | `testSearchTermMatchesGolden` | 2 results; empty term → 0 |
| 3 | `PodWash/PodWashTests/PodcastStoreMultiSubscriptionTests.swift` | `testMultipleSubscriptionsPersistAcrossReload` | Two feeds; reload retains count + titles |
| 4 | `PodWash/PodWashTests/PodcastStoreMultiSubscriptionTests.swift` | `testDuplicateSubscribeIsIdempotent` | Same feedURL; count stays 1; 5 episodes |
| 5 | `PodWash/PodWashTests/DiscoverViewModelTests.swift` | `testSubscribePersistsFeedAndSurfacesFailure` | Success + RSS failure branches |
| 6 | `PodWash/PodWashUITests/DiscoverUITests.swift` | `testPopularListRendersGoldenTitles` | `-UITestFixtureDiscover` |
| 7 | `PodWash/PodWashUITests/DiscoverUITests.swift` | `testSearchAndSubscribeUpdatesButton` | Search + subscribe value `"1"` |
| 8 | — | — | Command-level: unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0 |

## Verification commands

```bash
# Fast inner loop (NOT sufficient for Done):
scripts/verify.sh \
  -only-testing:PodWashTests/ITunesSearchClientTests \
  -only-testing:PodWashTests/PodcastStoreMultiSubscriptionTests \
  -only-testing:PodWashTests/DiscoverViewModelTests \
  -only-testing:PodWashUITests/DiscoverUITests

# Done gate — FULL suite, zero failures, zero skips:
scripts/verify.sh
```

## Verification record (QA fills at Verify)

> Paste the `VERIFY RESULT:` line from the full-suite `scripts/verify.sh` run here.
> A slice without a recorded full-suite green artifact is not Done.

```
VERIFY RESULT: (pending)
```

## Plan review record (coordinator fills before downstream roles)

> Record readonly review outcomes before QA writes tests (ADR review) and before
> Engineer starts (test spec review). No record = next role must not spawn.
> See [`multitask-workflow.md`](../multitask-workflow.md) § Plan review gates.

```
ADR review (2026-07-10): (pending) QA cleared — pipeline worker finished PM cleared — pipeline worker finished
Test spec review (2026-07-10): Architect cleared — pipeline worker finished
```

## Done gate

- [x] Popular-list product question resolved or explicitly pinned in ADR
- [x] Every AC mapped to a test; all rows in the mapping table filled
- [ ] **Full suite green:** unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0
- [ ] Verification record pasted above (exit code + counts + `.xcresult` path)
- [ ] Auto-commit made on green: `slice-22: <short description>` (push only when the user asks)

## Role artifacts

| Role | Gate | Artifact path |
|------|------|---------------|
| PM | Required | `docs/slices/slice-22-discovery-subscribe.md` (this file) |
| Architect | Required | `docs/adr/014-discovery-itunes-multi-sub.md` (iTunes client, multi-sub schema, subscribe flow) |
| UX | Required | `docs/slices/slice-22-ux.md` (Discover states, identifiers, UI scenarios — **UX authors; PM does not**) |
| QA | Required | Test files listed in verification mapping |
| Engineer | Required | `ITunesSearchClient`, `DiscoverView`, `PodcastStore` multi-sub refactor, `FixtureDiscover` |
