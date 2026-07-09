# Slice 11 — Queue + resume (durable persistence)

| Field | Value |
|-------|-------|
| **ID** | 11 |
| **Title** | Queue + resume |
| **Status** | Draft |
| **Crux** | Up-next queue and per-episode playback positions survive app relaunch via the chosen durable store. |

## PRD / spec references

- PRD §2 — Queue/up-next; resume position; played/unplayed
- PRD §11 — **Open decision: SwiftData vs Core Data.** ⚠️ Halt-and-ask: the coordinator surfaces this choice to the user at slice start — do not pick silently.

## Goal

Durable queue and resume behavior — the first slice that commits to the persistence stack.

## Deliverables

- Persistence layer (SwiftData or Core Data per user decision) for subscriptions, positions, played state, queue order, cleaning toggles (migrating Slice 06/09 in-memory stubs)
- Queue add/remove/reorder; auto-advance to next on episode end
- Position save on pause/background; restore on play
- `QueueTests`, `ResumePositionTests` (in-memory store configuration for speed)

## Depends on

- Slices 03, 06

**Parallelizable:** After the persistence decision, parallel with Slices 10, 12.

## Out-of-scope

- Cross-device sync (PRD §9: none, by design)
- Auto-download policies (Slice 13)

## Acceptance criteria

- [ ] 1. Unit test: add/remove/reorder queue operations produce the expected order; order persists across store reload.
- [ ] 2. Unit test: episode end auto-advances to the next queued episode (player spy).
- [ ] 3. Unit test: position saved on pause is restored on next play within ±1.0 s.
- [ ] 4. Unit test: played/unplayed flips at ≥ 95% listened; persists across reload.
- [ ] 5. Full suite green via `scripts/verify.sh`.

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/QueueTests.swift` | `testQueueOperationsAndPersistence` | TBD |
| 2 | `PodWash/PodWashTests/QueueTests.swift` | `testAutoAdvance` | TBD |
| 3 | `PodWash/PodWashTests/ResumePositionTests.swift` | `testPositionSaveRestore` | TBD |
| 4 | `PodWash/PodWashTests/ResumePositionTests.swift` | `testPlayedStateThreshold` | TBD |
| 5 | — | — | Command-level |

## Verification commands

```bash
scripts/verify.sh -only-testing:PodWashTests/QueueTests -only-testing:PodWashTests/ResumePositionTests
scripts/verify.sh    # Done gate
```

## Verification record (QA fills at Verify)

```
VERIFY RESULT: (pending)
```

## Done gate

- [ ] Persistence decision recorded (ADR) after user approval
- [ ] Every AC mapped to a test; all rows filled
- [ ] **Full suite green:** unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0
- [ ] Verification record pasted above
- [ ] Auto-commit on green: `slice-11: <short description>`

## Role artifacts

| Role | Gate | Artifact path |
|------|------|---------------|
| Architect | Required | `docs/adr/` persistence-choice ADR (after halt-and-ask) |
| UX | Light | queue reorder identifiers |
