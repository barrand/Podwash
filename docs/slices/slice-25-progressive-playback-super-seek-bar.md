# Slice 25 — Progressive playback + super seek bar (Skipper-style)

| Field | Value |
|-------|-------|
| **ID** | 25 |
| **Title** | Progressive playback + super seek bar |
| **Status** | Done |
| **Done at** | 2026-07-15T15:51:29Z |
| **Crux** | On a stepped analyzer fixture (**120.0 s**, first chunk at **30.0 s**), playback starts after chunk-1 intervals are applied — not after full-episode ASR — while the full-player **super seek bar** exposes live 12-segment counts, elapsed + remaining time, and seek targets clamped to `processedEnd`, all assertable in XCTest without device listening or Skipper comparison. |

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

Start listening after the first **~30 s** analysis chunk while background analysis continues, and replace the full-player elapsed-only strip with a Skipper-style super seek bar (colored processing segments + draggable playhead + elapsed/remaining) that blocks seeks past the processed frontier.

## Product decisions (resolved at intake — do not re-litigate)

| Decision | Choice |
|----------|--------|
| Start threshold | **Minimal** — begin playback as soon as the **first analysis chunk (30.0 s)** is processed and intervals for that span are applied |
| Seek into unprocessed (grey) territory | **Block** — playhead / seek target clamps to `processedEnd` (processed frontier) |
| Cleaning-off / no local file | No progressive-analysis gate; super seek bar shows elapsed/remaining + playhead for normal playback (no segment colors) |
| Cached analysis (replay) | Immediate play with full timeline green/yellow; no in-flight analysis UI |

## Background (current vs desired)

**Today:** `AppShellModel.playEpisode` sets `isPreparingPlayback = true` and awaits full `PlaybackCoordinator.preparePlayback` → entire ASR + matcher + segmenter before `engine.play()`. `PlaybackControlsView` shows elapsed only (Slice 03); `AnalysisTimelineView` is a non-interactive segment strip (`playbackAnalysisTimeline`); Slice 03 UX explicitly deferred scrub slider.

**Desired:** Chunked/incremental analysis publishes partial intervals and progress snapshots; playback starts after first chunk; super seek bar combines colored processing segments + playhead + `mm:ss` elapsed **and** remaining; tap-to-seek within `[0, processedEnd]`; seeks beyond frontier clamp to `processedEnd`.

## Deliverables

- **ADR-021** — incremental analysis chunks, partial `IntervalCache` / schedule extension, processed-frontier seek policy, super-seek-bar layout + test seams (Architect authors)
- **`ChunkedAnalysisPipeline`** or incremental extension of `AnalysisPipeline` — real chunk boundaries (not ADR-018 time-based estimate) for `processedEnd` / `processingStart` / `processingEnd`
- **`PlaybackCoordinator`** — `preparePlaybackProgressive` (or equivalent): apply partial schedule after chunk 1; extend schedule as chunks complete; `canStartPlayback` (or ADR-named equivalent) after chunk 1; final cache write unchanged
- **`AppShellModel`** — start `engine.play()` on first-chunk-ready callback instead of only after full `preparePlayback`; keep `playbackAnalysisSnapshot` live during in-flight analysis; `isPreparingPlayback` may remain true until terminal snapshot while audio is already playing
- **`SuperSeekBarView`** (or evolved `PlaybackControlsView`) — combined timeline + playhead + `playback.elapsed` + **`playback.remaining`**; accessibility identifiers per UX spec
- **UX spec** `docs/slices/slice-25-ux.md` — layout, colors (Slice 20 contract), tap-to-seek interaction (no slider scrub — Slice 03 precedent), frontier clamp feedback, a11y ids, UI test scenarios
- **Fixture launch arg** `-UITestFixtureProgressivePlayback` — stepped analyzer on **120.0 s** duration; first chunk at **30.0 s**; ≥ **3** snapshots before terminal complete
- **Tests (QA):** `PodWash/PodWashTests/ProgressivePlaybackTests.swift`, `PodWash/PodWashTests/SuperSeekBarModelTests.swift`, `PodWash/PodWashUITests/ProgressivePlaybackUITests.swift`

## Fixture strategy (pinned — PM / QA)

