# Slice 23 — Library & player shell (MVP shell — before CarPlay)

| Field | Value |
|-------|-------|
| **ID** | 23 |
| **Title** | Library & player shell |
| **Status** | Ready |
| **Crux** | Production `RootView` (no fixture args) exposes Library + Discover tabs; subscribed shows list from multi-sub `PodcastStore`; tapping a show opens `PodcastDetailView`, tapping an episode starts playback and surfaces a **mini-player** bar — wired through `PlaybackCoordinator` / `QueueCoordinator`, assertable via `-UITestFixtureLibrary` and store seeding. |

> **Placement:** MVP app shell insert **before CarPlay (Slice 15)** — historically scoped as **"14b"**. Requires Slice 22 (multi-subscribe + Discover).

## Product decisions (user, 2026-07-10)

| Decision | Choice |
|----------|--------|
| Library + Discover layout | **`TabView` tab bar** — `tabLibrary` + `tabDiscover`; Settings via `settingsButton` on both tabs |
| Player chrome | **Mini-player bar** — `miniPlayer` + `miniPlayerPlayPause` after episode play; tap `miniPlayer` expands to full `PlaybackControlsView` (sheet or push — UX spec) |

## PRD / spec references

- PRD §2 — Library of subscriptions; episode list per show; streaming playback controls (table stakes)
- PRD §6 — Native player (`AVPlayer`) and standard controls
- `docs/adr/000-foundations.md` §1 — `PlaybackEngine` architecture
- `docs/adr/006-playback-integration.md` — `PlaybackCoordinator` wiring
- `docs/adr/009-queue-resume.md` — `QueueCoordinator`, queue store
- Slice 03 — `PlaybackControlsView`, `playback.playPause`, fixture audio pattern
- Slice 06 — `PodcastDetailView`, `EpisodeListView`, episode cell identifiers
- Slice 08 — `PlaybackCoordinator`
- Slice 11 — `QueueCoordinator`, durable stores
- Slice 13 — `SettingsView`, `settingsButton` entry

## Goal

Replace the placeholder `ContentView` with a production navigation shell so a cold launch shows Library (and Discover entry), subscribed podcasts, episode detail, and working playback chrome — without UITest-only fixture routing.

## Deliverables

- **Production shell navigation** — `RootView` / `ContentView` refactor (exact pattern in ADR):
  - **`TabView`** with **Library** tab (`tabLibrary`) and **Discover** tab (`tabDiscover`)
  - Library tab: list of subscriptions from `PodcastStore.allSubscriptions()`
  - Discover tab: Slice 22 `DiscoverView`
  - **Settings** entry preserved (`settingsButton` on both tabs — Slice 13)
  - Empty library state when `subscriptionCount == 0` (copy + navigation to Discover tab)
- **`LibraryView` + `LibraryViewModel`** — reads multi-sub store; stable identifiers:
  - `libraryRoot`, `libraryList`, `libraryEmptyState`
  - `libraryCell_<index>` (0-based; label contains subscription title)
  - `tabLibrary`, `tabDiscover` (tab bar contract — user decision 2026-07-10)
- **Navigation wiring:**
  - Tap `libraryCell_<index>` → `PodcastDetailView` with existing `EpisodeListViewModel` / cleaning / download / queue integrations (Slices 06/09/10/11)
  - Tap `episodeCell_<index>` → start playback via `PlaybackCoordinator` + `QueueCoordinator`; show player chrome
- **Player chrome in production path** (user decision 2026-07-10):
  - After episode play: compact **mini-player** bar pinned above tab bar (`miniPlayer`)
  - `miniPlayerPlayPause` — play/pause on the bar (Slice 03 `accessibilityValue` contract: `"playing"` / `"paused"`)
  - Tap `miniPlayer` (bar chrome, not the play button) → expand to full `PlaybackControlsView` (`playback.playPause` and existing Slice 03/12 controls)
  - Mini-player remains visible while browsing Library/episode list; dismiss only on stop or UX-specified close (if any)
