# Slice 25 — Progressive playback + super seek bar (Skipper-style)

| Field | Value |
|-------|-------|
| **ID** | 25 |
| **Title** | Progressive playback + super seek bar |
| **Status** | Draft |
| **Crux** | With cleaning enabled on a downloaded episode, playback starts after the **first ~30 s** analysis chunk is ready (not after full-episode ASR), the full-player **super seek bar** shows live processing progress (green/blue/grey) plus a draggable playhead with **elapsed and remaining** time, and seeks past the processed frontier are **blocked** — all assertable via stepped analyzer fixtures without device listening or Skipper comparison. |

## PRD / spec references

- PRD §2 — table-stakes **seek/scrubbing** and polished playback chrome
- PRD §3 — clear UI indicators for analysis in progress; cleaning is dynamic (no re-encode)
- PRD §11 (2026-07-10) — analysis on first play with cleaning enabled; cache until episode deleted
- Slice 20 — `AnalysisTimelineModel` / 12-segment color contract (green/blue/grey/yellow)
- Slice 24 — production `AnalysisPipeline` + `AppShellModel.playEpisode` wiring
- `docs/adr/000-foundations.md` §1–§3 — AVPlayer + audioMix; offline verification; local files only for cleaned playback
- `docs/adr/006-playback-integration.md` — `PlaybackCoordinator.preparePlayback` (today: full analyze before schedule)
- `docs/adr/018-analysis-timeline.md` — `AnalysisProgressSnapshot` seam (today: time-based estimate during ASR, not chunk truth)

## Goal

Deliver Skipper-inspired “magic seek bar” UX: start listening quickly while analysis continues in the background, see how much of the episode is processed on the bar, scrub within processed territory, and read elapsed + remaining time — without blocking on full-episode WhisperKit completion.

## Product decisions (resolved at intake — do not re-litigate)

| Decision | Choice |
|----------|--------|
| Start threshold | **Minimal** — begin playback as soon as the **first analysis chunk (~30 s)** is processed and intervals for that span are applied |
| Seek into unprocessed (grey) territory | **Block** — playhead / seek target clamps to `processedEnd` (processed frontier) |
| Cleaning-off / no local file | No progressive-analysis gate; super seek bar still shows elapsed/remaining + playhead for normal playback |
| Cached analysis (replay) | Immediate play with full timeline green/yellow; no in-flight analysis UI |

## Goal (current vs desired)

**Today:** `AppShellModel.playEpisode` sets `isPreparingPlayback = true` and awaits full `PlaybackCoordinator.preparePlayback` → entire ASR + matcher + segmenter before `engine.play()`. `PlaybackControlsView` shows elapsed only (Slice 03); `AnalysisTimelineView` is a non-interactive segment strip; Slice 03 UX explicitly deferred scrub slider.

**Desired:** Chunked/incremental analysis publishes partial intervals and progress snapshots; playback starts after first chunk; super seek bar combines colored processing segments + playhead + `mm:ss` elapsed **and** remaining; drag/tap seek within `[0, processedEnd]`; seeks beyond frontier clamp to `processedEnd`.

## Deliverables

- **ADR-021** — incremental analysis chunks, partial `IntervalCache` / schedule extension, processed-frontier seek policy, super-seek-bar layout + test seams (Architect authors)
- **`ChunkedAnalysisPipeline`** or incremental extension of `AnalysisPipeline` — real chunk boundaries (not ADR-018 time-based estimate) for `processedEnd` / `processingStart` / `processingEnd`
- **`PlaybackCoordinator`** — `preparePlaybackProgressive` (or equivalent): apply partial schedule after chunk 1; extend schedule as chunks complete; final cache write unchanged
- **`AppShellModel`** — start `engine.play()` on first-chunk-ready callback instead of only in `preparePlayback` defer; keep `playbackAnalysisSnapshot` live during in-flight analysis
- **`SuperSeekBarView`** (or evolved `PlaybackControlsView`) — combined timeline + playhead + elapsed/remaining labels; accessibility identifiers per UX spec
- **UX spec** `docs/slices/slice-25-ux.md` — layout, colors (Slice 20 contract), playhead drag/tap interaction, frontier clamp feedback, a11y ids, UI test scenarios (tap-to-seek preferred over flaky slider scrub per Slice 03 precedent)
- **Tests (QA):** `PodWash/PodWashTests/ProgressivePlaybackTests.swift`, `PodWash/PodWashTests/SuperSeekBarModelTests.swift`, `PodWash/PodWashUITests/ProgressivePlaybackUITests.swift`
- **Fixture:** `-UITestFixtureProgressivePlayback` — stepped analyzer emitting first chunk at **30.0 s** on **120.0 s** duration; ≥ 3 snapshots before terminal complete

