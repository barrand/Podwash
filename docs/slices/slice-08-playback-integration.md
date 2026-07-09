# Slice 08 — Playback integration (intervals → mute/skip)

| Field | Value |
|-------|-------|
| **ID** | 08 |
| **Title** | Playback integration |
| **Status** | Draft |
| **Crux** | Cached intervals from the analysis pipeline drive `IntervalScheduler` during playback; switching mute ↔ skip reconfigures the player **without re-running analysis**. |

## PRD / spec references

- PRD §3 — Skip or mute (user choice); instant action switching
- `docs/adr/000-foundations.md` §1–§3 — audioMix, offline-render verification, local files

## Goal

Close the loop: analyzed episode plays with live mute/skip from its cached interval list.

## Deliverables

- Wiring: interval cache (Slice 07) → `IntervalScheduler` (Slice 04) → `PlaybackEngine` (Slice 03)
- Per-episode action setting (mute vs skip) consumed at playback
- `PlaybackIntegrationTests`

## Depends on

- Slices 04, 07

**Parallelizable:** No.

## Out-of-scope

- Progress UI / toggles UI (Slice 09)
- Beep/quack overlay (Slice 16)
- Streamed assets (local files only — ADR-000 §3)

## Acceptance criteria

- [ ] 1. Integration test: loading an analyzed fixture episode configures the player's audioMix with exactly the cached intervals (compare ramp time ranges to cache ±0.001 s).
- [ ] 2. Offline-render test: playback of the analyzed fixture satisfies the Slice 04 RMS thresholds (muted windows RMS < 0.01 full scale) using the pipeline-produced intervals.
- [ ] 3. Unit test: toggling mute → skip and back reconfigures the scheduler; ASR/matcher spies record **0** calls during the toggle.
- [ ] 4. Unit test: episode with no cached intervals plays normally (no mix applied, no crash).
- [ ] 5. Full suite green via `scripts/verify.sh`.

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/PlaybackIntegrationTests.swift` | `testCachedIntervalsConfigureAudioMix` | TBD |
| 2 | `PodWash/PodWashTests/PlaybackIntegrationTests.swift` | `testOfflineRenderMeetsRMSThresholds` | Reuses Slice 04 harness |
| 3 | `PodWash/PodWashTests/PlaybackIntegrationTests.swift` | `testActionToggleNoReanalysis` | TBD |
| 4 | `PodWash/PodWashTests/PlaybackIntegrationTests.swift` | `testNoIntervalsPlaysNormally` | TBD |
| 5 | — | — | Command-level |

## Verification commands

```bash
scripts/verify.sh -only-testing:PodWashTests/PlaybackIntegrationTests   # inner loop
scripts/verify.sh                                                       # Done gate
```

## Verification record (QA fills at Verify)

```
VERIFY RESULT: (pending)
```

## Done gate

- [ ] Every AC mapped to a test; all rows filled
- [ ] **Full suite green:** unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0
- [ ] Verification record pasted above
- [ ] Auto-commit on green: `slice-08: <short description>`

## Role artifacts

| Role | Gate | Artifact path |
|------|------|---------------|
| Architect | Required (wiring note) | inline design section or `docs/adr/` addendum |
| UX | Waived | — |
