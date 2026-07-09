# Slice 16 — Beep/quack overlay (hard)

| Field | Value |
|-------|-------|
| **ID** | 16 |
| **Title** | Beep/quack overlay |
| **Status** | Draft |
| **Crux** | An overlay sound plays synchronized (±50 ms) with mute windows during AVPlayer playback — the AVAudioEngine-sync problem ADR-000 §7 explicitly deferred. **Flagged hard; expect a spike phase.** |

## PRD / spec references

- PRD §3 — Optional beep/quack overlay on mute
- `docs/adr/000-foundations.md` §7 — deferral rationale + prototype starting values (1 kHz, 0.35 volume, 5 ms fades)
- `docs/specs/matching-spec.md` §1 — non-normative overlay constants

## Goal

The classic "censored" beep, without breaking the no-re-encode architecture.

## Deliverables

- Overlay engine (`AVAudioEngine` player node or secondary `AVPlayer`) triggered by a boundary time observer on the main player
- Sync spike report if the approach changes (supersede ADR-000 §7 via new ADR)
- Offline verification path: composite render or scheduled-callback timestamps asserted against interval boundaries
- `OverlaySyncTests`

## Depends on

- Slice 08

**Parallelizable:** Yes — with Slices 15, 17.

## Out-of-scope

- Quack asset sourcing polish (any licensed/generated asset OK)
- Perceptual "sounds right" checks (future automation target)

## Acceptance criteria

- [ ] 1. Unit test: overlay trigger timestamps (recorded by injected scheduler) are within **±50 ms** of each mute interval start on the fixture.
- [ ] 2. Unit test: overlay stops within ±50 ms of interval end; no overlay outside intervals.
- [ ] 3. Unit test: overlay respects the user setting (off / beep / quack) from Slice 13 settings.
- [ ] 4. Unit test: seek during an interval re-syncs the overlay (no orphaned overlay after seek-out).
- [ ] 5. Full suite green via `scripts/verify.sh`.

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/OverlaySyncTests.swift` | `testOverlayStartSync` | TBD |
| 2 | `PodWash/PodWashTests/OverlaySyncTests.swift` | `testOverlayEndAndSilenceOutside` | TBD |
| 3 | `PodWash/PodWashTests/OverlaySyncTests.swift` | `testOverlaySettingRespected` | TBD |
| 4 | `PodWash/PodWashTests/OverlaySyncTests.swift` | `testSeekResync` | TBD |
| 5 | — | — | Command-level |

## Verification commands

```bash
scripts/verify.sh -only-testing:PodWashTests/OverlaySyncTests
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
- [ ] Auto-commit on green: `slice-16: <short description>`

## Role artifacts

| Role | Gate | Artifact path |
|------|------|---------------|
| Architect | Required (spike + ADR) | `docs/adr/` overlay-sync ADR (TBD; supersedes ADR-000 §7 deferral) |
| UX | Waived | — (setting UI exists from Slice 13) |