| Asset | Value | Role |
|-------|-------|------|
| Episode duration | **120.0 s** | Matches Slice 20 fixture |
| Bucket size | **10.0 s** | **12** segments (`segmentCount == 12`) |
| First playable chunk | `processedEnd = 30.0`, processing `[30.0, 40.0)` | AC1–AC2 start gate; AC3 first snapshot `ready:3,processing:1,pending:8` |
| Mid-run snapshot | `processedEnd = 60.0`, processing `[60.0, 70.0)` | AC5 seek-clamp fixture freeze (`ready:6,processing:1,pending:5`) |
| Terminal | `processedEnd = 120.0` | AC4 complete state `ready:12,processing:0,pending:0` |
| Seek clamp attempt | Tap-to-seek to **90.0 s** when `processedEnd = 60.0` | AC5 UI: elapsed Int **55–60**; AC7 unit: **60.0 ± 0.5 s** |
| Chunk size constant | **30.0 s** | Architect may adjust in ADR if WhisperKit chunking differs; tests pin this value |
| Mute interval (AC8) | Injected transcript with ≥ **1** profanity hit wholly inside `[0, 30.0)` | Offline RMS **< 0.01** inside mute window (Slice 08 pattern; golden provenance hand-computed from `matching-spec.md` §8, not pipeline output) |

## Depends on

- Slice 20 — `AnalysisTimelineModel`, `AnalysisProgressSnapshot`, timeline colors
- Slice 24 — production analyzer factory + `AppShellModel` play path
- Slice 03 — `PlaybackEngine` seek surface, `playback.elapsed` contract (extend, do not break transport ids)
- Slice 08 — `PlaybackCoordinator`, offline mix asserts for partial schedules

**Parallelizable:** No — touches composition root, pipeline, coordinator, and full-player chrome. **Supersedes** the player-chrome scope of [task-011](../tasks/task-011-analysis-timeline-mini-full-player.md) (timeline visibility + heights); task-011 is **Halted** — do not reopen unless this slice defers mini-player timeline.

## Out-of-scope

- Changing **when** analysis runs (first play vs toggle) — Slice 13 policy
- Progressive analysis on **streaming-only** URL (no local file) — ADR-008 / Slice 24 gate unchanged
- CarPlay / lock-screen custom seek bar (native `MPNowPlayingInfoCenter` elapsed only)
- Episode-row timeline behavior (Slice 20 `analysisTimeline` — unchanged)
- Mini-player super seek bar / interactive playhead (full player only; mini may keep read-only `miniPlayerAnalysisTimeline` from task-011)
- Allowing uncleaned playback in grey/unprocessed regions (intake decision: **block**)
- Cached-replay progressive UI (immediate full green/yellow bar — no new AC; covered by Slice 20 terminal contract)
- Cleaning-off segment colors (elapsed + remaining + playhead only — no dedicated AC beyond preserving Slice 03 transport ids)
- Re-encoding audio; `MTAudioProcessingTap`
- Subjective Skipper side-by-side or device listening gates

## Acceptance criteria

Automatable only. **XCTSkip is not allowed on core ACs** — a mapped test that cannot run must fail.

