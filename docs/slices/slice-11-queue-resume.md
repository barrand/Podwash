# Slice 11 — Queue + resume (durable persistence)

| Field | Value |
|-------|-------|
| **ID** | 11 |
| **Title** | Queue + resume |
| **Status** | Done |
| **Crux** | After a Core Data container reload (simulating app relaunch), up-next queue order and per-episode playback position + played state match the last saved values — provable with fixture episode IDs `fixture-ep-001`…`005` and in-memory store configuration per ADR-007. |

## Persistence decision (resolved 2026-07-09)

**Core Data** — user decision recorded in [ADR-007](../adr/007-persistence-core-data.md).
Halt-and-ask gate cleared; Slice 11 may proceed through Architect test-spec gates.

## PRD / spec references

- PRD §2 — Queue/up-next; resume position; mark played/unplayed
- PRD §9 — On-device storage only (no sync)
- PRD §11 — Local persistence ✅ resolved (Core Data, ADR-007)
- `docs/adr/007-persistence-core-data.md` — schema, in-memory test container, migration from Slice 06/09/10 in-memory stubs
- `docs/adr/004-rss-parser.md` — fixture feed episode IDs (`fixture-ep-001`…`005` from `sample_feed.xml`)

## Goal

Commit PodWash to durable on-device Core Data storage so queue order, playback positions, and played/unplayed state survive process relaunch, migrating the Slice 06/09/10 in-memory store stubs.

## Deliverables

- `PodWash.xcdatamodeld` — versioned Core Data schema (subscriptions/episodes, queue order, positions, played flags, cleaning toggles, download state)
- `PersistenceController.swift` (or equivalent) — `NSPersistentContainer` factory; production on-disk store vs test `isStoredInMemoryOnly = true` (ADR-007 §3)
- Core Data–backed replacements:
  - `PodcastStore` — migrates `InMemoryPodcastStore` (Slice 06)
  - `CleaningToggleStore` — migrates `InMemoryCleaningToggleStore` (Slice 09)
  - `DownloadStateStore` — migrates `InMemoryDownloadStateStore` (Slice 10 deferred durable state)
  - `QueueStore` + resume helpers — up-next order, position save/restore, played threshold
- `QueueCoordinator` (or equivalent) — wires queue + `PlaybackEngine`; auto-advance on episode end; injectable player spy for tests
- Remove unused SwiftData template scaffold (`Item.swift`, `ModelContainer` in `PodWashApp.swift`) per ADR-007
- **Accessibility identifiers** (UX-light; full contract in `docs/slices/slice-11-queue-resume-ux.md` when UX gate runs):
  - `queueAddButton_<index>` — add episode at row index to up-next
  - `queueCell_<index>` — 0-based up-next list row
  - `queueRemoveButton_<index>` — remove from up-next
- `QueueTests`, `ResumePositionTests`, `PersistenceMigrationTests` — all use dedicated in-memory container instances; **no test reads disk state left by another test** (ADR-007 §3)
- Architect decision: `docs/adr/007-persistence-core-data.md` (stack) + `docs/adr/009-queue-resume.md` (modules/APIs)

## Depends on

- Slice 03 — `PlaybackEngine`, play/pause/seek hooks for position save + auto-advance spy
- Slice 06 — `Episode` model, fixture feed IDs, `InMemoryPodcastStore` stub to replace

**Parallelizable:** Yes — parallel with Slices 10, 12 (parallel group B after Slice 08). Store migrations also replace Slice 09/10 in-memory stubs when those slices are already Done; no new cleaning or download behavior.

**Implicit (kanban, not parsed as deps):** Slice 08 playback-end wiring informs `QueueCoordinator` auto-advance; do not change interval/cleaning behavior in this slice.

## Out-of-scope

- Cross-device sync or CloudKit (PRD §9: none, by design)
- Auto-download, auto-delete-after-played, and settings UI (Slice 13)
- Variable speed and sleep timer (Slice 12)
- `IntervalCache` migration from JSON files to Core Data (optional in ADR-007; defer unless zero-cost — JSON contract unchanged)
- Queue UI reorder drag-and-drop polish beyond stable identifiers (gesture timing not gated here)
- Lock screen / Control Center queue surfacing (Slice 14)
- CarPlay queue templates (Slice 15)
- Live network, real AVPlayer timing, or device-only relaunch tests (in-memory container reload + spies only)
- Changing download, analysis, or RSS parse behavior (this slice swaps store backends only)
- Subjective “feels like relaunch” manual checks

## Acceptance criteria

Automatable only. **XCTSkip is not allowed on core ACs** — a mapped test that cannot run must fail.

