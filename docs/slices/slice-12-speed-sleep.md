# Slice 12 — Variable speed + sleep timer

| Field | Value |
|-------|-------|
| **ID** | 12 |
| **Title** | Variable speed + sleep timer |
| **Status** | Draft |
| **Crux** | Playback rate control (0.75x–3x) and an injectable-clock sleep timer behave deterministically under unit test, including rate interaction with mute intervals. |

## PRD / spec references

- PRD §2 — Variable speed, sleep timer
- PRD §3 — Playback behaves normally through native controls with cleaning active

## Goal

Two table-stakes controls, delivered together because both are small `PlaybackEngine` extensions.

## Deliverables

- Rate control on `PlaybackEngine` (`0.75, 1.0, 1.25, 1.5, 2.0, 3.0`)
- Sleep timer with injected `Clock`/scheduler; pause-at-fire; extend/cancel
- Speed + sleep controls in player UI (identifiers `speedButton`, `sleepTimerButton`)
- `PlaybackRateTests`, `SleepTimerTests`

## Depends on

- Slice 03 (rate); Slice 08 (rate × mute interaction test)

**Parallelizable:** Yes — with Slices 10, 11.

## Out-of-scope

- Settings persistence of default speed (Slice 13)
- Trim-silence / voice boost features

## Acceptance criteria

- [ ] 1. Unit test: setting each supported rate yields `player.rate` equal to it (±0.001) while playing.
- [ ] 2. Unit test: at rate 2.0 with an active mute interval, the audioMix ramp **time ranges are unchanged** (intervals are media-timeline-based, not wall-clock) — offline render at rate 1.0 still satisfies RMS thresholds.
- [ ] 3. Unit test: sleep timer with injected clock advanced past the deadline pauses playback exactly once; extend before deadline defers it; cancel prevents it.
- [ ] 4. UI test: `speedButton` cycles its accessibility value through the supported rates.
- [ ] 5. Full suite green via `scripts/verify.sh`.

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/PlaybackRateTests.swift` | `testSupportedRates` | TBD |
| 2 | `PodWash/PodWashTests/PlaybackRateTests.swift` | `testRateDoesNotShiftMuteIntervals` | TBD |
| 3 | `PodWash/PodWashTests/SleepTimerTests.swift` | `testTimerFireExtendCancel` | Injected clock |
| 4 | `PodWash/PodWashUITests/PlaybackControlsUITests.swift` | `testSpeedButtonCycles` | TBD |
| 5 | — | — | Command-level |

## Verification commands

```bash
scripts/verify.sh -only-testing:PodWashTests/PlaybackRateTests -only-testing:PodWashTests/SleepTimerTests
scripts/verify.sh    # Done gate
```

## Verification record (QA fills at Verify)

```
VERIFY RESULT: (pending)
```

## Done gate

- [ ] Every AC mapped to a test; all rows filled
- [ ] **Full suite green:** unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0
- [ ] Verification record pasted above
- [ ] Auto-commit on green: `slice-12: <short description>`

## Role artifacts

| Role | Gate | Artifact path |
|------|------|---------------|
| Architect | Waived (extends existing engine API) | — |
| UX | Light | control identifiers in slice file |
