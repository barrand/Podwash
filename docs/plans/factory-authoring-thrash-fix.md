# Factory: authoring-phase thrash fix + slice 12 resume

> Status: **factory fixes landed** — slice 12 resume still pending (manual).
> Context: slice 12 halted with `THRASH HALT: red verify limit reached (2/2)` during
> QA test-spec authoring. This is a **different factory bug** than the slice 11
> referee/ledger halt (fixed in commit `0ddb81a`).

## Verdict

Slice 11 died in the post-implement referee/ledger fix loop. Slice 12 died in
**pre-implement QA test-spec authoring** because intentional TDD compile-red was
misclassified as thrash.

| | Slice 11 | Slice 12 |
|---|----------|----------|
| Phase | Post-implement fix loop | Test-spec gate (6/9 → test-spec review) |
| Mechanism | Referee JSON → heuristic → ledger halt | `max_red_verifies=2` on `RunProgress` |
| Expected red? | Real assertion failure | Yes — tests call APIs that do not exist yet |
| Actual failure | Spy double-count (QA test bug) | Compile: missing `SleepTimer`, `MonotonicClock`, `PlaybackPausing` |

```mermaid
sequenceDiagram
    participant QA as QA_test_spec
    participant V as verify_filtered
    participant RP as RunProgress
    participant Loop as slice_loop

    QA->>QA: write SleepTimerTests PlaybackRateTests
    QA->>V: verify.sh filtered
    V->>V: BUILD FAILED failed=0
    RP->>RP: detect xcodebuild TEST FAILED
    RP->>RP: red verify 1/2
    QA->>V: verify again
    V->>V: BUILD FAILED again
    RP->>RP: red verify 2/2
    RP->>Loop: ThrashHalt
```

## What actually failed

Latest xcresult (`verify-20260710-125502.xcresult`): **6 compile errors, 0 tests
run** — all in `SleepTimerTests.swift` (`MonotonicClock`, `PlaybackPausing`,
`SleepTimer` missing). Tests are correct TDD-red; app APIs do not exist yet. The
opaque log line `xcodebuild — TEST FAILED` with `failed=0` is the factory failing
to classify **build_error**.

Slice 12 state at halt: Status **Ready**; test files on disk (uncommitted); Test
spec review **(pending)**; Engineer not started; VERIFY RESULT pending.

## Why the factory halted

`_record_red_verify` in `scripts/slice_loop_progress.py` (~1479–1531) counts every
red `verify.sh` / `xcodebuild … test` for non-fix workers. The pipeline `test_spec`
prompt (`build_gate_prompt` in `scripts/slice_pipeline.py` ~1298–1300) says "write
failing tests" but does **not** ban verify. QA role docs allow verify. So QA did
the right TDD thing and the loop killed itself.

Fix workers already set `max_red_verifies=0` + verify ban. Authoring workers do not.

## Factory fixes (execute in this order)

### 1. Exempt pre-implement authoring from red-verify thrash (highest leverage)

Pipeline gate workers are spawned in `run_pipeline_slice` with only `forced_role`
(two spawn sites, ~2484 and ~2517 in `scripts/slice_pipeline.py`):

```python
prog = progress_cls(
    slice_id, title, slice_file, _log,
    verbose=verbose, heartbeat_secs=heartbeat_secs,
    repo_root=repo_root,
    forced_role=role,
)
```

Add `authoring_gate=True` for gates before `implement` (`story`, `architect`,
`ux`, ADR reviews, `test_spec`, `test_review`) at **both** spawn sites. In
`_record_red_verify`: when `authoring_gate`, do not increment `_red_verify_count`
and never halt; log once per run:
`authoring-phase red verify ignored (TDD compile-red expected until Engineer implements)`.

### 2. Hard-enforce the verify ban for test_spec (not just prompt text)

Two layers, both needed:

- **Prompt:** update `build_gate_prompt("test_spec")` to mirror implement:
  "Do NOT run scripts/verify.sh or xcodebuild test — the loop owns verification
  after Engineer. Your tests are expected to fail to compile until app code exists."
- **Enforcement:** reuse the existing `_handle_verify_ban` cancel machinery
  (`scripts/slice_loop_progress.py` ~1533) for authoring gates: cancel the shell
  command with "TDD red is expected — do not verify during test-spec; end your
  turn when tests are written." Unlike fix workers, do **not** burn any budget —
  cancel and continue. Prompt bans are soft (models ignore them); the cancel is
  the guarantee that saves ~110 s of doomed xcodebuild per ignored ban.

