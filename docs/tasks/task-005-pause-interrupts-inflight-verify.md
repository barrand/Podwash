# Task 005 — Pause interrupts in-flight verify

| Field | Value |
|-------|-------|
| **ID** | 005 |
| **Title** | Pause interrupts in-flight verify |
| **Status** | Done |
| **Kind** | fix |
| **Priority** | P1 |
| **Area** | `scripts/factory_floor/server.py`, `scripts/task_loop.py`, `scripts/test_task_factory.py` (or new `scripts/test_forge_floor_controls.py`) |
| **Crux** | Floor **Pause** stops in-flight `verify.sh` / `xcodebuild` / Mechanic batch work within **5 s**, not only the next loop tick. |

## Outcome

**Observed:** With Forge Floor **Pause** set (`controls.json` `paused: true`, `running: false`), `task_loop.py` continued a **FULL-VERIFY** Mechanic retry: child `verify.sh` + `xcodebuild test` kept running, the iPhone simulator rebooted after being killed, and overlay beeps continued. Pause only parks `wait_while_paused()` at the top of the next task iteration; `run_batch_gate` does not observe pause mid-flight. Floor **Stop** terminates the runner; **Pause** does not.

**Expected:** **Pause** immediately interrupts in-flight work the same way an operator expects “stop making noise / stop touching the tree”: terminate (then kill if needed) the active verify/xcodebuild children, clear `batch_running`, set station to `paused`, and do not start another verify until **Resume**. Terminal BEL from `notify()` must not fire while paused (or remove BEL entirely — notification banner alone is enough).

**Framing:** If Pause leaves no live `verify.sh`/`xcodebuild` for PodWash and station phase is `paused`, we never need to manually `kill` processes after “pausing” for a call.

## Acceptance criteria

- [ ] 1. With a simulated in-flight batch verify (child process group alive, `batch_running: true`), applying Floor Pause (`POST /api/control` `action=pause` or equivalent control write) causes the child process to exit within **5 s** (SIGTERM then SIGKILL if needed).
- [ ] 2. After Pause, `controls.json` has `paused: true` and `batch_running: false`; `station.json` `phase` is `paused` (or equivalent idle-paused) within **5 s**.
- [ ] 3. While `paused: true`, `task_loop` does **not** start a new `scripts/verify.sh` until Resume clears pause.
- [ ] 4. `task_loop.notify()` does **not** write the terminal bell character (`\a`); macOS notification (osascript) may remain.

## Surgical test scope

| AC# | Test id | New? |
|-----|---------|------|
| 1–3 | `scripts.test_task_factory.PauseInterruptsInflightTests/test_pause_kills_inflight_verify_child` | yes (or equivalent module name under `scripts/test_*.py`) |
| 2 | `scripts.test_task_factory.PauseInterruptsInflightTests/test_pause_clears_batch_running_and_station` | yes |
| 3 | `scripts.test_task_factory.PauseInterruptsInflightTests/test_paused_loop_does_not_start_verify` | yes |
| 4 | `scripts.test_task_factory.PauseInterruptsInflightTests/test_notify_omits_terminal_bell` | yes |

> Task Done for this ticket: green `python3 -m unittest` on the new tests above (plus any existing forge control tests touched). Xcode `VERIFY_SLICE_TESTS` not required — Area is scripts-only.

## Authorized test changes

- New/extended unit tests under `scripts/test_*.py` only — assert pause kills children, clears `batch_running`, blocks new verify, and that `notify` stdout has no `\a`.
- Do **not** weaken existing batch-gate / thrash / Done contracts.

## Depends on

- None

## Out of scope

- Silencing overlay `AVAudioPlayer` in XCTest (task 004).
- Changing **Stop** semantics (already terminates runner) except to share helper code with Pause if useful.
- Auto-shutdown of the iOS Simulator on Pause (nice-to-have; not required for Done).
- Slice-loop pause behavior (separate runner).

## Human checklist

- (none — automatable fix)

## Verification record

> Loop writes `VERIFY RESULT:` here. For this scripts-only task, record the unittest line (treat as Done evidence in lieu of xcodebuild tier-2).

```
VERIFY RESULT: exit=0 total=4 passed=4 failed=0 skipped=0 filtered=1 bundle=scripts-unittest tier=2 class=unittest
```
