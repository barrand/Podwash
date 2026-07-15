# Slice 30 — Mini-player super seek bar parity (shared chrome)

| Field | Value |
|-------|-------|
| **ID** | 30 |
| **Title** | Mini-player super seek bar parity (shared chrome) |
| **Status** | In Progress |
| **Priority** | P3 |
| **Crux** | Mini and full player host the **same** `SuperSeekBarView` (one paint + seek + mute-marker implementation): with analysis complete and ≥ **1** profanity mute, both expose matching segment + `muteMarkers:N` AX, and mini supports playhead + frontier-clamped tap-to-seek without a second bar implementation. |

## PRD / spec references

- PRD — playback chrome / cleaning visibility (player surfaces)
- `docs/adr/000-foundations.md` — AX / offline verify over device listening
- `docs/adr/018-analysis-timeline.md` — 12-segment colors; yellow = ads only
- `docs/adr/021-progressive-playback-super-seek-bar.md` — super seek model (playhead, remaining, frontier clamp); today mini interactive seek is OOS
- `docs/adr/023-super-seek-bar-mute-markers.md` — mute overlays + `muteMarkers:` AX; today entry is full-player only

## Goal

Give the mini player full visual/interaction parity with the full-player super seek bar (segments, red mute streaks, playhead, tap-to-seek) by **reusing one shared view/model**, not a parallel mini-only timeline.

## Intake decisions (locked)

| Decision | Choice |
|----------|--------|
| Scope | Full mini ↔ full parity: segment colors, mute-marker overlays, playhead, tap-to-seek with frontier clamp |
| Codebase | **Single source of truth** — one `SuperSeekBarView` (+ `SuperSeekBarModel`) hosted in both `MiniPlayerBar` and `PlaybackControlsView`; height/layout params only — **no** second mute/seek paint path |
| Expand vs seek | Tap **title / artwork row** (or existing `miniPlayer` expand target) opens full player; tap **on the shared seek bar** seeks (clamped). `miniPlayerPlayPause` unchanged |
| Identifiers | Full keeps `playback.superSeekBar`. Mini retires read-only `miniPlayerAnalysisTimeline` in favor of a dedicated mini host id (UX pins name, e.g. `miniPlayer.superSeekBar`) that uses the **same** AX value grammar as full |
| Mute markers | Same ADR-023 filter + complete-only gate; mini and full `muteMarkers:N` counts match for the same now-playing episode |
| Episode-row `analysisTimeline` | **Out of scope** this slice (user may intake a follow-up to retire row timelines) |
| CarPlay / lock screen | OOS |

## Deliverables

- ADR — [`docs/adr/026-mini-player-super-seek-parity.md`](../adr/026-mini-player-super-seek-parity.md) (lifts mini OOS from ADR-021 / ADR-023; shared host + expand-vs-seek)
- UX spec `docs/slices/slice-30-ux.md` — mini layout heights, expand vs bar hit targets, AX ids, fixture scenarios
- Wire `MiniPlayerBar` to host `SuperSeekBarView` with mute intervals + seek callbacks (same seams as full player)
- Remove / stop painting mini-only `AnalysisTimelineView` path for player chrome (episode-row bar unchanged)
- Tests — unit (shared model unchanged or thin host wiring) + UI (mini AX + seek + mute parity with full)

## Design note (Architect)

**ADR-026** is the gate artifact. Summary for downstream roles:

| Concern | Decision |
|---------|----------|
| Shared type | One `SuperSeekBarView` (+ existing `SuperSeekBarModel`); parameterize `barHeight` + `accessibilityIdentifier` |
| Mini id | `miniPlayer.superSeekBar` (retire `miniPlayerAnalysisTimeline`); same AX value grammar as full |
| Expand vs seek | Title/artwork = `miniPlayer` expand; bar = seek only; not nested in expand button |
| Mute / seek | Same ADR-023 complete-only gate + ADR-021 frontier clamp; shell reuses `seekClampedToProcessedFrontier` + cached intervals |
| Visibility | Host bar whenever mini player is visible (grey track when no colors) — do not hide when colors nil |

## Depends on

- Slice 25 (Done) — super seek bar
- Slice 27 (Done) — mute markers on full player

**Parallelizable:** No vs work that edits `SuperSeekBarView.swift` / `MiniPlayerBar.swift` concurrently; serialize with slice-29 only if both touch shared shell files.

## Out-of-scope

- Episode-row `analysisTimeline` markers or removal (separate intake)
- CarPlay / lock-screen seek chrome
- Changing mute/skip algorithm, ASR, or ADR-018 yellow = ads rules
- Transcript word highlighting
- Interactive seek on episode rows
- Replacing full-player sheet chrome beyond sharing the bar view

## Acceptance criteria

Automatable only. **XCTSkip is not allowed on core ACs.**