## Fixture strategy (pinned — PM / QA)

| Asset | Value | Role |
|-------|-------|------|
| Episode duration | **120.0 s** | Matches Slice 20 fixture |
| First playable chunk | **`processedEnd = 30.0`**, processing `[30.0, 40.0)` | AC1–AC2 start gate + frontier |
| Mid-run snapshot | `processedEnd = 60.0`, processing `[60.0, 70.0)` | AC3 live bar update |
| Terminal | `processedEnd = 120.0` | AC4 complete state |
| Seek clamp attempt | User/tap seeks to **90.0 s** when `processedEnd = 60.0` | AC5 clamps to **60.0 ± 0.5 s** |
| Chunk size constant | **30.0 s** | Architect may adjust in ADR if WhisperKit chunking differs; tests pin this value |

## Depends on

- Slice 20 — `AnalysisTimelineModel`, `AnalysisProgressSnapshot`, timeline colors
- Slice 24 — production analyzer factory + `AppShellModel` play path
- Slice 03 — `PlaybackEngine` seek surface, `playback.elapsed` contract (extend, do not break transport ids)
- Slice 08 — `PlaybackCoordinator`, offline mix asserts for partial schedules

**Parallelizable:** No — touches composition root, pipeline, coordinator, and full-player chrome. **Supersedes** the player-chrome scope of [task-011](../tasks/task-011-analysis-timeline-mini-full-player.md) (timeline visibility + heights); task-011 should be **Halted** or folded here before either ships.

## Out-of-scope

- Changing **when** analysis runs (first play vs toggle) — Slice 13 policy
- Progressive analysis on **streaming-only** URL (no local file) — ADR-008 / Slice 24 gate unchanged
- CarPlay / lock-screen custom seek bar (native MPNowPlayingInfoCenter elapsed only)
- Episode-row timeline behavior (Slice 20)
- Allowing uncleaned playback in grey/unprocessed regions (intake decision: **block**)
- Re-encoding audio; MTAudioProcessingTap
- Subjective Skipper side-by-side or device listening gates

## Acceptance criteria

Automatable only. **XCTSkip is not allowed on core ACs.**

