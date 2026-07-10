# Slice 11 — UX spec: Queue + resume (up-next chrome)

| Field | Value |
|-------|-------|
| **Slice** | 11 — Queue + resume (durable persistence) |
| **Screen** | `PodcastDetailView` (fixture mode; extends Slice 06/09/10 layout) |
| **ADR** | [ADR-009](../adr/009-queue-resume.md) §6 (minimum identifiers); unit ACs cover persistence/reload |

## Layout

Extends Slice 06/09/10 (`slice-06-ux.md`, `slice-09-ux.md`, `slice-10-downloads-ux.md`):

1. **Podcast header** — unchanged.
2. **Up Next section** — new block between header and episode list:
   - Section title: **Up Next** (visible; not a separate AX element — the list carries identifiers)
   - **Queue list** — vertical list of queued episodes, top to bottom = play order (ascending `sortIndex`)
   - Each queue row: episode title (primary line) + **Remove** button trailing
   - **Empty copy** — "Nothing queued" when the queue has zero episodes
3. **Episode list** — each row adds a **queue add** control in the trailing accessory stack:
   - Accessory layout (leading → trailing): `[ queueAddButton_<index> | downloadButton_<index> | episodeCleaningToggle_<index> ]`

**Reorder:** `QueueStore.move` is unit-tested (AC#1). No drag-and-drop or move-up/move-down controls in this slice (out-of-scope per slice file). Queue order in the UI reflects store order only.

**Resume / played:** Position restore and the 95% played threshold are persistence-layer behavior (`ResumePositionStore`, `QueueCoordinator`); no new episode-row or player chrome indicators in this slice. Existing `playback.*` identifiers (Slice 03) remain unchanged when playback is wired later.

## States

### Up Next section

| State | Visible UI | Root `accessibilityIdentifier` | `accessibilityValue` |
|-------|------------|--------------------------------|----------------------|
| **Empty** | "Nothing queued" copy; no `queueCell_*` | `queueEmpty` | — |
| **Loaded** | Queue list with 1…N rows | `queueList` | Queue count as decimal string (e.g. `0`, `1`, `3`) |

Only one of `queueEmpty` or a non-empty `queueList` is meaningful at a time. When `queueList` `accessibilityValue == "0"`, `queueEmpty` is visible. When count ≥ 1, `queueEmpty` is hidden / not in the AX tree.

### Episode row — add control

| State | `queueAddButton_<index>` `accessibilityValue` | Enabled | Notes |
|-------|-----------------------------------------------|---------|-------|
| **Not queued** | `notQueued` | Yes | Tap appends episode to up-next |
| **Queued** | `queued` | No | Episode already in up-next; button remains visible for stable queries |

Adding an episode updates `queueList` count and appends `queueCell_<queueIndex>`. Removing from up-next reverts the source episode's add button to `notQueued`.

### Queue row

| State | `queueCell_<index>` | `queueRemoveButton_<index>` |
|-------|---------------------|-----------------------------|
| **Present** | `accessibilityLabel` = episode title; `accessibilityValue` = episode ID (e.g. `fixture-ep-001`) | Enabled; tap removes that queue position and reindexes remaining cells |

After remove, indices are **dense 0…N−1** (same convention as `episodeCell_<index>`).

## Accessibility identifiers

| Control / region | `accessibilityIdentifier` | `accessibilityLabel` | `accessibilityValue` | `accessibilityHint` |
|------------------|---------------------------|----------------------|----------------------|---------------------|
| Up-next list container | `queueList` | `Up next` | Queue count as decimal string | — |
| Up-next empty state | `queueEmpty` | `Nothing queued` | — | — |
| Queue row *q* (0-based queue position) | `queueCell_<q>` | Episode title (full string) | Episode ID string (`fixture-ep-00N`) | — |
| Remove from queue (row *q*) | `queueRemoveButton_<q>` | `Remove from queue` | Episode ID of row *q* | `Removes this episode from up next.` |
| Add to queue (episode row *i*) | `queueAddButton_<i>` | `Add to queue` when `notQueued`; `In queue` when `queued` | `notQueued` / `queued` | When `notQueued`: `Adds this episode to up next.` Omit when `queued`. |

Existing Slice 06/09/10 identifiers (`episodeList`, `episodeCell_<index>`, `downloadButton_<index>`, cleaning toggles/badges, etc.) are unchanged.

**Index conventions:**

- `<i>` on episode list rows matches `episodeCell_<i>` (0 = newest fixture episode `fixture-ep-001`).
- `<q>` on queue rows is 0-based **queue position**, not episode-list index. After add/remove, `queueCell_0` is always the next-to-play item.

**Interaction contract:** UI tests tap `queueAddButton_<i>` and `queueRemoveButton_<q>` via `app.buttons[...]`. Controls are discrete `UIButton`s (not switches). State changes must update `accessibilityValue` synchronously on the main actor before XCTest post-tap idle (same pattern as `downloadButton_*` in Slice 10).

**Cell scoping:** Queue and episode controls are globally queryable by identifier (descendant queries on `XCUIApplication`).

## Fixture modes

### Feed fixture (Slice 06, required base)

Launch argument: `-UITestFixtureFeed`

Loads bundled `sample_feed.xml`. Required for all Slice 11 UI tests.

### Queue fixture (new)

Launch argument: `-UITestFixtureQueue`

When present:

- App uses Core Data–backed stores (`PodcastStore`, `QueueStore`, etc.) instead of in-memory stubs in fixture `RootView` wiring.
- On launch, **clears the up-next queue** (and only the queue — feed/toggles/downloads follow existing fixture rules) so each test starts with an empty queue unless noted below.
- Implies feed fixture behavior when combined with `-UITestFixtureFeed`.

Implementation note for Engineer: mirror `FixtureDownload` / `FixtureAnalysis` — e.g. `FixtureQueue.isEnabled` and `FixtureQueue.shouldResetOnLaunch`.

### Queue preserve fixture (new)

Launch argument: `-UITestFixtureQueuePreserve`

When present **without** a concurrent reset flag:

- Skips queue wipe on launch so on-disk Core Data queue state from a prior process survives.
- Used only in the relaunch step of `testQueuePersistsAcrossRelaunch` (see scenarios).
- Still requires `-UITestFixtureFeed` so `PodcastDetailView` loads.

**Typical argument sets:**

| Test | Launch arguments |
|------|------------------|
| Add / remove flows | `-UITestFixtureFeed`, `-UITestFixtureQueue` |
| Relaunch persistence (step 1) | `-UITestFixtureFeed`, `-UITestFixtureQueue` |
| Relaunch persistence (step 2) | `-UITestFixtureFeed`, `-UITestFixtureQueuePreserve` |

## UI test scenarios

Mapped tests live in `QueueUITests.swift`. These are **UX smoke tests** — slice AC#1–#5 are covered by unit tests (`QueueTests`, `ResumePositionTests`, `PersistenceMigrationTests`). UI scenarios prove the queue chrome contract and on-disk persistence across process death.

### `testAddToQueue`

1. **Launch** — `XCUIApplication` with `-UITestFixtureFeed` and `-UITestFixtureQueue`; wait for `episodeList` (timeout **10 s**).
2. **Initial empty** — assert `queueEmpty` exists; assert `queueList` `accessibilityValue == "0"`; assert `queueCell_0` does **not** exist.
3. **Add first episode** — tap `queueAddButton_0`; within **2 s**, assert `queueList` `accessibilityValue == "1"`; assert `queueEmpty` does **not** exist; assert `queueCell_0` `label` equals golden `episodes[0].title`; assert `queueCell_0` `value == "fixture-ep-001"`; assert `queueAddButton_0` `value == "queued"`.
4. **Add third episode** — tap `queueAddButton_2`; within **2 s**, assert `queueList` `accessibilityValue == "2"`; assert `queueCell_1` `label` equals golden `episodes[2].title`; assert `queueCell_1` `value == "fixture-ep-003"`; assert `queueAddButton_2` `value == "queued"`.

### `testRemoveFromQueue`

1. **Launch and seed** — same launch args as scenario 1; wait for `episodeList` (10 s).
2. **Add two** — tap `queueAddButton_0`, then `queueAddButton_1`; assert `queueList` `accessibilityValue == "2"` within **2 s**.
3. **Remove second in queue** — tap `queueRemoveButton_1`; within **2 s**, assert `queueList` `accessibilityValue == "1"`; assert `queueCell_0` `value == "fixture-ep-001"`; assert `queueCell_1` does **not** exist; assert `queueAddButton_1` `value == "notQueued"`.

### `testQueuePersistsAcrossRelaunch`

1. **Launch with reset** — `-UITestFixtureFeed`, `-UITestFixtureQueue`; wait for `episodeList` (10 s).
2. **Build queue** — tap `queueAddButton_0`, `queueAddButton_1`, `queueAddButton_2`; assert `queueList` `accessibilityValue == "3"` within **2 s**; record `queueCell_0` / `_1` / `_2` `label` and `value`.
3. **Terminate** — `app.terminate()`.
4. **Relaunch preserving store** — new `XCUIApplication` with `-UITestFixtureFeed`, `-UITestFixtureQueuePreserve`; launch; wait for `queueList` (10 s).
5. **Assert persisted order** — assert `queueList` `accessibilityValue == "3"`; assert `queueCell_0` / `_1` / `_2` exist with the same `label` and `value` as step 2; assert `queueAddButton_0`, `_1`, `_2` each `value == "queued"`.

## Verification mapping

| Scope | UX artifact | Test method | Notes |
|-------|-------------|-------------|-------|
| Add + queue row contract | `testAddToQueue` scenarios 1–4 | `QueueUITests.testAddToQueue` | UX smoke; not a slice AC |
| Remove + reindex | `testRemoveFromQueue` scenarios 1–3 | `QueueUITests.testRemoveFromQueue` | UX smoke; not a slice AC |
| On-disk queue across relaunch | `testQueuePersistsAcrossRelaunch` scenarios 1–5 | `QueueUITests.testQueuePersistsAcrossRelaunch` | UX smoke; complements AC#1 unit reload pattern |
| AC#1–#5 persistence/resume | — | `QueueTests`, `ResumePositionTests`, `PersistenceMigrationTests` | Unit tests per slice verification table |
