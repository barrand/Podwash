# Slice 15 — CarPlay

| Field | Value |
|-------|-------|
| **ID** | 15 |
| **Title** | CarPlay |
| **Status** | Ready |
| **Crux** | CarPlay audio-app templates (library subscriptions, per-show episode list, up-next queue, now-playing) are built from injectable store/coordinator data sources; list contents, selection → playback, and play/pause state are asserted on template doubles — physical head-unit checks are documentation only, never gates. |

## PRD / spec references

- PRD §2 — Native media controls including CarPlay; library of subscriptions; queue/up-next
- PRD §7 — CarPlay framework alongside `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter` (Slice 14)
- PRD §11 — ✅ **Resolved 2026-07-10** (see § Product decisions below)
- `docs/adr/000-foundations.md` §1 — injected doubles for system frameworks
- `docs/adr/009-queue-resume.md` — `QueueStore`, `QueueCoordinator`, fixture episode IDs
- `docs/adr/011-remote-commands-background-audio.md` — Now Playing + transport; CarPlay reuses same stack
- `docs/adr/015-app-shell-navigation.md` — multi-sub `PodcastStore`, Library fixture seeding, namespaced episode IDs

## Product decisions (user, 2026-07-10 — unblocks this slice)

| Decision | Choice |
|----------|--------|
| CarPlay timing | **MVP** — ship CarPlay browsing/playback templates with the initial release; physical head-unit checks remain documentation-only (not a Done gate) |

## Goal

Expose CarPlay library, episode, queue, and now-playing templates so a driver can browse subscribed shows, pick an episode or queued item, and control playback through standard CarPlay audio-app UI — matching PRD §2 native-controls requirements without simulator head-unit dependency in automated tests.

## Deliverables

- **`CarPlayCoordinator`** (or scene delegate + builder split per ADR) — wires `PodcastStore`, `QueueStore`, `PlaybackCoordinator` into CarPlay template hierarchy; production `CPTemplateApplicationSceneDelegate` adapter
- **`CarPlayTemplateBuilding`** protocol — pure data-source surface for list/now-playing mapping (testable without `CPTemplateApplicationScene`)
- **Injectable doubles** — `CPListTemplateRecorder`, `CPNowPlayingTemplateDouble`, `PlaybackTransportSpy` (reuse or extend Slice 14 spy); programmatic list-item selection + playback-state callbacks
- **Template mapping** (minimum):
  - **Library root** — one `CPListItem` per subscription (`PodcastStore.allSubscriptions()`)
  - **Show drill-down** — one `CPListItem` per episode for the selected subscription
  - **Queue** — one `CPListItem` per `queueEpisodeIDs()` entry (Slice 11 order)
  - **Now playing** — title + play/pause state synced from `PlaybackEngine`
- **`PodWash/Info.plist`** — `CPTemplateApplicationScene` scene manifest entry (structural AC)
- **Entitlement request documentation** — `com.apple.developer.carplay-audio` steps in slice ADR or README note; Apple approval is external, **not** a Done gate
- `PodWash/PodWashTests/CarPlayTemplateTests.swift`
- Architect decision: `docs/adr/016-carplay-templates.md` — module boundaries, template hierarchy, double contract, **CarPlay framework spike** (doubles must be validated against real `CPListItem` / `CPNowPlayingTemplate` APIs before QA test spec)

## Fixture strategy (pinned)

| Asset | Role |
|-------|------|
| Golden subscription titles | `"Fixture Popular Alpha"`, `"Fixture Popular Beta"` — `itunes_popular_response.json` entries 0–1 (`collectionName`) |
| Golden episode titles (queue / show list) | From `sample_feed.xml` items 0–2: `"Alpha Signal — Pilot Launch"`, `"Beta Notes — Listener Mail"`, `"Gamma Graph — Data Deep Dive"` |
| Queue episode IDs | `"fixture-ep-001"`, `"fixture-ep-002"`, `"fixture-ep-003"` (Slice 11 contract) |
| Show drill-down episode count | **5** episodes per seeded subscription (`sample_feed.xml`) |
| Library namespaced IDs | Per ADR-015: `lib-0-fixture-ep-001` … `lib-1-fixture-ep-005` when seeded via `FixtureLibrary` pattern |
| Playback clip | `PodWash/PodWashTests/Fixtures/audio/test-clip.m4a` — **30.0 s** (Slice 14 provenance) for now-playing duration asserts if needed |
| In-memory Core Data | Per-test `PersistenceController(isStoredInMemoryOnly: true)`; no cross-test disk leakage |

## Depends on

- Slice 03 — `PlaybackEngine`, play/pause transport
- Slice 08 — `PlaybackCoordinator`
- Slice 11 — `QueueStore`, `QueueCoordinator`, fixture episode IDs, durable queue order
- Slice 14 — Now Playing + remote command stack CarPlay reuses (do not regress)
- Slice 22 — multi-subscription `PodcastStore`, golden iTunes fixture titles
- Slice 23 — production shell / `FixtureLibrary` seeding pattern for library subscriptions

**Parallelizable:** Yes — with Slices 16, 17 (after 22–23 are **Done**).

## Out-of-scope

- Physical head-unit or Xcode CarPlay simulator window verification as a Done gate (manual spot-check doc only)
- CarPlay-specific settings screen or cleaning-toggle surfacing
- Queue reorder drag-and-drop on CarPlay (read-only queue list + tap-to-play only)
- Lock screen / `MPRemoteCommandCenter` behavior changes (Slice 14 — must not regress)
- Variable speed, sleep timer, segmentation banner, or analysis UI on CarPlay (in-app only)
- Artwork pixel-perfect rendering asserts (placeholder/non-nil count only; no image hash gates)
- Live network, live AVPlayer timing, or device-only CarPlay entitlement approval blocking CI
- StoreKit / paywall gating of CarPlay (Slice 17 deferred)
- Subjective “feels native on head unit” review