- [ ] 1. Unit test (`ProgressivePlaybackTests`, stepped analyzer fixture, duration **120.0 s**): after pipeline emits first snapshot with `processedEnd = 30.0`, `PlaybackCoordinator` (or spy) has **non-empty** `cachedIntervals` covering only `[0, 30.0)` and `canStartPlayback == true` within **0.5 s** of that emission (no wait for `processedEnd = 120.0`).
- [ ] 2. Unit test (same fixture): `AppShellModel` (or test harness) transitions `isPreparingPlayback` → playback **started** (`engine.isPlaying` or play-spy) within **0.5 s** of AC1 chunk-ready signal; full `analyze` completion is **not** required first.
- [ ] 3. UI test (`-UITestFixtureProgressivePlayback`, cleaning on, local audio): tap play → within **5.0 s**, `playback.playPause` `accessibilityValue` is **`playing`** while `playbackAnalysisTimeline` (or `playback.superSeekBar`) `accessibilityValue` matches **`ready:3,processing:1,pending:8`** (first chunk, not terminal `ready:12`).
- [ ] 4. UI test (same fixture): within **10.0 s** of play, `accessibilityValue` becomes **`ready:12,processing:0,pending:0`** (terminal analysis complete while playback may continue).
- [ ] 5. UI test (same fixture, `processedEnd = 60.0` mid-run): tap/drag seek on `playback.superSeekBar` to position **90.0 s** (fixture documents bar coordinate or accessibility action) → within **2.0 s**, `playback.elapsed` `accessibilityValue` as `Int` is **≤ 60** and **≥ 55** (clamped to frontier **60.0 ± 5.0 s** rounding).
- [ ] 6. UI test (same fixture, playing at **≥ 10.0 s** elapsed): `playback.remaining` exists; `Int(elapsed) + Int(remaining) == 120` (± **2 s** tolerance for tick timing).
- [ ] 7. Unit test (`SuperSeekBarModelTests` or layout constants): playhead position for elapsed **15.0 s** on **120.0 s** duration maps to normalized position **0.125 ± 0.02**; frontier clamp: requested **90.0 s** with `processedEnd = 60.0` returns **60.0 ± 0.5 s**.
- [ ] 8. Offline integration test (injected transcript chunked at **30.0 s** boundaries, sine fixture): after chunk 1 schedule applied, offline render RMS **< 0.01** inside a mute interval wholly within `[0, 30.0)` (Slice 08 pattern).
- [ ] 9. Full suite green via `scripts/verify.sh` (**exit 0, failed 0, skipped 0**).

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/ProgressivePlaybackTests.swift` | `testPlaybackStartsAfterFirstChunkIntervalsApplied` | TBD until QA test spec |
| 2 | `PodWash/PodWashTests/ProgressivePlaybackTests.swift` | `testAppShellStartsPlayBeforeFullAnalysisCompletes` | TBD |
| 3 | `PodWash/PodWashUITests/ProgressivePlaybackUITests.swift` | `testPlaybackStartsWhileAnalysisInFlight` | TBD |
| 4 | `PodWash/PodWashUITests/ProgressivePlaybackUITests.swift` | `testSeekBarReachesTerminalAnalysisState` | TBD |
| 5 | `PodWash/PodWashUITests/ProgressivePlaybackUITests.swift` | `testSeekClampsToProcessedFrontier` | TBD |
| 6 | `PodWash/PodWashUITests/ProgressivePlaybackUITests.swift` | `testElapsedAndRemainingSumToDuration` | TBD |
| 7 | `PodWash/PodWashTests/SuperSeekBarModelTests.swift` | `testPlayheadPositionAndFrontierClamp` | TBD |
| 8 | `PodWash/PodWashTests/ProgressivePlaybackTests.swift` | `testPartialScheduleMutesWithinFirstChunk` | TBD |
| 9 | — | full `scripts/verify.sh` | Done gate |

## Verification commands

```bash
# Fast inner loop (NOT sufficient for Done):
scripts/verify.sh -only-testing:PodWashTests/ProgressivePlaybackTests
scripts/verify.sh -only-testing:PodWashUITests/ProgressivePlaybackUITests

# Done gate — FULL suite, zero failures, zero skips:
scripts/verify.sh
```

## Verification record (QA fills at Verify)

```
VERIFY RESULT: (pending)
```

## Plan review record (coordinator fills before downstream roles)

```
ADR review: (pending)
Test spec review: (pending)
```

## Done gate

- [ ] Every AC mapped to a test; all rows in the mapping table filled
- [ ] **Full suite green:** unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0
- [ ] Verification record pasted above (exit code + counts + `.xcresult` path)
- [ ] Auto-commit made on green: `slice-25: progressive playback + super seek bar` (push only when the user asks)

## Role artifacts

| Role | Gate | Artifact path |
|------|------|---------------|
| Architect | **Required** | `docs/adr/021-progressive-playback-super-seek-bar.md` |
| UX | **Required** | `docs/slices/slice-25-ux.md` |

## Human checklist (post-verify spot-check)

- [ ] iPhone, downloaded episode, channel cleaning **on**: tap play → audio starts in **< 10 s** (not minutes).
- [ ] Full player: colored bar shows blue/grey advancing while listening.
- [ ] Drag playhead: cannot scrub into grey/unprocessed tail; playhead stops at the colored/green frontier.
- [ ] Elapsed and remaining times both visible and sensible during playback.
