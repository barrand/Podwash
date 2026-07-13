# Task 013 — Pause after current soft control

| Field | Value |
|-------|-------|
| **ID** | 013 |
| **Title** | Pause after current soft control |
| **Status** | In Progress |
| **Kind** | tweak |
| **Priority** | P2 |
| **Area** | `scripts/task_loop.py`, `scripts/factory_floor/server.py`, `scripts/test_task_factory.py` (and/or `scripts/test_forge_floor_controls.py`) |
| **Crux** | Arming Floor **Pause after current** finishes the active unit of work (punch-list ticket through Done/Halted, or in-flight batch/Ship-now verify), then parks `paused: true` before the next Queued pick or idle-drain start — without interrupting Engineer/QA mid-ticket. |

## Outcome

**Current:** Floor **Pause** immediately interrupts in-flight work (task-005) and parks the loop. Operators who want a device/local-dev break mid-backlog must either interrupt an In Progress ticket or baby-sit for a quiet boundary.

**Desired:** A second soft control **Pause after current** arms `pause_after_current: true`. The loop keeps working until the current unit of work ends, then sets `paused: true` (and clears the arm flag) so the next tick hits `wait_while_paused()` before starting another Queued task or idle-drain FULL-VERIFY. Immediate **Pause** remains unchanged. **Resume** (and an explicit cancel of the arm, if exposed) clears both `paused` and `pause_after_current`.

**Unit of work (option A):** Whatever Stations is actively doing — (1) a punch-list ticket from start through Done or Halted, or (2) an already in-flight batch / Ship-now verify. Do **not** start a new ticket or a new idle drain after that unit ends while the arm is set.

## Acceptance criteria

- [ ] 1. `POST /api/control` with `action=pause_after_current` sets `controls.json` `pause_after_current: true` without setting `paused: true` and without calling `interrupt_inflight_on_pause`.
- [ ] 2. With `pause_after_current: true` and a task In Progress, the loop does **not** pause mid-ticket; after that ticket reaches Done or Halted, before `query_next()` starts another Queued task, the loop sets `paused: true`, clears `pause_after_current`, and enters the paused wait (station phase `paused` or equivalent).
- [ ] 3. With `pause_after_current: true` while a batch / Ship-now verify is in flight (`batch_running` / FORCE verify), after that verify finishes (success or failure path that returns to the main loop), the loop sets `paused: true` and clears the arm **before** starting a Queued task or another idle-drain verify.
- [ ] 4. If `pause_after_current: true` when the loop is already idle (no In Progress ticket, no in-flight batch), the next loop boundary parks immediately (`paused: true`, arm cleared) without starting work.
- [ ] 5. `action=resume` clears both `paused` and `pause_after_current`. Immediate `action=pause` still interrupts in-flight work (task-005 contract unchanged) and should clear or supersede the arm (`pause_after_current: false`) so state is not ambiguous.
- [ ] 6. Floor UI: a **Pause after current** control (toolbar or adjacent to Pause); while armed and not yet paused, Stations / hot strip shows an armed indicator containing the literal substring `pause after current` (e.g. `Will pause after current`); button remains cancelable via Resume (or a cancel that clears only the arm).

## Surgical test scope

| AC# | Test id | New? |
|-----|---------|------|
| 1 | `scripts.test_task_factory.PauseAfterCurrentTests/test_api_arms_flag_without_pausing` | yes |
| 2 | `scripts.test_task_factory.PauseAfterCurrentTests/test_pauses_after_task_done_before_next_pick` | yes |
| 3 | `scripts.test_task_factory.PauseAfterCurrentTests/test_pauses_after_inflight_batch_before_next_work` | yes |
| 4 | `scripts.test_task_factory.PauseAfterCurrentTests/test_idle_arm_pauses_at_next_boundary` | yes |
| 5 | `scripts.test_task_factory.PauseAfterCurrentTests/test_resume_clears_arm_and_pause` | yes |
| 5 | `scripts.test_task_factory.PauseAfterCurrentTests/test_immediate_pause_clears_arm` | yes |
| 6 | `scripts.test_task_factory.PauseAfterCurrentTests/test_board_snapshot_shows_armed_indicator` | yes (or floor board test module) |

> Task Done: green `python3 -m unittest` on the tests above. Xcode `VERIFY_SLICE_TESTS` not required — Area is scripts-only.

## Authorized test changes

- New/extended unit tests under `scripts/test_*.py` only — assert arm/API, boundary pause after task/batch, idle immediate park, resume/immediate-pause clearing the arm, and board/SSE indicator text.
- Do **not** weaken existing Pause-interrupts-inflight (task-005) or batch-gate contracts.

## Depends on

- Task 005 (Done) — immediate Pause interrupt semantics remain the other control

## Out of scope

- Auto-opening a device worktree / Xcode from Floor
- Changing Stop semantics
- Slice-loop pause-after-current (task-loop / Floor only)
- Renaming immediate Pause

## Human checklist

- (none — automatable fix)

## Verification record

> Loop writes `VERIFY RESULT:` here. For this scripts-only task, record the unittest line (treat as Done evidence in lieu of xcodebuild tier-2).

```
VERIFY RESULT: exit=0 total=7 passed=7 failed=0 skipped=0 filtered=1 bundle=scripts-unittest tier=2 class=unittest
```