### 3. Root-fix opaque failures in verify.sh itself

`scripts/verify.sh` knows the ground truth: xcodebuild exit code + whether the
xcresult contains any executed tests. Emit it in the artifact line:
`VERIFY RESULT: exit=65 total=0 … class=build` when exit!=0 and 0 tests ran,
`class=tests` otherwise. Every consumer (`parse_verify_result`, `RunProgress`,
`FailurePacket`, referee prompt) then gets build-vs-test classification for free
instead of each re-deriving it.

### 4. Classify build failures in the log stream

In `detect_test_failures` / `_collect_test_failures`
(`scripts/slice_loop_progress.py`):

- Parse `error:` / `cannot find` / `** BUILD FAILED **` /
  `Testing cancelled because the build failed` (reuse `_BUILD_HINT_RE` from
  `scripts/failure_packet.py`)
- When exit!=0 and failed=0, signature becomes `build_error: <first compile error>`
  (e.g. `build_error: Cannot find type 'MonotonicClock' in scope`) instead of
  `xcodebuild — TEST FAILED`
- Log: `likely compile/build failure (0 tests executed)`

### 5. Leave diagnosable artifacts on every halt

`_halt_for_thrash` currently exits without a stuck card, session bundle, or
event-log entry (slice 12's `events-slice-12.jsonl` shows QA spawn then nothing).
On halt:

- Write `stuck-slice-NN.txt` + session bundle (reuse `write_session_bundle`)
- Record a `HALT` event in the EventLog with gate id and signature
- Make the halt message gate-aware: for pre-implement halts say "next: complete
  test-spec review, then Engineer implement" instead of the generic "spawn
  engineer and re-run"

### 6. Durability: commit test spec when the gate clears

Slice 12's tests sat untracked on disk through the halt. After `test_spec` +
`test_review` gates clear, auto-commit `PodWashTests/**` + `PodWashUITests/**` as
`slice-NN: test spec` (already the commit policy; run
`scripts/check-test-isolation.sh --staged` first). A halt then never risks
orphaning authored tests.

### 7. Regression tests

In `scripts/test_slice_loop_progress.py` / `scripts/test_slice_pipeline.py`:

- Authoring-gate red verify ×3 does **not** raise `ThrashHalt`;
  coordinator/post-implement path still halts at 2
- Authoring-gate verify shell is cancelled (ban) without burning budget
- `detect_test_failures` extracts a compile error from a BUILD FAILED blob
  (fixture from slice 12's real output)
- `parse_verify_result` reads `class=build`
- `test_spec` prompt contains the verify ban

## Slice 12 resume (after factory fixes land)

Do **not** re-run blind verify — that is the trap.

1. Commit test spec (`slice-12: test spec`) — `PlaybackRateTests.swift` and
   `SleepTimerTests.swift` are untracked; `PlaybackControlsUITests.swift` is
   modified. Run `scripts/check-test-isolation.sh --staged` first.
2. Spawn Architect readonly test-spec review; record outcome in the slice's
   Plan review record (`docs/slices/slice-12-speed-sleep.md`).
3. Spawn Engineer for `PlaybackEngine.setRate`, `SleepTimer` + `MonotonicClock` +
   `PlaybackPausing`, and UI `speedButton` / `sleepTimerButton` in
   `PlaybackControlsView`.
4. Loop-owned verify (tier-2 → full suite) → record VERIFY RESULT → Done banner
   (or run `scripts/slice-loop.sh --max 1` which now handles the whole sequence).

## Docs

Update `docs/slice-pipeline.md`: authoring gates must not run verify; red-verify
thrash applies only after implement / to coordinator-monitored fix grinding, not
TDD compile-red. Add the `VERIFY RESULT: … class=build|tests` field. Also fix the
drift where the doc still describes coordinator as default orchestrator (pipeline
is the default in `scripts/slice_loop.py`).

## Hardening principle this encodes

The factory distinguishes three red states that previously shared one budget:

- **TDD compile-red during authoring** — expected, never counted, verify cancelled
- **Build-red after implement** — `build_error` class, routed to Engineer with the
  compile error text
- **Test-red after implement** — assertion class, referee routes Engineer/QA with
  full fix budget

Each phase's failure gets its own policy instead of one global "2 reds and you're
dead" counter — the same philosophy as the slice 11 fix (ledger reroute instead of
halt), applied to the authoring phase.