## Open product questions

None — CarPlay timing resolved 2026-07-10 (see § Product decisions).

## Acceptance criteria

Automatable only. **XCTSkip is not allowed on core ACs** — a mapped test that cannot run must fail.

- [ ] 1. Unit test (`CarPlayLibraryDataSource`, in-memory store seeded with **2** subscriptions — golden titles `"Fixture Popular Alpha"` then `"Fixture Popular Beta"`): `listItems().count == 2`; `items[0].text` and `items[1].text` equal those strings **exactly**; `items.filter { $0.image != nil }.count == 2`.
- [ ] 2. Unit test (`CarPlayShowDataSource`, subscription index **0** from the same seed): `listItems().count == 5`; `items[0].text == "Alpha Signal — Pilot Launch"` **exactly**; `items[1].text == "Beta Notes — Listener Mail"` **exactly**.
- [ ] 3. Unit test (`CarPlayQueueDataSource`, `QueueStore` with `add("fixture-ep-001")`, `add("fixture-ep-002")`, `add("fixture-ep-003")`): `listItems().count == 3`; titles `== ["Alpha Signal — Pilot Launch", "Beta Notes — Listener Mail", "Gamma Graph — Data Deep Dive"]` **exactly** (order matches queue); `items.filter { $0.image != nil }.count == 3`.
- [ ] 4. Unit test (`CarPlayCoordinator`, injected list double + `PlaybackTransportSpy`): programmatically invoke selection handler on queue list item at **index 1** → spy records exactly **1** `play(episodeID:)` call with argument `"fixture-ep-002"`.
- [ ] 5. Unit test (`CarPlayNowPlayingUpdater`, injected `CPNowPlayingTemplateDouble` + `PlaybackEngine` + `test-clip.m4a`): after `play()` then `pause()`, double records exactly **2** playback-state updates with values `[.playing, .paused]` in order; after the first `play()` only, `lastTitle == "Alpha Signal — Pilot Launch"` **exactly**.
- [ ] 6. Unit test (bundle structural): read the test-host app `Info.plist`; `UIApplicationSceneManifest` contains exactly **1** scene configuration whose `UISceneClassName` is **`CPTemplateApplicationScene`**.
- [ ] 7. Full suite green via `scripts/verify.sh` with **exit 0, failed 0, skipped 0**.

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/CarPlayTemplateTests.swift` | `testLibraryListItemsFromSubscriptions` | 2 subs; exact golden titles; artwork non-nil on 2 |
| 2 | `PodWash/PodWashTests/CarPlayTemplateTests.swift` | `testShowListItemsForSubscription` | Sub index 0; 5 episodes; first 2 titles pinned |
| 3 | `PodWash/PodWashTests/CarPlayTemplateTests.swift` | `testQueueListItemsFromStore` | 3 queue IDs; 3 titles; artwork non-nil on 3 |
| 4 | `PodWash/PodWashTests/CarPlayTemplateTests.swift` | `testQueueSelectionStartsPlayback` | Index 1 → exactly 1 play for `fixture-ep-002` |
| 5 | `PodWash/PodWashTests/CarPlayTemplateTests.swift` | `testNowPlayingStatePropagation` | 2 state updates; play then pause; pinned title |
| 6 | `PodWash/PodWashTests/CarPlayTemplateTests.swift` | `testCarPlaySceneDeclaredInPlist` | Exactly 1 `CPTemplateApplicationScene` entry |
| 7 | — | — | Command-level: unfiltered `scripts/verify.sh` |

## Verification commands

```bash
# Fast inner loop (NOT sufficient for Done):
scripts/verify.sh -only-testing:PodWashTests/CarPlayTemplateTests

# Done gate — FULL suite, zero failures, zero skips:
scripts/verify.sh
```

## Verification record (QA fills at Verify)

```
VERIFY RESULT: exit=0 total=99 passed=99 failed=0 skipped=0 filtered=0 bundle=build/test-results/verify-20260711-092412.xcresult tier=3 class=tests
```

## Plan review record (coordinator fills before downstream roles)

```
ADR review (2026-07-11): (pending) QA cleared — pipeline worker finished PM cleared — pipeline worker finished
Test spec review (2026-07-11): Architect cleared — pipeline worker finished
```

## Done gate

- [ ] Every AC mapped to a test; all rows in the mapping table filled
- [ ] **Full suite green:** unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0
- [ ] Verification record pasted above (exit code + counts + `.xcresult` path)
- [ ] Auto-commit made on green: `slice-15: <short description>` (push only when the user asks)

## Design notes (Architect)

See [`docs/adr/016-carplay-templates.md`](../adr/016-carplay-templates.md): tab root
(Library + Queue), show push, `CarPlayListItemModel` + data sources, selection via
`EpisodePlaying` (not `PlaybackTransporting`), now-playing presenting seam (template
has no title/state API), Info.plist scene, entitlement doc-only. Spike: `image` is
get-only — use init/`setImage`; `CPNowPlayingTemplate.shared` only.

## Role artifacts

| Role | Gate | Artifact path |
|------|------|---------------|
| Architect | Required | `docs/adr/016-carplay-templates.md` — hierarchy, doubles, CarPlay API spike |
| UX | Light | [`docs/slices/slice-15-ux.md`](slice-15-ux.md) — template hierarchy, test-seam identifiers, unit scenarios |
