# Slice 31 — Restore now-playing session on relaunch

| Field | Value |
|-------|-------|
| **ID** | 31 |
| **Title** | Restore now-playing session on relaunch |
| **Status** | In Progress |
| **Priority** | P3 |
| **Crux** | After a simulated process relaunch with a durable active episode, saved position, and up-next queue, cold start shows `miniPlayer` for that episode **paused** at the saved timestamp (± **1.0** s) without re-tapping an episode row — and does **not** auto-play. |

## PRD / spec references

- PRD §2 — Resume/remember playback position; queue / up-next
- PRD §9 — On-device storage only (no sync)
- `docs/adr/000-foundations.md` — AX / offline verify over device listening
- `docs/adr/009-queue-resume.md` — `QueueStore`, `ResumePositionStore`, reload pattern (Slice 11 Done — **store-level only**)
- `docs/adr/015-app-shell-navigation.md` — `AppShellModel`, `isMiniPlayerVisible`, mini / full player

## Goal

Close the gap between durable queue/position stores and the shell: leaving and returning to the app keeps the mini player open on the same episode at the same spot, with the queue intact, without janky re-discovery.

## Intake decisions (locked)

| Decision | Choice |
|----------|--------|
| Cold-relaunch audio | Show `miniPlayer` **paused** at saved position — **do not** auto-play |
| What clears durable active session | **Only** when the current episode **finishes** and the up-next queue is **empty** |
| Explicit mini dismiss / `stopAndDismissPlayer` | Must **not** clear the durable active-session id (Architect: hide chrome vs keep session — session survives relaunch until finish+empty-queue) |
| Background return (no process death) | Same session already in memory; no new product behavior beyond ensuring position is flushed so a later kill still restores correctly |
| CarPlay / lock screen | Out of scope |

## Deliverables

- ADR — `docs/adr/027-restore-now-playing-session.md` (active-session schema; when set/clear; launch bootstrap; pause-not-play; position flush on resign/background)
- UX spec `docs/slices/slice-31-ux.md` — cold-start mini states, AX asserts for paused restore, relaunch fixture args
- Persist **active now-playing episode id** (and any fields ADR requires) so `AppShellModel` can rehydrate after process death
- On cold launch / shell bootstrap: if active session exists → rebuild engine session, seek to `ResumePositionStore` position, set `isMiniPlayerVisible == true`, leave **paused**
- Flush playback position on pause / scene resign so kill mid-listen still restores within ±1.0 s
- Clear durable active session **only** on episode end with empty queue (align `QueueCoordinator.handlePlaybackEnded` / shell teardown)
- Unit + UI tests per ACs (relaunch preserve pattern akin to `-UITestFixtureQueuePreserve`)

## Depends on

- Slice 11 (Done) — queue + resume stores
- Slice 23 (Done) — Library + mini player shell

**Parallelizable:** No vs concurrent edits to `AppShellModel.swift` / persistence model; serialize with Slice 30 if both land in the same forge window.

## Out-of-scope

- Auto-play on restore (locked off)
- Clearing session via swipe-dismiss / stop button (intake: finish+empty-queue only)
- Cross-device sync / CloudKit
- CarPlay now-playing restore
- Changing 95% played-threshold math (Slice 11)
- Redesigning mini / full player chrome (Slice 30 parity remains separate)
- Mid-episode auto-advance restore edge cases beyond: queue order already persisted + active id + position restore

## Acceptance criteria

Automatable only. **XCTSkip is not allowed on core ACs.**