- [ ] 1. Unit test (`ProgressivePlaybackTests`, stepped analyzer fixture, duration **120.0 s**): after pipeline emits first snapshot with `processedEnd = 30.0`, `PlaybackCoordinator` (or spy) within **0.5 s** has `cachedIntervals.count ≥ 1`, every interval `end ≤ 30.0` s, and `canStartPlayback == true` — without waiting for `processedEnd = 120.0`.
- [ ] 2. Unit test (same fixture): within **0.5 s** of AC1 chunk-ready signal, `engine.isPlaying == true` (or play-spy records `play()`); full `analyze` completion is **not** required first.
- [ ] 3. UI test (`-UITestFixtureProgressivePlayback`, cleaning on, local audio): tap play → within **5.0 s**, `playback.playPause` `accessibilityValue` is **`playing`** while `playback.superSeekBar` `accessibilityValue` is exactly **`ready:3,processing:1,pending:8`** (first chunk, not terminal `ready:12`).
- [ ] 4. UI test (same fixture): within **10.0 s** of play, `playback.superSeekBar` `accessibilityValue` becomes **`ready:12,processing:0,pending:0`** (terminal analysis complete while playback may continue).
- [ ] 5. UI test (same fixture, fixture frozen at `processedEnd = 60.0`): tap-to-seek on `playback.superSeekBar` to position **90.0 s** (UX documents coordinate or custom accessibility action — **no** slider scrub) → within **2.0 s**, `playback.elapsed` `accessibilityValue` parsed as `Int` is **≥ 55** and **≤ 60**.
- [ ] 6. UI test (same fixture, playing at **≥ 10.0 s** elapsed): `playback.remaining` exists; `Int(elapsed) + Int(remaining)` is **118–122** (duration **120.0 s**, ± **2 s** tick tolerance).
- [ ] 7. Unit test (`SuperSeekBarModelTests`): playhead position for elapsed **15.0 s** on **120.0 s** duration maps to normalized position **0.125 ± 0.02**; frontier clamp: requested seek **90.0 s** with `processedEnd = 60.0` returns **60.0 ± 0.5 s**.
- [ ] 8. Offline integration test (injected transcript chunked at **30.0 s** boundaries, sine fixture): after chunk-1 schedule applied, offline render RMS **< 0.01** inside a mute interval wholly within `[0, 30.0)` (Slice 08 pattern).
- [ ] 9. Full suite green via `scripts/verify.sh` (**exit 0, failed 0, skipped 0**).

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/ProgressivePlaybackTests.swift` | `testPlaybackStartsAfterFirstChunkIntervalsApplied` | Stepped double; `canStartPlayback` + intervals `end ≤ 30.0` before terminal |
| 2 | `PodWash/PodWashTests/ProgressivePlaybackTests.swift` | `testAppShellStartsPlayBeforeFullAnalysisCompletes` | `isPlaying` within 0.5 s; `analyze` still in flight |
| 3 | `PodWash/PodWashUITests/ProgressivePlaybackUITests.swift` | `testPlaybackStartsWhileAnalysisInFlight` | `ready:3,processing:1,pending:8` + `playing` |
| 4 | `PodWash/PodWashUITests/ProgressivePlaybackUITests.swift` | `testSeekBarReachesTerminalAnalysisState` | Terminal `ready:12,processing:0,pending:0` |
| 5 | `PodWash/PodWashUITests/ProgressivePlaybackUITests.swift` | `testSeekClampsToProcessedFrontier` | Freeze at 60 s; tap `dx=0.75` → elapsed Int 55–60 |
| 6 | `PodWash/PodWashUITests/ProgressivePlaybackUITests.swift` | `testElapsedAndRemainingSumToDuration` | Sum 118–122 |
| 7 | `PodWash/PodWashTests/SuperSeekBarModelTests.swift` | `testPlayheadPositionAndFrontierClamp` | 0.125 ± 0.02; clamp 60.0 ± 0.5 s |
| 8 | `PodWash/PodWashTests/ProgressivePlaybackTests.swift` | `testPartialScheduleMutesWithinFirstChunk` | §8 transcript chunk 1; RMS < 0.01 |
| 9 | — | — | Command-level: unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0 |

## Verification commands

```bash
# Fast inner loop (NOT sufficient for Done):
scripts/verify.sh -only-testing:PodWashTests/ProgressivePlaybackTests -only-testing:PodWashTests/SuperSeekBarModelTests
scripts/verify.sh -only-testing:PodWashUITests/ProgressivePlaybackUITests

# Done gate — FULL suite, zero failures, zero skips:
scripts/verify.sh
```

## Verification record (QA fills at Verify)

```
VERIFY RESULT: exit=0 total=179 passed=179 failed=0 skipped=0 filtered=0 bundle=build/test-results/verify-20260715-094109.xcresult tier=3 class=tests
```

## Design notes (Architect)

Canonical design: [`docs/adr/021-progressive-playback-super-seek-bar.md`](../adr/021-progressive-playback-super-seek-bar.md).

Summary pins for downstream roles:

- Chunk size **30.0 s**; cache write **terminal only**; partial intervals via `onPartialIntervals`.
- `PlaybackCoordinator.preparePlaybackProgressive` + `canStartPlayback` after first chunk; shell may `play()` while `isPreparingPlayback` remains true.
- Full-player identifier `playback.superSeekBar` (retires `playbackAnalysisTimeline`); frontier clamp in `SuperSeekBarModel` above `PlaybackEngine`.
- Done-gate ACs use fixture / injected doubles — no live WhisperKit chunk-timing spike required.

## Plan review record (coordinator fills before downstream roles)

```
ADR review (2026-07-15): (pending) QA cleared — pipeline worker finished PM cleared — pipeline worker finished
Test spec review (2026-07-15): Architect cleared — pipeline worker finished
```

## Done gate

- [x] Every AC mapped to a test; all rows in the mapping table filled
- [ ] **Full suite green:** unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0
- [ ] Verification record pasted above (exit code + counts + `.xcresult` path)
- [ ] Auto-commit made on green: `slice-25: progressive playback + super seek bar` (push only when the user asks)

## Role artifacts

| Role | Gate | Artifact path |
|------|------|---------------|
| Architect | **Required** | `docs/adr/021-progressive-playback-super-seek-bar.md` |
| UX | **Required** | `docs/slices/slice-25-ux.md` |

## Human checklist (post-verify spot-check — not a Done gate)

- [ ] iPhone, downloaded episode, channel cleaning **on**: tap play → audio starts in **< 10 s** (not minutes).
- [ ] Full player: colored bar shows blue/grey advancing while listening.
- [ ] Drag playhead: cannot scrub into grey/unprocessed tail; playhead stops at the colored/green frontier.
- [ ] Elapsed and remaining times both visible and sensible during playback.