- **App composition root** — wire `PlaybackEngine`, `PlaybackCoordinator`, `QueueCoordinator`, `RemoteCommandCoordinator` for non-fixture launches (mirror fixture wiring from `RootView` today)
- **Launch-argument fixture mode** — `-UITestFixtureLibrary`: seeds **exactly 2** subscriptions (golden titles from Slice 22 fixtures) with `sample_feed.xml` episodes into in-memory Core Data at launch; lands on Library tab; uses bundled audio fixture for play assertion (no live network)
- `LibraryViewModelTests`, `LibraryNavigationTests` (unit/integration), `LibraryUITests`
- Architect decision: `docs/adr/015-app-shell-navigation.md` — tab vs stack, coordinator ownership, fixture seeding (014 was Discovery)

## Fixture strategy (pinned)

| Asset | Role |
|-------|------|
| `-UITestFixtureLibrary` | Seeds 2 subscriptions; opens Library |
| Golden titles | Reuse `itunes_popular_response.json` entries 0 and 1 `collectionName` strings |
| `sample_feed.xml` | 5 episodes per seeded show; play test uses `episodeCell_0` |
| `-UITestFixtureAudio` clip | Bundled local audio for play/pause assert (Slice 03 path) |
| In-memory Core Data | Per UI test launch; `FixtureLibrary.prepareSeededStore()` |

## Depends on

- Slice 22 — Multi-subscription `PodcastStore`, `DiscoverView`
- Slice 03 — `PlaybackEngine`, `PlaybackControlsView`, bundled audio fixture
- Slice 06 — `PodcastDetailView`, episode list identifiers (`episodeList`, `episodeCell_<index>`)
- Slice 08 — `PlaybackCoordinator`
- Slice 11 — `QueueCoordinator`, `QueueStore`, `PersistenceController`
- Slice 13 — Settings reachable from shell (`settingsButton`)

**Implicit (kanban, not parsed as deps):** Slices 09/10 UI on `PodcastDetailView` should continue to work when reached from Library; this slice must not regress their identifiers.

**Parallelizable:** No — requires Slice 22 **Done**. After Slice 23 is **Done**, CarPlay (15) may start; parallel with 18–21 on non-shell files.

## Out-of-scope

- CarPlay templates and scene delegate (Slice 15)
- Visual identity / brand tokens (Slice 21 — may restyle shell later)
- Skipper-style analysis timeline (Slice 20)
- Redesign of cleaning toggles, download UI, or queue UI beyond wiring existing views
- Lock screen / Control Center behavior changes (Slice 14 — should not regress)
- Segmentation / unrelated-content UI (Slices 18–19)
- Paywall blocking library or playback (Slice 17)
- Deep linking, universal links, or handoff
- Subjective "feels like a podcast app" manual review
- Offline-only discover (Discover may still use network in production; tests stay stubbed)

## Open product questions

None — tab bar and mini-player resolved 2026-07-10 (see § Product decisions).

## Acceptance criteria

Automatable only. **XCTSkip is not allowed on core ACs** — a mapped test that cannot run must fail.