- [ ] 1. Unit test (persistence reload): seed active session for `"fixture-ep-001"`, `ResumePositionStore` position **127.5** s, queue `["fixture-ep-002", "fixture-ep-003"]`; after new `PersistenceController` on the same store, restored active episode id is `"fixture-ep-001"`, position **127.5 ± 1.0** s, queue ids unchanged.
- [ ] 2. Unit test (`AppShellModel` or session bootstrap seam): after restore bootstrap with seeded session + position **127.5** s, `isMiniPlayerVisible == true`, `nowPlayingEpisodeID == "fixture-ep-001"`, engine reports **not** playing (`isPlaying == false`), and seek/current time is **127.5 ± 1.0** s.
- [ ] 3. Unit test (clear policy): with active session + **empty** queue, simulate playback ended for the active episode → durable active session is **cleared**; after reload, restore bootstrap leaves `isMiniPlayerVisible == false` / no active episode id.
- [ ] 4. Unit test (clear policy negative): with active session + non-empty queue, simulate playback ended → auto-advance path keeps a durable active session for the **next** episode (id matches advanced episode); session is **not** cleared.
- [ ] 5. UI test (relaunch preserve fixture): seed/play path that establishes session at a pinned position (e.g. **30.0** s or fixture constant); `app.terminate()`; relaunch with preserve arg; within **10.0** s `miniPlayer` exists; `miniPlayerPlayPause` `accessibilityValue == "paused"`; expand full player → `playback.elapsed` Int within **±1** of the pinned position seconds.
- [ ] 6. UI test (same preserve family): after relaunch, up-next queue chrome still shows the seeded queued episode id(s) (at least `queueList` count / `queueCell_0` value match pre-terminate snapshot).
- [ ] 7. Full suite green via `scripts/verify.sh` (**exit 0, failed 0, skipped 0**).

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/NowPlayingSessionTests.swift` | `testActiveSessionPersistsAcrossReload` | ADR-007 reload pattern; fixture ids |
| 2 | `PodWash/PodWashTests/NowPlayingSessionTests.swift` | `testBootstrapRestoresMiniPlayerPausedAtPosition` | No auto-play; ±1.0 s |
| 3 | `PodWash/PodWashTests/NowPlayingSessionTests.swift` | `testSessionClearsWhenEpisodeEndsWithEmptyQueue` | Finish + empty queue |
| 4 | `PodWash/PodWashTests/NowPlayingSessionTests.swift` | `testSessionSurvivesAdvanceWhenQueueNonEmpty` | Next episode becomes active |
| 5 | `PodWash/PodWashUITests/NowPlayingSessionUITests.swift` | `testMiniPlayerRestoresPausedAfterRelaunch` | Preserve launch arg; elapsed ±1 |
| 6 | `PodWash/PodWashUITests/NowPlayingSessionUITests.swift` | `testQueuePersistsWithRestoredSessionAfterRelaunch` | Queue + mini together |
| 7 | — | — | Unfiltered `scripts/verify.sh` |

## Verification commands

```bash
# Fast inner loop (NOT sufficient for Done):
scripts/verify.sh -only-testing:PodWashTests/NowPlayingSessionTests
scripts/verify.sh -only-testing:PodWashUITests/NowPlayingSessionUITests

# Done gate — FULL suite, zero failures, zero skips:
scripts/verify.sh
```

## Verification record (QA fills at Verify)

```
VERIFY RESULT: exit=0 total=6 passed=6 failed=0 skipped=0 filtered=1 bundle=build/test-results/verify-20260715-231655.xcresult tier=2 class=tests
```

## Plan review record (coordinator fills before downstream roles)

```
ADR review (2026-07-15): (pending) QA cleared — pipeline worker finished PM cleared — pipeline worker finished
Test spec review (2026-07-15): Architect cleared — pipeline worker finished
```

## Done gate

- [ ] Every AC mapped to a test; all rows in the mapping table filled
- [ ] **Full suite green:** unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0
- [ ] Verification record pasted above
- [ ] Auto-commit on green: `slice-31: restore now-playing session`

## Tickets (optional)

| Ticket | Owner role | AC subset | Depends on |
|--------|------------|-----------|------------|
| — | — | — | — |

## Role artifacts

| Role | Required? | Artifact |
|------|-----------|----------|
| PM | **Required** | This story |
| Architect | **Required** | `docs/adr/027-restore-now-playing-session.md` |
| UX | **Required** | `docs/slices/slice-31-ux.md` |
| QA | **Required** | `NowPlayingSessionTests` + `NowPlayingSessionUITests` (names may refine at test-spec) |
| Engineer | **Required** | Session persist + `AppShellModel` bootstrap |
