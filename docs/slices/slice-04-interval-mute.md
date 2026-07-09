# Slice 04 — Interval mute/skip

| Field | Value |
|-------|-------|
| **ID** | 04 |
| **Title** | Interval mute/skip |
| **Status** | Draft |
| **Crux** | An interval list applied to `PlaybackEngine` produces silence (mute) verified by **offline render + numeric RMS assertions**, and seek-past (skip) — on local synthetic fixtures, no human listening. |

## PRD / spec references

- PRD §3 — Profanity handling (mute/skip actions, quality criteria)
- `docs/adr/000-foundations.md` §1–§3 — AVMutableAudioMix; **offline-render verification** (`AVAssetReaderAudioMixOutput` sharing the player's audioMix); **local files only**

## Goal

Prove the core differentiator: interval-driven mute and skip on the Slice 03 player, verified deterministically.

## Deliverables

- `IntervalScheduler`: builds an `AVMutableAudioMix` with volume ramps from an interval list (**consumes `IntervalBuilder` output from Slice 02** — no interval math re-implemented here); seek-past logic for skip
- Offline-render test harness: renders the fixture asset through `AVAssetReaderAudioMixOutput` with the **same audioMix instance** and computes windowed RMS on the PCM
- Synthetic tone fixture (constant-amplitude sine, < 1 MB) in `PodWash/PodWashTests/Fixtures/audio/` with generation script or documented provenance
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

- [ ] 1. Unit test: `IntervalScheduler` accepts `IntervalBuilder` output directly (typed interface, no duplicate padding/merge logic — structural assert on module dependency).
- [ ] 2. Offline-render test: for intervals `[(1.0, 1.5), (3.0, 3.4)]` on the sine fixture, windowed RMS **< 0.01 full scale** in every 10 ms window fully inside each interval, and **> 0.25 full scale** in windows fully outside intervals.
- [ ] 3. Offline-render test: fade ramp duration matches configured value ±10 ms; no sample-to-sample discontinuity > 0.05 full scale at interval boundaries.
- [ ] 4. Unit test: skip mode advances `currentTime` past interval end +0/-0.1 s without `timeControlStatus` leaving `.playing`.
- [ ] 5. Unit test: seek into an active mute window re-applies the schedule; offline re-render still satisfies AC2 thresholds.
- [ ] 6. Full suite green via `scripts/verify.sh`.

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/IntervalMuteSkipTests.swift` | `testSchedulerConsumesIntervalBuilderOutput` | TBD |
| 2 | `PodWash/PodWashTests/IntervalBoundaryEnergyTests.swift` | `testOfflineRenderRMSInsideAndOutsideIntervals` | Offline render per ADR-000 §2 |
| 3 | `PodWash/PodWashTests/IntervalBoundaryEnergyTests.swift` | `testFadeRampAndBoundaryContinuity` | TBD |
| 4 | `PodWash/PodWashTests/IntervalMuteSkipTests.swift` | `testSkipAdvancesPastInterval` | TBD |
| 5 | `PodWash/PodWashTests/IntervalMuteSkipTests.swift` | `testSeekReappliesScheduleRMS` | TBD |
| 6 | — | — | Command-level |

## Verification commands

```bash
# Fast inner loop:
scripts/verify.sh -only-testing:PodWashTests/IntervalMuteSkipTests -only-testing:PodWashTests/IntervalBoundaryEnergyTests

# Done gate — FULL suite:
scripts/verify.sh
```

## Verification record (QA fills at Verify)

```
VERIFY RESULT: (pending)
```

## Done gate

- [ ] Every AC mapped to a test; all rows filled
- [ ] **Full suite green:** unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0
- [ ] Verification record pasted above
- [ ] Auto-commit on green: `slice-04: <short description>`

## Role artifacts

| Role | Gate | Artifact path |
|------|------|---------------|
| Architect | Required | `docs/adr/002-interval-scheduler.md` (TBD; conforms to ADR-000 §1–§3) |
| UX | Waived | — (reuses Slice 03 chrome) |