- [ ] 1. Unit test (`LibraryViewModel`, in-memory store seeded with 2 subscriptions): `subscriptionCount == 2`; `titles == [goldenTitle0, goldenTitle1]` **exactly** (same order as Slice 22 golden); after container reload, unchanged.
- [ ] 2. UI test (production routing, **no** `-UITestFixtureFeed` / `-UITestFixtureAudio` / `-UITestFixtureDiscover`): launch with **only** `-UITestFixtureLibrary` → `libraryRoot` exists; `libraryCell_0` and `libraryCell_1` exist; labels contain golden titles 0 and 1 respectively (substring match, case-sensitive).
- [ ] 3. UI test (`-UITestFixtureLibrary`): tap `libraryCell_0` → `episodeList` exists within **5 s**; `episodeCell_0`, `episodeCell_1`, `episodeCell_2` exist (first 3 episodes from `sample_feed.xml`).
- [ ] 4. UI test (`-UITestFixtureLibrary`): from episode list, tap `episodeCell_0` → `miniPlayer` exists within **5 s**; tap `miniPlayerPlayPause` → `accessibilityValue == "playing"` within **5 s** (Slice 03 play-state contract).
- [ ] 4b. UI test (`-UITestFixtureLibrary`): with mini-player visible, tap `miniPlayer` (bar, not play button) → `playback.playPause` exists within **5 s** (expanded full player).
- [ ] 5. UI test (`-UITestFixtureLibrary`): `settingsButton` exists and `isHittable == true` from Library (Settings entry not regressed).
- [ ] 6. UI test (`-UITestFixtureLibrary`): tap `tabDiscover` → `discoverRoot` exists within **5 s**.
- [ ] 7. UI test (empty library fixture `-UITestFixtureLibraryEmpty` or launch flag that skips seed): `libraryEmptyState` exists; label contains **`Discover`** (exact substring); tap affordance navigates to `discoverRoot` within **5 s**.
- [ ] 8. Full suite green via `scripts/verify.sh` with **exit 0, failed 0, skipped 0**.

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/LibraryViewModelTests.swift` | `testLibraryListsAllSubscriptionsAfterReload` | 2 seeded subs; exact title order |
| 2 | `PodWash/PodWashUITests/LibraryUITests.swift` | `testLibraryRendersSeededSubscriptions` | `-UITestFixtureLibrary` only |
| 3 | `PodWash/PodWashUITests/LibraryUITests.swift` | `testTapShowOpensEpisodeList` | Detail navigation |
| 4 | `PodWash/PodWashUITests/LibraryUITests.swift` | `testTapEpisodeShowsMiniPlayerAndPlays` | `miniPlayer` + `miniPlayerPlayPause` → `"playing"` |
| 4b | `PodWash/PodWashUITests/LibraryUITests.swift` | `testMiniPlayerExpandsToFullControls` | Tap `miniPlayer` → `playback.playPause` |
| 5 | `PodWash/PodWashUITests/LibraryUITests.swift` | `testSettingsReachableFromLibrary` | `settingsButton` hittable |
| 6 | `PodWash/PodWashUITests/LibraryUITests.swift` | `testDiscoverEntryFromLibrary` | Discover navigation |
| 7 | `PodWash/PodWashUITests/LibraryUITests.swift` | `testEmptyLibraryShowsDiscoverPrompt` | Empty seed flag; `libraryEmptyState` |
| 8 | — | — | Command-level: unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0 |

## Verification commands

```bash
# Fast inner loop (NOT sufficient for Done):
scripts/verify.sh \
  -only-testing:PodWashTests/LibraryViewModelTests \
  -only-testing:PodWashUITests/LibraryUITests

# Done gate — FULL suite, zero failures, zero skips:
scripts/verify.sh
```

## Verification record (QA fills at Verify)

> Paste the `VERIFY RESULT:` line from the full-suite `scripts/verify.sh` run here.
> A slice without a recorded full-suite green artifact is not Done.

```
VERIFY RESULT: exit=0 total=93 passed=93 failed=0 skipped=0 filtered=0 bundle=build/test-results/verify-20260711-010638.xcresult tier=3 class=tests
```

## Plan review record (coordinator fills before downstream roles)

> Record readonly review outcomes before QA writes tests (ADR review) and before
> Engineer starts (test spec review). No record = next role must not spawn.
> See [`multitask-workflow.md`](../multitask-workflow.md) § Plan review gates.

```
ADR review (2026-07-11): (pending) QA cleared — pipeline worker finished PM cleared — pipeline worker finished
Test spec review (2026-07-11): Architect cleared — pipeline worker finished
```

## Done gate

- [ ] Every AC mapped to a test; all rows in the mapping table filled
- [ ] **Full suite green:** unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0
- [ ] Verification record pasted above (exit code + counts + `.xcresult` path)
- [ ] Auto-commit made on green: `slice-23: <short description>` (push only when the user asks)

## Role artifacts

| Role | Gate | Artifact path |
|------|------|---------------|
| PM | Required | `docs/slices/slice-23-library-player-shell.md` (this file) |
| Architect | Required | `docs/adr/015-app-shell-navigation.md` (navigation graph, coordinator wiring) |
| UX | Required | `docs/slices/slice-23-ux.md` (Library/Discover/Player chrome, identifiers, scenarios — **UX authors; PM does not**) |
| QA | Required | `LibraryViewModelTests.swift`, `LibraryUITests.swift` |
| Engineer | Required | `LibraryView`, `RootView`/`ContentView` production shell, `FixtureLibrary`, coordinator wiring |