- [ ] 1. UI test (`-UITestFixtureMuteMarkers`, cleaning on): within **5.0 s** of mini-player visible, mini super-seek host exists and `accessibilityValue` includes `muteMarkers:` with count **≥ 1** (pinned fixture **2** if applicable).
- [ ] 2. UI test (same session): expand full player → within **5.0 s**, `playback.superSeekBar` `muteMarkers` count **equals** the mini host’s count; segment triple (`ready`/`processing`/`pending`) matches.
- [ ] 3. UI test (ads-only mute fixture): mini host terminal AX includes `muteMarkers:0`; segment sum **12**.
- [ ] 4. UI test: with frontier / processedEnd fixture (or progressive mid-run), tap on mini super-seek bar at a normalized position past the frontier → `playback.elapsed` (after expand) or mini-visible elapsed contract is clamped within **±0.5 s** of `processedEnd` (same clamp semantics as Slice 25 full player).
- [ ] 5. UI test: tap `miniPlayer` expand target (title/artwork — **not** the seek bar) still presents full player (`playback.playPause` or `playback.superSeekBar` within **5.0 s**).
- [ ] 6. Unit or compile-time seam test: mini and full player chrome both construct / host `SuperSeekBarView` (or a single shared wrapper type named in the ADR) — **no** parallel mute-overlay drawing in `AnalysisTimelineView` / `MiniPlayerBar` private paint.
- [ ] 7. Full suite green via `scripts/verify.sh` (**exit 0, failed 0, skipped 0**).

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashUITests/MiniPlayerSuperSeekBarUITests.swift` | `testMiniPlayerExposesMuteMarkersWhenProfanityMutePresent` | `-UITestFixtureMuteMarkers`; `miniPlayer.superSeekBar`; pinned `muteMarkers:2` |
| 2 | `PodWash/PodWashUITests/MiniPlayerSuperSeekBarUITests.swift` | `testMiniAndFullPlayerMuteMarkersParity` | Same session; expand; segment triple + mute count match |
| 3 | `PodWash/PodWashUITests/MiniPlayerSuperSeekBarUITests.swift` | `testMiniPlayerMuteMarkersZeroForAdsOnly` | `-UITestFixtureMuteMarkersAdsOnly`; `muteMarkers:0`; sum 12 |
| 4 | `PodWash/PodWashUITests/MiniPlayerSuperSeekBarUITests.swift` | `testMiniPlayerSeekClampsToProcessedFrontier` | Progressive freeze at 60 s; mini tap `dx=0.75`; expand; elapsed 55–65 |
| 5 | `PodWash/PodWashUITests/MiniPlayerSuperSeekBarUITests.swift` | `testMiniPlayerExpandStillOpensFullPlayer` | Tap `miniPlayer` (not seek bar); full chrome within 5 s |
| 6 | `PodWash/PodWashTests/MiniPlayerSuperSeekBarHostTests.swift` | `testMiniPlayerBarHostsSuperSeekBarViewNotParallelTimelinePaint` | Source-contract seam; no `AnalysisTimelineView` in mini chrome |
| 6 | `PodWash/PodWashTests/MiniPlayerSuperSeekBarHostTests.swift` | `testPlaybackControlsViewHostsSuperSeekBarView` | Full-player host seam; no parallel `AnalysisTimelineView` seek path |
| 7 | — | — | Unfiltered `scripts/verify.sh` |

**Expected authorized migrations (QA):** `LibraryUITests` mini timeline asserts that require exact `ready:12,processing:0,pending:0` without `muteMarkers:` and/or `miniPlayerAnalysisTimeline` id; any UX copy that says mini is read-only strip only.

## Verification commands

```bash
# Fast inner loop (NOT sufficient for Done):
scripts/verify.sh -only-testing:PodWashUITests/SuperSeekBarUITests
scripts/verify.sh -only-testing:PodWashUITests/LibraryUITests

# Done gate — FULL suite, zero failures, zero skips:
scripts/verify.sh
```

## Verification record (QA fills at Verify)

```
VERIFY RESULT: exit=0 total=7 passed=7 failed=0 skipped=0 filtered=1 bundle=build/test-results/verify-20260715-172330.xcresult tier=2 class=tests
```

## Plan review record (coordinator fills before downstream roles)

```
ADR review (2026-07-15): (pending) QA cleared — pipeline worker finished PM cleared — pipeline worker finished
Test spec review (2026-07-15): Architect cleared — pipeline worker finished
```

## Done gate

- [x] Every AC mapped to a test; all rows in the mapping table filled
- [ ] **Full suite green:** unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0
- [ ] Verification record pasted above
- [ ] Auto-commit on green: `slice-30: mini-player super seek parity`

## Tickets (optional)

| Ticket | Owner role | AC subset | Depends on |
|--------|------------|-----------|------------|
| — | — | — | — |

## Role artifacts

| Role | Required? | Artifact |
|------|-----------|----------|
| PM | **Required** | This story |
| Architect | **Required** | [`docs/adr/026-mini-player-super-seek-parity.md`](../adr/026-mini-player-super-seek-parity.md) |
| UX | **Required** | `docs/slices/slice-30-ux.md` |
| QA | **Required** | Test mapping + fixtures; migrate Library mini AX asserts |
| Engineer | **Required** | Shared `SuperSeekBarView` in mini + full; wire mute + seek |

## Framing

If a UI test proved mini and full used the same bar AX grammar (including mute markers) and mini seek clamped like full, you would never need to open the full player just to see red streaks or scrub.
