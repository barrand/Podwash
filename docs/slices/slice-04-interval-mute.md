# Slice 04 — Interval mute/skip

| Field | Value |
|-------|-------|
| **ID** | 04 |
| **Title** | Interval mute/skip |
| **Status** | Done |
| **Crux** | An interval list applied to `PlaybackEngine` produces silence (mute) verified by **offline render + numeric RMS assertions**, and seek-past (skip) — on local synthetic fixtures, no human listening. |

## PRD / spec references

- PRD §3 — Profanity handling (mute/skip actions, quality criteria)
- `docs/adr/000-foundations.md` §1–§3 — AVMutableAudioMix; **offline-render verification** (`AVAssetReaderAudioMixOutput` sharing the player's audioMix); **local files only**

## Goal

Prove the core differentiator: interval-driven mute and skip on the Slice 03 player, verified deterministically.

## Deliverables

- `IntervalScheduler`: builds an `AVMutableAudioMix` with volume ramps from an interval list (**consumes `IntervalBuilder` output from Slice 02** — no interval math re-implemented here); seek-past logic for skip
- Offline-render test harness: renders the fixture asset through `AVAssetReaderAudioMixOutput` with the **same audioMix instance** and computes windowed RMS on the PCM
- Synthetic tone fixture — **constant-amplitude 300 Hz sine, amplitude 0.9, mono, 44.1 kHz, lossless PCM WAV, 5 s** (< 1 MB) — in `PodWash/PodWashTests/Fixtures/audio/` with generation script or documented provenance (per ADR-002 §8). Frequency/amplitude pinned so the fixture's inherent adjacent-sample slew ≈ 0.0385 (< AC3's 0.05) and a fade-band window still reads ≈ 0.367 (> AC2's 0.25); the Slice 03 440 Hz AAC clip is **not** reused (inherent slew ≈ 0.063 > 0.05, plus codec ringing)
- `IntervalMuteSkipTests`, `IntervalBoundaryEnergyTests`

## Depends on

- Slice 02 (interval math), Slice 03 (player shell)

**Parallelizable:** No — requires both dependencies green.

## Out-of-scope

- Beep/quack overlay (Slice 16 — hard, deferred per ADR-000 §7)
- Streamed/remote assets (ADR-000 §3: muting requires local files)
- Perceptual ear tests (future automation target)
- ASR or matcher wiring (Slice 07)
- New SwiftUI screens (reuses Slice 03 controls)

## Acceptance criteria

- [x] 1. Unit test: `IntervalScheduler` accepts `IntervalBuilder` output directly (typed interface, no duplicate padding/merge logic — structural assert on module dependency).
- [x] 2. Offline-render test: for intervals `[(1.0, 1.5), (3.0, 3.4)]` on the sine fixture, windowed RMS **< 0.01 full scale** in every 10 ms window fully inside `[start + 0.030, end − 0.030]`, and **> 0.25 full scale** in every 10 ms window outside all intervals by **≥ 0.030 s**. The `±0.030 s` band around each boundary is a don't-care transition region (the `AVAssetReaderAudioMixOutput` renderer smooths volume ramps over a ~20 ms floor, so a fade bleeds into the interior — see ADR-002 §4 "Revision", §7).
- [x] 3. Offline-render test on the pinned 300 Hz / amplitude-0.9 lossless fixture (inherent slew ≈ 0.0385 < 0.05): with `fadeDuration = 0.020 s`, measured rendered fade width matches the configured value ±10 ms; no sample-to-sample discontinuity > 0.05 full scale within one 10 ms window of any interval boundary.
- [x] 4. Unit test: skip mode advances `currentTime` past interval end +0/-0.1 s without `timeControlStatus` leaving `.playing`.
- [x] 5. Unit test: seek into an active mute window retains the schedule (the item's `audioMix` stays the applied mix after `seek(to:)`); a full-context offline re-render (reader started at ≤ `start − fadeDuration`) has RMS < 0.01 in the interior window at the seek target. (The reader **cannot** be started inside a mute interval — it drops the pre-start ramp state and renders base volume; ADR-002 §6 "Revision".)
- [x] 6. Full suite green via `scripts/verify.sh`.

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/IntervalMuteSkipTests.swift` | `testSchedulerConsumesIntervalBuilderOutput` | Typed proof: `IntervalSchedule(intervals:)` takes `IntervalBuilder.buildIntervals(...)` output verbatim; asserts `schedule.intervals == built` (no re-pad/re-merge) + default fade sourced from `IntervalScheduler.defaultFadeDuration` |
| 2 | `PodWash/PodWashTests/IntervalBoundaryEnergyTests.swift` | `testOfflineRenderRMSInsideAndOutsideIntervals` | Offline render per ADR-000 §2 via `OfflineRenderRMS` harness; windows in `[s+0.030, e−0.030]` RMS < 0.01, windows outside by ≥ 0.030 s RMS > 0.25 (settle margin covers the renderer's ~20 ms ramp smoothing) |
| 3 | `PodWash/PodWashTests/IntervalBoundaryEnergyTests.swift` | `testFadeRampAndBoundaryContinuity` | Windowed-RMS fade width == `defaultFadeDuration` ±10 ms at each boundary; raw-sample max \|Δ\| ≤ 0.05 within ±1 window on the pinned 300 Hz/0.9 fixture (inherent slew ≈ 0.0385) |
| 4 | `PodWash/PodWashTests/IntervalMuteSkipTests.swift` | `testSkipAdvancesPastInterval` | Drives real `PlaybackEngine` on the fixture; skip `[2.0,2.5]`, periodic-observer expectation (no sleep); asserts `currentTime ∈ [end−0.1, end]` and `.playing` |
| 5 | `PodWash/PodWashTests/IntervalMuteSkipTests.swift` | `testSeekReappliesScheduleRMS` | After `seek(to: 1.2)` asserts `currentItem.audioMix` is retained; full-context render (reader from t=0) asserts the `[1.2,1.3]` interior window RMS < 0.01 (reader cannot start inside a mute interval — ADR-002 §6) |
| 6 | — | — | Command-level (`scripts/verify.sh`, full suite) |

## Verification commands

```bash
# Fast inner loop:
scripts/verify.sh -only-testing:PodWashTests/IntervalMuteSkipTests -only-testing:PodWashTests/IntervalBoundaryEnergyTests

# Done gate — FULL suite:
scripts/verify.sh
```

## Verification record (QA fills at Verify)

```
VERIFY RESULT: exit=0 total=18 passed=18 failed=0 skipped=0 filtered=0 bundle=build/test-results/verify-20260708-220224.xcresult
```

Full unfiltered `scripts/verify.sh` run 2026-07-08 (simulator resolved dynamically). All 18 tests
(5 new Slice-04 tests + Slice 01–03 suite) passed, 0 failed, 0 skipped. Fixture regenerated via
`aevalsrc` (peak ≈ 0.90); `defaultFadeDuration = 0.020 s`, settle margin 0.030 s (ADR-002 Revision).
Note (non-gating): the QA test file emits Swift-6 actor-isolation/`await` warnings on
`CensorInterval` property access — future cleanup target, not a Done blocker.

## Done gate

- [x] Every AC mapped to a test; all rows filled
- [x] **Full suite green:** unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0
- [x] Verification record pasted above
- [x] Auto-commit on green: `slice-04: interval mute/skip`

## Role artifacts

| Role | Gate | Artifact path |
|------|------|---------------|
| Architect | Required | [`docs/adr/002-interval-scheduler.md`](../adr/002-interval-scheduler.md) — Accepted; conforms to ADR-000 §1–§3, additive to ADR-001 |
| UX | Waived | — (reuses Slice 03 chrome) |