- [ ] 1. Unit test (`QueueStore`, in-memory container): starting from empty queue — `add("fixture-ep-001")`, `add("fixture-ep-002")`, `add("fixture-ep-003")` → `queueEpisodeIDs() == ["fixture-ep-001", "fixture-ep-002", "fixture-ep-003"]`; `remove("fixture-ep-002")` → `["fixture-ep-001", "fixture-ep-003"]`; `move("fixture-ep-003", toIndex: 0)` → `["fixture-ep-003", "fixture-ep-001"]`; after **new** `PersistenceController` instance reload from the same underlying store (ADR-007 reload pattern), `queueEpisodeIDs()` unchanged and `count == 2`.
- [ ] 2. Unit test (`QueueCoordinator`, player spy): with `currentEpisodeID == "fixture-ep-001"` and `queueEpisodeIDs() == ["fixture-ep-002", "fixture-ep-003"]`, simulate playback ended for `"fixture-ep-001"`; within **1.0 s** the spy records exactly **1** `play(episodeID:)` call with argument `"fixture-ep-002"`; after handling, `queueEpisodeIDs() == ["fixture-ep-003"]`.
- [ ] 3. Unit test (resume helper): for `"fixture-ep-001"` with stub duration **600.0 s**, save position **127.5 s** on `pause()`; after container reload, next `play(episodeID: "fixture-ep-001")` seeks to **127.5 ± 1.0 s** (assert `abs(restored - 127.5) <= 1.0`).
- [ ] 4. Unit test (played threshold): for `"fixture-ep-004"` with stub duration **100.0 s** — progress **94.9 s** → `isPlayed == false`; progress **95.0 s** → `isPlayed == true`; after container reload, `isPlayed` remains **true** for `"fixture-ep-004"`.
- [ ] 5. Unit test (`PersistenceMigrationTests`): seed from parsed `sample_feed.xml` (5 episodes) plus `setChannelCleaning(true)`, `setEpisodeCleaning("fixture-ep-001", true)`, download state `.downloaded` for `"fixture-ep-001"`; after container reload — `episodes.count == 5`, `episodes[0].id == "fixture-ep-001"`, `isChannelCleaningEnabled == true`, `isEpisodeCleaningEnabled("fixture-ep-001") == true`, `downloadState(for: "fixture-ep-001") == .downloaded`.
- [ ] 6. Full suite green via `scripts/verify.sh` with **exit 0, failed 0, skipped 0**.

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/QueueTests.swift` | `testQueueOperationsPersistAcrossReload` | Fixture IDs from `sample_feed.xml`; reload = new container on same in-memory store |
| 2 | `PodWash/PodWashTests/QueueTests.swift` | `testAutoAdvanceOnEpisodeEnd` | Injectable `PlaybackEngine` spy; end event via coordinator API or notification |
| 3 | `PodWash/PodWashTests/ResumePositionTests.swift` | `testPositionSaveRestoreWithinTolerance` | Duration stub 600.0 s; save 127.5 s; ±1.0 s tolerance |
| 4 | `PodWash/PodWashTests/ResumePositionTests.swift` | `testPlayedThresholdAndPersistence` | 94.9 s → false; 95.0 s → true; survives reload |
| 5 | `PodWash/PodWashTests/PersistenceMigrationTests.swift` | `testInMemoryStubMigrationSurvivesReload` | Podcast + cleaning + download state smoke after Core Data swap |
| 6 | — | — | Command-level: unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0 |

## Verification commands

```bash
# Fast inner loop (NOT sufficient for Done):
scripts/verify.sh -only-testing:PodWashTests/QueueTests -only-testing:PodWashTests/ResumePositionTests -only-testing:PodWashTests/PersistenceMigrationTests

# Done gate — FULL suite, zero failures, zero skips:
scripts/verify.sh
```

## Verification record (QA fills at Verify)

> Paste the `VERIFY RESULT:` line from the full-suite `scripts/verify.sh` run here.
> A slice without a recorded full-suite green artifact is not Done.

```
VERIFY RESULT: exit=0 total=50 passed=50 failed=0 skipped=0 filtered=0 bundle=build/test-results/verify-20260710-124027.xcresult tier=3
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

- [x] Persistence decision recorded (ADR-007 — Core Data; ADR-009 — queue/resume APIs)
- [ ] Every AC mapped to a test; all rows in the mapping table filled
- [ ] **Full suite green:** unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0
- [ ] Verification record pasted above (exit code + counts + `.xcresult` path)
- [ ] Auto-commit on green: `slice-11: <short description>` (push only when the user asks)

## Role artifacts

| Role | Gate | Artifact path |
|------|------|---------------|
| PM | Required | `docs/slices/slice-11-queue-resume.md` (this file) |
| Architect | Required | `docs/adr/007-persistence-core-data.md` (stack) + `docs/adr/009-queue-resume.md` (modules/APIs) |
| UX | Light | `docs/slices/slice-11-queue-resume-ux.md` — queue add/remove/reorder identifiers |
| QA | Required | `QueueTests.swift`, `ResumePositionTests.swift`, `PersistenceMigrationTests.swift` |
| Engineer | Required | `PodWash.xcdatamodeld`, `PersistenceController.swift`, store replacements, `QueueCoordinator` |
